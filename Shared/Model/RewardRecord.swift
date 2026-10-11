// Shared/Model/RewardRecord.swift — Earned break data (specs/011-ios-companion/plan.md §2,
// implementation-contract.md §4). One table, two kinds: `catalog` (a reward the user defined) and
// `grant` (a reward attached to one task/goal). State is DERIVED (`RewardRules.state`), never stored.
//
// UNVERIFIED: written on Windows, never compiled. Follows `VolarTask`'s @Model conventions: a plain
// literal default on every non-optional so SwiftData lightweight migration can read it.
import Foundation
import SwiftData

enum RewardKind: String, Codable, Sendable {
    case catalog, grant
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
    /// Grant only.
    var taskId: UUID?
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
            taskId: taskId,
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
        taskId = item.taskId
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
    var taskId: UUID?
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
        taskId: UUID? = nil,
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
        self.taskId = taskId
        self.rewardId = rewardId
        self.breakStartedAt = breakStartedAt
        self.breakEndsAt = breakEndsAt
        self.startedDevice = startedDevice
        self.closedAt = closedAt
        self.remindWhenOver = remindWhenOver
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, minutes, icon, taskId, rewardId, breakStartedAt, breakEndsAt
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
        taskId = try c.decodeIfPresent(UUID.self, forKey: .taskId)
        rewardId = try c.decodeIfPresent(UUID.self, forKey: .rewardId)
        breakStartedAt = try c.decodeIfPresent(Date.self, forKey: .breakStartedAt)
        breakEndsAt = try c.decodeIfPresent(Date.self, forKey: .breakEndsAt)
        startedDevice = try c.decodeIfPresent(String.self, forKey: .startedDevice)
        closedAt = try c.decodeIfPresent(Date.self, forKey: .closedAt)
        remindWhenOver = try c.decodeIfPresent(Bool.self, forKey: .remindWhenOver) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

enum RewardState: Sendable, Equatable {
    case locked, unlocked, running, ended
}

enum RewardRules {
    /// plan §2.2. Break progress wins over the task's done flag: unticking a task mid-break keeps
    /// the timer (no penalty). Only a grant that never started a break falls back to `taskDone`.
    /// A catalog row is never unlocked.
    static func state(of grant: RewardItem, taskDone: Bool, now: Date) -> RewardState {
        if grant.closedAt != nil { return .ended }
        if grant.breakStartedAt != nil {
            guard let ends = grant.breakEndsAt else { return .ended }
            return now < ends ? .running : .ended
        }
        return (grant.kind == .grant && taskDone) ? .unlocked : .locked
    }

    /// plan §2.3 — per task keep the newest `updatedAt` (tie: larger uuidString, deterministic) and
    /// return the ids of the rest. Callers pass only LIVE grants (not deleted, not closed).
    static func duplicateGrantIDsToTombstone(_ grants: [(item: RewardItem, updatedAt: Date)]) -> [UUID] {
        var winner: [UUID: (id: UUID, updatedAt: Date)] = [:]
        for g in grants {
            guard let taskId = g.item.taskId else { continue }
            if let w = winner[taskId] {
                let newer = g.updatedAt > w.updatedAt
                    || (g.updatedAt == w.updatedAt && g.item.id.uuidString > w.id.uuidString)
                if newer { winner[taskId] = (g.item.id, g.updatedAt) }
            } else {
                winner[taskId] = (g.item.id, g.updatedAt)
            }
        }
        return grants.compactMap { g in
            guard let taskId = g.item.taskId, let w = winner[taskId], w.id != g.item.id else { return nil }
            return g.item.id
        }
    }
}
