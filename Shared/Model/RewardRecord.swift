// Shared/Model/RewardRecord.swift — Earned break data (specs/011-ios-companion/plan.md §2,
// implementation-contract.md §4). One table, two kinds: `catalog` (a reward the user defined) and
// `grant` (a reward attached to one task/goal). State is DERIVED (`RewardRules.state`), never stored.
//
// UNVERIFIED: written on Windows, never compiled. Follows `VolarTask`'s @Model conventions: a plain
// literal default on every non-optional so SwiftData lightweight migration can read it.
import Foundation
import SwiftData

enum RewardKind: String, Codable, Sendable {
    case catalog, goal, grant
}

enum RewardIcon: String, CaseIterable, Codable, Sendable {
    case gamepad, tv, headphones, cup, book, walk

    var systemImage: String {
        switch self {
        case .gamepad: return "gamecontroller"
        case .tv: return "tv"
        case .headphones: return "headphones"
        case .cup: return "cup.and.saucer"
        case .book: return "book"
        case .walk: return "figure.walk"
        }
    }
}

@Model
final class RewardRecord {
    @Attribute(.unique) var id: UUID
    var kindRaw: String = "catalog"
    /// Catalog name, or the grant's SNAPSHOT of it.
    var title: String?
    var minutes: Int?
    var iconRaw: String?
    /// Legacy column = `taskIds.first`, kept so rows saved before multi-goal still read.
    var taskId: UUID?
    /// Goal only (multi-goal-rewards.md G1): the goal's tasks; the goal is done when ALL are done.
    var taskIds: [UUID] = []
    /// Grant only: the goals; the reward unlocks when ALL are done.
    var goalIds: [UUID] = []
    /// Grant only; nil = a goal without a reward.
    var rewardId: UUID?
    var breakStartedAt: Date?
    var breakEndsAt: Date?
    var startedDevice: String?
    var closedAt: Date?
    var remindWhenOver: Bool = true
    var createdAt: Date = Date()
    /// Stamped by `TaskStore.saveThrowing()`, exactly like `VolarTask.updatedAt`.
    var updatedAt: Date = Date(timeIntervalSince1970: 0)
    var deletedAt: Date?
    var syncedAt: Date?

    var isPendingSync: Bool { syncedAt == nil || syncedAt! < updatedAt }

    init(id: UUID = UUID(), kind: RewardKind = .catalog, createdAt: Date = Date()) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.createdAt = createdAt
    }

    var asItem: RewardItem {
        RewardItem(
            id: id,
            kind: RewardKind(rawValue: kindRaw) ?? .catalog,
            title: title,
            minutes: minutes,
            icon: iconRaw.flatMap { RewardIcon(rawValue: $0) },
            taskIds: taskIds.isEmpty ? [taskId].compactMap { $0 } : taskIds,
            goalIds: goalIds,
            rewardId: rewardId,
            breakStartedAt: breakStartedAt,
            breakEndsAt: breakEndsAt,
            startedDevice: startedDevice,
            closedAt: closedAt,
            remindWhenOver: remindWhenOver,
            createdAt: createdAt
        )
    }

    /// Copies every field except `id`/`updatedAt`/`deletedAt`/`syncedAt`.
    func apply(_ item: RewardItem) {
        kindRaw = item.kind.rawValue
        title = item.title
        minutes = item.minutes
        iconRaw = item.icon?.rawValue
        taskId = item.taskIds.first
        taskIds = item.taskIds
        goalIds = item.goalIds
        rewardId = item.rewardId
        breakStartedAt = item.breakStartedAt
        breakEndsAt = item.breakEndsAt
        startedDevice = item.startedDevice
        closedAt = item.closedAt
        remindWhenOver = item.remindWhenOver
        createdAt = item.createdAt
    }
}

