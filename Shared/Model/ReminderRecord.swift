// Sources/Model/ReminderRecord.swift — one persisted reminder intent for a task
// (specs/002-workflow-command-center/contracts/phase4-contract.md §A). `ReminderScheduler`
// (Sources/Reminders/ReminderScheduler.swift) is the only reader/writer of this model; this file
// defines just the persisted shape plus the pure derivation math, so both the shape and the
// escalation/offset logic stay unit-testable without a live `ModelContext`
// (Tests/ReminderSchedulerTests.swift exercises `derive` directly).
import Foundation
import SwiftData

/// Durable record of one reminder fire-time for one task. Constitution IV: the scheduler's entire
/// heap is rebuilt from rows of this type on every launch/wake — nothing about "what should fire
/// when" is allowed to live only in memory.
@Model
final class ReminderRecord {
    @Attribute(.unique) var id: UUID
    var taskId: UUID
    var fireAt: Date
    /// One of the contract's frozen kinds: "-1d" / "-1h" / "at" / "override" / "resurface" /
    /// "unblocked" / "nudge". "-1d"/"-1h"/"at" are the three standard `ReminderPolicy.offsets`
    /// values (the current global `ReminderPolicy.defaultPolicy` only ever carries `[0]` -> "at",
    /// but a custom policy/override can still carry -1d/-1h); "override" is any `offsets` value
    /// that doesn't match one of those three, AND every deadline-anchored mark
    /// `ReminderRecord.derive` generates from `fractionsRemaining`/`remindPeriod` (see that
    /// function's doc comment); "resurface" covers both `scheduleResurface` (FR-017) and
    /// `offerReschedule` (FR-016) — see `NotificationActions.category(forOffsetKind:)` for how the
    /// two are told apart at delivery time; "unblocked" is `notifyUnblocked` (FR-015); "nudge" is
    /// every mark `ReminderRecord.derive` generates for a task with NO deadline (anh Khôi's
    /// gentle-backoff nudges — see `noDeadlineMarks`'s doc comment). Any kind string not matched
    /// by a specific `switch` case anywhere it's read (`NotificationActions.category(forOffsetKind:)`,
    /// `ReminderScheduler.timingPhrase(offsetKind:)`) falls to that switch's own safe `default`,
    /// which was verified for "nudge" when it was introduced (see this task's final report).
    var offsetKind: String
    /// "scheduled" (durable, not yet fired) / "delivered" (visual shown, awaiting acknowledgment)
    /// / "satisfied" (suppressed-as-done, or resolved by a user action).
    var state: String
    /// Drives the voice escalation rung (contract §A): true for at-or-after-deadline offsets, so
    /// a plain "-1d"/"-1h" heads-up stays visual-only unless a PRIOR visual for the same task went
    /// unacknowledged (see `ReminderScheduler.evaluate`).
    var isHighUrgency: Bool

    init(
        id: UUID = UUID(),
        taskId: UUID,
        fireAt: Date,
        offsetKind: String,
        state: String = "scheduled",
        isHighUrgency: Bool = false
    ) {
        self.id = id
        self.taskId = taskId
        self.fireAt = fireAt
        self.offsetKind = offsetKind
        self.state = state
        self.isHighUrgency = isHighUrgency
    }
}

// MARK: - Derivation (pure — no I/O, no `ModelContext`, no clock reads)

extension ReminderRecord {
    /// Labels a raw policy offset with its contract-frozen kind string. Any offset that isn't one
    /// of the three global-policy standard values is necessarily a custom per-task override.
    private static func offsetKind(for offset: TimeInterval) -> String {
        switch offset {
        case -86400: return "-1d"
        case -3600: return "-1h"
        case 0: return "at"
        default: return "override"
        }
    }

