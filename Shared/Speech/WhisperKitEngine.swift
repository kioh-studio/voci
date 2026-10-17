// Sources/Speech/WhisperKitEngine.swift — WhisperKit (on-device, FREE tier) batch transcription engine
import Foundation
import AVFoundation
import WhisperKit

/// On-device transcription via WhisperKit (argmaxinc, MIT — Whisper on CoreML/Neural Engine) — the
/// **free** tier of the freemium speech design (backlog "★ KIẾN TRÚC CHỐT"): private, offline,
/// no per-minute cost, in exchange for weaker accuracy than the Groq paid tier — especially on
/// Vietnamese and vi↔en code-switching, which is pushed to Groq by design (see backlog). A
/// **batch** `SpeechEngine`, structured exactly like `GroqEngine`: records the whole utterance to a
/// temp AAC file, then on `stop()` runs it through the local WhisperKit pipeline and delivers a
/// single final transcript through `onFinal`. No interim results (`supportsPartialResults == false`).
///
/// ## Model
/// Defaults to `"base"` (~145MB) rather than `"small"` (~480MB) to honor the backlog's "keep the
/// free tier light" call. `"small"` is a meaningfully better English-accuracy option if that
/// tradeoff is ever revisited — change `modelName`'s default (or pass one into `init`) to switch.
///
/// ## Hardware gate
/// WhisperKit needs Apple Silicon (Neural Engine). `isSupported` gates this at the type level so
/// `AppState` can fall back to `SpeechCapture` on Intel Macs without ever constructing a pipeline
/// that can't run. `prepare()` also self-guards and reports `.failed` on unsupported hardware, in
/// case something calls it directly.
///
/// ## Model download / readiness
/// WhisperKit's initializer downloads the named model from Hugging Face on first run and caches it
/// under Application Support — that network fetch (and subsequent CoreML compile) is what `.preparing`
/// covers. `state` is exposed so Settings can show "Downloading model…" / "Ready" / an error, and so
/// `AppState` can decide whether to route a capture to this engine or fall back to Apple's on-device
/// recognizer while the model isn't ready yet.
///
/// ## Concurrency
/// `@MainActor`, matching every other engine (`SpeechCapture`, `GroqEngine`) and the `SpeechEngine`
/// protocol itself. `session` mirrors `GroqEngine`'s token pattern to guard the async transcription
/// against a stop/restart race.
@MainActor
final class WhisperKitEngine: SpeechEngine {
    let supportsPartialResults = false
    private(set) var isRunning = false

    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    /// Whether this Mac's hardware can run WhisperKit at all (Neural Engine / Apple Silicon).
    /// `AppState` checks this before ever routing a capture here.
    static var isSupported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// The WhisperKit model identifier to load. Defaults to `"base"` — see the type-level doc
    /// comment for the `"small"` tradeoff.
    private let modelName: String

    /// Model-download/load lifecycle, surfaced to Settings (and used by `AppState` to decide
    /// whether to route captures here vs. falling back to `SpeechCapture`).
    enum State: Equatable {
        case notReady
        case preparing
        case ready
        case failed(String)
    }
    private(set) var state: State = .notReady
    var isModelReady: Bool { state == .ready }

    private var pipeline: WhisperPipelineBox?

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    /// Guards the async transcription against a stop/restart race (mirrors `GroqEngine.session` /
    /// `AppState.captureSession`).
    private var session = 0

    init(modelName: String = "base") {
        self.modelName = modelName
    }

    /// Downloads (first run only — cached after) and loads the WhisperKit model. Idempotent: a
    /// second call while `.preparing` or once `.ready` is a no-op. Call this eagerly (e.g. when the
    /// user picks WhisperKit in Settings) so the model is ready well before the next capture.
    func prepare() async {
        guard Self.isSupported else {
            state = .failed("Requires Apple Silicon")
            return
        }
        switch state {
        case .preparing, .ready:
            return
        case .notReady, .failed:
            break
        }
        state = .preparing
        do {
            // UNVERIFIED (Mac/Xcode) — confirm WhisperKitConfig(model:) and the WhisperKit(_:)
            // async-throwing initializer signature against the installed WhisperKit version;
            // this is the documented pattern as of WhisperKit 0.9.x.
            self.pipeline = try await Self.loadPipeline(modelName: modelName)
            self.state = .ready
        } catch {
            self.state = .failed(error.localizedDescription)
        }
    }

