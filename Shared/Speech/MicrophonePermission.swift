// Sources/Speech/MicrophonePermission.swift — the ONE place that asks macOS for microphone access
//
// WHY THIS FILE EXISTS: `SpeechCapture`, `GroqEngine`, and `WhisperKitEngine` each used to call
// `AVAudioApplication.requestRecordPermission()` directly. `AVAudioApplication` is an iOS 17+ /
// Mac Catalyst API — on native macOS it is NOT the API that drives the microphone TCC prompt, so
// calling it there silently does nothing: it returns without ever showing the system "Volar would
// like to access the microphone" sheet. The correct native-macOS API is `AVCaptureDevice` (also
// AVFoundation, just a different type): `authorizationStatus(for: .audio)` to read the cached
// decision, and `requestAccess(for: .audio)` to actually trigger the one-time TCC prompt.
//
// Do NOT read this as "the old code never prompted at all" — on the first real-Mac run a mic sheet
// DID appear, because macOS also prompts on its own the moment an app actually touches the input
// hardware (`AVAudioEngine`'s input tap in `SpeechCapture`, `AVAudioRecorder.record()` in
// `GroqEngine`). What the old code could not do is prompt DELIBERATELY, up front, before capture —
// or report a trustworthy answer, which is what `SpeechCapture.requestAuthorization()`'s `guard`
// and Settings ▸ Permissions both depend on. That is what this file fixes.
//
// Centralized here (rather than fixed inline at each of the 3 call sites) so there is exactly one
// place that knows which AVFoundation type is the real macOS entry point — the next engine added
// to this app should never have a chance to reintroduce the `AVAudioApplication` mistake.
import AVFoundation

enum MicrophonePermission {
    /// The OS's cached decision, read without prompting. Safe to call any time (e.g. Settings'
    /// Permissions tab, re-read on every appearance).
    static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Triggers the system microphone prompt and returns whether access is granted.
    ///
    /// IMPORTANT — TCC only ever asks once: if `status` is already `.denied` or `.restricted`,
    /// `requestAccess(for:)` returns `false` IMMEDIATELY and macOS does NOT show the prompt again
    /// — there is no API to re-arm it. Once a user has answered (or the request was made on their
    /// behalf and refused) that answer is permanent from the app's side; the only way back is the
    /// user manually flipping the toggle in System Settings ▸ Privacy & Security ▸ Microphone.
    /// This is exactly the confusion Việc 3 (Settings ▸ Permissions tab) exists to resolve: once
    /// denied, this method can never fix it — the UI has to hand off to System Settings instead.
    static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

/// iOS needs an active record-capable `AVAudioSession` or the mic returns silence with no error;
/// macOS has no such session, so both calls are no-ops there. Shared by every recording engine.
enum RecordingAudioSession {
    static func activate() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true)
        #endif
    }

    /// Best-effort: a deactivate failure is not a capture error.
    static func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
