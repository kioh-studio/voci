// Shared/Intents/IntentBridge.swift — the seam App Intents reach the running app through.
//
// WHY THIS FILE EXISTS (and why it is this small): every App Intent in `VolarAppIntents.swift`
// needs two things — a reference to the one live `AppState`, and a way to hand text to the capture
// pipeline that returns an OUTCOME it can read back to the user. Neither existed, and neither
// belongs inside the 6000-line `AppState.swift`. Nothing here re-implements parsing, saving,
// scheduling, or syncing: `captureFromIntent` drives the exact same two properties + one method
// (`textCaptureInput` / `submitTextCapture()` / `textCapture`) that `TextCapturePanel` already
// drives, so an intent capture and a typed capture are literally the same code path.
//
// THE CONFIRM RULE, restated for headless surfaces (anh Khôi chốt 2026-08-17):
// every capture must show the user WHAT IT PARSED, through whichever channel the user is actually
// present on. On screen that is the confirm card. On Siri that is the spoken read-back this file's
// `IntentCaptureOutcome.saved(titles:)` carries. `docs/app-links.md`'s "never bypasses the confirm
// card" is unchanged for `volar://capture` — this is a different surface with a different channel,
// not an exemption.
//
// Crucially, the simple-vs-complex split this needs ALREADY EXISTS and was not invented here:
// `AppState.applyTextCaptureParseResult` (Việc 4, 2026-07-28 "chỉ đi qua confirm khi phức tạp")
// auto-saves a lone, unambiguous, condition-free draft and hands anything else to the confirm card.
// `captureFromIntent` simply reports which of the two happened, so Siri can say "added" or "needs
// your confirmation in Volar" instead of lying.
//
// UNVERIFIED: written on Windows with no Swift toolchain (see CLAUDE.md build-env note). Not
// compiled, not run. Every symbol referenced below was grepped out of the current tree first
// (`textCapture`, `textCaptureInput`, `submitTextCapture()`, `captureState`, `activeTask`,
// `frogTask`, `focusActive`, `focusSecondsLeft`, `startFocus()`), but the build must be confirmed
// on the Mac before anyone claims this works.
import Foundation

extension AppState {
    /// The one live `AppState`, published for out-of-band entry points that have no SwiftUI
    /// environment to read it from — today that is App Intents only.
    ///
    /// `weak` so this never keeps the app state alive on its own; the strong owner remains
    /// `VolarApp`'s `@State` (and `AppDelegate.appState`), exactly as before. Assigned in
    /// `VolarApp.init()` immediately after the single `AppState(store:)` is constructed — that
    /// initializer's own comment already states there is exactly one instance in the app, and this
    /// property must not become a second way to create one.
    ///
    /// `static` stored properties are permitted in extensions (unlike instance ones), which is what
    /// keeps this out of `AppState.swift` entirely.
    static weak var shared: AppState?

    /// Waits for `shared` to be populated, up to `timeout`.
    ///
    /// Needed because macOS may launch Volar in the background specifically to service an intent:
    /// in that case the intent can dispatch while `VolarApp.init()` is still running. In the far
    /// commoner case (Volar already sitting in the menu bar) this returns on the first check with
    /// no sleep at all.
    static func awaitShared(timeout: Duration = .seconds(3)) async -> AppState? {
        if let existing = shared { return existing }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try? await _Concurrency.Task.sleep(for: .milliseconds(60))
            if let existing = shared { return existing }
        }
        return nil
    }
}

/// What happened to one headless capture — the three outcomes `AppState.textCapture` can settle
/// into, translated into something an intent can speak.
enum IntentCaptureOutcome: Sendable, Equatable {
    /// The simple path: parsed, saved, done. `titles` is what actually landed in the store, so the
    /// read-back reflects the PARSE, not the user's raw sentence — which is the entire point of
    /// reading it back (a wrong date is audible here and nowhere else).
    case saved(titles: [String])
    /// The complex path: more than one task, a possible duplicate, or a condition — the confirm
    /// card is now open in Volar and the user has a real decision to make. Nothing was saved yet.
    case needsConfirmation
    /// Parse or store rejected it (e.g. a dependency cycle). `message` is the app's own wording.
    case failed(String)
}

extension AppState {
    /// Hands `raw` to the typed-capture pipeline and waits for it to settle.
    ///
    /// This is deliberately a thin driver over `submitTextCapture()` rather than a second capture
    /// implementation: parsing tier selection, the 2000-char cap, batch capping, duplicate
    /// detection, condition handling, reminder scheduling, store writes and sync notification all
    /// stay where they are. If the capture pipeline changes, this changes with it for free.
    ///
    /// Returns `.failed` rather than throwing on every user-facing failure — an intent's job is to
    /// say what happened, and "couldn't parse that" is an answer, not an exception.
    func captureFromIntent(_ raw: String, timeout: Duration = .seconds(25)) async -> IntentCaptureOutcome {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failed("Nothing to add.") }

        // A capture already in flight (the user is mid-`⌃⌥T`, or a previous intent is still
        // parsing): refuse rather than stomp on `textCaptureInput` and lose what they typed.
        let draftInProgress = textCapture == .editing && !textCaptureInput.isEmpty
        guard textCapture != .saving, !draftInProgress else {
            return .failed("Volar is already saving a capture. Try again in a moment.")
        }

        textCaptureInput = text
        submitTextCapture()

        // `submitTextCapture()` returns immediately (it spawns the parse), so poll the same state
        // property `TextCapturePanel` renders from. 60ms is well inside `finishSaveUI`'s 900ms
        // `.saved` window, so the titles are never missed.
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            switch textCapture {
            case .saved(let titles):
                return .saved(titles: titles)
            case .failed(let message):
                // Leave `textCaptureInput` populated — same courtesy the typed popup extends, so
                // the user can open Volar and fix it rather than retype from memory.
                return .failed(message)
            case .closed:
                // Two ways to land here. The complex-case branch of
                // `applyTextCaptureParseResult` sets `textCapture = .closed` AND
                // `captureState = .parsed` (confirm card now on screen). Anything else means the
                // save already completed and its 900ms banner elapsed — treat as success with no
                // titles to read back rather than inventing a failure.
                if captureState == .parsed { return .needsConfirmation }
                return .saved(titles: [])
            case .saving, .editing:
                break
            }
            try? await _Concurrency.Task.sleep(for: .milliseconds(60))
        }
        return .failed("Volar didn't finish in time.")
    }
}
