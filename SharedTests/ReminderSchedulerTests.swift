// Tests/ReminderSchedulerTests.swift — XCTest coverage for the reminder subsystem
// (specs/002-workflow-command-center/contracts/phase4-contract.md §A/§B, T027).
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here):
//   1. This is a NEW test target (`VolarTests` in `Volar/project.yml`) — confirm on Mac that
//      `xcodegen generate` followed by `xcodebuild test` actually builds and runs it.
//   2. M-4: `makeScheduler()` now uses `TaskStore(inMemory: true)` so the `TaskStore` side no
//      longer accumulates on-disk rows across repeated local runs. `ReminderScheduler`'s OWN
//      `ModelContainer` (`ReminderScheduler.swift`'s `makeContext()`, named store
//      `"VolarReminders"`) is still on-disk — threading an in-memory option through there would
//      require adding a parameter to the frozen `ReminderScheduler.init(store:voice:gate:)`
//      seam (contract §A), which this fix does not touch. `ReminderRecord` rows in that store
//      still accumulate across runs; every test below already uses a freshly-`UUID()`-suffixed
//      task id, so this is cosmetic (disk growth), not a correctness risk for these assertions.
//   3. `ReminderScheduler.rebuildFromStorage()`/`scheduleReminders`/etc. each spawn a
//      fire-and-forget `Task { ... await UNUserNotificationCenter... }` for system-request
//      registration. None of it is awaited by these tests (every assertion below only reads
//      synchronously-set `ReminderRecord` fields), but confirm on Mac this doesn't hang or crash
//      the `VolarTests` bundle when run unsigned / without notification authorization.
import XCTest
@testable import Volar

@MainActor
final class ReminderSchedulerTests: XCTestCase {

    // MARK: - Fixtures

    private func makeScheduler() throws -> (ReminderScheduler, TaskStore) {
        let store = try TaskStore(inMemory: true)
        let voice = VoiceReminderChannel(playback: VoicePlayback())
        let gate = ReminderContextGate()
        let scheduler = ReminderScheduler(store: store, voice: voice, gate: gate)
        return (scheduler, store)
    }

    // MARK: - rebuild-from-storage on launch

    func testRebuildFromStorageDerivesRemindersForOpenDatedTasks() throws {
        let (scheduler, store) = try makeScheduler()
        let deadline = Date().addingTimeInterval(3 * 86_400) // 3 days out — every mark is future
        let item = TaskItem(
            title: "Rebuild test \(UUID())", priority: .medium, deadline: deadline, when: .later
        )
        store.add(item)

        scheduler.rebuildFromStorage()

        // New default policy (anh Khôi, 2026-07-28): proportional marks at 1/2 and 1/3 of the
        // remaining time, plus at-deadline — no more fixed -1d/-1h. For a 3-day-out deadline, the
        // 1/2 mark (1.5 days out) is past the 1-day floor and clamps to exactly `deadline - 1 day`;
        // the 1/3 mark (1 day out) already sits AT that floor, so the two collapse into one
        // "override" mark once the <10-minute dedup drops the duplicate — leaving 2 records total.
        let records = scheduler.recordsForTask(item.id)
        XCTAssertEqual(records.count, 2, "the 1/2 and 1/3 marks both clamp to the same 1-day floor and collapse")
        XCTAssertEqual(Set(records.map(\.offsetKind)), Set(["override", "at"]))
        XCTAssertTrue(records.allSatisfy { $0.state == "scheduled" }, "nothing is due yet")

        let atRecord = records.first { $0.offsetKind == "at" }
        XCTAssertEqual(atRecord?.fireAt, deadline)
        XCTAssertEqual(atRecord?.isHighUrgency, true)
        let overrideRecord = records.first { $0.offsetKind == "override" }
        XCTAssertEqual((overrideRecord?.fireAt.timeIntervalSince(deadline) ?? .nan), -86_400, accuracy: 1.0)
        XCTAssertEqual(overrideRecord?.isHighUrgency, false)
    }

    // MARK: - no-deadline "gentle nudge" repeats forever (anh Khôi's ship-blocker fix, 2026-07-29)
    //
    // `ReminderScheduler.ensureDerived`'s old guard (`recordsForTask(taskId).isEmpty`) meant a
    // no-deadline task's nudge batch topped up exactly ONCE — after every one of the (capped) 8
    // marks fired, the task had records again and `rebuildFromStorage` stopped deriving anything
    // further for it forever, even though `ReminderRecord.derive`'s own doc comment describes the
    // backoff as repeating every 3 days forever. The fix loosens the guard for a no-deadline task
    // ONLY: also re-derive when no `"scheduled"` record is left with a future `fireAt`.
    //
    // These tests mutate `ReminderRecord.state` directly on the objects returned by
    // `scheduler.recordsForTask(_:)` to simulate "already delivered" — `ReminderRecord` is a
    // SwiftData `@Model` reference type tracked by the scheduler's own `ModelContext`, so mutating
    // a fetched instance's property updates the SAME tracked object subsequent calls on this
    // scheduler will see, without needing a save seam exposed to the test target.

