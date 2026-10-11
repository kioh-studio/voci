// Shared/Sync/SyncPayload.swift — wire types for `sync_exchange` (client-contract.md §3.1, §6)
// plus the ONE pair of date helpers the whole sync client uses.
//
// UNVERIFIED: written on Windows, never compiled.
//
// WHY `TaskPayload` IS NOT `TaskItem`: `TaskItem` isn't `Codable`, and more importantly the wire
// shape must change SLOWER than the in-app shape (design.md §7 — the model has already changed 6
// times in 3 weeks). `TaskPayload` is a field-for-field mirror, decoded defensively (every field
// via `decodeIfPresent` with a fallback, same convention `ReminderPolicy`'s hand-rolled `Codable`
// already uses in `Recurrence.swift`) so a payload written by an OLDER or NEWER build — missing a
// field this build expects, or carrying one this build has never heard of — still decodes into
// *something* instead of taking down the whole record. See `SyncClient.swift` for the second,
// batch-level layer of the same tolerance (one bad row must not lose every other row in the page).
import Foundation
import VolarCore

// MARK: - ConditionDTO (private mirror of VolarTask.swift's own — see that file's doc comment for
// why this is hand-rolled rather than relying on `VolarCore.Condition` being `Codable`, which the
// frozen contract does not promise. Duplicated rather than shared because `VolarTask.swift`'s copy
// is `private` to that file and owned by group A — re-declaring the same small DTO here is cheaper
// and safer than reaching across an ownership boundary for four lines of code.)

private struct ConditionDTO: Codable {
    private enum Kind: String, Codable { case taskDone, afterDate, external }
    private var kind: Kind
    private var taskId: UUID?
    private var date: Date?
    private var description: String?
    private var satisfied: Bool?

    init(_ condition: VolarCore.Condition) {
        switch condition {
        case .taskDone(let id):
            kind = .taskDone; taskId = id
        case .afterDate(let date):
            kind = .afterDate; self.date = date
        case .external(let description, let satisfied):
            kind = .external; self.description = description; self.satisfied = satisfied
        }
    }

    /// A structurally-invalid element (e.g. `.taskDone` missing its id) decodes to `nil` rather
    /// than throwing — one bad condition is dropped, not the whole task (see file header).
    var asCondition: VolarCore.Condition? {
        switch kind {
        case .taskDone: return taskId.map { .taskDone($0) }
        case .afterDate: return date.map { .afterDate($0) }
        case .external:
            guard let description, let satisfied else { return nil }
            return .external(description: description, satisfied: satisfied)
        }
    }
}

// MARK: - TaskPayload

/// Field-for-field wire mirror of `TaskItem`. Lives inside `payload` in the request/response shape
/// (client-contract.md §3.1) — the server never reads it (it's opaque JSONB, migration 0005's own
/// header: "server đợt này là ống dẫn ngu").
///
/// `schemaVersion` is carried BOTH here (self-describing — a future reader of the raw JSONB column
/// doesn't need to join back to `tasks.schema_version` to know what shape it's looking at) AND
/// as a sibling field in the wrapper (`SyncTaskOutbound`/`SyncTaskInbound` below, matching
/// `tasks.schema_version`, the column the DB actually indexes/reasons about). The wrapper's
/// copy is authoritative; this one is redundant-by-design, not a second source of truth to keep in
/// sync by hand — `TaskPayload.init(_:)` always stamps `Self.currentSchemaVersion` and nothing
/// downstream reads this copy back out except `asTaskItem`, which doesn't consult it at all.
struct TaskPayload: Sendable, Equatable {
    static let currentSchemaVersion = 1

