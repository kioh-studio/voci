// Shared/Sync/SyncContracts.swift — the seam every sync group codes against.
//
// UNVERIFIED: written on Windows, never compiled. Types only — no networking, no SwiftData, no
// SwiftUI, so this file compiles on macOS, iOS and (later) watchOS identically.
//
// Pinned by `specs/008-sync/client-contract.md` §2. Changing a name or a field here silently
// breaks a sibling file owned by a different agent — change the contract doc first.
import Foundation

/// One local task waiting to be pushed. Built by `TaskStore.pendingForSync()` (group A), consumed
/// by `SyncEngine` (group B). Carries `TaskItem` rather than the `@Model` on purpose: the wire
/// shape must never be a live SwiftData object crossing an actor boundary.
struct PendingTask: Sendable {
    var item: TaskItem
    /// The task's logical clock — the value stamped by `TaskStore.save()`. Never `Date()` read here.
    var updatedAt: Date
    /// Non-nil = tombstone. The payload is still sent in full (design §6: a later edit may revive it).
    var deletedAt: Date?
    /// Mirrors `VolarTask.isSensitive` (see that field's doc comment) — carried alongside `item`,
    /// not inside it, because `TaskItem` deliberately does not carry this flag (the
    /// `ReminderScheduler` seam VolarTask.swift documents). `TaskStore.pendingForSync` is the only
    /// producer; it always fills this from the real column. The default here exists only so a
    /// call site that predates this field (test fixtures) still compiles — every real producer
    /// passes an explicit value.
    var isSensitive: Bool = true
}

/// One remote task the server says we should apply. Produced by `SyncEngine` after decoding the
/// wire payload, consumed by `TaskStore.applyRemote(_:)` (group A).
struct RemoteTask: Sendable {
    var id: UUID
    var updatedAt: Date
    var deletedAt: Date?
    /// `nil` only when the payload was unreadable (schema skew, corrupt row). A `nil` item with a
    /// non-nil `deletedAt` is still applicable — a tombstone needs no content.
    var item: TaskItem?
    /// Mirrors `VolarTask.isSensitive`, carried alongside (not inside) `item` for the same reason
    /// as `PendingTask.isSensitive` above. Produced by `SyncTaskInbound.asRemoteTask`, which
    /// defaults an absent/unparseable wire value to `true` — see `TaskPayload.isSensitive`'s doc
    /// comment for the full three-way asymmetry this is one leg of. The default here (also `true`)
    /// exists only so pre-existing call sites (test fixtures built before this field existed)
    /// still compile; `TaskStore.applyRemote` always receives an explicit value from the producer.
    var isSensitive: Bool = true
}

/// One local completion event waiting to be pushed. `CompletionEvent` is append-only, so there is
/// no `updatedAt` and no conflict — see `completions` in 0005.
struct PendingCompletion: Sendable {
    var id: UUID
    var taskId: UUID
    var completedAt: Date
    var titleSnapshot: String
    var parentIdSnapshot: UUID?
    var estimateSnapshot: Int?
}

/// One remote completion to insert locally if absent. Same shape as `PendingCompletion` — the
/// separate type exists so a reader never has to ask which direction a value is travelling.
struct RemoteCompletion: Sendable {
    var id: UUID
    var taskId: UUID
    var completedAt: Date
    var titleSnapshot: String
    var parentIdSnapshot: UUID?
    var estimateSnapshot: Int?
}

/// The THREE outcomes of §8.2, kept apart by the type system so no call site can accidentally
/// collapse them into "sync failed". Every UI string for these lives in group C; this enum carries
/// no copy of its own beyond `LocalizedError` fallbacks.
enum SyncFailure: Error, Equatable, Sendable {
    /// 403 + message `sync_pro_required`. The account is not Pro (or Pro lapsed).
    case proRequired
    /// 403 + message `sync_disabled`. The account-level toggle is OFF. **This is not an error** —
    /// it is a state. UI shows "Sync is off for this account" plus a way to turn it on.
    case disabled
    /// 401 + message `sync_not_authenticated`, or no local session at all.
    case signedOut
    /// Transport failure: offline, timeout, DNS, TLS. **Silent** — the UI shows nothing.
    case offline(String)
    /// Anything else the server said (5xx, malformed body, unexpected status). Retried later,
    /// surfaced only in the diagnostics row — never as a banner.
    case server(status: Int, message: String?)
}

/// Server truth about the account-level switch. Decoded from `volar_sync_state()` (and returned by
/// `volar_set_sync_enabled`). Group C owns fetching it; group B reads it after any 403.
struct SyncState: Sendable, Equatable, Codable {
    var isPro: Bool
    var syncEnabled: Bool
    var enabledAt: Date?
    var enabledByDevice: String?
    var devices: [SyncDevice]

