// Sources/Reminders/ReminderScheduler.swift — durable reminder scheduling + fire-time delivery
// (specs/002-workflow-command-center/contracts/phase4-contract.md §A, constitution IV, T029).
//
// PERSISTENCE DESIGN NOTE: this scheduler owns its own `ModelContainer`/`ModelContext` for
// `ReminderRecord`, kept separate from `TaskStore`'s container (`Sources/Model/TaskStore.swift`,
// schema `[VolarTask.self, CompletionEvent.self, ParseCorrection.self]`). This task owns
// `Model/ReminderRecord.swift` but explicitly not `TaskStore.swift`, so extending TaskStore's
// schema/init wasn't an option without touching a file outside this task's ownership. A single
// shared container would be a reasonable future consolidation (worth a backlog line — flagged in
// this task's final report rather than written to `backlog.md` directly, per this task's "do not
// edit backlog" constraint) but is NOT required for correctness: `ReminderRecord` rows are just as
// durable in their own named SwiftData store, and `rebuildFromStorage()` reconciles against
// `TaskStore.fetchAll()` regardless of which container either side lives in.
import Foundation
import SwiftData
import UserNotifications
#if os(iOS)
import UIKit
#endif
// i-2: this file uses `TaskStatus`/`TaskItem` (both re-exported via the `Volar` module's own
// `Sources/Model/TaskItem.swift`, which itself does `import VolarCore`) — importing VolarCore
// directly here too, rather than relying on the same-module typealias visibility, so this
// compiles even if that indirection is ever narrowed.
import VolarCore

// `NSObject` inheritance is load-bearing, not decorative: this class self-assigns as
// `UNUserNotificationCenter.current().delegate` in `init` (see below) and conforms to
// `UNUserNotificationCenterDelegate` (an `@objc` protocol with optional methods) in the extension
// at the bottom of this file — optional-method `@objc` dispatch requires `NSObject` lineage.
@MainActor
final class ReminderScheduler: NSObject {
    private let store: TaskStore
    private let voice: VoiceReminderChannel
    private let gate: ReminderContextGate
    private let context: ModelContext
    private let center = UNUserNotificationCenter.current()

    /// Headroom under `UNUserNotificationCenter`'s documented ~64 pending-local-notification cap
    /// (research.md R2) — leaves room for any other notification source the app might add later
    /// and avoids racing the exact ceiling.
    static let systemRequestCap = 60

    #if os(iOS)
    /// iOS equivalent of the macOS wake path this file's `init` doc comment describes (and
    /// deliberately does NOT itself register any more — that responsibility moved to
    /// `VolarApp.swift`'s `NSWorkspace.shared.notificationCenter` observer after the `m-2` fix).
    /// There is no `VolarIOS/Sources/App/*` file yet (Phase 1, out of this task's scope) to own an
    /// app-lifetime foreground observer the way `VolarApp.swift` owns the macOS one, so this
    /// self-registers instead — the same idiom macOS's `init` tried and abandoned, but WITHOUT
    /// that idiom's actual bug: macOS's problem was `NSWorkspace.didWakeNotification` posting on
    /// `NSWorkspace.shared.notificationCenter`, not `NotificationCenter.default` — `UIApplication
    /// .didBecomeActiveNotification` is documented to post on `NotificationCenter.default`, so
    /// there is no equivalent "wrong center" trap here.
    private var foregroundObserverToken: NSObjectProtocol?
    #endif

    // MARK: - Full-screen escalation (the last rung above system notification + voice — see
    // `sweepForFullScreenEscalation()` below, and `Sources/Reminders/FullScreenEscalationDecision.swift`/
    // `FullScreenTakeoverWindow.swift` for the pure decision + the window itself)

    // The seam this file is built around (plan 007 §2): the DECISION to escalate is shared —
    // `FullScreenEscalationDecision` is platform-neutral, lives in `Shared/`, and is unit-tested
    // for every platform. Only the PRESENTATION is macOS-only, because a full-screen `NSPanel`
    // seizing the display is a desktop gesture; `FullScreenTakeoverWindow` therefore stays in
    // `Volar/Sources/Reminders/` and is not compiled for iOS or watchOS at all.
    //
    // Consequence, deliberately accepted for now: iOS reaches the same "this needs escalating"
    // conclusion and then has nowhere to put it. The intended iOS/watchOS surface is a local
    // notification plus haptic rather than a takeover window — not built yet, tracked in
    // backlog.md. Guarding rather than stubbing keeps that gap loud instead of shipping an
    // escalation path that silently does nothing.
    #if os(macOS)
    private let takeoverWindow = FullScreenTakeoverWindow()
    #endif
    /// Records that have already been offered ONE full-screen takeover this run. Deliberately
    /// one-shot per record, not a re-nag loop: both "Xong" and "Tôi thấy rồi — 10 phút nữa" already
    /// change the record's state/urgency so it stops qualifying on its own (see
    /// `handleAction`/`reschedule`); this set exists specifically to also cover the THIRD outcome —
    /// the 60s auto-close timeout, where nothing about the record changes at all. Without this
    /// guard, an ignored takeover would reappear on every later sweep tick
    /// (`fullScreenSweepInterval`) forever, which is the opposite of anh Khôi's explicit
    /// no-rage requirement for this feature. In-memory only (not persisted): a relaunch starts
    /// this set empty again, so a record that timed out before quitting CAN be offered once more
    /// after a relaunch — an accepted, documented trade-off, not an oversight (flagged in this
    /// task's report as a candidate follow-up if anh Khôi instead wants persistent one-shot state
    /// or a repeat cadence).
    private var escalatedRecordIds: Set<UUID> = []
    // NO `fullScreenSweepTimer` STORED PROPERTY, and no `deinit` (2026-08-01). Both used to exist
    // purely so `deinit` could `invalidate()` the sweep timer, on the assumption that
    // `Timer.invalidate()` being thread-safe made it legal there. It isn't: a `deinit` on a
    // `@MainActor` class runs NONISOLATED under Swift 6, and reaching a stored property of the
    // non-`Sendable` type `Timer?` from that context is a hard error ("cannot access property
    // 'fullScreenSweepTimer' with a non-Sendable type 'Timer?'") — the thread-safety of the method
    // being CALLED is irrelevant, it's touching the property at all that's rejected.
    //
    // Same conclusion `HotkeyManager.swift` already reached for the identical rule ("No `deinit`:
    // teardown happens via `stop()`... Swift 6 also forbids a `deinit` on a `@MainActor`-isolated
    // class from touching actor-isolated stored properties"). Teardown moved INTO the timer block
    // instead — see `startFullScreenEscalationSweep()`, where the tick invalidates its own timer as
    // soon as `self` is gone. Nothing else ever read this property, so storing it bought nothing
    // once `deinit` couldn't use it.
    /// How often the sweep re-checks for a delivered, high-urgency, non-nudge record that has sat
    /// undismissed long enough to escalate. Independent of `FullScreenEscalationDecision.ignoredAfter`
    /// (the 5-minute "has it been ignored" threshold) — this is just the polling cadence.
    private static let fullScreenSweepInterval: TimeInterval = 60