    var id: UUID
    var title: String
    var details: String
    var priority: Priority
    var status: TaskStatus
    var deadline: Date?
    var startTime: Date?
    var conditions: [VolarCore.Condition]
    var createdAt: Date
    var when: When
    var durationMinutes: Int?
    var frog: Bool
    var notes: String?
    var sourceTranscript: String?
    var kind: TaskKind
    var recurrence: Recurrence?
    var reminderOverride: ReminderPolicy?
    var resumeNote: String?
    var cue: TaskCue?
    var switchAwayCount: Int
    var completedAt: Date?
    var parentId: UUID?
    var delegation: DelegationMeta?
    var schemaVersion: Int
    /// Mirrors `VolarTask.isSensitive` (specs/008-sync/client-contract.md — this field's own task).
    /// NOT part of `TaskItem`/`asTaskItem` round-trip below — it never was and stays that way; it
    /// travels alongside the payload the same way `PendingTask.isSensitive`/`RemoteTask.isSensitive`
    /// carry it alongside `item` in `SyncContracts.swift`, for the identical reason (`TaskItem`
    /// deliberately does not carry this flag).
    ///
    /// THREE-WAY ASYMMETRY, deliberate — do not "fix" for consistency, it would reopen the exact
    /// privacy hole this field exists to close:
    ///  - The persisted column (`VolarTask.isSensitive`) defaults to `false`. Flipping that default
    ///    to `true` would retroactively mark every task on every existing install as sensitive on
    ///    upgrade — breaking every reminder currently working — to protect a local-row count that
    ///    has always been zero (no UI path sets `true` today).
    ///  - `TaskStore.isSensitive(_:)` (the LOCAL read) falls back to `false` for an unknown id —
    ///    `nil` there means "no such task", not "missing data", so there is nothing to hide.
    ///  - THIS field, decoded off the wire below, falls back to `true` when the key is absent or
    ///    the payload is otherwise unreadable. Here `nil`/missing means "a client that wrote this
    ///    payload didn't say" (older build, a platform — e.g. .NET Windows — that hasn't implemented
    ///    the flag yet), and the safe assumption under that uncertainty is the OPPOSITE of the
    ///    local-read case: guess quiet, never guess loud. A wrongly-hidden title is an inconvenience;
    ///    a wrongly-spoken one is the kind of incident that gets the app deleted.
    var isSensitive: Bool

    init(_ item: TaskItem, isSensitive: Bool = true) {
        id = item.id
        title = item.title
        details = item.details
        priority = item.priority
        status = item.status
        deadline = item.deadline
        startTime = item.startTime
        conditions = item.conditions
        createdAt = item.createdAt
        when = item.when
        durationMinutes = item.durationMinutes
        frog = item.frog
        notes = item.notes
        sourceTranscript = item.sourceTranscript
        kind = item.kind
        recurrence = item.recurrence
        reminderOverride = item.reminderOverride
        resumeNote = item.resumeNote
        cue = item.cue
        switchAwayCount = item.switchAwayCount
        completedAt = item.completedAt
        parentId = item.parentId
        delegation = item.delegation
        schemaVersion = Self.currentSchemaVersion
        self.isSensitive = isSensitive
    }

    /// Reconstructs a `TaskItem`. Declared as a plain (non-failable) computed property rather than
    /// `TaskItem?` — every field already decodes to *something* via `init(from:)`'s tolerant
    /// `decodeIfPresent` fallbacks below, so there is no state this can fail on today. Kept
    /// non-optional deliberately (not `TaskItem?`) so a future required field can't silently start
    /// swallowing whole records here without a compiler error forcing a decision at the call site.
    var asTaskItem: TaskItem {
        TaskItem(
            id: id,
            title: title,
            details: details,
            priority: priority,
            status: status,
            deadline: deadline,
            startTime: startTime,
            conditions: conditions,
            createdAt: createdAt,
            when: when,
            durationMinutes: durationMinutes,
            frog: frog,
            notes: notes,
            sourceTranscript: sourceTranscript,
            kind: kind,
            recurrence: recurrence,
            reminderOverride: reminderOverride,
            resumeNote: resumeNote,
            switchAwayCount: switchAwayCount,
            completedAt: completedAt,
            parentId: parentId,
            delegation: delegation,
            cue: cue
        )
    }
}

