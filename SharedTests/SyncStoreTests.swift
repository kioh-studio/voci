// Tests/SyncStoreTests.swift — XCTest coverage for `TaskStore`'s `SyncTaskStoring` conformance
// (specs/008-sync/client-contract.md §2/§4/§4b/§5, design.md §5/§6/§7): stamping discipline,
// LWW, tombstones, the one-time `updatedAt` backfill, the single-frog invariant, and completion
// insert-if-absent — all driven through `TaskStore(inMemory: true)`'s PUBLIC surface only (no
// direct `ModelContext`/`VolarTask` access — those are private to `TaskStore.swift`, owned by
// group A).
//
// Group D (Test) — written against code already on disk by groups A/B/C
// (specs/008-sync/client-contract.md §0). Does NOT touch `Shared/Model/TaskStore.swift` or any
// other file outside `SharedTests/`.
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here): confirm
// on Mac that `xcodebuild test` picks this file up, that `TaskStore(inMemory: true)` behaves as
// documented, and every assertion below still holds once compiled for real. In particular:
// `TaskStore.saveThrowing()`'s use of `context.insertedModelsArray`/`changedModelsArray` is itself
// flagged UNVERIFIED in `TaskStore.swift` — if that API doesn't exist on Mac and group A falls
// back to the documented `touch(_:)` alternative, the stamping tests below should still hold
// (they only observe `updatedAt` through the public `pendingForSync` surface, not the mechanism).
import XCTest
import Foundation
import VolarCore
@testable import Volar

@MainActor
final class SyncStoreTests: XCTestCase {
    private func makeStore() throws -> TaskStore {
        try TaskStore(inMemory: true)
    }

    // MARK: - Stamping (client-contract.md §1 rule 3, §4): `add`/`updateEditableFields`/`toggle`
    // advance `updatedAt` and mark the row pending. Observed through `pendingForSync` — the only
    // public window onto `updatedAt`/`isPendingSync`, since neither is threaded through `TaskItem`.

    func testAddStampsUpdatedAtAndMarksPending() throws {
        let store = try makeStore()
        let before = Date()
        let item = TaskItem(title: "new task", priority: .medium, when: .later)
        store.add(item)

        let pending = try XCTUnwrap(store.pendingForSync(limit: 100).first { $0.item.id == item.id })
        XCTAssertNil(pending.deletedAt)
        XCTAssertGreaterThanOrEqual(pending.updatedAt, before.addingTimeInterval(-2))
    }

    func testUpdateEditableFieldsAdvancesUpdatedAtAndReMarksPending() throws {
        let store = try makeStore()
        let item = TaskItem(title: "edit me", priority: .medium, when: .later)
        store.add(item)

        let firstPending = try XCTUnwrap(store.pendingForSync(limit: 100).first { $0.item.id == item.id })
        // Simulate a successful push+confirm round trip so the row starts clean.
        store.markSynced([item.id: (sent: firstPending.updatedAt, confirmed: firstPending.updatedAt)])
        XCTAssertTrue(store.pendingForSync(limit: 100).isEmpty, "row confirmed synced must not still be pending")

        var edited = item
        edited.title = "edited title"
        XCTAssertTrue(store.updateEditableFields(from: edited))

        let secondPending = try XCTUnwrap(store.pendingForSync(limit: 100).first { $0.item.id == item.id })
        XCTAssertGreaterThanOrEqual(secondPending.updatedAt, firstPending.updatedAt)
        XCTAssertEqual(secondPending.item.title, "edited title")
    }

    func testToggleAdvancesUpdatedAtAndMarksPending() throws {
        let store = try makeStore()
        let item = TaskItem(title: "toggle me", priority: .medium, when: .later)
        store.add(item)

        let firstPending = try XCTUnwrap(store.pendingForSync(limit: 100).first { $0.item.id == item.id })
        store.markSynced([item.id: (sent: firstPending.updatedAt, confirmed: firstPending.updatedAt)])
        XCTAssertTrue(store.pendingForSync(limit: 100).isEmpty)

        store.toggle(item.id)

        let secondPending = try XCTUnwrap(store.pendingForSync(limit: 100).first { $0.item.id == item.id })
        XCTAssertGreaterThanOrEqual(secondPending.updatedAt, firstPending.updatedAt)
    }

    // MARK: - 🔴 applyRemote must NOT re-stamp `updatedAt` (client-contract.md §4 — "cái bẫy chết
    // người"). This is the single most important test in this file: if `applyRemote` restamped
    // `updatedAt = Date()` internally, every row just pulled from the server would immediately
    // look newer than the server's own record of it, and two devices would push-pull forever.

