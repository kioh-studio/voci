// Shared/Model/TourModel.swift (moved from Volar/Sources/Views/Tour 2026-10-11: `AppState` in
// Shared/ references `TourStop`, so the iOS target needs it too) — pure data model for the first-run guided coach-mark tour
// (`TourOverlay.swift`). Deliberately free of SwiftUI/AppKit imports so `TourStop.all` and its
// content can be exercised by `Tests/TourFlowTests.swift` with zero UI/store/EventKit dependencies
// — the same "pure model, tested without the view" split this codebase already uses for
// `ReminderRecord.derive`/`ReminderPolicy` (see `Sources/Reminders/Recurrence.swift`).

/// Which real, on-screen UI element a tour stop spotlights — resolved to an actual `CGRect` via
/// `TourAnchorKey`'s anchor-preference plumbing (`TourAnchor.swift`), never a hardcoded frame. Four
/// cases instead of a bare `String`/enum-per-view-file because the SAME identifier has to be
/// produced by `.tourAnchor(_:)` call sites scattered across `Sidebar.swift`/`TodayView.swift` and
/// consumed by `TourOverlay.swift` — a shared, exhaustively-checked enum is what keeps those two
/// sides from drifting apart silently (a typo'd raw string would just silently fail to resolve).
///
/// `.focusPrimary`/`.focusFallback` exist as a PAIR for the same stop (see `TourStop.all`'s "focus"
/// stop below) because the "Start focus" button `.focusPrimary` tags only renders once a task is
/// actually eligible for the NOW spotlight (`TodayView.nowSpotlight`'s `if let active =
/// appState.activeTask` branch) — a brand-new user with zero tasks, or a user whose engine has
/// nothing eligible, never renders it at all. `.focusFallback` tags the "Focus" button inside
/// `frogPill`, which DOES render in that empty/no-eligible-task state (`TodayView.frogPill` has no
/// such guard), so the tour still has something real to point at instead of silently falling back
/// to a centered, anchor-less card that would read as a UI bug rather than a deliberate choice.
enum TourAnchorID: Hashable, Sendable {
    case capture
    case taskList
    case focusPrimary
    case focusFallback
}

/// One stop in the four-stop guided tour. `Identifiable`/`Equatable`/`Sendable` so `TourOverlay`
/// can diff/animate stop transitions and `AppState.tourStop` can be read from any isolation context
/// without a warning.
struct TourStop: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let body: String
    /// The real UI element this stop spotlights. `nil` for the calendar stop — that one has no
    /// single control to ring (its own primary action, "Enable Calendar", is part of the card's
    /// body content, not a pre-existing chrome element worth highlighting), so it renders centered
    /// with no hole cut in the scrim (see `TourOverlay.cardOrigin`'s `rect == nil` branch).
    let anchor: TourAnchorID?
    /// Tried only when `anchor` fails to resolve to a real on-screen rect this run (see this type's
    /// own header comment on why the "focus" stop is the one that needs this). `nil` for every
    /// other stop — their anchors are unconditionally rendered chrome (the sidebar capture button,
    /// the main task-list column), so there is nothing for them to ever fall back from.
    let fallbackAnchor: TourAnchorID?
    /// The last stop — `TourOverlay` swaps its footer's "Next →" button for the calendar-connect
    /// actions when this is `true` (there is no fifth stop to advance to).
    let isFinal: Bool

    /// The four fixed stops, in tour order. English copy only (this app's entire UI is English —
    /// see `OnboardingView.swift`, which this tone/length matches: plain, calm, ≤2 short sentences
    /// per stop, no exclamation marks, no "!"-style hype).
    static let all: [TourStop] = [
        TourStop(
            id: "capture",
            title: "Add a task, however you like",
            body: "Click here, or press \u{2303}\u{2325}M from anywhere on your Mac — either way, Volar starts listening.",
            anchor: .capture,
            fallbackAnchor: nil,
            isFinal: false
        ),
        TourStop(
            id: "list",
            title: "Your day, sorted for you",
            body: "NOW is the one task the engine picked as most worth doing right now. NEXT, Later, and Completed hold everything else.",
            anchor: .taskList,
            fallbackAnchor: nil,
            isFinal: false
        ),
        TourStop(
            id: "focus",
            title: "One task, no distractions",
            body: "Start focus opens a fullscreen timer for 25 minutes — just that one task, with calm pause and end controls.",
            anchor: .focusPrimary,
            fallbackAnchor: .focusFallback,
            isFinal: false
        ),
        TourStop(
            id: "calendar",
            title: "See which blocks are actually free",
            body: "Volar can read your calendar to see what's already booked. If you turn on mirroring, timed tasks appear as events in a separate \"Volar\" calendar it creates — your other calendars are never touched, and it's entirely optional.",
            anchor: nil,
            fallbackAnchor: nil,
            isFinal: true
        ),
    ]
}
