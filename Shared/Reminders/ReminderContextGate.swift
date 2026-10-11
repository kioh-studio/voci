// Sources/Reminders/ReminderContextGate.swift — voice-suppression gate (contract §B, T072).
// Constitution I / the contract's explicit instruction: "fail toward SUPPRESSED when unsure."
// Every concrete signal below either (a) produces a definite true/false from a public,
// no-extra-entitlement API, or (b) is an injectable extension point that defaults to "no signal"
// (not suppressing on that axis alone) until something wires it — see the doc comment on each
// property for exactly which is which, and this task's final report for what's left unwired.
import Foundation
import AVFoundation

@MainActor
final class ReminderContextGate {
    /// Calendar-busy windows. Injected by the caller — `[]` until Phase 3's calendar integration
    /// lands (contract §B says so explicitly: "busyIntervals injected — [] until P3"). A `now`
    /// inside any interval here suppresses voice.
    var busyIntervals: [DateInterval] = []

    // MARK: - Extension points
    //
    // These four cover signals this gate has no live-instance access to from its own files (mic
    // capture belongs to `Sources/Speech/SpeechCapture.swift`, owned elsewhere; screen-sharing and
    // Focus/DND have no stable, unprivileged public API on macOS as of this SDK — Focus status
    // specifically requires the restricted `com.apple.developer.focus-status` entitlement via
    // `INFocusStatusCenter`, which this task deliberately does NOT add speculatively to
    // `Resources/Volar.entitlements`, since that entitlement needs Apple approval and this is a
    // MAS-first app — research.md R3). `nil` means "not wired yet" and reads as "no signal" for
    // that one axis; once wired (by whichever agent owns the live instance/API), a `true` from any
    // of these suppresses voice same as a concrete check would.
    var isLocalMicCaptureActive: (() -> Bool)?
    var isOtherAudioPlaying: (() -> Bool)?
    var isScreenBeingShared: (() -> Bool)?
    var isDoNotDisturbOn: (() -> Bool)?

    init() {}

    /// `true` suppresses the voice rung for this fire (visual delivery is unaffected either way —
    /// this gate only ever guards `VoiceReminderChannel`, never `UNUserNotificationCenter`).
    func shouldSuppressVoice(now: Date) -> Bool {
        if busyIntervals.contains(where: { $0.contains(now) }) { return true }
        if isLocalMicCaptureActive?() == true { return true }
        if isOtherAudioPlaying?() == true { return true }
        if isScreenBeingShared?() == true { return true }
        if isDoNotDisturbOn?() == true { return true }
        if isAnotherAppUsingMicrophone() { return true }
        return false
    }

    /// Best-effort "a call is likely active" signal with NO extra entitlement and NO permission
    /// prompt of its own: `AVCaptureDevice.isInUseByAnotherApplication` is a standard AVFoundation
    /// capture-device property that apps use to detect camera/mic contention (e.g. before grabbing
    /// the mic themselves) — reading it does not itself request microphone access. Fails toward
    /// suppressed: any state other than a definite "no device / not in use" suppresses.
    private func isAnotherAppUsingMicrophone() -> Bool {
        #if os(macOS)
        guard let device = AVCaptureDevice.default(for: .audio) else {
            // No audio input device at all — nothing else could plausibly be "on a call" via it.
            return false
        }
        return device.isInUseByAnotherApplication
        #else
        // `isInUseByAnotherApplication` is macOS-only. iOS manages call/mic contention itself
        // (notifications are already muted during calls by the system), so nothing to suppress here.
        return false
        #endif
    }
}
