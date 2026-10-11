// SharedTests/RewardTests.swift — Earned break model: derived state, store CRUD, sync apply,
// one-live-grant-per-task repair, tolerant wire decode (implementation-contract.md §4/§5).
//
// UNVERIFIED: written on Windows, never compiled or run — confirm on Mac.
import XCTest
import Foundation
import SwiftData
@testable import Volar

@MainActor
final class RewardTests: XCTestCase {
    private func makeStore() throws -> TaskStore {
        try TaskStore(inMemory: true)
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func grant(
        task: UUID = UUID(), start: Date? = nil, end: Date? = nil, closed: Date? = nil
    ) -> RewardItem {
        RewardItem(
            kind: .grant, title: "Game", minutes: 30, taskId: task,
            breakStartedAt: start, breakEndsAt: end, closedAt: closed
        )
    }

    // MARK: - Derived state (plan §2.2)

    func testLockedWhenTaskNotDone() {
        XCTAssertEqual(RewardRules.state(of: grant(), taskDone: false, now: t0), .locked)
    }

    func testUnlockedWhenTaskDoneAndNoBreak() {
        XCTAssertEqual(RewardRules.state(of: grant(), taskDone: true, now: t0), .unlocked)
    }

    func testUntickDoneGoesBackToLocked() {
        let g = grant()
        XCTAssertEqual(RewardRules.state(of: g, taskDone: true, now: t0), .unlocked)
        XCTAssertEqual(RewardRules.state(of: g, taskDone: false, now: t0), .locked)
    }

    func testRunningKeepsTimerWhenTaskUnticked() {
        let g = grant(start: t0, end: t0.addingTimeInterval(1800))
        let mid = t0.addingTimeInterval(600)
        XCTAssertEqual(RewardRules.state(of: g, taskDone: true, now: mid), .running)
        XCTAssertEqual(RewardRules.state(of: g, taskDone: false, now: mid), .running)
    }

    func testEndedWhenTimerPassedOrClosed() {
        let timed = grant(start: t0, end: t0.addingTimeInterval(1800))
        XCTAssertEqual(RewardRules.state(of: timed, taskDone: true, now: t0.addingTimeInterval(1800)), .ended)
        let closed = grant(start: t0, end: t0.addingTimeInterval(1800), closed: t0.addingTimeInterval(60))
        XCTAssertEqual(RewardRules.state(of: closed, taskDone: true, now: t0.addingTimeInterval(120)), .ended)
    }

    // MARK: - Store CRUD

    func testAddUpdateDeleteReward() throws {
        let store = try makeStore()
        var item = RewardItem(kind: .catalog, title: "Game", minutes: 30, icon: .gamepad)
        store.addReward(item)
        XCTAssertEqual(store.fetchRewards().map(\.id), [item.id])

        item.minutes = 45
        store.updateReward(item)
        XCTAssertEqual(store.fetchRewards().first?.minutes, 45)

        store.deleteReward(item.id)
        XCTAssertTrue(store.fetchRewards().isEmpty)
        // The tombstone must still be pushed.
        let pending = try XCTUnwrap(store.pendingRewardsForSync(limit: 10).first { $0.item.id == item.id })
        XCTAssertNotNil(pending.deletedAt)
    }

    func testPendingIncludesTombstonesAndExcludesSyncedRows() throws {
        let store = try makeStore()
        let a = RewardItem(kind: .catalog, title: "A", minutes: 10)
        let b = RewardItem(kind: .catalog, title: "B", minutes: 10)
        store.addReward(a)
        store.addReward(b)
        let pa = try XCTUnwrap(store.pendingRewardsForSync(limit: 10).first { $0.item.id == a.id })
        store.markRewardsSynced([a.id: pa.updatedAt])
        XCTAssertNil(store.pendingRewardsForSync(limit: 10).first { $0.item.id == a.id })
        XCTAssertNotNil(store.pendingRewardsForSync(limit: 10).first { $0.item.id == b.id })
        store.deleteReward(a.id)
        XCTAssertNotNil(store.pendingRewardsForSync(limit: 10).first { $0.item.id == a.id })
    }

    func testSweepRemovesOnlySyncedOldTombstones() throws {
        let store = try makeStore()
        let now = Date()
        func tombstone(ageDays: Double, synced: Bool) throws -> UUID {
            let item = RewardItem(kind: .catalog, title: "T", minutes: 10)
            store.addReward(item)
            let model = try XCTUnwrap(store.context.fetch(FetchDescriptor<RewardRecord>()).first { $0.id == item.id })
            store.withoutStamping {
                model.deletedAt = now.addingTimeInterval(-ageDays * 86_400)
                model.syncedAt = synced ? now : nil
            }
            return item.id
        }
        let oldSynced = try tombstone(ageDays: 40, synced: true)
        let oldUnsynced = try tombstone(ageDays: 40, synced: false)
        let recentSynced = try tombstone(ageDays: 10, synced: true)
        store.sweepRewardTombstones(now: now)
        let left = Set(try store.context.fetch(FetchDescriptor<RewardRecord>()).map(\.id))
        XCTAssertFalse(left.contains(oldSynced))
        XCTAssertTrue(left.contains(oldUnsynced))
        XCTAssertTrue(left.contains(recentSynced))
    }

    // MARK: - RewardCenter snapshots

    func testAttachAndReplaceRewardSnapshotsTitleAndMinutes() throws {
        let store = try makeStore()
        let center = RewardCenter(store: store)
        let taskId = UUID()
        let game = center.addReward(title: "Game", minutes: 30, icon: .gamepad, remindWhenOver: true)
        let book = center.addReward(title: "Book", minutes: 20, icon: .book, remindWhenOver: false)

        center.attachReward(game.id, to: taskId)
        var g = try XCTUnwrap(store.liveGrant(for: taskId))
        XCTAssertEqual(g.title, "Game")
        XCTAssertEqual(g.minutes, 30)
        XCTAssertEqual(g.rewardId, game.id)

        center.attachReward(book.id, to: taskId)
        g = try XCTUnwrap(store.liveGrant(for: taskId))
        XCTAssertEqual(g.title, "Book")
        XCTAssertEqual(g.minutes, 20)
        XCTAssertFalse(g.remindWhenOver)
        XCTAssertEqual(store.fetchRewards().filter { $0.kind == .grant }.count, 1)

        // Deleting the catalog entry must not touch the snapshot.
        center.removeReward(book.id)
        g = try XCTUnwrap(store.liveGrant(for: taskId))
        XCTAssertEqual(g.title, "Book")
    }

    // MARK: - One live grant per task (plan §2.3)

    func testApplyRemoteWithTwoGrantsKeepsNewestOnly() throws {
        let store = try makeStore()
        let taskId = UUID()
        let older = RewardItem(kind: .grant, title: "Old", minutes: 10, taskId: taskId)
        let newer = RewardItem(kind: .grant, title: "New", minutes: 20, taskId: taskId)
        let day = t0
        try store.applyRemoteRewards([
            RemoteReward(id: older.id, updatedAt: day, deletedAt: nil, item: older),
            RemoteReward(id: newer.id, updatedAt: day.addingTimeInterval(60), deletedAt: nil, item: newer),
        ])
        XCTAssertEqual(store.liveGrant(for: taskId)?.id, newer.id)
        XCTAssertEqual(store.fetchRewards().filter { $0.kind == .grant }.count, 1)
        // The loser's tombstone is a real edit and must be pending.
        let tomb = try XCTUnwrap(store.pendingRewardsForSync(limit: 10).first { $0.item.id == older.id })
        XCTAssertNotNil(tomb.deletedAt)
    }

    func testDuplicateRuleIgnoresDifferentTasks() {
        let a = (item: RewardItem(kind: .grant, taskId: UUID()), updatedAt: t0)
        let b = (item: RewardItem(kind: .grant, taskId: UUID()), updatedAt: t0)
        XCTAssertTrue(RewardRules.duplicateGrantIDsToTombstone([a, b]).isEmpty)
    }

    func testApplyRemoteDoesNotRestampAndInsertsBareTombstone() throws {
        let store = try makeStore()
        let id = UUID()
        try store.applyRemoteRewards([RemoteReward(id: id, updatedAt: t0, deletedAt: t0, item: nil)])
        XCTAssertTrue(store.fetchRewards().isEmpty)
        XCTAssertTrue(store.pendingRewardsForSync(limit: 10).isEmpty, "applied rows are already in sync")
    }

    // MARK: - Wire decode

    func testItemRoundTripsThroughSyncCoding() throws {
        let item = RewardItem(
            kind: .grant, title: "Walk", minutes: 15, icon: .walk, taskId: UUID(), rewardId: UUID(),
            breakStartedAt: t0, breakEndsAt: t0.addingTimeInterval(900), startedDevice: "dev",
            remindWhenOver: false, createdAt: t0
        )
        let data = try SyncCoding.makeEncoder().encode(item)
        let back = try SyncCoding.makeDecoder().decode(RewardItem.self, from: data)
        XCTAssertEqual(back, item)
    }

    func testTolerantDecodeMissingRemindAndUnknownIcon() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","kind":"catalog","title":"X","icon":"hologram"}
        """
        let item = try SyncCoding.makeDecoder().decode(RewardItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.id, id)
        XCTAssertTrue(item.remindWhenOver)
        XCTAssertNil(item.icon)
        XCTAssertNil(item.minutes)
    }
}