extension TaskPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, details, priority, status, deadline, startTime, conditions, createdAt,
             when, durationMinutes, frog, notes, sourceTranscript, kind, recurrence,
             reminderOverride, resumeNote, cue, switchAwayCount, completedAt, parentId,
             delegation, schemaVersion, isSensitive
    }

    /// EVERY field goes through `decodeIfPresent` with an explicit fallback — see file header.
    /// `id`/`title` are the only two fields with no safe fallback value (an empty-string title is
    /// "safe" in the sense that it decodes, even though it's a bad task) — a genuinely missing
    /// `id` throws, and the caller (`SyncClient`, batch-decoding one row at a time) treats that one
    /// row's payload as unreadable rather than losing the rest of the page (contract §2's
    /// `RemoteTask.item == nil` case exists exactly for this).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        details = try container.decodeIfPresent(String.self, forKey: .details) ?? ""
        priority = try container.decodeIfPresent(Priority.self, forKey: .priority) ?? .medium
        status = TaskPayload.status(
            from: try container.decodeIfPresent(String.self, forKey: .status)
        )
        deadline = try container.decodeIfPresent(Date.self, forKey: .deadline)
        startTime = try container.decodeIfPresent(Date.self, forKey: .startTime)
        let conditionDTOs = try container.decodeIfPresent([ConditionDTO].self, forKey: .conditions) ?? []
        conditions = conditionDTOs.compactMap(\.asCondition)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        when = try container.decodeIfPresent(When.self, forKey: .when) ?? .now
        durationMinutes = try container.decodeIfPresent(Int.self, forKey: .durationMinutes)
        frog = try container.decodeIfPresent(Bool.self, forKey: .frog) ?? false
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        sourceTranscript = try container.decodeIfPresent(String.self, forKey: .sourceTranscript)
        kind = try container.decodeIfPresent(TaskKind.self, forKey: .kind) ?? .task
        recurrence = try container.decodeIfPresent(Recurrence.self, forKey: .recurrence)
        reminderOverride = try container.decodeIfPresent(ReminderPolicy.self, forKey: .reminderOverride)
        resumeNote = try container.decodeIfPresent(String.self, forKey: .resumeNote)
        cue = try container.decodeIfPresent(TaskCue.self, forKey: .cue)
        switchAwayCount = try container.decodeIfPresent(Int.self, forKey: .switchAwayCount) ?? 0
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        parentId = try container.decodeIfPresent(UUID.self, forKey: .parentId)
        delegation = try container.decodeIfPresent(DelegationMeta.self, forKey: .delegation)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        // 🔴 Safe-default direction is INVERTED from every other field on this struct: `?? true`,
        // not `?? false`. A missing key here means another client (older build, or a platform that
        // hasn't implemented this flag yet) didn't say — see this property's doc comment above for
        // why guessing "sensitive" is the only safe guess.
        isSensitive = try container.decodeIfPresent(Bool.self, forKey: .isSensitive) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(details, forKey: .details)
        try container.encode(priority, forKey: .priority)
        try container.encode(TaskPayload.rawValue(for: status), forKey: .status)
        try container.encodeIfPresent(deadline, forKey: .deadline)
        try container.encodeIfPresent(startTime, forKey: .startTime)
        try container.encode(conditions.map(ConditionDTO.init), forKey: .conditions)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(when, forKey: .when)
        try container.encodeIfPresent(durationMinutes, forKey: .durationMinutes)
        try container.encode(frog, forKey: .frog)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(sourceTranscript, forKey: .sourceTranscript)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(recurrence, forKey: .recurrence)
        try container.encodeIfPresent(reminderOverride, forKey: .reminderOverride)
        try container.encodeIfPresent(resumeNote, forKey: .resumeNote)
        try container.encodeIfPresent(cue, forKey: .cue)
        try container.encode(switchAwayCount, forKey: .switchAwayCount)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(parentId, forKey: .parentId)
        try container.encodeIfPresent(delegation, forKey: .delegation)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(isSensitive, forKey: .isSensitive)
    }

    /// `VolarCore.TaskStatus` isn't `Codable` (frozen engine contract) — mapped to/from the same
    /// four raw strings `VolarTask.rawValue(for:)`/`VolarTask.status(from:)` use, kept as a SEPARATE
    /// private mapping here rather than reaching into `VolarTask.swift` (those statics are private
    /// to that file, and it's owned by group A) — two independent copies of a 4-case switch is a
    /// cheaper risk than a cross-file/cross-owner dependency for something this frozen.
    private static func rawValue(for status: TaskStatus) -> String {
        switch status {
        case .todo: return "todo"
        case .inProgress: return "inProgress"
        case .done: return "done"
        case .archived: return "archived"
        }
    }

    private static func status(from raw: String?) -> TaskStatus {
        switch raw {
        case "inProgress": return .inProgress
        case "done": return .done
        case "archived": return .archived
        default: return .todo
        }
    }
}

// MARK: - CompletionPayload