    /// Seam for "Volar's own capture panel is mid-recording" (contract §B — a takeover must never
    /// fight the app's own capture UI). `AppState`/`AppDelegate` (App-wiring, not owned by this
    /// task) is the only place with a live reference to `CapturePanelController`'s driving state
    /// (`appState.captureState`), so this defaults to a closure that always answers `false` ("not
    /// capturing") until that owner assigns a real one — same "unwired extension point reads as no
    /// signal" convention `ReminderContextGate.isLocalMicCaptureActive` already established (see
    /// that file's header comment). THE MISSING WIRING LINE (for whoever owns `AppState.swift`):
    /// after constructing `scheduler`, add `scheduler.isVolarCapturing = { [weak self] in
    /// self?.captureState == .recording }`. Until that line exists, this check can never block a
    /// takeover on Volar's own recording — flagged prominently in this task's final report.
    var isVolarCapturing: () -> Bool = { false }

    init(store: TaskStore, voice: VoiceReminderChannel, gate: ReminderContextGate) {
        self.store = store
        self.voice = voice
        self.gate = gate
        self.context = Self.makeContext()
        super.init()

        // Self-wire as the notification-center delegate right here: `AppState` (App-wiring,
        // sibling-owned) constructs exactly one `ReminderScheduler` for the app's lifetime and
        // retains it (`AppState.scheduler`), so `self` is already the long-lived instance the
        // delegate property needs a strong-enough reference to keep working — no separate
        // delegate object for another agent to construct/retain (see `AppDelegate.swift`'s own
        // comment: it deliberately did NOT assign this, leaving it to "contract A/B's own
        // initializer"). See the `UNUserNotificationCenterDelegate` conformance at the bottom of
        // this file.
        UNUserNotificationCenter.current().delegate = self

        #if os(iOS)
        // R2 (plan.md §8) / T5a: rebuild on every foreground, not just launch — this is iOS's
        // wake-recovery equivalent of the macOS `NSWorkspace.didWakeNotification` path. `@Sendable`
        // + explicit `_Concurrency.Task { @MainActor in }` hop mirrors this file's own
        // `willPresent`/`didReceive` convention below (system-invoked closures on this
        // `@MainActor` class must not be inferred MainActor-isolated, or Swift 6's runtime
        // isolation check traps). Qualified `_Concurrency.Task` — not plain `Task` — for the same
        // reason every other call site in this file is: `import VolarCore` (top of file) brings in
        // `VolarCore.Task` (the engine's model struct), which shadows `Swift.Task` here.
        foregroundObserverToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { @Sendable [weak self] _ in
            _Concurrency.Task { @MainActor in
                self?.rebuildFromStorage()
            }
        }
        #endif

        // Constitution IV: rebuild on wake as well as launch. LAUNCH is the constructing caller's
        // responsibility — call `rebuildFromStorage()` once right after building this scheduler
        // (kept out of `init` itself so the initializer stays synchronous/side-effect-light and
        // testable). WAKE recovery is intentionally NOT wired here (m-2): this used to register an
        // observer on `NotificationCenter.default`, but `NSWorkspace.didWakeNotification` actually
        // posts on `NSWorkspace.shared.notificationCenter` — that observer never fired and was
        // deleted rather than fixed in place, since `VolarApp.swift` (App-wiring, sibling-owned)
        // already has the correct wake path wired via `NSWorkspace.shared.notificationCenter` and
        // calls `scheduler?.rebuildFromStorage()` from there.

        // macOS-only: the sweep exists solely to drive `FullScreenTakeoverWindow`. Starting it on
        // iOS would burn a 60s timer forever to reach a presentation call that does not exist.
        #if os(macOS)
        startFullScreenEscalationSweep()
        #endif
    }

    // MARK: - Contract §A

