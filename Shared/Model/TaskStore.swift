// Sources/Model/TaskStore.swift — SwiftData ModelContainer + CRUD, mapped VolarTask <-> TaskItem.
// Enforces data-model.md's 6 persistence validation rules; everything else (VolarCore's own
// invariants — DAG-ness of `.taskDone` edges, ordering, eligibility) is delegated to VolarCore.
//
// TRUST BOUNDARY (self-review "client-side exploitable holes"): validation here runs on the
// WRITE path (`add`/`addBatch`/`addCondition`/`setRecurrence`/`setParent`). A store row edited
// directly on disk (hostile plist/db edit, cross-device sync corruption) bypasses all of it — the
// read path (`fetchAll`) does not re-validate `.taskDone` acyclicity or re-check the 10-task cap,
// both for cost (O(n) validateCondition-equivalent work on every launch) and because VolarCore's
// hot path (`nextTask`) is documented to tolerate a corrupted snapshot without crashing (dangling
// ids resolve as "satisfied", per contract). What IS defended unconditionally, including against
// a corrupted store: `ModelContext.parentId` cycle walks below always terminate (visited-set
// bounded), and JSON blob decode failures fail closed to empty/`nil` rather than throwing.
import Foundation
import SwiftData
import VolarCore

/// Errors surfaced by `TaskStore`'s validated mutation APIs. Every case carries a human-readable
/// message (constitution II: never silently guess or drop — always explain) suitable for direct
/// display.
enum TaskStoreError: Error, LocalizedError, Equatable {
    case invalidCondition(String)
    case parentNotFound
    case parentCycle(childTitle: String, parentTitle: String)
    case parentHasRecurrence(String)
    case recurrenceRequiresLeaf(String)
    case batchTooLarge(limit: Int)

    var errorDescription: String? {
        switch self {
        case .invalidCondition(let message):
            return message
        case .parentNotFound:
            return "That parent task no longer exists."
        case .parentCycle(let child, let parent):
            return "\u{201C}\(parent)\u{201D} can't become a sub-task of \u{201C}\(child)\u{201D} — that would create a loop."
        case .parentHasRecurrence(let title):
            return "\u{201C}\(title)\u{201D} repeats, so it can't have sub-tasks."
        case .recurrenceRequiresLeaf(let title):
            return "\u{201C}\(title)\u{201D} has sub-tasks, so it can't repeat on its own."
        case .batchTooLarge(let limit):
            return "Only \(limit) tasks can be created at once."
        }
    }
}

/// Owns the SwiftData container and exposes `TaskItem`-shaped CRUD so `AppState` never touches
/// `VolarTask`/`ModelContext` directly.
///
/// `init()` can throw (container creation can fail); callers (see `VolarApp.swift`) are expected
/// to `try?` it and fall back to `AppState`'s empty in-memory task list when it does, per the
/// architecture spec's "degrade gracefully if container init fails" requirement.
@MainActor
final class TaskStore {
    private let container: ModelContainer
    // Internal (not private): the `RewardStore.swift` extension needs it.
    let context: ModelContext

    /// Validation rule 6.
    static let maxBatchSize = 10

    /// Sentinel matching `VolarTask.updatedAt`'s literal default (`Date(timeIntervalSince1970: 0)`).
    /// Duplicated here rather than pointed at a shared static property because that model's own
    /// default expression must stay a bare, non-static-referencing literal for SwiftData
    /// lightweight migration (see `VolarTask.swift`'s header) — there is no static property to
    /// reference in the first place. Used by `fetchAll()`'s one-time sync backfill below.
    private static let unbackfilledSyncEpoch = Date(timeIntervalSince1970: 0)

    init() throws {
        let schema = Schema([VolarTask.self, CompletionEvent.self, ParseCorrection.self, RewardRecord.self])
        let configuration = ModelConfiguration(schema: schema)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
    }