    /// WhisperKit only needs the microphone (no Speech-framework authorization, no server
    /// consent — everything stays on-device). Matches `GroqEngine`'s mic-only path.
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
            .appendingPathComponent("volar-whisper-\(UUID().uuidString).m4a")
        // 16 kHz mono AAC — matches GroqEngine's format; ideal for Whisper.
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
                onError?(NSError(domain: "Volar.WhisperKit", code: 0, userInfo: [NSLocalizedDescriptionKey: "Recorder failed to start"]))
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
            guard let box = self.pipeline else {
                if self.session == token {
                    self.onError?(NSError(domain: "Volar.WhisperKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"]))
                }
                try? FileManager.default.removeItem(at: url)
                return
            }
            do {
                let text = try await Self.runTranscription(box, audioPath: url.path)
                try? FileManager.default.removeItem(at: url)
                guard self.session == token else { return }
                if text.isEmpty {
                    self.onError?(NSError(domain: "Volar.WhisperKit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Nothing recognized"]))
                } else {
                    self.onFinal?(text)
                }
            } catch {
                try? FileManager.default.removeItem(at: url)
                guard self.session == token else { return }
                self.onError?(error)
            }
        }
    }

    /// Immediately abandons the in-flight capture: bumps `session` FIRST (so an already-running
    /// `stop()` transcription's session check above discards its result — no `onFinal`/`onError`
    /// — instead of delivering it), stops the recorder, and deletes any temp audio file still
    /// referenced (a transcription already past the recorder handoff cleans up its own copy of
    /// the file; this covers the "still recording" case where `fileURL` is still ours to delete).
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

    /// File-based transcription of a recording NOT captured by this engine's own `start()`/
    /// `stop()` cycle — added for `GroqEngine`'s cloud-403/429 fallback
    /// (`AppState.handleCloudSpeechUnavailable`), which salvages an already-recorded utterance
    /// on-device instead of discarding it when the cloud proxy reports this account can't use Groq
    /// right now. Callers MUST check `isModelReady` first (mirrors every other caller's gate on
    /// this engine); this method itself touches only `pipeline`, never `session`/`isRunning`/
    /// `recorder`, so it can run concurrently with this engine's own capture lifecycle without
    /// racing it.
    func transcribe(audioPath: String) async throws -> String {
        guard let box = pipeline else {
            throw NSError(domain: "Volar.WhisperKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }
        return try await Self.runTranscription(box, audioPath: audioPath)
    }

    /// `nonisolated` is load-bearing: `WhisperKit`'s initializer and `transcribe` are both
    /// `nonisolated async`, so the pipeline must be built and used outside the main actor's region.
    /// Returning/receiving it inside a `Sendable` box is what lets it cross to `@MainActor` storage.
    private nonisolated static func loadPipeline(modelName: String) async throws -> WhisperPipelineBox {
        WhisperPipelineBox(kit: try await WhisperKit(WhisperKitConfig(model: modelName)))
    }

    private nonisolated static func runTranscription(_ box: WhisperPipelineBox, audioPath: String) async throws -> String {
        // UNVERIFIED (Mac/Xcode) — confirm DecodingOptions' field names (`task`, `detectLanguage`)
        // and `WhisperKit.transcribe(audioPath:decodeOptions:)`'s signature/return type
        // ([TranscriptionResult]) against the installed WhisperKit version. No `language:` is
        // passed on purpose so vi/en are auto-detected.
        let options = DecodingOptions(task: .transcribe, detectLanguage: true)
        let results = try await box.kit.transcribe(audioPath: audioPath, decodeOptions: options)
        return results.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Carries the WhisperKit pipeline across isolation domains.
///
/// `WhisperKit` is a non-`Sendable` class whose `transcribe` is `nonisolated async` — it runs its
/// CoreML work off the main actor on purpose. Holding the object in `WhisperKitEngine`'s
/// `@MainActor` state and then calling `transcribe` on it hands a main-actor-isolated value to
/// another executor, which Swift 6 rejects ("Sending 'pipe' risks causing data races"). Wrapping it
/// in an `actor` does not help — an actor is just a different isolation domain with the same
/// problem. So the pipeline travels inside this `Sendable` box and is only ever *used* from a
/// `nonisolated` context, where it is a disconnected value.
///
/// The `@unchecked` is sound because of how `WhisperKitEngine` uses it, not because `WhisperKit` is
/// thread-safe: the box is written exactly once in `prepare()` and only read afterwards, and the
/// engine serializes captures (`isRunning` guards `start()`, `stop()` runs one transcription per
/// capture), so two `transcribe` calls never overlap on the same pipeline.
private struct WhisperPipelineBox: @unchecked Sendable {
    let kit: WhisperKit
}
