// Shared/Intents/VolarAppIntents.swift — the three App Intents, and the Shortcuts phrases for them.
//
// WHY APP INTENTS AND NOT N INTEGRATIONS (backlog "Đường vào Volar", anh Khôi chốt 2026-08-17):
// writing these three unlocks Shortcuts, Siri, Spotlight (macOS 14+), Focus-mode automation and —
// once the iOS target ships — the Action Button and widgets, from one API. That is the whole point:
// the user wires Volar into a workflow we never predicted, instead of us guessing ten integrations
// and shipping nine nobody uses. It is also why this file lives in `Shared/` rather than
// `Volar/Sources/` — `project.yml` compiles `../Shared` into every Apple target, so iOS inherits
// all three untouched when its turn comes. Nothing here is macOS-specific.
//
// NOTHING IN THIS FILE PARSES OR SAVES ANYTHING. Every intent goes through
// `AppState.captureFromIntent` / `startFocus()` / `activeTask` — see `IntentBridge.swift` for why
// that indirection exists and what the read-back contract is.
//
// UNVERIFIED: written on Windows with no Swift toolchain. Not compiled, not run. Build on the Mac
// before believing any of it. Specifically worth checking there: whether Shortcuts picks the
// phrases up on first launch (they are registered at app launch, and the Shortcuts app is known to
// cache aggressively — a rebuild plus a Shortcuts relaunch is usually needed to see them).
import AppIntents
import Foundation

// MARK: - Add a task

/// "Add <text> to Volar" — the capture surface for when there is no screen to look at.
@available(macOS 14.0, iOS 17.0, *)
struct AddVolarTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Task"
    static let description = IntentDescription(
        "Capture a task in Volar. It reads dates, times and priority out of the sentence, the same way typing in the app does.",
        categoryName: "Capture"
    )

    /// Volar lives in the menu bar and is normally already running, so an intent must not yank the
    /// window to the front — that is precisely the context switch this whole feature exists to
    /// avoid. If Volar is not running, macOS launches it in the background to service the intent
    /// and `AppState.awaitShared` covers the startup race.
    static let openAppWhenRun = false

    @Parameter(title: "Task", requestValueDialog: "What should I add?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let app = await AppState.awaitShared() else {
            throw VolarIntentError.notRunning
        }

        switch await app.captureFromIntent(text) {
        case .saved(let titles) where titles.isEmpty:
            // Saved, but the read-back window elapsed before we could read the titles (see
            // `captureFromIntent`). Say the true thing rather than echoing the raw sentence back
            // as if it were the parse.
            return .result(dialog: "Added to Volar.")

        case .saved(let titles):
            // THE read-back. This says what was PARSED, not what was said — a mis-read date is
            // audible right here and nowhere else on this surface.
            return .result(dialog: IntentDialog(stringLiteral: "Added: \(Self.spoken(titles: titles))"))

        case .needsConfirmation:
            // Honest by design: more than one task, a possible duplicate, or a condition — Volar
            // opened its confirm card and nothing is saved yet. Never claim otherwise.
            return .result(dialog: "That one needs your confirmation — I've opened it in Volar.")

        case .failed(let message):
            return .result(dialog: IntentDialog(stringLiteral: message))
        }
    }

    /// "A", "A and B", "A, B and C" — plus a count once the list is long enough that reading every
    /// title aloud stops being useful.
    private static func spoken(titles: [String]) -> String {
        switch titles.count {
        case 0: return ""
        case 1: return titles[0]
        case 2: return "\(titles[0]) and \(titles[1])"
        case 3: return "\(titles[0]), \(titles[1]) and \(titles[2])"
        default: return "\(titles[0]), \(titles[1]) and \(titles.count - 2) more"
        }
    }
}

// MARK: - What am I doing