/// Field-for-field wire mirror of the three snapshot fields carried by `PendingCompletion`/
/// `RemoteCompletion` (`SyncContracts.swift`) — `id`/`taskId`/`completedAt` stay at the WRAPPER
/// level (matching `completions`'s actual columns), so this only holds what the DB calls
/// `payload`: the historical snapshot fields that have no column of their own.
struct CompletionPayload: Sendable, Equatable, Codable {
    var titleSnapshot: String
    var parentIdSnapshot: UUID?
    var estimateSnapshot: Int?

    init(_ pending: PendingCompletion) {
        titleSnapshot = pending.titleSnapshot
        parentIdSnapshot = pending.parentIdSnapshot
        estimateSnapshot = pending.estimateSnapshot
    }

    private enum CodingKeys: String, CodingKey { case titleSnapshot, parentIdSnapshot, estimateSnapshot }

    /// Same tolerance convention as `TaskPayload` — a missing `titleSnapshot` degrades to an empty
    /// title rather than losing the whole completion event (a completion is append-only and can
    /// never be re-sent once superseded, so silently dropping one here would be permanent).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        titleSnapshot = try container.decodeIfPresent(String.self, forKey: .titleSnapshot) ?? ""
        parentIdSnapshot = try container.decodeIfPresent(UUID.self, forKey: .parentIdSnapshot)
        estimateSnapshot = try container.decodeIfPresent(Int.self, forKey: .estimateSnapshot)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(titleSnapshot, forKey: .titleSnapshot)
        try container.encodeIfPresent(parentIdSnapshot, forKey: .parentIdSnapshot)
        try container.encodeIfPresent(estimateSnapshot, forKey: .estimateSnapshot)
    }
}

// MARK: - Wire wrappers (client-contract.md §3.1's per-element shapes)

/// One entry of `p_tasks` in the outbound request. Field names are camelCase and match the
/// contract's JSON EXACTLY via `Codable` synthesis — do not add a `CodingKeys` here without also
/// updating the contract doc.
struct SyncTaskOutbound: Sendable, Encodable {
    var id: UUID
    var updatedAt: Date
    var deletedAt: Date?
    var payload: TaskPayload
    var schemaVersion: Int

    init(_ pending: PendingTask) {
        id = pending.item.id
        updatedAt = pending.updatedAt
        deletedAt = pending.deletedAt
        payload = TaskPayload(pending.item, isSensitive: pending.isSensitive)
        schemaVersion = TaskPayload.currentSchemaVersion
    }
}

/// One entry of `tasks[]` in the response. `serverUpdatedAt`/`originDevice` only exist here (never
/// sent by the client) — see migration 0005's `tasks` table.
///
/// `payload` is decoded INDEPENDENTLY of every other field here (custom `init(from:)` below) —
/// deliberately NOT `TaskPayload` (non-optional) the way `SyncTaskOutbound` is, because that would
/// mean one unreadable `payload` drags down `id`/`updatedAt`/`deletedAt` too, and those are exactly
/// what a tombstone needs to apply correctly EVEN WHEN its payload can't be parsed at all
/// (`SyncContracts.swift`'s own `RemoteTask.item` doc comment: "nil only when the payload was
/// unreadable... a tombstone needs no content"). Losing the wrapper alongside a bad payload would
/// silently violate that guarantee.
struct SyncTaskInbound: Sendable {
    var id: UUID
    var updatedAt: Date
    var deletedAt: Date?
    /// `nil` only when the payload itself couldn't be parsed AT ALL (missing entirely, or not a
    /// JSON object) — a merely incomplete-but-present payload already survives via `TaskPayload`'s
    /// own tolerant `init(from:)` and never reaches `nil` here.
    var payload: TaskPayload?
    var schemaVersion: Int
    var serverUpdatedAt: Date
    var originDevice: String?

    /// Builds the `RemoteTask` `SyncEngine` hands to `TaskStore.applyRemote(_:)`. `item` mirrors
    /// `payload`'s own optionality exactly — see that field's doc comment.
    ///
    /// `isSensitive` falls back to `true` when `payload` itself is `nil` (unparseable) — same `??
    /// true` direction `TaskPayload.init(from:)` already applies for a merely-missing key; this
    /// covers the strictly worse case of the whole payload being unreadable, which must land on
    /// the same safe side.
    var asRemoteTask: RemoteTask {
        RemoteTask(
            id: id, updatedAt: updatedAt, deletedAt: deletedAt, item: payload?.asTaskItem,
            isSensitive: payload?.isSensitive ?? true
        )
    }
}

