// Sources/Speech/SpeechCapture.swift — on-device speech-to-text: SFSpeechRecognizer + AVAudioEngine
import Foundation
import Speech
import AVFoundation

/// Errors specific to `SpeechCapture` (as opposed to whatever `Error` the Speech framework itself
/// throws/reports).
enum SpeechCaptureError: Error, Sendable {
    case recognizerUnavailable
    case authorizationDenied
    case recognitionFailed(String)
    /// On-device recognition couldn't run (Dictation is off on this Mac). Distinct from
    /// `recognitionFailed` so the caller can offer "enable Dictation" / "use Apple's servers"
    /// instead of a generic error.
    case onDeviceUnavailable
}

extension SpeechCaptureError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognizer is unavailable right now."
        case .authorizationDenied:
            return "Speech recognition or microphone access was denied."
        case .recognitionFailed(let message):
            return "Speech recognition failed: \(message)"
        case .onDeviceUnavailable:
            return "On-device dictation is off on this Mac."
        }
    }
}

/// Bridges Apple's Speech framework into a plain start/stop + callback API. Prefers on-device
/// recognition (`requiresOnDeviceRecognition = true`, no audio/transcript ever leaves the
/// machine — constitution I); falls back to Apple's server-based recognition only when the
/// caller has explicitly set `allowServerFallback = true` (user consent, e.g. Dictation is off).
///
/// ## Ownership & bridging (for Phase 2C `HotkeyManager` / Phase 3 `VolarApp` wiring)
/// `HotkeyManager` should own exactly one `SpeechCapture` for the app's lifetime (creating a new
/// `SFSpeechRecognizer` + `AVAudioEngine` pair per keypress is wasteful and can hit rate limits).
/// This type intentionally has **no dependency on `AppState`** — per the Phase 2 split in
/// `docs/app-architecture.md`, `Speech/` stays decoupled from `App/`; the caller bridges partials
/// and completion into `AppState`. Intended wiring, once the ⌃⌥M toggle-capture hotkey fires:
///
/// ```swift
/// // once, at HotkeyManager init:
/// speechCapture.onFinal = { final in appState.finishRecording(transcript: final) }
/// speechCapture.onError = { _ in appState.captureState = .error }
///
/// // first press (toggle -> start):
/// appState.startCapture()                       // -> .recording; clears liveTranscript/parsed
/// Task {
///     guard await speechCapture.requestAuthorization() else {
///         appState.captureState = .error
///         return
///     }
///     speechCapture.start(onPartial: { partial in appState.liveTranscript = partial })
/// }
///
/// // second press (toggle -> stop):
/// speechCapture.stop()   // triggers one last final result -> onFinal -> finishRecording(transcript:)
/// ```
///
/// ## Concurrency bridging (UNVERIFIED — please double-check on the Mac/Xcode 26 toolchain)
/// This type is `@MainActor` (all its stored state — engine/request/task refs, `isRunning` — is
/// only ever touched from the main actor). Two system callbacks do NOT run on the main actor and
/// must not touch `self` or MainActor-isolated state directly:
///   1. `AVAudioNode.installTap` block runs on a realtime audio thread. It must stay
///      allocation-light and non-blocking, so it captures only the local `SFSpeechAudioBufferRecognitionRequest`
///      (via `nonisolated(unsafe) let`, since that system class isn't `Sendable` but
///      `append(_:)` is documented safe to call from any thread while streaming) and calls only
///      `append(buffer:)` — it never reaches back into `self`.
///   2. `SFSpeechRecognizer.recognitionTask`'s result handler is invoked on an arbitrary
///      non-main queue. It captures `self` weakly (`nonisolated(unsafe) weak var` boxing avoided by
///      hopping immediately) and re-enters the main actor via `Task { @MainActor in ... }` before
///      touching `self` or invoking the caller-supplied `onPartial`/`onFinal`/`onError` closures —
///      those are expected to feed `AppState`, a `@MainActor` type.
/// If the Xcode 26 SDK has tightened `AVAudioNodeTapBlock` / the recognition-task closure to
/// require full `Sendable` closures (or `@Sendable` capture lists), the `nonisolated(unsafe)`
/// local-let workaround below is the intended escape hatch — narrow it further (e.g. wrap in a
/// dedicated `@unchecked Sendable` box type) if the compiler still objects on Mac.
@MainActor
final class SpeechCapture {
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private(set) var isRunning = false

