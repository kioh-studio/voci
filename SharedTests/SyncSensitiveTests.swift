// Tests/SyncSensitiveTests.swift — XCTest coverage for `VolarTask.isSensitive` crossing the sync
// seam (this task's own spec, layered on specs/008-sync/client-contract.md §2/§4): the wire-decode
// safe-default direction (`?? true`, the OPPOSITE of every other field on `TaskPayload`), the new
// `TaskStore.setSensitive` mutator, and that `applyRemote` writes the flag without re-marking the
// row pending (client-contract.md §4 — "cái bẫy chết người").
//
// Deliberately a NEW file, not an addition to `SyncPayloadTests.swift`/`SyncStoreTests.swift` — per
// this task's own instructions, those two are left untouched.
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here): confirm
// on Mac that `xcodebuild test` picks this file up and every assertion below still holds once
// compiled for real.
import XCTest
import Foundation
import VolarCore
@testable import Volar

@MainActor
final class SyncSensitiveTests: XCTestCase {
    private func makeStore() throws -> TaskStore {
        try TaskStore(inMemory: true)
    }

    // MARK: - TaskPayload round-trip: isSensitive survives both true and false

    func testTaskPayloadRoundTripPreservesIsSensitiveTrue() {
        let item = TaskItem(title: "sensitive task", priority: .medium, when: .later)
        let payload = TaskPayload(item, isSensitive: true)
        XCTAssertTrue(payload.isSensitive)
    }

    func testTaskPayloadRoundTripPreservesIsSensitiveFalse() {
        let item = TaskItem(title: "ordinary task", priority: .medium, when: .later)
        let payload = TaskPayload(item, isSensitive: false)
        XCTAssertFalse(payload.isSensitive)
    }

    func testTaskPayloadIsSensitiveSurvivesJSONRoundTrip() throws {
        for expected in [true, false] {
            let item = TaskItem(title: "round trip", priority: .medium, when: .later)
            let payload = TaskPayload(item, isSensitive: expected)

            let encoder = SyncCoding.makeEncoder()
            let data = try encoder.encode(payload)
            let decoder = SyncCoding.makeDecoder()
            let decoded = try decoder.decode(TaskPayload.self, from: data)

            XCTAssertEqual(decoded.isSensitive, expected, "isSensitive=\(expected) must survive an encode/decode round trip")
        }
    }

    // MARK: - 🔴 The safety-critical decode default: missing key on the wire -> `true`, never
    // `false`. This is the exact inverse of `title`/`frog`/`switchAwayCount`/every other field on
    // `TaskPayload`, which all fall back to their local-empty default — see this field's own doc
    // comment in SyncPayload.swift for why the direction flips here specifically.

