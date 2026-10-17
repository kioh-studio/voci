// Sources/Speech/GroqEngine.swift — Groq (cloud, paid tier) batch transcription engine
import Foundation
import AVFoundation

/// Cloud transcription via Groq Speech-to-Text — the paid tier of the freemium speech design
/// (backlog: on-device WhisperKit = free, Groq = paid). A **batch** `SpeechEngine`: it records the
/// whole utterance to a temp AAC file, then on `stop()` uploads it and delivers a single final
/// transcript through `onFinal`. No interim results (`supportsPartialResults == false`).
///
/// Model strategy (backlog "★ KIẾN TRÚC CHỐT"): `whisper-large-v3` primary for best vi↔en
/// code-switching; on a *server-side (5xx) or transport* failure it falls back once to
/// `whisper-large-v3-turbo` (cheaper/faster) rather than failing the capture outright. Language:
/// `languageCode` (set by `AppState` from Settings' Recognition-language picker) is forwarded as
/// Groq's ISO-639-1 `language` hint on every request; the picker's "Automatic (multilingual)"
/// choice leaves `languageCode` nil so the client sends no `language` field and Groq auto-detects
/// instead — short clips auto-detect poorly, so a fixed locale should be preferred when known.
///
/// Scope note: NOT yet wired into `AppState`/`PopoverView` (that's the tier-routing + StoreKit
/// epic). It conforms to `SpeechEngine` so the capture flow can route to it later exactly as it
/// does the on-device engine.
@MainActor
final class GroqEngine: SpeechEngine {
    /// Whether a Groq credential is available (env/UserDefaults token) — drives the pre-record
    /// fallback in `AppState.selectedEngine` and the Settings status hint, the same "configured?"
    /// gate WhisperKit expresses via `isModelReady`. `nonisolated` so it's readable from any
    /// context; it only touches the non-isolated `EnvironmentGroqCredentialProvider` static.
    nonisolated static var isConfigured: Bool { EnvironmentGroqCredentialProvider.isConfigured }

    let supportsPartialResults = false
    private(set) var isRunning = false

    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    /// Fired INSTEAD OF `onError` when the cloud proxy reports this account can't use Groq right
    /// now — `403 upgrade_required` (the cached entitlement gate in
    /// `EnvironmentGroqCredentialProvider.authorization()` was stale — a subscription lapsed, or
    /// was never Pro, discovered only server-side/mid-flight) or `429 quota_exceeded` (today's
    /// cloud speech cap hit). Per the no-shame UI rule (FR-016/FR-036, specs/002-workflow-command-
    /// center/contracts/account-auth.md) this is a ROUTING signal, not a capture failure —
    /// `AppState` never surfaces it through `.error` (see `AppState.handleCloudSpeechUnavailable`).
    ///
    /// Receives the just-recorded temp `.m4a`'s URL — still on disk at the moment this fires, since
    /// the `defer` that removes it (top of the `stop()` task below) only runs once THIS closure's
    /// `await` returns — so the receiver can attempt an on-device (WhisperKit) salvage
    /// transcription of the same utterance before the file is gone. `async` specifically so the
    /// caller can await an entitlement refresh and/or a salvage transcription before returning,
    /// keeping the temp file alive for exactly as long as that needs.
    var onCloudUnavailable: ((URL) async -> Void)?

    /// ISO-639-1 language hint (e.g. "vi", "en") forwarded to Groq on every transcription, or `nil`
    /// to let Groq auto-detect. Kept in sync with `AppState.recognitionLocaleID` by
    /// `AppState.setRecognitionLocale`/its init — the "auto" sentinel resolves to `nil` here, any
    /// specific locale resolves to its 2-letter code.
    var languageCode: String?

    private let client: GroqTranscriptionClient
    private let primaryModel: GroqModel
    private let fallbackModel: GroqModel

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    /// Guards the async upload against a stop/restart race (mirrors `AppState.captureSession`).
    private var session = 0

    init(
        client: GroqTranscriptionClient = GroqTranscriptionClient(credentials: EnvironmentGroqCredentialProvider()),
        primaryModel: GroqModel = .largeV3,
        fallbackModel: GroqModel = .largeV3Turbo
    ) {
        self.client = client
        self.primaryModel = primaryModel
        self.fallbackModel = fallbackModel
    }

