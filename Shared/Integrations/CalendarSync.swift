// Sources/Integrations/CalendarSync.swift — one-way (Volar → Calendar) task mirroring into a
// dedicated, app-created "Volar" calendar. Shares `CalendarAccess`'s single `EKEventStore`
// instance (see that file's header) rather than constructing its own.
//
// THE CORE SAFETY PROPERTY THIS FILE EXISTS TO GUARANTEE: Volar must never MUTATE (write, modify,
// or delete) anything in a calendar it did not itself create — and, specifically in THIS file,
// never read individual event content from any calendar either (that stays scoped to
// `CalendarAccess.swift`'s bare calendar *count*, which is metadata about calendars as a whole, not
// their contents; see that file for why even that narrow read is fine to keep).
// `requestFullAccessToEvents()` (`CalendarAccess.swift`) grants EventKit permission across EVERY
// calendar on the Mac — there is no OS-level way to scope that grant down to just one calendar. So
// the scoping has to happen in THIS code, structurally, not by trusting the OS: every write path
// below goes through TWO independent ownership guards before it will touch an existing `EKEvent`:
//   1. `event.calendar?.calendarIdentifier == volarCalendarID` — the event must live in the exact
//      calendar `ensureVolarCalendar()` created (identified by its stable EventKit identifier, not
//      by title — titles are user-editable and could collide with a calendar the user made
//      themselves called "Volar").
//   2. `event.url == markerURL(for: taskID)` — the event must carry the `volar://task/<uuid>`
//      marker this file itself stamped onto it when creating it.
// Either guard failing means "this is not an event Volar created" and the code drops it from
// `eventMap` and creates a fresh replacement instead of ever calling `save`/`remove` on it. This is
// what makes it structurally impossible (not just policy) for a stale/tampered/id-reused
// `eventMap` entry to cause Volar to mutate a foreign event — see `reconcile(tasks:)` for both
// guards in the create/update path and `removeAllMirroredEvents()` for the same guards in the
// delete path.
//
// SYNC DIRECTION: strictly one-way, Volar's own tasks → the "Volar" calendar. Volar never reads
// event titles/times/attendees/notes from any calendar to create or modify a task — that would be
// a materially different (and separately scoped) feature. `reconcile(tasks:)` is a pure "make the
// Volar calendar's contents match this task list" operation; it never feeds anything back into
// `TaskItem`/`TaskStore`.
//
// WHY `eventMap` LIVES IN USERDEFAULTS, NOT ON `VolarTask` (SwiftData): `VolarTask.swift`'s own
// header explains this project has never declared a `VersionedSchema`/`SchemaMigrationPlan` and
// treats that as fragile enough to avoid except when unavoidable. Adding an `eventIdentifier`
// field to that model for what is entirely REBUILDABLE derived data (if this map were lost
// entirely, the worst case is `reconcile` orphaning old events until `removeAllMirroredEvents`
// cleans them up, and creating fresh ones with fresh identifiers) would be introducing exactly the
// kind of schema churn that file's migration strategy exists to avoid, for data that was never
// worth the risk. Keeping it in UserDefaults — the same idiom `AppState.swift` already uses for
// every other piece of small persisted app state (`ambientKey`/`accentKey`/etc.) — costs nothing
// and keeps the SwiftData schema untouched.
//
// WHY NO `EKAlarm`: Volar has its own reminder subsystem (`Sources/Reminders/ReminderScheduler.swift`
// et al., contracts/phase4-contract.md) that already schedules local notifications/voice reminders
// for every dated task. Adding a system Calendar alert on top of that would double-notify the user
// for the same deadline through two independent paths — a real user-facing bug, not a nice-to-have
// extra. `reconcile(tasks:)` never sets `event.addAlarm(...)` for this reason.
//
// WHY `@MainActor`: same reason as `CalendarAccess` — `EKEventStore`/`EKEvent`/`EKCalendar` are not
// `Sendable`, and this target builds with `SWIFT_STRICT_CONCURRENCY: complete` under Swift 6.
import EventKit
import Observation
import Foundation

@MainActor
@Observable
final class CalendarSync {
    /// Local, non-EventKit error for the one failure mode `ensureVolarCalendar()` refuses to work
    /// around: no calendar source it's willing to write into exists.
    enum CalendarSyncError: LocalizedError {
        case noUsableSource

        var errorDescription: String? {
            switch self {
            case .noUsableSource:
                return "No writable calendar source is available on this device, so Volar can't create its \"Volar\" calendar. Volar will never write into a subscribed calendar or one it doesn't own."
            }
        }
    }