    func testTaskPayloadDecodeWithIsSensitiveKeyEntirelyMissingDefaultsToTrue() throws {
        let id = UUID()
        let json: [String: Any] = [
            "id": id.uuidString,
            "createdAt": "2026-08-09T10:00:00.000000+00:00",
            // "isSensitive" deliberately OMITTED — simulates an older/other-platform client that
            // has never implemented this flag.
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoder = SyncCoding.makeDecoder()
        let payload = try decoder.decode(TaskPayload.self, from: data)

        XCTAssertTrue(payload.isSensitive, "a payload silent about isSensitive must decode to true — guess quiet, never guess loud")
    }

    func testTaskPayloadDecodeWithIsSensitiveExplicitFalsePreservesFalse() throws {
        // Guard against an over-eager "always true" bug: an EXPLICIT `false` on the wire must be
        // honored, not collapsed into the missing-key fallback.
        let id = UUID()
        let json: [String: Any] = [
            "id": id.uuidString,
            "createdAt": "2026-08-09T10:00:00.000000+00:00",
            "isSensitive": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoder = SyncCoding.makeDecoder()
        let payload = try decoder.decode(TaskPayload.self, from: data)

        XCTAssertFalse(payload.isSensitive)
    }

    // MARK: - TaskStore.setSensitive — the only mutator that can flip the flag

    func testSetSensitiveTrueMakesTheRowPendingWithTheFlagSet() throws {
        let store = try makeStore()
        let item = TaskItem(title: "needs protecting", priority: .medium, when: .later)
        store.add(item)

        // Start clean, same setup convention `SyncStoreTests` uses: simulate a confirmed push so
        // the row isn't pending purely because of the initial `add`.
        let firstPending = try XCTUnwrap(store.pendingForSync(limit: 100).first { $0.item.id == item.id })
        store.markSynced([item.id: (sent: firstPending.updatedAt, confirmed: firstPending.updatedAt)])
        XCTAssertTrue(store.pendingForSync(limit: 100).isEmpty)

        let changed = store.setSensitive(true, on: item.id)
        XCTAssertTrue(changed)

        let pending = try XCTUnwrap(store.pendingForSync(limit: 100).first { $0.item.id == item.id })
        XCTAssertTrue(pending.isSensitive, "PendingTask.isSensitive must reflect the just-set flag")
        XCTAssertTrue(store.isSensitive(item.id))
    }

    func testSetSensitiveWithUnchangedValueIsANoOpAndDoesNotMakeTheRowPending() throws {
        let store = try makeStore()
        // A brand-new task defaults to isSensitive == false (VolarTask.swift).
        let item = TaskItem(title: "already not sensitive", priority: .medium, when: .later)
        store.add(item)

        let firstPending = try XCTUnwrap(store.pendingForSync(limit: 100).first { $0.item.id == item.id })
        store.markSynced([item.id: (sent: firstPending.updatedAt, confirmed: firstPending.updatedAt)])
        XCTAssertTrue(store.pendingForSync(limit: 100).isEmpty)

        let changed = store.setSensitive(false, on: item.id)

        XCTAssertFalse(changed, "setting the flag to the value it already holds must be a no-op")
        XCTAssertTrue(
            store.pendingForSync(limit: 100).isEmpty,
            "a no-op setSensitive call must not churn the store into looking edited"
        )
    }

    func testSetSensitiveOnUnknownIdIsANoOp() throws {
        let store = try makeStore()
        XCTAssertFalse(store.setSensitive(true, on: UUID()))
    }

    // MARK: - applyRemote: writes the flag WITHOUT re-marking the row pending (client-contract.md
    // §4 — the exact bug that would make two devices ping-pong forever).

    func testApplyRemoteWritesIsSensitiveTrueAndLeavesTheRowNotPending() throws {
        let store = try makeStore()
        let id = UUID()
        let item = TaskItem(id: id, title: "a biopsy follow-up", priority: .medium, when: .later)

        let written = try store.applyRemote([
            RemoteTask(id: id, updatedAt: Date(), deletedAt: nil, item: item, isSensitive: true)
        ])

        XCTAssertEqual(written, [id])
        XCTAssertTrue(store.isSensitive(id), "applyRemote must actually write the incoming flag onto the local row")
        XCTAssertTrue(
            store.pendingForSync(limit: 100).isEmpty,
            "a row just pulled from the server must not be marked pending — re-stamping here is the LWW ping-pong bug (client-contract.md §4)"
        )
    }

    func testApplyRemoteWritesIsSensitiveFalseForANeverSeenId() throws {
        // Exercises the OTHER branch of applyRemote — inserting a row this device has never had —
        // making sure isSensitive is set there too, not just on the update-existing-row path.
        let store = try makeStore()
        let id = UUID()
        let item = TaskItem(id: id, title: "ordinary remote task", priority: .medium, when: .later)

        let written = try store.applyRemote([
            RemoteTask(id: id, updatedAt: Date(), deletedAt: nil, item: item, isSensitive: false)
        ])

        XCTAssertEqual(written, [id])
        XCTAssertFalse(store.isSensitive(id))
    }

    func testApplyRemoteUpdatesIsSensitiveOnAnAlreadyKnownRow() throws {
        let store = try makeStore()
        let id = UUID()
        store.add(TaskItem(id: id, title: "flip me", priority: .medium, when: .later))
        XCTAssertFalse(store.isSensitive(id), "a freshly-added task defaults to not sensitive")

        let farFuture = Date().addingTimeInterval(60 * 60 * 24 * 365 * 10)
        let remoteItem = TaskItem(id: id, title: "flip me", priority: .medium, when: .later)
        let written = try store.applyRemote([
            RemoteTask(id: id, updatedAt: farFuture, deletedAt: nil, item: remoteItem, isSensitive: true)
        ])

        XCTAssertEqual(written, [id], "a newer remote row must win LWW")
        XCTAssertTrue(store.isSensitive(id), "the LWW-winning remote row's isSensitive must overwrite the local value")
    }
}