    static let unknown = SyncState(
        isPro: false, syncEnabled: false, enabledAt: nil, enabledByDevice: nil, devices: []
    )
}

struct SyncDevice: Sendable, Equatable, Codable, Identifiable {
    var deviceId: String
    var label: String?
    var lastSeen: Date?

    var id: String { deviceId }
}

/// One losing record kept in `public.sync_rejects` — design §5's black box. Read-only in v1.
struct SyncReject: Sendable, Equatable, Identifiable {
    var id: UUID
    var taskId: UUID
    var updatedAt: Date
    var rejectedAt: Date
    var originDevice: String?
    /// The losing payload verbatim, pretty-printed. Kept as a string, not a decoded `TaskItem`:
    /// this row exists precisely because the shape may be from another build.
    var payloadJSON: String
    /// Best-effort title lifted out of the payload for the list row; `nil` if unreadable.
    var title: String?
}

/// The seam `SyncEngine` (B) uses to reach persistence (A) without importing SwiftData itself.
/// `TaskStore` declares conformance inside `TaskStore.swift`; every method below is implemented
/// there. `@MainActor` because `TaskStore` is.
@MainActor
protocol SyncTaskStoring: AnyObject {
    /// Every row with `isPendingSync == true`, oldest `updatedAt` first, capped at `limit`.
    /// INCLUDES tombstones (`deletedAt != nil`) — a delete is just another pending edit.
    func pendingForSync(limit: Int) -> [PendingTask]
    /// Marks rows as confirmed by the server: sets `syncedAt = confirmedUpdatedAt` for each id.
    /// A row edited again in the meantime stays pending because its `updatedAt` moved past this.
    func markSynced(_ confirmations: [UUID: Date])
    /// Applies a batch of remote rows under LWW. MUST NOT re-stamp `updatedAt` (see §4).
    /// Returns the ids it actually wrote (for logging/tests); rows that lost LWW are skipped.
    /// THROWS if the write to disk failed — the caller MUST NOT advance the cursor in that case
    /// (see §4b). Swallowing this is silent permanent data loss with no crash involved.
    @discardableResult
    func applyRemote(_ remote: [RemoteTask]) throws -> [UUID]
    /// Append-only completions still to push, oldest first, capped at `limit`.
    func pendingCompletions(limit: Int) -> [PendingCompletion]
    func markCompletionsSynced(_ ids: [UUID])
    /// Inserts any completion whose id is not already present. Never updates an existing row.
    /// THROWS on a failed disk write, same contract as `applyRemote` above (see §4b).
    @discardableResult
    func applyRemoteCompletions(_ remote: [RemoteCompletion]) throws -> Int
}

// MARK: - Rewards stream (011-ios-companion implementation-contract §5)
// UNVERIFIED: written on Windows, never compiled. Mirrors the task stream above.

/// One local reward row (catalog or grant) waiting to be pushed. Built by C1's `TaskStore` conformance.
struct PendingReward: Sendable {
    var item: RewardItem
    var updatedAt: Date
    /// Non-nil = tombstone; payload still sent in full.
    var deletedAt: Date?
}

/// One remote reward row to apply. `item == nil` only when the payload was unreadable; a tombstone
/// with a nil item is still applicable.
struct RemoteReward: Sendable {
    var id: UUID
    var updatedAt: Date
    var deletedAt: Date?
    var item: RewardItem?
}

/// Same shape as `SyncTaskStoring`, for rewards. `TaskStore` conforms in `RewardStore.swift` (C1).
@MainActor
protocol SyncRewardStoring: AnyObject {
    /// Rows with `isPendingSync == true`, oldest `updatedAt` first, capped at `limit`. Includes tombstones.
    func pendingRewardsForSync(limit: Int) -> [PendingReward]
    /// Sets `syncedAt = confirmed updatedAt` per id; a row edited meanwhile stays pending.
    func markRewardsSynced(_ confirmations: [UUID: Date])
    /// LWW via `SyncMerge.decide`, without stamping `updatedAt`. THROWS on a failed disk write; the
    /// caller must not advance the cursor then (client-contract §4b). Returns ids actually written.
    @discardableResult func applyRemoteRewards(_ remote: [RemoteReward]) throws -> [UUID]
}

extension Notification.Name {
    /// Posted by `SyncEngine` after a round applied at least one remote task or reward.
    /// userInfo: `["taskIds": [UUID], "rewardIds": [UUID]]`.
    static let volarSyncDidApplyRemote = Notification.Name("volar.sync.didApplyRemote")
}
