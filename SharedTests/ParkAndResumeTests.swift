// Tests/ParkAndResumeTests.swift — "đang làm A, B chen ngang, quay lại A" (anh Khôi 2026-09-06).
//
// Covers the three pieces that carry real branching: `focusTaskNow` (park + pin), the
// `toggleDone`-driven `resumeParkedTaskIfNeeded` (hand the spotlight back, but ONLY for the task
// that actually interrupted), and `setResumeNote`'s trim/nil normalization.
//
// No-store `AppState()` throughout — same "the no-argument initializer degrades to the in-memory
// fallback, which is all these need" split `CaptureHotkeyAndTitleEditTests` already documents.
//
// UNVERIFIED (written on Windows — no Xcode here): not run against a real `VolarTests` bundle.
import XCTest
@testable import Volar

@MainActor
final class ParkAndResumeTests: XCTestCase {

    private func makeTask(_ title: String, priority: Priority = .medium) -> TaskItem {
        TaskItem(title: title, priority: priority, when: .now)
    }

    /// Two open tasks, `a` spotlit by the engine (or by an explicit pin), `b` the interruption.
    private func makeState(_ tasks: [TaskItem]) -> AppState {
        AppState(tasks: tasks)
    }

    // MARK: - focusTaskNow

    func testFocusTaskNowPinsTheTargetAndParksWhatWasSpotlit() {
        let a = makeTask("Write the deck")
        let b = makeTask("Call the client")
        let state = makeState([a, b])
        // Pin A explicitly rather than assuming which of two equal tasks the engine spotlights —
        // this is "the one I'm working on" regardless of ranking.
        state.focusTaskNow(a.id)

        state.focusTaskNow(b.id)

        XCTAssertEqual(state.dashboardActiveTask?.id, b.id, "the named task must become the active one")
        XCTAssertEqual(state.parkedTaskID, a.id, "whatever was spotlit must be remembered, not forgotten")
        XCTAssertEqual(state.tasks.first { $0.id == a.id }?.switchAwayCount, 1, "leaving a task must go through the same `recordSwitchAway` Switch uses")
    }

    func testFocusTaskNowOnTheAlreadySpotlitTaskParksNothing() {
        // One task, so "what is spotlit" is not an engine-ranking question.
        let a = makeTask("Write the deck")
        let state = makeState([a])

        state.focusTaskNow(a.id)

        XCTAssertEqual(state.dashboardActiveTask?.id, a.id)
        XCTAssertNil(state.parkedTaskID, "a task must never be parked on top of itself")
    }

    func testFocusTaskNowIgnoresAnUnknownID() {
        let state = makeState([makeTask("Write the deck")])
        state.focusTaskNow(UUID())

        XCTAssertNil(state.parkedTaskID)
    }

    // MARK: - resume on completion

    func testFinishingTheInterruptionHandsTheSpotlightBack() {
        let a = makeTask("Write the deck")
        let b = makeTask("Call the client")
        let state = makeState([a, b])
        state.focusTaskNow(a.id)
        state.focusTaskNow(b.id)

        state.toggleDone(b.id)

        XCTAssertEqual(state.dashboardActiveTask?.id, a.id, "finishing the interruption must return to the parked task")
        XCTAssertNil(state.parkedTaskID, "the slot must clear so the next completion doesn't re-trigger it")
    }

    func testTickingAnUnrelatedTaskDoesNotYankTheSpotlight() {
        let a = makeTask("Write the deck")
        let b = makeTask("Call the client")
        let c = makeTask("Water the plants")
        let state = makeState([a, b, c])
        state.focusTaskNow(a.id)
        state.focusTaskNow(b.id)

        state.toggleDone(c.id)

        XCTAssertEqual(state.dashboardActiveTask?.id, b.id, "an unrelated tick must leave the interruption in place")
        XCTAssertEqual(state.parkedTaskID, a.id)
    }

    func testAParkedTaskThatIsGoneJustDropsThePin() {
        let a = makeTask("Write the deck")
        let b = makeTask("Call the client")
        let state = makeState([a, b])
        state.focusTaskNow(a.id)
        state.focusTaskNow(b.id)
        state.toggleDone(a.id)   // the parked task got finished some other way (voice-done, sweep…)

        state.toggleDone(b.id)

        XCTAssertNil(state.parkedTaskID)
        XCTAssertNotEqual(state.dashboardActiveTask?.id, a.id, "must never pin a task that is no longer open")
    }

    // MARK: - setResumeNote

    func testSetResumeNoteTrimsAndStoresTheLine() {
        let a = makeTask("Write the deck")
        let state = makeState([a])

        state.setResumeNote(a.id, "  stuck on slide 4  ")

        XCTAssertEqual(state.tasks.first { $0.id == a.id }?.resumeNote, "stuck on slide 4")
    }