    func testApplyRemoteDoesNotRestampUpdatedAt() throws {
        let store = try makeStore()
        let id = UUID()
        // Both timestamps are far in the past relative to "now" (this test runs in 2026) — the
        // key property under test is that the SECOND, slightly-newer-than-the-first update still
        // wins LWW, which is only possible if the first `applyRemote` call left `updatedAt` at its
        // own old value instead of jumping to `Date()`.
        let t1 = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01
        let t2 = Date(timeIntervalSince1970: 1_609_459_200) // 2021-01-01

        let itemV1 = TaskItem(id: id, title: "v1", priority: .medium, createdAt: t1, when: .later)
        let writtenV1 = try store.applyRemote([RemoteTask(id: id, updatedAt: t1, deletedAt: nil, item: itemV1)])
        XCTAssertEqual(writtenV1, [id])
        XCTAssertEqual(store.fetchAll().first { $0.id == id }?.title, "v1")
        // A row just pulled from the server is, by definition, already in sync — it must not be
        // pending immediately after being applied.
        XCTAssertTrue(
            store.pendingForSync(limit: 100).isEmpty,
            "row just pulled from the server must not be marked pending"
        )

        let itemV2 = TaskItem(id: id, title: "v2", priority: .medium, createdAt: t1, when: .later)
        let writtenV2 = try store.applyRemote([RemoteTask(id: id, updatedAt: t2, deletedAt: nil, item: itemV2)])
        // If `applyRemote` had re-stamped `updatedAt = Date()` (≈2026) after the FIRST apply, this
        // second apply (t2 = 2021, still far in the past relative to "now") would lose the LWW
        // comparison (`t2 > updatedAt` would be false) and be silently skipped. Succeeding here
        // proves the stored `updatedAt` after the first apply really was `t1`, not `now`.
        XCTAssertEqual(
            writtenV2, [id],
            "second remote update must win LWW against t1 — proves updatedAt after the first apply was t1, not Date()"
        )
        XCTAssertEqual(store.fetchAll().first { $0.id == id }?.title, "v2")
        XCTAssertTrue(store.pendingForSync(limit: 100).isEmpty)
    }

    // MARK: - LWW at the record level (design.md §5)

    func testApplyRemoteOlderThanLocalIsSkippedAndLocalWins() throws {
        let store = try makeStore()
        let id = UUID()
        store.add(TaskItem(id: id, title: "local-current", priority: .medium, when: .later))

        let farPast = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01 — certainly older than "just added"
        let remote = RemoteTask(
            id: id, updatedAt: farPast, deletedAt: nil,
            item: TaskItem(id: id, title: "remote-old", priority: .medium, when: .later)
        )
        let written = try store.applyRemote([remote])

        XCTAssertEqual(written, [], "an older remote row must lose LWW and be skipped")
        XCTAssertEqual(store.fetchAll().first { $0.id == id }?.title, "local-current")
    }

    func testApplyRemoteNewerThanLocalOverwritesLocal() throws {
        let store = try makeStore()
        let id = UUID()
        store.add(TaskItem(id: id, title: "local-current", priority: .medium, when: .later))

        let farFuture = Date().addingTimeInterval(60 * 60 * 24 * 365 * 10) // 10 years out
        let remote = RemoteTask(
            id: id, updatedAt: farFuture, deletedAt: nil,
            item: TaskItem(id: id, title: "remote-new", priority: .medium, when: .later)
        )
        let written = try store.applyRemote([remote])

        XCTAssertEqual(written, [id], "a newer remote row must win LWW and be applied")
        XCTAssertEqual(store.fetchAll().first { $0.id == id }?.title, "remote-new")
    }

    // MARK: - Tombstones (client-contract.md §5, design.md §6)

    func testDeleteTombstoneIsHiddenFromFetchAllButKeptInPendingForSync() throws {
        let store = try makeStore()
        let item = TaskItem(title: "to delete", priority: .medium, when: .later)
        store.add(item)

        _ = store.delete(item.id)

        XCTAssertFalse(store.fetchAll().contains { $0.id == item.id }, "a tombstoned row must be invisible to fetchAll")
        let pending = try XCTUnwrap(store.pendingForSync(limit: 100).first { $0.item.id == item.id })
        XCTAssertNotNil(pending.deletedAt, "a tombstone is the thing MOST worth pushing — it must stay in pendingForSync")
    }