    /// Floor for proportional/period reminders: never fire more than 1 day ahead of the deadline
    /// (anh Khôi's approved boundary — a 30-day task's "halfway" mark clamps to "1 day before",
    /// it doesn't fire 15 days early). Plain `TimeInterval` arithmetic (not `Calendar`) is
    /// deliberate here: this is a "how far from this instant" cutoff, not a calendar-wall-clock
    /// concept like "the same time tomorrow" — DST/month-length don't enter into it, so borrowing
    /// `RecurrenceEngine`'s `Calendar`-based philosophy would add complexity without changing the
    /// answer.
    private static let reminderFloorInterval: TimeInterval = 86400
    /// Minimum spacing between any two kept reminders for one task (anh Khôi's approved boundary).
    private static let reminderMinimumGap: TimeInterval = 600
    /// Hard cap on before-deadline reminders per task. Not something anh Khôi asked for directly —
    /// added because `UNUserNotificationCenter` only holds ~64 pending local notifications for the
    /// WHOLE app (`ReminderScheduler.systemRequestCap`), and an uncapped `remindPeriod` (e.g. "every
    /// 5 minutes" on a 1-day task = 288 marks) from a SINGLE task would blow through that budget by
    /// itself. Keeps the marks nearest the deadline, since those are the most useful/urgent ones.
    ///
    /// Reused verbatim (not a second constant) for the no-deadline "nudge" backoff below
    /// (`noDeadlineMarks`) — same underlying reason (the shared system pending-notification
    /// budget) applies just as much to a never-ending backoff/repeat sequence as it does to an
    /// uncapped `remindPeriod`.
    private static let maxBeforeDeadlineMarks = 8

    /// Backoff offsets (seconds from `createdAt`) for a no-deadline task flagged `priority == 1`
    /// (anh Khôi's approved schedule): 1h, 3h, 7h, 14h, 24h, 72h.
    private static let noDeadlineHighPriorityOffsets: [TimeInterval] = [3600, 10_800, 25_200, 50_400, 86_400, 259_200]
    /// Same backoff with the two most eager marks (1h/3h) dropped — used for every OTHER priority,
    /// INCLUDING `nil` (unset)/2/3/4. anh Khôi: a task nobody flagged urgent doesn't need
    /// pestering within the hour.
    private static let noDeadlineDefaultOffsets: [TimeInterval] = [25_200, 50_400, 86_400, 259_200]
    /// Once either backoff list above is exhausted, the nudge repeats forever at this cadence
    /// (anh Khôi: "lặp mãi mỗi 3 ngày"). See `noDeadlineMarks` for how a literally-unbounded
    /// repeat is turned into a finite, still-correct candidate list.
    private static let noDeadlineRepeatInterval: TimeInterval = 259_200
    /// Safety backstop for the step-walking loops in `noDeadlineMarks` — mirrors the existing
    /// `remindPeriod` walk-back loop's own `k > 10_000` guard further down this file. Protects
    /// against a pathological input (e.g. a `createdAt` decades in the past, or a tiny
    /// user-specified `remindPeriod`) spinning far longer than needed to collect
    /// `maxBeforeDeadlineMarks` marks, without changing the answer for any realistic input.
    private static let derivationStepBudget = 10_000

    /// One in-progress fire-time candidate, tagged with how the 1-day floor should treat it.
    private struct Mark {
        var date: Date
        var offsetKind: String
        var isHighUrgency: Bool
        var boundaryBehavior: BoundaryBehavior

        func makeRecord(taskId: UUID) -> ReminderRecord {
            ReminderRecord(taskId: taskId, fireAt: date, offsetKind: offsetKind, isHighUrgency: isHighUrgency)
        }
    }

    /// `.drop`: a mark earlier than the 1-day floor is discarded outright (fixed `offsets` marks,
    /// and `remindPeriod` marks — the latter never even generates one past the floor, see below).
    /// `.clampToFloor`: a mark earlier than the floor is pulled IN to sit exactly at the floor
    /// instead of vanishing — reserved for `fractionsRemaining` marks per anh Khôi's approved
    /// example (a 30-day task's halfway mark becomes "1 day before", not "gone").
    private enum BoundaryBehavior {
        case drop
        case clampToFloor
    }

