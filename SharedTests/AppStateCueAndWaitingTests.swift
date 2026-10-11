// Tests/AppStateCueAndWaitingTests.swift — XCTest coverage for the two pure decision helpers T5
// (specs/006-cues-and-waiting, "wire UI") pulled out of `AppState.swift` specifically so they're
// testable without standing up a full `AppState`/`TaskStore`/SwiftData stack: `AppState.
// firstUnshownCue` (cue "don't repeat within a session" bookkeeping) and `AppState.eligibleOrder`
// (the `WaitingMode.decide(eligibleOrder:)` feed). Both are `static`, so these tests call them
// directly on the type — no `AppState()` instance, no store, no UserDefaults.
//
// 2026-08-09 (Opus review): `eligibleOrder` used to hand-copy `VolarCore`'s eligibility rule
// because that rule (and the full ordered list) had no public entry point — a live silent-drift
// risk with no compiler tie back to the engine. `VolarCore.eligibleTasksOrdered(from:now:calendar:)`
// is now public (`NextTask.swift`), and `eligibleOrder` is a thin wrapper around it — so every
// assertion below now exercises the REAL engine rule through that wrapper, not a parallel copy of
// it. The invariant that makes this safe (`nextTask == eligibleTasksOrdered(...).first`) is pinned
// separately in `VolarCore/Tests/VolarCoreTests/EligibleTasksOrderedTests.swift`.
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here): confirm
// on Mac that `xcodebuild test` picks this file up and every assertion below still holds once
// compiled for real.
import XCTest
import VolarCore
@testable import Volar

