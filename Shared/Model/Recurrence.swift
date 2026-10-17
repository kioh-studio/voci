// Sources/Model/Recurrence.swift — recurrence rule + reset-in-place engine (research.md R8),
// reminder policy, delegation metadata, and task kind. All four are persisted as JSON blobs on
// `VolarTask` (see VolarTask.swift) — this file only defines the pure value types + pure math.
import Foundation
import VolarCore

// MARK: - TaskKind

/// UI treatment only (data-model.md) — the engine has no notion of this.
enum TaskKind: String, Sendable, Equatable, Codable, CaseIterable {
    case task
    case review
}

// MARK: - Recurrence

/// Leaf-task-only schedule. `TaskStore.setRecurrence`/`add`/`addBatch` enforce "no children"
/// (validation rule 2) at the persistence boundary — this type itself is a pure value with no
/// awareness of the task graph.
enum Recurrence: Sendable, Equatable {
    case daily
    case weekly
    case monthly
    case every(days: Int)
}

extension Recurrence: Codable {
    /// Hand-rolled (rather than relying on compiler-synthesized `Codable` for an enum with
    /// associated values) so the on-disk shape is explicit, stable across app versions, and
    /// independent of any toolchain synthesis behavior — this JSON blob is what a future
    /// migration/export tool needs to read reliably.
    private enum Kind: String, Codable { case daily, weekly, monthly, every }
    private struct Wire: Codable { var kind: Kind; var days: Int? }

    init(from decoder: Decoder) throws {
        let wire = try Wire(from: decoder)
        switch wire.kind {
        case .daily: self = .daily
        case .weekly: self = .weekly
        case .monthly: self = .monthly
        case .every:
            guard let days = wire.days else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Recurrence.every is missing its `days` payload"
                )
            }
            self = .every(days: days)
        }
    }

    func encode(to encoder: Encoder) throws {
        let wire: Wire
        switch self {
        case .daily: wire = Wire(kind: .daily, days: nil)
        case .weekly: wire = Wire(kind: .weekly, days: nil)
        case .monthly: wire = Wire(kind: .monthly, days: nil)
        case .every(let days): wire = Wire(kind: .every, days: days)
        }
        try wire.encode(to: encoder)
    }
}

// MARK: - ReminderPolicy

/// NOTE ON MEMBERWISE INIT: this struct deliberately does NOT declare any initializer in its own
/// body (the `Codable` conformance below lives in a separate `extension` instead) so the compiler
/// keeps auto-synthesizing the memberwise init with `offsets`/`repeatEvery` first (in that order)
/// and the two newer fields defaulted and trailing. That's not cosmetic: `IntentParsing.swift` and
/// `NLParser.swift` (both owned by other in-flight agents, not touched by this change) call
/// `ReminderPolicy(offsets:repeatEvery:)` by keyword — moving/reordering fields or hand-writing an
/// init in the primary declaration would silently break those call sites.
struct ReminderPolicy: Sendable, Equatable {
    /// Offsets relative to the task's deadline (seconds; negative = before). Always applied on
    /// top of whatever `fractionsRemaining`/`remindPeriod` produce (see `ReminderRecord.derive`) —
    /// this is how "fire exactly at the deadline" keeps working under the new default, which
    /// carries only `[0]` here.
    var offsets: [TimeInterval]
    /// "Every 30 minutes" style repeat after the deadline; `nil` = fire once per offset only.
    var repeatEvery: TimeInterval?
    /// User-facing "remind me at the halfway point / with a third of the time left" reminders,
    /// expressed as fractions of the remaining time-to-deadline (0.5 = halfway, 1/3 = a third
    /// left, ...). Only consulted by `ReminderRecord.derive` when `remindPeriod` is `nil` — an
    /// explicit repeat cadence always wins over the proportional one. Empty = no proportional
    /// reminders (the pre-existing offsets-only behavior).
    var fractionsRemaining: [Double] = []
    /// "Nhắc mỗi X" — user-specified fixed repeat cadence counting back from the deadline
    /// (`deadline - P`, `deadline - 2P`, ...), used INSTEAD of `fractionsRemaining` when set.
    /// `nil` = no user-specified cadence; fall back to `fractionsRemaining`.
    var remindPeriod: TimeInterval?