    /// Fires once, on the main actor, with the last transcript when recognition ends (normally
    /// right after `stop()` flushes the request and the recognizer reports `isFinal`). Set this
    /// before calling `start(onPartial:)`. The CALLER is responsible for then calling
    /// `appState.finishRecording(transcript:)` — kept as a settable property rather than a
    /// `start(...)` parameter so `start`'s signature stays exactly `(onPartial:)`.
    var onFinal: ((String) -> Void)?

    /// Fires on the main actor if recognition can't start (e.g. recognizer unavailable) or fails
    /// mid-stream. Set this before calling `start(onPartial:)`. The caller is expected to set
    /// `appState.captureState = .error` from it.
    var onError: ((Error) -> Void)?

    /// Interim-result handler, stored (not just a `start` parameter) so the recognition-task
    /// callback can reach it via `self` on the main actor instead of capturing a non-Sendable
    /// closure into the `@MainActor` hop.
    private var onPartialHandler: ((String) -> Void)?

    /// When false (default): force on-device recognition (private, needs Dictation enabled).
    /// When true (user consented): allow Apple's server recognition (audio leaves the Mac).
    var allowServerFallback = false

    /// Tracks whether the in-flight attempt is on-device, so the `recognitionTask` error handler
    /// can tell a Dictation-disabled failure apart from any other recognition failure.
    private var isOnDeviceAttempt = false

    /// Bumped on every `start()` and on `cancel()`; the `recognitionTask` completion closure
    /// captures the token in effect when *its* task was created and only delivers `onFinal`/
    /// `onError` if `session` still matches it when the (main-actor-hopped) callback runs. This
    /// guards against a late/stale callback from a superseded or cancelled task reaching the
    /// current capture (see FIX 2/FIX 4 in HotkeyManager/SpeechCapture review notes).
    private var session = 0

