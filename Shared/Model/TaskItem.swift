// Sources/Model/TaskItem.swift — UI/domain task model + mapping into VolarCore.Task (v2 shape,
// contracts/volarcore-api.md). See VolarTask.swift for the paired SwiftData persistence model.
import Foundation
import VolarCore

/// Alias so app code (and Phase-2 views) can write `TaskStatus` without importing `VolarCore`
/// everywhere — the lifecycle enum itself lives in the engine package and is not redefined here.
typealias TaskStatus = VolarCore.TaskStatus

/// UI-facing priority, 1 (highest) ... 3 (lowest). Maps 1:1 onto `VolarCore.Task.priority`'s
/// `Int` scale via `rawValue` (the engine additionally allows 4 / `nil`; this app never produces
/// those, so the UI enum only needs high/medium/low).
enum Priority: Int, Sendable, Equatable, CaseIterable, Codable {
    case high = 1
    case medium = 2
    case low = 3
}

/// UI-only "Now" vs "Later today" bucket. The engine has no notion of this; it is purely how
/// `TodayView` (Phase 2) groups the list, mirroring the prototype's `task.when`.
enum When: Sendable, Equatable, Codable {
    case now
    case later
}

/// specs/010-calendar-and-hard-deadlines/design.md §3.1/§3.5 — whether `deadline` is a mark the
/// user can freely move (`.soft`) or one an outside party enforces with a real consequence
/// (`.hard`, e.g. a tax filing). v1 is manual-toggle only, never inferred from the utterance
/// (§3.5: guessing "does this have legal consequence" from words is exactly the wrong kind of
/// silent-failure guess). Deliberately UI-facing only — see `TaskItem.deadlineKind` for why this
/// never reaches `VolarCore.Task`.
enum DeadlineKind: String, Sendable, Equatable, CaseIterable {
    case soft   // mốc tự đặt — đẩy được, không ai phạt
    case hard   // mốc bên ngoài áp, có chế tài — app không đẩy được
}

struct TaskItem: Identifiable, Sendable, Equatable {
    let id: UUID
    var title: String
    var details: String
    var priority: Priority
    var status: TaskStatus
    /// The moment this task must be DONE by — drives ordering tier 2 of `VolarCore.nextTask` (see
    /// `NextTask.swift`) and the reminder subsystem. Contrast with `startTime` immediately below,
    /// which is a different instant entirely.
    var deadline: Date?
    /// specs/010-calendar-and-hard-deadlines/design.md §3.1 — `.soft` (default) vs `.hard`.
    /// Meaningless when `deadline == nil`; deliberately NOT validated/normalized back to `.soft`
    /// in that case (no throw, no silent coercion) — every read site that cares must already be
    /// gating on `deadline` being non-nil first, same as `timeBadge` below does.
    var deadlineKind: DeadlineKind = .soft
    /// The moment the user said they'd START working — set from an urgent utterance ("làm ngay
    /// lập tức" / "right now"), where `startTime` = the instant the utterance was spoken.
    /// Deliberately inert: it does NOT drive ordering, eligibility, or reminders (those all stay
    /// on `deadline`/`conditions` exactly as before). An urgent task "jumps the queue" because its
    /// PARSER-DERIVED `deadline` (typically `startTime + 30min`) lands in today's near-term tier,
    /// not because of this field — this is carried purely as data for anything downstream that
    /// wants to show/reason about "when did they mean to start". `nil` for every task that wasn't
    /// created from an urgent utterance.
    var startTime: Date?
    /// Gates eligibility (replaces v1's `dependsOn: [UUID]` — data-model.md "Persisted layer").
    /// AND semantics, mirrors `VolarCore.Task.conditions` 1:1 (see `snapshot()`). `.taskDone`
    /// edges must be validated via `TaskStore` before being attached (validation rule 1); this
    /// struct itself carries no validation, matching `VolarCore.Condition`'s own pure-value
    /// nature — see `TaskStore`'s doc comments for the trust-boundary note.
    var conditions: [VolarCore.Condition]
    var createdAt: Date
    var when: When
    var durationMinutes: Int?
    var frog: Bool

    // MARK: - v2 fields (specs/002-workflow-command-center/data-model.md "Persisted layer")