    private let access: CalendarAccess

    /// User opt-in toggle for one-way task → Calendar mirroring, persisted at `mirrorEnabledKey`.
    /// Defaults to `false`: writing to the user's calendar is opt-in, never automatic just because
    /// `CalendarAccess.status == .granted` — that status only means the OS PERMITS reading/writing,
    /// not that the user has asked Volar to actually mutate their calendar.
    ///
    /// `private(set)` — mutated only through `setMirrorEnabled(_:)` below, not a plain settable
    /// `var` with a `didSet`. Two reasons this shape was chosen instead: (1) turning mirroring OFF
    /// is a DESTRUCTIVE action (it deletes every event Volar previously created via
    /// `removeAllMirroredEvents()`) — that belongs behind an explicit, named method a caller can
    /// see at the call site, not hidden inside a property observer that fires as a side effect of
    /// what reads like a plain assignment; (2) this mirrors the codebase's own established
    /// convention for exactly this situation, `AppState.setAccent`/`setDensity` (see that file's
    /// comment on why it avoids `didSet`), rather than inventing a second idiom — and sidesteps the
    /// specific uncertainty a `didSet` on an `@Observable` stored property raised here previously
    /// (whether the macro's rewrite could cause `init`'s own initial assignment to misfire the
    /// observer), which could not be verified from Windows. `SettingsView`'s `VolarToggle` binds via
    /// `Binding(get:set:)` calling `AppState.setCalendarMirror(_:)` (which itself calls
    /// `setMirrorEnabled(_:)`) rather than a raw two-way `Binding` to this property directly.
    private(set) var mirrorEnabled: Bool

    /// Persists `enabled`, and — only when actually turning mirroring OFF — deletes every event
    /// Volar previously created (`removeAllMirroredEvents()`) rather than waiting for some later
    /// `reconcile(tasks:)` call that might not come soon: turning mirroring off should visibly and
    /// promptly clean up, not leave stale events sitting in the user's calendar list. No-ops when
    /// `enabled` already matches the current value (mirrors `AppState.setAccent`'s own no-op guard)
    /// so re-invoking this with an unchanged value — e.g. a `Binding` re-firing — never re-runs the
    /// delete path for nothing.
    func setMirrorEnabled(_ enabled: Bool) {
        guard enabled != mirrorEnabled else { return }
        mirrorEnabled = enabled
        UserDefaults.standard.set(mirrorEnabled, forKey: Self.mirrorEnabledKey)
        if !mirrorEnabled {
            removeAllMirroredEvents()
        }
    }

    /// EventKit identifier of the app-created "Volar" calendar, once one exists. `nil` until the
    /// first successful `ensureVolarCalendar()`.
    private(set) var volarCalendarID: String?

    /// taskID -> `EKEvent.eventIdentifier` for every event Volar currently believes it owns.
    /// Persisted as `[String: String]` (UUID's `.uuidString` as the key) at `eventMapKey` — see the
    /// file header for why this lives here instead of on the SwiftData model.
    private var eventMap: [UUID: String]

    private(set) var lastError: String?

    private static let mirrorEnabledKey = "volar.calendarMirrorEnabled"
    private static let volarCalendarIdentifierKey = "volar.calendarIdentifier"
    private static let eventMapKey = "volar.calendarEventMap"

    init(access: CalendarAccess) {
        self.access = access
        self.mirrorEnabled = UserDefaults.standard.bool(forKey: Self.mirrorEnabledKey)
        self.volarCalendarID = UserDefaults.standard.string(forKey: Self.volarCalendarIdentifierKey)
        if let raw = UserDefaults.standard.dictionary(forKey: Self.eventMapKey) as? [String: String] {
            var map: [UUID: String] = [:]
            for (key, value) in raw {
                if let id = UUID(uuidString: key) {
                    map[id] = value
                }
            }
            self.eventMap = map
        } else {
            self.eventMap = [:]
        }
        self.lastError = nil
    }

    private var store: EKEventStore { access.eventStore }

    // MARK: - Calendar lifecycle