    func testSetResumeNoteClearsOnBlankInput() {
        let a = makeTask("Write the deck")
        let state = makeState([a])
        state.setResumeNote(a.id, "stuck on slide 4")

        state.setResumeNote(a.id, "   ")

        XCTAssertNil(state.tasks.first { $0.id == a.id }?.resumeNote, "an emptied field must clear the note, not store whitespace")
    }

    // MARK: - Automatic breadcrumb on park (anh Khôi chốt 2026-09-06)

    func testParkingWritesABreadcrumbWhenNothingIsWrittenDownYet() {
        let a = makeTask("Write the deck")
        let b = makeTask("Call the client")
        let state = makeState([a, b])
        state.focusTaskNow(a.id)

        state.focusTaskNow(b.id)

        let note = state.tasks.first { $0.id == a.id }?.resumeNote
        XCTAssertNotNil(note, "coming back to a blank stare is the thing this exists to prevent")
        XCTAssertTrue(note?.hasPrefix("Paused ") == true, "the breadcrumb must say when it stopped")
        XCTAssertTrue(note?.contains("Call the client") == true, "…and what it stopped for")
    }

    func testParkingNeverOverwritesANoteTheUserWrote() {
        let a = makeTask("Write the deck")
        let b = makeTask("Call the client")
        let state = makeState([a, b])
        state.focusTaskNow(a.id)
        state.setResumeNote(a.id, "stuck on slide 4")

        state.focusTaskNow(b.id)

        XCTAssertEqual(
            state.tasks.first { $0.id == a.id }?.resumeNote,
            "stuck on slide 4",
            "a generated line must never clobber what the user typed"
        )
    }

    // MARK: - Dependency park & resume ("A chờ B xong mới làm tiếp" — anh Khôi 2026-09-06)
    //
    // Store-backed (`addTaskDependency` needs a real `TaskStore` to validate + persist the
    // `.taskDone` edge), same `TaskStore(inMemory: true)` convention `TaskDependencyStoreTests`
    // already uses.

    private func makeStoreState(_ tasks: [TaskItem]) throws -> (AppState, TaskStore) {
        let store = try TaskStore(inMemory: true)
        try store.addBatch(tasks)
        return (AppState(store: store), store)
    }

    func testBlockingTheSpotlitTaskParksItAndFinishingTheBlockerHandsItBack() throws {
        let a = makeTask("Ship the release")
        let b = makeTask("Get legal sign-off")
        let (state, _) = try makeStoreState([a, b])
        state.focusTaskNow(a.id)

        XCTAssertNil(state.addTaskDependency(a.id, dependsOn: b.id), "a plain A-waits-on-B edge must be accepted")
        XCTAssertEqual(state.parkedTaskID, a.id, "the task that just became blocked must be set aside, not left pinned")
        XCTAssertNotEqual(state.dashboardActiveTask?.id, a.id, "a blocked task must stop being the one on screen")

        state.toggleDone(b.id)

        XCTAssertEqual(state.dashboardActiveTask?.id, a.id, "finishing the blocker must hand the spotlight straight back")
        XCTAssertNil(state.parkedTaskID, "the slot must be released once it has been handed back")
    }

    func testFinishingAnUnrelatedTaskLeavesTheBlockedTaskParked() throws {
        let a = makeTask("Ship the release")
        let b = makeTask("Get legal sign-off")
        let c = makeTask("Water the plants")
        let (state, _) = try makeStoreState([a, b, c])
        state.focusTaskNow(a.id)
        XCTAssertNil(state.addTaskDependency(a.id, dependsOn: b.id))

        state.toggleDone(c.id)

        XCTAssertEqual(state.parkedTaskID, a.id, "only the thing A was waiting on may wake A up")
        XCTAssertNotEqual(state.dashboardActiveTask?.id, a.id)
    }

    func testDeletingTheBlockerAlsoHandsTheParkedTaskBack() throws {
        let a = makeTask("Ship the release")
        let b = makeTask("Get legal sign-off")
        let (state, _) = try makeStoreState([a, b])
        state.focusTaskNow(a.id)
        XCTAssertNil(state.addTaskDependency(a.id, dependsOn: b.id))

        state.deleteTask(b.id)

        XCTAssertEqual(state.dashboardActiveTask?.id, a.id, "a blocker that no longer exists frees A exactly like a finished one")
        XCTAssertNil(state.parkedTaskID)
    }

    func testBlockingATaskThatIsNotSpotlitParksNothing() throws {
        let a = makeTask("Ship the release")
        let b = makeTask("Get legal sign-off")
        let c = makeTask("Water the plants")
        let (state, _) = try makeStoreState([a, b, c])
        state.focusTaskNow(c.id)

        XCTAssertNil(state.addTaskDependency(a.id, dependsOn: b.id))

        XCTAssertNil(state.parkedTaskID, "adding a dependency to some background task must not hijack the spotlight slot")
        XCTAssertEqual(state.dashboardActiveTask?.id, c.id)
    }
}