    /// Free-text notes, distinct from `details` (which stays the voice-capture read-back copy
    /// spoken by `AppState.speakDetails`).
    var notes: String?
    /// Verbatim utterance for voice-created tasks — always kept (FR-001).
    var sourceTranscript: String?
    var kind: TaskKind
    /// Leaf tasks only — `TaskStore.setRecurrence`/`add`/`addBatch` reject setting this on a task
    /// that has children (validation rule 2).
    var recurrence: Recurrence?
    /// `nil` -> global default `ReminderPolicy.defaultPolicy`.
    var reminderOverride: ReminderPolicy?
    /// "Save game" note surfaced on re-entry (FR-042).
    var resumeNote: String?
    /// Implementation-intention cue (specs/006-cues-and-waiting/design.md §2 Việc B) — the user's
    /// own if-then utterance ("ngủ dậy thì test feature này"), read back verbatim at the right
    /// moment. SURFACING ONLY (design.md §1): this field never gates eligibility and is not a
    /// `VolarCore.Condition` — a task with a cue is eligible exactly as if it had none. See
    /// `Reminders/CueFiring.swift` for the pure decision logic that reads it.
    var cue: TaskCue?
    /// Đổi-gió counter; ≥3 triggers a one-time breakdown suggestion (FR-030).
    var switchAwayCount: Int
    /// Latest completion instant; full history lives in `CompletionEvent` — recurrence resets
    /// in place, so this field alone can't reconstruct history.
    var completedAt: Date?
    /// Breakdown child -> parent link. Engine rule: a task that is a parent of any open child is
    /// excluded from `nextTask`, even though it stays selectable in its own right once every
    /// child is done/archived.
    var parentId: UUID?
    /// Present while delegated-to-AI (US4); cleared once the matching `.external` condition is
    /// satisfied (signal or manual).
    var delegation: DelegationMeta?

    init(
        id: UUID = UUID(),
        title: String,
        details: String = "",
        priority: Priority,
        status: TaskStatus = .todo,
        deadline: Date? = nil,
        deadlineKind: DeadlineKind = .soft,
        startTime: Date? = nil,
        conditions: [VolarCore.Condition] = [],
        createdAt: Date = Date(),
        when: When,
        durationMinutes: Int? = nil,
        frog: Bool = false,
        notes: String? = nil,
        sourceTranscript: String? = nil,
        kind: TaskKind = .task,
        recurrence: Recurrence? = nil,
        reminderOverride: ReminderPolicy? = nil,
        resumeNote: String? = nil,
        switchAwayCount: Int = 0,
        completedAt: Date? = nil,
        parentId: UUID? = nil,
        delegation: DelegationMeta? = nil,
        cue: TaskCue? = nil
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.priority = priority
        self.status = status
        self.deadline = deadline
        self.deadlineKind = deadlineKind
        self.startTime = startTime
        self.conditions = conditions
        self.createdAt = createdAt
        self.when = when
        self.durationMinutes = durationMinutes
        self.frog = frog
        self.notes = notes
        self.sourceTranscript = sourceTranscript
        self.kind = kind
        self.recurrence = recurrence
        self.reminderOverride = reminderOverride
        self.resumeNote = resumeNote
        self.switchAwayCount = switchAwayCount
        self.completedAt = completedAt
        self.parentId = parentId
        self.delegation = delegation
        self.cue = cue
    }

    /// Derived: "done" is purely the engine status, never a separately stored bool.
    var done: Bool { status == .done }

    /// Derived: formatted deadline time ("11:30 AM"); `nil` once done or when there's no
    /// deadline at all — matches the prototype's `timeBadge` (only ever shown for open tasks).
    var timeBadge: String? {
        guard !done, let deadline else { return nil }
        return deadline.formatted(.dateTime.hour().minute())
    }

    /// Derived: "45 min" / "1 hr" / "1h 30m" — matches the prototype's `dur` label.
    var durationLabel: String? {
        guard let durationMinutes, durationMinutes > 0 else { return nil }
        return Self.durationLabel(minutes: durationMinutes)
    }

    /// "45 min", "1 hr", "1h 30m" — shared by every view that shows a duration.
    static func durationLabel(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 { return hours == 1 ? "1 hr" : "\(hours) hrs" }
        return "\(hours)h \(remainder)m"
    }

    /// Duration menu presets (minutes).
    static let durationPresetMinutes: [Int] = [5, 10, 15, 30, 45, 60, 90, 120, 180, 240]

    /// The only bridge into the pure selection engine (contracts/volarcore-api.md): maps this UI
    /// struct into the small value type `nextTask(from:now:calendar:)` actually consumes. No selection
    /// logic is duplicated here. `durationMinutes` feeds the engine's `estimateMinutes` — same
    /// concept, kept under its existing UI-facing name here (see TaskStore migration notes for
    /// why the persisted attribute name wasn't renamed to match).
    func snapshot() -> VolarCore.Task {
        VolarCore.Task(
            id: id,
            title: title,
            status: status,
            priority: priority.rawValue,
            deadline: deadline,
            conditions: conditions,
            estimateMinutes: durationMinutes,
            parentId: parentId,
            createdAt: createdAt
        )
    }
}