extension SyncTaskInbound: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, updatedAt, deletedAt, payload, schemaVersion, serverUpdatedAt, originDevice
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        // `try?`, not `try container.decodeIfPresent` — the point isn't "handle a missing key",
        // it's "handle a PRESENT-BUT-UNPARSEABLE value too" (schema skew this build has never seen,
        // not the ordinary missing/extra-field case `TaskPayload.init(from:)` already tolerates).
        payload = try? container.decode(TaskPayload.self, forKey: .payload)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        serverUpdatedAt = try container.decode(Date.self, forKey: .serverUpdatedAt)
        originDevice = try container.decodeIfPresent(String.self, forKey: .originDevice)
    }
}

/// One entry of `p_rewards` (011 contract §5). Same shape as `SyncTaskOutbound`; payload is `RewardItem`.
struct SyncRewardOutbound: Sendable, Encodable {
    var id: UUID
    var updatedAt: Date
    var deletedAt: Date?
    var payload: RewardItem
    var schemaVersion: Int

    init(_ pending: PendingReward) {
        id = pending.item.id
        updatedAt = pending.updatedAt
        deletedAt = pending.deletedAt
        payload = pending.item
        schemaVersion = 1
    }
}

/// One entry of `rewards[]` in the response. Payload decoded independently (`try?`) so a bad payload
/// still yields a wrapper a tombstone can use — same reasoning as `SyncTaskInbound`.
struct SyncRewardInbound: Sendable {
    var id: UUID
    var updatedAt: Date
    var deletedAt: Date?
    var payload: RewardItem?
    var schemaVersion: Int
    var serverUpdatedAt: Date
    var originDevice: String?

    var asRemoteReward: RemoteReward {
        RemoteReward(id: id, updatedAt: updatedAt, deletedAt: deletedAt, item: payload)
    }
}

extension SyncRewardInbound: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, updatedAt, deletedAt, payload, schemaVersion, serverUpdatedAt, originDevice
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        payload = try? container.decode(RewardItem.self, forKey: .payload)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        serverUpdatedAt = try container.decode(Date.self, forKey: .serverUpdatedAt)
        originDevice = try container.decodeIfPresent(String.self, forKey: .originDevice)
    }
}

/// One entry of `p_completions` in the outbound request.
struct SyncCompletionOutbound: Sendable, Encodable {
    var id: UUID
    var taskId: UUID
    var completedAt: Date
    var payload: CompletionPayload

    init(_ pending: PendingCompletion) {
        id = pending.id
        taskId = pending.taskId
        completedAt = pending.completedAt
        payload = CompletionPayload(pending)
    }
}

/// One entry of `completions[]` in the response.
struct SyncCompletionInbound: Sendable, Decodable {
    var id: UUID
    var taskId: UUID
    var completedAt: Date
    var payload: CompletionPayload
    var serverUpdatedAt: Date

    var asRemoteCompletion: RemoteCompletion {
        RemoteCompletion(
            id: id, taskId: taskId, completedAt: completedAt,
            titleSnapshot: payload.titleSnapshot,
            parentIdSnapshot: payload.parentIdSnapshot,
            estimateSnapshot: payload.estimateSnapshot
        )
    }
}

// MARK: - SyncExchangeRequest / SyncExchangeResponse (client-contract.md §3.1)

/// Top-level request body for `POST /rest/v1/rpc/sync_exchange`. `CodingKeys` map to the RPC's
/// ACTUAL parameter names (`p_cursor_tasks`, ...) — PostgREST binds top-level JSON body keys to
/// function parameter names by exact string match, so these are VERBATIM from
/// `0005_sync_schema.sql`'s `create or replace function public.sync_exchange(...)` signature, not
/// negotiable spelling.
///
/// `cursorTasks`/`cursorCompletions` are `String?` — NEVER `Date?`. Contract §6: Postgres emits up
/// to 6 fractional-second digits and this value must round-trip byte-for-byte or the cursor can
/// skip rows. Keeping the Swift type `String` makes that a compile-time guarantee, not a
/// convention someone has to remember.
struct SyncExchangeRequest: Sendable, Encodable {
    var cursorTasks: String?
    var cursorCompletions: String?
    var device: String
    var deviceLabel: String?
    var tasks: [SyncTaskOutbound]
    var completions: [SyncCompletionOutbound]
    /// Third stream (011 contract §5). Defaulted so existing call sites compile unchanged.
    var cursorRewards: String? = nil
    var rewards: [SyncRewardOutbound] = []
    var limit: Int