    /// One `ReminderRecord` per offset in `reminderOverride ?? globalPolicy`, PLUS whatever
    /// proportional/periodic marks that policy's `fractionsRemaining`/`remindPeriod` produce,
    /// anchored to `deadline`. When `deadline == nil`, this switches to an entirely different,
    /// deadline-independent "gentle nudge" backoff anchored to `createdAt` instead — see
    /// `noDeadlineMarks` below for that branch's full doc comment. `policy`/`globalPolicy`
    /// (`offsets`/`fractionsRemaining`/`remindPeriod` computed from a deadline) never apply there;
    /// only `reminderOverride?.remindPeriod` is consulted, as an explicit user-specified cadence.
    ///
    /// Pure: deterministic for identical inputs — `now` (and, for the no-deadline branch,
    /// `createdAt`) is a parameter, never read from the wall clock internally, so this stays
    /// trivially testable. Fire times can still land in the past for an already-overdue deadline
    /// (`deadline <= now`); the scheduler's recovery path, not this function, decides what to do
    /// about that (see `ReminderScheduler.rebuildFromStorage`). When overdue, this function
    /// deliberately skips ALL of the proportional/periodic/boundary machinery below and returns
    /// exactly the pre-existing offsets-only mapping — a negative or zero "time remaining" has
    /// nothing meaningful to take a fraction of, and due-but-missed recovery already assumes
    /// offsets map 1:1 the way they always have.
    ///
    /// Priority when `deadline > now`: `remindPeriod` (fixed repeat cadence, if set) wins over
    /// `fractionsRemaining` (proportional reminders) — never both. `policy.offsets` is ALWAYS
    /// applied on top regardless of which (if either) of those fired, which is how "at the
    /// deadline" keeps working under the new default (`offsets: [0]`).
    ///
    /// Boundary passes, in this order, over the FULL combined set (offsets + proportional/period):
    /// 1. 1-day floor: drop (fixed/period marks) or clamp-to-floor (fraction marks) anything
    ///    earlier than `deadline - 1 day`.
    /// 2. Sort ascending, then drop any mark within `reminderMinimumGap` (10 min) of the previously
    ///    KEPT mark — applied across the whole list, including the at-deadline mark(s).
    /// 3. Cap: at most `maxBeforeDeadlineMarks` (8) marks that fire before the deadline
    ///    (`isHighUrgency == false`), keeping the ones nearest the deadline. At-or-after-deadline
    ///    marks are never capped.
    static func derive(
        taskId: UUID,
        deadline: Date?,
        createdAt: Date,
        priority: Int?,
        reminderOverride: ReminderPolicy?,
        globalPolicy: ReminderPolicy = .defaultPolicy,
        now: Date
    ) -> [ReminderRecord] {
        guard let deadline else {
            // No deadline: anh Khôi's approved "gentle nudge" backoff, anchored to `createdAt` —
            // deliberately NOT `now`. `ReminderScheduler.rebuildFromStorage` calls this again on
            // every launch/wake, and every task edit re-derives too; if the anchor were `now`
            // instead, a task sitting untouched for a week would restart its backoff at "1h from
            // now" on every single rebuild, degenerating into an hourly nag forever instead of
            // ever reaching the 7h/14h/24h/72h marks. Anchoring to the fixed `createdAt` means the
            // SAME absolute fire times come out of this function every time it's called for the
            // same task, so repeated derivation is idempotent rather than a reset.
            return noDeadlineMarks(createdAt: createdAt, priority: priority, reminderOverride: reminderOverride, now: now)
                .map { $0.makeRecord(taskId: taskId) }
        }
        let policy = reminderOverride ?? globalPolicy

        let fixedMarks: [Mark] = policy.offsets.map { offset in
            // "-1d" is a calendar day (DST-safe), not a flat 86400 s.
            let markDate = offset == -86400
                ? (Calendar.current.date(byAdding: .day, value: -1, to: deadline) ?? deadline.addingTimeInterval(offset))
                : deadline.addingTimeInterval(offset)
            return Mark(
                date: markDate,
                offsetKind: offsetKind(for: offset),
                isHighUrgency: offset >= 0,
                boundaryBehavior: .drop
            )
        }

        guard deadline > now else {
            // Overdue: no time remaining to take a fraction/period of — old offsets-only behavior,
            // untouched by the boundary/gap/cap passes below (see doc comment above).
            return fixedMarks.map { $0.makeRecord(taskId: taskId) }
        }

        var proportionalMarks: [Mark] = []
        let floor = deadline.addingTimeInterval(-reminderFloorInterval)
        if let period = policy.remindPeriod, period > 0 {
            // Repeat cadence wins over fractions. Walk backward from the deadline in steps of
            // `period`; STOP (don't generate, don't clamp) once a candidate would land STRICTLY
            // before `now` or before the 1-day floor — the explicit "don't clamp `remindPeriod`"
            // carve-out from anh Khôi's approved design. Deliberately `<` (not `<=`): a candidate
            // that lands EXACTLY on `now` (e.g. a 15-min period on a task due in exactly 1 hour
            // produces marks at -45'/-30'/-15'/-0', the last one landing exactly on `now`) is still
            // a real, includable mark — "touching" the boundary stops the NEXT step, not the one
            // that reached it.
            var k = 1
            while true {
                let candidate = deadline.addingTimeInterval(-period * Double(k))
                if candidate < now || candidate < floor { break }
                proportionalMarks.append(
                    Mark(date: candidate, offsetKind: "override", isHighUrgency: false, boundaryBehavior: .drop)
                )
                k += 1
                // Defensive backstop (mirrors `RecurrenceEngine.advance`'s own guard philosophy) —
                // `reminderMinimumGap`/`maxBeforeDeadlineMarks` below are the REAL backstop against
                // an absurdly small `period`, but this keeps the loop itself from spinning long
                // before ever reaching one of those exits.
                if k > 10_000 { break }
            }
        } else if !policy.fractionsRemaining.isEmpty {
            let remaining = deadline.timeIntervalSince(now)
            for fraction in policy.fractionsRemaining {
                let candidate = deadline.addingTimeInterval(-fraction * remaining)
                proportionalMarks.append(
                    Mark(date: candidate, offsetKind: "override", isHighUrgency: false, boundaryBehavior: .clampToFloor)
                )
            }
        }

        // Pass 1: 1-day floor (drop or clamp, per each mark's own boundary behavior).
        var marks: [Mark] = (fixedMarks + proportionalMarks).compactMap { mark in
            guard mark.date < floor else { return mark }
            switch mark.boundaryBehavior {
            case .drop: return nil
            case .clampToFloor:
                var clamped = mark
                clamped.date = floor
                return clamped
            }
        }

        // Pass 2: sort, then drop anything within `reminderMinimumGap` of the previously KEPT mark
        // — across the WHOLE list, including the at-deadline mark(s) from `offsets`.
        marks.sort { $0.date < $1.date }
        var kept: [Mark] = []
        for mark in marks {
            if let last = kept.last, mark.date.timeIntervalSince(last.date) < reminderMinimumGap { continue }
            kept.append(mark)
        }

        // Pass 3: cap before-deadline marks at `maxBeforeDeadlineMarks`, keeping the ones nearest
        // the deadline (the tail of the ascending-sorted before-deadline subsequence). At-or-after
        // marks (isHighUrgency) are never capped.
        let before = kept.filter { !$0.isHighUrgency }
        let atOrAfter = kept.filter { $0.isHighUrgency }
        let cappedBefore = before.count > maxBeforeDeadlineMarks ? Array(before.suffix(maxBeforeDeadlineMarks)) : before

        return (cappedBefore + atOrAfter)
            .sorted { $0.date < $1.date }
            .map { $0.makeRecord(taskId: taskId) }
    }

