// Tests/FocusSwitchTests.swift — XCTest coverage for the "Switch" (đổi gió) action added to
// `Sources/App/AppState.swift`: `AppState.nextSwitchTarget(excluding:from:now:calendar:)` (the pure
// replacement-task selector), the `switchFocusTask()`/`canSwitchFocusTask` wiring behind
// `Sources/Views/FocusOverlay.swift`'s "Switch" button, the `switchDashboardActiveTask()`/
// `canSwitchDashboardActiveTask`/`dashboardActiveTask` wiring behind `Sources/Views/TodayView.swift`'s
// hero-card "Switch" button, and the shared FR-030 tail both paths run through
// (`recordSwitchAway`/`maybeOfferBreakdown` bumping `switchAwayCount` and arming the one-time
// breakdown suggestion).
//
// Anh Khôi chốt 2026-07-15 (backlog (l)): Switch must be a first-class action, equal in standing to
// "Mark done", with completely non-judgmental behavior. FR-030 (spec.md:280) additionally requires
// counting switches (`switchAwayCount`, NEVER surfaced to the user) and a one-time-only breakdown
// invite once a task crosses 3. Every "switch succeeded" test below asserts the task being LEFT is
// unchanged in every field EXCEPT `switchAwayCount` (`XCTAssertEqual` on the whole `TaskItem`, which
// is `Equatable`, against an explicitly-bumped copy) — never `status`, never anything else.
// `nextSwitchTarget` itself is pure (no `Date()`/`Calendar.current` read inside; `now`/`calendar` are
// always parameters — repo convention, see `VolarCore.nextTask`'s and `TaskSections.swift`'s own doc
// comments), so it is tested directly with no `AppState` involved at all for the pure-function cases.
//
// UNVERIFIED (written entirely on Windows — no Xcode/simulator available here): confirm on Mac that
// `xcodegen generate` + `xcodebuild test` discovers and runs this file under the `VolarTests`
// target, same as every other file already in this directory.
import Foundation
import XCTest
import VolarCore
@testable import Volar

@MainActor
final class FocusSwitchTests: XCTestCase {