    #if os(iOS)
    /// AVAudioSession interruption token (phone call, Siri, etc. — R6, plan.md §8). Registered
    /// once in `init` for the app's lifetime (mirrors `VolarApp.swift`'s own app-lifetime
    /// `NotificationCenter` observers — never removed; no leak, since this type is an
    /// app-lifetime singleton owned by `AppState`).
    private var interruptionObserverToken: NSObjectProtocol?
    #endif

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.recognizer = Self.resolvedRecognizer(for: locale)
        #if os(iOS)
        registerInterruptionObserver()
        #endif
    }

    #if os(iOS)
    /// R6 (plan.md §8): a phone call or Siri request interrupts recording. On `.began`, stop
    /// capture the SAME way a user-initiated stop would (`stop()`, not `cancel()`) so the
    /// recognizer still delivers its final result with whatever transcript accumulated so far —
    /// never silently discarded, never a crash. `.ended` is deliberately NOT auto-resumed:
    /// resuming a live mic capture without the user re-tapping the FAB would be surprising, and
    /// this feature requests no background-audio capability (plan §7.2), so most interruptions
    /// outlive the app's foreground time anyway.
    /// `@Sendable` + explicit `Task { @MainActor in }` hop mirrors `VolarApp.swift`'s
    /// `registerWindowIndependentObservers()` convention — `addObserver(forName:object:queue:
    /// using:)`'s `using` closure is NOT inferred `@MainActor` even though `queue: .main`
    /// guarantees main-thread delivery (same gotcha documented there), so this hops explicitly
    /// rather than touching `self`/`isRunning` directly in the closure body.
    /// // UNVERIFIED: AVAudioSessionInterruptionTypeKey/InterruptionType payload shape — matches
    /// Apple's documented AVAudioSession interruption-handling sample code, not exercised here.
    private func registerInterruptionObserver() {
        interruptionObserverToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { @Sendable [weak self] notification in
            guard let info = notification.userInfo,
                  let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType),
                  type == .began else { return }
            Task { @MainActor in
                self?.stop()
            }
        }
    }
    #endif

    /// Switch the recognition language at runtime (Settings ▸ Language). Recreates the underlying
    /// recognizer via `resolvedRecognizer(for:)`'s fallback chain; only a truly last-resort failure
    /// (see that function's doc comment) surfaces later as `.recognizerUnavailable`.
    func setLocale(_ locale: Locale) {
        recognizer = Self.resolvedRecognizer(for: locale)
    }

    /// Resolves a locale to a working `SFSpeechRecognizer`, with graceful fallbacks so a capture
    /// never dies outright on an unsupported locale. Regression fix (2026-07-26): `AppState`'s
    /// "Automatic" recognition-language choice resolves to `Locale.current`, and
    /// `SFSpeechRecognizer.init(locale:)` returns `nil` for anything
    /// `SFSpeechRecognizer.supportedLocales()` doesn't cover exactly — an unusual region, a locale
    /// like "en-VN", or one carrying extensions like "vi-VN@calendar=gregorian" — which, unguarded,
    /// would kill capture on a brand-new install whose system locale isn't a good match. Centralized
    /// here (not in `AppState`) so every call site — `init`, `setLocale` — is protected the same way.
    ///
    /// 1. Try the exact locale first (unchanged fast path for an already-supported locale, e.g. the
    ///    hardcoded `"en-US"` default or any locale the user explicitly picked in Settings).
    /// 2. Fall back to any `supportedLocales()` entry sharing the same base language code (e.g. the
    ///    system locale is a Vietnamese variant `SFSpeechRecognizer` doesn't recognize verbatim, but
    ///    it does support a different Vietnamese locale tag) — still recognizes the right language.
    /// 3. Last resort: `"en-US"`, which is guaranteed supported — this is exactly the fixed default
    ///    this type had before the "Automatic"/`Locale.current` path existed, so behavior here can
    ///    never be worse than it was before that change.
    /// Logs which branch fired (via the same `print` convention as the two callers above) so this
    /// is visible during a Mac verify session.
    private static func resolvedRecognizer(for locale: Locale) -> SFSpeechRecognizer? {
        if let exact = SFSpeechRecognizer(locale: locale) {
            return exact
        }
        if let languageCode = locale.language.languageCode?.identifier,
           let sameLanguageLocale = SFSpeechRecognizer.supportedLocales().first(where: {
               $0.language.languageCode?.identifier == languageCode
           }),
           let sameLanguageRecognizer = SFSpeechRecognizer(locale: sameLanguageLocale) {
            print("[Volar.Speech] locale \(locale.identifier) unsupported -> falling back to same-language locale \(sameLanguageLocale.identifier)")
            return sameLanguageRecognizer
        }
        print("[Volar.Speech] locale \(locale.identifier) unsupported and no same-language match -> falling back to en-US")
        return SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - Authorization

    /// Requests both Speech-recognition and microphone authorization; returns `true` only if both
    /// are granted (recording is pointless with just one). Safe to call every time before
    /// `start(...)` — the system only prompts the user once and returns the cached decision after.
    ///
    /// IMPORTANT (Swift 6 dynamic isolation): this method lives on a `@MainActor` type, so any
    /// non-`@Sendable` closure literal formed here is INFERRED to be MainActor-isolated. The
    /// Speech framework's completion handler isn't `@Sendable` in the SDK and is invoked on a
    /// background queue (`com.apple.root.default-qos`) — Swift 6 inserts a runtime
    /// `dispatch_assert_queue(main)` check at the entry of MainActor-isolated closures, which
    /// traps with EXC_BREAKPOINT *before the closure body even runs* (this is why the
    /// `ContinuationOnce` double-resume guard alone could not stop the crash). The explicit
    /// `@Sendable` below opts the closure out of MainActor inference so it may legally run on
    /// any queue.
    func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            // `@Sendable` is load-bearing — see the isolation note in the doc comment above.
            // ContinuationOnce additionally guards against the handler firing more than once
            // (a second resume of a checked continuation also traps).
            let once = ContinuationOnce(continuation)
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                once.resume(status)
            }
        }
        guard speechStatus == .authorized else { return false }

        // Fix (2026-07-27): was `AVAudioApplication.requestRecordPermission()` — that API is
        // iOS 17+/Mac Catalyst only and never triggered macOS's mic TCC prompt at all, which is
        // why anh Khôi never saw a permission dialog. `MicrophonePermission` (this module) wraps
        // the real native-macOS entry point, `AVCaptureDevice.requestAccess(for:)` — no completion
        // handler, no continuation, so still no isolation-inference hazard for the mic half.
        let micGranted = await MicrophonePermission.request()
        return micGranted
    }

    // MARK: - Start / stop

    /// Starts on-device recognition and taps the default input. `onPartial` fires on the main
    /// actor with the transcript-so-far for every interim result (live captions while
    /// `.recording`). Final-transcript and error notifications go through the `onFinal`/`onError`
    /// properties above (set them before calling `start`) rather than extra parameters here, so
    /// this method's signature matches `start(onPartial: @escaping (String) -> Void)` exactly.
    func start(onPartial: @escaping (String) -> Void) {
        guard !isRunning else { return }
        // A prior `stop()` ends audio but leaves `task`/`request` alive until the recognizer
        // delivers its final result asynchronously; if that hasn't happened yet, cancel it now
        // (not just nil it) so its eventual callback can't deliver into this new capture, and bump
        // `session` so the token check below also rejects it if it's already past the cancel call.
        session += 1
        task?.cancel()
        task = nil
        request = nil
        guard let recognizer, recognizer.isAvailable else {
            onError?(SpeechCaptureError.recognizerUnavailable)
            return
        }

        onPartialHandler = onPartial

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        // Prefer on-device (private). Only use Apple's servers when the user has explicitly
        // consented (allowServerFallback) — audio leaves the Mac in that mode.
        let useOnDevice = !allowServerFallback
        newRequest.requiresOnDeviceRecognition = useOnDevice
        isOnDeviceAttempt = useOnDevice
        newRequest.taskHint = .dictation          // free-form sentences, not search/confirmation
        if #available(macOS 13.0, *) {
            newRequest.addsPunctuation = true      // better readability + segmentation
        }
        request = newRequest

        // iOS: without an active recording AVAudioSession the mic is silent with no error.
        do {
            try RecordingAudioSession.activate()
        } catch {
            request = nil
            onError?(SpeechCaptureError.recognitionFailed("Audio session setup failed: \(error.localizedDescription)"))
            return
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // With no usable input device (or the mic TCC grant not yet effective) the hardware
        // format comes back as 0 Hz / 0 channels — `installTap` then raises an ObjC exception
        // ("IsFormatSampleRateAndChannelCountValid(format)") and CoreAudio aborts the process.
        // Fail soft through `onError` instead.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            teardown()
            onError?(SpeechCaptureError.recognitionFailed("No usable audio input device"))
            return
        }

        // Realtime audio thread from here down: capture only the request (thread-safe `append`),
        // never `self`. `@Sendable` is load-bearing: without it this closure literal, formed in a
        // `@MainActor` method, is inferred MainActor-isolated and Swift 6's runtime isolation
        // check traps (EXC_BREAKPOINT) when the audio thread invokes it — same failure mode as
        // the authorization callback (see `requestAuthorization`).
        nonisolated(unsafe) let tapRequest = newRequest
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            tapRequest.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            teardown()
            onError?(error)
            return
        }

        isRunning = true

        // Captured by value into the recognitionTask closure below so the (main-actor-hopped)
        // completion handler can tell whether it belongs to *this* start() call or a stale one
        // that `cancel()`/a later `start()` has since superseded (see `session` doc comment).
        let taskSession = session

        // `@Sendable` again load-bearing (arbitrary-queue callback; prevents MainActor inference
        // + the Swift 6 runtime isolation trap). Capturing `self` weakly is fine — a @MainActor
        // class is implicitly Sendable.
        task = recognizer.recognitionTask(with: newRequest) { @Sendable [weak self] result, error in
            // This handler runs on an arbitrary queue, and `result`/`error` are non-Sendable.
            // Pull only Sendable primitives out here, then hop to the main actor with just those
            // (never send SFSpeechRecognitionResult / NSError across the actor boundary). Mirrors
            // the Sendable-primitive extraction pattern in HotkeyManager.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorMessage = error?.localizedDescription
            let nsError = error as NSError?
            let errorDomain = nsError?.domain
            let errorCode = nsError?.code
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Stale callback from a task `cancel()`/a newer `start()` already superseded —
                // never deliver into the current capture (privacy/correctness guard).
                guard self.session == taskSession else { return }
                if let text {
                    if isFinal {
                        self.teardown()
                        self.onFinal?(text)
                    } else {
                        self.onPartialHandler?(text)
                    }
                }
                if let errorMessage {
                    self.teardown()
                    let lower = errorMessage.lowercased()
                    // Dictation-off is reported by the Speech framework as
                    // `kAFAssistantErrorDomain` code 1101 or 1107 — checked first since the
                    // string match below only matches English-localized descriptions and misses
                    // e.g. Vietnamese macOS. // UNVERIFIED: exact domain/code values.
                    let isDictationDomainError = errorDomain == "kAFAssistantErrorDomain"
                        && (errorCode == 1101 || errorCode == 1107)
                    let looksLikeDictationOff = lower.contains("dictation") || lower.contains("siri")
                    if self.isOnDeviceAttempt, isDictationDomainError || looksLikeDictationOff {
                        self.onError?(SpeechCaptureError.onDeviceUnavailable)
                    } else {
                        self.onError?(SpeechCaptureError.recognitionFailed(errorMessage))
                    }
                }
            }
        }
    }

    /// Ends the audio input and signals end-of-utterance to the recognition request, which causes
    /// the recognizer to deliver one last final result on the in-flight task (routed through the
    /// `onFinal` property, if set). Safe to call even if recognition already finished on its own.
    func stop() {
        guard isRunning else { return }
        request?.endAudio()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRunning = false
    }

    /// Immediately abandons the in-flight capture: bumps `session` (via `teardown()`, so the recognitionTask
    /// completion closure's session check — see above — drops any result/error already in
    /// flight, delivering neither `onFinal` nor `onError`), then runs the same teardown `stop()`
    /// and the recognizer's own completion path share.
    func cancel() {
        teardown()
    }

    /// Internal cleanup shared by the "recognizer finished/errored on its own" and `stop()` paths.
    private func teardown() {
        session += 1
        task?.cancel()
        task = nil
        request = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        isRunning = false
        RecordingAudioSession.deactivate()
    }
}

/// Guards a `CheckedContinuation` so it is resumed at most once. Some system authorization
/// callbacks (notably `SFSpeechRecognizer.requestAuthorization` on some macOS builds) invoke
/// their completion handler more than once; a second resume of a checked continuation traps
/// (EXC_BREAKPOINT). This box drops every resume after the first.
private final class ContinuationOnce<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: sending T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

extension SpeechCapture: SpeechEngine {
    /// SFSpeechRecognizer streams interim results.
    var supportsPartialResults: Bool { true }
}
