// SharedTests/RewardTests.swift — Earned break model: derived state, store CRUD, sync apply,
// one-live-grant-per-task repair, tolerant wire decode (implementation-contract.md §4/§5).
//
// UNVERIFIED: written on Windows, never compiled or run — confirm on Mac.
import XCTest
import Foundation
import SwiftData
import VolarCore
@testable import Volar

@MainActor
final class RewardTests: XCTestCase {
    private func makeStore() throws -> TaskStore {
        try TaskStore(inMemory: true)
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func grant(
        goal: UUID = UUID(), start: Date? = nil, end: Date? = nil, closed: Date? = nil
    ) -> RewardItem {
        RewardItem(
            kind: .grant, title: "Game", minutes: 30, goalIds: [goal],
            breakStartedAt: start, breakEndsAt: end, closedAt: closed
        )
    }

    // MARK: - Derived state (plan §2.2)

    func testLockedWhenTaskNotDone() {
        XCTAssertEqual(RewardRules.state(of: grant(), allGoalsDone: false, now: t0), .locked)
    }

    func testUnlockedWhenTaskDoneAndNoBreak() {
        XCTAssertEqual(RewardRules.state(of: grant(), allGoalsDone: true, now: t0), .unlocked)
    }

    func testUntickDoneGoesBackToLocked() {
        let g = grant()
        XCTAssertEqual(RewardRules.state(of: g, allGoalsDone: true, now: t0), .unlocked)
        XCTAssertEqual(RewardRules.state(of: g, allGoalsDone: false, now: t0), .locked)
    }

    func testRunningKeepsTimerWhenTaskUnticked() {
        let g = grant(start: t0, end: t0.addingTimeInterval(1800))
        let mid = t0.addingTimeInterval(600)
        XCTAssertEqual(RewardRules.state(of: g, allGoalsDone: true, now: mid), .running)
        XCTAssertEqual(RewardRules.state(of: g, allGoalsDone: false, now: mid), .running)
    }

    func testEndedWhenTimerPassedOrClosed() {
        let timed = grant(start: t0, end: t0.addingTimeInterval(1800))
        XCTAssertEqual(RewardRules.state(of: timed, allGoalsDone: true, now: t0.addingTimeInterval(1800)), .ended)
        let closed = grant(start: t0, end: t0.addingTimeInterval(1800), closed: t0.addingTimeInterval(60))
        XCTAssertEqual(RewardRules.state(of: closed, allGoalsDone: true, now: t0.addingTimeInterval(120)), .ended)
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
        let goalId = UUID()
        let game = center.addReward(title: "Game", minutes: 30, icon: .gamepad, remindWhenOver: true)
        let book = center.addReward(title: "Book", minutes: 20, icon: .book, remindWhenOver: false)

        center.attachReward(game.id, toGoals: [goalId])
        var g = try XCTUnwrap(store.liveGrant(forGoal: goalId))
        XCTAssertEqual(g.title, "Game")
        XCTAssertEqual(g.minutes, 30)
        XCTAssertEqual(g.rewardId, game.id)

        center.attachReward(book.id, toGoals: [goalId])
        g = try XCTUnwrap(store.liveGrant(forGoal: goalId))
        XCTAssertEqual(g.title, "Book")
        XCTAssertEqual(g.minutes, 20)
        XCTAssertFalse(g.remindWhenOver)
        XCTAssertEqual(store.fetchRewards().filter { $0.kind == .grant }.count, 1)

        // Deleting the catalog entry must not touch the snapshot.
        center.removeReward(book.id)
        g = try XCTUnwrap(store.liveGrant(forGoal: goalId))
        XCTAssertEqual(g.title, "Book")
    }

    // MARK: - One live grant per goal (plan §2.3)

    func testApplyRemoteWithTwoGrantsKeepsNewestOnly() throws {
        let store = try makeStore()
        let goalId = UUID()
        let older = RewardItem(kind: .grant, title: "Old", minutes: 10, goalIds: [goalId])
        let newer = RewardItem(kind: .grant, title: "New", minutes: 20, goalIds: [goalId])
        let day = t0
        try store.applyRemoteRewards([
            RemoteReward(id: older.id, updatedAt: day, deletedAt: nil, item: older),
            RemoteReward(id: newer.id, updatedAt: day.addingTimeInterval(60), deletedAt: nil, item: newer),
        ])
        XCTAssertEqual(store.liveGrant(forGoal: goalId)?.id, newer.id)
        XCTAssertEqual(store.fetchRewards().filter { $0.kind == .grant }.count, 1)
        // The loser's tombstone is a real edit and must be pending.
        let tomb = try XCTUnwrap(store.pendingRewardsForSync(limit: 10).first { $0.item.id == older.id })
        XCTAssertNotNil(tomb.deletedAt)
    }

    func testDuplicateRuleIgnoresDifferentGoals() {
        let a = (item: RewardItem(kind: .grant, goalIds: [UUID()]), updatedAt: t0)
        let b = (item: RewardItem(kind: .grant, goalIds: [UUID()]), updatedAt: t0)
        XCTAssertTrue(RewardRules.duplicateGrantIDsToTombstone([a, b]).isEmpty)
    }

    func testApplyRemoteDoesNotRestampAndInsertsBareTombstone() throws {
        let store = try makeStore()
        let id = UUID()
        try store.applyRemoteRewards([RemoteReward(id: id, updatedAt: t0, deletedAt: t0, item: nil)])
        XCTAssertTrue(store.fetchRewards().isEmpty)
        XCTAssertTrue(store.pendingRewardsForSync(limit: 10).isEmpty, "applied rows are already in sync")
    }

    // MARK: - Goals & rewards (multi-goal-rewards.md rev 2)

    private func task(_ title: String, done: Bool) -> TaskItem {
        var t = TaskItem(title: title, priority: .medium, when: .now)
        if done { t.status = .done }
        return t
    }

    func testIsGoalDone() {
        let a = UUID(), b = UUID()
        XCTAssertFalse(RewardRules.isGoalDone(RewardItem(kind: .goal, taskIds: []), doneTaskIds: [a]))
        let goal = RewardItem(kind: .goal, taskIds: [a, b])
        XCTAssertFalse(RewardRules.isGoalDone(goal, doneTaskIds: [a]))
        XCTAssertTrue(RewardRules.isGoalDone(goal, doneTaskIds: [a, b]))
    }

    func testCenterStateNeedsEveryGoalDoneAndResolved() throws {
        let center = RewardCenter(store: try makeStore())
        let t1 = task("1", done: true)
        let t2 = task("2", done: false)
        let ga = center.addGoal(title: "A", taskIds: [t1.id])
        let gb = center.addGoal(title: "B", taskIds: [t2.id])
        let g = RewardItem(kind: .grant, title: "Game", minutes: 30, goalIds: [ga.id, gb.id])
        XCTAssertEqual(center.state(of: g, tasks: [t1, t2], now: t0), .locked)
        XCTAssertEqual(center.doneCount(of: ga, tasks: [t1, t2]), 1)
        XCTAssertEqual(center.doneCount(of: gb, tasks: [t1, t2]), 0)
        var t2d = t2
        t2d.status = .done
        XCTAssertEqual(center.state(of: g, tasks: [t1, t2d], now: t0), .unlocked)
        let dangling = RewardItem(kind: .grant, goalIds: [ga.id, UUID()])
        XCTAssertEqual(center.state(of: dangling, tasks: [t1, t2d], now: t0), .locked)
    }

    func testDuplicateRuleTombstonesGrantLosingOnAnyGoal() {
        let g1 = UUID(), g2 = UUID()
        let a = (item: RewardItem(kind: .grant, goalIds: [g1, g2]), updatedAt: t0)
        let b = (item: RewardItem(kind: .grant, goalIds: [g2]), updatedAt: t0.addingTimeInterval(60))
        XCTAssertEqual(RewardRules.duplicateGrantIDsToTombstone([a, b]), [a.item.id])
    }

    func testRemoveGoalStripsGrantsAndTombstonesEmptyOnes() throws {
        let store = try makeStore()
        let center = RewardCenter(store: store)
        let game = center.addReward(title: "Game", minutes: 30, icon: .gamepad, remindWhenOver: true)
        let a = center.addGoal(title: "A", taskIds: [UUID()])
        let b = center.addGoal(title: "B", taskIds: [UUID()])
        center.attachReward(game.id, toGoals: [a.id, b.id])
        center.removeGoal(a.id)
        XCTAssertNil(store.liveGrant(forGoal: a.id))
        XCTAssertEqual(store.liveGrant(forGoal: b.id)?.goalIds, [b.id])
        XCTAssertEqual(center.goals.map(\.id), [b.id])
        center.removeGoal(b.id)
        XCTAssertTrue(store.fetchRewards().filter { $0.kind == .grant }.isEmpty)
    }

    func testAttachNilTombstonesAndAttachSplitsGoalsOutOfOldGrant() throws {
        let store = try makeStore()
        let center = RewardCenter(store: store)
        let game = center.addReward(title: "Game", minutes: 30, icon: .gamepad, remindWhenOver: true)
        let a = center.addGoal(title: "A", taskIds: [UUID()])
        let b = center.addGoal(title: "B", taskIds: [UUID()])

        center.attachReward(game.id, toGoals: [a.id, b.id])
        let both = try XCTUnwrap(store.liveGrant(forGoal: a.id))
        XCTAssertEqual(both.goalIds, [a.id, b.id])
        XCTAssertEqual(both.title, "Game")
        XCTAssertEqual(both.rewardId, game.id)

        // B on its own: old grant keeps [A], a NEW grant holds [B].
        center.attachReward(game.id, toGoals: [b.id])
        XCTAssertEqual(store.liveGrant(forGoal: a.id)?.goalIds, [a.id])
        XCTAssertEqual(store.liveGrant(forGoal: a.id)?.id, both.id)
        let solo = try XCTUnwrap(store.liveGrant(forGoal: b.id))
        XCTAssertEqual(solo.goalIds, [b.id])
        XCTAssertNotEqual(solo.id, both.id)

        center.attachReward(nil, toGoals: [a.id])
        XCTAssertNil(store.liveGrant(forGoal: a.id))
        XCTAssertNotNil(store.liveGrant(forGoal: b.id))
    }

    func testDecodeLegacySingleTaskId() throws {
        let id = UUID(), t = UUID()
        let json = """
        {"id":"\(id.uuidString)","kind":"grant","taskId":"\(t.uuidString)"}
        """
        let item = try SyncCoding.makeDecoder().decode(RewardItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.taskIds, [t])
        XCTAssertTrue(item.goalIds.isEmpty)
    }

    func testEncodeWritesTaskIdTaskIdsAndGoalIds() throws {
        let t1 = UUID(), t2 = UUID(), g = UUID()
        let goal = RewardItem(kind: .goal, title: "G", taskIds: [t1, t2])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try SyncCoding.makeEncoder().encode(goal)) as? [String: Any])
        XCTAssertEqual(obj["taskId"] as? String, t1.uuidString)
        XCTAssertEqual((obj["taskIds"] as? [String])?.count, 2)
        let grant = RewardItem(kind: .grant, goalIds: [g])
        let obj2 = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try SyncCoding.makeEncoder().encode(grant)) as? [String: Any])
        XCTAssertEqual(obj2["goalIds"] as? [String], [g.uuidString])
    }

    // MARK: - Wire decode

    func testItemRoundTripsThroughSyncCoding() throws {
        let item = RewardItem(
            kind: .grant, title: "Walk", minutes: 15, icon: .walk, taskIds: [UUID()], goalIds: [UUID(), UUID()], rewardId: UUID(),
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
