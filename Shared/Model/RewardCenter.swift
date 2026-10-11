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
    }

    func refresh() {
        guard let store else {
            catalog = []
            grants = []
            return
        }
        let all = store.fetchRewards()
        catalog = all.filter { $0.kind == .catalog }
        grants = all.filter { item in
            guard item.kind == .grant, item.taskId != nil else { return false }
            guard let closedAt = item.closedAt else { return true }
            return Calendar.current.isDateInToday(closedAt)
        }
    }

    func grant(for taskId: UUID) -> RewardItem? {
        grants.first { $0.taskId == taskId && $0.closedAt == nil }
    }

    func state(of grant: RewardItem, tasks: [TaskItem], now: Date = Date()) -> RewardState {
        let done = tasks.first { $0.id == grant.taskId }?.status == .done
        return RewardRules.state(of: grant, taskDone: done, now: now)
    }

    /// The grant whose break is running right now, if any. Needs no task list: `.running` depends
    /// only on the break timestamps.
    func runningBreak(now: Date = Date()) -> RewardItem? {
        grants.first { RewardRules.state(of: $0, taskDone: false, now: now) == .running }
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

    /// Turning a goal on creates a grant with no reward; off tombstones the live grant.
    func setGoal(_ taskId: UUID, _ isGoal: Bool) {
        guard let store else { return }
        let live = store.liveGrant(for: taskId)
        if isGoal {
            guard live == nil else { return }
            store.addReward(RewardItem(kind: .grant, taskId: taskId))
        } else if let live {
            cancelBreakNotification(live.id)
            store.deleteReward(live.id)
        }
        didMutate()
    }

    /// Creates the grant if none; snapshots title/minutes/icon/remind from the catalog entry so a
    /// later catalog edit or delete cannot break it. `nil` = goal without a reward.
    func attachReward(_ rewardId: UUID?, to taskId: UUID) {
        guard let store else { return }
        var item = store.liveGrant(for: taskId) ?? RewardItem(kind: .grant, taskId: taskId)
        let isNew = store.liveGrant(for: taskId) == nil
        if let rewardId, let source = store.fetchRewards().first(where: { $0.id == rewardId && $0.kind == .catalog }) {
            item.rewardId = source.id
            item.title = source.title
            item.minutes = source.minutes
            item.icon = source.icon
            item.remindWhenOver = source.remindWhenOver
        } else {
            item.rewardId = nil
            item.title = nil
            item.minutes = nil
            item.icon = nil
        }
        if isNew { store.addReward(item) } else { store.updateReward(item) }
        didMutate()
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
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
