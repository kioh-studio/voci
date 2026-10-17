// Shared/Model/RewardCenter.swift — observable Earned-break state over `TaskStore`'s reward CRUD
// (implementation-contract.md §4). Injected via `.environment`; AppState is NOT involved — it only
// calls `handleRemoteApplied()` through a closure it owns.
//
// UNVERIFIED: written on Windows, never compiled.
import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class RewardCenter {
    private let store: TaskStore?

    private(set) var catalog: [RewardItem] = []
    /// Live goals (a named group of tasks), oldest first.
    private(set) var goals: [RewardItem] = []
    /// Live grants (closedAt == nil) plus grants closed today (so Goals can show "ended").
    private(set) var grants: [RewardItem] = []
    /// Grants whose Unlocked sheet was already shown this session ("Save it for later").
    var offeredGrantIDs: Set<UUID> = []

    static let enabledKey = "volar.view.goalRewards"

    /// Same key the views read with `@AppStorage`; computed so both always agree.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    init(store: TaskStore?) {
        self.store = store
        refresh()
        store?.sweepRewardTombstones()
    }

    func refresh() {
        guard let store else {
            catalog = []
            goals = []
            grants = []
            return
        }
        let all = store.fetchRewards()
        catalog = all.filter { $0.kind == .catalog }
        goals = all.filter { $0.kind == .goal }
        grants = all.filter { item in
            guard item.kind == .grant, !item.goalIds.isEmpty else { return false }
            guard let closedAt = item.closedAt else { return true }
            return Calendar.current.isDateInToday(closedAt)
        }
    }

    func goal(_ id: UUID) -> RewardItem? {
        goals.first { $0.id == id }
    }

    func grant(forGoal goalId: UUID) -> RewardItem? {
        grants.first { $0.goalIds.contains(goalId) && $0.closedAt == nil }
    }

    func isDone(_ goal: RewardItem, tasks: [TaskItem]) -> Bool {
        RewardRules.isGoalDone(goal, doneTaskIds: Self.doneIds(tasks), knownTaskIds: Set(tasks.map(\.id)))
    }

    /// Done or archived counts as resolved (same as `TaskSections.isResolved`).
    private static func doneIds(_ tasks: [TaskItem]) -> Set<UUID> {
        Set(tasks.filter { $0.status == .done || $0.status == .archived }.map(\.id))
    }

    /// How many of the goal's tasks are done.
    func doneCount(of goal: RewardItem, tasks: [TaskItem]) -> Int {
        let done = Self.doneIds(tasks)
        return goal.taskIds.filter { done.contains($0) }.count
    }

    /// Unlocked needs every goal of the grant alive and done; an unresolved goal id counts as not done.
    func state(of grant: RewardItem, tasks: [TaskItem], now: Date = Date()) -> RewardState {
        let allDone = !grant.goalIds.isEmpty && grant.goalIds.allSatisfy { id in
            goal(id).map { isDone($0, tasks: tasks) } ?? false
        }
        return RewardRules.state(of: grant, allGoalsDone: allDone, now: now)
    }

    /// The grant whose break is running right now, if any. Needs no task list: `.running` depends
    /// only on the break timestamps.
    func runningBreak(now: Date = Date()) -> RewardItem? {
        grants.first { RewardRules.state(of: $0, allGoalsDone: false, now: now) == .running }
    }

    // MARK: - Catalog

    @discardableResult
    func addReward(title: String, minutes: Int, icon: RewardIcon, remindWhenOver: Bool) -> RewardItem {
        let item = RewardItem(
            kind: .catalog, title: title, minutes: minutes, icon: icon, remindWhenOver: remindWhenOver
        )
        store?.addReward(item)
        didMutate()
        return item
    }

    func updateReward(_ item: RewardItem) {
        store?.updateReward(item)
        didMutate()
    }

    func removeReward(_ id: UUID) {
        store?.deleteReward(id)
        didMutate()
    }

    // MARK: - Goals

    @discardableResult
    func addGoal(title: String, taskIds: [UUID]) -> RewardItem {
        var seen = Set<UUID>()
        let item = RewardItem(kind: .goal, title: title, taskIds: taskIds.filter { seen.insert($0).inserted })
        store?.addReward(item)
        didMutate()
        return item
    }

    /// Rename / change tasks.
    func updateGoal(_ goal: RewardItem) {
        store?.updateReward(goal)
        didMutate()
    }

    /// G4: tombstone the goal and strip its id from every live grant; a grant left empty is tombstoned.
    func removeGoal(_ id: UUID) {
        guard let store else { return }
        store.deleteReward(id)
        detach([id])
        didMutate()
    }

    /// Always creates a NEW grant over `goalIds` (never edits an old one). The goals first leave any
    /// grant they were in (an emptied grant is tombstoned). `nil` = no reward: nothing new is created.
    /// Snapshots title/minutes/icon/remind from the catalog entry so a later catalog edit or delete
    /// cannot break it.
    func attachReward(_ rewardId: UUID?, toGoals goalIds: [UUID]) {
        guard let store else { return }
        var seen = Set<UUID>()
        let ids = goalIds.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return }
        if let rewardId, let source = store.fetchRewards().first(where: { $0.id == rewardId && $0.kind == .catalog }) {
            detach(ids)
            store.addReward(RewardItem(
                kind: .grant, title: source.title, minutes: source.minutes, icon: source.icon,
                goalIds: ids, rewardId: source.id, remindWhenOver: source.remindWhenOver
            ))
        } else {
            // nil (or a vanished catalog id): only these goals lose their reward;
            // other goals sharing the grant keep it (`detach` tombstones a grant
            // only once it has no goals left).
            detach(ids)
        }
        didMutate()
    }

    /// Removes `goalIds` from every live grant; a grant left with no goals
    /// is tombstoned. No `didMutate` — callers do it.
    private func detach(_ goalIds: [UUID]) {
        guard let store else { return }
        let gone = Set(goalIds)
        for var g in store.fetchRewards() where g.kind == .grant && g.closedAt == nil {
            guard g.goalIds.contains(where: gone.contains) else { continue }
            g.goalIds.removeAll { gone.contains($0) }
            if g.goalIds.isEmpty {
                cancelBreakNotification(g.id)
                store.deleteReward(g.id)
            } else {
                store.updateReward(g)
            }
        }
    }

    // MARK: - Break

    func startBreak(_ grantId: UUID, now: Date = Date()) {
        guard var item = store?.fetchRewards().first(where: { $0.id == grantId }),
              let minutes = item.minutes, minutes > 0 else { return }
        item.breakStartedAt = now
        item.breakEndsAt = now.addingTimeInterval(TimeInterval(minutes) * 60)
        item.startedDevice = SyncEngine.shared.deviceId
        item.closedAt = nil
        store?.updateReward(item)
        scheduleBreakNotification(item, now: now)
        didMutate()
    }

    func endBreak(_ grantId: UUID, now: Date = Date()) {
        guard var item = store?.fetchRewards().first(where: { $0.id == grantId }) else { return }
        item.closedAt = now
        store?.updateReward(item)
        cancelBreakNotification(grantId)
        didMutate()
    }

    /// "Save it for later": only hides the sheet; the grant stays unlocked and shows on Goals.
    func dismissUnlocked(_ grantId: UUID) {
        offeredGrantIDs.insert(grantId)
    }

    /// Called by AppState (via its `rewardCenterDidApplyRemote` closure) after a sync apply. A break
    /// started or closed on another device must not fire a notification here.
    func handleRemoteApplied() {
        refresh()
        guard let store else { return }
        let me = SyncEngine.shared.deviceId
        for item in store.fetchRewards() where item.kind == .grant && item.breakStartedAt != nil {
            if item.closedAt != nil || item.startedDevice != me {
                cancelBreakNotification(item.id)
            }
        }
    }

    // MARK: - Internals

    private func didMutate() {
        refresh()
        SyncEngine.shared.requestSync(reason: .localEdit)
    }

    private func notificationID(_ grantId: UUID) -> String {
        "reward-break-\(grantId.uuidString)"
    }

    private func cancelBreakNotification(_ grantId: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [notificationID(grantId)]
        )
    }

    private func scheduleBreakNotification(_ item: RewardItem, now: Date) {
        guard item.remindWhenOver, let ends = item.breakEndsAt else { return }
        let interval = ends.timeIntervalSince(now)
        guard interval > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "Break's over"
        content.body = ["Back to Now.", item.title].compactMap { $0 }.joined(separator: " ")
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: notificationID(item.id),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        )
        // `@Sendable`: same off-main completion trap `NotificationCenterSendable.volarAdd` documents.
        UNUserNotificationCenter.current().add(request) { @Sendable _ in }
    }
}
