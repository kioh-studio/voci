// Tests/CalendarSyncTests.swift — XCTest coverage for `Sources/Integrations/CalendarSync.swift`
// (one-way task -> "Volar" calendar mirroring; see that file's header for the two ownership guards
// this test file leans on the STATIC, EventKit-free halves of).
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here):
//   1. Confirm on Mac that `CalendarSyncTests` builds and runs under the `VolarTests` target.
//   2. Nothing here exercises `ensureVolarCalendar()`, `reconcile(tasks:)`, or
//      `removeAllMirroredEvents()` against a real `EKEventStore` — doing so would need a live,
//      authorized calendar source and would create/delete real calendar data on whatever machine
//      runs the suite. Only the pure `static func` helpers those methods are built from are tested
//      here (`isDesired`, `eventWindow`, `markerURL(forTaskID:)`/`taskID(fromMarkerURL:)`) — the
//      same reasoning `CalendarAccessTests.swift` uses to skip `requestAccess()`.
import XCTest
@testable import Volar

@MainActor
final class CalendarSyncTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTask(
        title: String = "Test task",
        status: TaskStatus = .todo,
        deadline: Date? = Date(),
        durationMinutes: Int? = nil
    ) -> TaskItem {
        TaskItem(title: title, priority: .medium, status: status, deadline: deadline, when: .later, durationMinutes: durationMinutes)
    }

    // MARK: - isDesired (the mirror-eligibility predicate)

    func testIsDesiredIncludesOpenDatedTask() {
        let task = makeTask(status: .todo, deadline: Date())
        XCTAssertTrue(CalendarSync.isDesired(task))
    }

    func testIsDesiredExcludesDoneTask() {
        let task = makeTask(status: .done, deadline: Date())
        XCTAssertFalse(CalendarSync.isDesired(task), "a done task must never keep a mirrored event")
    }

    func testIsDesiredExcludesUndatedTask() {
        let task = makeTask(status: .todo, deadline: nil)
        XCTAssertFalse(CalendarSync.isDesired(task), "nothing to anchor an event to without a deadline")
    }

    func testIsDesiredExcludesDoneAndUndatedTask() {
        let task = makeTask(status: .done, deadline: nil)
        XCTAssertFalse(CalendarSync.isDesired(task))
    }

    // MARK: - eventWindow (deadline + duration -> start/end)

    func testEventWindowUsesExplicitPositiveDuration() {
        let deadline = Date()
        let (start, end) = CalendarSync.eventWindow(deadline: deadline, durationMinutes: 45)
        XCTAssertEqual(start, deadline)
        XCTAssertEqual(end, deadline.addingTimeInterval(45 * 60))
    }

    func testEventWindowDefaultsToThirtyMinutesWhenDurationIsNil() {
        let deadline = Date()
        let (start, end) = CalendarSync.eventWindow(deadline: deadline, durationMinutes: nil)
        XCTAssertEqual(start, deadline)
        XCTAssertEqual(end, deadline.addingTimeInterval(30 * 60))
    }

    func testEventWindowDefaultsToThirtyMinutesWhenDurationIsZero() {
        let deadline = Date()
        let (_, end) = CalendarSync.eventWindow(deadline: deadline, durationMinutes: 0)
        XCTAssertEqual(end, deadline.addingTimeInterval(30 * 60))
    }

    func testEventWindowDefaultsToThirtyMinutesWhenDurationIsNegative() {
        let deadline = Date()
        let (_, end) = CalendarSync.eventWindow(deadline: deadline, durationMinutes: -15)
        XCTAssertEqual(end, deadline.addingTimeInterval(30 * 60), "a negative duration is nonsensical input, must not produce an end before the start")
    }

    // MARK: - ownership-marker URL round-trip

    func testMarkerURLRoundTripsToTheSameTaskID() {
        let taskID = UUID()
        guard let url = CalendarSync.markerURL(forTaskID: taskID) else {
            return XCTFail("markerURL(forTaskID:) must always succeed for a valid UUID")
        }
        XCTAssertEqual(url.scheme, "volar")
        XCTAssertEqual(url.host, "task")
        XCTAssertEqual(CalendarSync.taskID(fromMarkerURL: url), taskID)
    }

    func testTaskIDFromMarkerURLRejectsWrongScheme() {
        let taskID = UUID()
        let url = URL(string: "https://task/\(taskID.uuidString)")!
        XCTAssertNil(CalendarSync.taskID(fromMarkerURL: url), "only `volar://task/<uuid>` URLs are valid ownership markers")
    }

    func testTaskIDFromMarkerURLRejectsWrongHost() {
        let taskID = UUID()
        let url = URL(string: "volar://ai-done/\(taskID.uuidString)")!
        XCTAssertNil(CalendarSync.taskID(fromMarkerURL: url), "a differently-hosted volar:// URL (e.g. the ai-done app-link) must not parse as a task marker")
    }

    func testTaskIDFromMarkerURLRejectsGarbagePath() {
        let url = URL(string: "volar://task/not-a-uuid")!
        XCTAssertNil(CalendarSync.taskID(fromMarkerURL: url))
    }

    // MARK: - setMirrorEnabled (FIX 3: explicit setter replacing the former `didSet`-backed `var`)
    //
    // Only the persist/no-op shape is tested here — NOT the "turning mirroring off deletes every
    // mirrored event" behavior, since that runs through `removeAllMirroredEvents()` ->
    // `store.commit()` against a real `EKEventStore`, which is exactly the live-EventKit surface
    // this file's header says to avoid (would need a live, authorized calendar source, and would
    // create/delete real calendar data on whatever machine runs the suite). Constructing a fresh
    // `CalendarSync` here never touches EventKit either (`CalendarAccess.eventStore` allocates
    // lazily on first use — see that file's own doc comment — and `CalendarSync.init` never reads
    // it), so this is safe to run unconditionally in CI/on any machine.
    private nonisolated static let mirrorEnabledDefaultsKey = "volar.calendarMirrorEnabled"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.mirrorEnabledDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.mirrorEnabledDefaultsKey)
        super.tearDown()
    }

    func testSetMirrorEnabledDefaultsToFalse() {
        let sync = CalendarSync(access: CalendarAccess())
        XCTAssertFalse(sync.mirrorEnabled, "writing to the user's calendar must be opt-in, never on by default")
    }

    func testSetMirrorEnabledPersistsWhenChanged() {
        let sync = CalendarSync(access: CalendarAccess())
        sync.setMirrorEnabled(true)
        XCTAssertTrue(sync.mirrorEnabled)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Self.mirrorEnabledDefaultsKey))
    }

    func testSetMirrorEnabledNoOpsWhenUnchanged() {
        let sync = CalendarSync(access: CalendarAccess())
        // Already `false` at construction (fresh UserDefaults, cleaned in `setUp`) — setting it to
        // `false` again must be a genuine no-op (never write, never flip any other state) rather
        // than re-running the "turn mirroring off" path for a value that was never on.
        sync.setMirrorEnabled(false)
        XCTAssertFalse(sync.mirrorEnabled)
        XCTAssertNil(
            UserDefaults.standard.object(forKey: Self.mirrorEnabledDefaultsKey),
            "a no-op call must never write to UserDefaults at all, not even the same value"
        )
    }

    func testSetMirrorEnabledReflectsPersistedValueAcrossInstances() {
        let first = CalendarSync(access: CalendarAccess())
        first.setMirrorEnabled(true)
        // A second instance reading the same UserDefaults key (mirrors how a relaunch would
        // rehydrate `CalendarSync` from persisted state) must see the change.
        let second = CalendarSync(access: CalendarAccess())
        XCTAssertTrue(second.mirrorEnabled)
    }
}