/// Plain-value form of a reward row; also the sync wire payload (dates via `SyncCoding`).
struct RewardItem: Identifiable, Sendable, Equatable, Codable {
    let id: UUID
    var kind: RewardKind
    var title: String?
    var minutes: Int?
    var icon: RewardIcon?
    /// Goal only; else [].
    var taskIds: [UUID]
    /// Grant only; else [].
    var goalIds: [UUID]
    var rewardId: UUID?
    var breakStartedAt: Date?
    var breakEndsAt: Date?
    var startedDevice: String?
    var closedAt: Date?
    var remindWhenOver: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: RewardKind = .catalog,
        title: String? = nil,
        minutes: Int? = nil,
        icon: RewardIcon? = nil,
        taskIds: [UUID] = [],
        goalIds: [UUID] = [],
        rewardId: UUID? = nil,
        breakStartedAt: Date? = nil,
        breakEndsAt: Date? = nil,
        startedDevice: String? = nil,
        closedAt: Date? = nil,
        remindWhenOver: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.minutes = minutes
        self.icon = icon
        self.taskIds = taskIds
        self.goalIds = goalIds
        self.rewardId = rewardId
        self.breakStartedAt = breakStartedAt
        self.breakEndsAt = breakEndsAt
        self.startedDevice = startedDevice
        self.closedAt = closedAt
        self.remindWhenOver = remindWhenOver
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, minutes, icon, taskId, taskIds, goalIds, rewardId, breakStartedAt, breakEndsAt
        case startedDevice, closedAt, remindWhenOver, createdAt
    }

    /// Tolerant like `TaskPayload`: only `id` is required; an unknown `kind`/`icon` string (a newer
    /// build) falls back instead of failing the whole row.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = (try c.decodeIfPresent(String.self, forKey: .kind)).flatMap { RewardKind(rawValue: $0) } ?? .catalog
        title = try c.decodeIfPresent(String.self, forKey: .title)
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes)
        icon = (try c.decodeIfPresent(String.self, forKey: .icon)).flatMap { RewardIcon(rawValue: $0) }
        if let ids = try c.decodeIfPresent([UUID].self, forKey: .taskIds) {
            taskIds = ids
        } else {
            taskIds = (try c.decodeIfPresent(UUID.self, forKey: .taskId)).map { [$0] } ?? []
        }
        goalIds = try c.decodeIfPresent([UUID].self, forKey: .goalIds) ?? []
        rewardId = try c.decodeIfPresent(UUID.self, forKey: .rewardId)
        breakStartedAt = try c.decodeIfPresent(Date.self, forKey: .breakStartedAt)
        breakEndsAt = try c.decodeIfPresent(Date.self, forKey: .breakEndsAt)
        startedDevice = try c.decodeIfPresent(String.self, forKey: .startedDevice)
        closedAt = try c.decodeIfPresent(Date.self, forKey: .closedAt)
        remindWhenOver = try c.decodeIfPresent(Bool.self, forKey: .remindWhenOver) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// Writes BOTH `taskId` (= first) and `taskIds` so an older build still reads the row (G3).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(minutes, forKey: .minutes)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(taskIds.first, forKey: .taskId)
        try c.encode(taskIds, forKey: .taskIds)
        try c.encode(goalIds, forKey: .goalIds)
        try c.encodeIfPresent(rewardId, forKey: .rewardId)
        try c.encodeIfPresent(breakStartedAt, forKey: .breakStartedAt)
        try c.encodeIfPresent(breakEndsAt, forKey: .breakEndsAt)
        try c.encodeIfPresent(startedDevice, forKey: .startedDevice)
        try c.encodeIfPresent(closedAt, forKey: .closedAt)
        try c.encode(remindWhenOver, forKey: .remindWhenOver)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

enum RewardState: Sendable, Equatable {
    case locked, unlocked, running, ended
}

enum RewardRules {
    /// plan §2.2. Break progress wins over the goals' done flags: unticking a task mid-break keeps
    /// the timer (no penalty). Only a grant that never started a break falls back to `allGoalsDone`.
    /// A catalog or goal row is never unlocked.
    static func state(of grant: RewardItem, allGoalsDone: Bool, now: Date) -> RewardState {
        if grant.closedAt != nil { return .ended }
        if grant.breakStartedAt != nil {
            guard let ends = grant.breakEndsAt else { return .ended }
            return now < ends ? .running : .ended
        }
        return (grant.kind == .grant && allGoalsDone) ? .unlocked : .locked
    }

    /// G2: a goal is done when it has tasks and every one is done.
    static func isGoalDone(_ goal: RewardItem, doneTaskIds: Set<UUID>) -> Bool {
        !goal.taskIds.isEmpty && goal.taskIds.allSatisfy { doneTaskIds.contains($0) }
    }

    /// plan §2.3 + G3 — per goalId keep the newest grant (`updatedAt`; tie: larger
    /// uuidString, deterministic). A grant that loses on ANY of its goals is returned and gets
    /// tombstoned whole. Callers pass only LIVE grants (not deleted, not closed).
    // ponytail: whole-grant tombstone can also drop a loser's other, uncontested goals; splitting
    // the grant instead is the upgrade if that ever bites.
    static func duplicateGrantIDsToTombstone(_ grants: [(item: RewardItem, updatedAt: Date)]) -> [UUID] {
        var winner: [UUID: (id: UUID, updatedAt: Date)] = [:]
        for g in grants {
            for goalId in g.item.goalIds {
                if let w = winner[goalId] {
                    let newer = g.updatedAt > w.updatedAt
                        || (g.updatedAt == w.updatedAt && g.item.id.uuidString > w.id.uuidString)
                    if newer { winner[goalId] = (g.item.id, g.updatedAt) }
                } else {
                    winner[goalId] = (g.item.id, g.updatedAt)
                }
            }
        }
        return grants.compactMap { g in
            g.item.goalIds.contains { winner[$0]?.id != g.item.id } ? g.item.id : nil
        }
    }
}