    /// VIỆC 2.1: every nudge already `.delivered`, none `.scheduled` in the future -> the next
    /// rebuild must derive a FRESH batch, and every new mark must be in the future.
    func testNoDeadlineTaskRederivesFreshBatchOnceAllNudgesDelivered() throws {
        let (scheduler, store) = try makeScheduler()
        let now = Date()
        let item = TaskItem(
            title: "No-deadline rederive test \(UUID())", priority: .high, deadline: nil,
            createdAt: now, when: .later
        )
        store.add(item)

        scheduler.rebuildFromStorage()
        let firstBatch = scheduler.recordsForTask(item.id)
        XCTAssertFalse(firstBatch.isEmpty, "a no-deadline task must get an initial nudge batch")
        XCTAssertTrue(firstBatch.allSatisfy { $0.state == "scheduled" && $0.fireAt > now })

        // Simulate every nudge in the batch having already fired.
        for record in firstBatch { record.state = "delivered" }

        scheduler.rebuildFromStorage()
        let afterTopUp = scheduler.recordsForTask(item.id)
        let firstBatchIds = Set(firstBatch.map(\.id))
        let freshRecords = afterTopUp.filter { !firstBatchIds.contains($0.id) }

        XCTAssertFalse(freshRecords.isEmpty, "once the whole batch is delivered, rebuild must top up a fresh batch")
        XCTAssertTrue(
            freshRecords.allSatisfy { $0.state == "scheduled" && $0.fireAt > Date() },
            "every newly-derived mark must be scheduled and in the future"
        )
        XCTAssertTrue(
            afterTopUp.filter { firstBatchIds.contains($0.id) }.allSatisfy { $0.state == "delivered" },
            "the original delivered batch must be left alone — history is not touched"
        )
    }

    /// VIỆC 2.2: a no-deadline task still has a `.scheduled` nudge in the future -> rebuild must
    /// NOT derive a second batch (no duplication).
    func testNoDeadlineTaskWithFutureScheduledNudgeDoesNotDuplicate() throws {
        let (scheduler, store) = try makeScheduler()
        let now = Date()
        let item = TaskItem(
            title: "No-deadline no-duplicate test \(UUID())", priority: .high, deadline: nil,
            createdAt: now, when: .later
        )
        store.add(item)

        scheduler.rebuildFromStorage()
        let firstBatch = scheduler.recordsForTask(item.id)
        XCTAssertFalse(firstBatch.isEmpty)
        XCTAssertTrue(firstBatch.allSatisfy { $0.state == "scheduled" && $0.fireAt > now }, "nothing has fired yet")

        scheduler.rebuildFromStorage()
        let afterSecondRebuild = scheduler.recordsForTask(item.id)

        XCTAssertEqual(
            Set(afterSecondRebuild.map(\.id)), Set(firstBatch.map(\.id)),
            "with a future-scheduled nudge still pending, a second rebuild must not insert any new records"
        )
    }

    /// VIỆC 2.3: a task WITH a deadline, every reminder already fired (none `.scheduled` at all)
    /// -> rebuild must NOT re-derive (old behavior, unchanged) — re-deriving would resurrect
    /// past-due `policy.offsets` marks (e.g. "at deadline") as fresh `.scheduled` rows and re-fire
    /// a notification the user already received. See `ensureDerived`'s doc comment for why this
    /// is deliberately NOT symmetric with the no-deadline case above.
    func testDeadlineTaskDoesNotRederiveOnceEveryReminderHasFired() async throws {
        let (scheduler, store) = try makeScheduler()
        let deadline = Date().addingTimeInterval(-2 * 3600) // already overdue
        let item = TaskItem(
            title: "Deadline no-rederive test \(UUID())", priority: .medium, deadline: deadline, when: .later
        )
        store.add(item)

        await scheduler.rebuildFromStorage().value
        let firstBatch = scheduler.recordsForTask(item.id)
        XCTAssertFalse(firstBatch.isEmpty)
        XCTAssertTrue(
            firstBatch.allSatisfy { $0.state == "delivered" },
            "an overdue open task's reminders fire immediately on recovery"
        )

        await scheduler.rebuildFromStorage().value
        let afterSecondRebuild = scheduler.recordsForTask(item.id)

        XCTAssertEqual(
            Set(afterSecondRebuild.map(\.id)), Set(firstBatch.map(\.id)),
            "a deadline task with every reminder already fired must NOT be re-derived"
        )
        XCTAssertTrue(afterSecondRebuild.allSatisfy { $0.state == "delivered" })
    }