    private enum CodingKeys: String, CodingKey {
        case cursorTasks = "p_cursor_tasks"
        case cursorCompletions = "p_cursor_completions"
        case device = "p_device"
        case deviceLabel = "p_device_label"
        case tasks = "p_tasks"
        case completions = "p_completions"
        case cursorRewards = "p_cursor_rewards"
        case rewards = "p_rewards"
        case limit = "p_limit"
    }
}

/// Top-level response body. NOT `Decodable` — see `SyncClient.swift`'s `decode(from:)` for why:
/// this needs per-row tolerance (one malformed task must not sink every other row in the page),
/// which plain `Codable` synthesis on an array can't express (a single throwing element fails the
/// whole array decode). Built by hand from a `JSONSerialization`-parsed dictionary instead, same
/// idiom `VolarTask.conditions`'s getter already uses for the same reason.
struct SyncExchangeResponse: Sendable {
    /// Opaque, same reasoning as the request's cursor fields — never parsed to `Date`.
    var cursorTasks: String?
    var cursorCompletions: String?
    var tasks: [SyncTaskInbound]
    var completions: [SyncCompletionInbound]
    /// Absent from an OLD server's response -> `nil` / `[]` (defaults keep old call sites compiling).
    var cursorRewards: String? = nil
    var rewards: [SyncRewardInbound] = []
    var hasMore: Bool
    /// Task ids the client pushed that LOST an LWW conflict (contract §3.1) — the server already
    /// filed the losing payload in `sync_rejects`; this list just tells the client "the version you
    /// now have for this id came from the server, not from what you sent."
    var rejected: [UUID]
}

extension SyncExchangeResponse {
    /// Parses the raw response body leniently: a single malformed task or completion entry is
    /// DROPPED rather than failing the whole page — see this struct's own doc comment for why
    /// plain `Decodable` synthesis on `[SyncTaskInbound]` can't express that (one throwing element
    /// fails the entire array decode). Throws only when the TOP-LEVEL body isn't even a JSON
    /// object — a shape this client has no way to recover from at all, unlike a single bad row.
    static func decode(from data: Data) throws -> SyncExchangeResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [], debugDescription: "sync_exchange response is not a JSON object"
                )
            )
        }
        let decoder = SyncCoding.makeDecoder()
        let tasks: [SyncTaskInbound] = Self.lenientDecode(root["tasks"] as? [Any], using: decoder)
        let completions: [SyncCompletionInbound] = Self.lenientDecode(root["completions"] as? [Any], using: decoder)
        let rewards: [SyncRewardInbound] = Self.lenientDecode(root["rewards"] as? [Any], using: decoder)
        let rejected = (root["rejected"] as? [String])?.compactMap(UUID.init) ?? []

        return SyncExchangeResponse(
            cursorTasks: root["cursorTasks"] as? String,
            cursorCompletions: root["cursorCompletions"] as? String,
            tasks: tasks,
            completions: completions,
            cursorRewards: root["cursorRewards"] as? String,
            rewards: rewards,
            hasMore: root["hasMore"] as? Bool ?? false,
            rejected: rejected
        )
    }

    /// Same idiom `VolarTask.conditions`'s getter already uses (`VolarTask.swift`): re-serialize
    /// EACH array element on its own and decode it independently, so one bad element (`try?`
    /// returning `nil`) is skipped instead of a single `[Element]` decode failing for the whole
    /// batch.
    private static func lenientDecode<Element: Decodable>(
        _ rawElements: [Any]?, using decoder: JSONDecoder
    ) -> [Element] {
        guard let rawElements else { return [] }
        return rawElements.compactMap { element -> Element? in
            guard let elementData = try? JSONSerialization.data(withJSONObject: element) else { return nil }
            return try? decoder.decode(Element.self, from: elementData)
        }
    }
}

// MARK: - SyncDate (client-contract.md §6 — the ONE pair of date helpers for this whole client)