    /// Builds the "gentle nudge" candidates for a task with NO deadline, anchored to `createdAt`
    /// (see `derive`'s doc comment above for why `createdAt`, never `now`). Two mutually exclusive
    /// shapes:
    /// - `reminderOverride?.remindPeriod` set (the user said something like "nhắc tôi mỗi 2
    ///   tiếng"): that explicit cadence wins outright, walking FORWARD from `createdAt` in steps
    ///   of `period` — this is "user said so" taking priority over the generic backoff, same
    ///   spirit as `remindPeriod` already winning over `fractionsRemaining` in the deadline branch
    ///   above. `globalPolicy`/`reminderOverride.offsets`/`.fractionsRemaining` are never consulted
    ///   here — all three are deadline-relative (they compute backward FROM a deadline), and
    ///   there's no deadline for them to be relative to.
    /// - otherwise: the fixed backoff list for this `priority` (`noDeadlineHighPriorityOffsets`
    ///   for `priority == 1`; `noDeadlineDefaultOffsets` for every other value, INCLUDING `nil`),
    ///   then repeating forever at `noDeadlineRepeatInterval` once that list is exhausted.
    ///
    /// A literal "repeat forever" can't be a finite array. This walks the (possibly-repeating)
    /// offset sequence one step at a time, keeps only marks landing STRICTLY after `now` (an
    /// earlier one already fired or is moot — same reasoning as every other branch in this file),
    /// and stops once `maxBeforeDeadlineMarks` have been kept. That cap, combined with this
    /// function being called again on every later launch/wake/edit
    /// (`ReminderScheduler.rebuildFromStorage`/`scheduleReminders`), is the architecture that turns
    /// "repeat every 3 days forever" into something finite and re-derivable rather than an infinite
    /// loop or an infinite stored list — it is NOT a sign the "forever" part was implemented as
    /// only-8-times-then-stop. (Caveat surfaced in this task's own report, not fixed here since
    /// it's outside this change's scope: `ReminderScheduler.ensureDerived` only re-derives a task
    /// that currently has ZERO `ReminderRecord` rows, so a no-deadline task that is never edited
    /// again after its last pre-generated nudge fires won't automatically get a fresh batch top-up
    /// from `rebuildFromStorage` alone — only an explicit re-derive, e.g. from an edit, does that.)
    private static func noDeadlineMarks(
        createdAt: Date, priority: Int?, reminderOverride: ReminderPolicy?, now: Date
    ) -> [Mark] {
        if let period = reminderOverride?.remindPeriod, period > 0 {
            var kept: [Mark] = []
            var k = 1
            while kept.count < maxBeforeDeadlineMarks && k <= derivationStepBudget {
                let candidate = createdAt.addingTimeInterval(period * Double(k))
                if candidate > now {
                    kept.append(Mark(date: candidate, offsetKind: "nudge", isHighUrgency: false, boundaryBehavior: .drop))
                }
                k += 1
            }
            return kept
        }

        let baseOffsets = priority == 1 ? noDeadlineHighPriorityOffsets : noDeadlineDefaultOffsets
        var kept: [Mark] = []
        var index = 0
        while kept.count < maxBeforeDeadlineMarks && index <= derivationStepBudget {
            let offset: TimeInterval
            if index < baseOffsets.count {
                offset = baseOffsets[index]
            } else {
                // Fixed list still has future marks: don't pad with tail marks. The tail is only
                // a top-up (ensureDerived re-derives once nothing future is left scheduled).
                if !kept.isEmpty { break }
                // Past the end of the fixed list: keep adding `noDeadlineRepeatInterval` past the
                // list's last entry, forever ("lặp mãi mỗi 3 ngày").
                let stepsIntoRepeat = index - baseOffsets.count + 1
                offset = baseOffsets[baseOffsets.count - 1] + noDeadlineRepeatInterval * Double(stepsIntoRepeat)
            }
            let candidate = createdAt.addingTimeInterval(offset)
            if candidate > now {
                kept.append(Mark(date: candidate, offsetKind: "nudge", isHighUrgency: false, boundaryBehavior: .drop))
            }
            index += 1
        }
        return kept
    }
}