    /// Groq only needs the microphone (no Speech-framework authorization). Matches
    /// `SpeechCapture`'s mic path so both engines authorize identically.
    ///
    /// Fix (2026-07-27): was `AVAudioApplication.requestRecordPermission()` — wrong, iOS-only API
    /// that never showed macOS's mic prompt at all (see `MicrophonePermission.swift`'s header for
    /// the full story). Routed through the shared helper so this and every other engine ask macOS
    /// the same, correct way.
    func requestAuthorization() async -> Bool {
        await MicrophonePermission.request()
    }

    func start(onPartial: @escaping (String) -> Void) {
        guard !isRunning else { return }
        // `onPartial` is intentionally ignored — a batch engine emits no interim results.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("volar-groq-\(UUID().uuidString).m4a")
        // 16 kHz mono AAC: ideal for Whisper, keeps the upload small.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        do {
            try RecordingAudioSession.activate()
            let rec = try AVAudioRecorder(url: url, settings: settings)
            guard rec.record() else {
                RecordingAudioSession.deactivate()
                onError?(GroqTranscriptionError.network("Recorder failed to start"))
                return
            }
            recorder = rec
            fileURL = url
            isRunning = true
            session += 1
        } catch {
            RecordingAudioSession.deactivate()
            onError?(error)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        recorder?.stop()
        recorder = nil
        RecordingAudioSession.deactivate()
        guard let url = fileURL else { return }
        fileURL = nil
        session += 1
        let token = session

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: url) }
            // A cancel() racing in between stop() and this task body running must prevent
            // the upload from ever starting, not just discard its result.
            guard self.session == token else { return }
            let audio: Data
            do {
                audio = try Data(contentsOf: url)
            } catch {
                if self.session == token { self.onError?(GroqTranscriptionError.network("Couldn't read recording")) }
                return
            }
            do {
                let text = try await self.transcribeWithFallback(audio: audio, filename: url.lastPathComponent)
                guard self.session == token else { return }
                self.onFinal?(text)
            } catch {
                guard self.session == token else { return }
                // 403 (stale entitlement) / 429 (quota) are not transcription failures — see
                // `onCloudUnavailable`'s doc comment. Everything else (network, missing creds,
                // decode, empty transcript, other HTTP statuses) is a real failure and still goes
                // through `onError` exactly as before.
                if case GroqTranscriptionError.http(let status, _) = error,
                   status == 403 || status == 429,
                   let onCloudUnavailable = self.onCloudUnavailable {
                    await onCloudUnavailable(url)
                    return
                }
                self.onError?(error)
            }
        }
    }

    /// Tries the primary (large-v3) model; on a server-side (5xx) or transport failure only, retries
    /// once with the turbo fallback. Client-side failures (missing creds, 4xx, too-large, empty,
    /// decoding) are NOT retried — a different model wouldn't help.
    private func transcribeWithFallback(audio: Data, filename: String) async throws -> String {
        do {
            return try await client.transcribe(audio: audio, filename: filename, model: primaryModel, language: languageCode)
        } catch let error as GroqTranscriptionError {
            guard Self.isRetriable(error) else { throw error }
            return try await client.transcribe(audio: audio, filename: filename, model: fallbackModel, language: languageCode)
        }
    }

    private static func isRetriable(_ error: GroqTranscriptionError) -> Bool {
        switch error {
        case .network: return true
        case .http(let status, _): return (500..<600).contains(status)
        case .missingCredentials, .audioTooLarge, .decoding, .emptyTranscript: return false
        }
    }

    /// Immediately abandons the in-flight capture. Bumps `session` FIRST — before anything else
    /// — so: (1) if `stop()` hasn't run yet, no upload ever starts for this session; (2) if an
    /// upload from `stop()` is already in flight, its session check (`guard self.session == token
    /// else { return }` above) discards the result when it resolves — none of `onFinal`, `onError`,
    /// nor `onCloudUnavailable` fires (that guard runs before the branch between them). The network
    /// request itself may still complete in the background (Groq
    /// isn't told to abort), but its transcript can never reach the app. Then stops the recorder
    /// and deletes any temp audio file still referenced (a `stop()`-started upload already
    /// captured its own copy of the file path and cleans it up itself via `defer`).
    func cancel() {
        session += 1
        isRunning = false
        recorder?.stop()
        recorder = nil
        RecordingAudioSession.deactivate()
        if let url = fileURL {
            fileURL = nil
            try? FileManager.default.removeItem(at: url)
        }
    }
}