    /// New default (anh Khôi, 2026-07-28): proportional reminders at the halfway point and with
    /// a third of the remaining time left, replacing the old fixed -1 day/-1 hour marks — plus
    /// the at-deadline offset, which is still how "fire exactly at the deadline" is expressed.
    static let defaultPolicy = ReminderPolicy(
        offsets: [0], repeatEvery: nil, fractionsRemaining: [0.5, 1.0 / 3.0], remindPeriod: nil
    )
}

extension ReminderPolicy {
    /// Preset repeat cadences (seconds) for the reminder editors.
    static let repeatPresets: [TimeInterval] = [900, 1800, 3600, 7200, 14400, 86400]

    static func repeatLabel(_ seconds: TimeInterval) -> String {
        switch seconds {
        case 900: return "15m"
        case 1800: return "30m"
        case 3600: return "1h"
        case 7200: return "2h"
        case 14400: return "4h"
        case 86400: return "1 day"
        default: return "\(Int(seconds / 60))m"
        }
    }
}

extension ReminderPolicy: Codable {
    private enum CodingKeys: String, CodingKey {
        case offsets, repeatEvery, fractionsRemaining, remindPeriod
    }

    /// Hand-written (rather than compiler-synthesized) so a JSON blob persisted by an OLDER build
    /// — which only ever wrote `offsets`/`repeatEvery`, see `AppState.setGlobalReminderPolicy` —
    /// still decodes successfully after this update. `AppState`'s own load path wraps this in
    /// `try?` and falls back to `.defaultPolicy` on ANY decode failure, so a naive
    /// compiler-synthesized `Codable` (which would require the two new keys to be present) would
    /// silently wipe out every user's already-saved global reminder policy the first time this
    /// build ran, without ever crashing or logging anything — `decodeIfPresent` + a default is
    /// what avoids that.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        offsets = try container.decode([TimeInterval].self, forKey: .offsets)
        repeatEvery = try container.decodeIfPresent(TimeInterval.self, forKey: .repeatEvery)
        fractionsRemaining = try container.decodeIfPresent([Double].self, forKey: .fractionsRemaining) ?? []
        remindPeriod = try container.decodeIfPresent(TimeInterval.self, forKey: .remindPeriod)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(offsets, forKey: .offsets)
        try container.encodeIfPresent(repeatEvery, forKey: .repeatEvery)
        try container.encode(fractionsRemaining, forKey: .fractionsRemaining)
        try container.encodeIfPresent(remindPeriod, forKey: .remindPeriod)
    }
}

// MARK: - DelegationMeta

/// TÀN DƯ (2026-08-22): tính năng delegation đã bỏ khỏi app — không còn chỗ nào GHI vào field này
/// nữa, nên thực tế nó luôn `nil` với dữ liệu mới. Struct và field `TaskItem.delegation` cố ý GIỮ
/// LẠI: chúng nằm trong schema SwiftData (`VolarTask.delegationData`) và trong `SyncPayload` — xoá
/// đi là một lần migration store cộng một lần đổi contract sync, mà hai bản Windows/iOS vẫn đang
/// đọc/ghi field này. Dọn khi cả ba bản cùng bỏ; tới lúc đó nó chỉ tốn một cột JSON luôn rỗng.
///
/// Present on a task while delegated-to-AI (US4). Lifecycle owned by the (later) orchestrator
/// layer — this file only defines the persisted shape.
struct DelegationMeta: Sendable, Equatable, Codable {
    var label: String
    var checkBackAt: Date
    /// 0 -> 10', 1 -> 30', >=2 -> batch-only (research.md R9).
    var backoffStage: Int
    var cwdHint: String?
    var delegatedAt: Date
}

// MARK: - Recurrence reset-in-place engine (research.md R8)