    /// M-4 (test hygiene): in-memory variant (`ModelConfiguration(isStoredInMemoryOnly:)`) so
    /// callers like `ReminderSchedulerTests` don't accumulate/pollute rows in the real on-disk
    /// store across repeated local runs. Functionally identical to `init()` otherwise — same
    /// schema, same validated CRUD surface.
    init(inMemory: Bool) throws {
        let schema = Schema([VolarTask.self, CompletionEvent.self, ParseCorrection.self, RewardRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
    }

    /// Loads all persisted tasks. (Previously seeded SampleData on first run; removed — the app
    /// now starts empty so the user creates their own tasks.)
    func loadOrSeed() -> [TaskItem] {
        return fetchAll()
    }

    /// Also runs the one-time `dependsOn` -> `.taskDone` fold (migration note in VolarTask.swift),
    /// the one-time sync `updatedAt` backfill, and a local tombstone sweep (client-contract.md §5,
    /// design.md §6/§7) — saving once for the whole batch if anything changed. Operates on EVERY
    /// row (including tombstones — `fetchAllModelsIncludingDeleted()`), since a soft-deleted row
    /// still needs fold/backfill just as much as a live one.
    func fetchAll() -> [TaskItem] {
        let allModels = fetchAllModelsIncludingDeleted()
        var storeChanged = false

        // Fold + backfill run inside `withoutStamping`: neither is a "real" edit a sync partner
        // needs to hear about at `now()` — restamping them would make an upgrading user's entire
        // existing library look "just edited" and race to push on the very first sync.
        withoutStamping {
            for model in allModels where model.foldLegacyDependsOn() {
                storeChanged = true
            }
            for model in allModels where model.updatedAt == TaskStore.unbackfilledSyncEpoch {
                model.updatedAt = model.completedAt ?? model.createdAt
                storeChanged = true
            }
        }

        // Snapshot the live (non-tombstoned) result BEFORE the sweep below physically deletes
        // anything — reading a `@Model` instance's properties after `context.delete` is not
        // something to rely on, so every `TaskItem` this call returns is built from models that
        // are still fully alive at the moment they're read.
        let result = allModels.filter { $0.deletedAt == nil }.map(\.asTaskItem)

        // Local tombstone sweep (design.md §6): 30 days, deliberately shorter than the server's 90
        // — the server is what other still-offline devices need to catch up against; this is just
        // reclaiming local disk space for a delete every device has almost certainly already seen.
        // Inside `withoutStamping` too: physically removing a long-dead tombstone isn't a change
        // any other device needs to hear about "now".
        withoutStamping {
            let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
            // Collect first, delete after — do NOT call `context.delete` while still iterating
            // `allModels`. That array is a Swift snapshot returned by `context.fetch`, so
            // walk-and-delete would likely be safe in theory, but "in theory" here means never run
            // on Mac, and if wrong it fails as a runtime crash, not a compile error. Splitting into
            // two passes leaves nothing left to verify — far cheaper than chasing a crash later.
            let expired = allModels.filter { model in
                guard let deletedAt = model.deletedAt else { return false }
                return deletedAt < cutoff
            }
            for model in expired {
                context.delete(model)
                storeChanged = true
            }
            if storeChanged {
                save()
            }
        }

        return result
    }

    func add(_ item: TaskItem) {
        var snapshot = allEngineSnapshot()
        insertSanitized(item, snapshot: &snapshot)
        save()
    }

    /// Validation rule 6: caps any batch materialization at `maxBatchSize`. Each item is
    /// sanitized against a snapshot that grows as earlier items in the SAME batch are accepted,
    /// so intra-batch `.taskDone` references (e.g. an AI breakdown's later steps depending on
    /// earlier ones) validate correctly without a second pass.
    func addBatch(_ items: [TaskItem]) throws {
        guard items.count <= Self.maxBatchSize else {
            throw TaskStoreError.batchTooLarge(limit: Self.maxBatchSize)
        }
        var snapshot = allEngineSnapshot()
        for item in items {
            insertSanitized(item, snapshot: &snapshot)
        }
        save()
    }

    /// Validation rule 1: adds `condition` to task `id`, rejecting a `.taskDone` payload that
    /// would create a cycle or self-reference via `VolarCore.validateCondition`, with the human-
    /// readable message the contract promises. `.afterDate`/`.external` never throw (contract
    /// guarantee 5) so they always attach.
    func addCondition(_ condition: VolarCore.Condition, to id: UUID) throws {
        guard fetchModel(id) != nil else { return } // unknown id — nothing to attach to
        if case .taskDone = condition {
            do {
                try VolarCore.validateCondition(adding: condition, to: id, in: allEngineSnapshot())
            } catch let dependencyError as DependencyError {
                throw TaskStoreError.invalidCondition(Self.describe(dependencyError))
            }
        }
        guard let model = fetchModel(id) else { return }
        model.conditions.append(condition)
        save()
    }

    /// Việc 3 (confirm-list data layer, duplicate-detection merge, 2026-07-28): merges a freshly-
    /// confirmed draft into an ALREADY-PERSISTED task the user chose instead of creating a
    /// duplicate row (`AppState.ConfirmDraft.DuplicateResolution.useExisting`). `applying` receives
    /// the task's CURRENT `TaskItem` and returns the merged version — building it this way (a
    /// caller-supplied transform, rather than a long list of optional-field parameters) keeps every
    /// "present vs. absent" / "dismissed vs. accepted" rule exactly where it already lives
    /// (`AppState.resolvedValue`/`AppState.mergeTransform`), while this method owns the two things
    /// a bare field copy would get wrong:
    ///   - Validation rule 2 (recurrence only on a leaf): if the merged result would set a
    ///     recurrence on a task that has children, that ONE field is silently reverted back to the
    ///     task's existing recurrence rather than rejecting the whole merge outright (the merge
    ///     already represents something the user explicitly asked for — a save failing over one
    ///     attribute the calling utterance likely didn't even care about would be a worse
    ///     experience than dropping that one field, mirroring `sanitizedConditions`'s "partial
    ///     success beats losing everything" precedent below).
    ///   - Validation rule 1 (`.taskDone` cycle/self-reference): the merged `conditions` array is
    ///     re-run through `sanitizedConditions` — the SAME bulk-insert gate `add`/`addBatch` use —
    ///     so a merge can never smuggle in a cyclic edge `addCondition`'s single-edge path would
    ///     have caught.
    /// Reuses `VolarTask.apply(_:)` (already documented there as "the one obvious place a future
    /// 'edit task' API writes through") for the actual field sync, so this file has exactly one
    /// place that copies a `TaskItem`'s fields onto a live model. A no-op (returns `nil`, no save)
    /// for an unknown id — nothing to merge into.
    @discardableResult
    func mergeIntoExisting(_ id: UUID, applying transform: (TaskItem) -> TaskItem) -> TaskItem? {
        guard let model = fetchModel(id) else { return nil }
        var merged = transform(model.asTaskItem)
        if merged.recurrence != nil, hasChildren(id) {
            merged.recurrence = model.recurrence
        }
        merged.conditions = sanitizedConditions(merged.conditions, for: id, in: allEngineSnapshot())
        model.apply(merged)
        save()
        return merged
    }

    /// Manual-edit contract §1.3
    /// (`specs/002-workflow-command-center/contracts/manual-edit-contract.md`): writes the 7
    /// contract fields a user can edit by hand on an already-created task — `title`, `details`,
    /// `notes`, `priorityRaw`, `startTime`, `deadline`, `durationMinutes`, `reminderOverride` —
    /// plus `deadlineKind` (specs/010-calendar-and-hard-deadlines/design.md §3.1/§3.2: the
    /// `.hard`/`.soft` toggle in task detail writes through this same path) — then saves.
    /// `AppState.updateTask` (the manual-edit contract's single write path, §1.4) is the sole
    /// caller. Returns `false` (no save) for an unknown id.
    ///
    /// Deliberately does NOT go through `VolarTask.apply(_:)` even though that method's own doc
    /// comment invites a future "edit task" API to reuse it (`mergeIntoExisting` above already
    /// does, for its own validated merge path). `apply` also overwrites `conditions`/`parentId`/
    /// `createdAt`/`status`/`completedAt` — invariants (`.taskDone` DAG-ness, parent/child
    /// structure, recurring-task no-children rule, completion history) this call has no validated
    /// snapshot to re-check. `mergeIntoExisting` earns the right to use `apply` by re-running
    /// `sanitizedConditions`/the recurrence-vs-children guard on the merged result first; a bare
    /// 8-field manual edit does none of that and has no business touching any of the four.
    @discardableResult
    func updateEditableFields(from item: TaskItem) -> Bool {
        guard let model = fetchModel(item.id) else { return false }
        model.title = item.title
        model.details = item.details
        model.notes = item.notes
        model.priorityRaw = item.priority.rawValue
        model.startTime = item.startTime
        model.deadline = item.deadline
        model.deadlineKind = item.deadlineKind
        model.durationMinutes = item.durationMinutes
        model.reminderOverride = item.reminderOverride
        save()
        return true
    }

    /// Cycle-detection contract §1.4: removes the condition at `index` from task `id`. Returns
    /// `false` (no save, no mutation) if `id` is unknown or `index` is out of bounds — same "safe
    /// no-op for bad input" convention as `clearFirstExternal`/`delete` above. `addCondition`
    /// keeps rejecting a cyclic `.taskDone` via `TaskStoreError.invalidCondition`; this is purely
    /// the removal half (an edge always being removed can never introduce a cycle, so there's
    /// nothing to validate here).
    @discardableResult
    func removeCondition(at index: Int, from id: UUID) -> Bool {
        guard let model = fetchModel(id) else { return false }
        guard model.conditions.indices.contains(index) else { return false }
        model.conditions.remove(at: index)
        save()
        return true
    }

    /// Validation rule 2: recurrence is only ever allowed on a task with no children.
    func setRecurrence(_ recurrence: Recurrence?, on id: UUID) throws {
        guard let model = fetchModel(id) else { return }
        if recurrence != nil, hasChildren(id) {
            throw TaskStoreError.recurrenceRequiresLeaf(model.title)
        }
        model.recurrence = recurrence
        save()
    }

    /// Validation rule 3: `parentId` must reference an existing task, and the parent-link graph
    /// must stay acyclic. Also enforces the flip side of rule 2 (a recurring task can't gain
    /// children) since that's only checkable from this direction once a child is being attached.
    func setParent(_ childId: UUID, to parentId: UUID?) throws {
        guard let child = fetchModel(childId) else { return }
        guard let parentId else {
            child.parentId = nil
            save()
            return
        }
        if childId == parentId {
            throw TaskStoreError.parentCycle(childTitle: child.title, parentTitle: child.title)
        }
        guard let parent = fetchModel(parentId) else {
            throw TaskStoreError.parentNotFound
        }
        if parent.recurrence != nil {
            throw TaskStoreError.parentHasRecurrence(parent.title)
        }
        // Walk up from the PROPOSED parent following existing `parentId` links; if `childId` is
        // reached, attaching would close a cycle. The visited-set bounds the walk even against a
        // store that already contains a corrupted parent cycle above `parent` (defends the walk
        // itself, not just the edge being added — self-review "parentId cycle... must terminate").
        var visited: Set<UUID> = []
        var cursor: UUID? = parentId
        while let current = cursor {
            guard visited.insert(current).inserted else { break }
            if current == childId {
                throw TaskStoreError.parentCycle(childTitle: child.title, parentTitle: parent.title)
            }
            cursor = fetchModel(current)?.parentId
        }
        child.parentId = parentId
        save()
    }

    /// Mirrors `AppState.toggleDone`'s open/close semantics, but the persisted side now owns
    /// strictly more: marking done always appends an immutable `CompletionEvent` (research.md R7
    /// — the only durable record once a recurring task resets in place); a completed recurring
    /// task reopens at its next occurrence instead of staying `.done` (state machine: open ->
    /// done(moment) -> open(next), R8); completing the last open child of a parent auto-completes
    /// the parent too, cascading upward (validation rule 5).
    func toggle(
        _ id: UUID,
        now: Date = Date(),
        calendar: Calendar = .current,
        anchorRecurrenceToCompletion: Bool = false
    ) {
        guard let model = fetchModel(id) else { return }
        if model.status == .done {
            model.status = .todo
            model.completedAt = nil
            save()
            return
        }
        completeCascading(
            from: model, now: now, calendar: calendar,
            anchorRecurrenceToCompletion: anchorRecurrenceToCompletion
        )
        save()
    }

    /// Validation rule 4: strips the deleted id from every other task's `.taskDone` conditions
    /// and nulls children's `parentId`, then returns ids of OTHER tasks that flip newly-eligible
    /// as a result (via `VolarCore.eligibilityDiff`), so the caller can notify once instead of
    /// re-deriving it separately. `CompletionEvent`s referencing this id are left untouched by
    /// design (history, not a live reference — see CompletionLog.swift).
    @discardableResult
    func delete(_ id: UUID, now: Date = Date()) -> [UUID] {
        let before = fetchAllModels()
        guard before.contains(where: { $0.id == id }) else { return [] }
        let beforeSnapshot = before.map { $0.asTaskItem.snapshot() }

        for model in before where model.id != id {
            if model.parentId == id {
                model.parentId = nil
            }
            let stripped = model.conditions.filter { condition in
                if case .taskDone(let referenced) = condition { return referenced != id }
                return true
            }
            if stripped.count != model.conditions.count {
                model.conditions = stripped
            }
        }
        // Soft-delete (client-contract.md §5, design.md §6): tombstone instead of `context.delete`,
        // so an offline device that pulls this deletion later can APPLY it, instead of reading
        // "server has nothing here" as "never existed" and pushing its own stale copy back up
        // (design.md §6's whole reason for tombstones existing at all). This is a real edit — it
        // runs OUTSIDE `withoutStamping`, so `save()` stamps `updatedAt`, which is exactly what
        // makes the tombstone something another device will notice on its next pull.
        if let target = before.first(where: { $0.id == id }) {
            target.deletedAt = now
        }
        save()

        // `fetchAllModels()` already filters `deletedAt == nil`, so the just-tombstoned row is
        // correctly absent from `afterSnapshot` without any extra filtering here.
        let afterSnapshot = fetchAllModels().map { $0.asTaskItem.snapshot() }
        return VolarCore.eligibilityDiff(before: beforeSnapshot, after: afterSnapshot, now: now)
    }

    /// T036 (phase5-contract.md §C): voice-done's `.clearExternal` intent resolves to a task id
    /// only (contract A's `VoiceMatch` carries `taskId`/`title`/`score`, not which specific
    /// `.external` description matched) — this clears the FIRST still-unsatisfied `.external`
    /// condition on `id`, which covers the common case of exactly one outstanding external wait
    /// per task. A no-op (returns `[]`) for an unknown id or a task with nothing unsatisfied to
    /// clear. Mirrors `delete`'s pattern: returns newly-eligible task ids (via
    /// `VolarCore.eligibilityDiff`) so the caller notifies the scheduler once instead of
    /// recomputing the diff a second time (self-review "performance").
    ///
    /// Behavior UNCHANGED from before FIX 1 — now implemented via `clearFirstExternal(on:now:matching:)`
    /// with an always-true predicate.
    @discardableResult
    func clearFirstExternalCondition(on id: UUID, now: Date = Date()) -> [UUID] {
        clearFirstExternal(on: id, now: now, matching: { _ in true })
    }

    /// Shared implementation for `clearFirstExternalCondition`:
    /// finds the first unsatisfied `.external` condition on `id` whose description satisfies
    /// `match`, flips it to satisfied, saves, and returns newly-eligible task ids. A no-op
    /// (returns `[]`, no save) if `id` is unknown or nothing matches.
    private func clearFirstExternal(
        on id: UUID, now: Date, matching match: (String) -> Bool
    ) -> [UUID] {
        guard let model = fetchModel(id) else { return [] }
        guard let index = model.conditions.firstIndex(where: {
            if case .external(let description, let satisfied) = $0 { return !satisfied && match(description) }
            return false
        }) else { return [] }
        let beforeSnapshot = fetchAllModels().map { $0.asTaskItem.snapshot() }
        guard case .external(let description, _) = model.conditions[index] else { return [] }
        model.conditions[index] = .external(description: description, satisfied: true)
        save()
        let afterSnapshot = fetchAllModels().map { $0.asTaskItem.snapshot() }
        return VolarCore.eligibilityDiff(before: beforeSnapshot, after: afterSnapshot, now: now)
    }

    /// FIX 7 (seam): sets `id` as the single "frog of the day" on the PERSISTED side, clearing the
    /// flag on every other task (`nil` clears it everywhere, matching no task being frog). Mirrors
    /// `AppState.setFrog`'s in-memory single-frog invariant (`Volar/Sources/App/AppState.swift`)
    /// so the app-wiring agent's `store.setFrog(id)` call keeps the persisted store in sync with
    /// that in-memory array. Only touches models whose `frog` value actually changes, then saves
    /// once (or not at all if nothing changed) — same "don't churn the store" discipline as the
    /// rest of this file's mutators.
    func setFrog(_ id: UUID?) {
        var changed = false
        for model in fetchAllModels() {
            let shouldBeFrog = model.id == id
            if model.frog != shouldBeFrog {
                model.frog = shouldBeFrog
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    /// Constitution V / FR-044: appends one `ParseCorrection` row for a confirm-card chip edit
    /// (`AppState`'s chip-interaction methods, T024) — the only call site able to reach
    /// `ParseCorrectionLog.record` since it needs this store's private `ModelContext`
    /// (`ParseCorrection.swift`/T026 deliberately exposes no context of its own — see that file's
    /// header comment). Saves immediately: unlike `addBatch`, a chip edit isn't naturally batched
    /// with a larger transaction — it happens well before the user hits Save.
    func recordCorrection(attribute: String, parsed: String, corrected: String, transcript: String) {
        ParseCorrectionLog.record(attribute: attribute, parsed: parsed, corrected: corrected, transcript: transcript, in: context)
        save()
    }

    /// Computes "what's next" straight from the persisted snapshot via `VolarCore.nextTask`, for
    /// any caller that only has a `TaskStore` (no full `AppState`) — e.g. a future background
    /// refresh of the menu-bar label.
    func active(now: Date) -> TaskItem? {
        let all = fetchAll()
        guard let winner = VolarCore.nextTask(from: all.map { $0.snapshot() }, now: now, calendar: .current) else { return nil }
        return all.first { $0.id == winner.id }
    }

    /// Reminders subsystem seam (specs/002-workflow-command-center/contracts/phase4-contract.md
    /// §B): `VolarTask.isSensitive` is deliberately not threaded through `TaskItem` (see that
    /// field's doc comment in `VolarTask.swift`) — `ReminderScheduler`'s fire-time fresh reload
    /// needs to read it directly off the persisted model instead. Defaults to `false` (never
    /// sensitive) for an unknown/deleted id, matching every other "task not found" fallback in
    /// this file.
    ///
    /// 🔴 Do NOT change this fallback to `true` to "match" `TaskPayload.isSensitive`'s wire-decode
    /// fallback (also `?? true`, `Shared/Sync/SyncPayload.swift`) — the two `nil`s mean different
    /// things. Here, `nil` (from `fetchModel` returning nil) means "no task with this id exists at
    /// all" — there is no title to protect, so `false` costs nothing. There, a missing wire key
    /// means "a real task exists somewhere and a client just didn't say whether it's sensitive" —
    /// an entirely different kind of unknown, where guessing wrong is expensive. Same symbol
    /// (`isSensitive`), same shape of fallback (`?? Bool`), opposite direction, both correct for
    /// what `nil` means at that specific call site.
    func isSensitive(_ id: UUID) -> Bool {
        fetchModel(id)?.isSensitive ?? false
    }

    /// The only mutator that can ever set `isSensitive` (see `VolarTask.swift`'s doc comment on
    /// the field: as of that writing there was no path that ever set it to `true`). Exists so a
    /// future UI toggle — and `applyRemote` under sync, which now threads the flag across devices
    /// (specs/008-sync/client-contract.md, this field's own task) — have somewhere real to land a
    /// LOCAL edit. Returns `false` (no-op, no save) for an unknown id, and also when `isSensitive`
    /// already equals the requested value — same "don't churn the store" discipline as every other
    /// mutator in this file (`setFrog`/`setRecurrence`/...): a save that changes nothing would
    /// still stamp `updatedAt` and push a no-op edit to every other device.
    @discardableResult
    func setSensitive(_ isSensitive: Bool, on id: UUID) -> Bool {
        guard let model = fetchModel(id) else { return false }
        guard model.isSensitive != isSensitive else { return false }
        model.isSensitive = isSensitive
        save()
        return true
    }

    // MARK: - Completion internals

    /// Walks from `model` up through `parentId` links, completing (with recurrence reset where
    /// applicable) each task whose completion just emptied its parent's open-child set. A
    /// visited-set bounds the walk so a corrupted store containing a `parentId` cycle can't loop
    /// forever (defends the walk itself, not just edge creation — `setParent` already rejects
    /// creating new cycles going forward).
    private func completeCascading(
        from model: VolarTask, now: Date, calendar: Calendar, anchorRecurrenceToCompletion: Bool
    ) {
        var current = model
        var visited: Set<UUID> = []
        var anchorOverride = anchorRecurrenceToCompletion // only the task the user actually
        // completed gets the capture-time override; cascaded parent auto-completions always
        // reset on their own schedule.
        while visited.insert(current.id).inserted {
            completeOne(current, now: now, calendar: calendar, anchorToCompletion: anchorOverride)
            anchorOverride = false
            guard
                let parentId = current.parentId,
                let parent = fetchModel(parentId),
                parent.status != .done
            else { break }
            let hasOpenSiblings = fetchChildren(of: parentId).contains { $0.id != current.id && $0.status != .done }
            guard !hasOpenSiblings else { break }
            current = parent
        }
    }

    /// Completion for exactly one task: log + either recurrence reset-in-place or a plain
    /// `.done`.
    private func completeOne(_ model: VolarTask, now: Date, calendar: Calendar, anchorToCompletion: Bool) {
        model.completedAt = now
        if let recurrence = model.recurrence {
            // Validation rule 2 guarantees a recurring task has no children, so a parent reached
            // via the cascade above never hits this branch while also being "the auto-completed
            // parent" case — `assert` (not `precondition`) so a corrupted store that somehow
            // violates the invariant degrades to "resets like normal" in a release build instead
            // of crashing (self-review "must not crash-loop the app").
            assert(!hasChildren(model.id), "rule 2: a recurring task must have no children")
            let reset = RecurrenceEngine.reset(
                recurrence: recurrence,
                deadline: model.deadline,
                conditions: model.conditions,
                completedAt: now,
                anchorToCompletion: anchorToCompletion,
                calendar: calendar
            )
            model.deadline = reset.deadline
            model.conditions = reset.conditions
            model.status = .todo
        } else {
            model.status = .done
        }
        CompletionLog.recordCompletion(of: model, in: context)
    }

    // MARK: - Fetch helpers

    /// Filters `deletedAt == nil` (client-contract.md §5) — a soft-deleted row is invisible to
    /// every ordinary read path. Sync needs to see tombstones too; that's `fetchModelIncludingDeleted`
    /// below, not this one.
    private func fetchModel(_ id: UUID) -> VolarTask? {
        var descriptor = FetchDescriptor<VolarTask>(
            predicate: #Predicate<VolarTask> { $0.id == id && $0.deletedAt == nil }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Filters `deletedAt == nil` (client-contract.md §5).
    private func fetchAllModels() -> [VolarTask] {
        let descriptor = FetchDescriptor<VolarTask>(
            predicate: #Predicate<VolarTask> { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Filters `deletedAt == nil` (client-contract.md §5).
    private func fetchChildren(of parentId: UUID) -> [VolarTask] {
        let descriptor = FetchDescriptor<VolarTask>(
            predicate: #Predicate<VolarTask> { $0.parentId == parentId && $0.deletedAt == nil }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// // UNVERIFIED: `ModelContext.fetchCount(_:)` is part of the original macOS 14 SwiftData
    /// surface per Apple's WWDC23 materials — confirm it compiles/links against this project's
    /// deployment target on Mac; falls back to 0 (== "no children") on any fetch failure, which
    /// is the safe default for the rule-2 gate this guards. Filters `deletedAt == nil` (client-
    /// contract.md §5) — a soft-deleted child shouldn't count as a reason its ex-parent can't
    /// gain a recurrence.
    private func hasChildren(_ id: UUID) -> Bool {
        let descriptor = FetchDescriptor<VolarTask>(
            predicate: #Predicate<VolarTask> { $0.parentId == id && $0.deletedAt == nil }
        )
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    // MARK: - Fetch helpers (sync-only — see tombstones)
    //
    // The two below are the ONLY read paths in this file that do NOT filter `deletedAt == nil`.
    // Sync must see tombstones: `pendingForSync` needs to push them, and `applyRemote` needs to
    // find/revive them (client-contract.md §5).

    /// Like `fetchAllModels()` but includes tombstones. Used by `pendingForSync` and by the
    /// backfill/tombstone-sweep pass in `fetchAll()` — both must see every row, not just live ones.
    private func fetchAllModelsIncludingDeleted() -> [VolarTask] {
        let descriptor = FetchDescriptor<VolarTask>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Like `fetchModel(_:)` but includes tombstones. Used by `applyRemote(_:)` so a newer edit
    /// from another device can revive a task this device already soft-deleted locally, and by
    /// `markSynced(_:)` since a pushed tombstone still needs its confirmation recorded.
    private func fetchModelIncludingDeleted(_ id: UUID) -> VolarTask? {
        var descriptor = FetchDescriptor<VolarTask>(predicate: #Predicate<VolarTask> { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func allEngineSnapshot() -> [VolarCore.Task] {
        fetchAllModels().map { $0.asTaskItem.snapshot() }
    }

    /// Builds a `VolarTask` from `item`, filters its conditions through `sanitizedConditions`,
    /// inserts it, and appends its engine form to `snapshot` (in/out) so subsequent items in the
    /// same batch see it — shared by `add`/`addBatch` so their field-copy can't drift apart.
    @discardableResult
    private func insertSanitized(_ item: TaskItem, snapshot: inout [VolarCore.Task]) -> VolarTask {
        let model = VolarTask(
            id: item.id,
            title: item.title,
            details: item.details,
            priority: item.priority,
            status: item.status,
            deadline: item.deadline,
            startTime: item.startTime,
            createdAt: item.createdAt,
            when: item.when,
            durationMinutes: item.durationMinutes,
            frog: item.frog
        )
        model.conditions = sanitizedConditions(item.conditions, for: item.id, in: snapshot)
        model.parentId = item.parentId
        model.notes = item.notes
        model.sourceTranscript = item.sourceTranscript
        model.kind = item.kind
        model.deadlineKind = item.deadlineKind
        // Rule 2 (recurrence only on leaves): a brand-new task has no children yet, so accepting
        // `item.recurrence` unconditionally here can never violate it — children can only be
        // attached afterward via `setParent`, which itself rejects attaching to a recurring
        // parent.
        model.recurrence = item.recurrence
        model.reminderOverride = item.reminderOverride
        model.resumeNote = item.resumeNote
        model.switchAwayCount = item.switchAwayCount
        model.completedAt = item.completedAt
        model.delegation = item.delegation
        context.insert(model)
        snapshot.append(model.asTaskItem.snapshot())
        return model
    }

    /// Filters out any `.taskDone` condition that would fail `VolarCore.validateCondition` (self-
    /// reference or cycle) rather than throwing — used by the bulk-insert paths (`add`/
    /// `addBatch`), where surfacing a per-condition error isn't wired to any caller yet (that's
    /// `addCondition`'s job for the single-edge UI flow). `.afterDate`/`.external` never throw
    /// (contract guarantee 5) so they always pass through unchanged.
    private func sanitizedConditions(
        _ conditions: [VolarCore.Condition],
        for id: UUID,
        in snapshot: [VolarCore.Task]
    ) -> [VolarCore.Condition] {
        conditions.filter { condition in
            guard case .taskDone = condition else { return true }
            do {
                try VolarCore.validateCondition(adding: condition, to: id, in: snapshot)
                return true
            } catch {
                print("[Volar.TaskStore] dropped invalid condition on \(id): \(error)")
                return false
            }
        }
    }

    private static func describe(_ error: DependencyError) -> String {
        switch error {
        case .cycle(let from, let to):
            return "\u{201C}\(from)\u{201D} is already waiting on \u{201C}\(to)\u{201D} — making \u{201C}\(to)\u{201D} wait on \u{201C}\(from)\u{201D} would create a loop."
        case .selfDependency(let title):
            return "\u{201C}\(title)\u{201D} can't wait on itself."
        }
    }

    // MARK: - Sync stamping (client-contract.md §4)

    /// True only while `applyRemote`/`applyRemoteCompletions`/`markSynced`/`markCompletionsSynced`/
    /// the one-time backfill-and-sweep pass in `fetchAll()` are running. `save()` skips stamping
    /// while this is set — otherwise every row just pulled from the server (or just confirmed
    /// synced, or just backfilled) would immediately look "edited just now" and get pushed straight
    /// back up, and two devices would ping-pong forever (client-contract.md §4).
    ///
    /// ONE deliberate, explicit exception to "`save()` is the only place `updatedAt` is assigned":
    /// `enforceSingleFrogInvariant()` stamps its own two touched fields by hand while still inside
    /// `withoutStamping`, instead of letting a plain `save()` outside this flag do it. See that
    /// method's comment — it needs an update that is real (must propagate to other devices) without
    /// trusting `save()`'s bulk stamp to land on exactly the right rows.
    private var suppressStamp = false

    /// `rethrows` (not a plain non-throwing closure) so the SAME helper serves both the ordinary
    /// mutators (pass a non-throwing closure, no `try` needed at the call site — Swift's `rethrows`
    /// rule) and `applyRemote`/`applyRemoteCompletions` below (client-contract.md §4b), which need
    /// to propagate a failed `saveThrowing()` out to the sync engine rather than swallow it.
    /// `suppressStamp` is always returned to `false` via `defer`, including when `body` throws.
    // Internal: used by the `RewardStore.swift` extension.
    func withoutStamping(_ body: () throws -> Void) rethrows {
        suppressStamp = true
        defer { suppressStamp = false }
        try body()
    }

    /// THE only place `updatedAt` is assigned in the ordinary case (client-contract.md §1 rule 3 /
    /// §4). Every mutator in this file except `enforceSingleFrogInvariant()` ends by calling
    /// `save()`, and none of THOSE ever write `updatedAt` directly — that discipline is what makes
    /// this single spot sufficient instead of needing every current and future mutator to remember
    /// to stamp itself. (The one named exception stamps by hand for a documented reason — see
    /// `suppressStamp`'s doc comment above and `enforceSingleFrogInvariant()` below. It is not a
    /// second place this rule was quietly broken.)
    /// // UNVERIFIED: `context.insertedModelsArray` / `changedModelsArray` are SwiftData APIs never
    /// compiled on this machine (no Swift/Xcode on Windows) — confirm on Mac that both exist and
    /// return what their names imply, for macOS 14 / iOS 17 / watchOS 10. Documented fallback if
    /// they don't (client-contract.md §4): a `private func touch(_ model: VolarTask)` called
    /// explicitly at every mutator call site, plus a test asserting the call-site count — strictly
    /// worse (easy to forget at the next call site), but written down here so nobody "solves" a
    /// compile failure by scattering `updatedAt = Date()` around instead.
    ///
    /// Swallows a failed disk write on purpose (`try?` around `saveThrowing()` below) — by the time
    /// any of this file's ordinary mutators call `save()`, the user's action already completed on
    /// screen, and surfacing a flaky-disk error here would only turn a successful user-facing
    /// operation into a crash/error path for no benefit. `saveThrowing()` is the one exception,
    /// reserved for the path that applies data FROM the server (client-contract.md §4b).
    // Internal: used by the `RewardStore.swift` extension.
    func save() {
        try? saveThrowing()
    }

    /// Same stamping logic as `save()`, but THROWS instead of swallowing a failed disk write.
    /// Reserved for `applyRemote`/`applyRemoteCompletions` (client-contract.md §4b): if a write
    /// there fails silently, the sync engine still sees "success", advances its cursor past rows
    /// that were never actually persisted, and the server will never send them again — permanent,
    /// silent data loss with no crash involved. `markSynced`/`markCompletionsSynced` do NOT use
    /// this (see their doc comments) — losing a confirmation is harmless (just re-pushes once
    /// more), the asymmetric case is losing an APPLY.
    // Internal: used by the `RewardStore.swift` extension.
    func saveThrowing() throws {
        if !suppressStamp {
            let stamp = Date()
            for model in context.insertedModelsArray + context.changedModelsArray {
                (model as? VolarTask)?.updatedAt = stamp
                (model as? RewardRecord)?.updatedAt = stamp
            }
        }
        try context.save()
    }
}

// MARK: - SyncTaskStoring (specs/008-sync/client-contract.md §2)
//
// Declared here, not in `Shared/Sync/`, so `SyncEngine` (group B) never has to import SwiftData —
// this file is the one seam allowed to know both the sync wire types and `ModelContext`. Every
// method below is `@MainActor` for free since `TaskStore` itself is.
extension TaskStore: SyncTaskStoring {
    /// INCLUDES tombstones — a delete is just another pending edit (protocol doc comment), and
    /// exactly the kind of row most worth pushing first. Filtering to `isPendingSync` happens in
    /// memory rather than via `#Predicate`: that computed property force-unwraps an `Optional`
    /// inside its own comparison, which is not something the `#Predicate` macro is known to
    /// reliably translate into a SwiftData query — see `VolarTask.isPendingSync`.
    func pendingForSync(limit: Int) -> [PendingTask] {
        fetchAllModelsIncludingDeleted()
            .filter(\.isPendingSync)
            .sorted { $0.updatedAt < $1.updatedAt }
            .prefix(limit)
            .map {
                PendingTask(
                    item: $0.asTaskItem, updatedAt: $0.updatedAt, deletedAt: $0.deletedAt,
                    isSensitive: $0.isSensitive
                )
            }
    }

    /// Sets `syncedAt = confirmedUpdatedAt` for each id. MUST run inside `withoutStamping` — this
    /// only touches `syncedAt`, never `updatedAt`, but `save()` would otherwise restamp `updatedAt`
    /// to `now` as an incidental side effect of the row being in `context.changedModelsArray`,
    /// which would make the row dirty again the instant it was marked clean.
    ///
    /// Deliberately does NOT throw on a failed disk write (uses `save()`, not `saveThrowing()`),
    /// unlike `applyRemote`/`applyRemoteCompletions` below — the two failure directions are NOT
    /// symmetric (client-contract.md §4b). Losing this write just leaves the row's `syncedAt` stale,
    /// so the next push resends it — one wasted round trip, self-correcting, harmless. Losing an
    /// `applyRemote`/`applyRemoteCompletions` write while the caller still advances the cursor is
    /// permanent, silent data loss: the server never sends that row again. Same failure mode,
    /// opposite consequence, so it is handled oppositely on purpose — don't "clean this up" to
    /// match the other one.
    func markSynced(_ confirmations: [UUID: Date]) {
        guard !confirmations.isEmpty else { return }
        withoutStamping {
            for (id, confirmedUpdatedAt) in confirmations {
                fetchModelIncludingDeleted(id)?.syncedAt = confirmedUpdatedAt
            }
            save()
        }
    }

    /// Record-level LWW (design.md §5). Runs inside `withoutStamping` for the same reason as
    /// `markSynced` above: a row just pulled from the server is, by definition, already in sync —
    /// applying it must not make it look freshly edited.
    ///
    /// Deliberately does NOT run `VolarCore.validateCondition`/cycle-detection on incoming rows:
    /// this is the calling user's own data, already accepted once on whichever device created it,
    /// and a hard `where` gate here would silently drop a task instead of applying it — exactly the
    /// "nuốt mất việc" outcome this whole design exists to prevent. A `.taskDone` cycle that somehow
    /// made it this far is a cross-device data-hygiene problem, not a reason to lose a row.
    ///
    /// THROWS on a failed disk write (client-contract.md §4b), and the caller MUST NOT advance its
    /// sync cursor when this throws — a swallowed write failure here would make the engine believe
    /// these rows are safely on disk, advance past them, and the server would never send them again.
    /// No `@discardableResult`: the returned ids are not optional to look at either — see `written`.
    func applyRemote(_ remote: [RemoteTask]) throws -> [UUID] {
        guard !remote.isEmpty else { return [] }
        var written: [UUID] = []
        try withoutStamping {
            for entry in remote {
                if let local = fetchModelIncludingDeleted(entry.id) {
                    // Equal or older: idempotent no-op, not an error — the 2-second overlap window
                    // (design.md §4) is expected to resend rows we've already applied. Goes through
                    // `SyncMerge.decide` rather than re-deriving the comparison here: LWW is the
                    // single most important rule in this feature and must have exactly one copy —
                    // the one `SharedTests/SyncMergeTests.swift` (group D) actually exercises.
                    guard SyncMerge.decide(localUpdatedAt: local.updatedAt, remoteUpdatedAt: entry.updatedAt) == .apply else { continue }
                    if let item = entry.item {
                        local.apply(item)
                    }
                    local.updatedAt = entry.updatedAt
                    local.deletedAt = entry.deletedAt
                    local.syncedAt = entry.updatedAt
                    // `VolarTask.apply(_:)` deliberately does NOT touch `isSensitive` (that field
                    // is not part of `TaskItem`), so it must be written here explicitly or a
                    // remote update would silently leave whatever the flag already was — which
                    // happens to look harmless (the flag doesn't flip on its own) but would mean
                    // a device that flips it locally never sees the flip lost. Writing it
                    // unconditionally, same as every other synced field on this line.
                    local.isSensitive = entry.isSensitive
                    written.append(entry.id)
                } else {
                    // Never seen locally — insert even when `item == nil` (a bare tombstone for a
                    // task this device never had). Skipping it would let a LATER, staler pull
                    // re-insert the pre-deletion content, because there would be no local row left
                    // for the LWW comparison above to reject that stale insert against
                    // (client-contract.md §5).
                    // Minimal construction + `apply(item)` (rather than threading every field
                    // through the initializer) so this has exactly one place that copies a
                    // `TaskItem`'s fields onto a model — `apply(_:)` already covers every field
                    // that matters here, matching how `VolarTask.apply`'s own doc comment
                    // describes itself.
                    let model: VolarTask
                    if let item = entry.item {
                        model = VolarTask(id: entry.id, title: item.title, priority: item.priority, when: item.when)
                        model.apply(item)
                    } else {
                        model = VolarTask(
                            id: entry.id, title: "", priority: .medium,
                            createdAt: entry.updatedAt, when: .later
                        )
                    }
                    model.updatedAt = entry.updatedAt
                    model.deletedAt = entry.deletedAt
                    model.syncedAt = entry.updatedAt
                    model.isSensitive = entry.isSensitive
                    context.insert(model)
                    written.append(entry.id)
                }
            }
            try saveThrowing()
        }
        // One-frog invariant (design.md §3, last table row): LWW is per-record and cannot preserve
        // a cross-record invariant on its own, so two devices setting different frogs while both
        // offline merge into two frogs live at once. Fixing it is a REAL edit (turning a losing
        // frog off) that needs its own `updatedAt` stamp so it propagates to every other device —
        // see `enforceSingleFrogInvariant()` for why that stamp is applied by hand instead of by a
        // plain `save()` call out here.
        enforceSingleFrogInvariant()
        return written
    }

    /// Oldest `completedAt` first — see `CompletionLog.pendingForSync`. Completions are append-only
    /// with no `updatedAt`/conflict of their own (client-contract.md §2), so there is nothing more
    /// to this than a plain fetch.
    func pendingCompletions(limit: Int) -> [PendingCompletion] {
        CompletionLog.pendingForSync(limit: limit, in: context)
    }

    /// Runs inside `withoutStamping` — see `markSynced(_:)` above for why marking something clean
    /// must never look like an edit. Also mirrors that method in NOT throwing on a failed disk
    /// write — same asymmetry-with-`applyRemoteCompletions` reasoning documented there.
    func markCompletionsSynced(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        withoutStamping {
            CompletionLog.markSynced(ids, in: context)
            save()
        }
    }

    /// Insert-if-absent, matching the server's `on conflict do nothing` (0005_sync_schema.sql) —
    /// completions are append-only on both ends, so there is nothing to merge, only to add.
    ///
    /// THROWS on a failed disk write, same contract as `applyRemote` above (client-contract.md
    /// §4b): the caller must not advance its cursor when this throws. No `@discardableResult` —
    /// same reasoning as `applyRemote`.
    func applyRemoteCompletions(_ remote: [RemoteCompletion]) throws -> Int {
        guard !remote.isEmpty else { return 0 }
        var count = 0
        try withoutStamping {
            count = CompletionLog.applyRemote(remote, in: context)
            try saveThrowing()
        }
        return count
    }

    /// Design.md §3's last table row ("bất biến một-frog"): keeps the frog with the newest
    /// `updatedAt`, clears the rest. Only ever called from `applyRemote` above, right after its own
    /// `withoutStamping { ... try saveThrowing() }` block closes successfully (a throw from that
    /// block propagates out of `applyRemote` before this ever runs, per client-contract.md §4b).
    ///
    /// Runs inside `withoutStamping` and stamps `updatedAt` BY HAND on exactly the rows it touches,
    /// rather than clearing `frog` and letting a plain `save()` (outside `withoutStamping`) do the
    /// stamping for it. Reason: that plain `save()` would rely on `context.changedModelsArray`
    /// having been fully drained by the prior `saveThrowing()` call inside `applyRemote`'s own
    /// `withoutStamping` block — true only if SwiftData reliably clears the changed-set after a
    /// save, which is unverified on this machine. If that assumption doesn't hold, this second
    /// `save()` would stamp `updatedAt = now` on the ENTIRE batch just pulled from the server — the
    /// exact ping-pong bug `suppressStamp` exists to prevent, and one that would only ever surface
    /// with two real devices syncing, i.e. nearly undebuggable. Stamping only the rows this method
    /// itself changed is deterministic regardless of that unverified SwiftData behavior. Also
    /// resets `syncedAt = nil` on those rows — the fix must become pending again so the next push
    /// carries it to every other device; leaving `syncedAt` untouched would make this device's own
    /// fix look already-synced and it would never leave the device.
    ///
    /// Uses the ordinary swallow-the-error `save()`, NOT `saveThrowing()`, on purpose: this is a
    /// local, self-correcting repair running right after a batch that already, successfully, made
    /// it to disk. Losing this specific write just leaves two frogs live until the next batch
    /// exposes the duplicate again and it gets fixed then — unlike `applyRemote` itself, there is no
    /// cursor advancing on the strength of this write, so there is nothing irrecoverable to protect
    /// against here (client-contract.md §4b only requires `throws` on the writes a cursor depends
    /// on).
    private func enforceSingleFrogInvariant() {
        let frogs = fetchAllModels().filter(\.frog)
        guard frogs.count > 1, let winner = frogs.max(by: { $0.updatedAt < $1.updatedAt }) else { return }
        withoutStamping {
            let stamp = Date()
            for model in frogs where model.id != winner.id {
                model.frog = false
                model.updatedAt = stamp
                model.syncedAt = nil
            }
            save()
        }
    }
}