    func testApplyRemoteTombstoneForNeverSeenIdIsStillWritten() throws {
        let store = try makeStore()
        let id = UUID()
        // `item: nil` — payload unreadable/absent — a bare tombstone still needs to be written so
        // a LATER, staler pull can't re-insert pre-deletion content with nothing local to reject
        // it against.
        let remote = RemoteTask(id: id, updatedAt: Date(), deletedAt: Date(), item: nil)

        let written = try store.applyRemote([remote])

        XCTAssertEqual(written, [id])
        XCTAssertFalse(store.fetchAll().contains { $0.id == id })
    }

    func testNewerRemoteRevivesALocallyTombstonedTask() throws {
        let store = try makeStore()
        let item = TaskItem(title: "revive me", priority: .medium, when: .later)
        store.add(item)
        _ = store.delete(item.id)
        XCTAssertFalse(store.fetchAll().contains { $0.id == item.id })

        let farFuture = Date().addingTimeInterval(60 * 60 * 24 * 365 * 10)
        var revived = item
        revived.title = "revived"
        let remote = RemoteTask(id: item.id, updatedAt: farFuture, deletedAt: nil, item: revived)

        let written = try store.applyRemote([remote])

        XCTAssertEqual(written, [item.id])
        XCTAssertEqual(store.fetchAll().first { $0.id == item.id }?.title, "revived")
    }

    // MARK: - One-time updatedAt backfill (design.md §7, client-contract.md §4): a row whose
    // updatedAt is still the epoch sentinel becomes `completedAt ?? createdAt` on the next
    // `fetchAll()`, never `now`. `applyRemote` is the only way to get a row into that sentinel
    // state through TaskStore's public surface (every ordinary mutator stamps `updatedAt = now`
    // via `save()`).

    func testBackfillSetsUpdatedAtToCreatedAtWhenNeverCompleted() throws {
        let store = try makeStore()
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_000_000_000) // fixed, far-past reference date
        let epoch = Date(timeIntervalSince1970: 0) // TaskStore's "never backfilled" sentinel
        let item = TaskItem(id: id, title: "legacy row", priority: .medium, createdAt: createdAt, when: .later)
        _ = try store.applyRemote([RemoteTask(id: id, updatedAt: epoch, deletedAt: nil, item: item)])

        _ = store.fetchAll() // runs the one-time backfill pass