    /// VIỆC 2.4: the fresh top-up batch must still anchor to `createdAt`, not to `now` at
    /// derivation time — a task created long ago, deep into the infinite 72h-repeat tail, must
    /// keep producing marks spaced exactly 72h apart (mirrors
    /// `testDeriveNoDeadlineRepeatsEvery72HoursPastTheFixedList` at the `ReminderRecord.derive`
    /// level, but exercised through the scheduler's gap-fill path this task fixes).
    func testNoDeadlineTopUpBatchStillAnchorsToCreatedAtWithSeventyTwoHourTail() throws {
        let (scheduler, store) = try makeScheduler()
        let createdAt = Date().addingTimeInterval(-365 * 86_400) // created a year ago
        let item = TaskItem(
            title: "No-deadline anchor test \(UUID())", priority: .medium, deadline: nil,
            createdAt: createdAt, when: .later
        )
        store.add(item)

        scheduler.rebuildFromStorage()
        let firstBatch = scheduler.recordsForTask(item.id)
        XCTAssertFalse(firstBatch.isEmpty)
        for record in firstBatch { record.state = "delivered" }

        scheduler.rebuildFromStorage()
        let now = Date()
        let freshRecords = scheduler.recordsForTask(item.id).filter { $0.state == "scheduled" }
        XCTAssertFalse(freshRecords.isEmpty, "the top-up batch must produce new scheduled marks")

        let sorted = freshRecords.sorted { $0.fireAt < $1.fireAt }
        XCTAssertTrue(sorted.allSatisfy { $0.fireAt > now }, "every top-up mark must be in the future")
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            XCTAssertEqual(
                next.fireAt.timeIntervalSince(previous.fireAt), 259_200, accuracy: 1.0,
                "top-up marks deep in the repeat tail must stay spaced 72h apart, anchored to createdAt"
            )
        }
    }

    // MARK: - overdue-while-closed fires once

    func testOverdueReminderFiresOnceOnRecovery() async throws {
        let (scheduler, store) = try makeScheduler()
        // Deadline 2 hours in the past: the (now single, at-deadline) default-policy mark is
        // already due at derivation time — `ReminderRecord.derive`'s overdue guard skips the
        // proportional/period machinery entirely and falls back to the plain offsets mapping.
        let deadline = Date().addingTimeInterval(-2 * 3600)
        let item = TaskItem(
            title: "Overdue test \(UUID())", priority: .medium, deadline: deadline, when: .later
        )
        store.add(item)

        await scheduler.rebuildFromStorage().value
        let afterFirst = scheduler.recordsForTask(item.id)
        XCTAssertFalse(afterFirst.isEmpty)
        XCTAssertTrue(
            afterFirst.allSatisfy { $0.state == "delivered" },
            "an open task's due-but-missed reminders must fire on recovery"
        )

        // A second rebuild (e.g. a second wake) must NOT re-fire already-delivered records.
        await scheduler.rebuildFromStorage().value
        let afterSecond = scheduler.recordsForTask(item.id)
        XCTAssertEqual(
            afterFirst.map(\.state).sorted(), afterSecond.map(\.state).sorted(),
            "recovery must be idempotent — a due-but-missed reminder fires once"
        )
    }

    // MARK: - done-task suppression

    /// SB-2 fix: the original version of this test added an ALREADY-`.done` task and asserted
    /// records existed — but `rebuildFromStorage()`'s derive loop only considers OPEN dated tasks
    /// (`status == .todo || .inProgress`), so a `.done` task never gets anything derived for it in
    /// the first place. That made the original assertion (`records.allSatisfy { $0.state ==
    /// "satisfied" }` over an EMPTY array) trivially true for the wrong reason, while the real
    /// suppression path — derive while open, complete afterward, THEN fire — went completely
    /// untested. This version drives that real path: derive with the task still open (records
    /// land `.scheduled`), mark it done in the store, then explicitly fire each record via
    /// `handleFire` (mirrors what a due system notification / due-but-missed recovery would
    /// trigger) and asserts fresh-reload suppression actually kicks in (constitution IV).
    func testDoneTaskSuppressesFire() throws {
        let (scheduler, store) = try makeScheduler()
        let deadline = Date().addingTimeInterval(3600) // due in an hour — not yet due
        let item = TaskItem(
            title: "Done test \(UUID())", priority: .medium, deadline: deadline, when: .later
        )
        store.add(item)

        scheduler.rebuildFromStorage()
        let scheduled = scheduler.recordsForTask(item.id)
        XCTAssertFalse(scheduled.isEmpty, "an open, dated task must get reminders derived while still open")
        XCTAssertTrue(scheduled.allSatisfy { $0.state == "scheduled" }, "nothing is due yet")

        // Complete it in the store — the derived records themselves are untouched by this call;
        // constitution IV's fresh reload at FIRE time is what's supposed to catch this, not
        // completion itself reaching in to cancel rows.
        store.toggle(item.id, now: Date())

        // Drive the real fire path for every derived record (as due-but-missed recovery or a live
        // system notification would).
        for record in scheduled {
            scheduler.handleFire(recordId: record.id)
        }

        let afterFire = scheduler.recordsForTask(item.id)
        XCTAssertTrue(
            afterFire.allSatisfy { $0.state == "satisfied" },
            "a done task's fresh-reloaded reminder must resolve to satisfied, never delivered/spoken"
        )
    }

    // MARK: - policy escalation offsets (offsets-only policy — legacy-shape regression coverage)

    /// Regression guard (anh Khôi's ratio-reminder change, 2026-07-28): an offsets-only policy
    /// (`fractionsRemaining` empty, `remindPeriod` nil — the shape every policy had before this
    /// change, and what a pre-update persisted `ReminderPolicy` decodes to) must derive EXACTLY
    /// the same records as before: no proportional marks, and the 1-day-floor/10-minute-gap/
    /// 8-mark-cap passes are all no-ops on a 3-entry set already spaced far apart.
    func testDeriveOffsetsOnlyPolicyMatchesLegacyBehavior() {
        let now = Date()
        let deadline = now.addingTimeInterval(2 * 86_400)
        let policy = ReminderPolicy(offsets: [-86_400, -3600, 0], repeatEvery: nil)
        // `createdAt`/`priority` are unused by the deadline branch — any values are fine here.
        let records = ReminderRecord.derive(
            taskId: UUID(), deadline: deadline, createdAt: now, priority: nil, reminderOverride: policy, now: now
        )

        XCTAssertEqual(records.count, 3)
        let byKind = Dictionary(uniqueKeysWithValues: records.map { ($0.offsetKind, $0) })

        XCTAssertEqual(byKind["-1d"]?.fireAt, deadline.addingTimeInterval(-86_400))
        XCTAssertEqual(byKind["-1h"]?.fireAt, deadline.addingTimeInterval(-3600))
        XCTAssertEqual(byKind["at"]?.fireAt, deadline)

        XCTAssertEqual(byKind["-1d"]?.isHighUrgency, false)
        XCTAssertEqual(byKind["-1h"]?.isHighUrgency, false)
        XCTAssertEqual(byKind["at"]?.isHighUrgency, true, "at-or-after-deadline offsets drive the voice escalation rung")
    }

    func testDerivePrefersPerTaskOverride() {
        let now = Date()
        let deadline = now.addingTimeInterval(3600)
        let override = ReminderPolicy(offsets: [-1800], repeatEvery: nil) // 30 min before — nonstandard
        let records = ReminderRecord.derive(
            taskId: UUID(), deadline: deadline, createdAt: now, priority: nil, reminderOverride: override, now: now
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.offsetKind, "override")
        XCTAssertEqual(records.first?.fireAt, deadline.addingTimeInterval(-1800))
    }

    /// Superseded by anh Khôi's 2026-07-29 "gentle nudge" design (see the no-deadline test block
    /// below): a task with no deadline used to get NO reminders at all. It now gets a
    /// `createdAt`-anchored backoff nudge instead — this regression guard just confirms that's
    /// still non-empty (the concrete offsets are covered by the dedicated tests below).
    func testDeriveNoDeadlineProducesNudgesInsteadOfEmpty() {
        let now = Date()
        let records = ReminderRecord.derive(
            taskId: UUID(), deadline: nil, createdAt: now, priority: nil, reminderOverride: nil, now: now
        )
        XCTAssertFalse(records.isEmpty, "a no-deadline task must still get a gentle backoff nudge, not nothing")
        XCTAssertTrue(records.allSatisfy { $0.offsetKind == "nudge" && $0.isHighUrgency == false })
    }

    // MARK: - proportional (fractionsRemaining) reminders

    /// Task created 09:00, deadline 17:00 (8h out), fractions [1/2, 1/3] -> marks at 13:00 (half of
    /// the remaining 8h before deadline), 14:20 (a third of the remaining 8h before deadline), and
    /// 17:00 (at deadline) — anh Khôi's own worked example.
    func testDeriveFractionsRemainingBasicSplit() {
        let now = Date()
        let deadline = now.addingTimeInterval(8 * 3600)
        let policy = ReminderPolicy(offsets: [0], repeatEvery: nil, fractionsRemaining: [0.5, 1.0 / 3.0], remindPeriod: nil)
        // `createdAt`/`priority` are unused by the deadline branch — any values are fine here.
        let records = ReminderRecord.derive(
            taskId: UUID(), deadline: deadline, createdAt: now, priority: nil, reminderOverride: policy, now: now
        )

        XCTAssertEqual(records.count, 3)
        let sorted = records.sorted { $0.fireAt < $1.fireAt }
        XCTAssertEqual(sorted[0].fireAt.timeIntervalSince(deadline), -4 * 3600, accuracy: 0.01, "13:00 — half of the 8h remaining")
        XCTAssertEqual(sorted[1].fireAt.timeIntervalSince(deadline), -8 * 3600 / 3, accuracy: 0.01, "14:20 — a third of the 8h remaining")
        XCTAssertEqual(sorted[2].fireAt, deadline)
        XCTAssertEqual(sorted[0].isHighUrgency, false)
        XCTAssertEqual(sorted[1].isHighUrgency, false)
        XCTAssertEqual(sorted[2].isHighUrgency, true)
    }

    /// anh Khôi's approved urgent-task example: 30 minutes left. 1/2 -> 15 min out, 1/3 -> 10 min
    /// out. Those two are only 5 minutes apart (< the 10-minute minimum gap), so the 10-min-out
    /// mark (closer to deadline) is dropped, leaving just the 15-min-out mark plus at-deadline.
    func testDeriveFractionsDropsCloserMarkUnderTenMinuteGap() {
        let now = Date()
        let deadline = now.addingTimeInterval(30 * 60)
        let policy = ReminderPolicy(offsets: [0], repeatEvery: nil, fractionsRemaining: [0.5, 1.0 / 3.0], remindPeriod: nil)
        // `createdAt`/`priority` are unused by the deadline branch — any values are fine here.
        let records = ReminderRecord.derive(
            taskId: UUID(), deadline: deadline, createdAt: now, priority: nil, reminderOverride: policy, now: now
        )

        XCTAssertEqual(records.count, 2, "the 1/3 (10-min-out) mark is within 10 minutes of the 1/2 (15-min-out) mark and must be dropped")
        let sorted = records.sorted { $0.fireAt < $1.fireAt }
        XCTAssertEqual(sorted[0].fireAt.timeIntervalSince(deadline), -15 * 60, accuracy: 0.01)
        XCTAssertEqual(sorted[1].fireAt, deadline)
    }

    /// anh Khôi's approved long-task example: 30 days left. Both 1/2 (15 days out) and 1/3 (10
    /// days out) are past the 1-day floor, so BOTH clamp in to exactly `deadline - 1 day` instead
    /// of vanishing — then collapse into one record since they land on the same instant.
    func testDeriveFractionsClampToOneDayFloorAndCollapseDuplicate() {
        let now = Date()
        let deadline = now.addingTimeInterval(30 * 86_400)
        let policy = ReminderPolicy(offsets: [0], repeatEvery: nil, fractionsRemaining: [0.5, 1.0 / 3.0], remindPeriod: nil)
        // `createdAt`/`priority` are unused by the deadline branch — any values are fine here.
        let records = ReminderRecord.derive(
            taskId: UUID(), deadline: deadline, createdAt: now, priority: nil, reminderOverride: policy, now: now
        )

        XCTAssertEqual(records.count, 2, "both proportional marks clamp to the same 1-day floor and collapse")
        let sorted = records.sorted { $0.fireAt < $1.fireAt }
        XCTAssertEqual(sorted[0].fireAt.timeIntervalSince(deadline), -86_400, accuracy: 0.01)
        XCTAssertEqual(sorted[0].offsetKind, "override")
        XCTAssertEqual(sorted[0].isHighUrgency, false)
        XCTAssertEqual(sorted[1].fireAt, deadline)
    }

    // MARK: - fixed-cadence (remindPeriod) reminders

    /// "Nhắc mỗi 15 phút" on a task due in exactly 1 hour: walking back from the deadline in
    /// 15-minute steps lands on -45'/-30'/-15'/-0' before the loop's own `now`-boundary stops it —
    /// 4 evenly-spaced marks, plus the separate at-deadline mark from `offsets`.
    func testDeriveRemindPeriodEvenlySpacedMarksPlusAtDeadline() {
        let now = Date()
        let deadline = now.addingTimeInterval(3600)
        let policy = ReminderPolicy(offsets: [0], repeatEvery: nil, fractionsRemaining: [], remindPeriod: 15 * 60)
        // `createdAt`/`priority` are unused by the deadline branch — any values are fine here.
        let records = ReminderRecord.derive(
            taskId: UUID(), deadline: deadline, createdAt: now, priority: nil, reminderOverride: policy, now: now
        )

        XCTAssertEqual(records.count, 5, "4 marks spaced 15 minutes apart, plus the at-deadline mark")
        let sorted = records.sorted { $0.fireAt < $1.fireAt }
        let expectedOffsets: [TimeInterval] = [-3600, -2700, -1800, -900, 0]
        for (record, expected) in zip(sorted, expectedOffsets) {
            XCTAssertEqual(record.fireAt.timeIntervalSince(deadline), expected, accuracy: 0.01)
        }
        XCTAssertEqual(sorted.map(\.isHighUrgency), [false, false, false, false, true])
    }

    /// "Nhắc mỗi 1 phút" on a long task would naively produce hundreds of marks — the hard 8-mark
    /// cap (macOS's shared ~64 pending-notification ceiling across the WHOLE app) keeps only the 8
    /// nearest the deadline.
    func testDeriveRemindPeriodCapsAtEightNearestMarks() {
        let now = Date()
        let deadline = now.addingTimeInterval(10 * 86_400)
        let policy = ReminderPolicy(offsets: [0], repeatEvery: nil, fractionsRemaining: [], remindPeriod: 60)
        // `createdAt`/`priority` are unused by the deadline branch — any values are fine here.
        let records = ReminderRecord.derive(
            taskId: UUID(), deadline: deadline, createdAt: now, priority: nil, reminderOverride: policy, now: now
        )

        let before = records.filter { !$0.isHighUrgency }
        XCTAssertEqual(before.count, 8, "hard cap protects the system's shared pending-notification ceiling")
        XCTAssertEqual(records.count, 9, "8 capped before-deadline marks + the at-deadline mark")
        let nearestToDeadline = before.max { $0.fireAt < $1.fireAt }
        XCTAssertEqual((nearestToDeadline?.fireAt.timeIntervalSince(deadline) ?? .nan), -600, accuracy: 0.01, "nearest surviving mark, after the 10-minute-gap dedup thinned the raw 1-minute cadence")
    }

    /// `remindPeriod` wins outright over `fractionsRemaining` when both are set — never blended.
    func testDeriveRemindPeriodWinsOverFractionsRemaining() {
        let now = Date()
        let deadline = now.addingTimeInterval(3600)
        let policy = ReminderPolicy(offsets: [0], repeatEvery: nil, fractionsRemaining: [0.5, 1.0 / 3.0], remindPeriod: 15 * 60)
        // `createdAt`/`priority` are unused by the deadline branch — any values are fine here.
        let records = ReminderRecord.derive(
            taskId: UUID(), deadline: deadline, createdAt: now, priority: nil, reminderOverride: policy, now: now
        )

        XCTAssertEqual(records.count, 5, "identical to the remindPeriod-only case — fractionsRemaining contributes nothing")
    }

    /// An already-overdue deadline has no meaningful "time remaining" to take a fraction/period
    /// of — the proportional/period machinery (and its boundary/gap/cap passes) is skipped
    /// entirely, falling back to the plain offsets mapping (matches
    /// `ReminderScheduler.rebuildFromStorage`'s due-but-missed recovery assumption).
    func testDeriveSkipsProportionalMarksWhenAlreadyOverdue() {
        let now = Date()
        let deadline = now.addingTimeInterval(-3600)
        let policy = ReminderPolicy(offsets: [0], repeatEvery: nil, fractionsRemaining: [0.5, 1.0 / 3.0], remindPeriod: nil)
        // `createdAt`/`priority` are unused by the deadline branch — any values are fine here.
        let records = ReminderRecord.derive(
            taskId: UUID(), deadline: deadline, createdAt: now, priority: nil, reminderOverride: policy, now: now
        )

        XCTAssertEqual(records.count, 1, "overdue: only the fixed offsets mapping, no proportional marks")
        XCTAssertEqual(records.first?.offsetKind, "at")
        XCTAssertEqual(records.first?.fireAt, deadline)
    }

    // MARK: - no-deadline "gentle nudge" backoff (anh Khôi, 2026-07-29)

    /// Fresh high-priority task (`createdAt == now`): the FULL backoff list applies — 1h, 3h, 7h,
    /// 14h, 24h, 72h out from `createdAt`, all still in the future.
    func testDeriveNoDeadlineHighPrioritySixMarks() {
        let now = Date()
        let createdAt = now
        let records = ReminderRecord.derive(
            taskId: UUID(), deadline: nil, createdAt: createdAt, priority: 1, reminderOverride: nil, now: now
        )

        XCTAssertEqual(records.count, 6)
        let sorted = records.sorted { $0.fireAt < $1.fireAt }
        let expectedOffsets: [TimeInterval] = [3600, 10_800, 25_200, 50_400, 86_400, 259_200]
        for (record, expected) in zip(sorted, expectedOffsets) {
            XCTAssertEqual(record.fireAt.timeIntervalSince(createdAt), expected, accuracy: 1.0)
            XCTAssertEqual(record.offsetKind, "nudge")
            XCTAssertEqual(record.isHighUrgency, false)
        }
    }

    /// Fresh task with NO priority set (`nil`): the two most-eager marks (1h/3h) are dropped —
    /// the sequence starts at 7h, exactly like `priority == 3` below.
    func testDeriveNoDeadlineNilPrioritySkipsFirstTwoMarks() {
        let now = Date()
        let createdAt = now
        let records = ReminderRecord.derive(
            taskId: UUID(), deadline: nil, createdAt: createdAt, priority: nil, reminderOverride: nil, now: now
        )

        XCTAssertEqual(records.count, 4)
        let sorted = records.sorted { $0.fireAt < $1.fireAt }
        let expectedOffsets: [TimeInterval] = [25_200, 50_400, 86_400, 259_200]
        for (record, expected) in zip(sorted, expectedOffsets) {
            XCTAssertEqual(record.fireAt.timeIntervalSince(createdAt), expected, accuracy: 1.0)
        }
        XCTAssertFalse(sorted.contains { $0.fireAt.timeIntervalSince(createdAt) < 25_200 - 1 }, "no 1h/3h marks")
    }

    /// `priority == 3` (low, explicitly set) must land on the SAME reduced sequence as `nil` —
    /// only `priority == 1` gets the full 6-mark list.
    func testDeriveNoDeadlineLowPriorityMatchesNilPriority() {
        let now = Date()
        let createdAt = now
        let nilPriorityRecords = ReminderRecord.derive(
            taskId: UUID(), deadline: nil, createdAt: createdAt, priority: nil, reminderOverride: nil, now: now
        )
        let lowPriorityRecords = ReminderRecord.derive(
            taskId: UUID(), deadline: nil, createdAt: createdAt, priority: 3, reminderOverride: nil, now: now
        )

        XCTAssertEqual(lowPriorityRecords.count, 4)
        XCTAssertEqual(
            Set(lowPriorityRecords.map { $0.fireAt.timeIntervalSince(createdAt) }),
            Set(nilPriorityRecords.map { $0.fireAt.timeIntervalSince(createdAt) }),
            "only priority == 1 gets the extended 1h/3h marks — every other value (including nil) is identical"
        )
    }

    /// THE regression guard for the anchor bug this whole change exists to avoid: a task created
    /// 10 hours ago, with `now` = "right now" (i.e. `createdAt + 10h`). If the backoff were
    /// (incorrectly) anchored to `now` instead of `createdAt`, the next mark would be "1h from
    /// now". Anchored correctly to `createdAt`, the 1h/3h/7h marks (all < 10h out) have already
    /// passed and are dropped, and the next surviving mark is 14h out FROM CREATEDAT — i.e. 4
    /// hours from `now`, not 1 hour.
    func testDeriveNoDeadlineAnchorsToCreatedAtNotNow() {
        let createdAt = Date().addingTimeInterval(-10 * 3600)
        let now = createdAt.addingTimeInterval(10 * 3600) // "right now"
        let records = ReminderRecord.derive(
            taskId: UUID(), deadline: nil, createdAt: createdAt, priority: 1, reminderOverride: nil, now: now
        )

        XCTAssertFalse(records.isEmpty)
        let earliest = records.min { $0.fireAt < $1.fireAt }
        XCTAssertEqual(
            (earliest?.fireAt.timeIntervalSince(createdAt) ?? .nan), 50_400, accuracy: 1.0,
            "next surviving mark is 14h out from createdAt (1h/3h/7h already passed) — NOT 1h from now"
        )
        XCTAssertEqual(
            (earliest?.fireAt.timeIntervalSince(now) ?? .nan), 4 * 3600, accuracy: 1.0,
            "in now-relative terms that's 4h away, not the 1h it would be if the backoff had reset"
        )
    }

    /// Once the fixed backoff list is exhausted, marks keep coming every 72h forever. A task
    /// created long enough ago that `now` has already passed every fixed mark lands deep in that
    /// repeating tail — every kept mark (after the first) must be exactly 72h after the previous
    /// one, and every one of them must still be after `now`.
    func testDeriveNoDeadlineRepeatsEvery72HoursPastTheFixedList() {
        let createdAt = Date().addingTimeInterval(-365 * 86_400) // created a year ago
        let now = Date()
        let records = ReminderRecord.derive(
            taskId: UUID(), deadline: nil, createdAt: createdAt, priority: nil, reminderOverride: nil, now: now
        )

        XCTAssertFalse(records.isEmpty)
        let sorted = records.sorted { $0.fireAt < $1.fireAt }
        XCTAssertTrue(sorted.allSatisfy { $0.fireAt > now }, "every kept mark must be in the future")
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            XCTAssertEqual(next.fireAt.timeIntervalSince(previous.fireAt), 259_200, accuracy: 1.0, "72h repeat spacing")
        }
    }

    /// Hard cap — mirrors the deadline branch's own 8-mark cap (same constant, reused rather than
    /// duplicated): even arbitrarily far into the infinite 72h-repeat tail, `derive` never returns
    /// more than 8 records for a no-deadline task.
    func testDeriveNoDeadlineCapsAtEightMarks() {
        let createdAt = Date().addingTimeInterval(-365 * 86_400)
        let now = Date()
        let records = ReminderRecord.derive(
            taskId: UUID(), deadline: nil, createdAt: createdAt, priority: 1, reminderOverride: nil, now: now
        )
        XCTAssertLessThanOrEqual(records.count, 8)
    }

    /// Regression guard, the other direction: a task WITH a deadline must never get a "nudge" —
    /// the two branches are mutually exclusive.
    func testDeriveWithDeadlineNeverProducesNudge() {
        let now = Date()
        let deadline = now.addingTimeInterval(3 * 86_400)
        let records = ReminderRecord.derive(
            taskId: UUID(), deadline: deadline, createdAt: now.addingTimeInterval(-86_400), priority: 1,
            reminderOverride: nil, now: now
        )

        XCTAssertFalse(records.isEmpty)
        XCTAssertFalse(records.contains { $0.offsetKind == "nudge" }, "a dated task must never get a no-deadline nudge")
    }

    /// An explicit per-task `remindPeriod` ("nhắc tôi mỗi 2 tiếng") on a no-deadline task wins
    /// outright over the generic backoff sequence — cadence anchored to `createdAt`, walking
    /// forward (2h, 4h, 6h, ...), same "user said so" priority `remindPeriod` already has over
    /// `fractionsRemaining` in the deadline branch.
    func testDeriveNoDeadlineExplicitRemindPeriodOverridesBackoff() {
        let now = Date()
        let createdAt = now
        let override = ReminderPolicy(offsets: [0], repeatEvery: nil, fractionsRemaining: [], remindPeriod: 2 * 3600)
        let records = ReminderRecord.derive(
            taskId: UUID(), deadline: nil, createdAt: createdAt, priority: nil, reminderOverride: override, now: now
        )

        XCTAssertFalse(records.isEmpty)
        let sorted = records.sorted { $0.fireAt < $1.fireAt }
        XCTAssertEqual((sorted.first?.fireAt.timeIntervalSince(createdAt) ?? .nan), 2 * 3600, accuracy: 1.0)
        for (record, index) in zip(sorted, 1...) {
            XCTAssertEqual(
                record.fireAt.timeIntervalSince(createdAt), 2 * 3600 * Double(index), accuracy: 1.0,
                "every mark must land exactly on a 2h multiple from createdAt — not the backoff sequence"
            )
            XCTAssertEqual(record.offsetKind, "nudge")
        }
    }

    // MARK: - ReminderPolicy Codable (old persisted data must still decode)

    func testReminderPolicyDecodesLegacyJSONWithoutNewFields() throws {
        let legacyJSON = Data("""
        {"offsets":[-86400,-3600,0],"repeatEvery":null}
        """.utf8)

        let decoded = try JSONDecoder().decode(ReminderPolicy.self, from: legacyJSON)

        XCTAssertEqual(decoded.offsets, [-86_400, -3600, 0])
        XCTAssertNil(decoded.repeatEvery)
        XCTAssertEqual(decoded.fractionsRemaining, [], "missing key must default to empty, not throw")
        XCTAssertNil(decoded.remindPeriod)
    }

    func testReminderPolicyRoundTripsThroughCodable() throws {
        let policy = ReminderPolicy.defaultPolicy
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(ReminderPolicy.self, from: data)
        XCTAssertEqual(decoded, policy)
    }

    // MARK: - nearest-N refill under the 64 cap

    func testNearestCandidatesPicksEarliestUnderCapacity() {
        let now = Date()
        let records = (0..<10).map { offset in
            ReminderRecord(taskId: UUID(), fireAt: now.addingTimeInterval(Double(offset) * 60), offsetKind: "at")
        }
        let shuffled = records.shuffled()

        let selected = ReminderScheduler.nearestCandidates(shuffled, excluding: [], capacity: 3)

        XCTAssertEqual(selected.count, 3)
        XCTAssertEqual(
            selected.map(\.fireAt), Array(records.prefix(3)).map(\.fireAt),
            "must pick the 3 EARLIEST, not just any 3"
        )
    }

    func testNearestCandidatesExcludesAlreadyRegistered() {
        let now = Date()
        let records = (0..<5).map { offset in
            ReminderRecord(taskId: UUID(), fireAt: now.addingTimeInterval(Double(offset) * 60), offsetKind: "at")
        }

        let selected = ReminderScheduler.nearestCandidates(
            records, excluding: [records[0].id, records[1].id], capacity: 10
        )

        XCTAssertEqual(selected.count, 3)
        XCTAssertFalse(selected.contains { $0.id == records[0].id || $0.id == records[1].id })
    }

    func testNearestCandidatesRespectsZeroCapacity() {
        let record = ReminderRecord(taskId: UUID(), fireAt: Date(), offsetKind: "at")
        XCTAssertTrue(ReminderScheduler.nearestCandidates([record], excluding: [], capacity: 0).isEmpty)
    }

    func testNearestCandidatesSkipsNonScheduledStates() {
        let now = Date()
        let scheduled = ReminderRecord(taskId: UUID(), fireAt: now, offsetKind: "at", state: "scheduled")
        let delivered = ReminderRecord(taskId: UUID(), fireAt: now.addingTimeInterval(-10), offsetKind: "at", state: "delivered")

        let selected = ReminderScheduler.nearestCandidates([scheduled, delivered], excluding: [], capacity: 10)

        XCTAssertEqual(selected.map(\.id), [scheduled.id], "only .scheduled records are eligible for a system slot")
    }

    /// WG-nudge ship-blocker regression guard: a pile of near-term no-deadline nudges (all firing
    /// sooner than a real deadline reminder) must NOT push that deadline reminder out of a
    /// capacity-limited refill. Deadline-anchored kinds are prioritized as a group over "nudge",
    /// regardless of raw fire-time ordering.
    func testNearestCandidatesNeverLetsNudgesCrowdOutDeadlineReminders() {
        let now = Date()
        // 5 nudges, all firing within the next 5 minutes — earlier than the one deadline reminder.
        let nudges = (0..<5).map { offset in
            ReminderRecord(taskId: UUID(), fireAt: now.addingTimeInterval(Double(offset) * 60), offsetKind: "nudge")
        }
        // The real deadline reminder fires tomorrow — later than every nudge above.
        let deadlineReminder = ReminderRecord(taskId: UUID(), fireAt: now.addingTimeInterval(86_400), offsetKind: "at")

        let selected = ReminderScheduler.nearestCandidates(nudges + [deadlineReminder], excluding: [], capacity: 3)

        XCTAssertEqual(selected.count, 3)
        XCTAssertTrue(
            selected.contains { $0.id == deadlineReminder.id },
            "the deadline reminder must never be crowded out of the cap by earlier-firing nudges"
        )
        XCTAssertEqual(selected.filter { $0.offsetKind == "nudge" }.count, 2, "only the leftover capacity goes to nudges")
    }

    // MARK: - voice-gate suppression paths

    func testGateSuppressesDuringBusyInterval() {
        let gate = ReminderContextGate()
        let now = Date()
        gate.busyIntervals = [DateInterval(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(60))]
        XCTAssertTrue(gate.shouldSuppressVoice(now: now))
    }

    func testGateAllowsOutsideBusyInterval() {
        let gate = ReminderContextGate()
        let now = Date()
        gate.busyIntervals = [DateInterval(start: now.addingTimeInterval(3600), end: now.addingTimeInterval(7200))]
        XCTAssertFalse(gate.shouldSuppressVoice(now: now))
    }

    func testGateSuppressesWhenDoNotDisturbSignalFires() {
        let gate = ReminderContextGate()
        gate.isDoNotDisturbOn = { true }
        XCTAssertTrue(gate.shouldSuppressVoice(now: Date()))
    }

    func testGateSuppressesWhenLocalCaptureActive() {
        let gate = ReminderContextGate()
        gate.isLocalMicCaptureActive = { true }
        XCTAssertTrue(gate.shouldSuppressVoice(now: Date()))
    }

    func testGateSuppressesWhenScreenSharingSignalFires() {
        let gate = ReminderContextGate()
        gate.isScreenBeingShared = { true }
        XCTAssertTrue(gate.shouldSuppressVoice(now: Date()))
    }

    func testGateSuppressesWhenOtherAudioSignalFires() {
        let gate = ReminderContextGate()
        gate.isOtherAudioPlaying = { true }
        XCTAssertTrue(gate.shouldSuppressVoice(now: Date()))
    }

    func testGateDefaultsToNotSuppressedWithNoSignalsWired() {
        let gate = ReminderContextGate()
        // No busyIntervals, no injected closures wired. The only remaining concrete check
        // (AVCaptureDevice mic contention) should read `false` in a plain test-runner process with
        // no audio call in progress — fail-open by design absent any actual signal (see
        // ReminderContextGate.swift's header comment on why "unsure" vs "no signal" differ).
        XCTAssertFalse(gate.shouldSuppressVoice(now: Date()))
    }
}