    // MARK: - Deterministic time fixture (nothing here reads the system clock)

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The exact `UserDefaults` key `AppState` persists `switchBreakdownOffered` under (private to
    /// that file, so duplicated here rather than exposed) — same "know the literal key, not a
    /// symbol, and clean it in setUp/tearDown" convention `TourFlowTests.swift`'s `hasSeenTourKey`
    /// already establishes, needed here because the FR-030 "never re-offer" rule is specifically a
    /// claim about surviving BETWEEN test runs / app launches.
    private nonisolated static let switchBreakdownOfferedKey = "volar.switchBreakdownOffered"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.switchBreakdownOfferedKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.switchBreakdownOfferedKey)
        super.tearDown()
    }

    private func makeTask(
        id: UUID = UUID(),
        title: String,
        priority: Priority = .medium,
        status: TaskStatus = .todo,
        conditions: [VolarCore.Condition] = [],
        when: When = .now,
        parentId: UUID? = nil,
        sourceTranscript: String? = nil,
        switchAwayCount: Int = 0
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: title,
            priority: priority,
            status: status,
            conditions: conditions,
            createdAt: Self.now.addingTimeInterval(-3600),
            when: when,
            sourceTranscript: sourceTranscript,
            switchAwayCount: switchAwayCount,
            parentId: parentId
        )
    }

    // MARK: - `AppState.nextSwitchTarget` (pure)

    /// The everyday case: three open tasks, current is whichever `nextTask` itself would pick
    /// (highest priority); excluding it, the function must fall through to the engine's OWN next
    /// pick among what's left, not some ad hoc "next in list" rule.
    func testNextSwitchTargetPicksTheEngineWinnerAmongTheRemaining() {
        let taskA = makeTask(title: "A", priority: .high)
        let taskB = makeTask(title: "B", priority: .medium)
        let taskC = makeTask(title: "C", priority: .low)

        let result = AppState.nextSwitchTarget(
            excluding: taskA.id,
            from: [taskA, taskB, taskC],
            now: Self.now,
            calendar: Self.utc
        )

        XCTAssertEqual(result?.id, taskB.id, "B is the engine's own pick once A is excluded — C must lose on priority")
    }

    /// Edge case explicitly called out in the contract: exactly one open task, and it's the current
    /// one. There is nothing left to switch to, so this must return `nil`, not crash or fall back to
    /// re-selecting the excluded task itself.
    func testNextSwitchTargetReturnsNilWhenCurrentIsTheOnlyOpenTask() {
        let onlyTask = makeTask(title: "Solo")

        let result = AppState.nextSwitchTarget(
            excluding: onlyTask.id,
            from: [onlyTask],
            now: Self.now,
            calendar: Self.utc
        )

        XCTAssertNil(result)
    }

    /// Edge case explicitly called out in the contract: zero open tasks at all. Defensive — the
    /// real call sites (`AppState.focusSwitchCandidate()`/`dashboardSwitchCandidate()`) already
    /// guard non-empty before ever calling this, but the pure function itself must stay total
    /// (never force-unwrap into a crash) for an empty snapshot.
    func testNextSwitchTargetReturnsNilForEmptySnapshot() {
        let result = AppState.nextSwitchTarget(
            excluding: UUID(),
            from: [],
            now: Self.now,
            calendar: Self.utc
        )

        XCTAssertNil(result)
    }

    /// The one OTHER open task exists but is currently ineligible (a future `.afterDate` gate) —
    /// this must still return `nil`, proving the function actually re-runs full engine eligibility
    /// on the filtered snapshot rather than just "whatever's left after removing current".
    func testNextSwitchTargetReturnsNilWhenTheOnlyRemainingTaskIsIneligible() {
        let current = makeTask(title: "Current")
        let blocked = makeTask(
            title: "Blocked",
            conditions: [.afterDate(Self.now.addingTimeInterval(86_400))]
        )

        let result = AppState.nextSwitchTarget(
            excluding: current.id,
            from: [current, blocked],
            now: Self.now,
            calendar: Self.utc
        )

        XCTAssertNil(result, "the only remaining task is gated by a future afterDate — not eligible yet")
    }

    // MARK: - `AppState.switchFocusTask()` / `canSwitchFocusTask` (FocusOverlay path)

    /// The everyday case at the `AppState` layer: focus moves to the replacement, AND the task
    /// being left changes in EXACTLY one field — `switchAwayCount` goes from 0 to 1 — never
    /// `status`, never anything else.
    func testSwitchFocusTaskMovesFocusAndOnlyBumpsSwitchAwayCountOnTheOldTask() {
        let taskA = makeTask(title: "A", priority: .high)
        let taskB = makeTask(title: "B", priority: .medium)
        let taskC = makeTask(title: "C", priority: .low)
        var expectedA = taskA
        expectedA.switchAwayCount = 1

        let state = AppState(tasks: [taskA, taskB, taskC], clock: { Self.now })
        state.focusActive = true
        state.focusIndex = 0 // openTasks == [A, B, C]; index 0 is A

        state.switchFocusTask()

        XCTAssertEqual(state.openTasks[state.focusIndex].id, taskB.id, "must land on B, the engine's pick once A is excluded")
        let storedA = state.tasks.first { $0.id == taskA.id }
        XCTAssertEqual(storedA, expectedA, "the only change on the left task must be switchAwayCount 0 -> 1 — no status flip, nothing else")
        let storedB = state.tasks.first { $0.id == taskB.id }
        XCTAssertEqual(storedB?.switchAwayCount, 0, "the task being switched TO must not have its own counter touched")
    }

    /// Edge case: exactly one open task. `canSwitchFocusTask` must report false (drives the button's
    /// disabled state), and calling `switchFocusTask()` anyway must be a complete no-op — including
    /// `switchAwayCount`, which must NOT increment for an action that didn't actually switch anything.
    func testSwitchIsUnavailableAndANoOpWithExactlyOneOpenTask() {
        let onlyTask = makeTask(title: "Solo")
        let original = onlyTask

        let state = AppState(tasks: [onlyTask], clock: { Self.now })
        state.focusActive = true
        state.focusIndex = 0

        XCTAssertFalse(state.canSwitchFocusTask)

        state.switchFocusTask()

        XCTAssertEqual(state.focusIndex, 0)
        XCTAssertEqual(state.tasks.first { $0.id == onlyTask.id }, original, "a true no-op must not touch switchAwayCount either")
    }

    /// Edge case: a second open task exists but is ineligible (future `.afterDate`) — same
    /// "unavailable, no-op" behavior as the single-task case, including `switchAwayCount`.
    func testSwitchIsUnavailableAndANoOpWhenTheOnlyOtherTaskIsIneligible() {
        let current = makeTask(title: "Current")
        let blocked = makeTask(title: "Blocked", conditions: [.afterDate(Self.now.addingTimeInterval(86_400))])
        let originalCurrent = current

        let state = AppState(tasks: [current, blocked], clock: { Self.now })
        state.focusActive = true
        state.focusIndex = 0

        XCTAssertFalse(state.canSwitchFocusTask)

        state.switchFocusTask()

        XCTAssertEqual(state.focusIndex, 0)
        XCTAssertEqual(state.tasks.first { $0.id == current.id }, originalCurrent)
    }

    /// Re-entry data (FR-030's "last step, resume note, transcript" list) is never invented, only
    /// ever the task's own existing fields — this pins that `sourceTranscript` survives a
    /// switch-away round trip completely unchanged, since `FocusOverlay` reads it directly off the
    /// stored `TaskItem`.
    func testSourceTranscriptSurvivesASwitchRoundTripUnchanged() {
        let taskA = makeTask(title: "A", priority: .high, sourceTranscript: "call the dentist tomorrow")
        let taskB = makeTask(title: "B", priority: .medium)

        let state = AppState(tasks: [taskA, taskB], clock: { Self.now })
        state.focusActive = true
        state.focusIndex = 0

        state.switchFocusTask()

        XCTAssertEqual(state.tasks.first { $0.id == taskA.id }?.sourceTranscript, "call the dentist tomorrow")
    }

    // MARK: - `AppState.switchDashboardActiveTask()` / `canSwitchDashboardActiveTask` (TodayView path)

    /// The dashboard hero card's own Switch: `dashboardActiveTask` moves to the replacement, the
    /// RAW engine `activeTask` stays exactly what it always was (still A — nothing about A's data
    /// changed, so the engine still picks it first), and A only gains the same one-field
    /// `switchAwayCount` bump as the `FocusOverlay` path. This is the key proof that
    /// `dashboardActiveTask` is a genuinely separate, additive layer, not a rewrite of `activeTask`.
    func testSwitchDashboardActiveTaskOverridesTheHeroCardWithoutTouchingActiveTaskItself() {
        let taskA = makeTask(title: "A", priority: .high)
        let taskB = makeTask(title: "B", priority: .medium)
        let taskC = makeTask(title: "C", priority: .low)
        var expectedA = taskA
        expectedA.switchAwayCount = 1

        let state = AppState(tasks: [taskA, taskB, taskC], clock: { Self.now })

        XCTAssertEqual(state.dashboardActiveTask?.id, taskA.id, "no override yet — same as the engine's own pick")

        state.switchDashboardActiveTask()

        XCTAssertEqual(state.dashboardActiveTask?.id, taskB.id, "the hero card must now show B")
        XCTAssertEqual(state.activeTask?.id, taskA.id, "the raw engine pick is UNCHANGED — still A, since A's own data never changed")
        XCTAssertEqual(state.tasks.first { $0.id == taskA.id }, expectedA, "A only gains switchAwayCount 0 -> 1, nothing else")
    }

    /// Edge case at the dashboard layer, mirroring the `FocusOverlay` one: exactly one open task
    /// means nothing to switch to — `canSwitchDashboardActiveTask` false, and the call is a no-op.
    func testDashboardSwitchIsUnavailableAndANoOpWithExactlyOneOpenTask() {
        let onlyTask = makeTask(title: "Solo")

        let state = AppState(tasks: [onlyTask], clock: { Self.now })

        XCTAssertFalse(state.canSwitchDashboardActiveTask)

        state.switchDashboardActiveTask()

        XCTAssertEqual(state.dashboardActiveTask?.id, onlyTask.id)
        XCTAssertEqual(state.tasks.first { $0.id == onlyTask.id }, onlyTask)
    }

    // MARK: - FR-030: ≥3 switches away from the SAME task → one-time breakdown suggestion

    /// The load-bearing FR-030 behavior: switching away from the SAME task three times (moving
    /// focus back onto it between each switch, exactly like using ←/→ to return to it would) arms
    /// `switchBreakdownSuggestion` the moment the THIRD switch lands — not the first, not the
    /// second — and a fourth switch-away must NOT re-arm it a second time, even though the count
    /// keeps climbing.
    func testThirdSwitchAwayArmsTheBreakdownSuggestionExactlyOnceNotAFourthTime() {
        let taskA = makeTask(title: "A", priority: .high)
        let taskB = makeTask(title: "B", priority: .medium)

        let state = AppState(tasks: [taskA, taskB], clock: { Self.now })
        state.focusActive = true
        state.focusIndex = 0 // A

        state.switchFocusTask() // A: 0 -> 1, lands on B
        XCTAssertNil(state.switchBreakdownSuggestion, "not yet — only 1 switch away")
        state.focusIndex = state.openTasks.firstIndex { $0.id == taskA.id }! // back onto A

        state.switchFocusTask() // A: 1 -> 2
        XCTAssertNil(state.switchBreakdownSuggestion, "not yet — only 2 switches away")
        state.focusIndex = state.openTasks.firstIndex { $0.id == taskA.id }!

        state.switchFocusTask() // A: 2 -> 3 — crosses the threshold
        XCTAssertEqual(state.switchBreakdownSuggestion?.id, taskA.id, "the 3rd switch away from A must arm the invite for A")
        XCTAssertEqual(state.tasks.first { $0.id == taskA.id }?.switchAwayCount, 3)

        // Simulate the user never answering (banner still on screen) and switching away a 4th time.
        state.focusIndex = state.openTasks.firstIndex { $0.id == taskA.id }!
        state.switchFocusTask() // A: 3 -> 4
        XCTAssertEqual(state.tasks.first { $0.id == taskA.id }?.switchAwayCount, 4, "the count itself keeps climbing")
        XCTAssertEqual(state.switchBreakdownSuggestion?.id, taskA.id, "still A's pending suggestion — not cleared, but also not a SECOND fresh offer")
    }

    /// Declining ("Not now") just closes the banner — no re-arm, ever, for this task, even on a
    /// later switch-away.
    func testDismissingTheSuggestionNeverReoffersForTheSameTask() {
        let taskA = makeTask(title: "A", priority: .high, switchAwayCount: 2)
        let taskB = makeTask(title: "B", priority: .medium)

        let state = AppState(tasks: [taskA, taskB], clock: { Self.now })
        state.focusActive = true
        state.focusIndex = 0

        state.switchFocusTask() // A: 2 -> 3, arms the suggestion
        XCTAssertEqual(state.switchBreakdownSuggestion?.id, taskA.id)

        state.dismissSwitchBreakdownSuggestion()
        XCTAssertNil(state.switchBreakdownSuggestion)

        state.focusIndex = state.openTasks.firstIndex { $0.id == taskA.id }!
        state.switchFocusTask() // A: 3 -> 4
        XCTAssertNil(state.switchBreakdownSuggestion, "declined once — must never come back for this task")
    }

    /// Accepting routes straight into the EXISTING breakdown flow (`openBreakdown(for:)`) rather
    /// than inventing a second mechanism — this pins that `breakdownTask`/`showBreakdown` (the
    /// state `TaskBreakdownView`'s existing sheet already renders off) get set, and the suggestion
    /// itself is cleared.
    func testAcceptingTheSuggestionOpensTheExistingBreakdownFlow() {
        let task = makeTask(title: "Big vague task")
        let state = AppState(tasks: [task], clock: { Self.now })
        state.switchBreakdownSuggestion = task // arm directly — the arming path itself is covered above

        state.acceptSwitchBreakdownSuggestion()

        XCTAssertNil(state.switchBreakdownSuggestion)
        XCTAssertEqual(state.breakdownTask?.id, task.id)
        XCTAssertTrue(state.showBreakdown)
    }

    /// FR-030's "bền qua restart" requirement: the "already offered" record must survive past the
    /// `AppState` instance that armed it — proxying a real app relaunch (which would reconstruct a
    /// brand-new `AppState`) with a SECOND, independently-constructed instance. `switchAwayCount`
    /// itself isn't persisted in this no-store test fixture (that durability is `TaskStore`'s job,
    /// exercised by the store-backed `mergeIntoExisting` path, not re-tested here) — this test seeds
    /// the count directly on each instance's `TaskItem` to simulate "a previous session already
    /// persisted count == N", and asserts ONLY the "already offered" gate, which really is backed by
    /// real `UserDefaults` in both instances.
    func testBreakdownOfferedFlagSurvivesAFreshAppStateInstanceLikeARestart() {
        let taskB = makeTask(title: "B", priority: .medium)

        // Session 1: task X already at count 2 (simulating two prior switches); one more switch
        // crosses the threshold and records X as offered — into REAL UserDefaults, not this
        // instance's own memory.
        let taskXSession1 = makeTask(title: "X", priority: .high, switchAwayCount: 2)
        let session1 = AppState(tasks: [taskXSession1, taskB], clock: { Self.now })
        session1.focusActive = true
        session1.focusIndex = 0
        session1.switchFocusTask()
        XCTAssertEqual(session1.switchBreakdownSuggestion?.id, taskXSession1.id, "sanity: session 1 must have armed it")

        // Session 2: a FRESH AppState — simulating a relaunch. Seed X at count 3 (what a real
        // TaskStore would have persisted from session 1) so this session's own switch-away brings
        // it to 4 and re-checks the (separately, really) persisted "already offered" gate.
        let taskXSession2 = makeTask(id: taskXSession1.id, title: "X", priority: .high, switchAwayCount: 3)
        let session2 = AppState(tasks: [taskXSession2, taskB], clock: { Self.now })
        XCTAssertNil(session2.switchBreakdownSuggestion, "constructing AppState must never auto-arm anything by itself")

        session2.focusActive = true
        session2.focusIndex = 0
        session2.switchFocusTask() // X: 3 -> 4

        XCTAssertEqual(session2.tasks.first { $0.id == taskXSession1.id }?.switchAwayCount, 4)
        XCTAssertNil(session2.switchBreakdownSuggestion, "X was already offered in session 1 — a fresh AppState instance must still honor that and never re-arm")
    }
}