/// Pure recurrence math: every function takes an explicit `Calendar` and does all date math via
/// `Calendar` components (never bare `Date`/`TimeInterval` arithmetic), so DST transitions and
/// variable month lengths are resolved by the OS calendar rather than assumed by this code.
enum RecurrenceEngine {
    /// The date one occurrence of `rule` after `anchor`.
    ///
    /// // UNVERIFIED: confirm on Mac that `Calendar.date(byAdding: .month, ...)` CLAMPS an
    /// invalid day-of-month to the last valid day (Jan 31 + 1 month -> Feb 28, and Feb 29 in a
    /// leap year + 1 month -> Mar 29) rather than rolling over into the following month, and that
    /// `.day`/`.weekOfYear` addition across a DST spring-forward gap resolves to a valid
    /// wall-clock instant instead of producing `nil` or an off-by-one-hour result.
    static func advance(_ anchor: Date, by rule: Recurrence, calendar: Calendar) -> Date? {
        switch rule {
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: anchor)
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: anchor)
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: anchor)
        case .every(let days):
            // Malformed rule guard: never produced by a valid parse/UI path, but a corrupted
            // store could contain `every(days: 0)` or negative — treat as "can't advance" rather
            // than silently looping the caller or producing a date in the past.
            guard days > 0 else { return nil }
            return calendar.date(byAdding: .day, value: days, to: anchor)
        }
    }

    /// The persisted fields a reset touches — deliberately narrow (not the whole `VolarTask`) so
    /// this stays a pure function that's trivially unit-testable without SwiftData.
    struct Reset: Sendable, Equatable {
        var deadline: Date?
        var conditions: [VolarCore.Condition]
    }

    /// Completion -> reset-in-place: reopen at the next occurrence. Schedule-anchored by default
    /// (weekly-Monday stays Monday no matter which weekday it was actually completed).
    /// `.afterDate` conditions shift by the same rule,
    /// each from its own prior date; `.external` conditions reset to unsatisfied (a fresh cycle
    /// re-waits on whatever it was waiting on); `.taskDone` conditions are left untouched — a
    /// recurring task's cross-task prerequisites don't reset with its own schedule.
    static func reset(
        recurrence: Recurrence,
        deadline: Date?,
        conditions: [VolarCore.Condition],
        completedAt: Date,
        calendar: Calendar
    ) -> Reset {
        // FIX E: a single `advance(anchor, ...)` call only moves ONE period past the old
        // deadline/condition date. Completing a recurring task more than one period late (e.g. a
        // daily task completed after 5 days away) then reopened it with a deadline that's still
        // in the past, which immediately re-fires as overdue — a burst of instantly-overdue
        // notifications on the very next `rebuildFromStorage`/derive. Loop the advance until the
        // new date is strictly after `completedAt`, so the reopened task's next occurrence is
        // always actually in the future. `maxIterations` is a defensive backstop (mirrors
        // `advance`'s own defensive-guard philosophy above) against a pathological/corrupted rule
        // that would otherwise spin — e.g. `advance` returning the same instant it was given.
        func nextOccurrence(from original: Date) -> Date {
            var candidate = original
            var iterations = 0
            let maxIterations = 1000
            // Advance at least once (a task completed EARLY has original > completedAt and must
            // still move to the next cycle), then keep going until strictly after `completedAt`.
            while iterations == 0 || (candidate <= completedAt && iterations < maxIterations) {
                // If advancing ever fails (defensive — see `advance`'s doc comment), stop and fall
                // back to the last good candidate rather than producing `nil`/crashing; a
                // stuck-in-place recurring task is a visible, recoverable bug, not a crash.
                guard let advanced = advance(candidate, by: recurrence, calendar: calendar) else { break }
                candidate = advanced
                iterations += 1
            }
            return candidate
        }

        let nextDeadline: Date?
        if let deadline {
            nextDeadline = nextOccurrence(from: deadline)
        } else {
            // No prior schedule to anchor to — stays undated; only its
            // `.afterDate`/`.external` conditions (if any) gate the next cycle.
            nextDeadline = nil
        }

        let nextConditions = conditions.map { condition -> VolarCore.Condition in
            switch condition {
            case .afterDate(let date):
                return .afterDate(nextOccurrence(from: date))
            case .external(let description, _):
                return .external(description: description, satisfied: false)
            case .taskDone:
                return condition
            }
        }

        return Reset(deadline: nextDeadline, conditions: nextConditions)
    }
}