    /// Resolves the app-created "Volar" calendar, creating it on first use. Never returns, and
    /// never writes into, any calendar Volar didn't create itself.
    func ensureVolarCalendar() throws -> EKCalendar {
        if let id = volarCalendarID,
           let existing = store.calendar(withIdentifier: id),
           existing.allowsContentModifications {
            return existing
        }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Volar"
        // No `cgColor` assignment: this file must not import the design layer (`VolarColor.*` are
        // SwiftUI `Color`, not `CGColor`, and pulling in `Design/Theme.swift` here would be a
        // layering violation for a file that has nothing to do with UI). Leaving `cgColor` unset
        // lets EventKit/Calendar.app assign its own default, which is exactly what happens for any
        // calendar created without an explicit color.

        // Source selection: prefer a genuinely local source (never synced anywhere, entirely under
        // this Mac's control) over whatever `defaultCalendarForNewEvents` happens to point at. If
        // neither resolves to something Volar is willing to write into — including, explicitly, a
        // `.subscribed` source (read-only-by-convention calendars like public holiday feeds) or the
        // `.birthdays` source (synthetic, not a real writable calendar) — this THROWS rather than
        // silently falling back to writing into whatever source IS available. Falling back is
        // exactly the failure this whole design exists to prevent: it would mean the "Volar"
        // calendar itself might land inside an account/source the user didn't intend, defeating the
        // entire point of a dedicated calendar.
        let source: EKSource?
        let localSource = store.sources.first(where: { $0.sourceType == .local })
        #if os(iOS)
        // iOS with iCloud on hides `.local` calendars from Calendar.app, so a "Volar" calendar there
        // would be invisible: prefer the user's default calendar's source, `.local` as fallback.
        source = store.defaultCalendarForNewEvents?.source ?? localSource
        #else
        source = localSource ?? store.defaultCalendarForNewEvents?.source
        #endif
        guard let resolvedSource = source,
              resolvedSource.sourceType != .subscribed,
              resolvedSource.sourceType != .birthdays
        else {
            throw CalendarSyncError.noUsableSource
        }
        calendar.source = resolvedSource

        try store.saveCalendar(calendar, commit: true)
        volarCalendarID = calendar.calendarIdentifier
        UserDefaults.standard.set(calendar.calendarIdentifier, forKey: Self.volarCalendarIdentifierKey)
        return calendar
    }