        let backfilled = try XCTUnwrap(store.pendingForSync(limit: 100).first { $0.item.id == id })
        XCTAssertEqual(
            backfilled.updatedAt, createdAt,
            "backfill must set updatedAt = completedAt ?? createdAt, never `now`"
        )
    }

    func testBackfillPrefersCompletedAtOverCreatedAtWhenBothPresent() throws {
        let store = try makeStore()
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_000_000_000)
        let completedAt = Date(timeIntervalSince1970: 1_100_000_000)
        let epoch = Date(timeIntervalSince1970: 0)
        let item = TaskItem(
            id: id, title: "legacy done row", priority: .medium, status: .done,
            createdAt: createdAt, when: .later, completedAt: completedAt
        )
        _ = try store.applyRemote([RemoteTask(id: id, updatedAt: epoch, deletedAt: nil, item: item)])

        _ = store.fetchAll()

        let backfilled = try XCTUnwrap(store.pendingForSync(limit: 100).first { $0.item.id == id })
        XCTAssertEqual(backfilled.updatedAt, completedAt)
    }

    // MARK: - Single-frog invariant (design.md §3's last table row) — applied only from
    // `applyRemote`, per `enforceSingleFrogInvariant()`'s doc comment in TaskStore.swift.

    func testApplyRemoteEnforcesSingleFrogInvariantAndMarksTheLoserPending() throws {
        let store = try makeStore()
        let idA = UUID()
        let idB = UUID()
        let tA = Date(timeIntervalSince1970: 1_600_000_000) // older
        let tB = Date(timeIntervalSince1970: 1_700_000_000) // newer — should keep the frog

        let written = try store.applyRemote([
            RemoteTask(
                id: idA, updatedAt: tA, deletedAt: nil,
                item: TaskItem(id: idA, title: "frog A", priority: .medium, when: .later, frog: true)
            ),
            RemoteTask(
                id: idB, updatedAt: tB, deletedAt: nil,
                item: TaskItem(id: idB, title: "frog B", priority: .medium, when: .later, frog: true)
            ),
        ])
        XCTAssertEqual(Set(written), Set([idA, idB]))

        let frogs = store.fetchAll().filter(\.frog)
        XCTAssertEqual(frogs.count, 1, "at most one frog may survive after applying a batch")
        XCTAssertEqual(frogs.first?.id, idB, "the row with the newer updatedAt keeps the frog")

        // Turning A's frog off is a REAL edit that must propagate to other devices, not a silent
        // local-only fix — it must be pending.
        let pending = store.pendingForSync(limit: 100)
        let loserPending = try XCTUnwrap(pending.first { $0.item.id == idA })
        XCTAssertFalse(loserPending.item.frog)
        XCTAssertFalse(pending.contains { $0.item.id == idB }, "the winning frog must stay marked synced")
    }

    // MARK: - Completions: insert-if-absent, idempotent (client-contract.md §2's `PendingCompletion`/
    // `RemoteCompletion`, CompletionLog.swift's `on conflict do nothing` mirror)

    func testApplyRemoteCompletionsInsertIfAbsentIsIdempotent() throws {
        let store = try makeStore()
        let completion = RemoteCompletion(
            id: UUID(), taskId: UUID(), completedAt: Date(timeIntervalSince1970: 1_700_000_000),
            titleSnapshot: "done thing", parentIdSnapshot: nil, estimateSnapshot: 15
        )

        let firstCount = try store.applyRemoteCompletions([completion])
        XCTAssertEqual(firstCount, 1)

        let secondCount = try store.applyRemoteCompletions([completion])
        XCTAssertEqual(secondCount, 0, "calling twice with identical data must not insert a duplicate row")

        // Rows that arrived FROM the server are marked synced immediately — pushing them straight
        // back would be a pointless (and, worse, potentially confusing) round trip.
        XCTAssertFalse(store.pendingCompletions(limit: 100).contains { $0.id == completion.id })
    }

    func testApplyRemoteCompletionsWithMixedNewAndExistingOnlyInsertsTheNewOnes() throws {
        let store = try makeStore()
        let existing = RemoteCompletion(
            id: UUID(), taskId: UUID(), completedAt: Date(timeIntervalSince1970: 1_700_000_000),
            titleSnapshot: "already have this", parentIdSnapshot: nil, estimateSnapshot: nil
        )
        _ = try store.applyRemoteCompletions([existing])

        let brandNew = RemoteCompletion(
            id: UUID(), taskId: UUID(), completedAt: Date(timeIntervalSince1970: 1_700_000_100),
            titleSnapshot: "new one", parentIdSnapshot: nil, estimateSnapshot: nil
        )
        let count = try store.applyRemoteCompletions([existing, brandNew])

        XCTAssertEqual(count, 1, "only the never-before-seen id should be counted/inserted")
    }

    /// First CI integration run (2026-10-11): the server echoes `updatedAt` with millisecond
    /// precision, so a confirmation a few microseconds below the local stamp must still clear
    /// `isPendingSync` — otherwise every row is re-pushed on every poll forever.
    func testMarkSyncedToleratesMillisecondPrecisionLoss() throws {
        let store = try makeStore()
        let id = UUID()
        store.add(TaskItem(id: id, title: "ms", priority: .medium, when: .now))
        let pending = try XCTUnwrap(store.pendingForSync(limit: 10).first { $0.item.id == id })
        XCTAssertEqual(pending.updatedAt.timeIntervalSince1970 * 1000, (pending.updatedAt.timeIntervalSince1970 * 1000).rounded(.down), accuracy: 0.0001, "stamps are ms-truncated")
        store.markSynced([id: (sent: pending.updatedAt, confirmed: pending.updatedAt.addingTimeInterval(-0.0005))])
        XCTAssertNil(store.pendingForSync(limit: 10).first { $0.item.id == id })
    }

    /// Server clamped a far-future stamp: the row adopts the clamped `updatedAt` and stops being pending.
    func testMarkSyncedAdoptsClampedStamp() throws {
        let store = try makeStore()
        let id = UUID()
        store.add(TaskItem(id: id, title: "clamp", priority: .medium, when: .now))
        let pending = try XCTUnwrap(store.pendingForSync(limit: 10).first { $0.item.id == id })
        store.markSynced([id: (sent: pending.updatedAt, confirmed: pending.updatedAt.addingTimeInterval(-3600))])
        XCTAssertNil(store.pendingForSync(limit: 10).first { $0.item.id == id })
    }
}