/// "What am I doing?" — the same question Glance (⌃⌥N) answers on screen, answered out loud.
///
/// Reads `AppState.activeTask`, which recomputes `VolarCore.nextTask` from the live task list on
/// every access — so this can never disagree with what the app itself is showing.
@available(macOS 14.0, iOS 17.0, *)
struct WhatAmIDoingIntent: AppIntent {
    static let title: LocalizedStringResource = "What Am I Doing"
    static let description = IntentDescription(
        "Ask Volar which task is current right now.",
        categoryName: "Focus"
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let app = await AppState.awaitShared() else {
            throw VolarIntentError.notRunning
        }

        guard let task = app.activeTask else {
            let empty = app.openTasks.isEmpty
            return .result(dialog: IntentDialog(stringLiteral: empty
                ? "Nothing left today."
                : "Nothing running. Say \"start focus\" to begin the next one."))
        }

        var line = task.title
        if let deadline = task.deadline {
            line += ", due \(deadline.formatted(date: .omitted, time: .shortened))"
        }
        // Only mention the timer when a session is actually running — a minutes-left number with no
        // session behind it is noise, and this surface has room for exactly one fact.
        if app.focusActive {
            line += ". \(max(0, app.focusSecondsLeft) / 60) minutes left"
        }
        return .result(dialog: IntentDialog(stringLiteral: line))
    }
}

// MARK: - Start focus

/// "Start focus in Volar" — begins the 25-minute session on whatever the engine says is current.
@available(macOS 14.0, iOS 17.0, *)
struct StartVolarFocusIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Focus"
    static let description = IntentDescription(
        "Start a 25-minute focus session on the current task.",
        categoryName: "Focus"
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let app = await AppState.awaitShared() else {
            throw VolarIntentError.notRunning
        }
        guard !app.openTasks.isEmpty else {
            return .result(dialog: "Nothing to focus on — there are no open tasks.")
        }
        // Already running: report, don't restart. Restarting would silently throw away however many
        // minutes the user had already banked, which is the worst possible answer to "start focus".
        guard !app.focusActive else {
            let name = app.frogTask?.title ?? app.activeTask?.title ?? "your current task"
            return .result(dialog: IntentDialog(stringLiteral:
                "Already focusing on \(name), \(max(0, app.focusSecondsLeft) / 60) minutes left."))
        }

        app.startFocus()
        let name = app.frogTask?.title ?? app.activeTask?.title ?? "your current task"
        return .result(dialog: IntentDialog(stringLiteral: "Focusing on \(name) for 25 minutes."))
    }
}

// MARK: - Errors

@available(macOS 14.0, iOS 17.0, *)
enum VolarIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    /// Volar could not be reached — either it is not running and the system chose not to launch it,
    /// or launch took longer than `AppState.awaitShared`'s window.
    case notRunning

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning: return "Volar isn't running. Open it and try again."
        }
    }
}

// MARK: - Shortcuts phrases

/// Registers the spoken phrases Siri and Spotlight match against.
///
/// `\(.applicationName)` is required in every phrase by App Intents — it is what disambiguates
/// "add a task" between Volar and every other task app on the machine.
@available(macOS 14.0, iOS 17.0, *)
struct VolarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddVolarTaskIntent(),
            phrases: [
                "Add a task to \(.applicationName)",
                "New task in \(.applicationName)",
                "Capture in \(.applicationName)"
            ],
            shortTitle: "Add Task",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: WhatAmIDoingIntent(),
            phrases: [
                "What am I doing in \(.applicationName)",
                "What's my current task in \(.applicationName)",
                "Ask \(.applicationName) what I'm doing"
            ],
            shortTitle: "What Am I Doing",
            systemImageName: "eye"
        )
        AppShortcut(
            intent: StartVolarFocusIntent(),
            phrases: [
                "Start focus in \(.applicationName)",
                "Begin a focus session in \(.applicationName)"
            ],
            shortTitle: "Start Focus",
            systemImageName: "timer"
        )
    }
}