    /// Full-uninstall path: deletes every event Volar created, then deletes the "Volar" calendar
    /// itself. Not currently wired into `SettingsView` (kept small/optional per the task's own
    /// "only if it doesn't bloat the row" guidance) — exposed here so a future "remove Volar
    /// calendar entirely" affordance has something to call without touching this file again.
    func deleteVolarCalendar() {
        removeAllMirroredEvents()
        guard let id = volarCalendarID, let calendar = store.calendar(withIdentifier: id) else {
            volarCalendarID = nil
            UserDefaults.standard.removeObject(forKey: Self.volarCalendarIdentifierKey)
            return
        }
        do {
            try store.removeCalendar(calendar, commit: true)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        volarCalendarID = nil
        UserDefaults.standard.removeObject(forKey: Self.volarCalendarIdentifierKey)
    }

    // MARK: - Reconciliation (the one public entry point callers should drive)

    /// Makes the "Volar" calendar's contents match `tasks`: creates/updates an event for every
    /// open, dated task, and removes events for tasks that are done/deleted/no-longer-dated. Fully
    /// idempotent — safe to call on every task-list change, app-foreground, or timer tick. Never
    /// throws; every failure lands in `lastError`.
    func reconcile(tasks: [TaskItem]) {
        // FIX 2a: split what used to be a single combined guard. When access is NOT granted, the
        // delete calls inside `removeAllMirroredEvents()` cannot possibly succeed (EventKit has
        // nothing to grant them), so calling it here would just permanently orphan whatever events
        // Volar previously created — `eventMap` would be wiped with no real deletion having
        // happened, and Volar would lose the only record of which events are its own, forever
        // (even if access is re-granted later, there'd be nothing left in `eventMap` to clean up
        // with). Leave `eventMap` untouched and return; it survives to be cleaned up for real once
        // access is granted again and this function (or `removeAllMirroredEvents()` via a mirroring
        // toggle) runs with a store that can actually act on it.
        guard access.status == .granted else { return }
        guard mirrorEnabled else {
            if !eventMap.isEmpty {
                removeAllMirroredEvents()
            }
            return
        }

        do {
            let calendar = try ensureVolarCalendar()
            let desired = tasks.filter(Self.isDesired)
            let desiredIDs = Set(desired.map(\.id))

            // FIX 1: events this call CREATES (as opposed to updates in place) get their
            // `EKEvent.eventIdentifier` recorded into `eventMap` only after `store.commit()`
            // below succeeds — see the comment inside the loop for why. Collected here rather
            // than read inline.
            var newlyCreated: [(taskID: UUID, event: EKEvent)] = []

            for task in desired {
                guard let deadline = task.deadline else { continue }
                // Recurring tasks (`task.recurrence`): deliberately mirror only the task's CURRENT
                // `deadline` instance, exactly like every other open task. Building a real
                // `EKRecurrenceRule` from `Recurrence` would need to reconcile two independent
                // recurrence engines (Volar's own `Recurrence` model and EventKit's), which is out
                // of scope for v1 — a known, accepted limitation, not an oversight.
                let (start, end) = Self.eventWindow(deadline: deadline, durationMinutes: task.durationMinutes)
                guard let markerURL = Self.markerURL(forTaskID: task.id) else { continue }

                var target: EKEvent?
                if let existingID = eventMap[task.id] {
                    if let fetched = store.event(withIdentifier: existingID),
                       fetched.calendar?.calendarIdentifier == volarCalendarID,
                       fetched.url == markerURL {
                        // Guard 1 (calendar identity) and guard 2 (ownership-marker URL) both pass
                        // — this is genuinely an event Volar created, safe to update in place.
                        target = fetched
                    } else {
                        // Either the event vanished, moved to a different calendar, or lost its
                        // marker — never assume it's still ours. Drop the stale map entry and fall
                        // through to creating a fresh event below instead of touching whatever
                        // `existingID` now resolves to (if anything).
                        eventMap.removeValue(forKey: task.id)
                    }
                }

                // `target == nil` here means this is a brand-new event, not an update to one
                // already tracked in `eventMap` — captured BEFORE `target ?? EKEvent(...)` below
                // overwrites the distinction.
                let isNewEvent = target == nil
                let event = target ?? EKEvent(eventStore: store)
                event.title = task.title
                event.startDate = start
                event.endDate = end
                event.timeZone = .current
                event.calendar = calendar
                event.url = markerURL
                // No `event.addAlarm(...)` — see file header "WHY NO EKAlarm".
                try store.save(event, span: .thisEvent, commit: false)
                if isNewEvent {
                    // FIX 1 (duplicate-event bug): `EKEvent.eventIdentifier` is NOT reliably
                    // populated until the save is actually COMMITTED — every save in this loop
                    // uses `commit: false` (batched), so `store.commit()` hasn't run yet at this
                    // point. Reading `event.eventIdentifier` here, for a freshly created event,
                    // can silently read `nil`: the task -> event mapping would then never get
                    // recorded, and because `reconcile(tasks:)` is meant to run on every task
                    // change, the VERY NEXT call would see no `eventMap[task.id]`, conclude the
                    // task still needs an event, and create a SECOND one for the same task —
                    // compounding into visibly duplicated calendar events over time. Collect the
                    // pair now and read `eventIdentifier` only after `store.commit()` below has
                    // actually succeeded (see that point in this function). DO NOT "simplify" this
                    // back to an inline `eventMap[task.id] = event.eventIdentifier` — that
                    // reintroduces exactly this bug.
                    newlyCreated.append((taskID: task.id, event: event))
                }
                // An UPDATED event (the `else` of `isNewEvent`) already has a known, stable
                // identifier — it was fetched from `eventMap` via `existingID` above, and updating
                // an existing `EKEvent` in place never changes its `eventIdentifier`. No action
                // needed here for that case.
            }

            // Remove events for tasks no longer desired (done, deleted, or deadline cleared). Same
            // two ownership guards as above — an entry whose fetched event fails either guard is
            // just dropped from the map, never force-deleted.
            let mapSnapshot = eventMap
            for (taskID, eventID) in mapSnapshot where !desiredIDs.contains(taskID) {
                if let event = store.event(withIdentifier: eventID),
                   event.calendar?.calendarIdentifier == volarCalendarID,
                   event.url == Self.markerURL(forTaskID: taskID) {
                    try? store.remove(event, span: .thisEvent, commit: false)
                }
                eventMap.removeValue(forKey: taskID)
            }

            try store.commit()
            // FIX 1: only NOW — after the batched saves above have actually been committed — is it
            // safe to read `eventIdentifier` off each newly created event and record it. Every
            // entry in `newlyCreated` was created and saved (uncommitted) earlier in this same
            // call, so this is the first point in the whole function where `store.commit()` has
            // succeeded for them.
            for (taskID, event) in newlyCreated {
                if let identifier = event.eventIdentifier {
                    eventMap[taskID] = identifier
                }
            }
            persistEventMap()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Deletes every event Volar believes it created (same two ownership guards as `reconcile`),
    /// clears `eventMap`, and commits — used when mirroring is turned off or access is lost. Never
    /// deletes the "Volar" calendar itself, only its events; `deleteVolarCalendar()` above is the
    /// separate, explicit opt-in for removing the calendar too.
    private func removeAllMirroredEvents() {
        let mapSnapshot = eventMap
        for (taskID, eventID) in mapSnapshot {
            if let event = store.event(withIdentifier: eventID),
               event.calendar?.calendarIdentifier == volarCalendarID,
               event.url == Self.markerURL(forTaskID: taskID) {
                try? store.remove(event, span: .thisEvent, commit: false)
            } else {
                // Genuinely gone, moved to a different calendar, or lost its marker — same "not
                // ours (anymore)" reasoning as `reconcile(tasks:)`'s own stale-entry handling.
                // Nothing was queued for removal for this one, so it's safe to drop from the map
                // right away regardless of how the batched commit below turns out — unlike the
                // entries below that DO have a real `store.remove(...)` queued, this one was never
                // going to be affected by that commit's success or failure.
                eventMap.removeValue(forKey: taskID)
            }
        }
        // FIX 2b: `eventMap.removeAll()` + `persistEventMap()` used to run HERE, before
        // `store.commit()` — so a failed commit left the real events still sitting in the user's
        // calendar while Volar's own bookkeeping already claimed they were gone, with no way to
        // retry (eventMap, once cleared, is the only record of which events are Volar's). Only
        // clear/persist the remaining entries (the ones that had a genuine `store.remove(...)`
        // queued above) once the commit that actually removes them has succeeded.
        do {
            try store.commit()
            eventMap.removeAll()
            persistEventMap()
            lastError = nil
        } catch {
            // Commit failed: the removes queued above never went through. Leave whatever's left in
            // `eventMap` (the stale entries were already dropped individually above) intact so a
            // later call — the next mirroring toggle, or a future `reconcile(tasks:)` once access
            // is granted again — can retry exactly what didn't go through, instead of silently
            // losing track of it.
            lastError = error.localizedDescription
        }
    }

    private func persistEventMap() {
        var raw: [String: String] = [:]
        for (taskID, eventID) in eventMap {
            raw[taskID.uuidString] = eventID
        }
        UserDefaults.standard.set(raw, forKey: Self.eventMapKey)
    }

    // MARK: - Pure helpers (factored out static so tests can exercise them without EventKit)

    /// A task is mirrored iff it's still open (todo / in progress - not done, not archived) and has something to anchor an event to. Matches
    /// `ReminderRecord.derive`'s own "no deadline, nothing to schedule" stance elsewhere in this
    /// codebase.
    static func isDesired(_ task: TaskItem) -> Bool {
        (task.status == .todo || task.status == .inProgress) && task.deadline != nil
    }

    /// `deadline` is the event start; `durationMinutes` (when a positive value is set) is its
    /// length, defaulting to 30 minutes otherwise — mirrors `SettingsView`'s "Default task
    /// duration" framing (`AppState`'s own default-duration setting is a separate, cosmetic-only
    /// Settings control today; this is intentionally a fixed fallback, not wired to it, to avoid
    /// this file reaching into Settings state it doesn't own).
    static func eventWindow(deadline: Date, durationMinutes: Int?) -> (start: Date, end: Date) {
        let minutes: Int
        if let durationMinutes, durationMinutes > 0 {
            minutes = durationMinutes
        } else {
            minutes = 30
        }
        return (deadline, deadline.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    /// Builds the ownership-marker URL stamped onto every event Volar creates
    /// (`volar://task/<uuid>`) — this is what lets ownership be re-established even if `eventMap`
    /// is ever lost/corrupted (a rebuild would recognize its own old events by this marker, though
    /// no such rebuild path exists yet since `eventMap` loss just means orphaned events accumulate
    /// until `removeAllMirroredEvents`/`deleteVolarCalendar` clears them — a v1 limitation, not a
    /// safety gap, since orphaned events are inert, never mis-attributed to the wrong task).
    static func markerURL(forTaskID taskID: UUID) -> URL? {
        URL(string: "volar://task/\(taskID.uuidString)")
    }

    /// Inverse of `markerURL(forTaskID:)`, for tests and any future rebuild path. `nil` for any URL
    /// that isn't shaped like Volar's own marker.
    static func taskID(fromMarkerURL url: URL) -> UUID? {
        guard url.scheme == "volar", url.host == "task" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}