    /// Rebuilds ALL scheduler state from durable storage: re-derives reminders for every open,
    /// dated task that doesn't have any `ReminderRecord` yet (covers a task created/edited before
    /// this scheduler existed, or a derivation that never landed) — and, for a no-deadline task
    /// specifically, ALSO re-derives once its current nudge batch has fully fired, so "lặp mãi mỗi
    /// 3 ngày" actually keeps going instead of going quiet after the first batch (see
    /// `ensureDerived`'s doc comment for the full reasoning and why that doesn't apply to a
    /// deadline task) — fires any `.scheduled` record already past due ("due-but-missed" recovery
    /// — constitution IV), then refills the system's pending-request queue with the nearest-N.
    /// Call once at launch; also called automatically on `NSWorkspace.didWakeNotification` (see
    /// `init`). O(n) in the number of persisted tasks/records: one `TaskStore.fetchAll()`, one
    /// records fetch, one dictionary build — no nested re-fetching per record.
    func rebuildFromStorage() {
        let now = Date()
        let tasks = store.fetchAll()
        // WG-nudge: this used to require `$0.deadline != nil` too, so an open task with no
        // deadline never got any reminder derived for it at all. anh Khôi's approved design gives
        // every open task SOME reminder now — a deadline-anchored one if it has a deadline, else a
        // gentle createdAt-anchored backoff nudge (`ReminderRecord.derive`'s no-deadline branch) —
        // so this only gates on lifecycle status, not on whether a deadline is set.
        let openTasks = tasks.filter { $0.status == .todo || $0.status == .inProgress }
        for task in openTasks {
            ensureDerived(
                taskId: task.id, deadline: task.deadline, createdAt: task.createdAt,
                priority: task.priority.rawValue, reminderOverride: task.reminderOverride, now: now
            )
        }

        let byId = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        // FIX B: a notification the OS already delivered while the app was backgrounded/not
        // running never routed through `willPresent`/`presentationDecision` (those only fire
        // when the app is alive to receive the delegate callback), so its record is stuck at
        // `.scheduled` forever — the due-but-missed pass below would then treat it as missed and
        // re-fire it as a SECOND notification on every future launch/wake. Reconcile against
        // `UNUserNotificationCenter.deliveredNotifications()` first so an already-delivered record
        // is marked `.delivered` (not re-fired) before the due-but-missed pass runs.
        // `deliveredNotifications()` is async-only, so this whole rebuild (reconciliation +
        // due-but-missed pass + refill, in that order) moves inside a single `_Concurrency.Task`
        // hop — same fire-and-forget pattern `refillSystemRequests()` already uses elsewhere in
        // this file — so callers keep calling this as a plain synchronous method.
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcileDeliveredNotifications()

            let dueButMissed = self.fetchAllRecords().filter { $0.state == "scheduled" && $0.fireAt <= now }
            for record in dueButMissed {
                self.fire(record, using: byId)
            }

            self.refillSystemRequests()
        }
    }

    /// FIX B helper: marks every `.scheduled` record whose id matches an already-OS-delivered
    /// notification's identifier as `.delivered`, in a single batched save (one `fetchAllRecords()`
    /// — no fetch-in-loop). No-op if nothing was delivered or nothing needs updating.
    private func reconcileDeliveredNotifications() async {
        let delivered = await center.volarDeliveredSummaries()
        guard !delivered.isEmpty else { return }
        let deliveredIds = Set(delivered.compactMap { UUID(uuidString: $0.identifier) })
        guard !deliveredIds.isEmpty else { return }
        var didChange = false
        for record in fetchAllRecords() where record.state == "scheduled" && deliveredIds.contains(record.id) {
            record.state = "delivered"
            didChange = true
        }
        if didChange { save() }
    }

    /// Derives + persists this task's reminder set from its deadline × (`reminderOverride` ??
    /// global `ReminderPolicy`), replacing any not-yet-delivered rows from a prior derivation
    /// (deadline edits, recurrence resets land here). Delivered/satisfied history is left alone —
    /// this only ever touches `.scheduled` rows. A closed (`done`/`archived`) task gets no
    /// reminders at all.
    func scheduleReminders(for task: VolarTask) {
        deriveAndSchedule(
            taskId: task.id, status: task.status, deadline: task.deadline, createdAt: task.createdAt,
            priority: task.priorityRaw, reminderOverride: task.reminderOverride
        )
    }

    /// WG-1/M-3 (constitution IV, ship-blocker): `scheduleReminders(for: VolarTask)` above can't
    /// actually be called from `AppState` — `VolarTask` is the SwiftData persistence model this
    /// file/`TaskStore` own; `AppState` only ever holds `TaskItem` snapshots and has no way to
    /// obtain a live `VolarTask` instance (`TaskStore.fetchModel` is private). This is the real
    /// seam the App-wiring agent needs: resolve the task fresh from `store` by id (same "read
    /// `TaskItem`, not `VolarTask`" convention every other method on this class already uses — see
    /// `evaluate(_:snapshot:)`) and derive from that. A missing/deleted id is treated as "nothing
    /// to schedule," not an error — mirrors every other not-found fallback in this subsystem.
    func scheduleReminders(taskId: UUID) {
        guard let task = store.fetchAll().first(where: { $0.id == taskId }) else { return }
        deriveAndSchedule(
            taskId: taskId, status: task.status, deadline: task.deadline, createdAt: task.createdAt,
            priority: task.priority.rawValue, reminderOverride: task.reminderOverride
        )
    }

    /// Shared body for both `scheduleReminders` overloads above, so the derive logic can't drift
    /// apart between them.
    private func deriveAndSchedule(
        taskId: UUID, status: TaskStatus, deadline: Date?, createdAt: Date, priority: Int?,
        reminderOverride: ReminderPolicy?
    ) {
        clearScheduled(taskId: taskId)
        guard status == .todo || status == .inProgress else { return }
        let records = ReminderRecord.derive(
            taskId: taskId, deadline: deadline, createdAt: createdAt, priority: priority,
            reminderOverride: reminderOverride, globalPolicy: Self.currentGlobalReminderPolicy(), now: Date()
        )
        for record in records { context.insert(record) }
        save()
        refillSystemRequests()
    }

    /// Cancels every reminder for `taskId` — both the durable rows and any request already
    /// registered with the system — so completion/deletion never leaves an orphaned notification
    /// behind (constitution IV's cascade requirement). Safe to call for a task with no reminders.
    func cancelReminders(taskId: UUID) {
        let records = recordsForTask(taskId)
        guard !records.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: records.map(\.id.uuidString))
        for record in records { context.delete(record) }
        save()
        refillSystemRequests()
    }

    /// Fresh reload + fire "right now": reloads the task fresh from `store` and suppresses
    /// (resolves the record to `.satisfied`, delivers nothing) if it's done/archived/deleted;
    /// otherwise posts an immediate system notification and speaks if the escalation rule says to.
    /// Used for (1) due-but-missed recovery (`rebuildFromStorage`) and (2) the immediate-delivery
    /// helpers below (`scheduleResurface`/`notifyUnblocked`/`offerReschedule`). NOT used for a
    /// reminder the OS is already about to present live on its own schedule — that path is
    /// `presentationDecision(for:)`, so a pre-registered system banner is never duplicated.
    func handleFire(recordId: UUID) {
        guard let record = fetchRecord(recordId) else { return }
        fire(record, using: nil)
    }

    /// FR-017: resurface `taskId` at `date` (e.g. an `.afterDate` condition's target, per
    /// `VolarCore.nextResurfaceDate`). Scheduled ahead like a normal reminder — not fired
    /// immediately.
    ///
    /// FIX A: `AppState` calls this after EVERY mutation on a task with an `.afterDate`
    /// condition, so a naive unconditional insert would pile up a new `.scheduled` "resurface"
    /// row (and a duplicate system banner) on every single edit. Dedupe against any existing
    /// not-yet-delivered resurface record for this task first: same `fireAt` -> no-op; different
    /// `fireAt` -> update that one row in place instead of inserting a second.
    func scheduleResurface(at date: Date, taskId: UUID) {
        if let existing = recordsForTask(taskId).first(where: { $0.offsetKind == "resurface" && $0.state == "scheduled" }) {
            guard existing.fireAt != date else { return }
            // The old `fireAt` may already be registered as a pending `UNNotificationRequest`
            // under this record's identifier — drop it so `refillSystemRequests()` (below) treats
            // the record as unregistered and re-posts it with the new trigger time, instead of
            // leaving the stale-time request in place forever.
            center.removePendingNotificationRequests(withIdentifiers: [existing.id.uuidString])
            existing.fireAt = date
            save()
            refillSystemRequests()
            return
        }
        let record = ReminderRecord(taskId: taskId, fireAt: date, offsetKind: "resurface")
        context.insert(record)
        save()
        refillSystemRequests()
    }

    /// FR-015: one notification per newly-eligible task, fired immediately — there's nothing to
    /// schedule ahead of time, the unblock just happened. Caller passes the `eligibilityDiff`
    /// result once per mutation so this never double-notifies the same unblock event.
    func notifyUnblocked(taskIds: [UUID]) {
        for taskId in taskIds {
            let record = ReminderRecord(taskId: taskId, fireAt: Date(), offsetKind: "unblocked")
            context.insert(record)
            save()
            handleFire(recordId: record.id)
        }
    }

    /// FR-016: an overdue nudge offering tonight/tomorrow/weekend reschedule actions
    /// (`ReminderCategory.overdueReschedule`, reached via the shared `"resurface"` offset kind —
    /// see `NotificationActions.category(forOffsetKind:)`). Fired immediately, same reasoning as
    /// `notifyUnblocked`.
    func offerReschedule(taskId: UUID) {
        let record = ReminderRecord(taskId: taskId, fireAt: Date(), offsetKind: "resurface")
        context.insert(record)
        save()
        handleFire(recordId: record.id)
    }

    // MARK: - Notification-center delegate (see the `UNUserNotificationCenterDelegate`
    // conformance at the bottom of this file; `NotificationActions.swift` owns the
    // category/action identifiers these two methods read/switch on)

    /// For this class's own `willPresent` conformance: the OS is already about to show a
    /// pre-registered system banner for `recordId`. This does the SAME fresh-reload +
    /// suppress-or-show + maybe-speak evaluation as `fire(_:using:)`, but only returns the
    /// decision instead of posting a new request (posting again here would duplicate the banner
    /// the system is already displaying).
    func presentationDecision(for recordId: UUID) -> Bool {
        guard let record = fetchRecord(recordId) else { return false }
        // FIX C (`VoiceDeliveryMode.voiceOnly`): this method's return value controls whether the
        // OS shows the visual banner (`willPresent`'s completion handler passes `[.banner, .sound]`
        // vs `[]`), so `.voiceOnly` is honored here by folding `mode != .voiceOnly` into both
        // return paths below — the record is still marked delivered and voice still speaks per the
        // existing gates in `evaluate(_:)` either way, only the visual presentation is suppressed.
        // LIMITATION: `willPresent` only fires when the app process is alive to receive the
        // delegate callback — a notification delivered while the app is fully unlaunched is shown
        // by the OS with its own default presentation and never reaches this method, so
        // `.voiceOnly` cannot suppress that banner.
        let mode = Self.currentVoiceDeliveryMode()
        // `fire(_:using:)` sets `record.state = "delivered"` BEFORE it posts the immediate
        // `UNNotificationRequest` it fires for (notifyUnblocked/offerReschedule/due-but-missed
        // recovery), so by the time the OS calls `willPresent` for that request, this record is
        // already "delivered", not "scheduled" — `fire()` already ran `evaluate(_:)` (and the
        // voice/gate decision) for it moments earlier. The old `state == "scheduled"` guard below
        // therefore returned `false` here for EVERY immediate notification, silently suppressing
        // all of them whenever the app was frontmost. Trust the decision `fire()` already made and
        // show it, instead of re-evaluating gates a second time.
        if record.state == "delivered" { return mode != .voiceOnly }
        guard record.state == "scheduled" else { return false }
        guard let evaluation = evaluate(record, snapshot: nil) else {
            context.delete(record)
            save()
            return false
        }
        record.state = evaluation.shouldShow ? "delivered" : "satisfied"
        if evaluation.shouldShow, evaluation.shouldSpeak {
            voice.speakReminder(
                title: evaluation.task.title,
                timing: Self.timingPhrase(offsetKind: record.offsetKind),
                isSensitive: evaluation.isSensitive
            )
        }
        save()
        refillSystemRequests()
        return evaluation.shouldShow && mode != .voiceOnly
    }

    /// For this class's own `didReceive` conformance: routes a tapped action to a `TaskStore`
    /// mutation or a reschedule, WITHOUT ever opening the app window (FR-014/015/016 — enforced by
    /// `NotificationActions` never declaring `.foreground` on any action, not by anything here).
    func handleAction(_ actionId: String, recordId: UUID) {
        guard let record = fetchRecord(recordId) else { return }
        let now = Date()
        switch actionId {
        case ReminderAction.done:
            let taskId = record.taskId
            store.toggle(taskId, now: now)
            record.state = "satisfied"
            // WG-C (FR-020 gap fix): this path deliberately bypasses `AppState.toggleDone` (its own
            // doc comment explains why — FR-014/015/016 forbid a notification action from touching
            // the app/window directly), which otherwise refreshes `AppState.tasks` atomically after
            // every store mutation. Post the fact instead: `VolarApp.swift` observes
            // `.volarTasksDidChange` and calls `AppState.refreshFromStore()` on the main actor, so
            // `MenuBarLabel.activeTask` catches up without needing the window foregrounded first.
            NotificationCenter.default.post(name: .volarTasksDidChange, object: nil)
            // Mirrors `AppState.toggleDone` (`Sources/App/AppState.swift:542-548`, App-wiring-owned
            // — read for reference only, not edited here): `store.toggle` can leave the task
            // done/archived, OR reopen it in place (a recurring task resets to `.todo` with a fresh
            // deadline). Either way this record alone isn't the whole story — cancel the REST of
            // this task's reminders, and if it's still open, re-derive them from the new deadline.
            // Without this, a recurring task's future reminders are silently lost forever:
            // `ensureDerived` only derives for a task with zero records, so once this task has any
            // records at all it's skipped on every later `rebuildFromStorage`.
            if let fresh = store.fetchAll().first(where: { $0.id == taskId }) {
                cancelReminders(taskId: taskId)
                if fresh.status != .done, fresh.status != .archived {
                    scheduleReminders(taskId: taskId)
                }
            }
        case ReminderAction.snooze10:
            reschedule(record, to: now.addingTimeInterval(10 * 60))
        case ReminderAction.tomorrow, ReminderAction.rescheduleTomorrow:
            reschedule(record, to: Self.tomorrowMorning(from: now))
        case ReminderAction.rescheduleTonight:
            reschedule(record, to: Self.tonight(from: now))
        case ReminderAction.rescheduleWeekend:
            reschedule(record, to: Self.nextWeekend(from: now))
        default:
            // Default tap / dismiss identifiers: no state change, no window — a glance-and-dismiss
            // reminder that isn't acted on just stays as-is (constitution V).
            break
        }
        save()
        refillSystemRequests()
    }

    // MARK: - Shared fire core

    private struct FireEvaluation {
        var task: TaskItem
        var isSensitive: Bool
        var shouldShow: Bool
        var shouldSpeak: Bool
    }

    /// The "reload fresh -> suppress-if-done -> decide voice" core shared by `handleFire`/
    /// `rebuildFromStorage`'s due-but-missed loop and `presentationDecision`. `snapshot`, when
    /// provided, avoids a redundant `store.fetchAll()` for a caller that already fetched one (used
    /// by `rebuildFromStorage` to stay O(n) instead of O(n·m) for m due records); `nil` fetches
    /// fresh, which is exactly the "fire-time fresh reload" constitution IV requires for a
    /// single-record call. `isSensitive` is read separately via `store.isSensitive(_:)`
    /// (`VolarTask.isSensitive` is deliberately not carried on `TaskItem` — see that field's doc
    /// comment in `VolarTask.swift`).
    private func evaluate(_ record: ReminderRecord, snapshot: [UUID: TaskItem]?) -> FireEvaluation? {
        let task: TaskItem?
        if let snapshot {
            task = snapshot[record.taskId]
        } else {
            task = store.fetchAll().first { $0.id == record.taskId }
        }
        guard let task else { return nil } // deleted outright — nothing to show or suppress
        let isSensitive = store.isSensitive(task.id)
        guard task.status != .done, task.status != .archived else {
            return FireEvaluation(task: task, isSensitive: isSensitive, shouldShow: false, shouldSpeak: false)
        }

        let priorUnacknowledged = recordsForTask(record.taskId).contains {
            $0.id != record.id && $0.state == "delivered" && $0.fireAt < record.fireAt
        }
        let mode = Self.currentVoiceDeliveryMode()
        let shouldSpeak = (record.isHighUrgency || priorUnacknowledged)
            && mode != .visualOnly
            && !gate.shouldSuppressVoice(now: Date())
        return FireEvaluation(task: task, isSensitive: isSensitive, shouldShow: true, shouldSpeak: shouldSpeak)
    }

    /// Fires exactly one record: suppress-to-satisfied if the fresh task is done/archived/gone,
    /// otherwise post an immediate system notification (+ speak if escalation says to) and mark
    /// delivered. Guards `record.state == "scheduled"` so this is idempotent — calling it twice on
    /// an already-fired record (e.g. two overlapping `rebuildFromStorage` calls) is a no-op the
    /// second time, which is what makes "due-but-missed fires once" true.
    private func fire(_ record: ReminderRecord, using snapshot: [UUID: TaskItem]?) {
        guard record.state == "scheduled" else { return }
        guard let evaluation = evaluate(record, snapshot: snapshot) else {
            context.delete(record)
            save()
            return
        }
        guard evaluation.shouldShow else {
            record.state = "satisfied"
            save()
            return
        }
        record.state = "delivered"
        if evaluation.shouldSpeak {
            voice.speakReminder(
                title: evaluation.task.title,
                timing: Self.timingPhrase(offsetKind: record.offsetKind),
                isSensitive: evaluation.isSensitive
            )
        }
        save()
        // Extract plain Sendable values (`UUID`/`String`/the `TaskItem` struct) BEFORE spawning
        // the Task: `Task {}`'s closure must be `@Sendable`, and capturing `record` itself (a
        // non-`Sendable` SwiftData `@Model` class) directly would violate that — this mirrors the
        // Sendable-primitive-extraction pattern already used in `Sources/Speech/SpeechCapture.swift`.
        let recordId = record.id
        let offsetKind = record.offsetKind
        let task = evaluation.task
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            await self.postImmediateRequest(recordId: recordId, offsetKind: offsetKind, task: task)
        }
    }

    private func reschedule(_ record: ReminderRecord, to date: Date) {
        record.fireAt = date
        record.offsetKind = "resurface"
        record.isHighUrgency = false
        record.state = "scheduled"
    }

    // MARK: - Settings seam
    //
    // Both keys below are read directly from `AppState`'s own `static let ...Key` constants
    // (`Sources/App/AppState.swift`, App-wiring-owned — not edited by this task) rather than
    // duplicated string literals, so the two sides can never drift apart. `AppState` is the
    // documented owner of both settings (contract §B: "`VoiceDeliveryMode` ... lives in a
    // settings source read by the scheduler"; T033 adds the matching global `ReminderPolicy`
    // setting) — this file only ever READS them, never writes.

    private static func currentVoiceDeliveryMode() -> VoiceDeliveryMode {
        let raw = UserDefaults.standard.string(forKey: AppState.voiceDeliveryModeKey)
        return raw.flatMap(VoiceDeliveryMode.init(rawValue:)) ?? .visualPlusVoice
    }

    private static func currentGlobalReminderPolicy() -> ReminderPolicy {
        guard
            let data = UserDefaults.standard.data(forKey: AppState.globalReminderPolicyKey),
            let policy = try? JSONDecoder().decode(ReminderPolicy.self, from: data)
        else { return .defaultPolicy }
        return policy
    }

    // MARK: - Date helpers (explicit `Calendar` math — constitution: never bare Date arithmetic)

    private static func tomorrowMorning(from now: Date, calendar: Calendar = .current) -> Date {
        let base = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: base) ?? base
    }

    private static func tonight(from now: Date, calendar: Calendar = .current) -> Date {
        let candidate = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now) ?? now
        return candidate > now ? candidate : (calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate)
    }

    private static func nextWeekend(from now: Date, calendar: Calendar = .current) -> Date {
        var components = DateComponents()
        components.weekday = 7 // Gregorian: 1 = Sunday ... 7 = Saturday
        components.hour = 10
        components.minute = 0
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime) ?? now
    }

    // MARK: - System request plumbing

    /// Pulls the current pending-request count, then tops it back up to `systemRequestCap` with
    /// the earliest-firing `.scheduled` records not already registered. Called after every
    /// mutation that could change what "nearest" means (schedule/cancel/deliver/action).
    private func refillSystemRequests() {
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            let pending = await self.center.volarPendingIdentifiers()
            let pendingIds = pending.compactMap { UUID(uuidString: $0) }
            let capacity = Self.systemRequestCap - pending.count
            guard capacity > 0 else { return }
            let candidates = Self.nearestCandidates(self.fetchAllRecords(), excluding: pendingIds, capacity: capacity)
            let tasksById = Dictionary(uniqueKeysWithValues: self.store.fetchAll().map { ($0.id, $0) })
            for record in candidates {
                guard let task = tasksById[record.taskId] else { continue }
                await self.postScheduledRequest(record: record, task: task)
            }
        }
    }

    /// Pure selection: earliest-firing `.scheduled` records not already registered with the
    /// system, capped at `capacity`. No I/O — directly unit-testable
    /// (`ReminderSchedulerTests.testNearestNRefillUnderCap`) without touching
    /// `UNUserNotificationCenter` at all.
    ///
    /// WG-nudge (ship-blocker, flagged by anh Khôi): every open task now gets SOME reminder, even
    /// one with no deadline (`offsetKind == "nudge"`, `ReminderRecord.derive`'s no-deadline
    /// branch). A plain "earliest fire time wins" sort would let a pile of near-term nudges (e.g.
    /// dozens of stale tasks all due to nudge within the next hour) crowd a REAL deadline
    /// reminder — one that actually matters and is due tomorrow — out of the `capacity` slots
    /// entirely, since it fires later than all of them. Deadline-anchored reminders (every
    /// `offsetKind` except `"nudge"`: `-1d`/`-1h`/`at`/`override`/`resurface`/`unblocked`) are
    /// therefore given priority as a GROUP — all of them are placed ahead of every `"nudge"`
    /// record regardless of which fires sooner — with nudges only filling whatever capacity is
    /// left over. Within each group, earliest-first ordering is unchanged.
    static func nearestCandidates(_ records: [ReminderRecord], excluding registeredIds: [UUID], capacity: Int) -> [ReminderRecord] {
        guard capacity > 0 else { return [] }
        let excluded = Set(registeredIds)
        let eligible = records.filter { $0.state == "scheduled" && !excluded.contains($0.id) }
        let prioritized = eligible.filter { $0.offsetKind != "nudge" }.sorted { $0.fireAt < $1.fireAt }
        let nudges = eligible.filter { $0.offsetKind == "nudge" }.sorted { $0.fireAt < $1.fireAt }
        return Array((prioritized + nudges).prefix(capacity))
    }

    // MARK: - Full-screen escalation sweep (contract §A/§B)
    //
    // This is the ONE new hook point this feature adds to the scheduler: a periodic timer (started
    // from `init`) that notices when a delivered, high-urgency, non-nudge reminder has sat
    // undismissed in Notification Center past `FullScreenEscalationDecision.ignoredAfter`, and — if
    // every other contract §B condition also holds — takes the screen over
    // (`FullScreenTakeoverWindow`). Nothing about the EXISTING delivery path above (`fire`,
    // `presentationDecision`, `refillSystemRequests`, `nearestCandidates`) is touched or reordered;
    // this only ever READS `fetchAllRecords()`/`store.fetchAll()` and, on escalation, calls the
    // already-existing `handleAction(_:recordId:)` — the exact same entry point a real system
    // notification's Done/Snooze buttons use — so there is no second, parallel "mark done"/"snooze"
    // implementation anywhere in this file.

    // Everything from here to `presentFullScreenTakeover`'s closing brace is the macOS takeover
    // presentation path — see the seam note on `takeoverWindow` above.
    #if os(macOS)
    private func startFullScreenEscalationSweep() {
        // Mirrors `AppState.startDelegationTimer()`'s exact construction
        // (`Timer(timeInterval:repeats:block:)` + `RunLoop.main.add(_:forMode:.common)`, read for
        // convention only — that file isn't edited by this task): the `@Sendable` block hops back
        // onto `@MainActor` via `_Concurrency.Task` for the same Swift 6 isolation reason documented
        // there (a MainActor-inferred method called directly from a non-isolated `Timer` callback
        // traps at runtime under strict concurrency checking).
        let timer = Timer(timeInterval: Self.fullScreenSweepInterval, repeats: true) { @Sendable [weak self] firingTimer in
            // Self-teardown, replacing the `deinit` that used to hold (and invalidate) this timer —
            // see the comment where that property used to be declared for why `deinit` cannot do it
            // under Swift 6. `RunLoop.main` owns the timer, so without this an outlived scheduler
            // would leave a no-op tick firing every 60s for the rest of the process's life.
            // `invalidate()` runs on the same thread that scheduled the timer (the main run loop),
            // which is exactly what Foundation requires of it.
            //
            // In practice this is belt-and-braces: `AppState` builds exactly one scheduler and
            // holds it for the whole app lifetime, so `self` outliving the process is the norm and
            // this branch is expected never to run outside tests.
            guard self != nil else {
                firingTimer.invalidate()
                return
            }
            _Concurrency.Task { @MainActor [weak self] in
                self?.sweepForFullScreenEscalation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// One tick: gather every `.delivered`, `isHighUrgency`, non-`"nudge"` record that hasn't
    /// already been offered a takeover (`escalatedRecordIds`) and MIGHT be at least `ignoredAfter`
    /// past its ACTUAL delivery moment, then resolve the impure signals that need a system call
    /// (`getDeliveredNotifications()`, which also carries each notification's real `date`) before
    /// handing everything to the pure `FullScreenEscalationDecision.shouldEscalate`. Deliberately
    /// serialized behind `takeoverWindow.isPresenting`: only ever escalates ONE record per tick, so
    /// a backlog of several eligible records can't stack multiple full-screen windows — the rest
    /// simply wait for a later tick (by which point the first will likely have been acted on or
    /// auto-closed).
    ///
    /// FIX (Opus review): `deliveredAt` must be the notification's REAL delivery moment
    /// (`UNNotification.date`), never `ReminderRecord.fireAt`. Those two differ exactly in the
    /// most dangerous case: a due-but-missed recovery fire (`rebuildFromStorage`'s due-but-missed
    /// pass / `fire(_:using:)`) posts the notification "now" for a `fireAt` that can be hours in
    /// the past (e.g. the Mac slept overnight past the deadline). Using `fireAt` there would make
    /// `now - fireAt` blow past `ignoredAfter` the INSTANT the notification is first shown —
    /// full-screen-taking-over the user's just-woken machine before they've had one chance to see
    /// the banner. `fireAt` is only ever used below as a cheap, deliberately OVER-inclusive
    /// pre-filter (see `candidates` in `sweepForFullScreenEscalation` below) — it can never cause a
    /// false NEGATIVE (excluding a record that should truly qualify), because delivery can never
    /// happen before `fireAt`, so
    /// `now - fireAt` is always >= the true `now - realDeliveredAt`. The real per-notification
    /// `date` below is what actually decides the answer.
    private struct CandidateSnapshot: Sendable {
        let id: UUID
        let taskId: UUID
        let isHighUrgency: Bool
        let offsetKind: String
    }

    private func sweepForFullScreenEscalation() {
        guard FullScreenEscalationSetting.isEnabled else { return }
        guard !takeoverWindow.isPresenting else { return }

        let now = Date()
        // Cheap, over-inclusive pre-filter only (see this method's doc comment for why `fireAt`
        // can never wrongly EXCLUDE a record here) — just avoids waking up the async
        // `getDeliveredNotifications()` path at all when nothing could possibly qualify yet.
        let candidates: [CandidateSnapshot] = fetchAllRecords()
            .filter {
                $0.state == "delivered"
                    && $0.isHighUrgency
                    && $0.offsetKind != "nudge"
                    && !escalatedRecordIds.contains($0.id)
                    && now.timeIntervalSince($0.fireAt) >= FullScreenEscalationDecision.ignoredAfter
            }
            .map { CandidateSnapshot(id: $0.id, taskId: $0.taskId, isHighUrgency: $0.isHighUrgency, offsetKind: $0.offsetKind) }
        guard !candidates.isEmpty else { return }

        // `TaskItem` (unlike `ReminderRecord`) IS `Sendable` (a plain struct — see
        // `Sources/Model/TaskItem.swift`), so this dictionary is safe to carry across the `Task`
        // boundary below as-is.
        let tasksById = Dictionary(uniqueKeysWithValues: store.fetchAll().map { ($0.id, $0) })
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            let delivered = await self.center.volarDeliveredSummaries()
            // The REAL delivery moment per identifier (`UNNotification.date`) — not `fireAt`. A
            // record whose identifier isn't a key here is simply no longer in Notification Center
            // (already interacted with) OR its date couldn't be resolved; either way it's excluded
            // below rather than ever falling back to `fireAt`.
            var deliveredAtById: [UUID: Date] = [:]
            for notification in delivered {
                if let id = UUID(uuidString: notification.identifier) {
                    deliveredAtById[id] = notification.date
                }
            }

            for candidate in candidates.sorted(by: { (deliveredAtById[$0.id] ?? .distantFuture) < (deliveredAtById[$1.id] ?? .distantFuture) }) {
                // Freshest possible task read for THIS record specifically (contract §B: "đọc lại
                // bản tươi từ store, đừng tin snapshot cũ") — `tasksById` above was built once per
                // tick, immediately before this loop, not carried over from an earlier tick.
                guard let task = tasksById[candidate.taskId] else { continue }
                // Fail-safe (Opus review, explicit): no resolvable REAL delivery date -> skip this
                // record THIS tick rather than ever guessing via `fireAt`. This also naturally
                // covers "no longer in Notification Center" (`stillInNotificationCenter == false`),
                // since that identifier simply won't be a key in `deliveredAtById` either.
                guard let realDeliveredAt = deliveredAtById[candidate.id] else { continue }
                let signals = EscalationSignals(
                    isHighUrgency: candidate.isHighUrgency,
                    offsetKind: candidate.offsetKind,
                    isTaskOpen: task.status != .done && task.status != .archived,
                    stillInNotificationCenter: true, // guaranteed by the guard just above
                    deliveredAt: realDeliveredAt,
                    isMicrophoneInUse: MicrophoneActivityMonitor.isMicrophoneInUseSystemWide(),
                    isVolarCapturing: self.isVolarCapturing(),
                    settingEnabled: FullScreenEscalationSetting.isEnabled
                )
                guard FullScreenEscalationDecision.shouldEscalate(signals: signals, now: Date()) else { continue }

                self.escalatedRecordIds.insert(candidate.id)
                self.presentFullScreenTakeover(task: task, recordId: candidate.id)
                break // one takeover at a time — see this method's doc comment.
            }
        }
    }

    /// Presents the takeover, wiring its two buttons/Esc straight back to the SAME
    /// `handleAction(_:recordId:)` a real notification's "Done"/"Snooze 10 min" actions already go
    /// through — no second mark-done/snooze implementation.
    private func presentFullScreenTakeover(task: TaskItem, recordId: UUID) {
        takeoverWindow.present(
            title: task.title,
            deadline: task.deadline,
            onDone: { [weak self] in
                self?.handleAction(ReminderAction.done, recordId: recordId)
            },
            onSnooze: { [weak self] in
                self?.handleAction(ReminderAction.snooze10, recordId: recordId)
            }
        )
    }
    #endif

    private func postScheduledRequest(record: ReminderRecord, task: TaskItem) async {
        let content = Self.buildContent(task: task, offsetKind: record.offsetKind)
        // `UNTimeIntervalNotificationTrigger` requires a strictly positive interval even for a
        // record whose `fireAt` has already technically passed at registration time (e.g. one
        // just created by `notifyUnblocked` racing this refill) — 1s is effectively "now".
        let interval = max(record.fireAt.timeIntervalSinceNow, 1)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: trigger)
        try? await center.add(request)
    }

    private func postImmediateRequest(recordId: UUID, offsetKind: String, task: TaskItem) async {
        let content = Self.buildContent(task: task, offsetKind: offsetKind)
        let request = UNNotificationRequest(identifier: recordId.uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }

    private static func buildContent(task: TaskItem, offsetKind: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Volar"
        content.body = "\(task.title) \u{2014} \(timingPhrase(offsetKind: offsetKind))"
        content.sound = .default
        content.categoryIdentifier = NotificationActions.category(forOffsetKind: offsetKind)
        #if os(iOS)
        // 011 contract §7: due-now / due-in-an-hour break through Focus. UNVERIFIED: needs the time-sensitive entitlement.
        if UserDefaults.standard.object(forKey: "volar.reminders.timeSensitive") as? Bool ?? true,
           offsetKind == "at" || offsetKind == "-1h" {
            content.interruptionLevel = .timeSensitive
        }
        #endif
        return content
    }

    /// Calm, non-alarming phrasing (constitution V) — no "OVERDUE"/"MISSED" shouting.
    private static func timingPhrase(offsetKind: String) -> String {
        switch offsetKind {
        case "-1d": return "due tomorrow"
        case "-1h": return "due in about an hour"
        case "at": return "due now"
        case "unblocked": return "ready to start"
        case "resurface": return "worth a look"
        default: return "coming up"
        }
    }

    // MARK: - Persistence internals

    private static func makeContext() -> ModelContext {
        let schema = Schema([ReminderRecord.self])
        let configuration = ModelConfiguration("VolarReminders", schema: schema)
        if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
            return ModelContext(container)
        }
        // Degrade gracefully (mirrors `TaskStore.init()`'s documented fallback philosophy): an
        // in-memory container keeps the scheduler functional for the running session even if the
        // persistent store can't be opened, rather than crashing the app at launch.
        let fallback = ModelConfiguration("VolarReminders-fallback", schema: schema, isStoredInMemoryOnly: true)
        // Force-try is safe here: an in-memory `ModelContainer` for a schema that's already known
        // to be well-formed (it just failed for an on-disk reason above) has no plausible failure
        // mode short of an out-of-memory condition, which would already be fatal elsewhere.
        let container = try! ModelContainer(for: schema, configurations: [fallback])
        return ModelContext(container)
    }

    // Deliberately `internal` (not `private`), unlike the rest of this section: `@testable import
    // Volar` gives `ReminderSchedulerTests` access to `internal` symbols only, and these three are
    // the minimal read-only surface the tests need to assert on persisted `ReminderRecord` state
    // after driving the frozen public API (`rebuildFromStorage`/`scheduleReminders`/`handleFire`/
    // `cancelReminders`) — nothing here is exported outside the module.

    func fetchRecord(_ id: UUID) -> ReminderRecord? {
        var descriptor = FetchDescriptor<ReminderRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func recordsForTask(_ taskId: UUID) -> [ReminderRecord] {
        let descriptor = FetchDescriptor<ReminderRecord>(predicate: #Predicate { $0.taskId == taskId })
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchAllRecords() -> [ReminderRecord] {
        (try? context.fetch(FetchDescriptor<ReminderRecord>())) ?? []
    }

    private func clearScheduled(taskId: UUID) {
        let scheduled = recordsForTask(taskId).filter { $0.state == "scheduled" }
        guard !scheduled.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: scheduled.map(\.id.uuidString))
        for record in scheduled { context.delete(record) }
    }

    /// Derives when NO record exists yet for `taskId` (any state) — makes repeated
    /// `rebuildFromStorage()` calls idempotent instead of re-deriving (and re-firing) the same
    /// offsets on every wake. For a no-deadline task ONLY, ALSO re-derives once its current batch
    /// has fully fired — see the asymmetry note below.
    ///
    /// FIX (anh Khôi's "lặp mãi" nudge repeat, ship-blocker — was a KNOWN GAP left unfixed by the
    /// task that introduced the no-deadline "nudge" backoff): `ReminderRecord.derive`'s no-deadline
    /// branch caps out at `maxBeforeDeadlineMarks` (8) marks per call BY DESIGN — "repeat forever"
    /// literally cannot be a finite list, so the architecture leans on being CALLED AGAIN later to
    /// top up (see that function's own doc comment). The plain "any record at all" guard used to
    /// defeat that: once all 8 nudges in a batch had fired (state `"delivered"`/`"satisfied"`),
    /// `recordsForTask(taskId)` was never empty again, so this method stopped deriving anything
    /// further for that task FOREVER — the opposite of "lặp mãi mỗi 3 ngày". Fixed by also
    /// re-deriving whenever the no-deadline task has no `"scheduled"` record left with `fireAt` in
    /// the future (i.e. the whole current batch is spent and needs topping up).
    ///
    /// ⚠️ ASYMMETRIC ON PURPOSE — do NOT "simplify" this to the same condition for a task WITH a
    /// deadline. A deadline task's fixed `policy.offsets` marks (e.g. offset `0` = "at deadline")
    /// sit in the PAST once the task is overdue, and `ReminderRecord.derive`'s overdue branch
    /// returns those past offsets VERBATIM with no future-only filtering (unlike `noDeadlineMarks`,
    /// which only ever keeps marks `> now`). Loosening this guard the same way for a deadline task
    /// would re-derive and re-insert those already-fired past-due marks as brand-new `.scheduled`
    /// rows on every later `rebuildFromStorage`/wake, re-firing a notification the user already
    /// received. A no-deadline task has no such risk (`noDeadlineMarks` never emits a mark that
    /// isn't strictly after `now`), so only it gets the loosened re-derive condition below.
    private func ensureDerived(
        taskId: UUID, deadline: Date?, createdAt: Date, priority: Int?, reminderOverride: ReminderPolicy?, now: Date
    ) {
        let existing = recordsForTask(taskId)
        if deadline == nil {
            let hasFutureScheduled = existing.contains { $0.state == "scheduled" && $0.fireAt > now }
            guard existing.isEmpty || !hasFutureScheduled else { return }
        } else {
            guard existing.isEmpty else { return }
        }
        let records = ReminderRecord.derive(
            taskId: taskId, deadline: deadline, createdAt: createdAt, priority: priority,
            reminderOverride: reminderOverride, globalPolicy: Self.currentGlobalReminderPolicy(), now: now
        )
        for record in records { context.insert(record) }
        save()
    }

    private func save() {
        do {
            try context.save()
        } catch {
            print("[Volar.ReminderScheduler] save failed: \(error)")
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

/// Concurrency note (mirrors `Sources/Speech/SpeechCapture.swift`'s documented pattern for the
/// same underlying issue): `UNUserNotificationCenterDelegate`'s methods are invoked by the system
/// on an arbitrary background queue, not necessarily the main actor. A non-`nonisolated` method on
/// this `@MainActor` class would be inferred main-actor-isolated, and Swift 6's runtime isolation
/// check traps (`dispatch_assert_queue(main)`) when the system calls it off-main. Both methods
/// below are therefore `nonisolated` and hop to `@MainActor` themselves before touching any
/// scheduler state.
extension ReminderScheduler: UNUserNotificationCenterDelegate {
    /// The OS is about to show a pre-registered system banner live — routes to
    /// `presentationDecision(for:)` for the fresh-reload suppress/show call, per contract §A.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let identifier = notification.request.identifier
        // `completionHandler` is not `@Sendable` (the UserNotifications SDK doesn't annotate it), so
        // capturing it into the `@MainActor` Task below crosses an isolation boundary and Swift 6
        // flags "sending 'completionHandler' risks causing data races". The OS invokes this delegate
        // method once and we call the handler exactly once, on the main actor — box it in a
        // `nonisolated(unsafe) let` to assert that safety, matching this file's/`SpeechCapture.swift`'s
        // established convention for sending a non-Sendable system value across an isolation hop.
        nonisolated(unsafe) let handler = completionHandler
        _Concurrency.Task { @MainActor [weak self] in
            guard let self, let recordId = UUID(uuidString: identifier) else {
                // Not one of ours (foreign identifier) or the scheduler is gone — show it as the
                // system would by default rather than silently eating a notification.
                handler([.banner, .sound])
                return
            }
            handler(self.presentationDecision(for: recordId) ? [.banner, .sound] : [])
        }
    }

    /// Routes a tapped action (or the default tap/dismiss) to `handleAction(_:recordId:)` —
    /// TaskStore mutations only, NEVER opens the app window (FR-014/015/016; enforced by
    /// `NotificationActions` never declaring `.foreground` on any action, not by anything here).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let actionId = response.actionIdentifier
        // Same non-Sendable-completion-handler-across-isolation fix as `willPresent` above — box it
        // in a `nonisolated(unsafe) let` so sending it into the `@MainActor` Task doesn't trip
        // Swift 6's data-race diagnostic; called exactly once via `defer` on the main actor.
        nonisolated(unsafe) let handler = completionHandler
        _Concurrency.Task { @MainActor [weak self] in
            defer { handler() }
            guard let self, let recordId = UUID(uuidString: identifier) else { return }
            self.handleAction(actionId, recordId: recordId)
        }
    }
}
