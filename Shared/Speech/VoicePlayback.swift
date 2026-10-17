// Sources/Speech/VoicePlayback.swift — AVSpeechSynthesizer wrapper (readDay, voice feedback)
import AVFoundation

/// Wraps `AVSpeechSynthesizer` for spoken feedback — mirrors `volarSpeak`/`volarStopSpeak` in
/// `volar-ambient.jsx` plus the `readDay` behavior from `volar-mac.jsx`.
@MainActor
final class VoicePlayback {
    private let synthesizer = AVSpeechSynthesizer()

    /// `volarSpeak(text)`. The JS prototype sets `utterance.rate = 1.03` against the Web Speech
    /// API's "1.0 is normal" scale. `AVSpeechUtterance.rate` instead uses a 0...1 scale where
    /// `AVSpeechUtteranceDefaultSpeechRate` (~0.5) is "normal" — so rather than reusing `1.03` as
    /// an absolute value (which would read as near-fastest on this scale), this carries over the
    /// prototype's *relative* +3% bump on top of the natural default rate.
    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        #if os(iOS)
        activateSpeechSession()
        #endif
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.03
        utterance.pitchMultiplier = 1.0
        synthesizer.speak(utterance)
    }

    #if os(iOS)
    /// Activates a playback-capable `AVAudioSession` for spoken feedback (Focus mode
    /// announcements, `readDay`, the reminder voice channel) — consistent with `SpeechCapture`'s
    /// `.playAndRecord` session (T3/R1, plan.md §8), and deliberately non-destructive toward it:
    /// if `SpeechCapture` already has `.playAndRecord` active (mid-capture), that category
    /// already supports playback, so this leaves it alone rather than swapping in `.playback` and
    /// interrupting the live mic tap. Best-effort: a failure here isn't worth surfacing through
    /// this wrapper's frozen error-free API — logged only, same convention as `SpeechCapture`'s
    /// deactivation path.
    /// // UNVERIFIED: `AVAudioSession.Category` equality/`.category` readback — not exercised on
    /// device. Also NOTE (dead-code-adjacent, flagged in this task's self-review): this file has
    /// no `AVSpeechSynthesizerDelegate` wired up, so there is no completion hook to deactivate the
    /// session again once speech finishes — out of scope for this minimal wrapper; left as-is.
    private func activateSpeechSession() {
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playAndRecord else { return }
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            // best-effort: speech simply plays on the current session
        }
    }
    #endif

    /// `volarStopSpeak()`.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Mirrors `volar-mac.jsx`'s `readDay`: announces the open-task count and up to the first 3
    /// titles, or "All clear" when there is nothing open.
    ///
    /// NOTE: `AppState.readDayAloud()` (`Sources/App/AppState.swift`) is currently an empty stub.
    /// Per the Phase-2 brief, wiring it up is Phase-3 work: the app-assembly step should give
    /// `AppState` (or its owner) a `VoicePlayback` instance and have `readDayAloud()` call
    /// `voicePlayback.readDay(self)`. Not done here so this file doesn't reach into `AppState`'s
    /// frozen §4 stored-property list.
    func readDay(_ appState: AppState) {
        let open = appState.openTasks
        guard !open.isEmpty else {
            speak("All clear. Nothing scheduled.")
            return
        }
        let upNext = open.prefix(3).map(\.title).joined(separator: ", ")
        let taskWord = open.count == 1 ? "task" : "tasks"
        speak("You have \(open.count) open \(taskWord). Up next: \(upNext).")
    }
}