enum SyncDate {
    /// `withInternetDateTime` requires (and accepts) a numeric offset OR literal `Z` — both forms
    /// Postgres can emit — `withFractionalSeconds` additionally requires EXACTLY 3 digits after the
    /// decimal point, which is why `parse` truncates before handing off here.
    /// FIX (Swift 6 strict concurrency, first Mac build 2026-08-18): `ISO8601DateFormatter` is a
    /// class and is not `Sendable`, so a plain `static let` of one is global shared mutable state.
    /// Error: "static property 'withFraction' is not concurrency-safe".
    ///
    /// `nonisolated(unsafe)` is the right tool here rather than a cover-up, for one specific reason:
    /// both formatters are fully configured inside their own initializer closure and are NEVER
    /// mutated again — `parse`/`string(from:)` only ever call `date(from:)`/`string(from:)`, which
    /// Foundation documents as safe to call concurrently on a configured date formatter. The
    /// unsafety the compiler is warning about (one thread reconfiguring `formatOptions` while
    /// another parses) cannot occur because nothing in this file can reach `formatOptions` after
    /// construction. If that ever stops being true, this annotation becomes a lie — keep the
    /// formatters `private` so it stays checkable by reading this one file.
    ///
    /// The cleaner long-term fix is `Date.ISO8601FormatStyle`, a `Sendable` value type. Deliberately
    /// NOT done here: it parses with different strictness around `Z` vs `+00:00` and the fractional
    /// separator, and this is the sync path's date decoder — swapping it needs `SyncPayloadTests`
    /// green on a Mac, which this machine cannot run. Tracked in backlog.md.
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Fallback for a timestamp with NO fractional part at all (e.g. a value that happened to land
    /// on an exact second) — `withFraction` rejects those outright since it requires the `.###`.
    nonisolated(unsafe) private static let withoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Postgres emits up to 6 fractional-second digits (e.g. `2026-08-09T10:00:00.123456+00:00`);
    /// `ISO8601DateFormatter` accepts at most 3 and rejects the rest OUTRIGHT (returns `nil` for
    /// the whole string, not a truncated parse) — so this trims the fractional run to 3 digits
    /// first rather than losing the whole value. A string with zero fractional digits parses via
    /// `withoutFraction`. Returns `nil` only if neither formatter can make sense of the result —
    /// callers (`TaskPayload`'s date fields via `SyncCoding`'s decoder, below) treat that the same
    /// way any other malformed field is treated: this ONE value fails, not the whole record.
    static func parse(_ s: String) -> Date? {
        let truncated = truncateFractionalSeconds(s)
        return withFraction.date(from: truncated) ?? withoutFraction.date(from: truncated)
    }

    /// Always emits exactly 3 fractional digits + a numeric/`Z` offset — Postgres accepts this
    /// verbatim as a `timestamptz` literal.
    static func string(from date: Date) -> String {
        withFraction.string(from: date)
    }

    /// Truncates (never rounds — rounding could carry a `.9996` up into the whole-seconds field,
    /// which is more surgery than a wire-format quirk deserves) the first `.digits` run down to at
    /// most 3 digits. A string with no `.` at all, or already ≤3 digits, is returned unchanged.
    private static func truncateFractionalSeconds(_ s: String) -> String {
        guard let dotIndex = s.firstIndex(of: ".") else { return s }
        let afterDot = s.index(after: dotIndex)
        var digitsEnd = afterDot
        while digitsEnd < s.endIndex, s[digitsEnd].isNumber {
            digitsEnd = s.index(after: digitsEnd)
        }
        let digits = s[afterDot..<digitsEnd]
        guard digits.count > 3 else { return s }
        return s.replacingCharacters(in: afterDot..<digitsEnd, with: digits.prefix(3))
    }
}

// MARK: - SyncCoding (JSON coding config shared by every wire type above)

/// One seam so `updatedAt`/`deletedAt`/`completedAt`/`serverUpdatedAt`/`createdAt` — every `Date`
/// field anywhere in this file — round-trips through `SyncDate` consistently, without each caller
/// hand-rolling its own `JSONEncoder`/`JSONDecoder` date strategy. `cursorTasks`/`cursorCompletions`
/// are declared `String` (not `Date`) on `SyncExchangeRequest`/`Response`, so this strategy is
/// simply never invoked for them — the "never parse the cursor as a Date" rule is a type-level
/// guarantee, not something this enum has to remember to skip.
enum SyncCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(SyncDate.string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = SyncDate.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Not a parseable sync timestamp: \(raw)"
                )
            }
            return date
        }
        return decoder
    }
}
