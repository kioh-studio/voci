// Tests/TaskUpdateTests.swift — XCTest coverage for `TaskStore.updateEditableFields(from:)`
// (specs/002-workflow-command-center/contracts/manual-edit-contract.md §1.3): confirms it writes
// exactly the 7 user-editable fields (title/details/notes/priority/startTime/deadline/
// durationMinutes/reminderOverride) and leaves `conditions`/`parentId`/`status`/`createdAt`
// untouched even when the `TaskItem` passed in carries DIFFERENT values for those four — that is
// exactly the failure mode `VolarTask.apply(_:)` would introduce (see
// `TaskStore.updateEditableFields`'s own doc comment for why it deliberately does not reuse
// `apply`, unlike `mergeIntoExisting`, which earns the right to by re-validating first).
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here): confirm
// on Mac that `xcodegen generate` + `xcodebuild test` discovers and runs this file under the
// `VolarTests` target, same as every other file already in this directory (matches
// `StartTimePersistenceTests.swift`'s own note).
import Foundation
import XCTest
import VolarCore
@testable import Volar

@MainActor
final class TaskUpdateTests: XCTestCase {

    private func makeStore() throws -> TaskStore {
        try TaskStore(inMemory: true)
    }

    /// 1. Every one of the 7 editable fields actually lands after `updateEditableFields` + a
    /// reload through the store (`TaskItem` -> `VolarTask` -> `TaskItem`, same round-trip shape
    /// `StartTimePersistenceTests` uses).
    func testUpdateEditableFieldsWritesAllSevenFields() throws {
        let store = try makeStore()
        let original = TaskItem(
            title: "Original title",
            details: "Original details",
            priority: .low,
            deadline: Date().addingTimeInterval(3600),
            when: .later,
            durationMinutes: 30,
            notes: "Original details"
        )
        store.add(original)

        let newDeadline = Date().addingTimeInterval(7200)
        let newStartTime = Date().addingTimeInterval(120)
        let newReminder = ReminderPolicy(
            offsets: [0], repeatEvery: nil, fractionsRemaining: [], remindPeriod: 7200
        )

        var edited = original
        edited.title = "Edited title"
        edited.details = "Edited details"
        edited.notes = "Edited details"
        edited.priority = .high
        edited.startTime = newStartTime
        edited.deadline = newDeadline
        edited.durationMinutes = 90
        edited.reminderOverride = newReminder

        XCTAssertTrue(store.updateEditableFields(from: edited))

        let reloaded = try XCTUnwrap(store.fetchAll().first { $0.id == original.id })
        XCTAssertEqual(reloaded.title, "Edited title")
        XCTAssertEqual(reloaded.details, "Edited details")
        XCTAssertEqual(reloaded.notes, "Edited details")
        XCTAssertEqual(reloaded.priority, .high)
        XCTAssertEqual(reloaded.startTime, newStartTime)
        XCTAssertEqual(reloaded.deadline, newDeadline)
        XCTAssertEqual(reloaded.durationMinutes, 90)
        XCTAssertEqual(reloaded.reminderOverride, newReminder)
    }

    /// 2. An id that was never persisted returns `false` and (implicitly, since nothing was ever
    /// inserted) touches nothing.
    func testUpdateEditableFieldsReturnsFalseForUnknownId() throws {
        let store = try makeStore()
        let phantom = TaskItem(title: "Never persisted", priority: .medium, when: .now)
        XCTAssertFalse(store.updateEditableFields(from: phantom))
    }

    /// 3. THE invariant this method exists to protect (§1.3): `conditions`/`parentId`/`status`/
    /// `createdAt` must survive an edit untouched, even when the `TaskItem` handed to
    /// `updateEditableFields` carries DIFFERENT values for all four — a manual 7-field edit has no
    /// validated snapshot to re-check a changed `.taskDone` DAG or parent/child graph against, so
    /// it must never be able to smuggle a change to any of them through this path. Poisons every
    /// guarded field alongside a legitimate edit to one of the real 7 (title), so a bug that writes
    /// SOME but not all of the guarded fields would still be caught.
    func testUpdateEditableFieldsDoesNotTouchInvariantFields() throws {
        let store = try makeStore()

        let parent = TaskItem(title: "Parent task", priority: .medium, when: .later)
        store.add(parent)

        let fixedCreatedAt = Date().addingTimeInterval(-86_400)
        let child = TaskItem(
            title: "Child task",
            priority: .medium,
            status: .done,
            conditions: [.external(description: "waiting on legal", satisfied: false)],
            createdAt: fixedCreatedAt,
            when: .later,
            completedAt: Date(),
            parentId: parent.id
        )
        store.add(child)

        var poisoned = child
        poisoned.title = "Renamed child" // one of the real 7 — must still write through
        poisoned.conditions = [] // would silently erase the external condition if honored
        poisoned.status = .todo // would silently un-complete the task if honored
        poisoned.createdAt = Date() // would silently rewrite history if honored
        poisoned.parentId = nil // would silently orphan the child if honored

        XCTAssertTrue(store.updateEditableFields(from: poisoned))

        let reloaded = try XCTUnwrap(store.fetchAll().first { $0.id == child.id })
        XCTAssertEqual(reloaded.title, "Renamed child", "the 7 legit fields must still write through")
        XCTAssertEqual(reloaded.conditions, [.external(description: "waiting on legal", satisfied: false)])
        XCTAssertEqual(reloaded.status, .done)
        XCTAssertEqual(reloaded.createdAt, fixedCreatedAt)
        XCTAssertEqual(reloaded.parentId, parent.id)
    }

    /// New tasks must persist `cue` (it was dropped by `insertSanitized`).
    func testAddPersistsCue() throws {
        let store = try makeStore()
        let now = Date()
        let cue = TaskCue(kind: .wake, verbatim: "when I wake up", createdAt: now, expiresAt: TaskCue.defaultExpiry(from: now))
        var item = TaskItem(title: "Cued", priority: .medium, when: .now)
        item.cue = cue
        store.add(item)
        XCTAssertEqual(store.fetchAll().first?.cue, cue)
    }
}