@MainActor
final class AppStateCueAndWaitingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - firstUnshownCue(_:alreadyShown:)

    func testFirstUnshownCueEmptyCandidatesReturnsNil() {
        XCTAssertNil(AppState.firstUnshownCue([], alreadyShown: []))
    }

    func testFirstUnshownCuePicksFirstCandidateWhenNoneShownYet() {
        let a = UUID()
        let b = UUID()
        XCTAssertEqual(AppState.firstUnshownCue([a, b], alreadyShown: []), a)
    }

    func testFirstUnshownCueSkipsAlreadyShownIds() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        XCTAssertEqual(AppState.firstUnshownCue([a, b, c], alreadyShown: [a]), b)
    }

    func testFirstUnshownCueAllShownReturnsNil() {
        let a = UUID()
        let b = UUID()
        XCTAssertNil(AppState.firstUnshownCue([a, b], alreadyShown: [a, b]))
    }

    func testFirstUnshownCuePreservesCandidateOrderNotShownSetOrder() {
        // `Set` has no defined iteration order — if this function accidentally iterated
        // `alreadyShown` instead of `candidates`, this test would be flaky across runs.
        let a = UUID()
        let b = UUID()
        let c = UUID()
        XCTAssertEqual(AppState.firstUnshownCue([c, b, a], alreadyShown: [c]), b)
    }

    // MARK: - eligibleOrder(from:now:) — helpers

    private func makeTask(
        title: String,
        status: TaskStatus = .todo,
        priority: Priority = .medium,
        deadline: Date? = nil,
        createdAt: Date? = nil,
        conditions: [VolarCore.Condition] = [],
        parentId: UUID? = nil,
        id: UUID = UUID()
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: title,
            priority: priority,
            status: status,
            deadline: deadline,
            conditions: conditions,
            createdAt: createdAt ?? now.addingTimeInterval(-3600),
            when: .now,
            parentId: parentId
        )
    }

    // MARK: - eligibleOrder(from:now:) — membership

    func testEligibleOrderExcludesDoneAndArchivedTasks() {
        let open = makeTask(title: "open")
        let done = makeTask(title: "done", status: .done)
        let archived = makeTask(title: "archived", status: .archived)
        let order = AppState.eligibleOrder(from: [open, done, archived], now: now)
        XCTAssertEqual(order, [open.id])
    }

    func testEligibleOrderExcludesTaskBlockedByUnsatisfiedTaskDoneCondition() {
        let blocker = makeTask(title: "blocker", status: .todo)
        let blocked = makeTask(title: "blocked", conditions: [.taskDone(blocker.id)])
        let order = AppState.eligibleOrder(from: [blocker, blocked], now: now)
        XCTAssertEqual(order, [blocker.id])
    }

    func testEligibleOrderIncludesTaskWhoseTaskDoneTargetIsDone() {
        let blockerID = UUID()
        // The blocker itself is NOT in this snapshot at all (already archived out of the list) —
        // `Condition.taskDone`'s own contract treats "absent from the snapshot" as satisfied
        // (deleted), same as `.done`/`.archived`. This is the exact case `eligibleOrder`'s own doc
        // comment warns an iterative peel-and-remove approach would get wrong for a DIFFERENT
        // reason (falsely satisfying a dependency that ISN'T really done yet) — here the absence is
        // genuine, so satisfied is the CORRECT answer, and this test pins that this reimplementation
        // still gets it right.
        let unblocked = makeTask(title: "unblocked", conditions: [.taskDone(blockerID)])
        let order = AppState.eligibleOrder(from: [unblocked], now: now)
        XCTAssertEqual(order, [unblocked.id])
    }

    func testEligibleOrderIncludesTaskWhoseTaskDoneTargetIsExplicitlyDone() {
        let blocker = makeTask(title: "blocker", status: .done)
        let unblocked = makeTask(title: "unblocked", conditions: [.taskDone(blocker.id)])
        let order = AppState.eligibleOrder(from: [blocker, unblocked], now: now)
        XCTAssertEqual(order, [unblocked.id])
    }

    func testEligibleOrderExcludesParentOfOpenChild() {
        let parent = makeTask(title: "parent")
        let child = makeTask(title: "child", parentId: parent.id)
        let order = AppState.eligibleOrder(from: [parent, child], now: now)
        XCTAssertEqual(order, [child.id])
    }

    func testEligibleOrderIncludesParentOnceChildIsDone() {
        let parent = makeTask(title: "parent")
        let child = makeTask(title: "child", status: .done, parentId: parent.id)
        let order = AppState.eligibleOrder(from: [parent, child], now: now)
        XCTAssertEqual(order, [parent.id])
    }

    func testEligibleOrderExcludesUnsatisfiedAfterDateCondition() {
        let future = makeTask(title: "future", conditions: [.afterDate(now.addingTimeInterval(3600))])
        let past = makeTask(title: "past", conditions: [.afterDate(now.addingTimeInterval(-3600))])
        let order = AppState.eligibleOrder(from: [future, past], now: now)
        XCTAssertEqual(order, [past.id])
    }

    func testEligibleOrderExcludesUnsatisfiedExternalCondition() {
        let waiting = makeTask(title: "waiting", conditions: [.external(description: "reply", satisfied: false)])
        let ready = makeTask(title: "ready", conditions: [.external(description: "reply", satisfied: true)])
        let order = AppState.eligibleOrder(from: [waiting, ready], now: now)
        XCTAssertEqual(order, [ready.id])
    }

    // MARK: - eligibleOrder(from:now:) — ordering (matches VolarCore.Task.orderedBefore's tiers)

    func testEligibleOrderRanksInProgressBeforeTodo() {
        let todo = makeTask(title: "todo", status: .todo)
        let inProgress = makeTask(title: "in progress", status: .inProgress)
        let order = AppState.eligibleOrder(from: [todo, inProgress], now: now)
        XCTAssertEqual(order, [inProgress.id, todo.id])
    }

    func testEligibleOrderRanksTodayDeadlineBeforeNoDeadline() {
        let noDeadline = makeTask(title: "no deadline")
        let dueToday = makeTask(title: "due today", deadline: now.addingTimeInterval(1800))
        let order = AppState.eligibleOrder(from: [noDeadline, dueToday], now: now)
        XCTAssertEqual(order, [dueToday.id, noDeadline.id])
    }

    func testEligibleOrderRanksEarlierPriorityFirstWhenDeadlinesTie() {
        let low = makeTask(title: "low", priority: .low)
        let high = makeTask(title: "high", priority: .high)
        let order = AppState.eligibleOrder(from: [low, high], now: now)
        XCTAssertEqual(order, [high.id, low.id])
    }

    func testEligibleOrderFullListNotJustTheWinner() {
        // The whole point of this function (design.md §2 Việc C's `eligibleOrder:` contract): it
        // must return every eligible task, not just VolarCore.nextTask's single winner.
        let a = makeTask(title: "a", priority: .high)
        let b = makeTask(title: "b", priority: .medium)
        let c = makeTask(title: "c", priority: .low)
        let order = AppState.eligibleOrder(from: [c, a, b], now: now)
        XCTAssertEqual(order, [a.id, b.id, c.id])
    }

    func testEligibleOrderEmptyInputReturnsEmpty() {
        XCTAssertEqual(AppState.eligibleOrder(from: [], now: now), [])
    }
}
