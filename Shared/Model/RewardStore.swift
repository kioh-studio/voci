// Shared/Model/RewardStore.swift — reward CRUD + `SyncRewardStoring` on `TaskStore`
// (implementation-contract.md §4/§5). Mirrors the task versions in `TaskStore.swift`.
//
// UNVERIFIED: written on Windows, never compiled. Needs `TaskStore.context`, `save()`,
// `saveThrowing()` and `withoutStamping` to be non-private (a Swift extension in another file cannot
// see `private` members).
import Foundation
import SwiftData

extension TaskStore {
    // MARK: - CRUD

    /// Non-deleted rows of both kinds.
    func fetchRewards() -> [RewardItem] {
        fetchRewardModels().map(\.asItem)
    }

    func addReward(_ item: RewardItem) {
        let model = RewardRecord(id: item.id, kind: item.kind, createdAt: item.createdAt)
        model.apply(item)
        context.insert(model)
        save()
    }

    func updateReward(_ item: RewardItem) {
        guard let model = fetchRewardModel(item.id) else { return }
        model.apply(item)
        save()
    }

    /// Tombstone, not `context.delete` — same reasoning as `TaskStore.delete`.
    func deleteReward(_ id: UUID, now: Date = Date()) {
        guard let model = fetchRewardModel(id) else { return }
        model.deletedAt = now
        save()
    }

    /// Local sweep: physically deletes tombstones older than `days` that the server has already
    /// confirmed (`syncedAt != nil`) — an unsynced tombstone must still be pushed. Mirrors the sweep
    /// in `TaskStore.fetchAll()`. UNVERIFIED: written blind.
    func sweepRewardTombstones(olderThan days: Int = 30, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let expired = fetchAllRewardModelsIncludingDeleted().filter { model in
            guard let deletedAt = model.deletedAt, model.syncedAt != nil else { return false }
            return deletedAt < cutoff
        }
        guard !expired.isEmpty else { return }
        withoutStamping {
            for model in expired { context.delete(model) }
            save()
        }
    }

    /// The task's one live grant (kind grant, not deleted, not closed). If a corrupted store holds
    /// more than one, the newest `updatedAt` wins (the repair after sync tombstones the rest).
    func liveGrant(for taskId: UUID) -> RewardItem? {
        liveGrantModels()
            .filter { $0.taskId == taskId }
            .max(by: { $0.updatedAt < $1.updatedAt })?
            .asItem
    }

    // MARK: - Fetch helpers

    private func fetchRewardModels() -> [RewardRecord] {
        let descriptor = FetchDescriptor<RewardRecord>(
            predicate: #Predicate<RewardRecord> { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchRewardModel(_ id: UUID) -> RewardRecord? {
        var descriptor = FetchDescriptor<RewardRecord>(
            predicate: #Predicate<RewardRecord> { $0.id == id && $0.deletedAt == nil }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Includes tombstones — sync must see them.
    private func fetchAllRewardModelsIncludingDeleted() -> [RewardRecord] {
        let descriptor = FetchDescriptor<RewardRecord>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchRewardModelIncludingDeleted(_ id: UUID) -> RewardRecord? {
        var descriptor = FetchDescriptor<RewardRecord>(predicate: #Predicate<RewardRecord> { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func liveGrantModels() -> [RewardRecord] {
        fetchRewardModels().filter {
            $0.kindRaw == RewardKind.grant.rawValue && $0.closedAt == nil && $0.taskId != nil
        }
    }

    /// Like `enforceSingleFrogInvariant`: tombstones are stamped BY HAND inside `withoutStamping`
    /// so only the rows this repair touches become pending, regardless of whether SwiftData drains
    /// its changed-set after the previous save.
    fileprivate func enforceOneLiveGrantPerTask() {
        let grants = liveGrantModels()
        let doomed = Set(RewardRules.duplicateGrantIDsToTombstone(grants.map { (item: $0.asItem, updatedAt: $0.updatedAt) }))
        guard !doomed.isEmpty else { return }
        withoutStamping {
            let stamp = TaskStore.syncStamp()
            for model in grants where doomed.contains(model.id) {
                model.deletedAt = stamp
                model.updatedAt = stamp
                model.syncedAt = nil
            }
            save()
        }
    }
}

// MARK: - SyncRewardStoring (implementation-contract.md §5)
extension TaskStore: SyncRewardStoring {
    /// INCLUDES tombstones; filtered in memory (see `pendingForSync`).
    func pendingRewardsForSync(limit: Int) -> [PendingReward] {
        fetchAllRewardModelsIncludingDeleted()
            .filter(\.isPendingSync)
            .sorted { $0.updatedAt < $1.updatedAt }
            .prefix(limit)
            .map { PendingReward(item: $0.asItem, updatedAt: $0.updatedAt, deletedAt: $0.deletedAt) }
    }

    /// `save()` (not throwing) on purpose — a lost confirmation just re-pushes once.
    func markRewardsSynced(_ confirmations: [UUID: Date]) {
        guard !confirmations.isEmpty else { return }
        withoutStamping {
            for (id, confirmedUpdatedAt) in confirmations {
                guard let model = fetchRewardModelIncludingDeleted(id) else { continue }
                model.syncedAt = TaskStore.confirmedStamp(confirmedUpdatedAt, local: model.updatedAt)
            }
            save()
        }
    }

    /// Record-level LWW via `SyncMerge.decide`; THROWS on a failed disk write so the engine does not
    /// advance its cursor (client-contract.md §4b).
    @discardableResult
    func applyRemoteRewards(_ remote: [RemoteReward]) throws -> [UUID] {
        guard !remote.isEmpty else { return [] }
        var written: [UUID] = []
        try withoutStamping {
            for entry in remote {
                if let local = fetchRewardModelIncludingDeleted(entry.id) {
                    guard SyncMerge.decide(localUpdatedAt: local.updatedAt, remoteUpdatedAt: entry.updatedAt) == .apply else { continue }
                    if let item = entry.item {
                        local.apply(item)
                    }
                    local.updatedAt = entry.updatedAt
                    local.deletedAt = entry.deletedAt
                    local.syncedAt = entry.updatedAt
                    written.append(entry.id)
                } else {
                    // Insert even a bare tombstone (item == nil) so a later stale pull has a row to
                    // lose against (client-contract.md §5).
                    let model = RewardRecord(id: entry.id, kind: entry.item?.kind ?? .catalog, createdAt: entry.updatedAt)
                    if let item = entry.item {
                        model.apply(item)
                    }
                    model.updatedAt = entry.updatedAt
                    model.deletedAt = entry.deletedAt
                    model.syncedAt = entry.updatedAt
                    context.insert(model)
                    written.append(entry.id)
                }
            }
            try saveThrowing()
        }
        enforceOneLiveGrantPerTask()
        return written
    }
}
