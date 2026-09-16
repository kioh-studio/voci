// Sources/App/AppState.swift — central @Observable app state (frozen API, spec §4)
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
import Foundation
import Network
import Observation
import StoreKit
import UserNotifications
import VolarCore

/// WG-C (FR-020 gap fix): posted by `ReminderScheduler.handleAction` (`Sources/Reminders/
/// ReminderScheduler.swift`) right after a notification action mutates `TaskStore` state (e.g. the
/// "Done" action's `store.toggle(...)`), since that path deliberately bypasses `AppState` entirely
/// (FR-014/015/016 forbid a notification action from touching the app window/state directly).
/// `VolarApp.swift` observes this and calls `AppState.refreshFromStore()` so `tasks` — and
/// `MenuBarLabel.activeTask`, derived from it — catch back up without the app needing to be
/// foregrounded first.
extension Notification.Name {
    static let volarTasksDidChange = Notification.Name("volarTasksDidChange")
}

/// Ambient visual mode — mirrors the prototype's `ambient` prop
/// ('none' | 'rain' | 'snow' | 'embers' | 'custom') from `volar-ambient.jsx`.
/// String-backed + `CaseIterable`/`Identifiable` so Settings → Appearance can drive it straight
/// off a `Segmented<AmbientMode>` control and persist the raw value to `UserDefaults`.
enum AmbientMode: String, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    case none, rain, snow, embers, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .rain: return "Rain"
        case .snow: return "Snow"
        case .embers: return "Fireflies"
        case .custom: return "Custom"
        }
    }
}

/// Which transcription engine drives the NEXT voice capture — the freemium speech tier picker
/// (backlog "★ KIẾN TRÚC CHỐT"). String-backed + `CaseIterable`/`Identifiable` so Settings can
/// drive it off a picker and persist the raw value to `UserDefaults`, same convention as
/// `AmbientMode` above.
enum SpeechEngineChoice: String, Sendable, Equatable, CaseIterable, Identifiable {
    case appleOnDevice, whisperKit, groq
    var id: String { rawValue }
    var label: String {
        switch self {
        case .appleOnDevice: return "Apple (on-device)"
        case .whisperKit: return "WhisperKit (on-device)"
        case .groq: return "Groq (cloud)"
        }
    }
}

/// Local (on-device) vs Cloud task-parsing preference — the Settings switch this feature adds.
/// A thin bridge OVER the existing one-time cloud-parse consent (`cloudParseConsent` /
/// `cloudParseConsentKey`), which already gates the router's Cloud tier via
/// `DefaultCloudParseGate.isOptedIn()`: `.cloud` == opted in, `.onDevice` == not. Keeping that key
/// as the single source of truth means the voice-capture consent popover and this Settings picker
/// can never disagree. String-backed + `CaseIterable`/`Identifiable` so Settings drives it off a
/// picker, same convention as `SpeechEngineChoice` above.
enum ParseEnginePreference: String, Sendable, Equatable, CaseIterable, Identifiable {
    case onDevice, cloud
    var id: String { rawValue }
    var label: String {
        switch self {
        case .onDevice: return "On-device (private, free)"
        case .cloud: return "Cloud AI (better quality)"
        }
    }
}

/// specs/009-light-mode-list-v2/design.md §7: System/Light/Dark appearance preference (Settings →
/// General). String-backed + `CaseIterable`/`Identifiable`, same picker/persistence convention as
/// `SpeechEngineChoice`/`ParseEnginePreference` above. Deliberately holds NO `NSAppearance`
/// mapping itself — this file is compiled for iOS too (`#if canImport(AppKit)` at the top), so the
/// AppKit-only side effect (`NSApp.appearance = ...`) lives in `Volar/Sources/App/VolarApp.swift`'s
/// `AppDelegate` instead, which observes `AppState.appearance` and applies it there.
enum AppearancePreference: String, Sendable, Equatable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// How reminders are delivered (Phase 4 contract B): the visual `UNUserNotificationCenter`
/// notification always fires; this only gates the ADDITIONAL spoken channel
/// (`VoiceReminderChannel`, sibling-owned). Persisted under `AppState.voiceDeliveryModeKey` — the
/// exact seam `ReminderScheduler`/`VoiceReminderChannel` are expected to read directly from
/// `UserDefaults`, since the frozen `ReminderScheduler.init(store:voice:gate:)` takes no policy
/// parameter (read out-of-band rather than injected).
enum VoiceDeliveryMode: String, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    case visualOnly, visualPlusVoice, voiceOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .visualOnly: return "Visual only"
        case .visualPlusVoice: return "Visual + voice"
        case .voiceOnly: return "Voice only"
        }
    }
}

/// One step of a real (server- or on-device-generated) task breakdown, as rendered by
/// `TaskBreakdownView`. `id` is the step's position, not a UUID — `IntentRouter.breakdown(title:
/// notes:)` (the frozen `IntentParser` seam this is built from, `Sources/Parsing/
/// IntentParsing.swift`) returns bare `[String]` titles only; the backend's `POST /parse` with
/// `mode: "breakdown"` also returns a per-step `estimateMinutes`, but that number never survives
/// the trip through `CloudParser.breakdown(title:notes:) -> [String]` (it discards everything but
/// the title before returning — see that file, out of this task's allowed files, for the decode).
/// So there is no real per-step duration available through this seam today; `TaskBreakdownView`
/// intentionally shows none rather than inventing one (the OLD hard-coded "10 min"/"5 min" labels
/// this view used to show were exactly the kind of fake-looking content this feature removes).
struct BreakdownStep: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
}

/// State machine for `AppState.fetchBreakdown` (Change 3: real "Save all as tasks"). `TaskBreakdownView`
/// renders directly off this rather than owning any fetch state of its own.
enum BreakdownFetchState: Equatable, Sendable {
    /// No breakdown sheet open, or a fresh `openBreakdown(for:)` hasn't kicked off its fetch yet.
    case idle
    /// Request in flight (or about to be — set synchronously by `fetchBreakdown` before the async
    /// hop, so the sheet never shows a blank frame between opening and "loading").
    case loading
    /// Real steps, from either the on-device FoundationModels tier or the actual cloud call —
    /// never the hard-coded heuristic template (see `fetchBreakdown`'s doc comment for how that's
    /// ruled out). Empty is not a valid case here; `fetchBreakdown` maps an empty result to `.failed`.
    case loaded([BreakdownStep])
    /// Cloud parsing isn't usable AT ALL right now for a KNOWN reason determined before ever
    /// calling the router — not signed in, or never opted into cloud parsing
    /// (`AppState.cloudParseConsent != true`). Deliberately distinguished from `.failed` (which
    /// means an attempt was actually made) so `TaskBreakdownView` can point the user at Settings/
    /// sign-in instead of suggesting "try again."
    case unavailable
    /// Cloud was attempted (preconditions were met) but produced nothing usable — offline, quota
    /// exhausted server-side, or a decode failure. (2026-07-28: `IntentRouter.breakdown` used to
    /// have an unconditional hard-coded heuristic-template fallback here too — `HeuristicNLParser
    /// .breakdown`, `NLParser.swift` — which `fetchBreakdown` diffed the result against to catch
    /// it in disguise; that fallback is now disconnected from the router entirely, so an empty/
    /// non-real result reaches here as a plain empty array, not a template needing a diff.)
    case failed
}

/// One attribute a confirm-card chip governs (T024). Deliberately narrower than `ParsedTask`'s
/// full field list — `title`/`notes`/`subtasks` have no chip (title is the always-shown headline,
/// notes/subtasks aren't part of the v2 chip set per the contract's "Confirm + materialize"
/// section) and `conditions` are tracked separately (`dismissedConditions`/`acceptedConditions`/
/// `resolvedTaskDone`, keyed by index, since a task can carry several).
enum ChipKind: String, CaseIterable, Hashable, Sendable {
    case deadline, estimate, priority, reminder, recurrence, kind
    /// Mi-1 (constitution II): `ParsedTask.followUpReview` used to materialize a second `.review`
    /// task in `confirmSave` with no confirm-card representation at all — an unconfirmed task the
    /// user never explicitly saw or could dismiss. This chip makes it visible and dismissible like
    /// every other attribute, defaulting ON (dismissing it is the exception, not the rule) but
    /// removable before Save.
    case followUpReview
    /// T-disposition (2026-07-28, "làm ngay lập tức" / urgent-task disposition): `ParsedTask.
    /// startTime` — the instant the user said they'd START, as opposed to `.deadline` (when it's
    /// DUE). Same dismissible/uncertain-gated chip shape as every other scalar attribute above; see
    /// `TaskItem.startTime`'s own doc comment for why this is deliberately inert (never drives
    /// ordering/eligibility/reminders on its own — that's still `.deadline`'s job).
    case startTime
}

/// T-overdue (2026-07-28, confirm-card overdue nudge): the confirm card's client-side,
/// deterministic answer to "did the parser hand back a deadline that's already in the past AT
/// CAPTURE TIME" (e.g. "submit the report this morning" said at 3pm) — a plain `Date` comparison,
/// never a model call; the server side is separately instructed to return exactly the instant the
/// user said (never to silently push a spoken-past time into the future itself), so detecting
/// "did that instant already pass" is this app's job, not the parser's. `originalDeadline` is
/// `ParsedTask.deadline`'s raw value at the moment this was computed; `suggestedDeadline` is
/// `originalDeadline` moved forward by whole calendar day(s) — never a raw 86_400-second add,
/// which would land an hour off across a DST boundary — until it clears "now" (see
/// `OverdueSuggestion.makeIfOverdue` below for the exact loop + its hard cap). This is a SUGGESTION
/// only: constitution II forbids ever moving a deadline without an explicit tap, so nothing reads
/// `suggestedDeadline` unless the user acts on it via `AppState.applyOverdueSuggestion`.
struct OverdueSuggestion: Equatable, Sendable {
    let originalDeadline: Date
    let suggestedDeadline: Date

    /// Pure, deterministic, and `static` so it's directly unit-testable without constructing an
    /// `AppState`/`ConfirmDraft` at all (this task's own test guidance) — the ONE place this
    /// task's whole "was this overdue, and what's a sane fix" logic lives; `AppState.
    /// buildConfirmDrafts` just calls it. Calendar-DAY arithmetic, not a raw 86_400-second add:
    /// adding seconds crosses a DST boundary an hour off in any timezone that observes one;
    /// `Calendar.date(byAdding: .day, value: 1, to:)` preserves the wall-clock time of day across
    /// that boundary instead (self-review "correctness"). A deadline that's several days in the
    /// past — a stale transcript re-parsed days later, or "last Monday" said today — may STILL be
    /// in the past after just +1 day, so this walks forward a day at a time until the candidate
    /// clears `now`, capped at 366 iterations (a little over a year) so a corrupt/adversarial
    /// deadline can never spin this loop forever (self-review "client-exploit"). Returns `nil`
    /// when there's no deadline, the deadline is already in the future (the common case — no
    /// nudge needed), `Calendar.date(byAdding:...)` returns `nil` (should not happen for `.day`,
    /// but its `Optional` is never force-unwrapped), or the cap is hit without ever clearing `now`
    /// — all three mean "no sane suggestion to offer," never a crash or a still-wrong suggestion.
    static func makeIfOverdue(deadline: Date?, now: Date, calendar: Calendar = .current) -> OverdueSuggestion? {
        guard let deadline, deadline < now else { return nil }
        var candidate = deadline
        for _ in 0..<366 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: candidate) else { return nil }
            candidate = next
            if candidate >= now {
                return OverdueSuggestion(originalDeadline: deadline, suggestedDeadline: candidate)
            }
        }
        return nil
    }
}

/// cycle-detection-contract.md §1.2 (2026-07-29, anh Khôi: "A đợi B, B đợi C, C đợi A" must be
/// caught and explained, not silently dropped): the confirm-card batch's current `.taskDone`
/// cycle, if the drafts-plus-already-persisted-tasks graph has one right now. `nil` = clean —
/// `AppState.recomputeConfirmCycle()` is the only writer, called after every mutation that can
/// change the batch's edge set (see that method's own doc comment for the full call-site list).
/// `PopoverView` renders a BATCH-level (not per-draft) warning row off this and locks Save while
/// it's non-nil — unlike `conflicts`/`overdueSuggestion` above, this is a real error, not a
/// dismissible advisory, because dismissing it wouldn't make the cycle go away.
struct ConfirmCycle: Equatable {
    /// Closed display path: `["A", "B", "C", "A"]` — first == last, same shape
    /// `VolarCore.cyclePath`/`findCycle` return, just titles instead of ids.
    var titles: [String]
    /// Edges IN the cycle the user can remove right from the confirm card (an edge belonging to
    /// a draft in THIS batch). An edge belonging to an already-persisted task's own condition
    /// isn't in here — there's no draft/index for the card to dismiss it by; that half of the
    /// cycle has to be broken from `TaskDetailView` (§4) instead.
    var removableEdges: [RemovableEdge]

    struct RemovableEdge: Equatable, Identifiable {
        var id: String { "\(draftID)-\(conditionIndex)" }
        var draftID: ConfirmDraft.ID
        var conditionIndex: Int
        /// "C waits on A" — human-readable, same "from waits on to" reading as the titles path.
        var label: String
    }
}

/// One confirmed task's editable confirm-card state, layered OVER a router-parsed `ParsedTask`
/// (the sibling-owned contract type, never mutated in place) so every chip edit is reversible
/// before Save and `ParsedTask` itself stays exactly what the parser/router produced. This is
/// UI/materialization-only state; `AppState.confirmSave()` reads it to decide what actually gets
/// persisted (see `resolvedValue`/`resolvedConditions`).
struct ConfirmDraft: Identifiable, Equatable {
    let id = UUID()
    var task: ParsedTask
    /// 2026-07-28 (confirm-list data layer, Việc 1): ticked by default — the common case is the
    /// user wants every drafted task in the batch saved. Unticking (future `PopoverView` checkbox,
    /// lượt 2b) excludes this draft from `confirmSave()` entirely: not created, not eligible as an
    /// intra-batch `.taskDone` target (see `intraBatchTaskDone` below), nothing. Defaulting `true`
    /// is exactly what makes today's behavior fall out unchanged — every existing call site
    /// builds a fresh `ConfirmDraft` and never touches this field, so `confirmSave()` still saves
    /// every draft it's handed, same as before this field existed.
    var isIncluded: Bool = true
    /// Scalar attribute chips the user explicitly removed — dismissed attributes are never saved,
    /// regardless of confidence (constitution II: dismiss always wins).
    var dismissed: Set<ChipKind> = []
    /// Scalar attribute chips that were uncertain (<0.7) and the user explicitly tapped to accept
    /// — required before an uncertain value is ever committed (constitution II).
    var accepted: Set<ChipKind> = []
    /// `task.conditions` indices the user removed (dismissed chip, or "Skip" in the taskDone picker).
    var dismissedConditions: Set<Int> = []
    /// `task.conditions` indices for non-taskDone conditions (afterDate/external) that were
    /// uncertain (<0.7) and explicitly accepted — same gate as `accepted` above, per-condition.
    var acceptedConditions: Set<Int> = []
    /// `task.conditions` indices of `.taskDone` cases resolved to a REAL existing task id — either
    /// a confident (>=0.7 parser-confidence) fuzzy title match, or the user's explicit picker
    /// choice. Never populated by a guess below that bar (constitution II) — an unresolved
    /// `.taskDone` is simply absent here and gets dropped at save, not committed.
    var resolvedTaskDone: [Int: UUID] = [:]
    /// 2026-07-28 (confirm-list data layer, Việc 2 — real gap fix, not a new feature toggle):
    /// `task.conditions` indices of `.taskDone` cases resolved against ANOTHER DRAFT in the SAME
    /// batch rather than an already-persisted task — "xong task A thì tạo task B" said in one
    /// breath makes A and B together, so A is nowhere in `openTasks` for `preResolveConditions` to
    /// find; without this, that dependency was silently dropped at save (see that method's own
    /// doc comment). The value is the OTHER `ConfirmDraft`'s `id`, deliberately NOT a real task
    /// UUID — that task doesn't exist until `confirmSave()`'s first pass creates it. Kept as a
    /// SEPARATE map from `resolvedTaskDone` (never both set for the same index) so a real,
    /// already-persisted resolution can never be confused with a same-batch one that still needs
    /// `confirmSave()`'s second pass to become a real edge — see that method's doc comment for
    /// the two-pass save this drives.
    var intraBatchTaskDone: [Int: ConfirmDraft.ID] = [:]
    /// task_refs_v1 (2026-08-02, anh Khôi "update task đã có bằng giọng nói"): extra `.taskDone`/
    /// `.afterDate` conditions merged onto THIS draft by a DIFFERENT draft's `ParsedTaskUpdate` when
    /// that update's task reference resolved to THIS draft (`AppState.RefResolution.sibling` — "xong
    /// task A thì B lúc 3 giờ, và A đợi C" said in one breath, where A is this draft and C is
    /// another new task in the same batch). Kept as its OWN array, never folded into `task.
    /// conditions`/`intraBatchTaskDone`/`resolvedTaskDone`, for two reasons: (1) these conditions
    /// never came from THIS task's own parse at all — they arrived on a sibling draft's update
    /// payload — so there is no `task.conditions` index for them to occupy without corrupting the
    /// index space `dismissedConditions`/`acceptedConditions`/`resolvedTaskDone`/`intraBatchTaskDone`
    /// all key off; (2) `task` itself stays exactly what the router produced, never mutated in place
    /// (this struct's own header comment) — `AppState.mergeUpdateIntoSibling` DOES mutate `task.
    /// deadline`/`startTime`/`priority` directly for the SAME merge (see that method's doc comment
    /// for why THOSE three fields are a deliberate, narrow exception), but conditions have no single
    /// scalar slot to overwrite, so they get this parallel array instead. `.taskDone` targets are
    /// recorded as the OTHER draft's `id` (not yet a real task UUID), matching `intraBatchTaskDone`'s
    /// own "resolved to a real id only in `confirmSave`'s second pass" deferral exactly.
    enum RefCondition: Equatable {
        case taskDone(ConfirmDraft.ID)
        case afterDate(Date)
    }
    var refConditions: [RefCondition] = []
    /// Same "`Set<Int>` of dismissed indices, the array itself never mutated" convention as
    /// `dismissedConditions` above, scoped to `refConditions`' own index space (never shared with
    /// `dismissedConditions` — the two arrays have completely independent indices).
    var dismissedRefConditions: Set<Int> = []
    /// T074 (conflict advisory, `contracts/phase4-contract.md` §C/§E): computed ONCE, right when
    /// this draft is created from a fresh parse (`AppState.runParse`) — never recomputed per chip
    /// edit (self-review "performance"). Empty = clean capture; `PopoverView` renders AT MOST the
    /// first entry as a single calm line. Never re-derived at Save time either: the advisory is
    /// informational only and never blocks/gates `confirmSave()` (constitution II — never
    /// auto-act on it).
    var conflicts: [VolarCore.TaskConflict] = []
    /// User tapped the advisory row to dismiss it (glance-and-dismiss, same one-way convention as
    /// every other chip on this card — see `PopoverView.conflictAdvisoryRow`). Never re-surfaces
    /// within this confirm session; recording again starts fresh, same as every other draft field.
    var conflictDismissed: Bool = false
    /// T-overdue: computed ONCE, at the same time and for the same reason as `conflicts`/
    /// `duplicateCandidates` right above and below — never recomputed per chip edit (self-review
    /// "performance": re-deriving this on every keystroke would mean re-running `OverdueSuggestion.
    /// makeIfOverdue`'s `Calendar` math on every render for no reason, since the answer to "was
    /// this already overdue when the confirm card first appeared" cannot change mid-session — only
    /// the user's own action, `applyOverdueSuggestion`, ever changes it, and that clears it
    /// directly rather than re-deriving it). `nil` means either there is no deadline at all, or the
    /// deadline was still in the future at capture time — `PopoverView.overdueAdvisoryRow` renders
    /// nothing in either case.
    var overdueSuggestion: OverdueSuggestion?
    /// User tapped the overdue advisory row's text (not its "Move to tomorrow" action) to dismiss
    /// it — same one-way, never-re-surfaces-this-session convention as `conflictDismissed` above.
    /// Deliberately independent of `dismissed.contains(.deadline)`: dismissing the deadline CHIP
    /// itself already hides this row too (see `PopoverView.overdueAdvisoryRow`'s render guard), so
    /// this field only needs to cover "I saw the nudge, I don't want it" without touching the chip.
    var overdueDismissed: Bool = false
    /// specs/010-calendar-and-hard-deadlines/design.md §2.4(a): the single busiest-value calendar
    /// conflict warning — "14:00–15:00 · Họp nội bộ" — computed ONCE in `buildConfirmDrafts`, same
    /// "never recomputed per chip edit / per render" rule `overdueSuggestion`/`conflicts` right
    /// above already document (see those fields' own comments for why). `nil` when the "Read my
    /// calendar" toggle is off (§2.5, default off), when this draft has neither `deadline` nor
    /// `startTime`, or when neither instant falls inside a `CalendarAccess.BusyBlock`.
    ///
    /// PRIVACY (§2.5, §2.4a, not optional): this is a formatted DISPLAY STRING — "start–end · the
    /// conflicting event's own title" — never a `CalendarAccess.BusyBlock`/`EKEvent` itself. It is
    /// rendered as-is by `PopoverView` and never read by anything in `Sources/Parsing/CloudParser.
    /// swift` (grepped `CloudParser.appendContext` and every one of its request-building call
    /// sites while adding this field — none take a `ConfirmDraft` or this string; see this task's
    /// final report). Keep it that way: an event's title must never reach a cloud parse payload.
    var calendarConflict: String?
    /// User-edited deadline, written only by `AppState.applyOverdueSuggestion` today. `nil` until
    /// the user actually taps "Move to tomorrow" — mirrors `editedTitle`/`effectiveTitle` below
    /// EXACTLY: `ParsedTask` stays exactly what the parser/router produced, never mutated in place;
    /// every edit lives in this draft layer overlaid on top instead (same "never mutated in place"
    /// contract `editedTitle`'s own doc comment documents). Named/shaped generally (a `Date?`, not
    /// an "overdue-fix-only" type) so a future free-form deadline picker could reuse this same
    /// field rather than needing a second one — `applyOverdueSuggestion` just happens to be its
    /// only writer today.
    var editedDeadline: Date?
    /// 2026-07-28 (confirm-list data layer, Việc 3): up to 3 already-persisted tasks whose title
    /// looks like it might BE this same task, worth surfacing so the user can say "oh, I already
    /// have that" instead of ending up with two rows for the same thing. Computed EXACTLY ONCE,
    /// right when this draft is created (`AppState.buildConfirmDrafts`) — never recomputed as the
    /// user edits chips/title (self-review "performance": that would be an O(n) `openTasks` scan
    /// per keystroke). See `AppState.duplicateCandidates(for:in:)` for the threshold and why it's
    /// deliberately looser than `preResolveConditions`'s auto-resolve bar.
    var duplicateCandidates: [UUID] = []
    /// The user's call on what to do about `duplicateCandidates` — constitution II forbids ever
    /// picking `.useExisting` FOR the user, so this always starts (and stays, absent explicit
    /// input from a future `PopoverView` picker, lượt 2b) at `.addNew`. `Equatable` is declared
    /// explicitly (rather than relying on synthesis) per this task's own technical constraints.
    enum DuplicateResolution: Equatable {
        /// Default: create a brand-new task, exactly like today (no duplicate handling existed
        /// before this field).
        case addNew
        /// The user explicitly said "that's the same task" — `confirmSave()` merges this draft's
        /// resolved attributes/conditions INTO the existing task at this id instead of creating a
        /// second row. Never reached without an explicit user choice.
        case useExisting(UUID)
    }
    var duplicateResolution: DuplicateResolution = .addNew
    /// User-edited title from the confirm card's editable title field (`PopoverView.taskDraftCard`).
    /// `nil` until the user actually types something — mirrors the Windows port's
    /// `ConfirmDraft.EditedTitle` (`voci-windows/windows/.../CaptureFlowService.cs:126-134`), but
    /// written through `AppState.updateDraftTitle(_:forDraft:)` rather than an object reference,
    /// since this is a `struct` (see below). Never written into `task.title` directly — `ParsedTask`
    /// stays exactly what the parser/router produced, same "never mutated in place" contract this
    /// whole struct's header comment already documents for every other field.
    var editedTitle: String?
    /// The title actually rendered and saved: the user's edit if there is one and it isn't blank
    /// after trimming, else the parser's original `task.title`. A whitespace-only edit silently
    /// falls back rather than blocking Save or showing an error (constitution V — glance-and-dismiss,
    /// never a dead end).
    var effectiveTitle: String {
        guard let editedTitle else { return task.title }
        // Newlines are flattened, not just trimmed at the ends: the confirm card's title field is
        // multi-line so it can WRAP, never so a task title can contain line breaks. If Return ever
        // reaches the field instead of saving (see PopoverView's own note on `.onKeyPress`), the
        // break dies here rather than in the task list.
        let flattened = editedTitle
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        let trimmed = flattened.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? task.title : trimmed
    }
    /// The deadline actually resolved and saved: `editedDeadline` if the user has set one — via
    /// the overdue nudge's "Move to tomorrow" (`applyOverdueSuggestion`) OR a direct manual edit
    /// through the confirm card's `DatePicker` (`AppState.setDraftDeadline`, T-edit-deadline
    /// 2026-07-28 — the SAME write path whether the draft already had a deadline or had none at
    /// all) — else the parser's original `task.deadline`. Same "draft layer overlays the frozen
    /// parse" shape `effectiveTitle` above already establishes. Confidence is pinned to `1.0`
    /// (never inherited from `task.deadline`'s own confidence) whenever `editedDeadline` is set:
    /// the user explicitly choosing that exact instant — whether by tapping a suggestion or
    /// picking a time by hand — IS full confidence by definition, and anything less would let it
    /// fall into `ChipKind.deadline`'s "<0.7 needs an explicit accept" gate (`resolvedValue`) —
    /// silently requiring a SECOND tap on the deadline chip before an already-explicit user edit
    /// actually saves, which would make the edit a lie. `AppState.confirmSave`/`materialize`/
    /// `mergeTransform` (and `PopoverView`'s deadline chip) all read the deadline through THIS
    /// property, never `task.deadline` directly, specifically so any edit takes effect everywhere
    /// the original value used to be read (self-review "save path" — see this task's final report
    /// for the full call-site audit).
    var effectiveDeadline: ParsedValue<Date>? {
        if let editedDeadline {
            return ParsedValue(value: editedDeadline, confidence: 1.0)
        }
        // 2026-08-01: a DERIVED deadline follows the two values it was derived from. See
        // `rederivedDeadline` below — returns `nil` for every deadline the user actually stated, so
        // this line is the unchanged path for all of them.
        if let rederived = rederivedDeadline {
            return rederived
        }
        return task.deadline
    }

    /// Recomputes a MACHINE-DERIVED deadline (`startTime + estimate`) whenever the user edits either
    /// input it was built from — `nil` in every other case, so the ordinary path through
    /// `effectiveDeadline` above is untouched.
    ///
    /// THE BUG THIS FIXES (2026-08-01): `IntentRouter.applyStartTimeDerivation` fills an urgent,
    /// no-deadline utterance's `deadline` AND `estimateMinutes` from the SAME number — anh Khôi's
    /// single "default task duration" setting — precisely so the estimate chip and the deadline chip
    /// can never state two different durations for one task. But the confirm card's estimate chip
    /// wrote only `editedEstimateMinutes`, and `materialize` deliberately does no date math of its
    /// own, so changing 30' to 60' moved the estimate chip and left the deadline chip at start+30':
    /// the exact disagreement the one-setting design exists to prevent, now visible on screen.
    /// Editing the START TIME had the same effect — the derived deadline stayed anchored to the old
    /// start.
    ///
    /// Three guards keep this narrow, and each one matters:
    ///   - `task.deadlineIsEstimated` — the ONLY signal that this deadline was machine-derived
    ///     rather than spoken. A user who said "5 giờ chiều phải xong" gets `false` here, so their
    ///     stated deadline is never recomputed out from under them (constitution II).
    ///   - `editedDeadline == nil` (enforced by the caller above) — an explicit manual deadline edit
    ///     always wins over anything derived, in both directions.
    ///   - a positive `estimate` and a real `startTime` — with either missing there is nothing to
    ///     derive from, so the original derived value stands rather than being dropped.
    ///
    /// Confidence is INHERITED from the original derived deadline (0.75 today), never raised to
    /// `1.0` the way `editedDeadline` is: the user edited the estimate, not the deadline — the
    /// deadline is still the app's arithmetic, and it must keep rendering with `PopoverView
    /// .DeadlineControl`'s "est" marker (which keys off `deadlineIsEstimated` + `editedDeadline ==
    /// nil`, both still true here). It stays above `ParsedValue.isUncertain`'s 0.7 bar for the same
    /// reason the derivation picked 0.75 in the first place — see `applyStartTimeDerivation`'s long
    /// comment on why dropping below that bar silently broke the whole urgent-task feature once.
    private var rederivedDeadline: ParsedValue<Date>? {
        guard task.deadlineIsEstimated, let original = task.deadline else { return nil }
        guard let start = effectiveStartTime?.value,
              let minutes = effectiveEstimateMinutes?.value, minutes > 0 else { return nil }
        // `Calendar`, never raw `TimeInterval` second-math — same DST-safe convention (and the same
        // "return the value unchanged rather than fabricate one from a failed computation" handling
        // of a `nil` overflow result) as `applyStartTimeDerivation`, which produced `original`.
        guard let recomputed = Calendar.current.date(byAdding: .minute, value: minutes, to: start)
        else { return nil }
        return ParsedValue(value: recomputed, confidence: original.confidence)
    }
    /// User-edited notes/description from the confirm card's notes editor
    /// (`PopoverView.notesEditor`, T-edit-notes 2026-07-28 — anh Khôi: users need to fix a
    /// misheard/misparsed description right on the card, not just the title). `nil` until the
    /// user actually types something — same "overlay, never mutate `ParsedTask`" contract
    /// `editedTitle` documents above; written through `AppState.updateDraftNotes(_:forDraft:)`.
    var editedNotes: String?
    /// The notes actually saved: the user's edit if there is one and it isn't blank after
    /// trimming, else the parser's original `task.notes` — same fallback shape as `effectiveTitle`
    /// above, with ONE deliberate difference: newlines are NOT flattened here. A task title is
    /// conceptually single-line (it only wraps for display), but notes/description is genuinely
    /// multi-line free text — a grocery list or a set of instructions someone dictated is exactly
    /// the kind of note where line breaks are part of the content, not an artifact of the text
    /// field wrapping. Only the ENDS are trimmed (leading/trailing whitespace/newlines from
    /// however the field left focus), never anything in the middle.
    var effectiveNotes: String? {
        guard let editedNotes else { return task.notes }
        let trimmed = editedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? task.notes : trimmed
    }

    // MARK: - T-edit-attrs (2026-07-29, manual-edit-contract.md §1.1): the remaining 4 confirm-card
    // attributes anh Khôi wants editable — priority/startTime/estimate/reminder-cadence — laid out
    // in the SAME overlay shape `editedDeadline`/`effectiveDeadline` above already establish (`nil`
    // until the user acts, never mutate `task` in place). Each `edited*` is written by exactly one
    // setter below (`AppState.setDraftPriority` etc.); each `effective*` is what `materialize`/
    // `mergeTransform`/`PopoverView`'s chips must read instead of `task.*` directly — see §2.

    /// User-edited priority from the confirm card's priority chip. `nil` = user chưa sửa.
    var editedPriority: Int?              // 1...3, nil = user chưa sửa
    /// User-edited start time from the confirm card's start-time chip.
    var editedStartTime: Date?
    /// User-edited estimate/duration (minutes) from the confirm card's estimate chip.
    var editedEstimateMinutes: Int?       // > 0
    /// User-edited reminder CADENCE (not a full policy) from the confirm card's reminder chip —
    /// see `effectiveReminderOverride` below for how a lone period gets folded into a full
    /// `ReminderPolicy` at read time.
    var editedRemindPeriod: TimeInterval? // giây, > 0

    /// The priority actually resolved and saved: `editedPriority` if set, else the parser's
    /// original `task.priority`. Confidence is pinned to `1.0` whenever `editedPriority` is set —
    /// same non-negotiable reasoning `effectiveDeadline`'s doc comment above spells out in full:
    /// inheriting the parser's own (possibly <0.7) confidence would route an already-explicit tap
    /// back through `ChipKind.priority`'s uncertain-accept gate (`resolvedValue`), silently
    /// demanding a SECOND confirmation before the user's own edit actually saves — turning the edit
    /// into a lie. `materialize`/`mergeTransform` must read priority through THIS property, never
    /// `task.priority` directly, exactly like `effectiveDeadline`'s call sites.
    var effectivePriority: ParsedValue<Int>? {
        if let editedPriority {
            return ParsedValue(value: editedPriority, confidence: 1.0)
        }
        return task.priority
    }
    /// The start time actually resolved and saved — same shape/confidence-pinning reasoning as
    /// `effectivePriority` immediately above.
    var effectiveStartTime: ParsedValue<Date>? {
        if let editedStartTime {
            return ParsedValue(value: editedStartTime, confidence: 1.0)
        }
        return task.startTime
    }
    /// The estimate/duration actually resolved and saved — same shape/confidence-pinning reasoning
    /// as `effectivePriority` above.
    var effectiveEstimateMinutes: ParsedValue<Int>? {
        if let editedEstimateMinutes {
            return ParsedValue(value: editedEstimateMinutes, confidence: 1.0)
        }
        return task.estimateMinutes
    }
    /// The reminder policy actually resolved and saved. UNLIKE the three accessors above, this
    /// can't just swap in the raw edited value — `editedRemindPeriod` is a single cadence, not a
    /// full `ReminderPolicy` — so it folds onto a BASE policy first: `task.reminderOverride`'s
    /// value if the parser produced one, else `.defaultPolicy` (never `nil` — there must always be
    /// SOME base to carry `offsets`/`repeatEvery`/`fractionsRemaining` forward from). Only
    /// `remindPeriod` itself is overwritten; every other field of the base survives untouched
    /// (manual-edit-contract.md §1.1). `ReminderRecord.derive` already prefers `remindPeriod` over
    /// `fractionsRemaining` whenever both are present, so overwriting just this one field is enough
    /// to make the user's stated cadence win — no need to also clear `fractionsRemaining` here.
    var effectiveReminderOverride: ParsedValue<ReminderPolicy>? {
        guard let editedRemindPeriod else { return task.reminderOverride }
        var policy = task.reminderOverride?.value ?? .defaultPolicy
        policy.remindPeriod = editedRemindPeriod
        return ParsedValue(value: policy, confidence: 1.0)
    }
}

// MARK: - task_refs_v1 (2026-08-02): "update an existing task by voice" — resolution + confirm
// state for `ParsedCapture.taskRefs`/`.updates` (the sibling wire-layer's `Sources/Parsing/
// ParsedCapture.swift`, consumed here BY NAME ONLY, never redefined). See `AppState.runParse`/
// `resolveTaskRefs`/`buildConfirmUpdateDrafts`/`confirmSave` for the pipeline this state feeds.

/// How ONE `ParsedTaskRef` (a fuzzy title the model referenced, e.g. "task báo cáo") resolved
/// against this parse's snapshot — computed ONCE per ref by `AppState.resolveTaskRefs`, then shared
/// by every `ParsedTaskUpdate` whose `refIndex` points at it (task brief: "Resolve each ref ONCE").
/// Mirrors `ConfirmDraft.DuplicateResolution`'s "explicit enum, no raw `UUID?`" shape for the same
/// reason: a `nil` here would conflate "resolved to nothing yet" with "not yet attempted."
enum RefResolution: Equatable {
    /// A confident fuzzy match against an ALREADY-PERSISTED open task (`AppState.bestFuzzyMatch`,
    /// same ≥0.7 bar `preResolveConditions` uses for `.taskDone` — see `scoredMatches`'s doc
    /// comment for why a wrong match here is real corruption, not a glance-and-ignore hint, and
    /// therefore keeps that bar even though the scorer underneath it got more forgiving).
    case existing(UUID)
    /// A confident fuzzy match against ANOTHER draft in this SAME batch (`AppState.scoredMatches`,
    /// same bar) — "task A ... và cập nhật task B luôn" where B is a task this very utterance is
    /// also creating. Carries the OTHER `ConfirmDraft`'s `id`, never a real task UUID (that task
    /// doesn't exist until `confirmSave` creates it) — same "not real until confirmSave" deferral
    /// `ConfirmDraft.intraBatchTaskDone`'s doc comment documents for the analogous `.taskDone` case.
    case sibling(ConfirmDraft.ID)
    /// Neither ladder step cleared the 0.7 bar — constitution II: never auto-attach a low-confidence
    /// or no-match reference. `PopoverView` renders a picker (`AppState.resolveUpdateTarget`) rather
    /// than guessing; still-unresolved at Save is dropped (`confirmSave`'s own doc comment).
    case unresolved
}

/// One confirm-card update to an ALREADY-EXISTING (or, transiently, same-batch-sibling) task,
/// layered over a router-parsed `ParsedTaskUpdate` (the sibling-owned contract type) the SAME way
/// `ConfirmDraft` layers over `ParsedTask` — see that struct's header comment for the "never mutate
/// the parsed payload in place, edits live in overlay fields" contract this follows verbatim, reused
/// rather than reinvented (task brief: "REUSE its conventions... do not invent a second interaction
/// grammar").
///
/// PRODUCT DECISION (anh Khôi, 2026-08-02, hard requirement): an update to an EXISTING task is NEVER
/// auto-committed, at ANY confidence — mutating a task that already exists is strictly riskier than
/// creating a new one (constitution II). That is why this struct exists as a SEPARATE confirm-card
/// entity at all, rather than folding straight into `ConfirmDraft`/`confirmSave`: every instance
/// here (except a `.sibling`-resolved one, which never becomes a card in the first place — see
/// `AppState.mergeUpdateIntoSibling`) renders its OWN dismissible/editable card, and only what
/// survives on screen to the moment the user hits Save is ever applied (`AppState.confirmSave`).
///
/// A `.sibling`-resolved `ParsedTaskUpdate` is merged straight into its target `ConfirmDraft` at
/// construction time and NEVER produces one of these — "the referenced task turned out to be one the
/// user is creating in the same breath," so its fields flow through that draft's OWN chips
/// (`AppState.mergeUpdateIntoSibling`), which already carry the exact same confirm/dismiss gate this
/// struct provides for an `.existing` target. `resolution` therefore only ever holds `.existing` or
/// `.unresolved` for an instance that actually reaches `AppState.confirmUpdateDrafts` — `.sibling`
/// stays a valid case on the shared `RefResolution` enum (so `resolveTaskRefs`'s ladder has one
/// return type for all three outcomes) but is unreachable here in practice; `PopoverView` falls back
/// to the `.unresolved` picker rather than rendering nothing if that invariant is ever violated.
struct ConfirmUpdateDraft: Identifiable, Equatable {
    let id = UUID()
    /// 1-based, into `ParsedCapture.taskRefs` — the wire contract's own indexing convention,
    /// preserved verbatim (not converted to 0-based) so a `// UNVERIFIED`/telemetry log naming this
    /// index always matches what the router/server actually said.
    var refIndex: Int
    /// The fuzzy title the model referenced (`ParsedTaskRef.titleQuery`) — display fallback for the
    /// `.unresolved` picker's label and for `AppState.logCorrection`-style telemetry when this draft
    /// is dropped unresolved at Save (there is no `ParsedTask.sourceTranscript` to log against here,
    /// unlike `ConfirmDraft`, since this struct has no `ParsedTask` of its own).
    var sourceTitleQuery: String
    var resolution: RefResolution
    var deadline: ParsedValue<Date>?
    var startTime: ParsedValue<Date>?
    /// APPENDS to the existing task's notes at Save — never overwrites (see `AppState.
    /// mergeNotesAppending`, the SAME helper `ConfirmDraft`'s own merge-into-existing path already
    /// uses, reused verbatim here rather than a second copy).
    var notesAppend: ParsedValue<String>?
    var priority: ParsedValue<Int>?
    var addConditions: [ParsedUpdateCondition]

    /// The 4 fields above, as a dismiss/accept KEY set — deliberately a NEW small enum, not a reuse
    /// of `ChipKind`: `ChipKind` also carries `estimate`/`reminder`/`recurrence`/`kind`/
    /// `followUpReview`, none of which this struct has a field for, so reusing it verbatim would let
    /// `dismissed`/`accepted` hold meaningless states (e.g. "estimate dismissed" on a struct with no
    /// estimate). The MECHANICS below (present/dismissed/uncertain-needs-accept) are the exact same
    /// gate `ConfirmDraft.dismissed`/`.accepted`/`AppState.resolvedValue` already apply — see
    /// `AppState.resolvedUpdateValue`, the direct sibling of `resolvedValue` scoped to this enum —
    /// so this is "reuse the CONVENTION," not "invent a new grammar," per the task brief's own
    /// framing of that distinction.
    enum Field: Hashable {
        case deadline, startTime, notesAppend, priority
    }
    /// Chip explicitly removed by the user — never saved, regardless of confidence (constitution
    /// II: dismiss always wins, same as `ConfirmDraft.dismissed`).
    var dismissed: Set<Field> = []
    /// Explicit tap-to-accept for an uncertain (<0.7) field chip, same gate `ConfirmDraft.accepted`
    /// enforces for a brand-new task's attributes.
    var accepted: Set<Field> = []
    /// `addConditions` indices the user explicitly removed — same `Set<Int>`-over-the-array
    /// convention as `ConfirmDraft.dismissedConditions` (the array itself is never mutated).
    var dismissedAddConditions: Set<Int> = []
    /// Card-level dismiss (task brief: "Card-level dismiss removes the whole update") — also how the
    /// `.unresolved` picker's "Skip" resolves (`AppState.resolveUpdateTarget(_: to: nil)`), mirroring
    /// `dependencyPicker`'s own "Skip — no dependency" -> `dismissCondition` wiring.
    var cardDismissed: Bool = false
}

// MARK: - Phase 5 (T036): voice-done confirm state (contract A `VoiceDoneIntent`/`VoiceMatch`)

/// Which voice-done intent (contract A) a `VoiceDoneConfirm` answers — mirrors
/// `VoiceDoneIntent`'s two actionable cases (`.notACompletion` never reaches this type; it falls
/// straight through to the ordinary capture flow in `finishRecording` instead).
enum VoiceDoneAction: Sendable, Equatable {
    case complete
    case clearExternal
}

/// The pending glance-and-dismiss confirm for a `.complete`/`.clearExternal` voice-done match
/// (constitution II: never silently complete/clear a task — always surfaced here for an explicit
/// tap first). One candidate -> `PopoverView` renders a single one-tap/one-word confirm; several
/// -> a bounded disambiguation list (the defensive cap is applied where this is constructed, in
/// `presentVoiceDoneConfirm` below — self-review "client-exploit").
struct VoiceDoneConfirm: Identifiable, Equatable {
    let id = UUID()
    let action: VoiceDoneAction
    let candidates: [VoiceMatch]
}

// MARK: - Sidebar navigation sections (2026-07-27 — port of the Windows reference:
// voci-windows/windows/src/Volar.App/ViewModels/NavSection.cs)
//
// The sidebar's three rows (Sidebar.swift) existed since Wave 1 but only Today did anything;
// Upcoming/Inbox rendered hardcoded counts (12/3) with empty `{}` actions. This enum is what makes
// them navigation rather than decoration. Membership rules live in `Sources/Model/TaskSections.swift`
// — deliberately NOT here, same separation the Windows original draws between `NavSection.cs` and
// `TaskSections.cs`.
// `Hashable` (2026-08-22): sidebar giữ tập section đang gập trong một `Set<NavSection>`.
enum NavSection: Sendable, Equatable, Hashable {
    /// 2026-08-24 (anh Khôi): còn ba. `upcoming` bỏ hẳn; `inbox` (việc chưa có ngày) đổi thành
    /// `archived` (việc đã cất đi). `completed` vào từ 2026-08-22, thay cho ngăn "Completed" gập
    /// sẵn ở cuối Today — Today nay chỉ trả lời đúng một câu, việc đang phải làm.
    case today, archived, completed
}

/// One day's worth of Upcoming rows. `header` is pre-formatted ("Tomorrow" / "Wed, Mar 18") so
/// `TodayView` stays free of date formatting, matching how `todayDateLabel` is already handed over
/// ready to render there. Mirrors Windows `UpcomingDayGroup` (NavSection.cs:19-26) — `tasks` stands
/// in for that type's `Rows` of row view-models, since this app reuses `TaskItem`/`TaskRow` directly
/// rather than a separate row view-model layer.
struct UpcomingDayGroup: Identifiable, Equatable {
    /// The header text is unique per computation (one entry per calendar day) and stable across
    /// re-renders of the same day, unlike a freshly-minted `UUID()` would be — using it as `id`
    /// keeps SwiftUI's diffing from treating every recompute as an all-new list.
    var id: String { header }
    let header: String
    let tasks: [TaskItem]
}

/// One implementation-intention cue currently on screen (`AppState.cueBanner`'s value type,
/// specs/006-cues-and-waiting/design.md §2 Việc B / §3). A thin DISPLAY projection of `TaskCue` —
/// never the type itself, and `CueKind` is deliberately NOT carried through here at all: design.md
/// §3 forbids ever rendering "wake"/"dayEnd"/"unknown" on screen, and the surest way to guarantee
/// that is to not even hand the renderer a `kind` to accidentally interpolate. `createdAt` is
/// carried only so the view can phrase a calm, date-aware lead-in ("Tối qua anh nói…" vs "Anh
/// nói…") without reaching back into `AppState`/`TaskCue` for it.
struct CueBanner: Identifiable, Equatable {
    var id: UUID { taskId }
    let taskId: UUID
    let verbatim: String
    let createdAt: Date
}

@Observable
@MainActor
final class AppState {
    // MARK: - Frozen §4 stored state

    var tasks: [TaskItem]
    var accent: VolarAccent
    var density: Density
    var glass: GlassLevel
    var ambient: AmbientMode
    var customImageURL: URL?
    var voiceFeedback: Bool

    // Capture / popover
    enum CaptureState: Sendable, Equatable {
        case idle, recording, parsing, parsed, saving, done, error
    }
    var captureState: CaptureState
    var liveTranscript: String
    /// Up to 10 (`TaskStore.maxBatchSize`) confirm-card drafts from the last parse — replaces the
    /// v1 single `ParsedTask?` now that one utterance can yield a compound/multi-task result
    /// (contract "Confirm + materialize": multi-task confirm, ≤10). Empty = nothing to confirm.
    var confirmDrafts: [ConfirmDraft] = []
    /// task_refs_v1 (2026-08-02): confirm-card updates to EXISTING tasks from the last parse's
    /// `ParsedCapture.taskRefs`/`.updates` — a `.sibling`-resolved update never lands here at all
    /// (see `ConfirmUpdateDraft`'s own doc comment), so this is only ever `.existing`/`.unresolved`
    /// entries. Empty = nothing to confirm, same "no reference in this utterance" degrade every
    /// other reader of this property treats identically to the pre-task_refs_v1 behavior
    /// (`PopoverView`'s new section renders nothing at all when this is empty — self-review
    /// "no-reference path pixel-identical").
    var confirmUpdateDrafts: [ConfirmUpdateDraft] = []
    /// cycle-detection-contract.md §1.2: `nil` = batch sạch (no `.taskDone` cycle right now).
    /// Non-nil means `PopoverView` must show the batch-level cycle warning and LOCK Save — see
    /// `ConfirmCycle`'s own doc comment and `AppState.recomputeConfirmCycle()`. Only that method
    /// writes this; every other reader treats it as derived state.
    private(set) var confirmCycle: ConfirmCycle?
    /// T036: populated INSTEAD OF `confirmDrafts` when `finishRecording` classifies the transcript
    /// as `.complete`/`.clearExternal` (contract A) — routes to a distinct one-tap/disambiguation
    /// card in `PopoverView` rather than the normal parsed-task confirm card. `nil` = no voice-done
    /// confirm pending. Additive state (not part of the frozen §4 surface), mutually exclusive
    /// with `confirmDrafts` (a given `finishRecording` call populates at most one of the two).
    var voiceDoneConfirm: VoiceDoneConfirm?
    /// T036: set INSTEAD OF `voiceDoneConfirm` when a done/clear phrasing was detected but ZERO
    /// candidates matched (constitution II: state it, never guess) — holds the original transcript
    /// so `captureVoiceDoneAsNewTask()` can resume it into the normal capture flow. `nil` = not
    /// showing the "no matching task" row.
    var voiceDoneNoMatchTranscript: String?
    private(set) var captureErrorDetail: String?
    /// User consented to Apple server-based recognition (audio leaves the Mac). Persisted.
    private(set) var allowServerRecognition: Bool
    /// Speech-recognition language, as a BCP-47/locale identifier (e.g. "en-US", "vi-VN") or the
    /// `autoRecognitionLocaleID` ("auto") sentinel for "let each engine auto-detect". Persisted;
    /// applied live to both `speech` and `groq` via `setRecognitionLocale`.
    private(set) var recognitionLocaleID: String
    /// Which transcription engine the user picked in Settings (freemium tier). Persisted; the
    /// engine actually used for a given capture is further gated by `selectedEngine` (e.g.
    /// WhisperKit falls back to Apple when unsupported or its model isn't loaded yet).
    private(set) var speechEngineChoice: SpeechEngineChoice
    /// specs/009-light-mode-list-v2/design.md §7: System/Light/Dark appearance preference
    /// (Settings → General). Persisted; `VolarApp.swift`'s `AppDelegate` applies it to
    /// `NSApp.appearance` at launch AND live on every change (see `setAppearance` below).
    private(set) var appearance: AppearancePreference
    /// specs/010-calendar-and-hard-deadlines/design.md §2.5: a SEPARATE opt-in from calendar
    /// mirroring/EventKit permission — granting EventKit access (`calendarAccess.status ==
    /// .granted`, needed for the mirror feature) does NOT imply consent to read event content back
    /// (busy blocks, titles). Two different sensitivity levels: writing Volar's own tasks into a
    /// calendar it created vs. reading the user's other events. Persisted; defaults `false`
    /// (`UserDefaults.bool(forKey:)`'s own default for an unset key — same convention
    /// `allowServerRecognition` already uses). `AppState.hardAnchors(now:)`/
    /// `calendarConflictDescription(for:)` are the only two call sites that ever check this before
    /// touching `calendarAccess.busyBlocks` — see `setCalendarReadEnabled` below for the writer.
    private(set) var calendarReadEnabled: Bool
    /// True when capture failed because on-device recognition is unavailable (Dictation off) and
    /// the user hasn't consented to server recognition yet — drives the popover's hint + consent UI.
    private(set) var pendingServerConsent = false
    /// Cloud-parse opt-OUT flag (T024/contract R5): `nil` = never answered, which since
    /// 2026-09-06 means YES — cloud parsing is the default on every entry point and nothing asks
    /// (see `proceedToCapture`). Persisted, so an explicit `false` (Settings ▸ parse engine, or
    /// the onboarding toggle switched off) survives relaunch and still keeps every transcript on
    /// the device. Read by `DefaultCloudParseGate.isOptedIn()` below — the REAL seam with
    /// `IntentRouter` is that injected `CloudParseGate` protocol
    /// (`Sources/Parsing/IntentParsing.swift`, landed), not a convention this file has to guess at.
    private(set) var cloudParseConsent: Bool?
    /// Drives the popover's one-time cloud-parse consent row (mirrors `pendingServerConsent`'s
    /// reuse of the `.error` capture state for a non-error consent prompt). DORMANT since
    /// 2026-09-06: `proceedToCapture` no longer sets it, so the row never renders — kept (with
    /// `resolveCloudConsent` and its `PopoverView`/`CaptureSheet` UI) so re-arming the prompt, if
    /// an App Store review ever demands one, is a one-line change rather than a rebuild.
    private(set) var pendingCloudConsent = false
    /// The transcript awaiting a decision in `pendingCloudConsent`, resumed by `resolveCloudConsent`.
    private var pendingParseTranscript: String?

    // MARK: - Typed capture (⌃⌥T, `Sources/Views/TextCapturePanel.swift`) — "type one line, hit
    // Add task, done." A SEPARATE state machine from `captureState` above, deliberately: the typed
    // popup is a smaller surface with no recording/parsing-in-place/multi-second-wave visuals, and
    // — for the genuinely simple case (2026-07-28, Việc 4: one task, no duplicate hint, no
    // condition) — skips the confirm-card review pause `captureState == .parsed` exists for (see
    // `submitTextCapture()`'s doc comment for exactly why and how it still reuses the SAME
    // underlying save path). Anything more complex hands off to that SAME review pause instead of
    // guessing (`applyTextCaptureParseResult`'s own doc comment). Mutually exclusive with
    // `captureState`'s voice surface by construction (`openTextCapture()`/`handleHotkey()` below,
    // and `VolarApp.swift`'s `syncCapturePanel()`) — never both non-idle/non-closed at once.
    enum TextCaptureState: Sendable, Equatable {
        case closed
        case editing
        case saving
        case saved(titles: [String])
        case failed(String)
    }
    var textCapture: TextCaptureState = .closed
    var textCaptureInput: String = ""
    /// Monotonic guard mirroring `captureSession`'s role (see that property's doc comment) but
    /// scoped to the text-capture surface only. Kept as its OWN counter — never shared with
    /// `captureSession` — because a text capture and a voice capture can never be in flight at the
    /// same time (mutual exclusion is enforced by tearing the OTHER surface down before opening
    /// this one; see `openTextCapture()`), so there is no scenario where one counter needs to
    /// invalidate the other's in-flight work; keeping them separate just avoids one surface's
    /// cancel/retry accidentally bumping — and thereby invalidating — the other's guard for no
    /// reason.
    private var textCaptureSession = 0

    // MARK: - Phase 4: reminder / voice-delivery / triage settings (contract E)

    /// Persisted (`voiceDeliveryModeKey`); default `.visualPlusVoice` per contract B.
    private(set) var voiceDeliveryMode: VoiceDeliveryMode
    /// Persisted (`globalReminderPolicyKey`); default `ReminderPolicy.defaultPolicy`.
    private(set) var globalReminderPolicy: ReminderPolicy
    /// Persisted (`defaultTaskDurationMinutesKey`); default `30`. anh Khôi chốt 2026-07-29: ONE
    /// setting doing two jobs — the `estimateMinutes` a task gets when the model/user didn't give
    /// one, AND the number of minutes added to `startTime` to derive a deadline for an urgent,
    /// no-deadline utterance (`IntentRouter.applyStartTimeDerivation`). Same number both places on
    /// purpose, so the confirm card's estimate chip and its deadline chip can never disagree about
    /// how long the task is meant to take. Valid range 5...480 minutes — see `setDefaultTaskDurationMinutes`
    /// and this property's `init` read below for why out-of-range/absent values fall back to 30.
    private(set) var defaultTaskDurationMinutes: Int
    /// FR-018 weekly triage: task id -> instant last explicitly "kept" via `triageKeep(_:)`, so
    /// `staleTasks` doesn't immediately re-offer something the user just decided to keep. Falls
    /// back to `createdAt` for any task never explicitly kept (best available staleness proxy —
    /// see `staleTasks`'s doc comment for the full seam note). Lightly persisted so a relaunch
    /// mid-week doesn't lose "just kept" state.
    private var triageKeptAt: [UUID: Date]
    /// FR-030: task ids that have ALREADY been shown the one-time "want to split this up?"
    /// invite (`switchBreakdownSuggestion`) — checked before ever arming it again, so a task that
    /// crosses the switch-away threshold a second, third, ... time is never re-asked. Persisted
    /// (same `UserDefaults`-array-of-`uuidString` shape as `triageKeptAt`'s own dictionary
    /// persistence right above) so a relaunch can't re-ask a question the user already answered —
    /// this is the "bền qua restart" half of the FR-030 "one-time" rule. Never surfaced to the
    /// user in any form (no badge, no visible count) — purely an internal gate.
    private var switchBreakdownOffered: Set<UUID>

    // Focus session
    var focusActive: Bool
    var focusPaused: Bool
    var focusSecondsLeft: Int
    var focusIndex: Int

    // MARK: - Modal / banner state (Phase 3: mounts MorningFrogView / TaskBreakdownView /
    // NotificationView into the running app; not part of the frozen §4 surface, additive only).

    struct ReminderBanner: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var timing: String
    }

    var showMorningFrog = false
    var showBreakdown = false
    /// Which task the "Break down into steps…" context-menu action (`TaskRow.swift`,
    /// `TodayView.swift` x2, `triageBreakdown(_:)` below) was invoked on — `nil` while the sheet
    /// is closed. Kept as a SEPARATE property rather than folding it into `showBreakdown` itself
    /// (e.g. `showBreakdown: TaskItem?`) because `VolarApp.swift` (outside this change's allowed
    /// files) already binds `.sheet(isPresented:)` to the bare `Bool` and constructs
    /// `TaskBreakdownView(onSave:onClose:)` from it; changing that shape would require editing a
    /// file this task is not permitted to touch. `TaskBreakdownView` already receives the full
    /// `AppState` via `.environment(appState)` in that same `VolarApp.swift` wiring, so it reads
    /// this property directly instead of needing a new init parameter — no seam is actually
    /// missing, just routed differently than a single merged property would be.
    ///
    /// Every call site that sets `showBreakdown = true` MUST also set this in the same call
    /// (`openBreakdown(for:)` below is the one place that does both, and is now the only way to
    /// open the sheet) — the two are logically one piece of state, split only by the file-
    /// boundary constraint above. A plain (not `private(set)`) `var`, same convention as
    /// `captureState`/`confirmDrafts`/`textCapture` above: this codebase keeps state-machine
    /// properties directly test-drivable rather than encapsulated behind a setter method, and
    /// `Tests/` (this task's one other allowed location) relies on exactly that to unit-test the
    /// breakdown state machine without awaiting a real network round trip.
    var breakdownTask: TaskItem?
    /// Monotonic token guarding the async breakdown fetch (`fetchBreakdown`, mirrors
    /// `captureSession`/`textCaptureSession`'s exact shape) — bumped by every `openBreakdown(for:)`
    /// and by `closeBreakdown()`, so a fetch already in flight when the sheet is dismissed (by
    /// Cancel/Edit, Esc, or the system sheet-close control — `TaskBreakdownView`'s `.onDisappear`
    /// calls `closeBreakdown()` on ALL of those paths, since `VolarApp.swift`'s `.sheet(
    /// isPresented:)` binding only flips the bare `Bool` and cannot be taught to call back into
    /// this file) can never land on — or worse, silently populate — a DIFFERENT task's freshly
    /// reopened sheet.
    private var breakdownSession = 0
    /// State machine for the real (cloud-routed) breakdown fetch — `TaskBreakdownView` renders
    /// directly off this instead of ever holding its own copy, same "single source of truth,
    /// View is a pure function of AppState" convention as `confirmDrafts`/`captureState` above.
    /// Plain `var`, same test-drivability reasoning as `breakdownTask` above.
    var breakdownFetchState: BreakdownFetchState = .idle
    /// T034/FR-018: the weekly stale-task triage batch card (`TriageView`, sibling-owned §D).
    /// `VolarApp`'s main-window `.task` gates setting this `true` to once per ISO week (mirrors
    /// `frogLastShown`'s once-per-day pattern) and only when `staleTasks` is non-empty — this flag
    /// itself carries no additional gating so previews/tests can drive it directly.
    var showTriage = false
    var reminderBanner: ReminderBanner? = nil
    /// The task currently shown in the detail panel, by id — `nil` means the panel is closed.
    /// Kept as an id (not a snapshot) so `detailTask` below always reflects live edits/toggles.
    /// Was a `.sheet` gate before the panel-refactor pass (specs/005-cursor-retheme/panel-
    /// refactor.md); the signature and every call site are unchanged, only the presentation is.
    var detailTaskID: UUID?
    /// ⌘K command bar (`Sources/Views/CommandBar.swift`, "Volar Graphite" pass §4.2) — presented as
    /// an overlay over the main window's content in `VolarApp.swift`, not a `.sheet`. Presentation-
    /// only, same shape as `detailTaskID`'s bare-flag convention: `CommandBar` keeps its own local
    /// draft text and reuses the EXISTING `textCaptureInput`/`submitTextCapture()` typed-capture
    /// pipeline (`Sources/Views/TextCapturePanel.swift`'s ⌃⌥T popup uses the same two) to actually
    /// parse/save — this flag never forks that pipeline, it only controls whether the ⌘K overlay
    /// itself is on screen. See `openCommandBar()`/`closeCommandBar()` below.
    var showCommandBar = false

    // MARK: - Switch ("đổi gió") state — read/written by both `Sources/Views/FocusOverlay.swift`'s
    // "Switch" button and `Sources/Views/TodayView.swift`'s hero-card "Switch" button (see the
    // "Switch" MARK further down for the actual behavior). Same "additive, not part of the frozen
    // §4 surface" category as the modal/banner state directly above.

    /// FR-030: task pending the one-time "want to split this up?" invite, or `nil`. Armed by
    /// `maybeOfferBreakdown(taskID:newCount:)` the moment a task's `switchAwayCount` first crosses
    /// `switchBreakdownThreshold`; cleared by `dismissSwitchBreakdownSuggestion()`/
    /// `acceptSwitchBreakdownSuggestion()`. Either way `switchBreakdownOffered` has already
    /// recorded that this task got its one chance, so it can never re-arm for the same id.
    var switchBreakdownSuggestion: TaskItem?

    /// Dashboard-only Switch override (`TodayView`'s hero card): while set to a still-open task's
    /// id, `dashboardActiveTask` shows THAT task instead of the engine's raw `activeTask` pick.
    /// Deliberately ephemeral — never persisted — a relaunch always starts back at the engine's
    /// own pick, same as `activeTask` always has. `FocusOverlay`'s own separate Switch mechanism
    /// (`focusIndex`-based) is completely independent of this and is unaffected.
    private var dashboardSwitchOverrideID: UUID?

    // MARK: - Guided tour (coach-mark walkthrough shown right after onboarding; `TourOverlay`,
    // `TourModel`, `TourAnchor` — `Sources/Views/Tour/*`). Same "additive, not part of the frozen
    // §4 surface" category as the modal/banner state directly above.

    /// True while `TourOverlay` is mounted over the real `TodayView`. `VolarApp.swift`'s main-
    /// window `.task` also reads this as an extra guard on the morning-frog/triage/evening-sweep
    /// sheet gates, so a modal sheet can never stack on top of a running tour.
    var tourActive = false
    /// Index into `TourStop.all` (`TourModel.swift`). `private(set)` — `tourNext()`/`tourBack()`/
    /// `endTour()` below are the only mutators, mirroring `focusIndex`'s own single-writer
    /// convention elsewhere in this file (clamped only through its own dedicated methods).
    private(set) var tourStepIndex = 0
    /// Persisted under `hasSeenTourKey`. The tour auto-starts (`startTourIfNeeded()`) at most once
    /// per install unless the user explicitly re-runs it (`replayTour()`, Settings → "Replay guided
    /// tour").
    private(set) var hasSeenTour: Bool

    // MARK: - Sidebar navigation (2026-07-27) — see the `NavSection`/`UpcomingDayGroup` doc comments
    // above this class for the port note. Same "additive, not part of the frozen §4 surface"
    // category as `tourActive`/`showTriage` above.

    /// Which sidebar section `TodayView`'s main column shows. Today until the user picks otherwise;
    /// deliberately NEVER persisted — reopening the app lands on Today, which is the whole point of
    /// the app (mirrors Windows `TodayViewModel.SelectedSection`'s own doc comment).
    var selectedSection: NavSection = .today

    // MARK: - Collaborators (implementation detail, not part of the frozen §4 surface)

    /// Replaces the v1 `NLParser` direct call (contract "Confirm + materialize" / T025: "Replace
    /// any v1 direct-HeuristicNLParser call with the router"). `IntentRouter` is owned by the
    /// T019 agent (`Sources/Parsing/IntentParsing.swift`, landed) — constructed with its own
    /// default for `foundationModel` (2026-07-28: no more `heuristic:` parameter to default —
    /// that tier was disconnected from the router; see `IntentRouter.init`'s doc comment), wired
    /// here with a real `cloudGate:` (`DefaultCloudParseGate`, bottom of this file) so the
    /// Local↔Cloud choice this file owns
    /// (`parseEnginePreference` / `cloudParseConsent` / `resolveCloudConsent`) reaches the router.
    /// `cloud:` is now wired with `ConfigParseCredentialProvider` (a placeholder credential source):
    /// the Cloud tier is fully connected and user-switchable from Settings, but stays inert
    /// (falls back to on-device) until a parse-proxy base URL + token are configured — "code first,
    /// key later". The real StoreKit paid-JWS + `DeviceCheckProvider.swift` free-token composite
    /// (Phase 8/T051) supersedes that placeholder when it lands.
    private let router: IntentRouter
    private let store: TaskStore?
    /// Injected clock so `activeTask` stays pure/testable instead of reading the wall clock
    /// directly; defaults to the live clock so production behavior is unaffected.
    private let clock: () -> Date

    // MARK: - Phase 3: real service instances (VoicePlayback / AmbientSound / HotkeyManager /
    // SpeechCapture are all `@MainActor` classes with no-arg inits — see `Sources/Speech/*` and
    // `Sources/Audio/AmbientSound.swift`).
    /// Bare type annotation, NOT a declaration-site default (`= VoicePlayback()`) — `voiceChannel`
    /// further down needs to be built from this instance, and Swift's two-phase init rule forbids
    /// reading ANY `self.` stored property (even one with its own default expression) until every
    /// stored property of the class has been assigned. Constructed into a local constant in `init`
    /// instead — see that section's comment for why.
    let voice: VoicePlayback
    let ambientSound = AmbientSound()
    // iOS has no global hotkey concept (no Carbon Event Manager, no menu bar) — `HotkeyManager`
    // itself lives only in `Volar/Sources/Speech/HotkeyManager.swift` (macOS-only source tree, not
    // copied into `Shared/`), so this property must not exist on iOS at all.
    #if os(macOS)
    let hotkey = HotkeyManager()
    #endif
    let speech = SpeechCapture()
    /// Free on-device tier (backlog freemium split). Apple (`speech`) remains the default engine
    /// and the fallback whenever WhisperKit isn't supported/ready.
    let whisper = WhisperKitEngine()
    /// Paid cloud tier.
    let groq = GroqEngine()
    /// Read-only EventKit access (feature: guided-tour "Enable Calendar" step,
    /// `Sources/Views/Tour/TourOverlay.swift`'s final stop). Owned/implemented in
    /// `Sources/Integrations/CalendarAccess.swift` (sibling-owned) — bare type annotation rather
    /// than a declaration-site default (`= CalendarAccess()`) because `calendarSync` below is built
    /// FROM this instance, and a stored property's own default-value expression can't reference a
    /// sibling instance property. Constructed into a local constant in `init` instead (same reason
    /// as `voice` above) so `SettingsView` and `TourOverlay` are still guaranteed to observe the
    /// exact same access/status instance rather than two independently drifting ones.
    let calendarAccess: CalendarAccess
    /// One-way (Volar → Calendar) task mirroring into an app-created "Volar" calendar. Owned/
    /// implemented in `Sources/Integrations/CalendarSync.swift` (sibling-owned) — shares this
    /// exact `calendarAccess` instance (constructed on the line directly above) rather than each
    /// holding its own, so there is exactly one source of truth for EventKit authorization status
    /// across the app. See `syncCalendarMirror()`/`setCalendarMirror(_:)`/`enableCalendarAccess()`
    /// below for how this gets driven — `reconcile(tasks:)` itself is never called from a property
    /// observer or timer, only from explicit choke points after a task-list mutation.
    let calendarSync: CalendarSync

    // MARK: - Account & Entitlements (specs/002-workflow-command-center/contracts/account-auth.md)
    //
    // Every property below is a `@MainActor`-observable MIRROR of `AccountService.shared`/
    // `Entitlements.shared` (both plain, non-`@MainActor` `actor`s so their networking stays off
    // the main actor per this feature's constraints) — refreshed by the methods further down
    // right after each one awaits its actor. `SettingsView`'s Account tab reads these directly
    // instead of awaiting an actor itself, matching how every other `SettingsView` tab only ever
    // touches plain `AppState` properties/methods.

    var accountEmail: String?
    var accountTier: AccountTier = .free
    var subscriptionStatus: SubscriptionStatus?
    /// Backlog "1 free month of Pro" promo codes: set by a SUCCESSFUL `redeemPromoCode(_:)` so
    /// `SettingsView` can show a one-line "Pro until <date>" confirmation, mirroring how
    /// `accountError` already gives that same method's FAILURE path somewhere to land instead of
    /// inventing a parallel notification/toast mechanism. `nil` = nothing to confirm (fresh
    /// session, or the last redeem attempt failed/hasn't happened) — deliberately never cleared
    /// automatically on the NEXT unrelated account action (matches `accountEmail`/`accountTier`'s
    /// own "stays until explicitly replaced" convention elsewhere in this section), only ever
    /// overwritten by another successful redeem.
    var lastRedeemedUntil: Date?
    /// Inline error text for the Account tab (Apple sign-in / OTP / purchase / delete failures).
    /// Deliberately separate from any other error surface in this file — account actions are
    /// user-initiated from Settings, not part of the capture pipeline's error states.
    var accountError: String?
    /// True while an account/entitlement network action is in flight — drives a disabled/spinner
    /// state on the Account tab's buttons so a slow network can't be raced into a double sign-in/
    /// double-purchase.
    var accountBusy = false
    /// Hydrated by `startAccountLifecycle()`/`refreshAccountState()` so `SettingsView` can show
    /// `product.displayPrice` (never a hardcoded "$6.99" — wrong in every non-US storefront).
    var monthlyProduct: Product?
    var yearlyProduct: Product?

    // MARK: - Sync (008-sync, client-contract.md §0 group C — mirrors `SyncAccountClient`
    // (`Shared/Sync/SyncAccountState.swift`) the same way the properties above mirror
    // `AccountService`/`Entitlements`: real state lives in a plain, non-`@MainActor` actor, this
    // `@Observable` type mirrors just what the views need. `SyncState`/`SyncReject`/`SyncFailure`
    // are pinned VERBATIM by group B's `Shared/Sync/SyncContracts.swift` — never redefined here.

    /// Server truth about the account-level toggle. `.unknown` (all-false/empty, `isPro: false`)
    /// until the first `refreshSyncState()` completes. Do NOT render any status line off this value
    /// alone before checking `syncStateLoaded` below — `.unknown.isPro == false` would tell a real
    /// Pro user "Sync is a Pro feature." for the brief window before the first fetch resolves, which
    /// is exactly the false statement about their own account §8.2 exists to prevent (Opus review,
    /// 2026-08-10: "im lặng tốt hơn sai").
    var syncState: SyncState = .unknown
    /// True once the first `refreshSyncState()` call has completed — success OR failure, set in a
    /// `defer` so a failed first fetch still stops the UI from guessing. Both Settings screens MUST
    /// gate `syncState`-derived status text on this flag: `false` renders NOTHING (no card content,
    /// or a neutral "Checking…" placeholder), never a state guessed from `.unknown`'s all-false
    /// defaults. This is the fix for the "Pro required" flash a real Pro user could otherwise see
    /// for one frame at launch.
    var syncStateLoaded = false
    /// True while a sync-account action (`refreshSyncState`/`setSyncEnabled`/`purgeSyncData`) is in
    /// flight — same "disable the button, don't let a slow network race into a double action" role
    /// `accountBusy` plays above, kept as its OWN flag rather than reusing `accountBusy` because a
    /// sync action and a purchase/sign-in action are unrelated and must be able to spin
    /// independently (e.g. `SyncEnableSheet`'s CTA must not appear disabled just because an
    /// unrelated `redeemPromoCode` call happens to be in flight).
    var syncBusy = false
    /// Text for the SMALL diagnostics line only, never a banner — and deliberately NEVER set for
    /// `.proRequired`/`.disabled`/`.offline` (see `syncFailureMessage(_:)` below). Those three read
    /// straight off `syncState`/silence instead, per client-contract.md §1 rule 2: no enum, no
    /// string, no code path may collapse "needs Pro" / "toggle is off" / "no network" into one
    /// generic "sync error" — that's exactly what trains a user to go flip a working toggle on
    /// another device and debug wifi that was never broken.
    var syncError: String?
    /// `sync_rejects`, most recent first — populated by `loadSyncRejects()`, read by
    /// `SyncRejectsView`. Empty (not `nil`) when nothing has ever been rejected, matching that
    /// view's own empty-state handling.
    var syncRejects: [SyncReject] = []
    /// T036 (phase5-contract.md §C, contract A `VoiceDone`, `Sources/Speech/VoiceDone.swift`,
    /// sibling-owned — landed). Pure/stateless matcher; constructed once here like every other
    /// collaborator on this line.
    private let voiceDone = VoiceDone()
    /// The `SpeechEngine` actually driving the in-flight (or most recent) capture, so
    /// `stopCapture`/`cancelCapture`/`confirmSave` can address whichever engine `startCapture`
    /// routed to instead of hardcoding `speech`.
    private var runningEngine: SpeechEngine?

    // MARK: - Phase 4: reminder subsystem (contract A/B, sibling-owned types) — constructed once
    // here at init so the whole app shares one instance. `store` may be `nil` (container-init
    // failure degrades gracefully — see `VolarApp.init`'s doc comment), so `scheduler` is optional
    // too rather than requiring a non-optional `TaskStore` the app doesn't always have.
    // `voiceChannel`/`reminderGate` are unconditional (they don't need a store) so Settings/other
    // call sites can always reach them even in the no-store fallback.
    let voiceChannel: VoiceReminderChannel
    let reminderGate: ReminderContextGate
    let scheduler: ReminderScheduler?

    /// Route `volar://capture` (`AppLinkHandler`) — `nil` trong nhánh no-store. Tính năng
    /// delegation (route `ai-done`, `DelegationTracker`, `ClaudeCodeConnector`) đã bỏ 2026-08-22,
    /// nhưng app-link vẫn sống vì `volar://capture` không dính gì tới nó.
    let appLinkHandler: AppLinkHandler?

    /// FIX B: owns the focus-session 1s countdown — moved here from `FocusOverlay`'s own
    /// `Timer.publish`, which stopped firing the instant the overlay window closed (the menu bar's
    /// `focusSecondsLeft` readout froze and the session never auto-ended). Mirrors
    /// một `Timer` sống ở `AppState` (không phải ở view) so this survives
    /// the same way regardless of which window/view is on screen. See `startFocus()`/`endFocus()`/
    /// `focusTick()`.
    private var focusTimer: Timer?

    // MARK: - Ambient background persistence (UserDefaults; Settings → Appearance)

    private static let ambientKey = "volar.ambient"
    private static let customImageKey = "volar.customImageURL"
    private static let allowServerRecognitionKey = "volar.allowServerRecognition"
    private static let recognitionLocaleKey = "volar.recognitionLocale"
    /// Sentinel value for `recognitionLocaleID` meaning "no fixed language — let each engine
    /// auto-detect": `SpeechCapture`/`WhisperKit` get `Locale.current` (the system language),
    /// `GroqEngine` gets a nil `languageCode` so `GroqTranscriptionClient` omits the `language`
    /// field entirely (Groq's own auto-detect, best for vi↔en code-switching). It's a magic string
    /// rather than making `recognitionLocaleID` optional because that property is persisted
    /// directly and used as a SwiftUI `Picker` `tag` (`SettingsView.swift`). `static`/internal (not
    /// `private`) so `SettingsView` can tag its "Automatic (multilingual)" picker row with the same
    /// constant instead of duplicating the string.
    static let autoRecognitionLocaleID = "auto"
    private static let speechEngineKey = "volar.speechEngine"

    /// Resolves the persisted `recognitionLocaleID` to a concrete `Locale` for `SpeechCapture`/
    /// `WhisperKit`: `.current` (system locale) for the `autoRecognitionLocaleID` sentinel, the
    /// literal locale otherwise (unchanged behavior for an explicit picker choice). `static` (not
    /// an instance method) so it's safe to call from `init` before `self` is fully initialized.
    private static func appleRecognitionLocale(for recognitionLocaleID: String) -> Locale {
        recognitionLocaleID == autoRecognitionLocaleID ? Locale.current : Locale(identifier: recognitionLocaleID)
    }

    /// Resolves the persisted `recognitionLocaleID` to the ISO-639-1 code `GroqEngine`/
    /// `GroqTranscriptionClient` expect in their `language` field (e.g. "vi-VN" -> "vi"). Returns
    /// `nil` for the `autoRecognitionLocaleID` sentinel (Groq auto-detects when no `language` field
    /// is sent) or if the locale identifier doesn't resolve to a known language code.
    private static func groqLanguageCode(for recognitionLocaleID: String) -> String? {
        guard recognitionLocaleID != autoRecognitionLocaleID else { return nil }
        return Locale(identifier: recognitionLocaleID).language.languageCode?.identifier
    }

    /// One-time cloud-parse consent. `fileprivate` (not `private`) so `DefaultCloudParseGate`
    /// (bottom of this file) can read the same key from `isOptedIn()`. `nonisolated` because a
    /// `static let` declared inside a `@MainActor` type inherits that isolation (only statics at
    /// global/file scope are implicitly `nonisolated`), and `DefaultCloudParseGate` is deliberately
    /// NOT main-actor-isolated — without this, `isOptedIn()` fails to compile with "main
    /// actor-isolated static property ... cannot be accessed from outside of the actor".
    fileprivate nonisolated static let cloudParseConsentKey = "volar.cloudParseConsent"
    /// Phase 4 (T033): `static`/internal, NOT `private` — this is the exact key
    /// `ReminderScheduler`/`VoiceReminderChannel` (contract A/B, `Sources/Reminders/**`,
    /// sibling-owned) are expected to read directly, since their frozen inits take no policy
    /// parameter. Raw values match `VoiceDeliveryMode`'s cases exactly.
    static let voiceDeliveryModeKey = "volar.voiceDeliveryMode"
    /// Same seam as above, for the global default `ReminderPolicy` (used when a task has no
    /// `reminderOverride`) — JSON-encoded `ReminderPolicy` (`Recurrence.swift`).
    static let globalReminderPolicyKey = "volar.globalReminderPolicy"
    /// Same seam as `globalReminderPolicyKey` above, one level down (2026-07-29): `internal`, NOT
    /// `private` — `IntentRouter.currentDefaultDurationMinutes()` (`Sources/Parsing/
    /// IntentParsing.swift`) reads this exact key directly (no frozen init parameter to thread a
    /// value through, same reasoning as `voiceDeliveryModeKey`'s doc comment above). Referenced BY
    /// NAME from that file (`AppState.defaultTaskDurationMinutesKey`) rather than a duplicated
    /// string literal, so the two sides can never drift apart — see `IntentParsing.swift` for the
    /// read side. `nonisolated` for the exact reason `cloudParseConsentKey` above is: a `static let`
    /// inside a `@MainActor` type inherits that isolation, and the reader
    /// (`IntentRouter.currentDefaultDurationMinutes()`) is deliberately `nonisolated` so the
    /// off-main `CloudParser`/`FoundationModelParser` side can reach it — without this the reader
    /// fails to compile with "main actor-isolated static property ... cannot be referenced from a
    /// nonisolated context". Unlike `voiceDeliveryModeKey`/`globalReminderPolicyKey` right above,
    /// whose only sibling reader (`ReminderScheduler`) is itself `@MainActor` and so needs nothing.
    nonisolated static let defaultTaskDurationMinutesKey = "volar.defaultTaskDurationMinutes"
    /// FR-018 weekly triage "keep" bookkeeping — see `triageKeptAt`'s doc comment. Local to this
    /// file; no sibling reads this one.
    private static let triageKeptAtKey = "volar.triageKeptAt"
    /// FR-030 "already offered the breakdown invite" bookkeeping — see `switchBreakdownOffered`'s
    /// doc comment. Local to this file; no sibling reads this one.
    private static let switchBreakdownOfferedKey = "volar.switchBreakdownOffered"
    /// FIX 4: `accent`/`density` used to only ever be assigned from this `init`'s parameters —
    /// there was no read-back from `UserDefaults` here (unlike every other Settings → Appearance
    /// control: `ambientKey`/`customImageKey` right above both get one) and no write anywhere
    /// either, so a real launch (`VolarApp.swift` calls `AppState(store:)` with neither parameter
    /// supplied) silently reset both to their compiled-in defaults (`.indigo`/`.comfy`) every
    /// time, discarding whatever `SettingsView` had set last session.
    private static let accentKey = "volar.accent"
    /// `Density` (Theme.swift) is NOT `RawRepresentable`/`String`-backed like `VolarAccent` is, so
    /// there's no `.rawValue` to persist directly. Rather than invent a new ad hoc encoding, this
    /// reuses the EXACT `"cozy"`/`"comfy"`/`"roomy"` string mapping `SettingsView.densityID(_:)`/
    /// `density(fromID:)` already define for its own `Segmented` binding (`SettingsView.swift`) —
    /// same values, same default-to-`.comfy` fallback — so this is the established convention,
    /// not a new one.
    private static let densityKey = "volar.density"
    /// specs/009-light-mode-list-v2/design.md §7. Grepped every `UserDefaults` key literal in this
    /// file before picking this string (self-review (5) of this task's brief) — `"volar.appearance"`
    /// was unclaimed.
    private static let appearanceKey = "volar.appearance"
    /// specs/010-calendar-and-hard-deadlines/design.md §2.5. Grepped every `UserDefaults` key
    /// literal in this file before picking this string (same self-review step 009's
    /// `appearanceKey` comment records) — `"volar.calendarRead"` was unclaimed.
    private static let calendarReadKey = "volar.calendarRead"
    /// Guided-tour "seen" flag (`Sources/Views/Tour/*`). `V1` suffix mirrors `VolarApp.swift`'s own
    /// `hasOnboardedV1` `@AppStorage` key versioning convention, so a future tour redesign can force
    /// everyone through it again just by bumping the suffix, without touching this file's read/write
    /// call sites (`init` below / `endTour()` further down).
    private static let hasSeenTourKey = "volar.hasSeenTourV1"
    /// 006-cues-and-waiting (design.md §2 Việc B) / backlog.md "(A) RE-ENTRY": last moment the app
    /// genuinely became active — an APP-scoped key, deliberately NOT `lastTouchedAt` on `TaskItem`
    /// (the re-entry/decay backlog item's own PER-TASK staleness clock, a different concern the
    /// task brief for this feature explicitly says not to conflate). Named to match exactly what
    /// backlog.md's "(A) RE-ENTRY" entry already proposes for its own future use ("khoá UserDefaults
    /// `volar.lastActiveAt`"), so whichever feature lands second reads/writes the SAME key instead
    /// of inventing a duplicate. Read+written only by `recordAppBecameActive(now:)` below — see that
    /// method's own doc comment for the read-before-write ordering this key's correctness depends on.
    static let lastActiveAtKey = "volar.lastActiveAt"

    init(
        store: TaskStore? = nil,
        tasks: [TaskItem]? = nil,
        accent: VolarAccent = .indigo,
        density: Density = .comfy,
        glass: GlassLevel = .standard,
        ambient: AmbientMode = .none,
        customImageURL: URL? = nil,
        voiceFeedback: Bool = false,
        router: IntentRouter = IntentRouter(
            cloud: CloudParser(credentials: ConfigParseCredentialProvider()),
            cloudGate: DefaultCloudParseGate()
        ),
        clock: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.tasks = tasks ?? store?.loadOrSeed() ?? []
        self.accent = accent
        self.density = density
        self.glass = glass
        self.ambient = ambient
        self.customImageURL = customImageURL
        // Override from persisted user choice, if any — falls back to the caller-supplied
        // defaults above (e.g. previews/tests that construct AppState directly still work).
        if let raw = UserDefaults.standard.string(forKey: Self.ambientKey), let m = AmbientMode(rawValue: raw) {
            self.ambient = m
        }
        if let p = UserDefaults.standard.string(forKey: Self.customImageKey) {
            self.customImageURL = URL(fileURLWithPath: p)
        }
        // FIX 4: same override convention as `ambient`/`customImageURL` immediately above —
        // persisted choice wins, caller-supplied parameter is only the previews/tests fallback.
        if let raw = UserDefaults.standard.string(forKey: Self.accentKey), let a = VolarAccent(rawValue: raw) {
            self.accent = a
        }
        if let raw = UserDefaults.standard.string(forKey: Self.densityKey),
           let d = Self.densityFromPersistedID(raw) {
            self.density = d
        }
        self.allowServerRecognition = UserDefaults.standard.bool(forKey: Self.allowServerRecognitionKey)
        // FIX (backlog 2026-07-26): default was hardcoded "en-US", silently ignoring the user's
        // system language on first launch. "auto" lets both engines auto-detect until the user
        // picks a specific locale in Settings (see `autoRecognitionLocaleID`'s doc comment).
        self.recognitionLocaleID = UserDefaults.standard.string(forKey: Self.recognitionLocaleKey) ?? Self.autoRecognitionLocaleID
        // Cloud-first default (product decision, 2026-07-27): a NEVER-PERSISTED user gets `.groq`
        // now, not `.appleOnDevice` — the server side (Groq speech, free tier at 20/day) is live,
        // so defaulting to on-device meant it went unused. This ONLY changes the fallback on the
        // right of `??`; `SpeechEngineChoice(rawValue:)` still parses whatever string is ACTUALLY
        // persisted first, so a user who already picked an engine (in Settings, `setSpeechEngine`
        // below) keeps exactly that choice on every future launch — this line only fires for a key
        // that was never written. The existing degradation ladder is untouched: `selectedEngine`
        // (below) still falls back to `speech` (Apple on-device) whenever Groq isn't actually usable
        // — not configured (no signed-in session: `GroqEngine.isConfigured` requires
        // `KeychainStore.loadSession() != nil`, and ONLY that as of 2026-07-27 — the `&&
        // Entitlements.cachedIsPro` half was removed when cloud speech opened to the free tier at
        // 20/day, see `GroqTranscriptionClient.swift`) or `groqDegradedThisSession` (a mid-run
        // 403/429). So a signed-out user with this
        // new default still transcribes 100% on-device on every capture, exactly as before — the
        // default only changes WHICH engine gets attempted first once an account is configured.
        self.speechEngineChoice = SpeechEngineChoice(rawValue: UserDefaults.standard.string(forKey: Self.speechEngineKey) ?? "") ?? .groq
        // specs/009-light-mode-list-v2/design.md §7: no init parameter (unlike `accent`/`density`
        // above) — nothing in this codebase constructs an `AppState` expecting a specific
        // appearance, so straight-from-`UserDefaults`-with-a-default is enough, same shape as
        // `speechEngineChoice` right above.
        self.appearance = AppearancePreference(rawValue: UserDefaults.standard.string(forKey: Self.appearanceKey) ?? "") ?? .system
        // §2.5: defaults `false` for an unset key, same as `allowServerRecognition` above — an
        // upgrading user who never saw this toggle gets the private default, not an opt-in one.
        self.calendarReadEnabled = UserDefaults.standard.bool(forKey: Self.calendarReadKey)
        self.cloudParseConsent = UserDefaults.standard.object(forKey: Self.cloudParseConsentKey) as? Bool
        self.voiceDeliveryMode = VoiceDeliveryMode(
            rawValue: UserDefaults.standard.string(forKey: Self.voiceDeliveryModeKey) ?? ""
        ) ?? .visualPlusVoice
        if let policyData = UserDefaults.standard.data(forKey: Self.globalReminderPolicyKey),
           let decodedPolicy = try? JSONDecoder().decode(ReminderPolicy.self, from: policyData) {
            self.globalReminderPolicy = decodedPolicy
        } else {
            self.globalReminderPolicy = .defaultPolicy
        }
        // `UserDefaults.integer(forKey:)` returns `0` for a key that has never been set — that is
        // NOT the same claim as "the user chose 0 minutes" (0 isn't even in the valid 5...480
        // range), so a missing key and a corrupted/out-of-range stored value both fall back to the
        // same 30-minute default rather than persisting/using 0.
        let storedDuration = UserDefaults.standard.integer(forKey: Self.defaultTaskDurationMinutesKey)
        self.defaultTaskDurationMinutes = (5...480).contains(storedDuration) ? storedDuration : 30
        if let raw = UserDefaults.standard.dictionary(forKey: Self.triageKeptAtKey) as? [String: Double] {
            self.triageKeptAt = raw.reduce(into: [:]) { partial, pair in
                guard let id = UUID(uuidString: pair.key) else { return }
                partial[id] = Date(timeIntervalSince1970: pair.value)
            }
        } else {
            self.triageKeptAt = [:]
        }
        // FR-030 "already offered the breakdown invite" set — same string-array `UserDefaults`
        // shape `hasSeenTourKey`-adjacent persisted flags use elsewhere in this file, just a
        // collection instead of a single `Bool`. Absent/corrupt storage degrades to "never offered
        // anyone" (empty set), never to a crash.
        if let raw = UserDefaults.standard.array(forKey: Self.switchBreakdownOfferedKey) as? [String] {
            self.switchBreakdownOffered = Set(raw.compactMap { UUID(uuidString: $0) })
        } else {
            self.switchBreakdownOffered = []
        }
        // Guided tour: read-only override, same shape as every other persisted-choice read above —
        // absent means "never run before" (the honest default for a fresh install), so `Bool` here
        // needs no fallback expression the way `speechEngineChoice`/`voiceDeliveryMode` do.
        self.hasSeenTour = UserDefaults.standard.bool(forKey: Self.hasSeenTourKey)
        self.voiceFeedback = voiceFeedback
        self.captureState = .idle
        self.liveTranscript = ""
        self.confirmDrafts = []
        self.confirmUpdateDrafts = []
        self.focusActive = false
        self.focusPaused = false
        self.focusSecondsLeft = 25 * 60
        self.focusIndex = 0
        self.router = router
        self.clock = clock
        // FIX 6: `calendarSync` takes `calendarAccess` as a constructor argument, so — same
        // reasoning as the `voice`/`voiceChannel`/`reminderGate` locals a few lines below — it
        // must be assigned here inside `init`'s body rather than at its own declaration site
        // (`let calendarSync = CalendarSync(access: calendarAccess)` right next to
        // `calendarAccess`'s declaration would not compile: a stored property's own default-value
        // expression cannot reference a sibling instance property, since `self` isn't fully
        // available yet at that point).
        //
        // 2026-07-27 FIX: this used to read `self.calendarAccess` directly here, on the theory that
        // a stored property with its own declaration-site default expression is "already
        // initialized" and therefore safe to read early. That's wrong — Swift's two-phase init
        // rule (the compiler's "safety check 4") forbids reading ANY `self.` stored property, no
        // matter how it's initialized, until EVERY stored property of the class has been assigned;
        // at this point `voiceChannel`/`reminderGate`/`scheduler`/`appLinkHandler`
        // (all assigned further down this same init) are still unset, so the read was illegal and
        // would fail to compile the first time this file was ever built on a Mac (it never had
        // been — see backlog.md). Fixed by building `calendarAccess` into a LOCAL constant first
        // and passing the LOCAL (never `self.calendarAccess`) into `CalendarSync`.
        let calendarAccess = CalendarAccess()
        self.calendarAccess = calendarAccess
        self.calendarSync = CalendarSync(access: calendarAccess)
        // Phase 4 (T033): construct the reminder subsystem once `store` (the init parameter,
        // already mirrored into `self.store` at the very top of this init) is settled.
        //
        // 2026-07-27 FIX: same bug and same fix as `calendarAccess` immediately above — `voice`,
        // `voiceChannel`, and `reminderGate` are all built into LOCAL constants and passed as
        // locals (never as `self.voice` / `self.voiceChannel` / `self.reminderGate`) into whatever
        // needs them, because at this point in `init` the class's stored properties are still only
        // partially assigned (`appLinkHandler` comes later), so no `self.` property
        // read is legal yet regardless of whether that particular property already holds a value.
        let voice = VoicePlayback()
        self.voice = voice
        let voiceChannel = VoiceReminderChannel(playback: voice)
        self.voiceChannel = voiceChannel
        let reminderGate = ReminderContextGate()
        self.reminderGate = reminderGate
        if let store {
            let realScheduler = ReminderScheduler(store: store, voice: voiceChannel, gate: reminderGate)
            self.scheduler = realScheduler
        } else {
            self.scheduler = nil
        }
        // `volar://capture` cần một `TaskStore` để đẩy text vào; không có store thì không có
        // handler, cùng quy ước dựng-có-điều-kiện như `scheduler` ngay trên.
        self.appLinkHandler = store.map { AppLinkHandler(store: $0) }
        // M-1 (constitution I): wire the one cheaply-detectable, no-extra-entitlement signal this
        // file has direct access to — our own `AmbientSound` instance's public `isPlaying` flag —
        // so a voice reminder never talks over ambient sound already playing. Assigned HERE, after
        // every stored property above is initialized: this closure captures `self`, and Swift
        // forbids capturing `self` in a closure until the instance is fully initialized (doing it
        // earlier produced "variable 'self.scheduler' used before being initialized"). Mic
        // contention is already wired unconditionally inside `ReminderContextGate` itself
        // (`AVCaptureDevice.isInUseByAnotherApplication`); DND/screen-share have no public,
        // unprivileged API on macOS (see `ReminderContextGate.swift`'s own doc comment) and are
        // deliberately left non-suppressing rather than failing the whole gate open silently.
        // // UNVERIFIED: this only covers OUR OWN ambient playback, not other apps' audio in
        // general (no public system-wide "is any app playing audio" API without an entitlement)
        // — calendar-busy (P3) + call/mic remain the real guards for that case.
        self.reminderGate.isOtherAudioPlaying = { [weak self] in self?.ambientSound.isPlaying ?? false }
        // `ReminderContextGate.swift`'s own header comment names this same "nil means not wired
        // yet" extension point ("mic capture belongs to Sources/Speech/SpeechCapture.swift, owned
        // elsewhere") — `captureState == .recording` IS that local-mic-capture signal (it's driven
        // by this same speech-capture flow), so it's wired here alongside `isOtherAudioPlaying`
        // rather than left open.
        self.reminderGate.isLocalMicCaptureActive = { [weak self] in self?.captureState == .recording }
        // ReminderScheduler.swift's own doc comment on `isVolarCapturing` names this exact missing
        // line: a full-screen takeover must never fight Volar's own capture UI. Same "assign here,
        // after every stored property above is initialized" placement and `[weak self]` shape as
        // `reminderGate.isOtherAudioPlaying` immediately above — `scheduler` is optional (`nil`
        // without a store, per its own doc comment further up), so this is a no-op in that case.
        self.scheduler?.isVolarCapturing = { [weak self] in self?.captureState == .recording }
        speech.setLocale(Self.appleRecognitionLocale(for: self.recognitionLocaleID))
        groq.languageCode = Self.groqLanguageCode(for: self.recognitionLocaleID)
        // CAPTURE SEAM (AppLinkHandler.swift's own file header): wire `volar://capture?text=...`
        // into the SAME confirm-card-gated pipeline every other capture uses — never a bypass.
        // Assigned last (after every stored property above is set) since the closure captures
        // `self` and calls an instance method (`proceedToCapture`). `source` (FR-040's optional
        // origin reference) is folded into the transcript itself rather than a separate `notes`
        // field — `proceedToCapture`'s only parameter is the transcript, and the parser's own
        // `ParsedTask.notes` is what actually ends up in `TaskItem.notes`/`sourceTranscript`, so
        // this is the closest available seam to "stored in notes" without widening
        // `proceedToCapture`'s frozen-adjacent signature. // UNVERIFIED
        appLinkHandler?.onCapture = { [weak self] text, source in
            guard let self else { return }
            let transcript = source.map { "\(text) (via \($0))" } ?? text
            self.proceedToCapture(transcript: transcript)
        }
        // Account & Entitlements launch-time hydration — see that section below for what this
        // kicks off. Called last, same reasoning as `appLinkHandler?.onCapture` immediately above:
        // every stored property is settled by this point, and this call captures `self`.
        startAccountLifecycle()

        // 008-sync (client-contract.md §8): the FIRST of AppState's exactly-two direct touches of
        // `SyncEngine` (group B) — attach the real `TaskStore` once, right where it's created, so
        // `SyncEngine` has a `SyncTaskStoring` to read/write against for the rest of the app's life.
        // No-op in the no-store fallback (previews/tests), same guard every store-backed feature in
        // this init already uses. The second touch, `requestSync(reason: .localEdit)`, lives in
        // `notifySyncOfLocalEdit()` (Account & Entitlements actions section) and fires from
        // `syncCalendarMirror()`, not from here.
        if let store {
            SyncEngine.shared.attach(store: store)
        }
        refreshSyncState()

        // 006-cues-and-waiting (design.md §2 Việc B): registered ONCE here, in `init`, rather than
        // `activateServices()` — that method is deliberately called TWICE (main window's `.task` +
        // `AppDelegate.applicationDidFinishLaunching`, both documented idempotent for everything
        // currently inside it). A `NotificationCenter` observer has no such idempotency: registering
        // it there would attach a SECOND handler on the second call, so every real activation would
        // fire `recordAppBecameActive` twice — two handlers racing to read the same "previous"
        // `lastActiveAt` before either writes `now`, silently breaking that method's own
        // read-before-write contract. `init` runs exactly once per `AppState` instance, and there is
        // exactly one instance for the app's lifetime (`VolarApp.init()`'s own doc comment), so this
        // is the one place a single registration is guaranteed. `@Sendable` + explicit
        // `Task { @MainActor in ... }` hop for the same reason `AppDelegate`'s own notification
        // closures need it (`VolarApp.swift`'s `requestAuthorization`/wake-observer comments): a
        // MainActor-inferred closure literal invoked by a system API that doesn't itself run on
        // `@MainActor` traps at runtime under Swift 6 isolation checking — `queue: .main` here makes
        // that moot in practice (the callback DOES land on main), but the hop costs nothing and keeps
        // this immune to that gotcha regardless.
        // Only the notification's NAME is platform-specific — `UIApplication`'s is the exact
        // semantic analogue of `NSApplication`'s, same delivery, same meaning. Guarding just the
        // name (rather than the whole registration) keeps the observer body and the idempotency
        // reasoning above single-sourced; duplicating the registration per platform would mean
        // two copies of that argument drifting apart. watchOS would need `WKApplication`'s
        // equivalent here — deliberately not written until the watch target exists (Phase 3), so
        // that it fails loudly at compile time rather than silently observing nothing.
        #if os(macOS)
        let didBecomeActiveName = NSApplication.didBecomeActiveNotification
        #elseif os(iOS)
        let didBecomeActiveName = UIApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.addObserver(
            forName: didBecomeActiveName, object: nil, queue: .main
        ) { @Sendable [weak self] _ in
            _Concurrency.Task { @MainActor in
                self?.recordAppBecameActive()
            }
        }
    }

    // MARK: - Account & Entitlements actions
    //
    // Every method below follows the same shape: flip `accountBusy`, run one `_Concurrency.Task`
    // (qualified because `import VolarCore` shadows `Swift.Task` in this file — see the capture
    // flow's own comment on this a few hundred lines down), await the actor call, mirror the
    // result into the `@Observable` properties above, and clear `accountBusy` via `defer`.

    /// Launch-time hydration: start-once `Transaction.updates` listener (renewals/refunds/Ask-to-
    /// Buy), load the two products for the Account tab's upgrade rows, re-link every currently-
    /// active StoreKit entitlement (contract §8 — no server-side App Store Notifications yet, so
    /// this re-link-at-launch IS the renewal-propagation mechanism), then hydrate the mirrored
    /// state below. Called once from the end of `init` above.
    func startAccountLifecycle() {
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            await Entitlements.shared.startTransactionUpdatesListener()
            await Entitlements.shared.loadProducts()
            self.monthlyProduct = await Entitlements.shared.product(.monthly)
            self.yearlyProduct = await Entitlements.shared.product(.yearly)
            await Entitlements.shared.relinkCurrentEntitlements()
            self.refreshAccountState()
        }
    }

    /// Re-mirrors `AccountService`/`Entitlements`'s current state into this `@Observable` — called
    /// after every sign-in/verify/purchase/restore action below, and at launch.
    func refreshAccountState() {
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            self.accountEmail = await AccountService.shared.currentEmail
            let status = await Entitlements.shared.refreshStatus()
            self.subscriptionStatus = status
            self.accountTier = status?.tier ?? (Entitlements.cachedIsPro ? .pro : .free)
        }
    }

    func sendEmailOTP(email: String) {
        accountBusy = true
        accountError = nil
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.accountBusy = false }
            do {
                try await AccountService.shared.sendEmailOTP(email: email)
            } catch {
                self.accountError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    func verifyEmailOTP(email: String, code: String) {
        accountBusy = true
        accountError = nil
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.accountBusy = false }
            do {
                let user = try await AccountService.shared.verifyEmailOTP(email: email, code: code)
                self.accountEmail = user.email
                await Entitlements.shared.relinkCurrentEntitlements()
                self.refreshAccountState()
            } catch {
                self.accountError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    func signOutAccount() {
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            await AccountService.shared.signOut()
            // Must pair with the line above: `AccountService.signOut()` only clears the SESSION.
            // The tier snapshot lives in `Entitlements` (UserDefaults), and leaving it behind
            // makes `Entitlements.cachedIsPro` report Pro for a signed-out user at next launch.
            await Entitlements.shared.clearEntitlementCache()
            self.accountEmail = nil
            self.accountTier = .free
            self.subscriptionStatus = nil
            self.accountError = nil
        }
    }

    /// Contract §3 `delete-account` — Apple Guideline 5.1.1(v). `SettingsView` is responsible for
    /// the confirmation step before calling this; by the time this runs, deletion is final.
    func deleteAccount() {
        accountBusy = true
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.accountBusy = false }
            do {
                try await AccountService.shared.deleteAccount()
                // Same pairing as `signOutAccount()` above — the account is gone server-side, so
                // the cached Pro snapshot must go with it.
                await Entitlements.shared.clearEntitlementCache()
                self.accountEmail = nil
                self.accountTier = .free
                self.subscriptionStatus = nil
                self.accountError = nil
            } catch {
                self.accountError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    func purchase(_ product: VolarProduct) {
        accountBusy = true
        accountError = nil
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.accountBusy = false }
            do {
                _ = try await Entitlements.shared.purchase(product)
                self.refreshAccountState()
            } catch {
                self.accountError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    func restorePurchases() {
        accountBusy = true
        accountError = nil
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.accountBusy = false }
            do {
                try await Entitlements.shared.restorePurchases()
                self.refreshAccountState()
            } catch {
                self.accountError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    /// Backlog "1 free month of Pro" promo codes. Same shape as every other method in this
    /// section — `accountBusy` flip, one `_Concurrency.Task`, `defer` clears the busy flag, result
    /// mirrored into `@Observable` state, failure into `accountError`. `code` is passed straight
    /// through to `AccountService.redeemPromoCode` UNTOUCHED (no trimming/uppercasing here) — that
    /// method owns the ONE normalization step for the whole client (see its doc comment); this
    /// method only trims to decide whether the field is blank, which is a UI no-op guard, not a
    /// second normalization site feeding the network request.
    func redeemPromoCode(_ code: String) {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        accountBusy = true
        accountError = nil
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.accountBusy = false }
            do {
                let result = try await AccountService.shared.redeemPromoCode(code)
                // Source of truth stays the SERVER: never hand-set `accountTier = .pro` (or
                // anything else) from `result` directly — `refreshAccountState()` re-reads tier/
                // quota from `subscription/status` exactly like every other successful account
                // action above does, so a local guess about what was just granted can never drift
                // from what the account actually has.
                self.refreshAccountState()
                // `lastRedeemedUntil` is purely a display convenience for the confirmation banner —
                // reuses the SAME ISO8601-with-fractional-seconds fallback `ParsedTaskValidation`
                // already defines (`Sources/Parsing/IntentParsing.swift`) rather than hand-rolling a
                // second date parser, since `RedeemResult.expiresAt` is the same
                // Supabase-timestamp-shaped string every other `expiresAt` field in this file's
                // sibling `AccountModels.swift` already is. A parse failure just leaves the prior
                // confirmation (or `nil`) in place — the redemption itself already succeeded
                // (`refreshAccountState()` above is unaffected), so this is display-only best effort.
                if let expiresAt = result.expiresAt, let date = ParsedTaskValidation.parseISO8601(expiresAt) {
                    self.lastRedeemedUntil = date
                }
            } catch {
                self.accountError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    // MARK: - Sync actions (008-sync, client-contract.md §0 group C)
    //
    // Same shape as every Account action above: flip a busy flag, one `_Concurrency.Task`, await
    // the actor call, mirror the result into the `@Observable` properties above, `defer` clears
    // busy. client-contract.md §8 is explicit that AppState's ONLY two direct touches of
    // `SyncEngine` (group B's push/pull engine) are `attach(store:)` once and `requestSync(reason:)`
    // after a write — no polling timer belongs in this file, `SyncEngine` owns its own schedule.

    /// Last successful `sync_exchange` completion, written by `SyncEngine` (group B) to
    /// `UserDefaults` under the exact key client-contract.md §7 pins (`volar.sync.cursorTasks`'s
    /// sibling, `volar.sync.lastSuccessAt`). This file only READS it, for the "last synced" line in
    /// Settings — the key is spelled out as a literal (not a shared constant) because it's owned and
    /// WRITTEN by `Shared/Sync/SyncEngine.swift`, a file this group does not touch; the literal is
    /// pinned by the contract doc, so both sides agree on it without either owning the other's file.
    var lastSyncSuccessAt: Date? {
        UserDefaults.standard.object(forKey: "volar.sync.lastSuccessAt") as? Date
    }

    /// Group C's own text for a caught `SyncFailure` (or any other error) from a `SyncAccountClient`
    /// call. Deliberately does NOT reuse the generic `(error as? LocalizedError)?.errorDescription
    /// ?? "\(error)"` fallback every OTHER Account action above uses — that pattern is exactly the
    /// "gộp thành một thông báo sync lỗi" bug client-contract.md §1 rule 2 forbids. `.proRequired`/
    /// `.disabled` never reach the UI as an error string at all: `SettingsView`/`SettingsIOSView`
    /// read `syncState.settingsStatusLine` (`SyncAccountState.swift`) directly instead, because
    /// those two are STATES, not failures. `.offline` is silent by design (client-contract.md §3.3)
    /// — returning `nil` here is what keeps it silent even if a caller forgets to special-case it.
    /// Only `.signedOut`/`.server` ever produce visible text, and only in the small diagnostics line
    /// this property feeds (`syncError`), never a banner.
    private static func syncFailureMessage(_ error: Error) -> String? {
        guard let failure = error as? SyncFailure else {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        switch failure {
        case .proRequired, .disabled:
            return nil
        case .offline:
            return nil
        case .signedOut:
            return "Sign in to manage sync."
        case .server(let status, let message):
            return "Sync server error (\(status))\(message.map { ": \($0)" } ?? "")."
        }
    }

    /// Reads the account-level toggle. Called at launch and at foreground (same two moments
    /// `startAccountLifecycle()`/`refreshAccountState()` already care about) — `SyncAccountClient
    /// .fetchState()` hits `volar_sync_state()`, which is deliberately UNGATED server-side (design.md
    /// §8.2) so this call can succeed and explain WHY even when Pro has lapsed or the toggle is off
    /// elsewhere, rather than 403ing into "network error."
    func refreshSyncState() {
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            // Success OR failure both count as "asked" — a failed first fetch must stop the UI from
            // guessing just as much as a successful one does (Opus review, 2026-08-10).
            defer { self.syncStateLoaded = true }
            do {
                self.syncState = try await SyncAccountClient.shared.fetchState()
            } catch {
                self.syncError = Self.syncFailureMessage(error)
            }
        }
    }

    /// `SettingsView`'s toggle calls this directly for OFF (always allowed, no confirmation needed —
    /// design.md §8.3: "tắt thì LUÔN được, kể cả đã hết Pro"). For ON, the caller is `SyncEnableSheet`
    /// AFTER the user confirms — this method itself does not gate on `syncState.isPro` because the
    /// server-side RLS policy on `sync_prefs` is the real gate (client-contract.md §3.3's table);
    /// calling with `enabled: true` while not Pro just round-trips a `.proRequired` this method
    /// reports through `syncError` like any other failure — see `syncFailureMessage(_:)`.
    ///
    /// Device label comes from `SyncEngine.shared.deviceLabel` (group B, client-contract.md §7), NOT
    /// a locally-built string — this label lands in `sync_prefs.enabled_by_device`, and `SyncEngine`
    /// sends its OWN label into `sync_devices` via `sync_exchange`'s `p_device_label`. Two
    /// independently-built formulas for "this device's name" would let Settings call the same
    /// machine two different things right next to each other on screen (Opus review, 2026-08-10) —
    /// there must be exactly one source for that string.
    func setSyncEnabled(_ enabled: Bool) {
        syncBusy = true
        syncError = nil
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.syncBusy = false }
            do {
                self.syncState = try await SyncAccountClient.shared.setEnabled(
                    enabled, deviceLabel: SyncEngine.shared.deviceLabel
                )
            } catch {
                self.syncError = Self.syncFailureMessage(error)
            }
        }
    }

    /// The ONE path that deletes sync data server-side (`volar_sync_purge()`) — no job calls this,
    /// turning the toggle off does not call this, only a user tapping "Delete data on server" does
    /// (design.md §8.3). Never touches local data: `TaskStore`/`tasks` are untouched by this method
    /// regardless of outcome — Settings' confirmation copy for this button must say that plainly.
    func purgeSyncData() {
        syncBusy = true
        syncError = nil
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.syncBusy = false }
            do {
                _ = try await SyncAccountClient.shared.purge()
                self.refreshSyncState()
            } catch {
                self.syncError = Self.syncFailureMessage(error)
            }
        }
    }

    /// Valve 2 (design.md §6) — Settings' "Re-sync from scratch". A thin passthrough on purpose:
    /// `SyncEngine` owns the cursor keys (client-contract.md §7, "this file is the ONLY writer"), so
    /// this must not clear them itself. Does NOT set `syncBusy`: unlike `setSyncEnabled`/
    /// `purgeSyncData` there is no request to await here — the engine's own debounce runs the round,
    /// and `isSyncing`/`lastSyncSuccessAt` already report its progress.
    func resyncFromScratch() {
        syncError = nil
        SyncEngine.shared.resyncFromScratch()
    }

    /// Populates `syncRejects` for `SyncRejectsView`. Read-only, no busy flag of its own (the view
    /// shows its own empty state while `syncRejects` is still `[]`) — matches how this list is
    /// explicitly NOT part of the account-action busy/error story above (client-contract.md §9: read
    /// path only, v1 has no way to act on a reject).
    func loadSyncRejects() {
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.syncRejects = try await SyncAccountClient.shared.fetchRejects(limit: 200)
            } catch {
                if case SyncFailure.offline = error { return }
                self.syncError = Self.syncFailureMessage(error)
            }
        }
    }

    /// Signals `SyncEngine` (group B) that a local write just happened — the debounced-push half of
    /// client-contract.md §8's "exactly two calls." Called from `syncCalendarMirror()` below, the
    /// ONE existing choke point every task-list mutation in this file already funnels through (see
    /// that method's own doc comment) — deliberately NOT called from all ~15 individual mutator call
    /// sites: `syncCalendarMirror()` already IS "a task just changed, fan out the side effects" for
    /// this whole file, so adding a second, parallel fan-out list here would just be two lists that
    /// could drift apart. This one line is the sole reason `syncCalendarMirror()` — which otherwise
    /// belongs entirely to the calendar-mirror feature, not this one — gets touched outside this
    /// section; flagged here explicitly since it's the one deliberate exception to "only touch the
    /// Account & Entitlements section" in this file.
    ///
    /// SAFE EVEN IF THIS METHOD (or `syncCalendarMirror()` itself) ever misses a write path: the
    /// push queue is a DIRTY FLAG on each row (`isPendingSync`, design.md §7), not an event log —
    /// `pendingForSync` sweeps the whole store on every sync cycle regardless of whether anyone
    /// called `requestSync`. A write that doesn't reach this call loses nothing; it just rides the
    /// next poll (worst case ~30s per `SyncEngine`'s own schedule). `requestSync` only shaves that
    /// latency down — it is never the thing standing between a write and it eventually syncing, so
    /// this single call site does not need to be audited against every mutator in this file (Opus
    /// review, 2026-08-10).
    private func notifySyncOfLocalEdit() {
        SyncEngine.shared.requestSync(reason: .localEdit)
    }

    // MARK: - Derived task groupings

    var nowTasks: [TaskItem] { tasks.filter { !$0.done && $0.when == .now } }
    var laterTasks: [TaskItem] { tasks.filter { !$0.done && $0.when == .later } }
    var doneTasks: [TaskItem] { tasks.filter(\.done) }
    var openTasks: [TaskItem] { nowTasks + laterTasks }
    var frogTask: TaskItem? { tasks.first { $0.frog && !$0.done } }

    /// The task currently shown in the detail panel (looked up live so edits/toggles reflect).
    var detailTask: TaskItem? { detailTaskID.flatMap { id in tasks.first { $0.id == id } } }

    /// THE integration point with feature 001 (VolarCore nextTask engine): recomputed from the
    /// live `tasks` snapshot on every access, so there is no cached "active" state that can drift
    /// out of sync with `tasks`.
    var activeTask: TaskItem? {
        let engineTasks = tasks.map { $0.snapshot() }
        guard let winner = VolarCore.nextTask(from: engineTasks, now: clock(), calendar: .current) else { return nil }
        return tasks.first { $0.id == winner.id }
    }

    /// `TodayView`'s hero card reads THIS, not `activeTask` directly — everywhere else in the app
    /// (menu bar title, guided tour gating, voice read-day) keeps
    /// reading the engine's raw, un-overridable `activeTask` exactly as before; this property is
    /// additive, scoped to the one screen that needs a Switch override.
    ///
    /// While `dashboardSwitchOverrideID` names a task that's still genuinely open, THAT task wins
    /// over whatever the engine would otherwise pick — this is what makes "Switch" actually move
    /// the hero card's spotlight, since nothing about the switched-away task's own data (status/
    /// priority/deadline) ever changes, so the engine would otherwise keep re-selecting it forever.
    /// Self-healing: once the override task is done/deleted it silently drops out of `openTasks`
    /// and this falls straight back to `activeTask`, with no explicit teardown needed.
    var dashboardActiveTask: TaskItem? {
        if let overrideID = dashboardSwitchOverrideID,
           let overridden = openTasks.first(where: { $0.id == overrideID }) {
            return overridden
        }
        return activeTask
    }

    // MARK: - 006-cues-and-waiting: cue banner + waiting-mode holder (T5, wire UI)
    //
    // Both surfaces below follow the SAME ambient contract (design.md §3, this task's own brief):
    // no push notification, no sound, no full-screen takeover, no badge/count. `TodayView` is the
    // one screen that renders them (see that file's `todayScrollView`), alongside the other
    // "renders nothing when there's nothing to show" ambient banners already living there
    // (`SwitchBreakdownSuggestionBanner`).

    /// One cue on screen right now, or `nil`. Written ONLY by `recordAppBecameActive`/
    /// `noteNaturalCueTouch` below — never a live computed property, because `CueFiring.firing`'s
    /// wake-gap math is only meaningful measured against the value of `lastActiveAtKey` from
    /// BEFORE it gets overwritten for this activation; a computed property re-reading the (by then
    /// already-updated) key on every render would see a gap of zero forever.
    private(set) var cueBanner: CueBanner?

    /// design.md §3 ("Cue chỉ nhắc một lần mỗi lần fire. Im lặng = 'đừng hỏi nữa', không phải 'hỏi
    /// to hơn'."): `CueFiring.firing`/`.pending` are pure functions with no memory of their own by
    /// design (see that file's own header) — this is the caller-side bookkeeping the task brief
    /// explicitly assigns to T5. Keyed by task id (a task carries at most one `TaskCue` —
    /// `TaskItem.cue: TaskCue?` — so the task's own id is a sufficient identity for "already shown
    /// this one"). In-memory only, matching every other "this session" concept already in this file
    /// (`captureSession`/`resurfaceSession`): a fresh launch is a fresh session, on purpose — this
    /// is NOT the same thing as `TaskCue.expiresAt` (the 48h swallow-proof floor lives in the data
    /// itself; this is purely "don't repeat myself within one run").
    private var shownCueTaskIDs: Set<UUID> = []

    /// Every open task's cue, paired with its owning task id — the exact shape `CueFiring.firing`/
    /// `.pending` take as their `cues:` parameter. `openTasks`, not `tasks`: a cue on a `.done`/
    /// `.archived` task has nothing left to remind anyone about (mirrors every other ambient
    /// surface in this file reading `openTasks` rather than the raw store).
    private var openCues: [(taskId: UUID, cue: TaskCue)] {
        openTasks.compactMap { task in task.cue.map { (taskId: task.id, cue: $0) } }
    }

    /// Picks the first candidate id not already shown this session — factored out as a `static`,
    /// zero-dependency function (no `Date()`, no `UserDefaults`, no `self`) purely so it's
    /// unit-testable on its own, per this task's own instruction to pull decision logic out of
    /// `AppState` wherever it can be (precedent: `FullScreenEscalationDecision.swift`). Trivial by
    /// design — the interesting logic already lives in `CueFiring`; this is only the "don't repeat"
    /// half that has to live somewhere stateful.
    static func firstUnshownCue(_ candidates: [UUID], alreadyShown: Set<UUID>) -> UUID? {
        candidates.first { !alreadyShown.contains($0) }
    }

    /// The app genuinely became active (`NSApplication.didBecomeActiveNotification`, registered
    /// once in `init` above) — the ONLY call site allowed to run `CueFiring.firing`'s wake-gap math,
    /// and the ONLY writer of `Self.lastActiveAtKey`.
    ///
    /// ORDER IS LOAD-BEARING (flagged explicitly per this task's own brief, so nobody "cleans up"
    /// the ordering later): the OLD value must be read and handed to `CueFiring.firing` BEFORE the
    /// new value overwrites it. Write first and every gap becomes `now - now == 0`, which never
    /// clears `CueFiring.wakeGapHours`, which means the wake cue silently never fires again — a
    /// bug no test can catch (nothing here is wrong in isolation; only the ORDER of two correct
    /// lines is), which is exactly why this comment exists.
    func recordAppBecameActive() {
        // `clock()`, never a bare `Date()` default — this file's established seam for "now" (every
        // other action method reads it the same way, e.g. `activateServices()`'s own call sites)
        // specifically so tests can inject a fixed clock via `AppState.init(clock:)` rather than
        // fighting the real wall clock. A default-parameter expression can't reference `self.clock`
        // anyway (default values may not capture `self`), which is the other reason this reads it
        // from inside the body instead of as `now: Date = ...`.
        let now = clock()
        let previous = UserDefaults.standard.object(forKey: Self.lastActiveAtKey) as? Date
        let firingIDs = CueFiring.firing(now: now, lastActiveAt: previous, cues: openCues)
        UserDefaults.standard.set(now, forKey: Self.lastActiveAtKey)

        guard let chosenID = Self.firstUnshownCue(firingIDs, alreadyShown: shownCueTaskIDs),
              let cue = openTasks.first(where: { $0.id == chosenID })?.cue
        else { return }
        shownCueTaskIDs.insert(chosenID)
        cueBanner = CueBanner(taskId: chosenID, verbatim: cue.verbatim, createdAt: cue.createdAt)
    }

    /// The "natural touch point" half of design.md §2 Việc B ("Ở điểm chạm tự nhiên (mở popover):
    /// dùng CueFiring.pending(...), cũng ambient"). Called from `TodayView`'s `.onAppear` — the main
    /// window becoming visible is this app's most central "the user is looking at Volar right now"
    /// moment; `PopoverView` was deliberately NOT used for this (judgment call, flagged in this
    /// task's final report): it is capture-flow-specific (recording/confirm cards for a brand-new
    /// utterance), and surfacing an unrelated already-saved task's cue in the middle of capturing a
    /// different one would read as a non-sequitur, not an ambient aside.
    ///
    /// Never overwrites an already-showing banner (`cueBanner != nil` guard) — a wake cue that just
    /// fired this activation takes priority over a merely-pending one; this only fills the slot in
    /// when nothing is on screen yet.
    func noteNaturalCueTouch() {
        guard cueBanner == nil else { return }
        let now = clock() // same `clock()`-not-`Date()` seam as `recordAppBecameActive` above.
        let pendingIDs = CueFiring.pending(now: now, cues: openCues)
        guard let chosenID = Self.firstUnshownCue(pendingIDs, alreadyShown: shownCueTaskIDs),
              let cue = openTasks.first(where: { $0.id == chosenID })?.cue
        else { return }
        shownCueTaskIDs.insert(chosenID)
        cueBanner = CueBanner(taskId: chosenID, verbatim: cue.verbatim, createdAt: cue.createdAt)
    }

    /// `WaitingMode.decide`'s live reading, or `nil` when there's no anchor in the next 4 hours
    /// (design.md §2 Việc C: silence is the default — an empty horizon must never be dressed up
    /// into ambient noise). A plain computed property, unlike `cueBanner` above: `WaitingMode.decide`
    /// has no gap-since-an-overwritten-value hazard the way `CueFiring.firing` does, so recomputing
    /// it fresh on every render (same "no cached state that can drift" convention `activeTask`
    /// itself already documents) is both safe and simpler than latching it.
    var waitingModeDecision: WaitingMode.Decision? {
        let now = clock()
        return WaitingMode.decide(
            now: now,
            anchors: hardAnchors(now: now),
            tasks: tasks,
            eligibleOrder: Self.eligibleOrder(from: tasks, now: now)
        )
    }

    /// Merges both `WaitingMode.HardAnchor` sources (design.md §2.3, §0's "AppState is the one
    /// place allowed to know about both task storage and EventKit"):
    ///  1. Every open task's own `deadline` (`.deadline(taskID:)`) — filtered EXACTLY like
    ///     `SharedTests/WaitingModeTests.swift`'s `anchor(for:)` helper (the caller-side filter
    ///     `WaitingMode.decide` used to do internally, now pushed out to here per §2.3): drop
    ///     `.done`/`.archived` tasks and tasks with no `deadline`. Deliberately reads `tasks` (the
    ///     FULL store), not `openTasks` — `openTasks` only filters `.done`, not `.archived`, and
    ///     matching the test helper's exact two-status filter here (rather than trusting
    ///     `openTasks` to already cover it) is what keeps this in lockstep with that helper instead
    ///     of silently drifting from it.
    ///  2. `calendarAccess.busyBlocks` (`.calendar`) — ONLY when `calendarReadEnabled` (§2.5) is
    ///     on. Toggle off ⇒ `busyBlocks` is never called at all, not called-then-discarded (§2.5's
    ///     own rule) — no EventKit touch, nothing cached, nothing stored.
    private func hardAnchors(now: Date) -> [WaitingMode.HardAnchor] {
        let deadlineAnchors: [WaitingMode.HardAnchor] = tasks.compactMap { task in
            guard task.status != .done, task.status != .archived, let deadline = task.deadline else {
                return nil
            }
            return WaitingMode.HardAnchor(title: task.title, at: deadline, source: .deadline(taskID: task.id))
        }
        guard calendarReadEnabled else { return deadlineAnchors }
        let horizonEnd = now.addingTimeInterval(TimeInterval(WaitingMode.horizonMinutes * 60))
        let calendarAnchors = calendarAccess.busyBlocks(
            from: now,
            to: horizonEnd,
            excludingCalendarID: calendarSync.volarCalendarID
        ).map { block in
            WaitingMode.HardAnchor(title: block.title, at: block.start, source: .calendar)
        }
        return deadlineAnchors + calendarAnchors
    }

    /// The FULL eligible-task ordering — `WaitingMode.decide`'s `eligibleOrder:` parameter contract
    /// (design.md §2 Việc C): "phải là danh sách eligible ĐẦY ĐỦ engine trả về, KHÔNG được cắt
    /// top-N."
    ///
    /// 2026-08-09 (Opus review of T5, specs/006-cues-and-waiting): this used to be a hand-copied
    /// reimplementation of `VolarCore.eligibleTasks`'s filter rule, written because that function
    /// (and the ordered list this needs) had no public entry point at the time. That copy was a
    /// live silent-drift risk — a future change to `NextTask.swift`'s eligibility rule would compile
    /// cleanly here while this file quietly kept computing the OLD rule, corrupting
    /// `WaitingMode.Decision.anchorIsEligible` with no compiler error and no test able to catch it.
    /// `VolarCore.eligibleTasksOrdered(from:now:calendar:)` is now public for exactly this caller
    /// (see that function's own doc comment in `NextTask.swift`) — this is a thin wrapper, not a
    /// second copy of the rule. `static` + taking `tasks`/`now` as plain parameters (no `self`) so
    /// it stays unit-testable without an `AppState` instance, same reasoning as `firstUnshownCue`
    /// above; the tests in `Volar/Tests/AppStateCueAndWaitingTests.swift` now exercise the real
    /// engine rule through this wrapper instead of a parallel one.
    static func eligibleOrder(from tasks: [TaskItem], now: Date) -> [UUID] {
        let snapshot = tasks.map { $0.snapshot() }
        return VolarCore.eligibleTasksOrdered(from: snapshot, now: now, calendar: .current).map(\.id)
    }

    // MARK: - Sidebar sections (Upcoming/Inbox) — 2026-07-27, port of Windows
    // `TodayViewModel.RefreshSections` (ViewModels/TodayViewModel.cs:609-647). Membership itself
    // lives in `TaskSections` (Sources/Model/TaskSections.swift); everything here is just deriving
    // the sidebar's live counts + `TodayView`'s Upcoming/Inbox bodies from the same `openTasks`
    // snapshot Today already uses, so the three sections can never disagree about what exists.

    // Upcoming và Inbox bỏ 2026-08-24 (anh Khôi) — `startOfTomorrow`/`upcomingGroups`/
    // `upcomingNavCount`/`inboxTasks`/`inboxNavCount` xoá theo vì hết chỗ gọi. Luật phân loại
    // thuần vẫn nằm trong `Shared/Model/TaskSections.swift`, chưa đụng: nó còn chứa `isClosed`
    // và mấy helper ngày mà chỗ khác dùng, và hai bản Windows/iOS vẫn có Upcoming/Inbox.

    /// Cất một việc đi: `TaskStatus.archived`. KHÔNG phải hoàn thành (không `CompletionEvent`,
    /// không đếm vào "N done") và cũng không phải xoá — đây là "tôi không làm cái này nữa nhưng
    /// đừng vứt nó". Đi qua `mergeIntoExisting`, cùng đường mọi mutation khác trong file này dùng,
    /// nên không cần thêm API mới cho `TaskStore`.
    ///
    /// `.archived` làm task INELIGIBLE với `VolarCore.nextTask()` (xem `TaskStatus`), nên nếu nó
    /// đang là NOW thì việc kế tiếp tự lên — cùng cơ chế `delegateTask` từng dùng, không cần logic
    /// "advance" riêng.
    func archiveTask(_ id: UUID) {
        guard let store else {
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                tasks[index].status = .archived
            }
            return
        }
        let before = tasks
        _ = store.mergeIntoExisting(id) { existing in
            var updated = existing
            updated.status = .archived
            return updated
        }
        tasks = store.fetchAll()
        scheduler?.scheduleReminders(taskId: id)
        notifyEligibilityAndScheduleResurface(before: before, now: clock())
    }

    /// Số việc đã xong — cùng nguồn `doneTasks` mà section Completed hiển thị, không đếm riêng.
    var completedNavCount: Int { doneTasks.count }

    /// Việc đã cất đi (`TaskStatus.archived`) — section Archived, thay chỗ Inbox từ 2026-08-24.
    /// Mới nhất trước: `createdAt` giảm dần, cùng thứ tự Inbox từng dùng, vì một việc đã cất không
    /// có hạn lẫn thứ hạng nào để xếp theo.
    var archivedTasks: [TaskItem] {
        tasks.filter { $0.status == .archived }.sorted { $0.createdAt > $1.createdAt }
    }

    var archivedNavCount: Int { archivedTasks.count }

    // MARK: - Task CRUD

    func addTask(_ t: TaskItem) {
        let before = tasks
        tasks.insert(t, at: 0)
        store?.add(t)
        // WG-1 (constitution IV): every newly created dated task must actually get its reminders
        // scheduled — a no-op for an undated task (`ReminderRecord.derive` returns empty).
        scheduler?.scheduleReminders(taskId: t.id)
        notifyEligibilityAndScheduleResurface(before: before, now: clock())
        // FIX 6: a new task can carry a deadline from the moment it's created (membership change
        // + possible new deadline) — keep the calendar mirror in step.
        syncCalendarMirror()
    }

    /// Mirrors `volar-mac.jsx`'s `toggleTask`: marking a task done always bumps it to `.later`
    /// (it leaves "Now"); un-marking it leaves the `when` bucket untouched.
    ///
    /// Store-backed path: `TaskStore.toggle` owns strictly more than a plain status flip
    /// (recurrence reset-in-place, parent auto-complete cascade, `CompletionEvent` append — see
    /// `TaskStore.toggle`'s doc comment), so after it runs, `tasks` is refreshed wholesale from
    /// the store instead of hand-patched, keeping the store as the single source of truth for the
    /// UI. No-store fallback (previews/tests without a `TaskStore`) keeps the old in-memory-only
    /// behavior.
    ///
    /// T037 (phase5-contract.md §C, FR-020): THIS is the one consolidated completion+advance
    /// funnel every reachable completion source routes through — the plain UI toggle (its own
    /// original caller), `confirmVoiceDone`'s `.complete` case (T036), and `sweepComplete` (T038)
    /// all call this method directly rather than each re-implementing store.toggle + refresh +
    /// reminder-cancel + eligibility-diff. The single atomic `tasks = store.fetchAll()` assignment
    /// below is what gives `MenuBarLabel.activeTask` (a computed property re-deriving
    /// `VolarCore.nextTask` from `tasks` on every read) its "no intermediate empty/list state"
    /// property for free — there is no separate cached "active task" to go stale in between.
    /// KNOWN GAP (self-review "conflict", flagged rather than fixed — `Sources/Reminders/**` is
    /// out of this task's 5 owned files): `ReminderScheduler.handleAction` (the notification
    /// "Done" action) calls `store.toggle(...)` DIRECTLY, bypassing this method entirely, by
    /// design (FR-014/015/016: notification actions must never open/touch the app window). While
    /// the main window is open, that leaves `AppState.tasks` briefly stale until some other
    /// mutation refreshes it — `MenuBarLabel` isn't wrong forever, just not instantly live for
    /// that one background source. Fixing it needs a hook in `VolarApp.swift` (e.g. refresh
    /// `tasks` on window-foreground/menu-open), which is also outside this task's 3 owned files.
    func toggleDone(_ id: UUID) {
        guard let store else {
            guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
            let wasDone = tasks[index].done
            tasks[index].status = wasDone ? .todo : .done
            if !wasDone {
                tasks[index].when = .later
            }
            // FIX 6: done-state just flipped (the exact field `isDesired` filters on) — no-store
            // fallback (previews/tests) still needs this so `calendarSync`'s self-guards see it.
            syncCalendarMirror()
            resumeParkedTaskIfNeeded(justCompleted: id)
            return
        }
        let before = tasks
        let now = clock()
        store.toggle(id, now: now)
        tasks = store.fetchAll()
        // WG-2 (constitution IV): a backgrounded reminder delivery bypasses `willPresent`, so a
        // completed/archived task must have its outstanding reminders actively cancelled here
        // rather than relying solely on the fire-time fresh-reload suppression. The flip side also
        // applies: `TaskStore.toggle` can REOPEN a task (un-marking done) or reset a recurring
        // task back to `.todo` in place with a fresh deadline — either way it needs its reminders
        // re-derived, not left cancelled.
        if let toggled = tasks.first(where: { $0.id == id }) {
            if toggled.status == .done || toggled.status == .archived {
                scheduler?.cancelReminders(taskId: id)
            } else {
                scheduler?.scheduleReminders(taskId: id)
            }
        }
        let newlyEligible = notifyEligibilityAndScheduleResurface(before: before, now: now)
        // FIX 6: done-state changed (T037's completion funnel — `confirmVoiceDone`'s `.complete`,
        // `sweepComplete`, and the plain UI toggle all route through here), and `TaskStore.toggle`
        // can also reset a recurring task back to `.todo` with a FRESH deadline in place — both are
        // exactly the fields `CalendarSync.isDesired`/`eventWindow` key off of.
        syncCalendarMirror()
        // Park & resume: if what just got ticked was the interruption, hand the spotlight back to
        // whatever the user set aside for it. Runs after `tasks` is refreshed so it reads the real
        // post-toggle state (a recurring task that `TaskStore.toggle` reset back to `.todo` is
        // correctly NOT treated as finished).
        resumeParkedTaskIfNeeded(justCompleted: id)
        // ...and the dependency half: anything parked waiting on THIS task is workable again.
        resumeParkedTaskIfUnblocked(newlyEligible)
    }

    /// Store-backed path: `TaskStore.delete` strips the id from every other task's `.taskDone`
    /// conditions and nulls children's `parentId` (validation rule 4), so `tasks` is refreshed
    /// from the store afterward rather than just removing the one row — same rationale as
    /// `toggleDone` above. No-store fallback keeps the old in-memory-only behavior.
    func deleteTask(_ id: UUID) {
        guard let store else {
            tasks.removeAll { $0.id == id }
            // FIX 6: membership change (no-store fallback) — see `toggleDone`'s own no-store
            // branch for why this still needs calling even without a real `TaskStore`.
            syncCalendarMirror()
            return
        }
        let now = clock()
        // `TaskStore.delete` already computes its own before/after `eligibilityDiff` internally
        // (stripping this id from every other task's `.taskDone` conditions first) — reuse that
        // result directly instead of recomputing the same diff a second time here (self-review
        // "performance": exactly one `eligibilityDiff` per mutation).
        let newlyEligible = store.delete(id, now: now)
        tasks = store.fetchAll()
        // WG-2 (constitution IV): cascade cancellation — a deleted task's reminders must never
        // orphan-fire (the fresh-reload guard in `evaluate(_:snapshot:)` treats "not found" as
        // "nothing to show," but the durable rows/system requests should still be reaped promptly
        // rather than waiting for the next due-but-missed sweep).
        scheduler?.cancelReminders(taskId: id)
        if !newlyEligible.isEmpty {
            scheduler?.notifyUnblocked(taskIds: newlyEligible)
        }
        resumeParkedTaskIfUnblocked(newlyEligible)
        scheduleNextResurface(from: tasks.map { $0.snapshot() }, now: now)
        // FIX 6: membership change — `reconcile(tasks:)`'s own "no longer desired" pass (which a
        // deleted task's id will now fall into, since it's not in `tasks` at all anymore) is what
        // actually removes its mirrored event, if any.
        syncCalendarMirror()
    }

    /// T-edit-attrs (2026-07-29, manual-edit-contract.md §1.4 — anh Khôi: `TaskDetailView` becomes
    /// sửa-tại-chỗ for an already-created task): the ONE write path for the 7 manually-editable
    /// fields on an existing task. `TaskDetailView` (Agent C) is the only caller today, but any
    /// future editor must route through here too, never through `TaskStore` directly, so every
    /// side effect below (reminders/eligibility/calendar) always fires together rather than being
    /// re-implemented (and possibly forgotten) at each call site. Mirrors `addTask`/`toggleDone`'s
    /// own "before/now snapshot -> store mutation -> tasks = store.fetchAll() -> reminders ->
    /// eligibility -> calendar" shape exactly — see those two immediately above for the established
    /// convention this follows. `id` not found (task deleted out from under an open detail view,
    /// e.g. via the notification "Done" action bypass `refreshFromStore`'s own doc comment
    /// describes) is a silent no-op, same "can't act on what isn't there anymore" convention every
    /// other mutator in this file (`setDraftDeadline` et al.) already follows for an unknown id.
    func updateTask(
        _ id: UUID,
        title: String,
        details: String,
        priority: Priority,
        startTime: Date?,
        deadline: Date?,
        // specs/010-calendar-and-hard-deadlines/design.md §3.1/§3.2: threaded exactly like
        // `priority` right above — non-optional, no "unchanged" sentinel, direct overwrite below.
        // DELIBERATELY NO DEFAULT (Opus review, 2026-08-19): non-optional + direct-overwrite +
        // default would let any call site that simply forgets this argument silently downgrade a
        // `.hard` deadline to `.soft` — no compile error, no warning, no way to notice besides the
        // user losing protection with no idea it happened. That's exactly the class of silent lie
        // this whole feature exists to stop (design.md §3.0), so shipping it with its own silent
        // downgrade path would be self-defeating. Omitting the default forces the compiler to make
        // every caller state its intent instead — `SharedTests/ManualEditDraftTests.swift`'s 5 call
        // sites were updated to pass it explicitly for exactly this reason.
        deadlineKind: DeadlineKind,
        durationMinutes: Int?,
        remindPeriod: TimeInterval?
    ) {
        let before = tasks
        let now = clock()
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        var edited = tasks[index]
        edited.title = title
        // `details` AND `notes` MUST both be written to the SAME value (manual-edit-contract.md
        // §1.4): `details` is what `TaskDetailView`/`speakDetails` actually render/read aloud;
        // `notes` is the "did a human really author a note" signal `mergeTransform`'s notes-append
        // path (and `effectiveNotes` elsewhere) keys off of. Writing only one leaves the other
        // stale — either the edit never shows, or a later confirm-card merge treats a real edit as
        // if nothing was ever typed. Empty -> `nil` for `notes`, same "blank collapses to absent"
        // convention `effectiveNotes`/`effectiveTitle` already use elsewhere in this file, so
        // clearing the description doesn't leave a phantom empty-string note behind.
        edited.details = details
        edited.notes = details.isEmpty ? nil : details
        edited.priority = priority
        edited.startTime = startTime
        edited.deadline = deadline
        edited.deadlineKind = deadlineKind
        edited.durationMinutes = durationMinutes
        // `remindPeriod == nil` does NOT mean "wipe the whole override" — a task can carry a real
        // `reminderOverride` (parser-derived offsets/fractionsRemaining, or a previous edit) that
        // simply never had a fixed cadence set; clearing the cadence back to "not set" must leave
        // the rest of that override alone rather than nuking it. Only when there was no override to
        // begin with does it stay `nil` (nothing to carry forward, manual-edit-contract.md §1.4).
        // Mirrors `ConfirmDraft.effectiveReminderOverride`'s "fold the one edited field onto a base
        // policy" shape (§1.1) — `globalReminderPolicy` is the base here instead of `.defaultPolicy`
        // since an already-created task's baseline behavior is the user's own configured default,
        // not the app's hardcoded starting point.
        if let remindPeriod {
            var base = edited.reminderOverride ?? globalReminderPolicy
            base.remindPeriod = remindPeriod
            edited.reminderOverride = base
        } else if var base = edited.reminderOverride {
            base.remindPeriod = nil
            edited.reminderOverride = base
        }

        if let store {
            store.updateEditableFields(from: edited)
            tasks = store.fetchAll()
        } else {
            tasks[index] = edited
        }
        // manual-edit-contract.md §1.4 step 5: LUÔN gọi, không điều kiện. `ReminderScheduler.
        // scheduleReminders(taskId:)` re-reads the task fresh from the store and replaces every
        // `.scheduled`-but-not-yet-sent row (deadline edits land here, per that method's own doc
        // comment) while preserving `.delivered`/`.satisfied` history — so this must run even when
        // `deadline`/`remindPeriod` didn't actually change (the call is idempotent) and even when
        // `deadline` was just cleared to `nil` (that still needs `derive` to re-run and fall into
        // its nudge-backoff branch instead of leaving a stale deadline-based row armed). Skipping
        // this on a "nothing dated changed" edit would leave a notification armed for the OLD time
        // after the user changes it, e.g. 15:00 -> 20:00 with the OS still holding the 15:00 request.
        scheduler?.scheduleReminders(taskId: id)
        notifyEligibilityAndScheduleResurface(before: before, now: now)
        syncCalendarMirror()
    }

    /// WG-C (FR-020 gap fix): `ReminderScheduler.handleAction`'s notification "Done" action calls
    /// `store.toggle(...)` directly rather than routing through this file's `toggleDone` funnel (by
    /// design — FR-014/015/016 forbid the notification path from touching the app/AppState
    /// directly). That leaves `tasks` — and therefore `MenuBarLabel.activeTask`, which re-derives
    /// `VolarCore.nextTask` from `tasks` on every read — stale until some other mutation happens to
    /// refresh it. `ReminderScheduler` now posts `.volarTasksDidChange` after any such store
    /// mutation; `VolarApp.swift` observes it and calls this to catch `tasks` back up. Mirrors the
    /// exact `tasks = store.fetchAll()` refresh every other store-backed mutation above already
    /// does — no-op (not an error) when there's no store, same as every other no-store fallback in
    /// this file.
    func refreshFromStore() {
        guard let store else { return }
        tasks = store.fetchAll()
        // FIX 6: `tasks` just changed (possibly, if `refreshFromStore` picked up an out-of-band
        // mutation — see this method's own doc comment above) — keep the mirror in step. Cheap/
        // safe even when nothing actually changed: `reconcile(tasks:)` self-guards on
        // `mirrorEnabled`/access and diffs against `eventMap`, so a no-op refresh costs one
        // `isDesired` filter pass and nothing else.
        syncCalendarMirror()
    }

    // MARK: - Calendar mirroring wiring (FIX 6: nothing called `CalendarSync.reconcile(tasks:)`
    // before this — the mirror was constructed but never actually driven).

    /// Thin wrapper around `calendarSync.reconcile(tasks:)` — the single seam every task-list
    /// mutation choke point below calls through, so there is exactly one line to read to see what
    /// "keep the calendar mirror in sync" means. Safe to call often: `reconcile(tasks:)` itself
    /// never throws, and no-ops almost immediately when access isn't granted or mirroring is off
    /// (see that method's own early guards, `CalendarSync.swift`).
    private func syncCalendarMirror() {
        calendarSync.reconcile(tasks: tasks)
        // 008-sync (client-contract.md §8): the SECOND of AppState's exactly-two direct touches of
        // `SyncEngine` — signal a local write happened. Deliberately placed here, not at each of the
        // ~15 individual call sites below, because this method is already documented (see its own
        // header comment two lines up) as "the single seam every task-list mutation choke point ...
        // calls through" — the one true fan-out point for "a task just changed" in this file. Added
        // here rather than confined to the Account & Entitlements section — see
        // `notifySyncOfLocalEdit()`'s own doc comment for why that's a deliberate, single-line
        // exception rather than an oversight.
        notifySyncOfLocalEdit()
    }

    /// Settings' mirror toggle routes here (never straight to `calendarSync.setMirrorEnabled(_:)`)
    /// so flipping it ON mirrors immediately — persisting the flag alone wouldn't create any
    /// events until whatever task mutation happens to come next, which could be a while for a user
    /// who just enabled the feature and is now looking at their calendar for the first result.
    func setCalendarMirror(_ enabled: Bool) {
        calendarSync.setMirrorEnabled(enabled)
        syncCalendarMirror()
    }

    /// The tour's "Enable Calendar" button and Settings' permission button both call this instead
    /// of `calendarAccess.requestAccess()` directly, for the same "don't wait for the next
    /// coincidental task edit" reasoning as `setCalendarMirror(_:)` above: a fresh grant should let
    /// an already-enabled mirror populate the calendar right away, not just update `status`.
    func enableCalendarAccess() async {
        await calendarAccess.requestAccess()
        syncCalendarMirror()
    }

    // MARK: - Dependency editing on an already-created task (cycle-detection-contract.md §1.3/§4)
    //
    // `TaskDetailView`'s "Waiting on" section (Agent 4) routes here rather than through
    // `TaskStore` directly, same "one write path, every side effect fires together" convention
    // `updateTask` above already establishes — validation happens INLINE, at the moment the user
    // taps, not deferred to some later commit step, because a rejected dependency has to explain
    // itself right there.

    /// Adds "task `id` waits on task `dependsOn` (via `.taskDone`)" — the dependency picker's
    /// resolution. Returns `nil` on success, or an English message on rejection. Checks
    /// `VolarCore.cyclePath` itself BEFORE ever calling `TaskStore.addCondition`, rather than
    /// catching that method's own `TaskStoreError`/`DependencyError`, specifically so the message
    /// can show the FULL closed path ("A → B → C → A") — `DependencyError.cycle(from:to:)` only
    /// ever carries the two endpoint titles, not enough to explain a longer loop (contract's own
    /// "vì sao phải làm" table).
    @discardableResult
    func addTaskDependency(_ id: UUID, dependsOn: UUID) -> String? {
        // UNVERIFIED: no other mutator in this file returns an error string when `store` is nil
        // (every other one either no-ops silently for the no-store preview/test fallback, or —
        // like `confirmSave` — has its own separate in-memory branch). `TaskDetailView` only ever
        // shows an already-persisted task, which requires a real store to exist, so this branch
        // should be unreachable in practice; picked the most honest message over a silent no-op.
        guard let store else { return "No task store available." }
        guard tasks.contains(where: { $0.id == id }), tasks.contains(where: { $0.id == dependsOn }) else {
            return "That task no longer exists."
        }
        let snapshot = tasks.map { $0.snapshot() }
        if let cycle = VolarCore.cyclePath(from: id, dependsOn: dependsOn, in: snapshot) {
            return cycleMessage(for: cycle)
        }
        let before = tasks
        // Park & resume, dependency half: if the task being blocked is the one on screen right now,
        // it can't be worked on any more — set it aside (and drop any pin, which the `openTasks`-
        // based `dashboardActiveTask` would otherwise keep honouring for a blocked task) so
        // `resumeParkedTaskIfUnblocked` hands it back the moment `dependsOn` clears.
        let blockingTheSpotlitTask = dashboardActiveTask?.id == id
        do {
            try store.addCondition(.taskDone(dependsOn), to: id)
        } catch {
            // Defense in depth only — the `cyclePath` check above already covers every case
            // `TaskStore.addCondition` itself would otherwise reject for a `.taskDone` payload.
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        let now = clock()
        // §1.3: gỡ/thêm một cạnh có thể mở khoá task khác ngay — same three-step refresh tail
        // every other store-backed mutator in this file uses (`addTask`/`toggleDone`/`deleteTask`).
        tasks = store.fetchAll()
        if blockingTheSpotlitTask, let blocked = tasks.first(where: { $0.id == id }) {
            if dashboardSwitchOverrideID == id { dashboardSwitchOverrideID = nil }
            park(blocked, note: "Paused \(clock().formatted(.dateTime.hour().minute())) — waiting on \u{201C}\(titleFor(dependsOn) ?? "another task")\u{201D}")
        }
        notifyEligibilityAndScheduleResurface(before: before, now: now)
        syncCalendarMirror()
        return nil
    }

    /// Removes the condition at `conditionIndex` from task `id` — the "×" next to a "Waiting on"
    /// row. No-op (per `TaskStore.removeCondition`'s own contract, §1.4) if `id`/`conditionIndex`
    /// don't resolve to anything, same "can't act on what isn't there anymore" convention every
    /// other mutator in this file follows for an unknown id.
    func removeTaskDependency(_ id: UUID, at conditionIndex: Int) {
        guard let store else { return }
        let before = tasks
        // UNVERIFIED: `TaskStore.removeCondition(at:from:)` is Agent 4's addition
        // (cycle-detection-contract.md §1.4) — called here exactly per its frozen signature.
        guard store.removeCondition(at: conditionIndex, from: id) else { return }
        let now = clock()
        // §1.3: removing an edge can make some OTHER task newly eligible right now — this is
        // exactly the "gỡ một cạnh có thể làm task khác đủ điều kiện chạy ngay" case the contract
        // calls out; skipping this would silently lose that "unblocked" notification.
        tasks = store.fetchAll()
        notifyEligibilityAndScheduleResurface(before: before, now: now)
        syncCalendarMirror()
    }

    /// Builds "A → B → C → A" from a closed cycle path of ids (`VolarCore.cyclePath`/`findCycle`'s
    /// shared shape — first element == last), resolving each id against `tasks`' own titles.
    /// Deliberately NOT `DependencyError`-based (see `addTaskDependency`'s own doc comment) — this
    /// carries the whole loop, not just the two endpoints that would close it.
    private func cycleMessage(for cycle: [UUID]) -> String {
        let titles = cycle.map { taskID in
            tasks.first(where: { $0.id == taskID })?.title ?? "Unknown task"
        }
        let path = titles.joined(separator: " \u{2192} ")
        return "Can't add that dependency — it would create a loop: \(path). None of these could ever start."
    }

    // MARK: - Detail panel (Phase 1: click a task row to see/hear its full description; panel-
    // refactor pass, specs/005-cursor-retheme/panel-refactor.md §5 item 1, turned the sheet this
    // comment used to describe into an inspector panel — same `detailTaskID` signature throughout)

    /// Toggle, not a plain setter (panel-refactor.md §4): tapping the row that is ALREADY open
    /// closes the panel instead of re-opening it on itself. This is deliberately the panel's only
    /// non-Esc close gesture besides the Close button (path (c) in `TaskDetailView`'s commit
    /// mechanism) — Esc is intentionally NOT bound to the panel (§4 of the spec: it already belongs
    /// to the capture popover's `escCancelButton` and the ⌘K command bar; a third claimant risks
    /// closing the wrong surface). Every call site (`TaskRow`, NOW spotlight, `NextPeekRow`) keeps
    /// calling this the same way — a second tap on the same row is the only new behavior.
    func openDetail(_ id: UUID) { detailTaskID = (detailTaskID == id) ? nil : id }
    func closeDetail() { detailTaskID = nil }
    /// Speaks a task's description (falls back to its title when there's no description).
    func speakDetails(of task: TaskItem) {
        voice.speak(task.details.isEmpty ? task.title : task.details)
    }

    // MARK: - Capture / popover flow
    // CaptureState walks: .idle -> .recording -> .parsing -> .parsed -> .saving -> .done (or .error)

    /// Monotonic token guarding the *deferred* part of `startCapture()`: authorization is async
    /// (first run blocks on the TCC prompt), so by the time it resolves the user may already have
    /// released the hotkey or hit Esc. Every start/stop/cancel bumps this; a pending start only
    /// proceeds if its captured token is still current — otherwise the mic would be turned on
    /// with nothing left to ever turn it off.
    private var captureSession = 0

    /// Session-only (never persisted, never touches `speechEngineChoice`): set by
    /// `handleCloudSpeechUnavailable` the moment Groq reports a `403`/`429` mid-flight. Stops
    /// `selectedEngine` from retrying Groq for the REST OF THIS RUN without waiting on a second
    /// network round trip each capture — a lapsed subscription or a spent daily quota is a
    /// transient condition, not a user preference change, so the Settings picker stays exactly as
    /// the user left it. Never reset back to `false` within a run: the next thing that legitimately
    /// re-arms Groq is the user relaunching (fresh `AppState`) or explicitly re-picking it in
    /// Settings after fixing the underlying issue (resubscribing, waiting for the daily reset).
    private var groqDegradedThisSession = false

    /// Picks the engine for the NEXT capture based on user choice, with safe fallbacks:
    /// WhisperKit only when supported AND its model is loaded, else Apple; Groq (cloud) only when a
    /// credential is configured AND it hasn't degraded this session, else Apple on-device — so
    /// choosing cloud before a key exists (or after a `403`/`429` mid-capture, see
    /// `groqDegradedThisSession`) degrades quietly to local instead of hard-erroring at upload time
    /// ("code first, key later", mirrors the Local↔Cloud parse switch's fallback).
    private var selectedEngine: SpeechEngine {
        switch speechEngineChoice {
        case .appleOnDevice: return speech
        case .whisperKit: return (WhisperKitEngine.isSupported && whisper.isModelReady) ? whisper : speech
        case .groq: return (GroqEngine.isConfigured && !groqDegradedThisSession) ? groq : speech
        }
    }

    func startCapture() {
        captureState = .recording
        liveTranscript = ""
        confirmDrafts = []
        confirmUpdateDrafts = []
        confirmCycle = nil
        voiceDoneConfirm = nil
        voiceDoneNoMatchTranscript = nil
        captureErrorDetail = nil
        pendingServerConsent = false
        pendingCloudConsent = false
        pendingParseTranscript = nil
        captureSession += 1
        let session = captureSession
        let engine = selectedEngine
        runningEngine = engine
        // Kick off recognition. Must qualify `_Concurrency.Task` because `import VolarCore` brings
        // in `VolarCore.Task` (the engine's model struct), which shadows `Swift.Task` in this file.
        // Explicitly hopping back onto @MainActor is still intentional (matches
        // AmbientSound.rampVolume's convention elsewhere).
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = await engine.requestAuthorization()
            // Stale? The hold ended (key-up/Esc/retry) while the permission flow was in flight.
            guard self.captureSession == session, self.captureState == .recording else { return }
            guard granted else {
                self.captureErrorDetail = Self.describe(.authorizationDenied)
                self.captureState = .error
                return
            }
            // FIX 2b (privacy seam): guard against a late callback landing after this session was
            // superseded (Esc/cancel/a fresh capture already started) — without this, a `.stop()`
            // caller (`stopCapture`/`confirmSave`'s siblings) that genuinely wants the final result
            // is unaffected, but a callback arriving after `cancelCapture`/`dismissVoiceDoneConfirm`
            // already moved on (now routed through `.cancel()`, see those methods below) can no
            // longer resurrect a confirm card the user already dismissed.
            engine.onFinal = { [weak self] transcript in
                guard let self, self.captureSession == session else { return }
                self.finishRecording(transcript: transcript)
            }
            engine.onError = { [weak self] error in
                guard let self, self.captureSession == session else { return }
                self.handleCaptureError(error)
            }
            // Apple-only: server-consent. (Locale/language is already applied live by
            // `setRecognitionLocale`/init — but only for `speech` (Apple, via `setLocale`) and
            // `groq` (via `languageCode`); WhisperKit takes no locale input at all and always
            // auto-detects the spoken language, so there is nothing to apply to it here or there.)
            // WhisperKit also has no server-consent concept at all; Groq is cloud-only already (its
            // consent gate is the paid-tier check in `selectedEngine`, not this on-device/server
            // toggle) — so there's nothing analogous to wire for either of them here.
            if let apple = engine as? SpeechCapture {
                apple.allowServerFallback = self.allowServerRecognition
            }
            // Groq-only: 403/429 mid-flight routes here instead of `onError` — see
            // `handleCloudSpeechUnavailable`'s doc comment.
            if let groqEngine = engine as? GroqEngine {
                groqEngine.onCloudUnavailable = { [weak self] fileURL in
                    await self?.handleCloudSpeechUnavailable(session: session, salvageAudioURL: fileURL)
                }
            }
            engine.start(onPartial: { [weak self] partial in self?.liveTranscript = partial })
        }
    }

    /// Shared `onError` handling for whichever engine `startCapture()` routed to — moved out of
    /// the closure verbatim so `startCapture` doesn't have to special-case per-engine errors.
    private func handleCaptureError(_ error: Error) {
        if case SpeechCaptureError.onDeviceUnavailable = error {
            pendingServerConsent = true
            captureErrorDetail = "Dictation is off, so Volar can't recognize speech on-device. Turn on Dictation (System Settings ▸ Keyboard) to keep everything private and offline — or use Apple's servers, which needs internet and sends your audio to Apple."
            print("[Volar.Speech] onError -> onDeviceUnavailable (needs Dictation or server consent)")
            captureState = .error
            return
        }
        let detail = (error as? SpeechCaptureError).map(Self.describe) ?? error.localizedDescription
        captureErrorDetail = detail
        print("[Volar.Speech] onError -> \(detail)")
        captureState = .error
    }

    /// `GroqEngine.onCloudUnavailable` lands here (403 `upgrade_required` / 429 `quota_exceeded`)
    /// instead of `handleCaptureError` — see that property's doc comment in `GroqEngine.swift`. The
    /// no-shame UI rule (FR-016/FR-036) makes this a routing decision, never a visible error:
    /// `captureState` must never become `.error` for either status.
    ///
    /// 1. Marks `groqDegradedThisSession` so `selectedEngine` stops retrying Groq for the rest of
    ///    this run (see that property's doc comment) — independent of whether the refresh below
    ///    actually observes the change, since a spent daily quota doesn't necessarily flip the
    ///    cached tier that `GroqEngine.isConfigured` reads.
    /// 2. Best-effort refreshes the entitlement cache via `Entitlements.shared.refreshStatus()` —
    ///    the same "refresh affordance" `SettingsView`/app-launch already use, not a new mechanism —
    ///    so `EnvironmentGroqCredentialProvider.isConfigured`'s cached tier stops being stale.
    /// 3. Only when WhisperKit is genuinely `.ready` does it salvage the just-recorded utterance by
    ///    handing Groq's temp audio file to it; on success this calls `groq.onFinal` — the SAME
    ///    closure `startCapture()` already wired for this session — so the salvaged transcript flows
    ///    through the exact normal `finishRecording` path exactly once, never a second/parallel one.
    /// 4. If salvage isn't possible (hardware/model not ready) or fails (empty/throws), the
    ///    recording is discarded and, if this session is still the current one and still sitting in
    ///    `.parsing` (where `stopCapture()` leaves it while Groq's upload is in flight), capture
    ///    quietly returns to `.idle` — never `.error`, and never left stuck on "Parsing…" forever.
    ///
    /// `session` is the `AppState.captureSession` token captured at `startCapture()` time (NOT
    /// `GroqEngine`'s own private `session` counter) — re-checked after every `await` below exactly
    /// like `onFinal`/`onError`'s own guards, so a `cancelCapture()`/a fresh capture superseding this
    /// one while this method is mid-flight can never resurrect or clobber state for a session the
    /// user has already moved on from.
    private func handleCloudSpeechUnavailable(session: Int, salvageAudioURL: URL) async {
        groqDegradedThisSession = true
        // Calm, developer-facing log line only — this product has no non-error notice channel
        // wired up yet (`IntentParsing.lastCloudQuotaNote` is the analogous parse-side signal and
        // is itself not consumed by any view today), so per the no-shame UI rule this prefers
        // silence over inventing a banner.
        print("[Volar.Speech] cloud unavailable (stale entitlement or quota) -> falling back on-device")
        _ = await Entitlements.shared.refreshStatus()

        guard captureSession == session, captureState == .parsing else { return }

        if WhisperKitEngine.isSupported, whisper.isModelReady,
           let text = try? await whisper.transcribe(audioPath: salvageAudioURL.path),
           !text.isEmpty {
            guard captureSession == session else { return }
            groq.onFinal?(text)
            return
        }

        guard captureSession == session, captureState == .parsing else { return }
        captureState = .idle
        liveTranscript = ""
    }

    /// Turns a `SpeechCaptureError` into a user-facing message for `captureErrorDetail` — surfaces
    /// the real failure reason instead of the generic "Didn't catch that." copy (see
    /// `PopoverView`'s `.error` state).
    private static func describe(_ e: SpeechCaptureError) -> String {
        switch e {
        case .recognizerUnavailable: return "Speech recognizer unavailable on this Mac"
        case .authorizationDenied: return "Microphone or Speech permission denied"
        case .recognitionFailed(let msg): return msg
        // The onError handler above sets a longer, actionable message for this case directly;
        // this branch only exists so the switch stays exhaustive.
        case .onDeviceUnavailable: return "On-device speech recognition is unavailable (Dictation is off)"
        }
    }

    func cancelCapture() {
        captureSession += 1 // invalidate any authorization-pending start
        captureState = .idle
        liveTranscript = ""
        confirmDrafts = []
        confirmUpdateDrafts = []
        confirmCycle = nil
        voiceDoneConfirm = nil
        voiceDoneNoMatchTranscript = nil
        pendingCloudConsent = false
        pendingParseTranscript = nil
        // FIX 2a (privacy seam): `.stop()` means "finish and deliver" — Groq would still upload the
        // in-flight audio and a late `onFinal` could pop a confirm card after Esc. `.cancel()`
        // immediately abandons capture and discards the audio; neither `onFinal` nor `onError` fires
        // for it (the `captureSession` guard on both closures in `startCapture()` is defense-in-depth
        // on top of that contract, not a substitute for it).
        runningEngine?.cancel()
        runningEngine = nil
    }

    /// Stops an in-progress capture (called from `toggleCapture()`'s "stop" branch). If
    /// recognition is actually running, this just ends the utterance (`SpeechCapture.stop()`
    /// flushes one final result -> `finishRecording`). If the mic never started — authorization
    /// was still pending — it invalidates the deferred start and backs out to `.idle` so the mic
    /// is never left hot. Additive method; the frozen §4 surface (`startCapture`/`cancelCapture`)
    /// is untouched.
    func stopCapture() {
        if let engine = runningEngine, engine.isRunning {
            // FIX 1: `SpeechCapture.stop()` sets `isRunning = false` SYNCHRONOUSLY
            // (SpeechCapture.swift:308) but the final transcript still arrives async via
            // `onFinal`. This used to only flip to `.parsing` for a batch engine
            // (`!supportsPartialResults`), so a partial-results engine (Apple) stayed stuck in
            // `.recording` for that whole gap. A second `stopCapture()` call landing in that
            // window then fell through to the `else if captureState == .recording` branch below,
            // which bumps `captureSession` — invalidating the very session `onFinal`'s guard
            // checks — and silently swallowed the transcript. `.parsing` is the correct state for
            // EVERY engine here: it means "mic is off, waiting on the final result," which is
            // just as true with partial results as without. It is also what disarms the second
            // call: with `isRunning` already false AND `captureState` no longer `.recording`,
            // neither branch matches, so `stopCapture()` becomes a clean no-op that leaves the
            // in-flight session intact instead of taking the destructive `else if`.
            captureState = .parsing
            engine.stop()
        } else if captureState == .recording {
            captureSession += 1
            captureState = .idle
            liveTranscript = ""
        }
    }

    /// Toggle voice capture (⌃⌥M hotkey and the on-screen mic buttons use this): if we're
    /// recording, stop and let the final transcript flow into parsing; otherwise start a fresh
    /// capture. Additive — frozen §4 `startCapture`/`cancelCapture` untouched.
    func toggleCapture() {
        if captureState == .recording {
            stopCapture()
        } else {
            startCapture()
        }
    }

    /// The REAL "user pressed the hotkey / tapped the create-task button" entry point — ⌃⌥M
    /// (`HotkeyManager`), the sidebar mic button, and the morning-frog voice CTA all route here
    /// instead of `toggleCapture()` above (kept as-is for whatever else still calls it directly;
    /// see call-site notes in `HotkeyManager.swift`/`Sidebar.swift`/`MorningFrogView.swift`).
    ///
    /// `toggleCapture()`'s plain two-way branch (`.recording` -> stop, everything else -> start)
    /// has no case for "a confirm card is already up": pressing the hotkey again while
    /// `captureState == .parsed` used to blow the pending confirm away and open a brand-new
    /// recording session instead of doing what a user pressing "the capture key" again obviously
    /// means — save what's already parsed. This method fixes exactly that, and adds the guard the
    /// old code never had: several other states are ALSO a pending yes/no question the hotkey must
    /// never silently answer for the user (constitution II) —
    /// `voiceDoneConfirm`/`voiceDoneNoMatchTranscript` (T036's glance-and-dismiss voice-done card)
    /// and `pendingCloudConsent`/`pendingServerConsent` (the one-time privacy opt-ins, both of
    /// which reuse `captureState == .error` as their prompt surface — see those properties' own
    /// doc comments). None of those four are things "press capture again" should resolve, so this
    /// bails out before even looking at `captureState` when any of them is active.
    func handleHotkey() {
        // Mutual exclusion with the typed-capture popup (⌃⌥T, `openTextCapture()` below): pressing
        // ⌃⌥M while that popup is open closes it first — "whichever hotkey the user pressed wins"
        // (task brief). Falls through to the exact same guard/switch below afterward, so ⌃⌥M's own
        // toggle semantics are completely unchanged by this; it only ever adds "and also close the
        // OTHER capture surface first" as a side effect when there's something to close.
        if textCapture != .closed {
            cancelTextCapture()
        }

        guard voiceDoneConfirm == nil,
              voiceDoneNoMatchTranscript == nil,
              !pendingCloudConsent,
              !pendingServerConsent
        else { return }

        switch captureState {
        case .recording:
            stopCapture()
        case .parsed:
            confirmSave()
        case .parsing, .saving:
            // Mid-flight — nothing sane to toggle to; a stray hotkey press here is a no-op rather
            // than racing `finishRecording`/`confirmSave`.
            break
        case .idle, .done, .error:
            startCapture()
        }
    }

    // MARK: - Typed capture (⌃⌥T) — "type one line, hit Add task, done."
    //
    // Voice capture's pipeline (unchanged, see above): `finishRecording` -> `proceedToCapture`
    // (one-time cloud-parse consent gate) -> `runParse` (parses, builds `confirmDrafts`) ->
    // user reviews the confirm card -> `confirmSave()` commits (batching / `store.addBatch`
    // chunking / `tasks = store.fetchAll()` / `notifyEligibilityAndScheduleResurface` /
    // `scheduleRemindersForSavedItems` / `syncCalendarMirror` / `finishSaveUI`). The typed flow
    // below shares that exact same `buildConfirmDrafts`/`confirmSave()` pipeline — parse -> build
    // `confirmDrafts` the way `runParse` does -> either save immediately (the genuinely simple
    // case: one task, no duplicate hint, no condition of any kind) or hand off to the SAME
    // confirm-card review the voice flow uses (2026-07-28, Việc 4 — see
    // `applyTextCaptureParseResult`'s own doc comment for exactly which case is "simple" and why).
    // Either way this reuses `confirmSave()` verbatim (not a parallel save path) when it does
    // save — every side effect `confirmSave()` produces for a voice save (reminders scheduled,
    // calendar mirror synced, eligibility/resurface diff computed, `TaskStore.maxBatchSize`-
    // chunked `addBatch` commits) happens exactly the same way for a typed save.

    /// Opens the typed-capture popup. ⌃⌥T (`HotkeyManager`) is the only real caller.
    func openTextCapture() {
        // Mutual exclusion (task brief: "whichever hotkey the user pressed wins" — never show
        // both capture surfaces at once): opening the typed popup while ANY voice-side surface is
        // pending — an in-progress recording, a parsed-but-unsaved confirm card, a voice-done
        // confirm, or a cloud/server consent prompt — tears all of it down uniformly via the
        // existing `cancelCapture()` (see that method's own doc comment for the exact list it
        // clears). `captureState != .idle` is true for every one of those cases, so this single
        // check covers all of them without re-deriving the list here.
        if captureState != .idle {
            cancelCapture()
        }
        textCaptureSession += 1
        textCapture = .editing
        textCaptureInput = ""
    }

    /// Esc, or ⌃⌥M stealing the surface back (`handleHotkey()` above) — closes the popup and
    /// discards whatever was typed. Bumping `textCaptureSession` invalidates any parse still in
    /// flight from a `submitTextCapture()` call the user is backing out of (see that method's
    /// stale-result guard).
    func cancelTextCapture() {
        textCaptureSession += 1
        textCapture = .closed
        textCaptureInput = ""
    }

    // MARK: - ⌘K command bar (`Sources/Views/CommandBar.swift`) — a second, in-window entry point
    // into the SAME typed-capture pipeline as ⌃⌥T above; see that file's header comment for the
    // full reuse chain. `showCommandBar` (declared above, near `detailTaskID`) is presentation-only.

    /// Opens the ⌘K overlay. Applies the same "whichever surface the user reaches for wins" mutual-
    /// exclusion rule `openTextCapture()` above already applies between ⌃⌥M and ⌃⌥T: tears down an
    /// in-progress voice capture or an already-open ⌃⌥T popup first, so ⌘K never has to share the
    /// screen with a stray floating panel/confirm card it didn't ask for. In practice this is rarely
    /// live — `CommandBar` closes itself the instant it submits (see that file) — but it's the same
    /// defensive guard `openTextCapture()` takes for the identical reason, not new behavior invented
    /// for this flag.
    func openCommandBar() {
        if captureState != .idle {
            cancelCapture()
        }
        if textCapture != .closed {
            cancelTextCapture()
        }
        showCommandBar = true
    }

    /// Esc, or a submit that just fired (`CommandBar.submit()`) — closes the ⌘K overlay. Deliberately
    /// does NOT touch `textCaptureInput`/`textCapture`: `CommandBar` keeps its own local draft text
    /// and only ever writes into `textCaptureInput` right before calling `submitTextCapture()` — see
    /// that view's header comment for why closing this flag first (rather than lingering to show its
    /// own Saving/Saved/Failed state) is what keeps ⌘K from fighting the existing floating ⌃⌥T panel
    /// over the same `textCapture` transitions.
    func closeCommandBar() {
        showCommandBar = false
    }

    /// Parses `textCaptureInput` and saves it — the typed equivalent of the voice flow's
    /// `finishRecording` -> `runParse` -> (review pause) -> `confirmSave()`. Skips the review
    /// pause ONLY for the genuinely simple case (see this section's header comment and
    /// `applyTextCaptureParseResult`'s own doc comment for exactly which case that is, 2026-07-28
    /// Việc 4); anything more complex hands off to the same review pause the voice flow uses.
    /// Sync entry point; the actual parse is async, so
    /// this hops through `_Concurrency.Task { @MainActor in ... }` exactly like `runParse` does,
    /// with the same before-the-`await` session-token capture/guard pattern (`textCaptureSession`,
    /// mirroring `captureSession`) so a user who hits Esc mid-parse can never have a stale result
    /// land back on a popup they've already closed/reopened.
    ///
    /// CLOUD CONSENT (2026-09-06: no longer a difference from the voice path). This method has
    /// always called `router.parse` directly, on the grounds that a tiny "type one line" popup is
    /// the wrong surface to interrupt with a privacy decision. Voice used to differ — it paused on
    /// a one-time consent prompt — but `proceedToCapture` no longer does, so both entry points now
    /// behave identically: parse straight away, cloud by default. `IntentRouter` still applies its
    /// own `cloudGate.isOptedIn()` (+ `isOnline()`) gate internally regardless of caller (see
    /// `IntentRouter.parse` in `IntentParsing.swift`), so a user who has explicitly opted OUT in
    /// Settings/onboarding still gets on-device parsing here and their text still never leaves the
    /// machine.
    func submitTextCapture() {
        // Defensive: the "Add task" button/`.onSubmit` are both disabled/no-ops while `.saving`
        // per `TextCaptureView`, but this guards the method itself against a double-submit race
        // (e.g. Return arriving a frame after a click already started saving).
        guard textCapture != .saving else { return }
        let trimmed = textCaptureInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        textCapture = .saving
        textCaptureSession += 1
        let session = textCaptureSession
        let now = clock()
        let titles = openTasks.map(\.title)

        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            let results = await self.router.parse(trimmed, now: now, openTaskTitles: titles)
            self.applyTextCaptureParseResult(results, session: session)
        }
    }

    /// The synchronous back half of `submitTextCapture()` — split out from the `await
    /// router.parse(...)` call above SPECIFICALLY so it's directly unit-testable without awaiting
    /// a real (async, even if not truly network-bound for the on-device tiers) parse call, same
    /// precedent as `resolveCloudMatch` elsewhere in this file (see that method's own doc comment).
    /// Tests can simulate "the parse came back with N results" or "the session went stale before
    /// the parse returned" by calling this directly with a hand-built `[ParsedTask]` and/or a
    /// stale `session` token, instead of needing a real `IntentRouter` round trip.
    ///
    /// Not `private` for exactly that reason — every OTHER piece of `submitTextCapture()`'s logic
    /// (the empty-input guard, the `.saving` re-entrancy guard, the session bump, the delayed
    /// auto-dismiss) is either trivially pure or already covered indirectly through this method,
    /// but the stale-session guard and the zero-drafts failure path specifically live here because
    /// they can only be exercised AFTER an (async) parse result exists.
    func applyTextCaptureParseResult(_ results: [ParsedTask], session: Int) {
        // Stale? Esc (`cancelTextCapture`) or a second submit happened while this parse was in
        // flight — mirrors `runParse`'s own `captureSession`/`captureState` guard exactly, just
        // against the text-capture counter/state instead of the voice ones.
        guard textCaptureSession == session, textCapture == .saving else { return }

        // Same construction `runParse` uses: cap to `TaskStore.maxBatchSize`, pre-resolve the
        // "easy" `.taskDone` conditions (intra-batch included, Việc 2), and compute the conflict
        // advisory + duplicate hint (Việc 3) ONCE against a single shared `conflictNow` clock read
        // shared by every draft in the batch (T074 — never recomputed per draft). Shared with
        // `runParse` via `buildConfirmDrafts` so the two entry points can't drift apart.
        let capped = Array(results.prefix(TaskStore.maxBatchSize))
        let conflictNow = clock()
        let drafts = buildConfirmDrafts(from: capped, conflictNow: conflictNow)

        guard !drafts.isEmpty else {
            // Never close the popup and silently lose what the user typed (task brief) — the
            // field stays populated (`textCaptureInput` untouched) so they can fix and retry. In
            // practice every current `IntentParser` tier guarantees a non-empty result for
            // non-empty input (`IntentRouter.parse`'s own floor fallback,
            // `Sources/Parsing/IntentParsing.swift`), same as `runParse`'s analogous branch — this
            // exists as the defensive floor for whatever a future parser tier might legitimately
            // fail to extract anything from, not a reachable path today.
            textCapture = .failed("Didn't catch that.")
            return
        }

        // Việc 4 (2026-07-28, task brief: "chỉ đi qua confirm khi phức tạp"): the typed popup's
        // whole pitch is "type -> Add task -> done" with NO review pause — but that pitch only
        // holds for the genuinely simple case. The instant there's more than one drafted task, a
        // possible duplicate (Việc 3), or ANY condition at all (including one only resolvable
        // intra-batch, Việc 2) the user is facing a real decision this tiny popup has no UI for
        // (no checkbox, no dependency picker, no merge choice) — silently auto-resolving it here
        // would be exactly the "guess instead of ask" constitution II forbids. So: hand off to the
        // SAME confirm-card review the voice flow already has instead.
        let isSimpleCase = drafts.count == 1
            && (drafts.first?.duplicateCandidates.isEmpty ?? false)
            && (drafts.first?.task.conditions.isEmpty ?? false)
        guard isSimpleCase else {
            // Populate `confirmDrafts` and flip `captureState` to `.parsed` — EXACTLY what
            // `runParse` does on a successful voice parse. `VolarApp.swift`'s existing
            // `observeCaptureState()`/`observeTextCaptureState()` pair (already wired, no view
            // changes needed here — see this method's header comment) reacts to both property
            // changes: closing the typed popup (`textCapture == .closed` hides it, mirroring
            // `cancelTextCapture()`) and presenting the voice popover's confirm-card review
            // (`captureState != .idle` shows it). This file only needs to set the two properties;
            // the mutual-exclusion plumbing (`syncCapturePanel()`/`syncTextCapturePanel()`)
            // already exists and requires no changes.
            confirmDrafts = drafts
            // `buildConfirmDrafts` is a pure helper with no `self` to recompute against, so this
            // call sits right where its result actually becomes the live `confirmDrafts` instead
            // — see `recomputeConfirmCycle`'s own doc comment. Without this, `confirmCycle` would
            // still hold whatever a PREVIOUS confirm session left it at.
            recomputeConfirmCycle()
            captureState = .parsed
            textCapture = .closed
            textCaptureInput = ""
            return
        }

        // THE REUSE: hand the exact same drafts `runParse` would have produced straight to
        // `confirmSave()` — no parallel materialize/save/schedule/sync logic lives here.
        // `confirmSave()` is synchronous end-to-end except its own trailing 900ms auto-dismiss
        // (`finishSaveUI`, guarded by `captureSession` — untouched by anything in this method), so
        // by the time this call returns, `captureState` already reflects the real outcome: `.done`
        // on success, or `.error` (with `captureErrorDetail` set) if `TaskStore.addBatch` rejected
        // the batch (e.g. a dependency cycle).
        let addedTitles = drafts.map(\.effectiveTitle)
        confirmDrafts = drafts
        // Same reasoning as the branch above: a lone zero-condition draft can never itself close
        // a cycle, but `confirmCycle` could still be stale from a previous session — and
        // `confirmSave()` (below) now refuses to save at all while `confirmCycle != nil` (§2), so
        // this recompute is load-bearing, not just hygiene.
        recomputeConfirmCycle()
        confirmSave()

        if captureState == .error {
            // A genuine `TaskStore` rejection (e.g. a dependency cycle) — surface it on the TEXT
            // popup instead, since the user never saw a voice surface for this save.
            // `textCaptureInput` is still untouched at this point (only cleared on the success
            // path below), so — same as the zero-drafts branch above — the field stays populated
            // for the user to fix and retry.
            textCapture = .failed(captureErrorDetail ?? "Couldn't save.")
            // `captureState == .error` here is purely an artifact of routing through the shared
            // voice-flow method — nothing about the voice popover should be left sitting in an
            // error state for a failure that surfaced through the TEXT popup instead (see the
            // mutual-exclusion note on `syncCapturePanel()` in `VolarApp.swift`: the voice panel
            // is suppressed the whole time `textCapture != .closed` regardless, but there is no
            // reason to also leave stale error state behind for whenever `textCapture` eventually
            // closes and voice capture becomes visible again).
            captureState = .idle
            captureErrorDetail = nil
            confirmDrafts = []
            // task_refs_v1: defensive symmetry only — this text-capture path never populates
            // `confirmUpdateDrafts` itself (only `runParse`, the voice path, does), and
            // `openTextCapture()` already tore any prior voice session down via `cancelCapture()`
            // before this method could even run. Cleared here anyway so this reset stays exhaustive
            // if that ever changes.
            confirmUpdateDrafts = []
            return
        }

        textCaptureInput = ""
        textCapture = .saved(titles: addedTitles)
        // Same delayed-dismiss convention `finishSaveUI` uses for the voice popover (900ms flash
        // before returning to the closed state), guarded by the SAME `textCaptureSession` token
        // captured above rather than a new timer mechanism.
        _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(nanoseconds: 900_000_000)
            guard let self, self.textCaptureSession == session else { return }
            self.textCapture = .closed
        }
    }

    /// Opens System Settings so the user can enable Dictation (which downloads the on-device
    /// speech model). Pane URL differs across macOS versions; falls back to opening System
    /// Settings generally.
    func openDictationSettings() {
        #if os(macOS)
        let candidates = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard"
        ]
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
        #elseif os(iOS)
        // iOS has no deep link into the system Dictation pane (unlike macOS's
        // x-apple.systempreferences: scheme) — the correct fallback is Volar's own Settings
        // page, which is where the on-device/server-recognition consent toggle actually lives.
        // UNVERIFIED: UIApplication.openSettingsURLString opens THIS APP's Settings page in the
        // iOS Settings app (system-provided, not Volar's in-app SettingsIOSView) — verified
        // against Apple's documented constant name; behavior not runnable on this machine.
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    /// User consented to Apple server recognition. Persist it and immediately retry capture.
    func useServerRecognition() {
        allowServerRecognition = true
        UserDefaults.standard.set(true, forKey: Self.allowServerRecognitionKey)
        pendingServerConsent = false
        startCapture()
    }

    /// Change the speech-recognition language (Settings ▸ Language). Persists and applies live to
    /// BOTH engines: `speech` (Apple/WhisperKit path) gets a concrete `Locale`, `groq` gets the
    /// matching ISO-639-1 `languageCode` — `id == autoRecognitionLocaleID` resolves to
    /// `Locale.current` / `nil` respectively so each engine auto-detects instead.
    func setRecognitionLocale(_ id: String) {
        recognitionLocaleID = id
        UserDefaults.standard.set(id, forKey: Self.recognitionLocaleKey)
        speech.setLocale(Self.appleRecognitionLocale(for: id))
        groq.languageCode = Self.groqLanguageCode(for: id)
    }

    /// Change the transcription engine (Settings). Persists; picking WhisperKit on Apple Silicon
    /// kicks off the one-time model download/load so it's ready by the next capture.
    func setSpeechEngine(_ choice: SpeechEngineChoice) {
        speechEngineChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: Self.speechEngineKey)
        if choice == .whisperKit, WhisperKitEngine.isSupported {
            _Concurrency.Task { await whisper.prepare() }
        }
    }

    /// Local↔cloud parsing switch surfaced in Settings. Reads the SAME `cloudParseConsent` the
    /// router's Cloud tier is already gated on (`DefaultCloudParseGate`), so this is purely a
    /// friendlier presentation of that one bit — no second source of truth.
    ///
    /// Cloud-first default (same product decision as `speechEngineChoice`'s `init` fallback
    /// above): `cloudParseConsent == nil` — NEVER asked, e.g. an install that predates the
    /// onboarding cloud-consent step, or a corrupted/cleared default — now reads as `.cloud`
    /// instead of `.onDevice`. An EXPLICIT decision is untouched either way: `false` (the user
    /// affirmatively declined, either via the voice-capture consent popover's "no" or by picking
    /// on-device in Settings) still reads `.onDevice`; `true` still reads `.cloud`. So this is a
    /// three-way match, not a `== true` binary check — flip only the `nil` case.
    ///
    /// IMPORTANT — this is a DISPLAY default only, not a consent bypass: `parseEnginePreference`
    /// is read by `SettingsView`'s picker, never by the actual gate. The real gate a `nil` value
    /// still trips is `proceedToCapture`'s `guard cloudParseConsent != nil` (below) — an
    /// un-consented user still sees the one-time cloud-parse consent prompt before the FIRST
    /// parse, and `DefaultCloudParseGate.isOptedIn()` (bottom of file) still reads the literal
    /// persisted `UserDefaults` bool, which defaults `false` for an unset key regardless of what
    /// this computed property displays. So a user who has never actually answered the consent
    /// question sees "Cloud" pre-highlighted here (matching the new onboarding default) but Cloud
    /// is still never ATTEMPTED until they explicitly consent somewhere (onboarding's new step,
    /// the in-flow popover, or this same Settings picker) — no opt-in principle is bypassed.
    var parseEnginePreference: ParseEnginePreference {
        cloudParseConsent == false ? .onDevice : .cloud
    }

    /// Change the parsing engine from Settings. Persists to the existing `cloudParseConsentKey` so
    /// the router's Cloud gate picks it up immediately and the one-time voice-capture consent
    /// popover never re-appears once the user has made a Settings choice. Picking `.cloud` is
    /// itself the informed opt-in — the Settings row's hint states cloud parsing sends only the
    /// TEXT (never audio) of the utterance to our proxy.
    func setParseEngine(_ preference: ParseEnginePreference) {
        let allow = (preference == .cloud)
        cloudParseConsent = allow
        UserDefaults.standard.set(allow, forKey: Self.cloudParseConsentKey)
    }

    /// Not part of the frozen §4 method list, but required to actually drive
    /// `.recording -> .parsing -> .parsed`: Phase-2 `SpeechCapture` calls this once the
    /// on-device transcript settles. A pure addition — `startCapture`/`cancelCapture`/
    /// `confirmSave` keep their exact frozen signatures.
    ///
    /// T025: routes the parse itself through `IntentRouter` (replaces the v1 direct
    /// `HeuristicNLParser` call) — gated by the one-time cloud-parse consent sheet (T024) the
    /// FIRST time this ever runs, per contract R5 ("Cloud ... IF: user opted in").
    func finishRecording(transcript: String) {
        liveTranscript = transcript
        // T036 (phase5-contract.md §C): classify BEFORE treating this as new-task capture.
        // `voiceDoneOpenTasks` is rebuilt fresh from the live `tasks` snapshot on every call (never
        // cached) so a completion classified here always reflects the CURRENT open-task list, and
        // is always exactly the user's own tasks (self-review "security" — no cross-user/global
        // data reaches `VoiceDone`).
        switch voiceDone.classify(transcript, openTasks: voiceDoneOpenTasks) {
        case .complete(let candidates) where candidates.isEmpty:
            // T0xx: local Jaccard matching found the "xong/done" cue but nothing above the floor —
            // try a cloud semantic-paraphrase rescue before giving up (see
            // `resolveCompletionViaCloud`'s header comment). Every non-empty case below this one is
            // untouched: local matches are never second-guessed by a network round trip.
            resolveCompletionViaCloud(action: .complete, kind: .complete, transcript: transcript)
        case .complete(let candidates):
            presentVoiceDoneConfirm(action: .complete, candidates: candidates)
        case .clearExternal(let candidates) where candidates.isEmpty:
            resolveCompletionViaCloud(action: .clearExternal, kind: .clearExternal, transcript: transcript)
        case .clearExternal(let candidates):
            presentVoiceDoneConfirm(action: .clearExternal, candidates: candidates)
        case .notACompletion:
            // Existing Phase-3 new-task confirm flow, unchanged.
            proceedToCapture(transcript: transcript)
        }
    }

    /// The pre-existing Phase-3 new-task confirm flow (one-time cloud-parse consent gate ->
    /// `runParse`), split out of `finishRecording` so `captureVoiceDoneAsNewTask()` (the "no
    /// matching task, capture instead" escape hatch, T036) can resume the SAME transcript through
    /// the exact same gate rather than duplicating it.
    private func proceedToCapture(transcript: String) {
        // anh Khôi chốt 2026-09-06: cloud parsing is the default for EVERY entry point, so the
        // one-time consent pause is gone — voice now behaves exactly like typed capture always
        // has (see `submitTextCapture`'s own "CLOUD-CONSENT DIFFERENCE" note, which this change
        // resolves by making both paths identical). Opting OUT is still fully supported and still
        // honoured on every path: Settings ▸ parse engine / the onboarding toggle write `false` to
        // `cloudParseConsentKey`, which `DefaultCloudParseGate.isOptedIn()` reads before any
        // request leaves the device. `pendingCloudConsent` and `resolveCloudConsent` are kept (and
        // still wired in `PopoverView`/`CaptureSheet`) but are no longer reachable from this path.
        runParse(transcript: transcript)
    }

    // MARK: - T036: voice-done confirm (contract A/C)

    /// T036 (contract A `VoiceDoneTask`): id/title + each task's UNSATISFIED `.external`
    /// descriptions only (a satisfied one is nothing left for a "client đã ký"-style utterance to
    /// clear). Rebuilt fresh from `openTasks` every `finishRecording` call.
    private var voiceDoneOpenTasks: [VoiceDoneTask] {
        openTasks.map { task in
            VoiceDoneTask(
                id: task.id,
                title: task.title,
                externalDescriptions: task.conditions.compactMap { condition in
                    if case .external(let description, let satisfied) = condition, !satisfied { return description }
                    return nil
                }
            )
        }
    }

    /// Routes a `.complete`/`.clearExternal` classification into the glance-and-dismiss confirm
    /// surface — one confident candidate -> one-tap/one-word confirm; several -> a bounded
    /// disambiguation list (constitution II: multiple matches ALWAYS disambiguate, never guess);
    /// ZERO -> STATE "no matching task" and offer capture instead (never silently fall through to
    /// a guess, and never silently fall through to new-task capture either — the user must
    /// explicitly choose that). `captureState = .parsed` reuses the existing non-idle/non-error
    /// state; `PopoverView` gates its OWN voice-done card on `voiceDoneConfirm`/
    /// `voiceDoneNoMatchTranscript` being non-nil rather than on this state value, so this is just
    /// "not idle, not error, not recording" bookkeeping consistent with the rest of the enum.
    private func presentVoiceDoneConfirm(action: VoiceDoneAction, candidates: [VoiceMatch]) {
        guard !candidates.isEmpty else {
            voiceDoneNoMatchTranscript = liveTranscript
            captureState = .parsed
            return
        }
        // Defensive cap (self-review "client-exploit"): disambiguation stays bounded even against
        // a hostile/corrupted matcher result — mirrors `runParse`'s own defense-in-depth cap.
        voiceDoneConfirm = VoiceDoneConfirm(action: action, candidates: Array(candidates.prefix(10)))
        captureState = .parsed
    }

    // MARK: - T0xx: cloud completion-paraphrase rescue (empty-candidate case only)
    //
    // `VoiceDone.classify` detects a "xong"/"done"/"hoàn thành" cue and Jaccard-matches the rest of
    // the utterance against open-task titles. A paraphrase ("xong cái vụ report rồi" vs. the real
    // title "Viết báo cáo Q3") shares no tokens and scores 0.0 — `VoiceDone` correctly reports
    // "cue present, nothing matched" as EMPTY candidates (not `.notACompletion`; see
    // `VoiceDoneIntent`'s own doc comment). `finishRecording`'s switch above routes exactly that
    // empty-candidates outcome here instead of straight to `presentVoiceDoneConfirm`, so a cloud
    // semantic-match gets one shot before the user has to complete the task by hand.
    //
    // Quota/consent (self-review point 5): this is the ONLY call site for
    // `IntentRouter.resolveCompletion`, and it is reached ONLY from the two empty-candidates switch
    // arms above — a local match (any non-empty candidate list) never pays a round trip or a quota
    // unit. `IntentRouter.resolveCompletion` itself re-applies the same `cloudGate.isOptedIn()` +
    // `isOnline()` gate `parse` uses, so an un-opted-in user never has a transcript leave the Mac
    // here either.

    /// Confidence bar for a CLOUD-resolved completion match. This is a MODEL-PROBABILITY scale (the
    /// LLM's own reported confidence that its chosen `matchIndex` is correct) — it is deliberately
    /// NOT `VoiceDone.highConfidenceThreshold`, which lives on the JACCARD TOKEN-OVERLAP scale (the
    /// fraction of shared tokens between transcript and title). The two numbers measure different
    /// things on different scales and are never comparable or interchangeable; this constant exists
    /// specifically so nobody is tempted to reuse `VoiceDone.highConfidenceThreshold` here instead.
    /// Not `private` — `resolveCloudMatch` below is exposed for direct unit-testing and tests
    /// reference this constant rather than duplicating the literal.
    static let cloudCompletionConfidenceThreshold = 0.7

    /// `finishRecording`'s `.complete`/`.clearExternal` cases call this INSTEAD of
    /// `presentVoiceDoneConfirm` directly when local Jaccard matching (`VoiceDone`) came back with
    /// ZERO candidates. Cloud is asked to semantically match the utterance against the SAME
    /// open-task titles the local matcher already tried and failed on. A decline/failure/low-
    /// confidence/mismatched-echo/stale-session result all fall through to exactly today's
    /// behavior — `presentVoiceDoneConfirm(action:candidates: [])`, i.e. "no matching task, offer
    /// capture instead." No new UI, no new error banner, no new alert.
    ///
    /// Never marks a task done automatically (self-review point 4): every exit path below either
    /// hands a SINGLE resolved `VoiceMatch` to the EXISTING `presentVoiceDoneConfirm` (same one-tap
    /// confirm the local-match path already uses) or hands it an empty list — there is no path here
    /// that calls `toggleDone`/`confirmVoiceDone` or otherwise mutates a task directly.
    private func resolveCompletionViaCloud(action: VoiceDoneAction, kind: CloudParser.CompletionKind, transcript: String) {
        // Snapshot taken ONCE, before the network call (self-review point 3): the candidate titles
        // sent to Cloud and the task ids resolved back out of the response MUST come from the exact
        // same read of `openTasks`. Rebuilding after the `await` would let a reminder firing or a
        // sync landing mid-flight shift task ordering/membership, so `matchIndex` could end up
        // pointing at a DIFFERENT task than the one the model actually saw. `snapshot` is capped at
        // 100 entries up front (matching `CloudParser.resolveCompletion`'s own internal cap) so the
        // bounds this method re-checks below (`1...snapshot.count`) are checking against the exact
        // same list whose titles were actually put on the wire — not a longer, uncapped list that
        // would let an in-range server index silently resolve against the wrong local task.
        let snapshot: [(id: UUID, title: String)] = Array(openTasks.prefix(100)).map { ($0.id, $0.title) }
        guard !snapshot.isEmpty else {
            presentVoiceDoneConfirm(action: action, candidates: [])
            return
        }

        // Concurrency (self-review point 2): `finishRecording` is synchronous but resolution is
        // async, so this hops through `_Concurrency.Task { @MainActor in ... }` — the same pattern
        // `runParse` uses immediately below for the analogous new-task-parse round trip.
        // `captureState = .parsing` keeps the UI from looking frozen on a stale state during the
        // round trip; `captureSession` is bumped and captured BEFORE the `await` (stale-result
        // guard) so a user who cancels and immediately re-records can never have THIS utterance's
        // cloud match presented against the NEW recording — every exit path below either calls
        // `presentVoiceDoneConfirm` (which sets `captureState = .parsed`, a sane terminal state) or,
        // on a stale session, returns without touching `captureState` at all (the superseding
        // action already put it wherever it needs to be) — never leaves it stuck in `.parsing`.
        captureState = .parsing
        captureSession += 1
        let session = captureSession
        let now = clock()
        let titles = snapshot.map(\.title)

        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            let resolution = await self.router.resolveCompletion(transcript, now: now, kind: kind, candidates: titles)
            // Stale? Cancel/a fresh capture/anything else that bumps `captureSession` happened
            // while the cloud round trip was in flight — drop this result entirely rather than
            // presenting a match for an utterance the user already walked away from (mirrors
            // `runParse`'s identical guard).
            guard self.captureSession == session, self.captureState == .parsing else { return }

            guard let match = Self.resolveCloudMatch(resolution, snapshot: snapshot) else {
                // `.none` (model looked, found nothing), `.unavailable` (never got a trustworthy
                // answer), or a failed local safety check — all degrade identically to today's "no
                // matching task" outcome. See `CloudParser.CompletionResolution`'s doc comment for
                // why the transport layer keeps `.none`/`.unavailable` distinct even though this
                // call site does not.
                self.presentVoiceDoneConfirm(action: action, candidates: [])
                return
            }
            // Single resolved match still goes through the EXISTING one-tap confirm card — the
            // user confirms with one tap/word exactly as they would for a local match.
            self.presentVoiceDoneConfirm(action: action, candidates: [match])
        }
    }

    /// Pure decision logic for `resolveCompletionViaCloud`'s safety checks — split out as a
    /// `static` function (not `private`) so it is unit-testable directly, without spinning up a
    /// live `AppState`/`IntentRouter`/network stack (mirrors the file's existing `nonisolated
    /// static` helper convention, e.g. `IntentRouter.cap`/`isValidBreakdown` in
    /// `IntentParsing.swift`, for the same testability reason).
    ///
    /// Off-by-one (self-review point 1): `resolution`'s `index` is the wire's 1-BASED position.
    /// The ONLY conversion to a 0-based array index happens right here, at `snapshot[index - 1]` —
    /// `index == 1` picks `snapshot[0]`, the FIRST candidate, matching the locked contract
    /// ("`candidates[matchIndex - 1]` is the chosen title"). Every other touch point in this
    /// feature (`CloudParser.resolveCompletion`, `IntentRouter.resolveCompletion`) passes `index`
    /// through unchanged — this is deliberately the single place the arithmetic happens, so there
    /// is exactly one place to audit for the off-by-one class of bug this task calls out by name.
    ///
    /// Applies TWO independent safety checks before trusting a server-reported match, plus the
    /// confidence bar, and returns `nil` (⇒ caller treats identically to "no candidates") unless
    /// ALL of the following hold:
    ///   1. `confidence >= cloudCompletionConfidenceThreshold` (model-probability scale, see that
    ///      constant's own doc comment).
    ///   2. `index` is in `1...snapshot.count` — re-checked here even though `CloudParser` already
    ///      validated it against the list length it sent, because `snapshot` (this call's own
    ///      local state) is never trusted to still agree with what the server saw without a fresh,
    ///      local bounds check (constitution II: never trust a remote response transitively).
    ///   3. `title` (the model's verbatim echo of the title it chose) matches, after trimming,
    ///      `snapshot[index - 1].title` exactly. A disagreement means the model hallucinated/
    ///      misindexed — or a candidate title was UTF-16-truncated before being sent (see
    ///      `CloudParser.resolveCompletion`'s 200-unit-per-title cap) and the model echoed back the
    ///      truncated form. Either way this is treated as NO match, never as "trust whichever of
    ///      the two disagreeing values looks more plausible" — the failure mode is a false
    ///      negative (falls back to "no matching task," never wrong), not a false positive.
    static func resolveCloudMatch(
        _ resolution: CloudParser.CompletionResolution,
        snapshot: [(id: UUID, title: String)]
    ) -> VoiceMatch? {
        guard case .resolved(let index, let title, let confidence) = resolution else { return nil }
        guard confidence.isFinite, confidence >= cloudCompletionConfidenceThreshold else { return nil }
        // Bounds check written as two plain comparisons, not `(1...snapshot.count).contains(index)`:
        // `ClosedRange(1...0)` (an empty `snapshot`) TRAPS at range construction before `.contains`
        // ever runs. `resolveCompletionViaCloud` never calls this with an empty snapshot (guarded
        // before the network call), but this function is `static` specifically so it's exercised
        // directly from unit tests too — it must not crash on a malicious/malformed input the caller
        // didn't happen to pre-filter.
        guard index >= 1, index <= snapshot.count else { return nil }
        let expected = snapshot[index - 1] // the ONE off-by-one conversion point, see doc comment above
        guard expected.title.trimmingCharacters(in: .whitespacesAndNewlines)
                == title.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // `VoiceMatch.score` is documented (`VoiceDone.swift`) as a Jaccard token-overlap value in
        // [0, 1]; there is no separate field to carry a match's provenance (local-Jaccard vs.
        // cloud-model-confidence). Both are already bounded to [0, 1] so this never breaks any
        // existing consumer's range assumptions, but it IS a different scale under the same field
        // — flagged here since this is the one place that substitution happens, and `VoiceDone.swift`
        // itself (out of scope for this change) is not touched.
        return VoiceMatch(taskId: expected.id, title: expected.title, score: confidence)
    }

    /// User tapped the one-tap confirm, or picked one candidate from the disambiguation list.
    /// `.complete` routes through `toggleDone` — the SAME funnel every other completion source
    /// uses (T037/FR-020: one consolidated completion+advance path, no divergent refresh logic) —
    /// which already appends the `CompletionEvent`, cancels reminders, and refreshes `tasks`
    /// atomically so `MenuBarLabel`'s `activeTask` advances with no intermediate empty/list state.
    /// `.clearExternal` clears the condition instead (never a completion — no `CompletionEvent`),
    /// per the contract's explicit "or clear the `.external` condition" wording.
    func confirmVoiceDone(taskId: UUID) {
        guard let confirm = voiceDoneConfirm else { return }
        let action = confirm.action
        // Cleared FIRST — mirrors `finishSaveUI`'s "empty the source of truth before the async
        // tail" convention, so a stray double-tap on the (about-to-vanish) confirm button can't
        // re-fire this (self-review "client-exploit": completion is idempotent — once cleared,
        // there is no pending confirm left for a second tap to act on).
        voiceDoneConfirm = nil
        switch action {
        case .complete:
            toggleDone(taskId)
        case .clearExternal:
            clearExternalCondition(taskId: taskId, now: clock())
        }
        finishVoiceDoneUI(action: action)
    }

    /// Glance-and-dismiss "not this" / cancel — leaves every task untouched (constitution II: a
    /// declined confirm must never partially act). Also used as the no-match row's "Dismiss".
    func dismissVoiceDoneConfirm() {
        captureSession += 1
        voiceDoneConfirm = nil
        voiceDoneNoMatchTranscript = nil
        captureState = .idle
        liveTranscript = ""
        // FIX 2a (privacy seam): same rationale as `cancelCapture()` above — this is a decline/
        // dismiss path, not a "give me the final transcript" path, so it must not leave Groq
        // uploading audio (or any engine still capturing) behind it.
        runningEngine?.cancel()
        runningEngine = nil
    }

    /// The "no matching task" escape hatch (constitution II: zero matches states it, then offers
    /// capture — never guesses). Resumes the original transcript through the exact same
    /// consent-gated path a normal `.notACompletion` capture would take.
    func captureVoiceDoneAsNewTask() {
        guard let transcript = voiceDoneNoMatchTranscript else { return }
        voiceDoneNoMatchTranscript = nil
        proceedToCapture(transcript: transcript)
    }

    /// T036 `.clearExternal`: clears the FIRST unsatisfied `.external` condition on `taskId` — see
    /// `TaskStore.clearFirstExternalCondition`'s doc comment for why "first" (contract A's
    /// `VoiceMatch` only resolves to a task id, not which specific external description matched).
    /// Mirrors `deleteTask`'s pattern of reusing the store's own already-computed eligibility diff
    /// instead of a second `notifyEligibilityAndScheduleResurface` pass (self-review "performance").
    private func clearExternalCondition(taskId: UUID, now: Date) {
        guard let store else {
            // No-store fallback (previews/tests without a TaskStore) — mirrors `triageDefer`'s own
            // no-store branch: in-memory only, no eligibility/reminder side effects to drive.
            guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
            guard let conditionIndex = tasks[index].conditions.firstIndex(where: {
                if case .external(_, let satisfied) = $0 { return !satisfied }
                return false
            }), case .external(let description, _) = tasks[index].conditions[conditionIndex] else { return }
            tasks[index].conditions[conditionIndex] = .external(description: description, satisfied: true)
            return
        }
        let newlyEligible = store.clearFirstExternalCondition(on: taskId, now: now)
        tasks = store.fetchAll()
        // WG-1: this task's own condition state just changed — re-derive its reminders, same as
        // `triageDefer` does after adding a condition.
        scheduler?.scheduleReminders(taskId: taskId)
        if !newlyEligible.isEmpty {
            scheduler?.notifyUnblocked(taskIds: newlyEligible)
        }
        resumeParkedTaskIfUnblocked(newlyEligible)
        scheduleNextResurface(from: tasks.map { $0.snapshot() }, now: now)
    }

    /// Shared "flash a result + auto-dismiss" tail for `confirmVoiceDone` — mirrors
    /// `finishSaveUI`'s timing/guard convention exactly (900ms flash, `captureSession`-guarded so a
    /// superseded flash never clobbers a fresh capture already in flight).
    private func finishVoiceDoneUI(action: VoiceDoneAction) {
        captureState = .done
        runningEngine?.stop()
        let spoken: String
        switch action {
        case .complete: spoken = "Done."
        case .clearExternal: spoken = "Cleared."
        }
        voice.speak(spoken)
        captureSession += 1
        let session = captureSession
        _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(nanoseconds: 900_000_000)
            guard let self, self.captureSession == session, self.captureState == .done else { return }
            self.captureState = .idle
            self.liveTranscript = ""
        }
    }

    /// User answered the one-time cloud-parse consent sheet (`PopoverView`'s consent row).
    /// Persists the decision (decline ⇒ never asked again, never routes to Cloud — see
    /// `cloudParseConsent`'s doc comment for the seam note with `IntentRouter`) and resumes the
    /// transcript that was waiting on it, if any (a cancel in the meantime already cleared it).
    func resolveCloudConsent(allow: Bool) {
        cloudParseConsent = allow
        UserDefaults.standard.set(allow, forKey: Self.cloudParseConsentKey)
        pendingCloudConsent = false
        guard let transcript = pendingParseTranscript else { return }
        pendingParseTranscript = nil
        runParse(transcript: transcript)
    }

    /// The actual parse call, split out of `finishRecording` so the one-time consent gate above can
    /// defer it. Builds up to `TaskStore.maxBatchSize` `ConfirmDraft`s and pre-resolves the "easy"
    /// `.taskDone` conditions (parser-confidence >= 0.7 AND a confident fuzzy title match) so the
    /// confirm card doesn't show a picker for those — anything left unresolved is exactly the < 0.7
    /// / no-match case constitution II requires a picker for (`PopoverView`'s `dependencyPicker`).
    ///
    /// task_refs_v1 (2026-08-02): swapped `router.parse` for `router.parseCapture` — the sibling
    /// wire-layer's superset entry point, same args as `parse`, returning `ParsedCapture` (`tasks`
    /// plus `taskRefs`/`updates`). The FM/heuristic tiers report empty `taskRefs`/`updates` (per
    /// that method's own doc comment), so an utterance with no reference at all degrades to exactly
    /// today's `capture.tasks`-only behavior, byte for byte — `capture.tasks` still flows into
    /// `buildConfirmDrafts` completely unchanged, per the task brief's explicit instruction.
    private func runParse(transcript: String) {
        captureState = .parsing
        captureSession += 1
        let session = captureSession
        let now = clock()
        let titles = openTasks.map(\.title)
        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            let capture = await self.router.parseCapture(transcript, now: now, openTaskTitles: titles)
            // Stale? The hold ended (Esc/cancel/a second capture) while the parse was in flight —
            // mirrors `startCapture`'s authorization-pending guard.
            guard self.captureSession == session, self.captureState == .parsing else { return }
            // Defense-in-depth cap (self-review "client-exploit"): the contract promises the
            // router already enforces the 10-task cap; this survives a malformed/hostile result
            // regardless.
            let capped = Array(capture.tasks.prefix(TaskStore.maxBatchSize))
            // T074: conflict advisory computed ONCE per parse, right here — never per keystroke/
            // per chip-edit (self-review "performance"). `conflictNow` is a single fresh clock
            // read shared by every draft in the batch so a multi-task confirm scores consistently
            // against the same "now" instant.
            let conflictNow = self.clock()
            var drafts = self.buildConfirmDrafts(from: capped, conflictNow: conflictNow)
            // task_refs_v1: `capture.taskRefs`/`.updates` resolved against THIS exact `drafts`
            // snapshot — a `.sibling` update merges straight into its target draft in place (no
            // card of its own; see `mergeUpdateIntoSibling`), so `drafts` can come back changed.
            self.confirmUpdateDrafts = self.buildConfirmUpdateDrafts(from: capture, drafts: &drafts, openTasks: self.openTasks)
            self.confirmDrafts = drafts
            // `buildConfirmDrafts` stays a pure helper (no `self`) — see
            // `recomputeConfirmCycle`'s own doc comment for why the call has to live at each of
            // its call sites, here included, rather than inside it.
            self.recomputeConfirmCycle()
            if self.confirmDrafts.isEmpty {
                self.captureErrorDetail = "Didn't catch that."
                self.captureState = .error
            } else {
                self.captureState = .parsed
            }
        }
    }

    /// Shared "parsed tasks -> confirm drafts" pipeline for BOTH `runParse` (voice) and
    /// `applyTextCaptureParseResult` (typed) — kept as ONE implementation (2026-07-28) so Việc 2's
    /// intra-batch `.taskDone` resolution and Việc 3's duplicate hint can never drift between the
    /// two entry points. For a single-task batch with no matching duplicate/condition this reduces
    /// to exactly the original `capped.map { preResolveConditions(ConfirmDraft(task:)) }`
    /// pipeline — nothing else in a 1-draft batch to intra-batch-match against, and an empty
    /// `duplicateCandidates` never changes `confirmSave()`'s outcome — so the default/simple case
    /// is byte-for-byte unchanged.
    private func buildConfirmDrafts(from parsed: [ParsedTask], conflictNow: Date) -> [ConfirmDraft] {
        // Single read, reused for BOTH the duplicate hint and the intra-batch/openTasks
        // `.taskDone` resolution below, so every draft in this batch is scored against the exact
        // same snapshot (the previous code read `openTasks` twice, once inside
        // `preResolveConditions` and implicitly again via `computeConflicts`'s own `tasks` read —
        // harmless since nothing `await`s in between, but one read is simpler to reason about).
        let existingTasks = openTasks
        var drafts = parsed.map { ConfirmDraft(task: $0) }
        // Việc 3.1: duplicate hint computed ONCE here, at draft-creation time — never recomputed
        // per chip edit (self-review "performance"; see `ConfirmDraft.duplicateCandidates`'s doc
        // comment).
        // Chỉ mục dựng MỘT lần cho cả lô, không phải mỗi draft một lần — `duplicateCandidates`
        // được gọi trong vòng lặp ngay dưới.
        let searchIndex = TaskSearchIndex(tasks: existingTasks)
        for i in drafts.indices {
            drafts[i].duplicateCandidates = Self.duplicateCandidates(
                for: drafts[i].effectiveTitle,
                in: existingTasks,
                index: searchIndex
            ).map(\.id)
        }
        drafts = preResolveConditions(drafts, openTasks: existingTasks)
        for i in drafts.indices {
            drafts[i].conflicts = computeConflicts(for: drafts[i], now: conflictNow)
            // T-overdue: same "computed once, against the shared `conflictNow` clock read" rule
            // as `conflicts` immediately above — reusing `conflictNow` (rather than a fresh
            // `clock()`/`Date()` call here) keeps every draft in a multi-task batch scored against
            // the exact same "now" instant, same reasoning `conflictNow`'s own doc comment gives.
            drafts[i].overdueSuggestion = OverdueSuggestion.makeIfOverdue(
                deadline: drafts[i].task.deadline?.value, now: conflictNow
            )
            // §2.4(a): same "computed once, at draft-creation time" rule as the two fields right
            // above — see `ConfirmDraft.calendarConflict`'s own doc comment.
            drafts[i].calendarConflict = calendarConflictDescription(for: drafts[i].task)
        }
        return drafts
    }

    /// The one `CalendarAccess.BusyBlock` (§2.1) whose window contains `task`'s own `deadline` —
    /// or, absent a deadline, its `startTime` — formatted as "\(start)–\(end) · \(title)". `nil`
    /// whenever the "Read my calendar" toggle is off (§2.5: toggle off means `busyBlocks` is never
    /// even called, not called-then-discarded), `task` has neither instant, or nothing overlaps.
    ///
    /// The `busyBlocks` query window is deliberately just `[instant, instant + 1s)` — a 1-second
    /// probe, not the task's own duration or `WaitingMode.horizonMinutes` — because EventKit's
    /// predicate matches any event whose own interval OVERLAPS the queried range, so a block that
    /// actually contains `instant` (`block.start <= instant < block.end`) always overlaps this tiny
    /// probe regardless of how long the block itself runs. The `first(where:)` guard below then
    /// re-checks that exact containment precisely, so the probe's only job is fetching a candidate
    /// set from EventKit, never deciding correctness itself.
    private func calendarConflictDescription(for task: ParsedTask) -> String? {
        guard calendarReadEnabled else { return nil }
        guard let instant = task.deadline?.value ?? task.startTime?.value else { return nil }
        let blocks = calendarAccess.busyBlocks(
            from: instant,
            to: instant.addingTimeInterval(1),
            excludingCalendarID: calendarSync.volarCalendarID
        )
        guard let hit = blocks.first(where: { instant >= $0.start && instant < $0.end }) else { return nil }
        let start = hit.start.formatted(.dateTime.hour().minute())
        let end = hit.end.formatted(.dateTime.hour().minute())
        return "\(start)–\(end) · \(hit.title)"
    }

    /// Auto-resolves `.taskDone` conditions the router was itself confident about (>=0.7) — first
    /// against a confident fuzzy title match in `openTasks` (exactly the original v1 behavior),
    /// and — Việc 2 (2026-07-28, closing a real gap, not a new feature): if THAT comes up empty,
    /// against the OTHER drafts in this SAME batch (excluding itself). "Xong task A thì tạo task
    /// B" said in one breath makes A and B together — A is nowhere in `openTasks` yet because it
    /// doesn't exist until `confirmSave()` creates it, so without this second lookup the condition
    /// was silently dropped at save (see `ConfirmDraft.intraBatchTaskDone`'s doc comment). SAME
    /// 0.7 bar for both lookups — constitution II: matching within the batch is a convenience for
    /// what the user already said, never a reason to lower the confidence floor. A batch match is
    /// recorded in `intraBatchTaskDone` (the OTHER DRAFT's id), never `resolvedTaskDone` (which
    /// promises an already-persisted task id) and never a fabricated UUID.
    ///
    /// Takes the WHOLE batch (rather than one draft, the original signature) specifically so each
    /// draft's condition can see every OTHER draft's stable `id`/title before any of them exist as
    /// real tasks — a single-draft signature has no way to look sideways at its siblings. Both
    /// call sites (`buildConfirmDrafts` above) already have the full batch in hand, so this is a
    /// call-site-local change, not a wider API break.
    private func preResolveConditions(_ drafts: [ConfirmDraft], openTasks: [TaskItem]) -> [ConfirmDraft] {
        var drafts = drafts
        for i in drafts.indices {
            for (index, condition) in drafts[i].task.conditions.enumerated() {
                guard case .taskDone(let titleQuery, let confidence) = condition, confidence >= 0.7 else { continue }
                if let match = Self.bestFuzzyMatch(for: titleQuery, in: openTasks), match.score >= 0.7 {
                    drafts[i].resolvedTaskDone[index] = match.id
                    continue
                }
                let siblings: [(id: UUID, title: String)] = drafts.indices
                    .filter { $0 != i }
                    .map { (drafts[$0].id, drafts[$0].effectiveTitle) }
                if let match = Self.scoredMatches(for: titleQuery, candidates: siblings).first, match.score >= 0.7 {
                    drafts[i].intraBatchTaskDone[index] = match.id
                }
            }
        }
        return drafts
    }

    // MARK: - task_refs_v1 (2026-08-02): "update an existing task by voice"
    //
    // The client-side resolution + confirm-state pipeline for `ParsedCapture.taskRefs`/`.updates`
    // (the sibling wire-layer's `Sources/Parsing/ParsedCapture.swift`) — `capture.tasks` still flows
    // through `buildConfirmDrafts` completely unchanged (see `runParse`); this is purely additive.

    /// Resolves each `ParsedTaskRef` in a fresh parse's `taskRefs` array to a `RefResolution`, ONE
    /// time per ref — every `ParsedTaskUpdate.refIndex` sharing the same ref shares the same
    /// resolution (task brief: "Resolve each ref ONCE"). Mirrors `preResolveConditions`'s EXACT
    /// ladder/thresholds/scorer: step 1 is the identical `bestFuzzyMatch(for:in:)` call
    /// `preResolveConditions` makes against `openTasks` (≥0.7 — see `scoredMatches`'s own doc
    /// comment for why a wrong match here is real corruption, not a glance-and-ignore hint, and
    /// therefore keeps the 0.7 bar untouched); step 2 is the
    /// identical `scoredMatches(for:candidates:)` call against this batch's OTHER drafts (task
    /// brief explicitly says "the batch's other drafts," so unlike `preResolveConditions`'s
    /// intra-batch step, this does NOT exclude any particular draft by index — a ref legitimately
    /// can, and typically does, match a sibling other than "self" trivially since a task-ref
    /// query is never the referencing draft's own title).
    ///
    /// `ParsedTaskRef.confidence`/`.assumeExisting` are part of the pinned wire type but this
    /// round's ladder does not gate on either — the task brief's algorithm is exactly the 3-step
    /// ladder below, nothing more. Flagged here rather than silently ignored: if a future revision
    /// wants low-confidence refs to skip straight to `.unresolved` (bypassing steps 1/2 entirely) or
    /// `assumeExisting == false` to try step 2 before step 1, this is the one place that changes.
    ///
    /// Intentionally `internal`, not `private`, for direct testability — same exception, same
    /// reasoning, as `AppState.mergeNotesAppending`'s own doc comment gives (`Tests/
    /// ConfirmUpdateDraftTests.swift` calls this and the two methods below it directly rather than
    /// only through the async `runParse` entry point, which needs a real `IntentRouter.parseCapture`
    /// this test target cannot construct).
    func resolveTaskRefs(
        _ refs: [ParsedTaskRef], drafts: [ConfirmDraft], openTasks: [TaskItem]
    ) -> [RefResolution] {
        refs.map { ref in
            if let match = Self.bestFuzzyMatch(for: ref.titleQuery, in: openTasks), match.score >= 0.7 {
                return .existing(match.id)
            }
            let siblings: [(id: UUID, title: String)] = drafts.map { ($0.id, $0.effectiveTitle) }
            if let match = Self.scoredMatches(for: ref.titleQuery, candidates: siblings).first, match.score >= 0.7 {
                return .sibling(match.id)
            }
            return .unresolved
        }
    }

    /// "The referenced task turned out to be one the user is creating in this same breath" (task
    /// brief) — folds a `.sibling`-resolved `ParsedTaskUpdate` straight into its target
    /// `ConfirmDraft` rather than becoming a separate confirm card. Mutates `drafts[i].task.
    /// {deadline,startTime,priority}` DIRECTLY — a deliberate, narrow exception to `ConfirmDraft`'s
    /// own "never mutate `task` in place" rule (see that struct's header comment): this runs exactly
    /// ONCE, at draft-construction time, before the card has ever rendered or been interacted with,
    /// so there is no live user edit to clobber — and writing straight into `task.*` (rather than
    /// `editedDeadline`/etc, which unconditionally pins confidence to `1.0`) is what lets the
    /// merged value flow through `DeadlineControl`/`StartTimeControl`/`PriorityControl`'s EXISTING
    /// uncertain/dashed/accept-tap machinery completely unchanged — an update-supplied value below
    /// the 0.7 bar still needs an explicit accept tap before it can save, exactly like any other
    /// parsed attribute (constitution II), which an `editedX` overlay could not offer without
    /// inventing a second confidence-tracking mechanism (self-review "reuse over invention").
    ///
    /// "Respecting existing chip edit precedence" (task brief) is enforced by the `== nil` guard on
    /// each field: if the sibling's OWN parse already stated a value for that exact attribute
    /// (`task.deadline`/`.startTime`/`.priority` already non-nil), the merge never overwrites it —
    /// same "never second-guess what was already stated" rule `IntentRouter.
    /// applyStartTimeDerivation` already applies one field over (never overwriting a spoken
    /// `deadline` with a derived one).
    ///
    /// `notesAppend` and `addConditions` go through `ConfirmDraft.editedNotes`/`.refConditions`
    /// instead — see each assignment below for why those two, unlike the three scalars above, are
    /// NOT a "never overwrite what's already there" merge.
    ///
    /// Intentionally `internal`, not `private` — same direct-testability exception `resolveTaskRefs`
    /// above documents.
    func mergeUpdateIntoSibling(
        _ update: ParsedTaskUpdate, targetDraftID: ConfirmDraft.ID, drafts: inout [ConfirmDraft]
    ) {
        guard let i = drafts.firstIndex(where: { $0.id == targetDraftID }) else { return }
        if drafts[i].task.deadline == nil, let deadline = update.deadline {
            drafts[i].task.deadline = deadline
        }
        if drafts[i].task.startTime == nil, let startTime = update.startTime {
            drafts[i].task.startTime = startTime
        }
        if drafts[i].task.priority == nil, let priority = update.priority {
            drafts[i].task.priority = priority
        }
        // `notesAppend` has no confidence gate anywhere else in this file either (`ConfirmDraft.
        // editedNotes`/`.effectiveNotes` never check `isUncertain` — notes is free text, not a
        // scalar chip attribute), so this merge doesn't invent one: `mergeNotesAppending` is the
        // SAME append-or-leave-alone helper `AppState.mergeTransform`'s own notes handling already
        // calls, reused verbatim, writing through `editedNotes` (the sibling draft's OWN existing
        // overlay field — `NotesEditorControl` renders it with zero new UI).
        if let notesAppend = update.notesAppend,
           let combined = Self.mergeNotesAppending(existing: drafts[i].effectiveNotes, incoming: notesAppend.value) {
            drafts[i].editedNotes = combined
        }
        // `addConditions` carries no confidence at all in the pinned `ParsedUpdateCondition` type —
        // a deterministic index/date the router already resolved, not a fuzzy guess — so these
        // attach unconditionally into `refConditions` (visible/dismissible on the sibling's own
        // card via `PopoverView`'s `refConditionRows`, never silently invisible — constitution II).
        for condition in update.addConditions {
            switch condition {
            case .taskDoneNewTask(let refIndex):
                // 1-based into `ParsedCapture.tasks` == `drafts`' own order (this method runs
                // during draft construction, before any reordering/removal is possible).
                guard drafts.indices.contains(refIndex - 1) else { continue }
                let referencedID = drafts[refIndex - 1].id
                guard referencedID != drafts[i].id else { continue } // defensive: no self-reference
                drafts[i].refConditions.append(.taskDone(referencedID))
            case .afterDate(let date):
                drafts[i].refConditions.append(.afterDate(date))
            }
        }
    }

    /// `runParse`'s task_refs_v1 step, right after `buildConfirmDrafts` (task brief: "capture.tasks
    /// ... flow into buildConfirmDrafts unchanged" — this is a SEPARATE pass over the result, never
    /// a change to that method's own signature/behavior). Resolves `capture.taskRefs` against this
    /// exact `drafts`/`openTasks` snapshot, then routes each `capture.updates` entry: `.sibling` ->
    /// merged in place via `mergeUpdateIntoSibling` (no card); `.existing`/`.unresolved` -> a
    /// `ConfirmUpdateDraft` `PopoverView` renders.
    ///
    /// NOTE (self-review "known scope boundary"): `buildConfirmDrafts`'s own `conflicts`/
    /// `overdueSuggestion` computation already ran (inside that call) BEFORE this method ever
    /// touches `drafts`, so a deadline a `.sibling` merge fills in here will not retroactively gain
    /// an overdue-nudge/conflict advisory this session — only a deadline the router put directly on
    /// that task's own parse gets one. Accepted trade-off for keeping `buildConfirmDrafts` itself
    /// completely unchanged, per the task brief's explicit instruction.
    ///
    /// Intentionally `internal`, not `private` — same direct-testability exception `resolveTaskRefs`
    /// above documents.
    func buildConfirmUpdateDrafts(
        from capture: ParsedCapture, drafts: inout [ConfirmDraft], openTasks: [TaskItem]
    ) -> [ConfirmUpdateDraft] {
        let resolutions = resolveTaskRefs(capture.taskRefs, drafts: drafts, openTasks: openTasks)
        var updateDrafts: [ConfirmUpdateDraft] = []
        for update in capture.updates {
            // Defense-in-depth (self-review "client-exploit"): the wire contract's own doc comment
            // promises `refIndex` is "already bounds-validated," same as `IntentRouter.parse`'s own
            // 10-task cap promise `runParse` still re-enforces regardless (`capped =
            // Array(results.prefix(...))`) — this survives a malformed/hostile result either way.
            guard resolutions.indices.contains(update.refIndex - 1) else { continue }
            let ref = capture.taskRefs[update.refIndex - 1]
            switch resolutions[update.refIndex - 1] {
            case .existing(let id):
                updateDrafts.append(ConfirmUpdateDraft(
                    refIndex: update.refIndex, sourceTitleQuery: ref.titleQuery, resolution: .existing(id),
                    deadline: update.deadline, startTime: update.startTime, notesAppend: update.notesAppend,
                    priority: update.priority, addConditions: update.addConditions
                ))
            case .sibling(let siblingDraftID):
                mergeUpdateIntoSibling(update, targetDraftID: siblingDraftID, drafts: &drafts)
            case .unresolved:
                updateDrafts.append(ConfirmUpdateDraft(
                    refIndex: update.refIndex, sourceTitleQuery: ref.titleQuery, resolution: .unresolved,
                    deadline: update.deadline, startTime: update.startTime, notesAppend: update.notesAppend,
                    priority: update.priority, addConditions: update.addConditions
                ))
            }
        }
        return updateDrafts
    }

    private struct FuzzyMatch { let id: UUID; let score: Double }

    /// Shared fuzzy scorer — **trigram** (3 ký tự liên tiếp) chứ không phải token, anh Khôi chốt
    /// 2026-08-20 sau khi gặp ca thật: tạo task "Làm task Dem Search", nói lại "dems search", app
    /// không tìm ra. Bảng dưới là điểm thật của chính ca đó, cột trái là công thức cũ (Jaccard
    /// theo TỪ), cột phải là công thức này:
    ///
    ///     tiêu đề đã lưu                       Jaccard-từ   trigram
    ///     "Dems Search"                            1.00       1.00
    ///     "Làm task Dems Search"                   0.50       1.00   <- trượt bar 0.7 ở bản cũ
    ///     "Làm task Dem Search"                    0.20       0.727  <- ca của anh Khôi
    ///     "Làm task Custom Metadata Autotest"      0.50       0.00   <- báo trùng BẬY ở bản cũ
    ///     "Search" (một từ)                        0.50       0.462  <- loại đúng ở cả hai bar
    ///
    /// Hai điều Jaccard-theo-từ làm sai mà trigram làm đúng, và đều là hệ quả của cùng một chuyện
    /// (nó đo "hai tiêu đề GIỐNG nhau bao nhiêu phần" chứ không đo "cụm vừa nói có NẰM TRONG tiêu
    /// đề không"):
    ///   1. Chữ đệm ("làm", "task") nằm ở mẫu số, nên tiêu đề càng dài điểm càng tụt — dù cụm anh
    ///      nói khớp nguyên vẹn. Đây là lý do ca trên trượt.
    ///   2. Ngược lại, hai task khác hẳn nhau mà cùng bắt đầu bằng chữ đệm thì được cộng điểm —
    ///      "Làm task Dem Search" vs "Làm task Custom Metadata Autotest" đạt 0.50 ở nhánh lỏng,
    ///      vượt bar 0.45 của gợi ý trùng, tức app đi hỏi "có phải cùng một việc không" cho hai
    ///      việc chẳng liên quan. Trigram cho 0.00.
    /// Trigram còn chịu được lệch một ký tự ("Dem"/"Dems") mà không cần thư viện edit-distance nào.
    ///
    /// KHÔNG hạ bar 0.7 của `preResolveConditions`. Anh Khôi nói "thà tìm ra task trùng còn hơn
    /// không tìm ra cái nào" — đúng cho GỢI Ý (`duplicateCandidates`, bar thấp, người nhìn rồi
    /// chọn), nhưng bar 0.7 canh một việc khác hẳn: nó TỰ ĐỘNG gắn cạnh phụ thuộc `.taskDone` mà
    /// không hỏi ai, và gắn nhầm thì task mới biến mất khỏi Today cho tới khi task-nhầm-kia xong.
    /// Cách làm đúng ý anh mà không mở cửa đó: đổi cái THƯỚC, giữ nguyên cái BAR — ca của anh giờ
    /// đạt 0.727 nên tự khớp được, mà ca sai vẫn 0.00. Dưới 0.7 thì đã có picker để anh tự chọn
    /// (`resolveTaskDone`), không có gì bị nuốt mất.
    ///
    /// Một thước duy nhất cho cả hai chỗ gọi (enum `Similarity` cũ đã xoá): nhánh "lỏng" ngày xưa
    /// tồn tại để bắt ca "nói ngắn lại việc đã có", mà containment dưới đây làm việc đó tốt hơn hẳn
    /// và không kèm tác dụng phụ. Khác biệt giữa hai chỗ gọi nay nằm ở BAR, đúng chỗ nó nên nằm.
    ///
    /// Trả về mọi ứng viên có điểm > 0, sắp giảm dần; `Array.sorted` ổn định (Swift 5+) nên các
    /// ứng viên bằng điểm giữ nguyên thứ tự trong `candidates` — giữ đúng hành vi "ứng viên đầu
    /// tiên đạt điểm cao nhất thắng" mà `bestFuzzyMatch` vẫn dựa vào.
    private static func scoredMatches(
        for query: String,
        candidates: [(id: UUID, title: String)]
    ) -> [FuzzyMatch] {
        candidates
            .map { FuzzyMatch(id: $0.id, score: fuzzyMatchScore(query: query, candidate: $0.title)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
    }

    /// Điểm khớp mờ giữa hai chuỗi, 0…1. KHÔNG `private` đúng một lý do: đây là hạt nhân mà cả hai
    /// bar (0.7 tự-gắn-phụ-thuộc và `duplicateHintBar` gợi ý) đều dựa vào, nên nó phải test được
    /// trực tiếp thay vì test gián tiếp qua cả đường confirm — xem `FuzzyMatchScoreTests`.
    ///
    /// Cố ý tự tính lại trigram của `query` ở mỗi cặp thay vì nâng ra ngoài vòng lặp của
    /// `scoredMatches`: `openTasks` là danh sách task cá nhân (hàng chục tới hàng trăm), mỗi lượt
    /// tính là vài micro-giây, và đổi lại là CHỈ CÓ MỘT nơi định nghĩa công thức. Nếu hồ sơ đo cho
    /// thấy chỗ này thành điểm nóng thật thì mới nâng ra — đừng tối ưu trước khi có số.
    static func fuzzyMatchScore(query: String, candidate: String) -> Double {
        let queryGrams = trigrams(query)
        let candidateGrams = trigrams(candidate)
        guard !queryGrams.isEmpty, !candidateGrams.isEmpty else { return 0 }
        let shared = queryGrams.intersection(candidateGrams).count
        guard shared > 0 else { return 0 }

        let dice = 2 * Double(shared) / Double(queryGrams.count + candidateGrams.count)
        // Chốt chặn quan trọng nhất của cả hàm: containment = "cụm hỏi nằm trọn trong tiêu đề",
        // nên một query rác ngắn như "task" hay "search" đạt containment 1.00 với MỌI tiêu đề có
        // chứa chữ đó — ở bar 0.7 là tự động gắn phụ thuộc bậy. Query ngắn rơi về Dice (đối xứng,
        // phạt chênh lệch độ dài): "task" -> 0.333, "search" -> 0.462, dưới cả 0.7 lẫn 0.35.
        // Ngưỡng 8 ký tự ≈ hai từ thật; cùng tinh thần với guard `smaller >= 2` của bản Jaccard cũ.
        guard normalizedForMatching(query).count >= 8 else { return dice }
        return max(dice, Double(shared) / Double(queryGrams.count))
    }

    /// Chuẩn hoá trước khi cắt trigram: thường hoá, bỏ dấu tiếng Việt, **bỏ dấu câu** (bản token cũ
    /// chỉ cắt theo khoảng trắng nên "search," và "search" là hai thứ khác nhau), gộp khoảng trắng.
    private static func normalizedForMatching(_ text: String) -> String {
        let folded = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let cleaned = folded.map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    /// Tập 3-gram ký tự, có đệm một khoảng trắng ở hai đầu để biên từ cũng mang thông tin (" de"
    /// khác "ade") — chuẩn của mọi bộ so chuỗi mờ, và là thứ khiến "Dem"/"Dems" vẫn gần nhau.
    private static func trigrams(_ text: String) -> Set<String> {
        let padded = " " + Self.normalizedForMatching(text) + " "
        guard padded.count >= 3 else { return [] }
        let characters = Array(padded)
        var grams: Set<String> = []
        for i in 0...(characters.count - 3) {
            grams.insert(String(characters[i..<(i + 3)]))
        }
        return grams
    }

    /// Bar cho GỢI Ý trùng. Thấp hơn hẳn bar 0.7 tự-gắn-phụ-thuộc, và đó là chủ ý: anh Khôi chốt
    /// 2026-08-20 "thà tìm ra task trùng còn hơn không tìm ra cái nào". Sai ở đây tốn một cái liếc
    /// mắt; sót ở đây đẻ ra một task trùng thật, im lặng. Hạ 0.45 -> 0.35 vì thước đã đổi sang
    /// trigram: cái false positive mà bar 0.45 cũ để lọt ("Làm task Dem Search" vs "Làm task Custom
    /// Metadata Autotest", 0.50 theo công thức cũ) nay là 0.00, nên hạ bar không mang nó quay lại.
    private static let duplicateHintBar = 0.35
    /// 3 -> 5 ứng viên, cùng lý do trên. Vẫn có trần để thẻ confirm không bao giờ phải vẽ một danh
    /// sách không giới hạn.
    private static let duplicateHintLimit = 5

    /// Việc 3.1 (2026-07-28): tối đa `duplicateHintLimit` task đã lưu trông như CÓ THỂ chính là
    /// `title` — một GỢI Ý để liếc rồi quyết, không bao giờ tự áp (xem
    /// `ConfirmDraft.duplicateResolution`: luôn khởi đầu ở `.addNew`).
    private static func duplicateCandidates(
        for title: String,
        in openTasks: [TaskItem],
        index: TaskSearchIndex
    ) -> [FuzzyMatch] {
        // Hai đường tìm, lấy điểm CAO HƠN — không phải trung bình, không phải nhân. Chúng bắt hai
        // kiểu trùng khác hẳn nhau và mỗi đường mù đúng chỗ đường kia nhìn thấy:
        //   - trigram trên TIÊU ĐỀ: bắt "nói lại gần y hệt, lệch vài ký tự" ("dems"/"dem").
        //   - chỉ mục term (`TaskSearchIndex`): bắt "nói về cùng một việc bằng chữ khác", vì nó tra
        //     cả `notes`/`sourceTranscript` của task đã lưu — chữ "Solr" chỉ nằm trong câu nói gốc
        //     chứ chẳng bao giờ lọt vào tiêu đề, nên trigram-trên-tiêu-đề không thể thấy nó.
        // Lấy max là hệ quả trực tiếp của luật anh Khôi chốt 2026-08-20 ("thà tìm ra task trùng còn
        // hơn không tìm ra cái nào"): chỉ cần MỘT đường nhận ra là đủ để đưa lên cho người nhìn.
        var best: [UUID: Double] = [:]
        for match in scoredMatches(for: title, candidates: openTasks.map { ($0.id, $0.title) }) {
            best[match.id] = max(best[match.id] ?? 0, match.score)
        }
        for match in index.matches(for: title, limit: openTasks.count) {
            best[match.id] = max(best[match.id] ?? 0, match.score)
        }
        return best
            .map { FuzzyMatch(id: $0.key, score: $0.value) }
            .filter { $0.score >= duplicateHintBar }
            // `Dictionary` không có thứ tự, nên phải phá hoà bằng id — nếu không, cùng một dữ liệu
            // có thể cho ra hai danh sách gợi ý khác nhau giữa hai lần chạy.
            .sorted { $0.score == $1.score ? $0.id.uuidString < $1.id.uuidString : $0.score > $1.score }
            .prefix(duplicateHintLimit)
            .map { $0 }
    }

    /// O(n) trên `openTasks` cho mỗi condition — nhiều nhất ~10 condition một lượt confirm, nên
    /// vẫn rẻ ở quy mô hàng trăm task. Một kết quả tốt nhất; `scoredMatches` sắp ổn định nên khi
    /// bằng điểm thì ứng viên xuất hiện trước trong `openTasks` thắng, đúng như hành vi cũ.
    private static func bestFuzzyMatch(for query: String, in openTasks: [TaskItem]) -> FuzzyMatch? {
        scoredMatches(for: query, candidates: openTasks.map { ($0.id, $0.title) }).first
    }

    // MARK: - Confirm-card chip interactions (T024)
    //
    // Every mutation here edits a `ConfirmDraft` overlay, never the underlying `ParsedTask` (the
    // sibling-owned contract type) — see `ConfirmDraft`'s doc comment. Each is a one-way action
    // (dismissed/resolved chips disappear from the card, matching `PopoverView`'s rendering —
    // there is no re-surface-to-undo affordance within one confirm session; recording again
    // starts fresh). Every edit that actually changes what gets saved logs a `ParseCorrection`
    // (constitution V / FR-044).

    /// Removes a scalar attribute chip (deadline/estimate/priority/reminder/recurrence/kind) —
    /// it will not be saved regardless of confidence.
    func dismissAttribute(_ kind: ChipKind, forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].dismissed.insert(kind)
        logCorrection(kind: kind, task: confirmDrafts[index].task, correctedValue: "dismissed")
    }

    /// Explicit tap-to-accept for an uncertain (<0.7) scalar attribute chip — required before it
    /// is ever committed (constitution II).
    func acceptUncertainAttribute(_ kind: ChipKind, forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].accepted.insert(kind)
        logCorrection(kind: kind, task: confirmDrafts[index].task, correctedValue: "accepted")
    }

    /// Removes a condition (any kind) at `conditionIndex` — dropped rather than guessed
    /// (constitution II); also how the taskDone picker's "Skip" resolves.
    func dismissCondition(at conditionIndex: Int, forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].dismissedConditions.insert(conditionIndex)
        confirmDrafts[index].resolvedTaskDone[conditionIndex] = nil
        // Việc 2: dismiss wins over EITHER resolution kind — a dropped condition must not linger
        // as an intra-batch target `confirmSave()`'s second pass would otherwise still attach.
        confirmDrafts[index].intraBatchTaskDone[conditionIndex] = nil
        logCorrection(
            kind: nil, attribute: "condition[\(conditionIndex)]",
            task: confirmDrafts[index].task, correctedValue: "dropped"
        )
        recomputeConfirmCycle() // dropping a condition can drop the edge that closed a cycle
    }

    /// Explicit tap-to-accept for an uncertain (<0.7) `.afterDate`/`.external` condition chip.
    /// `.taskDone` never uses this path — it always resolves via `resolveTaskDone` (picker or
    /// confident fuzzy match), never a bare accept, per constitution II's explicit picker
    /// requirement for dependencies.
    func acceptUncertainCondition(at conditionIndex: Int, forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].acceptedConditions.insert(conditionIndex)
        logCorrection(
            kind: nil, attribute: "condition[\(conditionIndex)]",
            task: confirmDrafts[index].task, correctedValue: "accepted"
        )
        // `.taskDone` never reaches this path (see this method's own doc comment — it always
        // resolves via `resolveTaskDone`'s explicit picker instead), so this can never actually
        // change the `.taskDone` edge set; called anyway for the same "every condition mutator
        // recomputes" consistency the contract asks for, at negligible cost.
        recomputeConfirmCycle()
    }

    /// The dependency picker's resolution (constitution II: NEVER auto-attach below 0.7 — the
    /// user always makes this choice explicitly). `taskID == nil` drops the condition (picker's
    /// "Skip — no dependency").
    func resolveTaskDone(at conditionIndex: Int, to taskID: UUID?, forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        if let taskID {
            confirmDrafts[index].resolvedTaskDone[conditionIndex] = taskID
            // Việc 2: an explicit picker choice always overrides whatever `preResolveConditions`
            // may have auto-matched intra-batch — the two must never both be set for one index.
            confirmDrafts[index].intraBatchTaskDone[conditionIndex] = nil
            confirmDrafts[index].dismissedConditions.remove(conditionIndex)
        } else {
            confirmDrafts[index].dismissedConditions.insert(conditionIndex)
            confirmDrafts[index].intraBatchTaskDone[conditionIndex] = nil
        }
        logCorrection(
            kind: nil, attribute: "condition[\(conditionIndex)].taskDone",
            task: confirmDrafts[index].task, correctedValue: taskID?.uuidString ?? "dropped"
        )
        recomputeConfirmCycle()
    }

    /// 2026-07-28 (confirm-list UI, Việc 3): the picker's OTHER group — "task done" resolved
    /// against another DRAFT in this same batch rather than an already-persisted task (see
    /// `ConfirmDraft.intraBatchTaskDone`'s doc comment for why that has to be a separate map).
    /// Mirrors `resolveTaskDone`'s "taskID" branch exactly, but writes the sibling map instead and
    /// clears whatever `resolvedTaskDone` entry might already be there for the same index — the
    /// two must never both be set (same invariant `resolveTaskDone` enforces in the other
    /// direction). `target == draftID` is refused defensively (`PopoverView`'s picker already
    /// excludes the card's own draft from this group, so this should be unreachable from the UI,
    /// but a self-reference here would be a silent no-op dependency, not a crash, if it ever did
    /// get through).
    func resolveTaskDoneToDraft(_ draftID: ConfirmDraft.ID, conditionIndex: Int, target: ConfirmDraft.ID) {
        guard target != draftID else { return }
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].intraBatchTaskDone[conditionIndex] = target
        confirmDrafts[index].resolvedTaskDone[conditionIndex] = nil
        confirmDrafts[index].dismissedConditions.remove(conditionIndex)
        logCorrection(
            kind: nil, attribute: "condition[\(conditionIndex)].taskDone",
            task: confirmDrafts[index].task, correctedValue: "intraBatch:\(target.uuidString)"
        )
        recomputeConfirmCycle()
    }

    /// 2026-07-28 (confirm-list UI, Việc 1): the checkbox's mutator — ticks/unticks whether this
    /// draft is created at all (see `ConfirmDraft.isIncluded`'s doc comment and `confirmSave()`'s
    /// `filter(\.isIncluded)`). Deliberately REVERSIBLE, unlike the destructive per-task "x" this
    /// replaces (`removeDraft`, removed alongside this — its only call site was that button):
    /// toggling back on restores the draft exactly as it was, since nothing is ever actually
    /// removed from `confirmDrafts`.
    func setDraftIncluded(_ draftID: ConfirmDraft.ID, _ included: Bool) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].isIncluded = included
        // Unticking removes this draft's node (and every edge touching it) from the graph
        // entirely; re-ticking restores it. Either way the batch's edge set just changed.
        recomputeConfirmCycle()
    }

    /// 2026-07-28 (confirm-list UI, Việc 2): the duplicate-hint picker's resolution — constitution
    /// II forbids ever choosing `.useExisting` FOR the user (see `ConfirmDraft.duplicateResolution`'s
    /// doc comment), so this is the ONLY place that ever writes it.
    func setDuplicateResolution(_ draftID: ConfirmDraft.ID, _ resolution: ConfirmDraft.DuplicateResolution) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].duplicateResolution = resolution
        recomputeConfirmCycle() // changing `.useExisting` changes which node this draft's edges land on
    }

    /// task_refs_v1: dismisses a `ConfirmDraft.refConditions` entry — the sibling-merge equivalent
    /// of `dismissCondition` above, kept as its own method rather than folded into that one because
    /// the two arrays (`task.conditions` vs `refConditions`) have completely independent index
    /// spaces (see `ConfirmDraft.refConditions`'s own doc comment).
    func dismissRefCondition(at index: Int, forDraft draftID: ConfirmDraft.ID) {
        guard let draftIndex = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[draftIndex].dismissedRefConditions.insert(index)
    }

    // MARK: - task_refs_v1 confirm-card interactions (`ConfirmUpdateDraft`, mirrors the
    // `ConfirmDraft` chip-interaction section above field-for-field)

    /// Task-level dismiss (task brief: "Card-level dismiss removes the whole update") — also how
    /// the `.unresolved` picker's "Skip" resolves.
    func dismissConfirmUpdateDraft(_ draftID: ConfirmUpdateDraft.ID) {
        guard let index = confirmUpdateDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmUpdateDrafts[index].cardDismissed = true
    }

    /// The `.unresolved` picker's resolution — constitution II: the user always makes this choice
    /// explicitly, same "never auto-attach below 0.7" reasoning `AppState.resolveTaskDone` already
    /// documents for the analogous `.taskDone` picker. `taskID == nil` is "Skip" (same as
    /// `dismissConfirmUpdateDraft` — the picker's own dismiss affordance routes through here so
    /// `PopoverView` has one call for both its "pick a task" and "skip" rows).
    func resolveUpdateTarget(_ draftID: ConfirmUpdateDraft.ID, to taskID: UUID?) {
        guard let index = confirmUpdateDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        if let taskID {
            confirmUpdateDrafts[index].resolution = .existing(taskID)
        } else {
            confirmUpdateDrafts[index].cardDismissed = true
        }
    }

    /// Removes an update field chip (deadline/startTime/notesAppend/priority) — mirrors
    /// `AppState.dismissAttribute` exactly, scoped to `ConfirmUpdateDraft.Field`.
    func dismissUpdateField(_ field: ConfirmUpdateDraft.Field, forDraft draftID: ConfirmUpdateDraft.ID) {
        guard let index = confirmUpdateDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmUpdateDrafts[index].dismissed.insert(field)
    }

    /// Explicit tap-to-accept for an uncertain (<0.7) update field chip — mirrors
    /// `AppState.acceptUncertainAttribute` exactly, scoped to `ConfirmUpdateDraft.Field`.
    func acceptUpdateField(_ field: ConfirmUpdateDraft.Field, forDraft draftID: ConfirmUpdateDraft.ID) {
        guard let index = confirmUpdateDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmUpdateDrafts[index].accepted.insert(field)
    }

    /// Removes one `addConditions` entry — mirrors `AppState.dismissCondition`'s
    /// `Set<Int>`-over-the-array convention, scoped to `ConfirmUpdateDraft.addConditions`' own
    /// index space (never shared with `ConfirmDraft.dismissedConditions`/`.dismissedRefConditions`).
    func dismissUpdateAddCondition(at index: Int, forDraft draftID: ConfirmUpdateDraft.ID) {
        guard let draftIndex = confirmUpdateDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmUpdateDrafts[draftIndex].dismissedAddConditions.insert(index)
    }

    /// cycle-detection-contract.md §2: rebuilds `confirmCycle` from the CURRENT `confirmDrafts` +
    /// persisted `tasks` by constructing the SAME virtual `.taskDone` graph `confirmSave()` would
    /// actually commit, then asking `VolarCore.findCycle`. Must be called after EVERY mutation
    /// that can change the batch's edge set: wherever a fresh `buildConfirmDrafts(...)` result
    /// becomes the live `confirmDrafts` (`runParse`'s completion handler and both branches of
    /// `applyTextCaptureParseResult` — `buildConfirmDrafts` itself stays a pure `[ConfirmDraft]`-
    /// returning helper with no `self` to recompute against, so the call has to sit at each of
    /// its call sites instead of inside it), `dismissCondition`, `acceptUncertainCondition`,
    /// `resolveTaskDone`, `resolveTaskDoneToDraft`, `setDraftIncluded`, and `setDuplicateResolution`
    /// immediately above (changing `.useExisting` changes which node a draft's edges land on, so
    /// it's just as edge-set-changing as the condition mutators). A skipped call site leaves
    /// `confirmCycle` stale — either wrongly blocking a now-clean Save or wrongly letting a
    /// still-cyclic one through.
    private func recomputeConfirmCycle() {
        let includedDrafts = confirmDrafts.filter(\.isIncluded)
        guard !includedDrafts.isEmpty else {
            confirmCycle = nil
            return
        }

        // Step 1 (⚠️ contract's own flag for "the easy place to get this wrong"): the SAME id map
        // `confirmSave()` builds. `.addNew` -> a virtual node keyed by the draft's OWN `id` (safe:
        // this snapshot is thrown away the instant this method returns, so there's no real post-
        // save id to mint yet, and `ConfirmDraft.id` is already a stable `UUID`). `.useExisting(x)`
        // -> `x` itself, so this draft's edges MERGE into the ALREADY-EXISTING node `x` — never a
        // second node sharing that id, which would make `findCycle` read a corrupt graph and
        // miss/invent cycles.
        let currentTaskIDs = Set(tasks.map(\.id))
        func effectiveResolution(_ draft: ConfirmDraft) -> ConfirmDraft.DuplicateResolution {
            if case .useExisting(let id) = draft.duplicateResolution, !currentTaskIDs.contains(id) {
                return .addNew
            }
            return draft.duplicateResolution
        }
        var targetID: [ConfirmDraft.ID: UUID] = [:]
        for draft in includedDrafts {
            switch effectiveResolution(draft) {
            case .addNew: targetID[draft.id] = draft.id
            case .useExisting(let existingID): targetID[draft.id] = existingID
            }
        }

        // Step 2: every draft's `.taskDone` edges, filtered by the EXACT same rules `confirmSave()`
        // applies when it builds `intraBatchAttachments` (dismissed index dropped, self-edge
        // dropped, an edge to a draft that isn't in `targetID` — unticked, or never existed —
        // dropped) plus `resolvedConditions`'s own dismissed-index filter for the already-
        // resolved-to-a-real-task case. `.sorted(by:)` only makes ONE draft's own edges
        // deterministic relative to each other (`resolvedTaskDone`/`intraBatchTaskDone` are
        // `[Int: UUID]` dictionaries, unordered) — it does not reconstruct the original
        // `task.conditions` array order across different drafts, so when a cycle admits more than
        // one description, exactly WHICH edge is offered as removable can still vary run to run;
        // removing either one breaks the same cycle, so this doesn't affect correctness, only
        // which button happens to be shown.
        struct DraftEdge { let from: UUID; let to: UUID; let draftID: ConfirmDraft.ID; let conditionIndex: Int }
        var draftEdges: [DraftEdge] = []
        for draft in includedDrafts {
            guard let ownID = targetID[draft.id] else { continue }
            for (index, resolvedID) in draft.resolvedTaskDone.sorted(by: { $0.key < $1.key }) {
                guard !draft.dismissedConditions.contains(index), resolvedID != ownID else { continue }
                draftEdges.append(DraftEdge(from: ownID, to: resolvedID, draftID: draft.id, conditionIndex: index))
            }
            for (index, referencedDraftID) in draft.intraBatchTaskDone.sorted(by: { $0.key < $1.key }) {
                guard !draft.dismissedConditions.contains(index) else { continue }
                guard let refID = targetID[referencedDraftID], refID != ownID else { continue }
                draftEdges.append(DraftEdge(from: ownID, to: refID, draftID: draft.id, conditionIndex: index))
            }
        }

        // Step 3: snapshot = every persisted task (its OWN existing conditions kept intact) with
        // the batch's virtual edges layered ON TOP of whichever node they target — a `.useExisting`
        // draft's edges are ADDED to that task's real conditions, never replacing them, since its
        // already-persisted edges are just as real for cycle purposes. Whatever's left after that
        // targets a brand-new `.addNew` node that isn't in `tasks` yet, so it becomes a fresh
        // virtual `VolarCore.Task` (priority/deadline/etc. don't matter here — `findCycle` only
        // ever reads `conditions`).
        var edgesByNode: [UUID: [UUID]] = [:]
        for edge in draftEdges { edgesByNode[edge.from, default: []].append(edge.to) }
        var snapshot = tasks.map { $0.snapshot() }
        for i in snapshot.indices {
            guard let extra = edgesByNode.removeValue(forKey: snapshot[i].id) else { continue }
            snapshot[i].conditions.append(contentsOf: extra.map { VolarCore.Condition.taskDone($0) })
        }
        // Titles for nodes that are NOT already-persisted tasks (i.e. `.addNew` virtual nodes) —
        // needed below for the human-readable cycle path regardless of whether this particular
        // draft ended up with any outgoing edge of its own (it may still be the TARGET of one).
        var virtualTitles: [UUID: String] = [:]
        for draft in includedDrafts {
            guard let ownID = targetID[draft.id], !currentTaskIDs.contains(ownID) else { continue }
            virtualTitles[ownID] = draft.effectiveTitle
            if let extra = edgesByNode[ownID] {
                snapshot.append(VolarCore.Task(
                    id: ownID, title: draft.effectiveTitle, status: .todo, priority: nil,
                    deadline: nil, conditions: extra.map { VolarCore.Condition.taskDone($0) },
                    estimateMinutes: nil, parentId: nil, createdAt: Date()
                ))
            }
        }

        guard let cycle = VolarCore.findCycle(in: snapshot) else {
            confirmCycle = nil
            return
        }

        func title(for id: UUID) -> String {
            tasks.first(where: { $0.id == id })?.title ?? virtualTitles[id] ?? "Unknown task"
        }
        var removableEdges: [ConfirmCycle.RemovableEdge] = []
        for i in 0..<(cycle.count - 1) {
            let from = cycle[i]
            let to = cycle[i + 1]
            guard let edge = draftEdges.first(where: { $0.from == from && $0.to == to }) else { continue }
            removableEdges.append(ConfirmCycle.RemovableEdge(
                draftID: edge.draftID,
                conditionIndex: edge.conditionIndex,
                label: "\(title(for: from)) waits on \(title(for: to))"
            ))
        }
        confirmCycle = ConfirmCycle(titles: cycle.map { title(for: $0) }, removableEdges: removableEdges)
    }

    /// T074: dismisses the (at most one) conflict advisory line for one draft — never re-derives
    /// or re-runs `conflicts(...)`; just stops rendering it, exactly like every other chip's
    /// dismiss (constitution II — this is the user acting, not the system auto-modifying).
    func dismissConflictAdvisory(forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].conflictDismissed = true
    }

    /// T-overdue: the overdue advisory row's ONE tap-to-act affordance ("Move to tomorrow HH:mm",
    /// `PopoverView.overdueAdvisoryRow`) — writes `editedDeadline`, never `task.deadline` directly
    /// (see that field's own doc comment), so `effectiveDeadline` — and everything that reads
    /// through it (`confirmSave`/`materialize`/`mergeTransform`/`computeConflicts`/the deadline
    /// chip) — picks up the new instant. Clears `overdueSuggestion` right after so the advisory
    /// row disappears once acted on (there's nothing left to suggest — the deadline IS the
    /// suggestion now). Deliberately does NOT touch `dismissed`/`overdueDismissed`: constitution II
    /// says dismiss always wins, and there is no dismiss here to "undo" — if the deadline CHIP
    /// itself was already dismissed, `PopoverView.overdueAdvisoryRow`'s own render guard keeps this
    /// row hidden regardless of what this method does to `overdueSuggestion`.
    func applyOverdueSuggestion(forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }),
              let suggestion = confirmDrafts[index].overdueSuggestion
        else { return }
        confirmDrafts[index].editedDeadline = suggestion.suggestedDeadline
        confirmDrafts[index].overdueSuggestion = nil
    }

    /// T-overdue: dismisses the overdue advisory row WITHOUT changing the deadline — same one-way,
    /// never-re-surfaces-this-session convention as `dismissConflictAdvisory` immediately above.
    func dismissOverdueSuggestion(forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].overdueDismissed = true
    }

    /// The confirm card's editable title `TextField` (`PopoverView.taskDraftCard`) calls this on
    /// every keystroke. `ConfirmDraft` is a VALUE type (`struct`, unlike the Windows port's
    /// `ConfirmDraft` class) — mutating a local copy of the draft would silently lose the edit the
    /// instant that copy goes out of scope, so this MUST reach through `confirmDrafts[index]` the
    /// same way every other chip mutator in this section already does (self-review "value-type
    /// trap": the array is the only thing `PopoverView`/`materialize` actually read back from).
    /// Deliberately does NOT call `logCorrection` — a title edit isn't a chip attribute correction,
    /// it's free-text authorship, same reason `task.title` itself was never a `ChipKind`.
    func updateDraftTitle(_ title: String, forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].editedTitle = title
    }

    /// T-edit-deadline (2026-07-28, anh Khôi: manual in-place time edit on the confirm card): the
    /// deadline `DatePicker`'s (`PopoverView.DeadlineControl`) write side — sets `editedDeadline`,
    /// never `task.deadline` directly, same "never mutate the parser's `ParsedTask`" contract
    /// `updateDraftTitle` above already follows for the title. Works identically whether the draft
    /// already had a deadline (editing it) or had none at all (`DeadlineControl`'s "Add time"
    /// affordance) — either way this is the ONLY write path, so `effectiveDeadline` picks it up
    /// the same way in both cases; there is no separate "first time" branch to keep in sync.
    func setDraftDeadline(_ date: Date, forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].editedDeadline = date
    }

    /// T-edit-attrs (2026-07-29, manual-edit-contract.md §1.2): the priority chip's `Menu` write
    /// side (`PopoverView.attributeChips`) — sets `editedPriority`, never `task.priority` directly,
    /// same "never mutate the parser's `ParsedTask`" contract `setDraftDeadline` above already
    /// follows. MUST reach through `confirmDrafts[index]`, never a local copy — `ConfirmDraft` is a
    /// `struct`, so mutating a copy silently loses the edit the instant it goes out of scope (same
    /// value-type trap `updateDraftTitle`'s doc comment warns about). Does NOT touch `dismissed` —
    /// constitution II: dismiss always wins, same as `setDraftDeadline`.
    func setDraftPriority(_ raw: Int, forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].editedPriority = raw
    }

    /// Same shape/reasoning as `setDraftPriority` immediately above, for the start-time chip's
    /// `.popover` `DatePicker` write side.
    func setDraftStartTime(_ date: Date, forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].editedStartTime = date
    }

    /// Same shape/reasoning as `setDraftPriority` above, for the estimate/duration chip's preset
    /// list write side.
    func setDraftEstimateMinutes(_ minutes: Int, forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].editedEstimateMinutes = minutes
    }

    /// Same shape/reasoning as `setDraftPriority` above, for the reminder-cadence chip's preset
    /// list write side. Stores the RAW period only — `ConfirmDraft.effectiveReminderOverride` is
    /// where that gets folded into a full `ReminderPolicy` at read time, same "normalize once, at
    /// read time" split `updateDraftNotes`'s doc comment documents for notes below.
    func setDraftRemindPeriod(_ seconds: TimeInterval, forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].editedRemindPeriod = seconds
    }

    /// T-edit-notes (2026-07-28, same request as `setDraftDeadline` above): the notes editor's
    /// write side, same value-type/array-mutation-trap reasoning `updateDraftTitle`'s own doc
    /// comment already gives (`confirmDrafts[index]`, never a local copy). Deliberately does NOT
    /// trim/flatten here — `effectiveNotes` (see `ConfirmDraft`) is where that normalization
    /// happens, exactly once, at read time; storing the raw in-progress text here (including a
    /// trailing newline mid-edit) is what lets a multi-line `TextField`/`TextEditor` keep working
    /// normally while the user is still typing.
    func updateDraftNotes(_ notes: String, forDraft draftID: ConfirmDraft.ID) {
        guard let index = confirmDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        confirmDrafts[index].editedNotes = notes
    }

    /// Constitution V / FR-044: every chip edit is logged locally (never egressed) as the signal
    /// for improving parsing over time. Goes through `TaskStore.recordCorrection` (added
    /// alongside this task, since `ParseCorrectionLog.record` — the real T026 API,
    /// `Volar/Sources/Model/ParseCorrection.swift` — needs a `ModelContext` this file has no other
    /// way to reach). No-op (skipped, not crashed) in the no-store fallback used by
    /// previews/tests — logging is a best-effort local record, never load-bearing for save.
    private func logCorrection(kind: ChipKind?, attribute: String? = nil, task: ParsedTask, correctedValue: String) {
        let attributeName = attribute ?? kind?.rawValue ?? "unknown"
        store?.recordCorrection(
            attribute: attributeName,
            parsed: parsedValueDescription(kind: kind, task: task),
            corrected: correctedValue,
            transcript: task.sourceTranscript
        )
    }

    private func parsedValueDescription(kind: ChipKind?, task: ParsedTask) -> String {
        switch kind {
        case .deadline: return task.deadline.map { "\($0.value)" } ?? ""
        case .estimate: return task.estimateMinutes.map { "\($0.value)" } ?? ""
        case .priority: return task.priority.map { "\($0.value)" } ?? ""
        case .reminder: return task.reminderOverride.map { "\($0.value)" } ?? ""
        case .recurrence: return task.recurrence.map { "\($0.value)" } ?? ""
        case .kind: return task.kind.rawValue
        case .followUpReview: return "\(task.followUpReview)"
        case .startTime: return task.startTime.map { "\($0.value)" } ?? ""
        case nil: return "" // condition corrections describe themselves via `attribute`
        }
    }

    /// T025: materializes every confirmed draft through `TaskStore` validation (cycle rejection
    /// surfaces its human-readable message rather than crashing; the 10-task cap is enforced by
    /// `addBatch` itself). Preserves glance-and-dismiss + Enter-to-save (`PopoverView`'s
    /// `.keyboardShortcut(.defaultAction)` on the Save button, unchanged) and the frozen
    /// zero-argument signature.
    ///
    /// 2026-07-28 (confirm-list data layer): now a THREE-part save rather than a flat map —
    ///
    /// 1. Việc 1: `confirmDrafts.filter(\.isIncluded)` first. An unticked draft is saved nowhere,
    ///    isn't a candidate to merge into, and can't be an intra-batch `.taskDone` target (handled
    ///    below by simply never appearing in `targetID`).
    /// 2. Việc 3: every included draft gets its post-save IDENTITY decided up front — a freshly
    ///    minted id for `.addNew` (explicit, not left to `TaskItem.init`'s own default, so this
    ///    method can look it up again below), or the ALREADY-PERSISTED id for `.useExisting` (that
    ///    draft creates nothing; it merges into the existing task instead, see `mergeTransform`).
    ///    A `.useExisting` target that no longer exists in `before` (deleted between the confirm
    ///    card appearing and Save — this data layer has no live re-poll yet) degrades to `.addNew`
    ///    rather than merging into a dangling id or losing the draft (self-review "no crash/no
    ///    dangling id").
    /// 3. Việc 2: intra-batch `.taskDone` conditions are resolved to real ids via that SAME
    ///    `targetID` map — which is exactly why it has to exist before anything is created: the
    ///    referenced draft can appear later in `confirmDrafts` than the one depending on it. A
    ///    reference to a draft that isn't in `targetID` (unticked, or never existed) is simply
    ///    dropped, never attached to a nonexistent id (self-review "explicit handling of both
    ///    branches", task brief Việc 2.4).
    ///
    /// The store path commits in THREE ordered steps — new tasks (`addBatch`, chunked exactly as
    /// before), then merges (`TaskStore.mergeIntoExisting`), then intra-batch conditions
    /// (`TaskStore.addCondition`) — because step 3 needs every id from steps 1 and 2 to already be
    /// real. A failure in step 1 aborts before steps 2/3 ever run (same "leave `confirmDrafts`
    /// intact, let the user retry" contract the pre-existing catch block already had); a rejected
    /// edge in step 3 (should not happen — see the `confirmCycle == nil` guard and step 3's own
    /// comment below for why, per cycle-detection-contract.md §2) now surfaces through the shared
    /// `catch` below rather than being silently dropped via `try?`, same as every other failure in
    /// this method.
    ///
    /// task_refs_v1 (2026-08-02) adds a FOURTH step, threaded in between steps 2 and 3 above: every
    /// surviving `.existing`-target `ConfirmUpdateDraft` (`self.confirmUpdateDrafts`, snapshotted as
    /// `updateDrafts` right after `includedDrafts` below) writes its scalar fields
    /// (deadline/startTime/priority/notesAppend) onto the ALREADY-persisted target task, and its
    /// `addConditions` fold into the SAME `attachments` list step 3 already builds — both AFTER
    /// `targetID` exists (a `taskDoneNewTask` reference needs a just-minted new-task id, same
    /// "why this can't run any earlier" reasoning step 3 itself documents) but BEFORE the store's
    /// single post-mutation refresh, so one `tasks = store.fetchAll()` picks up everything. See the
    /// update-draft loops themselves (search `task_refs_v1`) for exactly why they call `TaskStore.
    /// updateEditableFields(from:)` directly rather than `AppState.updateTask` (duplicate-
    /// notification risk) and fold their target ids into `remindersTargetIDs` instead.
    func confirmSave() {
        // cycle-detection-contract.md §2: safety net. `PopoverView` already locks the Save button
        // (and its `.keyboardShortcut(.defaultAction)`) while `confirmCycle != nil`, but this
        // guard is the one place that's actually load-bearing — Enter/hotkey routes here directly
        // (`handleHotkey`'s `.parsed` case) without going through any button `.disabled` state at
        // all, so a stale/missed `recomputeConfirmCycle()` call must not be the only thing
        // standing between a cyclic batch and the store.
        guard confirmCycle == nil else { return }
        guard !confirmDrafts.isEmpty else { return }
        captureState = .saving
        let now = clock()
        // T031: snapshot taken BEFORE this batch materializes, so the eligibility diff below sees
        // exactly what this save changed (and nothing from a concurrent mutation elsewhere, since
        // this whole method runs synchronously on @MainActor).
        let before = tasks

        // Việc 1: unticked drafts are saved nowhere and can never be an intra-batch target —
        // simply excluding them from every list below (`targetID`, `itemsToSave`, merges) is
        // enough; nothing downstream needs a separate "is this included?" check.
        let includedDrafts = confirmDrafts.filter(\.isIncluded)
        guard !includedDrafts.isEmpty else {
            // Every draft was unticked (unreachable today — no UI sets `isIncluded = false` yet,
            // see that field's doc comment — but handled explicitly rather than left to crash or
            // silently misbehave once lượt 2b's checkbox exists). Nothing to persist; close out
            // quietly rather than announcing "0 tasks saved" via `finishSaveUI`.
            confirmDrafts = []
            // task_refs_v1: the user backed all the way out of this batch's new tasks, so any
            // pending update card goes with it too — see this method's doc comment addendum for why
            // this specific (today-unreachable) branch takes the conservative "whole batch" reading
            // rather than trying to keep a same-session update card alive with nothing left to
            // anchor its batch-order guarantees to.
            confirmUpdateDrafts = []
            captureState = .idle
            liveTranscript = ""
            return
        }

        // task_refs_v1: snapshot once, same "everything below reads THIS snapshot, never
        // `self.confirmUpdateDrafts` live" discipline `includedDrafts` above already follows.
        let updateDrafts = confirmUpdateDrafts
        // self-review "nothing user-said silently lost": an update still `.unresolved` at Save — the
        // picker (`PopoverView`'s `.unresolved` card) was on screen the whole time and the user
        // neither picked a target nor dismissed it — is dropped below (never attached to a guess,
        // constitution II), but RECORDED as a drop first, same local-telemetry convention
        // `dismissCondition`/`resolveTaskDone`'s "dropped" correctedValue already uses for every
        // other silent-ish drop in this file (`AppState.logCorrection`) — this one goes straight to
        // `TaskStore.recordCorrection` instead of through that helper because `ConfirmUpdateDraft`
        // has no `ParsedTask` to describe (see that struct's own doc comment on `sourceTitleQuery`).
        for draft in updateDrafts where !draft.cardDismissed && draft.resolution == .unresolved {
            store?.recordCorrection(
                attribute: "taskRef[\(draft.refIndex)]",
                parsed: draft.sourceTitleQuery,
                corrected: "unresolved-dropped-at-save",
                transcript: draft.sourceTitleQuery
            )
        }

        // Việc 3 self-review: a `.useExisting` target that vanished since the draft was built
        // (deleted from `before` — this confirm-list has no live re-poll) degrades to `.addNew`
        // rather than merging into a dangling id.
        let currentTaskIDs = Set(before.map(\.id))
        func effectiveResolution(_ draft: ConfirmDraft) -> ConfirmDraft.DuplicateResolution {
            if case .useExisting(let id) = draft.duplicateResolution, !currentTaskIDs.contains(id) {
                return .addNew
            }
            return draft.duplicateResolution
        }

        // Việc 2/3: every included draft's post-save identity, decided BEFORE anything is created
        // so intra-batch `.taskDone` conditions (which may reference a draft appearing later in
        // `confirmDrafts`) always have a real id to resolve against.
        var targetID: [ConfirmDraft.ID: UUID] = [:]
        for draft in includedDrafts {
            switch effectiveResolution(draft) {
            case .addNew: targetID[draft.id] = UUID()
            case .useExisting(let existingID): targetID[draft.id] = existingID
            }
        }

        var itemsToSave: [TaskItem] = []
        var mergeDrafts: [ConfirmDraft] = []
        for draft in includedDrafts {
            guard let id = targetID[draft.id] else { continue } // unreachable: built from includedDrafts above
            let parentTitle: String
            let parentSourceTranscript: String?
            switch effectiveResolution(draft) {
            case .addNew:
                let item = materialize(draft, id: id, now: now)
                itemsToSave.append(item)
                parentTitle = item.title
                parentSourceTranscript = item.sourceTranscript
            case .useExisting:
                mergeDrafts.append(draft)
                // No new `TaskItem` for a merge — but the followUpReview chip below still needs
                // something to name the derived review after; the utterance's own resolved title
                // reads fine even though the merge itself may keep the OLDER task's title.
                parentTitle = draft.effectiveTitle
                parentSourceTranscript = draft.task.sourceTranscript
            }
            // Mi-1: the "+ review after done" chip is dismissible (defaults on, per
            // `ChipKind.followUpReview`'s doc comment) — only materialize the derived `.review`
            // task when the user hasn't dismissed it. `id` here is the SAME post-save identity
            // (fresh or merge-target) an intra-batch condition elsewhere in this batch would also
            // resolve to — a follow-up review is just as valid a dependent either way.
            if draft.task.followUpReview, !draft.dismissed.contains(.followUpReview) {
                itemsToSave.append(materializeFollowUpReview(
                    parentID: id, parentTitle: parentTitle, sourceTranscript: parentSourceTranscript, now: now
                ))
            }
        }

        // Việc 2, pass two's payload: every intra-batch `.taskDone` this batch resolved, translated
        // from "the OTHER draft's id" into "the other draft's REAL post-save id" via `targetID`.
        // Computed once here (pure — no store/`tasks` mutation yet) so both the store and no-store
        // branches below can apply the identical list.
        var intraBatchAttachments: [(ownID: UUID, condition: VolarCore.Condition)] = []
        for draft in includedDrafts {
            guard let ownID = targetID[draft.id] else { continue }
            for (index, referencedDraftID) in draft.intraBatchTaskDone {
                // Dismiss always wins (constitution II) — same guard `resolvedConditions` applies
                // to every other condition kind.
                guard !draft.dismissedConditions.contains(index) else { continue }
                // The referenced draft is unticked, was removed from the batch, or (defensively)
                // never existed: Việc 2.4 says drop the condition rather than point at nothing.
                guard let refID = targetID[referencedDraftID], refID != ownID else { continue }
                intraBatchAttachments.append((ownID: ownID, condition: .taskDone(refID)))
            }
        }

        // task_refs_v1: fold in the two OTHER sources of a same-batch condition attachment —
        // (a) `ConfirmDraft.refConditions`, added by `mergeUpdateIntoSibling` when a reference
        // resolved to a SIBLING draft (see that field's own doc comment), and (b) a surviving
        // `.existing`-target `ConfirmUpdateDraft`'s own `addConditions`, whose `taskDoneNewTask`
        // needs `targetID` to resolve the 1-based index into a REAL, just-minted id — which is
        // exactly why neither can be computed any earlier than here (self-review "save-order
        // correctness"). One combined list so the SAME try-loop (store path) / append loop
        // (no-store path) below attaches every kind identically.
        //
        // UNVERIFIED / known scope boundary (self-review "known scope boundary"): unlike
        // `intraBatchTaskDone`/`resolvedTaskDone`, neither of these two sources feeds
        // `recomputeConfirmCycle()` — a cycle introduced ONLY through a reference update will not
        // show the pre-save `PopoverView` warning row, but is still caught here: `store.
        // addCondition` below re-validates every `.taskDone` attachment (including these) and
        // throws, surfacing through the SAME `catch` block as any other rejected edge (see that
        // catch's own comment). The no-store fallback has no such backstop (previews/tests only,
        // never a real save) — flagged as a follow-up, not fixed in this round.
        var attachments = intraBatchAttachments
        for draft in includedDrafts {
            guard let ownID = targetID[draft.id] else { continue }
            for (index, ref) in draft.refConditions.enumerated() {
                guard !draft.dismissedRefConditions.contains(index) else { continue }
                guard case .taskDone(let referencedDraftID) = ref else { continue }
                guard let refID = targetID[referencedDraftID], refID != ownID else { continue }
                attachments.append((ownID: ownID, condition: .taskDone(refID)))
            }
        }
        for draft in updateDrafts where !draft.cardDismissed {
            // `.unresolved` was already logged and is dropped here (no target to attach to);
            // `.sibling` never reaches `confirmUpdateDrafts` at all (see `ConfirmUpdateDraft`'s doc
            // comment) — either way, only `.existing` has anything to attach.
            guard case .existing(let existingID) = draft.resolution else { continue }
            for (index, condition) in draft.addConditions.enumerated() where !draft.dismissedAddConditions.contains(index) {
                switch condition {
                case .taskDoneNewTask(let refIndex):
                    // 1-based into `ParsedCapture.tasks` == `confirmDrafts`' own order — both were
                    // built from the SAME `capture.tasks` array, 1:1 (`ParsedUpdateCondition.
                    // taskDoneNewTask`'s own pinned doc comment states this indexing convention).
                    guard confirmDrafts.indices.contains(refIndex - 1) else { continue }
                    guard let refID = targetID[confirmDrafts[refIndex - 1].id] else { continue } // unticked/never existed — dropped, never attached to nothing
                    attachments.append((ownID: existingID, condition: .taskDone(refID)))
                case .afterDate(let date):
                    attachments.append((ownID: existingID, condition: .afterDate(date)))
                }
            }
        }

        let mergedTitles = mergeDrafts.map(\.effectiveTitle)
        let mergedIDs = mergeDrafts.compactMap { targetID[$0.id] }
        let savedTitles = itemsToSave.map(\.title) + mergedTitles
        // task_refs_v1: every surviving `.existing`-target update draft's id, folded into the SAME
        // list `scheduleRemindersForSavedItems` already processes at this method's single batched
        // tail — this is how "deadline/startTime changes MUST re-derive reminders" (task brief) is
        // satisfied WITHOUT calling `AppState.updateTask` per draft (see the scalar-field-write
        // comment further down for why that would double-fire a real notification).
        let updateTargetIDs = updateDrafts.compactMap { draft -> UUID? in
            guard !draft.cardDismissed, case .existing(let id) = draft.resolution else { return nil }
            return id
        }
        let remindersTargetIDs = itemsToSave.map(\.id) + mergedIDs + updateTargetIDs

        guard let store else {
            // No-store fallback (previews/tests without a TaskStore) — mirrors `addTask`'s own
            // no-store branch: in-memory only, no validation (there is no store to validate against).
            tasks.insert(contentsOf: itemsToSave.reversed(), at: 0)
            // Việc 3: apply each merge directly onto its `tasks` entry — same "no validation, this
            // is the no-store fallback" convention the rest of this branch already follows.
            for draft in mergeDrafts {
                guard let existingID = targetID[draft.id],
                      let index = tasks.firstIndex(where: { $0.id == existingID })
                else { continue }
                tasks[index] = mergeTransform(for: draft)(tasks[index])
            }
            // task_refs_v1: apply each surviving `.existing`-target update draft's scalar fields
            // directly — no-store fallback, same "no validation" convention as the merge loop right
            // above. Must run BEFORE the attachments loop below for no particular ordering reason
            // (the two touch disjoint parts of a `TaskItem`), but grouped here to mirror the store
            // branch's own step order exactly.
            for draft in updateDrafts where !draft.cardDismissed {
                guard case .existing(let existingID) = draft.resolution,
                      let index = tasks.firstIndex(where: { $0.id == existingID })
                else { continue } // deleted between parse and Save — no-op, matches `TaskStore.updateEditableFields`'s own guard for the store path below
                tasks[index] = updatedTaskItem(applying: draft, to: tasks[index])
            }
            // Việc 2 pass two, in-memory: append each resolved intra-batch/ref/update condition
            // directly (task_refs_v1: `attachments` now also carries `ConfirmDraft.refConditions`
            // and `ConfirmUpdateDraft.addConditions` — see that combined list's own comment above).
            for attachment in attachments {
                guard let index = tasks.firstIndex(where: { $0.id == attachment.ownID }) else { continue }
                if !tasks[index].conditions.contains(attachment.condition) {
                    tasks[index].conditions.append(attachment.condition)
                }
            }
            notifyEligibilityAndScheduleResurface(before: before, now: now)
            scheduleRemindersForSavedItems(remindersTargetIDs) // no-op: `scheduler` is nil without a store
            finishSaveUI(titles: savedTitles)
            // FIX 6: membership change (new tasks, possibly with new deadlines).
            syncCalendarMirror()
            return
        }

        // M-1: a `followUpReview` draft appends a SECOND item (the derived `.review` task), so
        // `itemsToSave.count` can exceed `TaskStore.maxBatchSize` even though the parse itself
        // stayed within the FR-012 ≤10-PARSED-tasks cap (e.g. 6 parsed tasks each with a
        // follow-up review = 12 items). `addBatch` throws `.batchTooLarge` above that limit, so a
        // single call here would make an otherwise-valid parse unsaveable. Splitting into
        // sequential ≤`maxBatchSize` chunks — each committed via its own `addBatch` call, in
        // order — fixes that without raising the parse cap itself. Order is preserved across
        // chunks, so a parent always commits at or before the chunk containing its dependent
        // review: if a chunk boundary falls between them, the parent's chunk has already `save()`d
        // by the time the review's chunk builds its `allEngineSnapshot()`, so the review's
        // `.taskDone(parent.id)` condition still validates correctly.
        let chunks = stride(from: 0, to: itemsToSave.count, by: TaskStore.maxBatchSize).map {
            Array(itemsToSave[$0..<min($0 + TaskStore.maxBatchSize, itemsToSave.count)])
        }

        do {
            for chunk in chunks {
                try store.addBatch(chunk)
            }
            // Việc 3: merges only ever touch an ALREADY-persisted task, so they never depend on
            // anything the chunk loop above just created — but doing them right after keeps every
            // store mutation for this `confirmSave()` grouped before the single refresh below.
            for draft in mergeDrafts {
                guard let existingID = targetID[draft.id] else { continue }
                store.mergeIntoExisting(existingID, applying: mergeTransform(for: draft))
            }
            // task_refs_v1: same "after new tasks/merges, before the attachments loop" placement as
            // the no-store branch above — deliberately NOT `AppState.updateTask` (which would call
            // `scheduler?.scheduleReminders`/`notifyEligibilityAndScheduleResurface`/
            // `syncCalendarMirror` a SECOND time per draft, on top of this method's own single
            // batched tail below). `ReminderScheduler.notifyUnblocked` is NOT idempotent — it
            // inserts and immediately DELIVERS a new `ReminderRecord`/notification every call — so
            // calling it once per update draft AND again for the whole batch would double-fire a
            // real, user-visible alert. Reminders still re-derive correctly: `existingID` is folded
            // into `remindersTargetIDs` above, which `scheduleRemindersForSavedItems` (this
            // method's existing single tail call, unchanged) re-derives for every id it's handed —
            // satisfying "deadline/startTime changes MUST re-derive reminders" without a second
            // reminder/eligibility/calendar pass.
            //
            // `mergeIntoExisting`, NOT `updateEditableFields(from:)` built off the in-memory
            // `tasks` snapshot (Opus review, 2026-08-02): `updateEditableFields` copies EVERY
            // editable field from the item it's handed, and the in-memory snapshot is stale by
            // this point whenever the merge loop right above already committed to this SAME target
            // id (a duplicate-merge appending notes to X while this update only moves X's deadline
            // — a stale-base copy would silently revert those notes). The closure receives the
            // FRESH post-merge row straight from the DB, and `updatedTaskItem` only touches the
            // fields this update actually resolved, so nothing else can be dragged backwards.
            // Unknown id (deleted between parse and Save) is `mergeIntoExisting`'s own documented
            // no-op — same convention as before.
            for draft in updateDrafts where !draft.cardDismissed {
                guard case .existing(let existingID) = draft.resolution else { continue }
                store.mergeIntoExisting(existingID) { self.updatedTaskItem(applying: draft, to: $0) }
            }
            // Việc 2, pass two: attach every intra-batch/ref/update `.taskDone`/`.afterDate` now
            // that every end (new, merged, OR already-existing) has a real, persisted id.
            // cycle-detection-contract.md §2: this USED to be `try?`, silently dropping a rejected
            // edge — but `recomputeConfirmCycle()` (called after every edit) plus the
            // `confirmCycle == nil` guard at the top of this method mean a batch that reaches here
            // should already be acyclic FOR THE EDGES IT COVERS. task_refs_v1's `refConditions`/
            // `addConditions` edges are NOT among those (see `attachments`'s own comment above) — so
            // for THOSE two specifically, this `try` is the first and only cycle check, not a "should
            // not happen" backstop. Either way, a throw here surfaces through the shared `catch`
            // below rather than being silently dropped — a task that's already committed by the time
            // this throws stays committed either way (this loop runs strictly after the `addBatch`/
            // merge/update steps above), just without the one edge that failed.
            for attachment in attachments {
                try store.addCondition(attachment.condition, to: attachment.ownID)
            }
            // Phase-2 refresh-from-store convention (auto-advance + menu bar stay correct).
            tasks = store.fetchAll()
            notifyEligibilityAndScheduleResurface(before: before, now: now)
            scheduleRemindersForSavedItems(remindersTargetIDs)
            finishSaveUI(titles: savedTitles)
            // FIX 6: membership change (new tasks, possibly with new deadlines) — every chunk
            // committed successfully by this point.
            syncCalendarMirror()
        } catch {
            // Cycle rejection / batch-too-large / any other `TaskStoreError` surfaces its
            // human-readable message instead of crashing; `confirmDrafts` is left intact so the
            // user can adjust (e.g. drop a condition) and retry rather than losing the capture.
            // A failure on a LATER chunk (after earlier chunks already committed) is refreshed
            // from the store here too, so the UI never shows stale/duplicate state for the part
            // that did save — the user only re-confirms what's genuinely still outstanding.
            // Merges/task_refs_v1 update-field-writes/intra-batch conditions never ran (they're only
            // reached after the `do` block's `addBatch` chunk loop finishes without throwing), so
            // there is nothing further to unwind here. If instead the `attachments` loop itself is
            // what throws (reachable now that it also carries task_refs_v1's `refConditions`/
            // `addConditions` edges — see that loop's own comment), everything ABOVE it in the `do`
            // block — new tasks, merges, AND update-field writes — has already committed and stays
            // committed; only the one failing edge (and any after it in `attachments`) is lost, same
            // "partial success on this one edge, not a full rollback" behavior this catch already
            // documented for merges before task_refs_v1 added a second source of a throwing edge.
            tasks = store.fetchAll()
            notifyEligibilityAndScheduleResurface(before: before, now: now)
            scheduleRemindersForSavedItems(itemsToSave.map(\.id))
            captureErrorDetail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            captureState = .error
            // FIX 6: an earlier chunk may have committed successfully before this failure (see the
            // comment above `tasks = store.fetchAll()` just above) — keep the mirror in step with
            // whatever partial state actually persisted, same as every other refresh in this catch.
            syncCalendarMirror()
        }
    }

    /// Việc 3: the merge-into-existing overlay, as a PURE `TaskItem -> TaskItem` transform so it
    /// can be shared verbatim between the store path (`TaskStore.mergeIntoExisting`, which applies
    /// it via `VolarTask.apply(_:)` behind its own cycle/rule-2 guards) and the no-store fallback
    /// (which applies it directly to a `tasks` element, matching that branch's existing "no
    /// validation" convention). Scalar attributes overwrite the existing value ONLY when
    /// `AppState.resolvedValue` says this draft actually resolved one (present, not dismissed, and
    /// accepted if uncertain — the SAME gate a brand-new task's `materialize(_:id:now:)` already
    /// applies) — `nil` from `resolvedValue` here means "this utterance said nothing about this
    /// attribute," so the existing task's value is left exactly as it was, never cleared. Anh Khôi
    /// deliberately did NOT ask for `title`/`kind` to be touched by a merge, so this leaves those
    /// alone — merging `title` would mean renaming an already-existing task, a different and
    /// unrequested feature. `notes` is DIFFERENT (anh Khôi chốt 2026-07-29): it used to sit in this
    /// same "left alone" group, but that was only ever true because notes couldn't be edited on the
    /// confirm card at all — once T-edit-notes (2026-07-28) added `PopoverView.NotesEditorControl`,
    /// picking "use existing" + typing a note started silently discarding whatever the user just
    /// typed on Save, with no warning. So `notes` now merges too, via `mergeNotesAppending` below —
    /// see that function's own doc comment for why it APPENDS rather than overwrites like every
    /// scalar attribute in this method, and why it writes through to `details` as well as `notes`.
    /// Conditions are UNIONED (de-duplicated), never replaced — anh Khôi: "có thể merge tất
    /// cả condition vào" — intra-batch `.taskDone` entries are excluded from this union on purpose
    /// (same as a brand-new task, `resolvedConditions` never includes them) since they're attached
    /// separately, after every draft's real/merge-target id is known (`confirmSave`'s second pass).
    private func mergeTransform(for draft: ConfirmDraft) -> (TaskItem) -> TaskItem {
        // `[self]` rather than six `self.` prefixes: this closure escapes (it is handed to
        // `TaskStore.mergeIntoExisting`), so the compiler requires the capture to be spelled out,
        // and the capture list says it once at the top instead of repeating it at every call. A
        // STRONG capture is deliberate and safe here — the closure is applied during the same
        // `confirmSave()` call and never stored on `self`, so there is no cycle to break; a
        // `[weak self]` would only add an optional to unwrap on a path that cannot outlive `self`.
        { [self] existing in
            var merged = existing
            // T-overdue (self-review "save path"): reads through `effectiveDeadline`, NOT
            // `draft.task.deadline` directly — a merge that resolved from a "Move to tomorrow" tap
            // must carry the EDITED deadline into the existing task, same as a brand-new task's
            // `materialize` below.
            if let deadline = resolvedValue(draft.effectiveDeadline, kind: .deadline, draft: draft) {
                merged.deadline = deadline
            }
            // T-disposition (self-review "save path"): `startTime` is a SCALAR overlay, same shape
            // as `deadline`/`priority`/`estimate`/`reminder`/`recurrence` right around it — NOT in
            // the title/kind group this method's own doc comment says anh Khôi deliberately
            // excluded from merges. It's a plain "when did they mean to start" instant, not
            // free-text authorship, so it follows the scalar convention: present, not dismissed,
            // and confident (or explicitly accepted) overwrites the existing task's value exactly
            // like every other attribute here.
            // T-edit-attrs (manual-edit-contract.md §2): reads through `draft.effective*`, NOT
            // `draft.task.*` directly — same "everywhere this attribute is read" reasoning
            // `effectiveDeadline`'s call sites already document above, applied to the 4 fields
            // T-edit-attrs added. A merge that resolved from a manual chip edit must carry the
            // EDITED value into the existing task, same as a brand-new task's `materialize` below.
            if let startTime = resolvedValue(draft.effectiveStartTime, kind: .startTime, draft: draft) {
                merged.startTime = startTime
            }
            if let priorityRaw = resolvedValue(draft.effectivePriority, kind: .priority, draft: draft) {
                merged.priority = Self.uiPriority(from: priorityRaw)
            }
            if let estimate = resolvedValue(draft.effectiveEstimateMinutes, kind: .estimate, draft: draft) {
                merged.durationMinutes = estimate
            }
            if let reminder = resolvedValue(draft.effectiveReminderOverride, kind: .reminder, draft: draft) {
                merged.reminderOverride = reminder
            }
            if let recurrence = resolvedValue(draft.task.recurrence, kind: .recurrence, draft: draft) {
                merged.recurrence = recurrence
            }
            // T-notes-merge (self-review "save path", anh Khôi chốt 2026-07-29): notes APPEND
            // rather than overwrite — the one deliberate exception to every scalar attribute
            // above. Base is `existing.notes` (not `existing.details`): `materialize` always
            // writes the SAME `effectiveNotes` value into both fields whenever the user actually
            // authored a note, so `existing.notes == existing.details` in that case and either
            // would do; but when a task has never had a real note, `existing.notes` is `nil`
            // while `existing.details` may still hold the sourceTranscript read-back copy
            // `materialize` falls back to for brand-new tasks — that fallback text is filler, not
            // authorship, so `notes` (the one field that is `nil` unless a human actually typed
            // something) is the correct "does this already have a real note" signal to append
            // onto. The result is written to BOTH fields so they stay in the same lockstep
            // `materialize` established — `details` is what `TaskDetailView`/`speakDetails`
            // actually show the user, so writing only `notes` would merge data nobody ever sees.
            if let mergedNotes = Self.mergeNotesAppending(existing: existing.notes, incoming: draft.effectiveNotes) {
                merged.notes = mergedNotes
                merged.details = mergedNotes
            }
            for condition in resolvedConditions(draft) where !merged.conditions.contains(condition) {
                merged.conditions.append(condition)
            }
            // 006-cues-and-waiting (design.md §2 Việc B, task brief: "Cue phải sống sót qua cả
            // đường tạo mới lẫn đường merge"): same scalar-overwrite convention as `deadline`/
            // `startTime`/`priority`/`estimate`/`reminder` above (present wins outright) — NOT
            // the `notes` append exception, since a cue is a single if-then utterance, not
            // free-text that accumulates. Only overwrites when the new draft actually carries one;
            // "xong task A" (an update utterance with no fresh cue) never blanks out a cue the
            // existing task already had.
            if let cue = draft.task.cue {
                merged.cue = cue
            }
            return merged
        }
    }

    /// Combines an existing (already-persisted) task's notes with a confirm draft's incoming
    /// notes for a merge-into-existing save — pure so it can be unit-tested directly without
    /// standing up an `AppState`/`ConfirmDraft` (see `mergeTransform` above for the one call site
    /// and the reasoning for why `notes` appends here while every OTHER attribute in that method
    /// overwrites). Intentionally `internal`, not `private`, for exactly that direct testability —
    /// every other helper around it is `private` because nothing needs to reach them from outside
    /// `mergeTransform`; this one is the deliberate exception.
    ///
    /// Returns `nil` — "leave `notes`/`details` exactly as they are" — when:
    ///   - `incoming` is `nil`, or blank after trimming (the most common case: the user never
    ///     touched the notes field on this draft at all, so `ConfirmDraft.effectiveNotes` is
    ///     whatever the parser produced or nothing; either way there is nothing new to add).
    ///   - `incoming` (trimmed) is already contained verbatim inside `existing` (trimmed) — most
    ///     often because the two are flatly equal (the user re-typed something very close to what
    ///     was already there), but a substring match is caught too so re-reading back a fragment
    ///     of a longer existing note doesn't duplicate it either.
    /// Otherwise returns the combined text: `existing` verbatim if there was none (or it was
    /// blank), else `existing` + `"\n"` + `incoming`, both trimmed of only their leading/trailing
    /// whitespace — same "trim ends, keep internal newlines" contract `ConfirmDraft.effectiveNotes`
    /// already documents, so a multi-line existing note is never mangled by this concatenation.
    static func mergeNotesAppending(existing: String?, incoming: String?) -> String? {
        guard let incoming else { return nil }
        let trimmedIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIncoming.isEmpty else { return nil }

        guard let existing else { return trimmedIncoming }
        let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExisting.isEmpty else { return trimmedIncoming }

        guard !trimmedExisting.contains(trimmedIncoming) else { return nil }
        return trimmedExisting + "\n" + trimmedIncoming
    }

    /// WG-1 (constitution IV): schedules reminders for exactly the ids that actually made it into
    /// `tasks` — filtering against the just-refreshed `tasks` snapshot (rather than assuming every
    /// id in `ids` saved) so a partial-chunk failure in `confirmSave`'s catch branch never
    /// schedules a reminder for a task that was never actually persisted. Takes bare ids (rather
    /// than `[TaskItem]`, the pre-2026-07-28 signature) since `ReminderScheduler.scheduleReminders
    /// (taskId:)` re-reads the task fresh from the store anyway — this lets `confirmSave` pass a
    /// MERGED task's id (whose deadline/reminderOverride may have just changed) alongside brand-new
    /// ones without needing a `TaskItem` for something that was never newly materialized.
    private func scheduleRemindersForSavedItems(_ ids: [UUID]) {
        guard let scheduler else { return }
        let savedIds = Set(tasks.map(\.id))
        for id in ids where savedIds.contains(id) {
            scheduler.scheduleReminders(taskId: id)
        }
    }

    /// One draft -> one `TaskItem`, resolving every `ParsedValue`/`ParsedCondition` per the
    /// contract's "Confirm + materialize" rules. `sourceTranscript` is ALWAYS persisted (closes
    /// the backlog item where `confirmSave` used to hardcode `deadline: nil` for voice tasks —
    /// deadlines, like every other attribute, now come resolved from `ParsedTask`). `id` is now an
    /// explicit parameter (2026-07-28, was `TaskItem.init`'s own default `UUID()`) so
    /// `confirmSave` can mint it BEFORE calling this, record it in `targetID`, and have an
    /// intra-batch `.taskDone` condition elsewhere in the same batch resolve to the exact id this
    /// task ends up with.
    private func materialize(_ draft: ConfirmDraft, id: UUID, now: Date) -> TaskItem {
        let task = draft.task
        // T-overdue (self-review "save path" — THE call site a "Move to tomorrow" tap must reach
        // for the button to do anything at all): `draft.effectiveDeadline`, never `task.deadline`
        // directly, so an applied overdue suggestion actually gets persisted.
        let deadline = resolvedValue(draft.effectiveDeadline, kind: .deadline, draft: draft)
        // T-disposition: same `resolvedValue` gate as every other scalar attribute here — dismissed
        // or unaccepted-uncertain `startTime` is simply absent, never persisted. No "+30 min" math
        // happens here or anywhere else in this file — that derivation already happened at the
        // router/parse layer BEFORE this draft existed (`ParsedTask.deadline` already carries it);
        // this file only ever reads the two values through, never recomputes either.
        // T-edit-attrs (manual-edit-contract.md §2 — THIS is the call site that decides whether a
        // manual chip edit actually gets saved, exactly like `effectiveDeadline` above already is
        // for the deadline chip): reads through `draft.effective*`, never `task.*` directly, or a
        // chip that visually shows the user's edit would still materialize the parser's old value.
        let startTime = resolvedValue(draft.effectiveStartTime, kind: .startTime, draft: draft)
        let estimate = resolvedValue(draft.effectiveEstimateMinutes, kind: .estimate, draft: draft)
        let priorityInt = resolvedValue(draft.effectivePriority, kind: .priority, draft: draft)
        let reminder = resolvedValue(draft.effectiveReminderOverride, kind: .reminder, draft: draft)
        let recurrence = resolvedValue(task.recurrence, kind: .recurrence, draft: draft)
        let kind = draft.dismissed.contains(.kind) ? .task : task.kind

        return TaskItem(
            id: id,
            title: draft.effectiveTitle,
            // `details` is the voice read-back copy (`AppState.speakDetails`'s frozen-field
            // meaning, distinct from `notes` — see TaskItem.swift) — prefer explicit notes, else
            // fall back to the verbatim transcript so read-back is never empty. T-edit-notes:
            // `draft.effectiveNotes`, not `task.notes` directly — same "everywhere notes is read"
            // reasoning `effectiveDeadline`'s call sites already document (self-review "save path").
            details: draft.effectiveNotes ?? task.sourceTranscript,
            priority: Self.uiPriority(from: priorityInt),
            status: .todo,
            deadline: deadline,
            startTime: startTime,
            conditions: resolvedConditions(draft),
            createdAt: now,
            when: .now,
            durationMinutes: estimate,
            frog: false,
            notes: draft.effectiveNotes,
            sourceTranscript: task.sourceTranscript,
            kind: kind,
            recurrence: recurrence,
            reminderOverride: reminder,
            // 006-cues-and-waiting (design.md §2 Việc B): straight pass-through, never resolved/
            // gated the way `deadline`/`priority`/etc. are above — `TaskCue` carries no
            // `ParsedValue`/confidence wrapper (unlike every other scalar attribute here) and no
            // confirm-card chip exists to dismiss/accept it this round, so there is nothing to
            // gate on. `nil` when the parse didn't produce one (no `task_cues_v1` cap, or no real
            // event anchor in the utterance — see `IntentParsing.validateCue`'s own doc comment),
            // exactly like every other optional field here that's simply absent when unparsed.
            cue: task.cue
        )
    }

    /// A `ParsedValue` only materializes if PRESENT, not dismissed, and either confident (>=0.7)
    /// or explicitly accepted (constitution II — never silently commit an uncertain attribute).
    private func resolvedValue<T>(_ value: ParsedValue<T>?, kind: ChipKind, draft: ConfirmDraft) -> T? {
        guard let value, !draft.dismissed.contains(kind) else { return nil }
        guard !value.isUncertain || draft.accepted.contains(kind) else { return nil }
        return value.value
    }

    /// task_refs_v1: `resolvedValue`'s exact same gate (present, not dismissed, confident-or-
    /// accepted), scoped to `ConfirmUpdateDraft.Field` instead of `ChipKind` — see that enum's own
    /// doc comment for why it's a separate small type rather than a `ChipKind` reuse.
    private func resolvedUpdateValue<T>(
        _ value: ParsedValue<T>?, field: ConfirmUpdateDraft.Field, draft: ConfirmUpdateDraft
    ) -> T? {
        guard let value, !draft.dismissed.contains(field) else { return nil }
        guard !value.isUncertain || draft.accepted.contains(field) else { return nil }
        return value.value
    }

    /// task_refs_v1: pure `TaskItem -> TaskItem` transform for one `ConfirmUpdateDraft`'s surviving
    /// fields onto its `.existing` target — same "pure transform shared by the store and no-store
    /// branches" shape `mergeTransform` above already establishes (see that method's own doc
    /// comment for the precedent). `deadline`/`startTime`/`priority` OVERWRITE (present-and-resolved
    /// wins outright, same as a brand-new task's own `materialize`); `notesAppend` reuses
    /// `mergeNotesAppending` VERBATIM — the exact function `mergeTransform`'s own notes handling
    /// already calls — so this is the SAME append-never-overwrite contract, not a second copy of it
    /// (task brief: "notesAppend appends to existing notes... never overwrites").
    private func updatedTaskItem(applying draft: ConfirmUpdateDraft, to existing: TaskItem) -> TaskItem {
        var updated = existing
        if let deadline = resolvedUpdateValue(draft.deadline, field: .deadline, draft: draft) {
            updated.deadline = deadline
        }
        if let startTime = resolvedUpdateValue(draft.startTime, field: .startTime, draft: draft) {
            updated.startTime = startTime
        }
        if let priorityRaw = resolvedUpdateValue(draft.priority, field: .priority, draft: draft) {
            updated.priority = Self.uiPriority(from: priorityRaw)
        }
        if let notesValue = resolvedUpdateValue(draft.notesAppend, field: .notesAppend, draft: draft),
           let combined = Self.mergeNotesAppending(existing: existing.notes, incoming: notesValue) {
            updated.notes = combined
            updated.details = combined
        }
        return updated
    }

    /// Resolves `task.conditions` into `VolarCore.Condition`s per the contract: `.afterDate`/
    /// `.external` map directly once past the same uncertain-accept gate as scalar attributes;
    /// `.taskDone` only ever comes from `resolvedTaskDone` (confident fuzzy match or explicit
    /// picker choice — `preResolveConditions`/`resolveTaskDone`), so an unresolved one is simply
    /// absent here, i.e. DROPPED rather than guessed (constitution II).
    private func resolvedConditions(_ draft: ConfirmDraft) -> [VolarCore.Condition] {
        var result: [VolarCore.Condition] = []
        for (index, condition) in draft.task.conditions.enumerated() {
            guard !draft.dismissedConditions.contains(index) else { continue }
            switch condition {
            case .afterDate(let date, let confidence):
                guard confidence >= 0.7 || draft.acceptedConditions.contains(index) else { continue }
                result.append(.afterDate(date))
            case .external(let description, let confidence):
                guard confidence >= 0.7 || draft.acceptedConditions.contains(index) else { continue }
                result.append(.external(description: description, satisfied: false))
            case .taskDone:
                if let resolved = draft.resolvedTaskDone[index] {
                    result.append(.taskDone(resolved))
                }
            }
        }
        return result
    }

    /// Engine `priority` is `1...4` (contract/data-model.md); the UI `Priority` enum only spans
    /// `1...3` (`TaskItem.swift`'s documented reasoning: "this app never produces those" — until
    /// now, a voice parse legitimately can). Clamp 4 into `.low` rather than crash/force-unwrap;
    /// absent/dismissed/unaccepted-uncertain priority falls back to the existing neutral default.
    private static func uiPriority(from raw: Int?) -> Priority {
        switch raw {
        case 1: return .high
        case 2: return .medium
        case 3, 4: return .low
        default: return .medium
        }
    }

    /// `followUpReview` (contract): a second `.review`-kind task depending on `parentID` via
    /// `.taskDone`. Appended immediately after its parent in `confirmSave`'s batch, so
    /// `TaskStore.addBatch`'s intra-batch snapshot (documented to grow as earlier items in the
    /// SAME batch are accepted) validates the edge without a second pass — and for a Việc 3 merge
    /// target, `parentID` already refers to an ALREADY-persisted task, so the edge validates
    /// trivially against the store's existing snapshot regardless. Takes `parentID`/`parentTitle`/
    /// `sourceTranscript` directly (2026-07-28, was a full `parent: TaskItem`) so `confirmSave` can
    /// call this the same way whether the parent is a brand-new item it just materialized OR an
    /// existing task being merged into (which never gets its own `TaskItem` from this save).
    private func materializeFollowUpReview(parentID: UUID, parentTitle: String, sourceTranscript: String?, now: Date) -> TaskItem {
        TaskItem(
            title: "Review: \(parentTitle)",
            details: "",
            priority: .medium,
            status: .todo,
            deadline: nil,
            conditions: [.taskDone(parentID)],
            createdAt: now,
            when: .later,
            durationMinutes: nil,
            frog: false,
            sourceTranscript: sourceTranscript,
            kind: .review
        )
    }

    /// Shared "Saved" flash + auto-dismiss tail for `confirmSave`'s two success paths (store /
    /// no-store fallback) — unchanged timing/guard behavior from the v1 implementation, just
    /// reading back a task-count-aware phrase for the multi-task case.
    private func finishSaveUI(titles: [String]) {
        captureState = .done
        confirmDrafts = []
        // task_refs_v1: every surviving update draft has already been applied by `confirmSave`
        // (both its store and no-store branches) by the time this runs — cleared here the same way
        // `confirmDrafts` itself is, since there is nothing left pending either way.
        confirmUpdateDrafts = []
        confirmCycle = nil
        runningEngine?.stop()
        voice.speak(titles.count == 1 ? (titles.first ?? "Saved") : "\(titles.count) tasks saved.")
        captureSession += 1
        let session = captureSession
        _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(nanoseconds: 900_000_000)
            guard let self, self.captureSession == session, self.captureState == .done else { return }
            self.captureState = .idle
            self.liveTranscript = ""
        }
    }

    // MARK: - Focus session (mirrors `volar-mac.jsx`'s startFocus/endFocus/completeFocusTask)

    func startFocus() {
        focusSecondsLeft = 25 * 60
        focusPaused = false
        let openNow = openTasks
        focusIndex = openNow.firstIndex { $0.frog } ?? 0
        focusActive = true
        if voiceFeedback {
            voice.speak("Focus session started. \(frogTask?.title ?? "Twenty five minutes.")")
        }
        // FIX B: (re)start the countdown owned by this instance — invalidate any timer left over
        // from a previous session first so two overlapping sessions can never double-decrement.
        // `Timer(timeInterval:repeats:
        // block:)` + `RunLoop.main.add(_:forMode:.common)`) — the `@Sendable` block hops back onto
        // `@MainActor` via `_Concurrency.Task` for the same Swift 6 isolation reason documented
        // there.
        focusTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { @Sendable [weak self] _ in
            _Concurrency.Task { @MainActor [weak self] in
                self?.focusTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        focusTimer = timer
    }

    /// FIX B: 1s tick, moved verbatim from `FocusOverlay.tick()` (see that file's git history) so
    /// the countdown keeps running even while the fullscreen overlay isn't mounted — only the
    /// visuals stayed behind in `FocusOverlay`, not the timing logic.
    private func focusTick() {
        guard focusActive, !focusPaused else { return }
        guard focusSecondsLeft > 0 else {
            endFocus()
            return
        }
        focusSecondsLeft -= 1
        if focusSecondsLeft <= 0 {
            endFocus()
        }
    }

    func endFocus() {
        focusTimer?.invalidate()
        focusTimer = nil
        focusActive = false
        focusSecondsLeft = 25 * 60
        focusPaused = false
    }

    func toggleFocusPause() {
        focusPaused.toggle()
    }

    /// Completes the given task and advances the focus index, clamping into range — mirrors the
    /// prototype's `completeFocusTask`. If that was the last open task, ends the session.
    func completeFocusTask(_ id: UUID) {
        // FIX 3: `remaining` used to be computed as `openTasks.count - 1` BEFORE calling
        // `toggleDone`, assuming completing one task always drops the open count by exactly one.
        // That's not true: `TaskStore.completeOne` (TaskStore.swift:394) resets a task with a
        // `recurrence` back to `.status == .todo` in place rather than closing it — it stays in
        // `openTasks`, a delta of 0, not -1 — and `TaskStore.toggle`'s parent auto-complete
        // cascade (TaskStore.swift:367-369) can additionally close the now-childless parent in
        // the same call, a delta of -2. Reading `openTasks.count` fresh AFTER `toggleDone` (which
        // itself refreshes `tasks` from the store) reports whichever of those actually happened
        // instead of guessing "-1".
        toggleDone(id)
        let remaining = openTasks.count
        focusIndex = remaining > 0 ? max(0, min(focusIndex, remaining - 1)) : 0
        if remaining == 0 {
            focusActive = false
        }
        if voiceFeedback {
            voice.speak(remaining > 0 ? "Done. \(remaining) left today." : "Done. All clear.")
        }
    }

    func readDayAloud() {
        // Mirrors `readDay` in volar-mac.jsx: announces open task count + up to 3 titles, or
        // "All clear" when empty. `VoicePlayback.readDay` reads `openTasks` off this instance.
        voice.readDay(self)
    }

    // MARK: - Switch ("đổi gió") — first-class, non-judgmental alternative to `completeFocusTask`
    // UNVERIFIED: authored on Windows, no Swift/Xcode toolchain available here — none of this
    // section (through `switchDashboardActiveTask()` below) has been compiled or run. Needs a Mac
    // build + `FocusSwitchTests` pass before shipping (see this session's final report for the
    // exact verify checklist).

    /// Anh Khôi's explicit framing (backlog 2026-07-15 (l)): an ADHD brain runs on novelty —
    /// changing what you're working on isn't giving up, it's how the brain actually works. Focus
    /// Lock was already a SOFT lock (`goToPrevious`/`goToNext` in `FocusOverlay` already let you
    /// move off the current task); this makes leaving-on-purpose a first-class action with its own
    /// name, equal in standing to `completeFocusTask`/`toggleDone`, instead of an unlabeled side-
    /// effect of the arrow keys or something that only lives in `FocusOverlay`.
    ///
    /// Pure: the ONE replacement task Switch should hand the focus slot to, given the full
    /// still-open snapshot and the id of whatever currently occupies it. Filters `currentID` OUT
    /// of the snapshot and re-runs `VolarCore.nextTask` on what's left — this app layer never
    /// reimplements the engine's own eligibility/ordering rules, it only excludes one task before
    /// asking again. Returns `nil` when nothing else is eligible (the excluded task was the only
    /// one open, or every remaining task is blocked/ineligible), so the caller can leave the slot
    /// alone instead of "switching" into nothing.
    ///
    /// `now`/`calendar` are parameters, never read internally (repo convention — see
    /// `VolarCore.nextTask`'s own doc comment and `TaskSections.swift`'s file header), so this
    /// stays a pure, deterministic, directly-testable function.
    static func nextSwitchTarget(
        excluding currentID: UUID,
        from openTasks: [TaskItem],
        now: Date,
        calendar: Calendar
    ) -> TaskItem? {
        let remaining = openTasks.filter { $0.id != currentID }
        guard !remaining.isEmpty else { return nil }
        let engineTasks = remaining.map { $0.snapshot() }
        guard let winner = VolarCore.nextTask(from: engineTasks, now: now, calendar: calendar) else { return nil }
        return remaining.first { $0.id == winner.id }
    }

    /// FR-030: once a task's `switchAwayCount` first reaches this many, it earns the one-time
    /// breakdown invite (`switchBreakdownSuggestion`).
    private static let switchBreakdownThreshold = 3

    /// Shared tail of EVERY Switch action, wherever it was triggered from (`FocusOverlay`'s
    /// fullscreen Switch or `TodayView`'s hero-card Switch) — the one and only place
    /// `switchAwayCount` is written, so the two call sites can never drift on how counting works.
    /// Bumps `left`'s `switchAwayCount` by exactly 1 (store-backed when a real `TaskStore` exists,
    /// via the EXISTING `mergeIntoExisting` — no new `TaskStore` method needed; in-memory fallback
    /// otherwise, same convention `toggleDone`'s own `guard let store else { … }` branch uses), then
    /// checks the FR-030 threshold. Deliberately the ONLY field this touches: no `status` change,
    /// no other mutation, on `left` or anyone else.
    private func recordSwitchAway(from left: TaskItem) {
        guard let store else {
            var newCount = left.switchAwayCount + 1
            if let index = tasks.firstIndex(where: { $0.id == left.id }) {
                tasks[index].switchAwayCount = newCount
            } else {
                // Unknown id (shouldn't happen — `left` always comes from a live `tasks` read just
                // above the call site) — still evaluate the threshold off the value we WOULD have
                // written, rather than silently skipping the FR-030 check.
                newCount = left.switchAwayCount + 1
            }
            maybeOfferBreakdown(taskID: left.id, newCount: newCount)
            return
        }
        let updated = store.mergeIntoExisting(left.id) { task in
            var updated = task
            updated.switchAwayCount += 1
            return updated
        }
        tasks = store.fetchAll()
        maybeOfferBreakdown(taskID: left.id, newCount: updated?.switchAwayCount ?? (left.switchAwayCount + 1))
    }

    /// FR-030: arms the one-time breakdown invite for `taskID` the FIRST time `newCount` crosses
    /// `switchBreakdownThreshold` — `switchBreakdownOffered` (persisted, see its own doc comment)
    /// is checked and updated in the SAME call, so a task that keeps getting switched away from
    /// (4th, 5th, ... time) is never asked twice. `switchAwayCount`/this check never appear in any
    /// UI copy — see `dismissSwitchBreakdownSuggestion`/`acceptSwitchBreakdownSuggestion` and
    /// `SwitchBreakdownSuggestionBanner` (`FocusOverlay.swift`) for the one place the RESULT of
    /// crossing the threshold is shown, which is a plain invite, never the count itself.
    private func maybeOfferBreakdown(taskID: UUID, newCount: Int) {
        guard newCount >= Self.switchBreakdownThreshold, !switchBreakdownOffered.contains(taskID) else { return }
        switchBreakdownOffered.insert(taskID)
        UserDefaults.standard.set(switchBreakdownOffered.map(\.uuidString), forKey: Self.switchBreakdownOfferedKey)
        switchBreakdownSuggestion = tasks.first { $0.id == taskID }
    }

    /// Declining the FR-030 invite: closes it, permanently (`switchBreakdownOffered` was already
    /// updated the moment it was armed, in `maybeOfferBreakdown` above — there is nothing left to
    /// persist here, this is purely dismissing the banner).
    func dismissSwitchBreakdownSuggestion() {
        switchBreakdownSuggestion = nil
    }

    /// Accepting the FR-030 invite: routes straight into the EXISTING breakdown flow
    /// (`openBreakdown(for:)`, unchanged) rather than inventing a second one — this is a shortcut
    /// into "Break down into steps…", the same feature already reachable from the hero card's/
    /// `TaskRow`'s own context menu.
    func acceptSwitchBreakdownSuggestion() {
        guard let task = switchBreakdownSuggestion else { return }
        switchBreakdownSuggestion = nil
        openBreakdown(for: task)
    }

    /// Shared plumbing for `switchFocusTask()`/`canSwitchFocusTask` (the `FocusOverlay` path): the
    /// task currently in the focus slot, the task `nextSwitchTarget` would hand focus to next, and
    /// that replacement's own index in `openTasks` — `nil` whenever there is nothing to switch TO
    /// (focus not active, `openTasks` empty, or every other open task is currently ineligible).
    /// Kept side-effect-free so the view can poll `canSwitchFocusTask` on every render without
    /// accidentally mutating anything.
    private func focusSwitchCandidate() -> (current: TaskItem, replacement: TaskItem, newIndex: Int)? {
        guard focusActive else { return nil }
        let openNow = openTasks
        guard !openNow.isEmpty else { return nil }
        let clampedIndex = min(max(focusIndex, 0), openNow.count - 1)
        let current = openNow[clampedIndex]
        guard
            let replacement = Self.nextSwitchTarget(excluding: current.id, from: openNow, now: clock(), calendar: .current),
            let newIndex = openNow.firstIndex(where: { $0.id == replacement.id })
        else { return nil }
        return (current, replacement, newIndex)
    }

    /// Drives the Switch button's disabled state (mirrors `bottomNav`'s existing prev/next
    /// disabled-at-the-bound convention in `FocusOverlay`) — false when there is genuinely nowhere
    /// else to send focus right now (e.g. exactly one open task left).
    var canSwitchFocusTask: Bool { focusSwitchCandidate() != nil }

    /// Hands the focus slot to a different open task. The task being left gets exactly ONE thing
    /// written to it — `switchAwayCount + 1`, via `recordSwitchAway` (never shown anywhere, purely
    /// an internal FR-030 signal) — and nothing else: no `status` change, no negative flag. It
    /// simply stops being the one shown, and re-enters normal `nextTask()` contention exactly where
    /// it already sat. Next time it wins selection again it comes back with its existing
    /// `sourceTranscript`/`resumeNote`/step progress intact (`FocusOverlay` re-displays those as-is
    /// via `stepProgress(for:)`), because nothing else about the task itself ever changed.
    ///
    /// Recomputes the replacement's index AFTER `recordSwitchAway` (rather than reusing
    /// `focusSwitchCandidate()`'s pre-mutation index) — same "refresh, then recompute" discipline
    /// `completeFocusTask` above already uses, since a store-backed `recordSwitchAway` reloads
    /// `tasks` from the store. A no-op when there is nowhere else to switch to
    /// (`canSwitchFocusTask == false`) — the UI disables the button for that same state, this guard
    /// is just the backstop.
    func switchFocusTask() {
        guard let candidate = focusSwitchCandidate() else { return }
        recordSwitchAway(from: candidate.current)
        if let refreshedIndex = openTasks.firstIndex(where: { $0.id == candidate.replacement.id }) {
            focusIndex = refreshedIndex
        }
        if voiceFeedback {
            voice.speak("Switched. \(candidate.replacement.title)")
        }
    }

    /// Shared plumbing for `switchDashboardActiveTask()`/`canSwitchDashboardActiveTask` (the
    /// `TodayView` hero-card path): today's dashboard-spotlit task (`dashboardActiveTask`) plus the
    /// task `nextSwitchTarget` would hand the spotlight to next — `nil` when there's nothing spotlit
    /// or nothing else eligible.
    private func dashboardSwitchCandidate() -> (current: TaskItem, replacement: TaskItem)? {
        guard let current = dashboardActiveTask else { return nil }
        guard let replacement = Self.nextSwitchTarget(excluding: current.id, from: openTasks, now: clock(), calendar: .current) else {
            return nil
        }
        return (current, replacement)
    }

    /// Drives the hero card's Switch button disabled state — same "false when nothing else is
    /// eligible" contract as `canSwitchFocusTask`, just against `dashboardActiveTask` instead of
    /// `focusIndex`.
    var canSwitchDashboardActiveTask: Bool { dashboardSwitchCandidate() != nil }

    /// Hands the dashboard hero card's spotlight to a different open task — same non-mutation
    /// contract as `switchFocusTask()` above (only `switchAwayCount` changes on the task being
    /// left, via the same shared `recordSwitchAway`). Sets `dashboardSwitchOverrideID` so
    /// `dashboardActiveTask` picks the replacement up immediately; self-heals back to the engine's
    /// own `activeTask` once the replacement itself is done/deleted/switched away from in turn.
    func switchDashboardActiveTask() {
        guard let candidate = dashboardSwitchCandidate() else { return }
        recordSwitchAway(from: candidate.current)
        dashboardSwitchOverrideID = candidate.replacement.id
        if voiceFeedback {
            voice.speak("Switched. \(candidate.replacement.title)")
        }
    }

    // MARK: - Park & resume ("đang làm A, B chen ngang" — anh Khôi 2026-09-06)
    //
    // `switchFocusTask`/`switchDashboardActiveTask` above answer "give me something ELSE"; the
    // engine picks the target. This answers the other half — "I have to do THIS one right now" —
    // and remembers where to come back to. No new mechanism: the target is pinned with the SAME
    // `dashboardSwitchOverrideID` Switch already uses, the task being left is marked with the SAME
    // `recordSwitchAway`, and what it was mid-way through is whatever the user typed into
    // `resumeNote` (`FocusOverlay`'s field, `setResumeNote` below), which `FocusOverlay` already
    // re-displays when the task comes back.

    /// The task set aside by `focusTaskNow`, or `nil`. Deliberately ONE level, not a stack:
    /// parking B while B itself was the interruption overwrites this and the first task falls back
    /// into normal `nextTask()` contention (where it was already sitting anyway — parking changes
    /// nothing about the task's own data).
    /// ponytail: single slot; make it an array only if real users report nested interruptions.
    private(set) var parkedTaskID: UUID?

    /// "Do this one now." Pins `id` as the active/focus task and remembers whatever was spotlit
    /// so `resumeParkedTaskIfNeeded` can hand it back once the interruption is finished. A no-op
    /// for an unknown/closed id, or for the task already spotlit.
    func focusTaskNow(_ id: UUID) {
        guard openTasks.contains(where: { $0.id == id }) else { return }
        if let current = dashboardActiveTask, current.id != id {
            recordSwitchAway(from: current)
            park(current, note: "Paused \(clock().formatted(.dateTime.hour().minute())) — switched to \u{201C}\(titleFor(id) ?? "another task")\u{201D}")
        }
        dashboardSwitchOverrideID = id
        if focusActive, let index = openTasks.firstIndex(where: { $0.id == id }) {
            focusIndex = index
        }
    }

    /// Called from `toggleDone` — the single funnel every completion path routes through (the UI
    /// toggle, `confirmVoiceDone`, `sweepComplete`, the notification action's own refresh), so this
    /// is written once rather than at each of them.
    ///
    /// Only fires when the task just completed is the one that INTERRUPTED (i.e. the pinned one).
    /// Ticking some unrelated row off the list must not yank the spotlight around, which is why
    /// this checks `dashboardSwitchOverrideID` rather than just "something got done".
    private func resumeParkedTaskIfNeeded(justCompleted id: UUID) {
        guard let parked = parkedTaskID,
              dashboardSwitchOverrideID == id,
              tasks.first(where: { $0.id == id })?.done == true
        else { return }
        restoreSpotlight(to: parked)
    }

    /// The OTHER way a parked task becomes workable again: it was set aside because it was WAITING
    /// on something (`addTaskDependency` parks it), and that something just cleared — the blocker
    /// got ticked off, deleted, or the external "cái kia xong rồi" was confirmed. Every one of
    /// those mutations already computes `eligibilityDiff`, which names exactly the tasks that
    /// flipped from blocked to workable, so this is the same one-slot handback keyed off that list
    /// instead of off a completion id. No polling, no new state.
    private func resumeParkedTaskIfUnblocked(_ newlyEligible: [UUID]) {
        guard let parked = parkedTaskID, newlyEligible.contains(parked) else { return }
        restoreSpotlight(to: parked)
    }

    private func titleFor(_ id: UUID) -> String? { tasks.first { $0.id == id }?.title }

    /// Sets a task aside and — ONLY when nothing is written down yet — leaves an automatic
    /// breadcrumb (anh Khôi chốt 2026-09-06). It answers "dừng lúc nào, vì việc gì", not "làm tới
    /// đâu"; that second half is the user's own line, typed over this one in the parked-note row
    /// (`TodayView`) or `FocusOverlay`'s field. A note the user wrote themselves always outranks a
    /// generated one and is never overwritten — this fills a blank, it does not maintain a log.
    private func park(_ task: TaskItem, note: String) {
        parkedTaskID = task.id
        guard (task.resumeNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        setResumeNote(task.id, note)
    }

    /// Shared tail of both resume triggers: clears the slot and hands the spotlight back.
    private func restoreSpotlight(to parked: UUID) {
        parkedTaskID = nil
        // Parked task deleted/completed/archived while away: drop the pin entirely and let the
        // engine pick again, rather than pinning something that no longer exists.
        guard let index = openTasks.firstIndex(where: { $0.id == parked }) else {
            dashboardSwitchOverrideID = nil
            return
        }
        dashboardSwitchOverrideID = parked
        if focusActive { focusIndex = index }
    }

    /// Writes the "where I left off" line. Store-backed via the EXISTING `mergeIntoExisting` (same
    /// convention `recordSwitchAway` uses — no new `TaskStore` method), in-memory otherwise.
    /// Deliberately does NOT run the reminders/eligibility/calendar tail `updateTask` does:
    /// `resumeNote` feeds none of them. It DOES nudge sync, so the note follows the user to their
    /// other machine — which is the whole point of writing it down.
    func setResumeNote(_ id: UUID, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        guard let store else {
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                tasks[index].resumeNote = value
            }
            return
        }
        store.mergeIntoExisting(id) { task in
            var updated = task
            updated.resumeNote = value
            return updated
        }
        tasks = store.fetchAll()
        notifySyncOfLocalEdit()
    }

    // MARK: - Appearance controls (Settings → Appearance)

    /// FIX 4: sets the accent color and persists it, so it survives relaunch — same "mutate +
    /// persist together" shape as `setAmbient` right below. A plain stored-property `didSet` was
    /// considered instead (would avoid touching `SettingsView.swift` at all), but this file has
    /// zero existing `didSet`/`willSet` usage anywhere, `@Observable`'s macro expansion turns a
    /// stored property into a computed one and the exact interaction with property observers
    /// isn't exercised anywhere else in this codebase to lean on — an explicit setter method
    /// mirrors the established, already-proven convention every other persisted Settings control
    /// in this file uses (`setAmbient`/`setSpeechEngine`/`setRecognitionLocale`/
    /// `setVoiceDeliveryMode`/`setGlobalReminderPolicy`), so it's the safer choice here.
    /// `SettingsView.swift`'s tap handler calls this instead of assigning `appState.accent`
    /// directly.
    func setAccent(_ a: VolarAccent) {
        accent = a
        UserDefaults.standard.set(a.rawValue, forKey: Self.accentKey)
    }

    /// FIX 4: sets the row/section density and persists it — same rationale/shape as `setAccent`
    /// above. `Density` has no `.rawValue` (see `densityKey`'s doc comment), so persistence goes
    /// through the two small string-mapping helpers below instead.
    func setDensity(_ d: Density) {
        density = d
        UserDefaults.standard.set(Self.densityPersistedID(d), forKey: Self.densityKey)
    }

    /// `Density -> String`, for persistence — deliberately the exact same three values as
    /// `SettingsView.densityID(_:)` (that method stays private to its view; this is the
    /// AppState-side mirror `setDensity`/`init` need for `UserDefaults`, not a second source of
    /// truth — see `densityKey`'s doc comment).
    private static func densityPersistedID(_ d: Density) -> String {
        switch d {
        case .cozy: return "cozy"
        case .comfy: return "comfy"
        case .roomy: return "roomy"
        }
    }

    /// The inverse of `densityPersistedID(_:)` above. Returns `nil` — rather than defaulting to
    /// `.comfy` — for an unrecognized/corrupted stored value, so `init` can leave the
    /// caller-supplied `density:` argument standing instead of stomping it with a hardcoded
    /// default. That matters because the init parameters are documented as the fallback for
    /// previews/tests, and it keeps this path symmetric with `accent`'s
    /// `VolarAccent(rawValue:)`, which is already `nil`-on-garbage for the same reason. Named
    /// distinctly from the `density` stored property (rather than overloading that name, as
    /// `densityPersistedID(_:)`'s counterpart does with `accent`/`setAccent`) purely so this static
    /// helper reads unambiguously at its one call site in `init` above.
    private static func densityFromPersistedID(_ id: String) -> Density? {
        switch id {
        case "cozy": return .cozy
        case "comfy": return .comfy
        case "roomy": return .roomy
        default: return nil
        }
    }

    /// specs/009-light-mode-list-v2/design.md §7: sets the System/Light/Dark appearance
    /// preference and persists it — same "mutate + persist" shape as `setAccent`/`setDensity`
    /// above. Deliberately does NOT touch `NSApp.appearance` here: that's an AppKit-only side
    /// effect and this file is compiled for iOS too (`#if canImport(AppKit)` at the top of this
    /// file). `VolarApp.swift`'s `AppDelegate` observes this property (same `withObservationTracking`
    /// re-arm pattern as `observeCaptureState()` there) and applies it to `NSApp.appearance` —
    /// both at launch and live, the moment this setter runs.
    func setAppearance(_ pref: AppearancePreference) {
        appearance = pref
        UserDefaults.standard.set(pref.rawValue, forKey: Self.appearanceKey)
    }

    /// specs/010-calendar-and-hard-deadlines/design.md §2.5 — "Read my calendar" toggle in
    /// Settings ▸ Calendar. Same "mutate + persist" shape as `setAppearance` above. Deliberately
    /// does nothing else: turning this off does not clear `calendarConflict` on any
    /// already-built `ConfirmDraft` (that field was computed once at draft-creation time and the
    /// batch is transient — same non-goal `overdueSuggestion`'s own fields already accept), and
    /// there is nothing cached anywhere else to invalidate — `hardAnchors(now:)`/
    /// `calendarConflictDescription(for:)` both re-check this flag fresh on every call, so the
    /// very next read after this returns already reflects the new value.
    func setCalendarReadEnabled(_ enabled: Bool) {
        calendarReadEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.calendarReadKey)
    }

    /// Sets the ambient visual mode and persists it, so it survives relaunch.
    func setAmbient(_ mode: AmbientMode) {
        ambient = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.ambientKey)
    }

    /// Sets (or clears) the custom background image and persists its path. Picking an image
    /// implicitly switches `ambient` to `.custom`, mirroring the prototype's behavior of
    /// previewing whatever image you just chose. Not sandboxed today, so a plain file path is
    /// fine; if sandboxing is ever enabled, this needs a security-scoped bookmark instead.
    func setCustomImage(_ url: URL?) {
        customImageURL = url
        if let url {
            UserDefaults.standard.set(url.path, forKey: Self.customImageKey)
            ambient = .custom
            UserDefaults.standard.set(AmbientMode.custom.rawValue, forKey: Self.ambientKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.customImageKey)
        }
    }

    // MARK: - Ambient sound (Phase 3: wires `Sources/Audio/AmbientSound.swift`)

    /// Mirrors the prototype's ambient-sound toggle button: toggles playback of whatever the
    /// current `ambient` visual mode implies (defaulting to `.rain` if no ambient mode is set,
    /// so the toolbar button always has *something* to toggle).
    func toggleAmbientSound() {
        ambientSound.toggle(ambient == .none ? .rain : ambient)
    }

    // MARK: - Frog of the day

    /// Sets `id` as the single "frog of the day", clearing the flag on every other task —
    /// mirrors `volar-mac.jsx`'s single-frog invariant.
    ///
    /// FIX 6 (data hygiene): used to only mutate the in-memory `tasks` array, never the store — the
    /// very next `tasks = store.fetchAll()` (any other mutation) silently wiped the flag, and it
    /// never survived relaunch at all. Store-backed path now routes through `TaskStore.setFrog(_:)`
    /// (persists, and is itself the single source of truth for the invariant) and refreshes `tasks`
    /// from it, same "mutate via store, refresh tasks" convention every other store-backed mutation
    /// in this file already follows. No-store fallback (previews/tests) keeps the old in-memory-only
    /// loop.
    func setFrog(_ id: UUID) {
        guard let store else {
            for index in tasks.indices {
                tasks[index].frog = (tasks[index].id == id)
            }
            return
        }
        store.setFrog(id)
        tasks = store.fetchAll()
    }

    // MARK: - Modal / banner actions (Phase 3)

    /// Morning-frog sheet: user picked a candidate — set it as today's frog, then dismiss.
    func pickFrog(_ id: UUID) {
        setFrog(id)
        showMorningFrog = false
    }

    /// Morning-frog sheet: "Skip today" (or answering by voice instead) — just dismiss.
    func dismissMorningFrog() {
        showMorningFrog = false
    }

    /// Task-breakdown sheet entry point: EVERY "Break down into steps…" call site (`TaskRow.swift`,
    /// `TodayView.swift` x2, `triageBreakdown` below) routes through here now, instead of the old
    /// bare `showBreakdown = true` that opened the sheet onto 5 hard-coded sample rows
    /// ("Open Framer", "Draft headline + subhead", …) regardless of which task — or whether ANY
    /// task — was actually clicked. Kicks off the real fetch immediately so the sheet opens
    /// straight into `.loading` rather than needing a second explicit trigger from the View.
    func openBreakdown(for task: TaskItem) {
        breakdownTask = task
        showBreakdown = true
        fetchBreakdown(for: task)
    }

    /// title+done snapshot of `task`'s existing children (anh Khôi, 2026-07-29 "richer context"
    /// addendum) — the extra grounding this app can offer `breakdown` calls beyond a bare
    /// title, so a repeat call never regenerates/repeats a step already finished. `nil` when there
    /// are no children yet, matching the wire's own "omit the field entirely" convention for an
    /// absent/empty `existingSubtasks` (see `TaskContextSubtask`'s doc comment,
    /// `Sources/Parsing/IntentParsing.swift`, for the shared type both this and the transport layer
    /// use). Dùng bởi `fetchBreakdown` — one
    /// definition, so the three call sites can never compute "which children count" three
    /// different ways.
    private func existingSubtaskContext(for task: TaskItem) -> [TaskContextSubtask]? {
        let children = tasks.filter { $0.parentId == task.id }
        guard !children.isEmpty else { return nil }
        return children.map { TaskContextSubtask(title: $0.title, done: $0.done) }
    }

    /// `TaskBreakdownView`'s `.onDisappear` calls this on EVERY dismissal path (Cancel, Edit-as-
    /// cancel, Esc, the system sheet-close control) — not just the `onClose()` closure
    /// `VolarApp.swift` wires to the Cancel/Edit buttons, since SwiftUI can tear a sheet down
    /// without that closure ever running. Bumping `breakdownSession` here is what stops a fetch
    /// already in flight for the task just dismissed from landing on — or silently populating —
    /// whichever task's sheet opens next: same stale-token shape as `captureSession`/
    /// `textCaptureSession` elsewhere in this file.
    func closeBreakdown() {
        breakdownSession += 1
        breakdownTask = nil
        breakdownFetchState = .idle
    }

    /// The actual async breakdown fetch, split out of `openBreakdown(for:)` so the session bump +
    /// `.loading` assignment happen SYNCHRONOUSLY before the `_Concurrency.Task` hop — exactly
    /// `runParse`'s own shape (`captureSession`/`captureState = .parsing` set synchronously, THEN
    /// the async router call, further down this file). Routes through the SAME `IntentRouter` the
    /// rest of cloud parsing already uses — `router.breakdownWithContext(...)` (anh Khôi, 2026-07-29
    /// "richer context" addendum; see that method's own doc comment for why it's a separate method
    /// from the frozen `router.breakdown(title:notes:)` protocol witness), alongside the existing
    /// `router.parse`/`router.resolveCompletion` — rather than a second networking path opened
    /// directly from a View.
    ///
    /// `router.breakdownWithContext` itself tries FM (on-device, macOS 26+) -> Cloud -> `[]`.
    ///
    /// (2026-07-28, anh Khôi chốt: `router.breakdown` USED to fall through, unconditionally, to a
    /// hard-coded heuristic floor — `HeuristicNLParser.breakdown`, `Sources/Model/NLParser.swift`:
    /// literally "Gather what's needed for X" / "Start the first small piece" / … / "Wrap up X",
    /// a fixed template, not real per-task content. That call is now removed from
    /// `IntentRouter.breakdown` itself (see the doc comment on `IntentRouter.init` in
    /// `IntentParsing.swift`) — `HeuristicNLParser`'s code is untouched, just no longer wired in.
    /// So `steps` below is now genuinely `[]`, not a disguised template, whenever neither FM nor
    /// Cloud produced a valid breakdown.)
    ///
    /// This method still adds two safeguards on top of `router.breakdown`:
    ///   1. A pre-flight check of the same two cloud preconditions the rest of the app already
    ///      surfaces (`cloudParseConsent == true` — the opt-in flag both the onboarding consent
    ///      toggle and the Settings parse-engine picker write — AND `ConfigParseCredentialProvider
    ///      .isConfigured`, i.e. signed in; mirrors `SettingsView`'s own "Cloud parsing status"
    ///      hint). Not signed in, or never opted in, -> `.unavailable` WITHOUT ever calling the
    ///      router.
    ///   2. Even when both preconditions hold, the live network call can still fail right now
    ///      (offline, quota just exhausted server-side) — `router.breakdown` now returns `[]` in
    ///      that case (no more hard-coded floor to fall through to), which `applyBreakdownFetchResult`
    ///      below maps to `.failed` via its plain "steps is empty" guard. The `heuristicFloor`
    ///      parameter/comparison further down is kept ONLY because `applyBreakdownFetchResult` is
    ///      also called directly by `CloudFirstDefaultsAndBreakdownTests.swift` to exercise that
    ///      exact disguised-floor scenario in isolation — from THIS call site it is now passed `[]`
    ///      and the comparison is dead weight (never true, since `steps` is non-empty by the time
    ///      it's reached). Left in place rather than reworking that test's signature, which is out
    ///      of scope for this change (see backlog.md).
    private func fetchBreakdown(for task: TaskItem) {
        breakdownSession += 1
        let session = breakdownSession
        breakdownFetchState = .loading

        guard cloudParseConsent == true, ConfigParseCredentialProvider.isConfigured else {
            breakdownFetchState = .unavailable
            return
        }

        // anh Khôi, 2026-07-29 "richer context" addendum: `task.sourceTranscript`/`task.deadline`
        // plus a snapshot of any existing children now ride along with the request — computed
        // synchronously here (pure reads off `self.tasks`, no `await` needed) rather than inside
        // the `_Concurrency.Task` below, so a mutation to `tasks` between now and the network
        // response can't change which snapshot this particular fetch reports.
        let context = existingSubtaskContext(for: task)

        _Concurrency.Task { @MainActor [weak self] in
            guard let self else { return }
            let steps = await self.router.breakdownWithContext(
                title: task.title,
                notes: task.notes,
                sourceTranscript: task.sourceTranscript,
                deadline: task.deadline,
                existingSubtasks: context
            )
            // No more `HeuristicNLParser().breakdown(...)` floor to diff against (removed
            // 2026-07-28 — see doc comment above): pass `[]` for `heuristicFloor` so
            // `applyBreakdownFetchResult`'s legacy disguised-floor comparison is a no-op from this
            // call site, while keeping that parameter's signature intact for the existing tests in
            // `CloudFirstDefaultsAndBreakdownTests.swift` that call it directly with real values.
            self.applyBreakdownFetchResult(steps, heuristicFloor: [], session: session)
        }
    }

    /// The synchronous tail of `fetchBreakdown` above, split out SPECIFICALLY so it's directly
    /// unit-testable without awaiting a real `IntentRouter.breakdown` round trip — same precedent
    /// as `applyTextCaptureParseResult(_:session:)` (`TextCaptureTests.swift` already documents
    /// this pattern for the typed-capture flow) and `resolveCloudMatch` elsewhere in this file.
    /// Tests can simulate "the router came back with these steps" (optionally identical to what
    /// the old heuristic floor would have produced, to exercise the `.failed` branch below) and/or
    /// "the session went stale before the fetch returned" by calling this directly with hand-built
    /// `[String]` arrays and/or a stale `session` token, instead of needing a real network round
    /// trip or a real `HeuristicNLParser` call.
    ///
    /// (2026-07-28: `IntentRouter.breakdown` no longer has a heuristic floor to disguise itself as
    /// — see `fetchBreakdown` above — so from the real call site `heuristicFloor` always arrives
    /// as `[]` and the `steps == heuristicFloor` check below is unreachable dead weight in
    /// production. It stays because `CloudFirstDefaultsAndBreakdownTests.swift` still calls this
    /// method directly with non-empty `heuristicFloor` values to test that exact comparison in
    /// isolation, and reworking that test's signature is out of scope for this change.)
    ///
    /// Not `private` for exactly that reason.
    func applyBreakdownFetchResult(_ steps: [String], heuristicFloor: [String], session: Int) {
        // Stale? The sheet was dismissed (`closeBreakdown()`) or reopened on a different task
        // while this request was in flight — mirrors `runParse`'s own `captureSession` guard.
        guard breakdownSession == session else { return }
        guard !steps.isEmpty else {
            // No steps at all -> `.failed` ("Couldn't reach the breakdown service", TaskBreakdownView).
            // This is now the ONLY path that matters from the real `fetchBreakdown` call site: FM
            // and Cloud both failed/unavailable, and there is no heuristic floor left to fall back
            // to (2026-07-28) — never invent step titles, tell the user honestly instead.
            breakdownFetchState = .failed
            return
        }
        // Legacy check, kept for the direct-call tests only (see doc comment above) — same content
        // as the hard-coded heuristic floor would mean "this WAS that floor in disguise," but the
        // real call site can no longer produce that situation since the floor itself is gone.
        if steps == heuristicFloor {
            breakdownFetchState = .failed
            return
        }
        breakdownFetchState = .loaded(
            steps.enumerated().map { BreakdownStep(id: $0.offset, title: $0.element) }
        )
    }

    /// Task-breakdown sheet: "Save all as tasks" — persists each REAL step title `fetchBreakdown`
    /// produced as its own `TaskItem` (medium priority, `.later`, no deadline/duration — the
    /// breakdown generator doesn't produce those yet), then dismisses and resets the breakdown
    /// state so the next `openBreakdown(for:)` starts clean.
    func saveBreakdown(_ titles: [String]) {
        for t in titles {
            addTask(TaskItem(
                id: UUID(),
                title: t,
                priority: .medium,
                status: .todo,
                deadline: nil,
                conditions: [],
                createdAt: clock(),
                when: .later,
                durationMinutes: nil,
                frog: false
            ))
        }
        showBreakdown = false
        breakdownTask = nil
        breakdownSession += 1
        breakdownFetchState = .idle
    }

    /// Menu-bar "Preview reminder": surfaces the in-app notification banner for the current
    /// `activeTask` (falling back to the artboard's sample copy when nothing is active).
    func showReminderPreview() {
        if let t = activeTask {
            reminderBanner = ReminderBanner(
                title: t.title,
                timing: t.timeBadge.map { "Coming up · \($0)" } ?? "Coming up"
            )
        } else {
            reminderBanner = ReminderBanner(
                title: "Customer call — Acme onboarding",
                timing: "In 15 minutes · 2:00 PM"
            )
        }
    }

    func dismissBanner() {
        reminderBanner = nil
    }

    // MARK: - Phase 4: eligibility auto-unblock + afterDate resurface (T031/T032, FR-015/FR-017)

    /// One monotonic guard for the local resurface-refresh continuation in `scheduleNextResurface`
    /// below — mirrors `captureSession`'s pattern: every mutation recomputes the next resurface
    /// date, so a still-pending sleep from an earlier (now-superseded) computation must not fire.
    private var resurfaceSession = 0

    /// Shared tail for every real task mutation (T031): diffs eligibility across the snapshot
    /// just before/after the mutation and notifies the scheduler once per newly-unblocked task
    /// (FR-015), then recomputes the next `.afterDate` resurface (FR-017/T032). Centralizing this
    /// here — rather than repeating the diff+notify+reschedule sequence at every call site — keeps
    /// every mutation path honest as more get added. `deleteTask` is the one exception: it reuses
    /// `TaskStore.delete`'s own already-computed diff instead of calling this (self-review
    /// "performance": exactly one `eligibilityDiff` per mutation, never two).
    ///
    /// NOTE (self-review "conflict"): the task brief describes this as
    /// `VolarCore.eligibilityDiff(before:after:now:calendar:)`; the actual landed signature in
    /// `VolarCore/Sources/VolarCore/Snapshots.swift` is `eligibilityDiff(before:after:now:)` — no
    /// `calendar` parameter. This wiring follows the real, already-compiled signature.
    ///
    /// Returns the newly-eligible ids so a caller that also cares about them (park & resume's
    /// `resumeParkedTaskIfUnblocked`) reads the diff this already computed instead of running a
    /// second one — same "exactly one `eligibilityDiff` per mutation" rule `deleteTask` follows.
    @discardableResult
    private func notifyEligibilityAndScheduleResurface(before: [TaskItem], now: Date) -> [UUID] {
        let beforeSnapshot = before.map { $0.snapshot() }
        let afterSnapshot = tasks.map { $0.snapshot() }
        let newlyEligible = VolarCore.eligibilityDiff(before: beforeSnapshot, after: afterSnapshot, now: now)
        if !newlyEligible.isEmpty {
            scheduler?.notifyUnblocked(taskIds: newlyEligible)
        }
        scheduleNextResurface(from: afterSnapshot, now: now)
        return newlyEligible
    }

    /// T032/FR-017: finds the earliest strictly-future `.afterDate` across the CURRENT snapshot
    /// (pure `VolarCore.nextResurfaceDate`), tells the durable scheduler about it (contract A), and
    /// ALSO arms a local one-shot continuation so the menu bar (`activeTask`, derived from `tasks`)
    /// updates the instant it passes even while the app stays running and nothing else happens to
    /// touch `tasks` in the meantime. This is NOT polling — a single scheduled continuation per
    /// mutation, invalidated by `resurfaceSession` the moment a later mutation supersedes it, not
    /// a repeating timer/re-check loop.
    private func scheduleNextResurface(from snapshot: [VolarCore.Task], now: Date) {
        resurfaceSession += 1
        let session = resurfaceSession
        // FIX 2: `VolarCore.nextResurfaceDate` returns only the SINGLE earliest `.afterDate`
        // across the whole snapshot, so registering just that one task with the durable scheduler
        // left every OTHER task's `.afterDate` completely unregistered. There's no safety net for
        // those either: `ReminderScheduler.rebuildFromStorage()` only rescans tasks with
        // `deadline != nil`, never `.afterDate` conditions, and a local in-memory wake (the sleep
        // below) doesn't survive an app quit. A task whose `.afterDate` isn't the single nearest
        // one across the whole store would then simply never resurface. Scan the snapshot
        // ourselves instead and register EVERY task's own earliest future `.afterDate`
        // individually — safe to call on every mutation because `ReminderScheduler.scheduleResurface`
        // (ReminderScheduler.swift:200-217) already dedupes per task (same `fireAt` -> no-op,
        // different `fireAt` -> updates the existing row in place), so this never piles up
        // duplicate durable records or duplicate system notifications.
        var earliestOverall: Date?
        for task in snapshot {
            var earliestForTask: Date?
            for condition in task.conditions {
                guard case .afterDate(let date) = condition, date > now else { continue }
                if earliestForTask == nil || date < earliestForTask! { earliestForTask = date }
            }
            guard let taskDate = earliestForTask else { continue }
            scheduler?.scheduleResurface(at: taskDate, taskId: task.id)
            if earliestOverall == nil || taskDate < earliestOverall! { earliestOverall = taskDate }
        }
        guard let date = earliestOverall else { return }

        // Defensive cap (self-review "client-exploit"): a corrupted/hostile store could carry an
        // absurd far-future `.afterDate`; clamp the LOCAL convenience wake so `UInt64(seconds *
        // 1e9)` can never come close to overflowing. The durable scheduler above already has the
        // real, un-clamped date — this only bounds the optional live-refresh nicety.
        let delaySeconds = min(max(date.timeIntervalSince(now), 0), 60 * 60 * 24 * 365 * 5)
        _Concurrency.Task { @MainActor [weak self] in
            try? await _Concurrency.Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard let self, self.resurfaceSession == session else { return }
            if let store = self.store {
                self.tasks = store.fetchAll()
            } else {
                // No store to refresh from (previews/tests) — still nudge Observation so any
                // observer recomputing `activeTask` at this instant actually re-renders.
                self.tasks = self.tasks
            }
            // FIX 2 (chain): the refresh above only advances `tasks` past the resurface moment
            // that just fired — on its own it does NOT re-arm whichever `.afterDate` comes next.
            // Re-running this same method against a fresh snapshot/`now` is what chains forward.
            // This cannot loop forever: the moment that just fired is now <= `now` (this closure
            // only runs once the sleep above has elapsed), and the scan above requires strictly
            // `date > now` to even be a candidate, so that same moment can never be picked again —
            // each recursive call either lands on a strictly later date (and stops after that
            // one sleep) or finds none left at all (and returns immediately, ending the chain).
            self.scheduleNextResurface(from: self.tasks.map { $0.snapshot() }, now: self.clock())
        }
    }

    // MARK: - Phase 4: capture-time conflict advisory (T074, FR-011c)

    /// Builds the throwaway `VolarCore.Task` `conflicts(forAdding:...)` needs, from exactly the
    /// same resolved/dismissed/accepted state `materialize`/`resolvedConditions` would use, so the
    /// advisory reflects what would ACTUALLY be saved — not the raw unconfirmed parse. Never
    /// persisted; reuses `draft.id` (a `Swift.UUID`, collision-safe) as the candidate's id purely
    /// as a stable placeholder. `busyIntervals: []` until the P3 calendar integration lands
    /// (contract C); `frogId` comes from today's frog if one is set, else `nil`.
    private func computeConflicts(for draft: ConfirmDraft, now: Date) -> [VolarCore.TaskConflict] {
        // T-overdue: `effectiveDeadline` rather than `task.deadline` directly, for the same
        // "everywhere the deadline is read" reasoning as `materialize`/`mergeTransform` — a no-op
        // change in practice today (this only ever runs from `buildConfirmDrafts`, before any edit
        // exists, so `effectiveDeadline == task.deadline` at every actual call site right now), but
        // keeps the invariant true regardless of call order, rather than depending on it.
        let deadline = resolvedValue(draft.effectiveDeadline, kind: .deadline, draft: draft)
        // T-edit-attrs: `draft.effective*` rather than `draft.task.*` directly, same "everywhere
        // this attribute is read" reasoning as the `effectiveDeadline` line right above (and
        // `materialize`/`mergeTransform`'s own copies of this same note) — a no-op in practice
        // today (this only ever runs from `buildConfirmDrafts`, before any edit exists), but keeps
        // the invariant true regardless of call order rather than depending on it.
        let estimate = resolvedValue(draft.effectiveEstimateMinutes, kind: .estimate, draft: draft)
        let priorityInt = resolvedValue(draft.effectivePriority, kind: .priority, draft: draft)
        let candidate = VolarCore.Task(
            id: draft.id,
            title: draft.task.title,
            status: .todo,
            priority: priorityInt,
            deadline: deadline,
            conditions: resolvedConditions(draft),
            estimateMinutes: estimate,
            parentId: nil,
            createdAt: now
        )
        return VolarCore.conflicts(
            forAdding: candidate,
            into: tasks.map { $0.snapshot() },
            now: now,
            calendar: .current,
            busyIntervals: [],
            frogId: frogTask?.id
        )
    }

    // MARK: - Phase 4: weekly stale-task triage (T034, FR-018)

    private static let staleThreshold: TimeInterval = 7 * 24 * 60 * 60
    private static let triageDeferInterval: TimeInterval = 3 * 24 * 60 * 60

    /// Open tasks eligible for the weekly triage batch (`TriageView`, sibling-owned §D): untouched
    /// for at least `staleThreshold`.
    ///
    /// NOTE (self-review "conflict"/seam, flagged in this task's final report): there is no
    /// `lastTouchedAt`/staleness field on `TaskItem`/`VolarTask` today — `TaskItem.swift` isn't one
    /// of this task's 5 owned files, so adding one is out of scope here. `createdAt` is used as
    /// the best available proxy for "untouched," and `triageKeep(_:)` below tracks an explicit
    /// "kept" instant in `triageKeptAt` (this file only) so a kept task doesn't immediately
    /// re-qualify. A real per-task `lastTouchedAt` (bumped on any edit) would be materially more
    /// accurate and is a good follow-up.
    var staleTasks: [TaskItem] {
        let cutoff = clock().addingTimeInterval(-Self.staleThreshold)
        return openTasks.filter { (triageKeptAt[$0.id] ?? $0.createdAt) <= cutoff }
    }

    /// FIX A (compile break): processing the last item of a sweep/triage batch used to leave an
    /// open blank sheet with no dismiss control — `showSweep`/`showTriage` only ever got set to
    /// `false` by their own explicit dismiss actions (`dismissSweep()`, or nothing at all for
    /// triage), never by the batch simply running out of items. Called at the tail of every
    /// mutating triage/sweep action (`triageKeep`/`triageBreakdown`/`triageDefer`/`triageDrop`/
    /// `sweepComplete`) so the sheet closes itself the instant its backing list empties out — a
    /// pure UI convenience, no store/model side effects.
    private func dismissBatchSheetsIfEmpty() {
        if showSweep, sweepItems.isEmpty { showSweep = false }
        if showTriage, staleTasks.isEmpty { showTriage = false }
    }

    /// Triage "Keep": no destructive/creative side effect on the task itself — just resets this
    /// task's staleness clock so it doesn't reappear in next week's batch.
    func triageKeep(_ item: TaskItem) {
        triageKeptAt[item.id] = clock()
        persistTriageKeptAt()
        dismissBatchSheetsIfEmpty()
    }

    /// Triage "Break down": opens the real per-task breakdown sheet for `item` via
    /// `openBreakdown(for:)` (Change 3 fix — this call site used to just set `showBreakdown =
    /// true` with no per-task target, same bug the context-menu entry points had; see
    /// `openBreakdown(for:)`'s doc comment for the full fix).
    func triageBreakdown(_ item: TaskItem) {
        openBreakdown(for: item)
        dismissBatchSheetsIfEmpty()
    }

    /// Triage "Defer": adds a `.afterDate` condition `triageDeferInterval` out, matching FR-017's
    /// resurface mechanism exactly — a deferred task automatically resurfaces (no polling) once
    /// that date passes, same as any other `.afterDate` task.
    func triageDefer(_ item: TaskItem) {
        let now = clock()
        guard let store else {
            if let index = tasks.firstIndex(where: { $0.id == item.id }) {
                tasks[index].conditions.append(.afterDate(now.addingTimeInterval(Self.triageDeferInterval)))
            }
            dismissBatchSheetsIfEmpty()
            return
        }
        let before = tasks
        try? store.addCondition(.afterDate(now.addingTimeInterval(Self.triageDeferInterval)), to: item.id)
        tasks = store.fetchAll()
        // WG-1: re-derive this task's reminders (deadline/condition state just changed).
        scheduler?.scheduleReminders(taskId: item.id)
        notifyEligibilityAndScheduleResurface(before: before, now: now)
        dismissBatchSheetsIfEmpty()
    }

    /// Triage "Drop": a plain delete — same path (and same FR-015 re-eligibility notification) as
    /// any other task deletion.
    func triageDrop(_ item: TaskItem) {
        deleteTask(item.id)
        dismissBatchSheetsIfEmpty()
    }

    private func persistTriageKeptAt() {
        let raw = Dictionary(uniqueKeysWithValues: triageKeptAt.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) })
        UserDefaults.standard.set(raw, forKey: Self.triageKeptAtKey)
    }

    // MARK: - Phase 5 (T038): evening sweep (contract B `SweepView`, sibling-owned, landed)

    /// Drives `SweepView`'s presentation — mirrors `VolarApp.swift`'s `showTriage` pattern
    /// (day-gated flag owned here, actual `.sheet` mount point lives in `VolarApp.swift`). WG-A/B
    /// ship-blocker fix: now actually mounted + triggered there (see `VolarApp.swift`'s main-window
    /// `.sheet`/`.task`) — was previously wired here but never surfaced.
    var showSweep = false

    private static let sweepLastShownDayKey = "volar.sweepLastShownDay"

    /// `SweepView.items`: "today's open/in-progress tasks" (contract B) — MINORS fix: was
    /// `nowTasks` only, which silently dropped every `.later`-bucket open task from the evening
    /// sweep. `openTasks` (`nowTasks + laterTasks`) is this app's full still-open set, matching the
    /// contract's "today's open/in-progress tasks" wording without inventing a narrower notion of
    /// "today" than the rest of the app already uses.
    var sweepItems: [TaskItem] { openTasks }

    /// T038: once-daily schedule (ISO-day gate, mirroring `VolarApp.swift`'s `frogLastShown`/
    /// `triageLastShownWeek` `@AppStorage` pattern — kept here as plain `UserDefaults` instead
    /// since `AppState` isn't a `View` and every other persisted setting in this file already uses
    /// `UserDefaults` directly, e.g. `triageKeptAt`/`voiceDeliveryMode`), skip-if-empty
    /// (`sweepItems.isEmpty` — `SweepView` itself also self-guards on an empty `items` as a second
    /// line of defense per its own doc comment).
    ///
    /// WG-A/B ship-blocker fix: `VolarApp.swift`'s main-window `.task` now calls this (gated to
    /// evening hours ≥18:00 at that call site — this method itself only self-gates on ISO-day +
    /// non-empty `sweepItems`) and mounts a `.sheet` presenting `SweepView` bound to `showSweep`,
    /// mirroring `showTriage`'s exact shape:
    /// ```swift
    /// appState.maybeShowEveningSweep()
    /// ```
    /// ```swift
    /// .sheet(isPresented: Binding(
    ///     get: { appState.showSweep },
    ///     set: { presented in if !presented { appState.dismissSweep() } }
    /// )) {
    ///     SweepView(
    ///         items: appState.sweepItems,
    ///         onComplete: { appState.sweepComplete($0) },
    ///         onSkip: { appState.sweepSkip($0) },
    ///         onDismiss: { appState.dismissSweep() }
    ///     )
    ///     .environment(appState)
    ///     .frame(minWidth: 560, minHeight: 480)
    /// }
    /// ```
    func maybeShowEveningSweep() {
        let day = Self.isoDayKey(from: clock())
        guard UserDefaults.standard.string(forKey: Self.sweepLastShownDayKey) != day, !sweepItems.isEmpty else { return }
        showSweep = true
        UserDefaults.standard.set(day, forKey: Self.sweepLastShownDayKey)
    }

    /// POSIX/Gregorian day key, identical formula to `VolarApp.swift`'s own `day` computation (so
    /// the two stay in lockstep) — duplicated locally rather than shared across files since this
    /// task can't touch `VolarApp.swift` to extract a common helper.
    private static func isoDayKey(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// `SweepView.onComplete`: one-tap complete, routed through the SAME funnel as every other
    /// completion (T037) — `toggleDone` (store.toggle + `CompletionEvent` + refresh + auto-advance,
    /// so `MenuBarLabel` advances immediately even while the sweep card stays open for the rest of
    /// the batch).
    func sweepComplete(_ item: TaskItem) {
        toggleDone(item.id)
        dismissBatchSheetsIfEmpty()
    }

    /// `SweepView.onSkip`: no-op — "Skip" means "didn't get to it today," carried over silently
    /// (FR-036/constitution V: never destructive, never a silent completion, no shame styling).
    /// Named explicitly (rather than leaving `VolarApp.swift`'s future sheet wiring pass an inline
    /// `{ _ in }`) so this seam is documented and independently testable.
    func sweepSkip(_ item: TaskItem) {
        // Intentionally empty — see doc comment above.
    }

    /// `SweepView.onDismiss`: closes the sweep card ("Done for today").
    func dismissSweep() {
        showSweep = false
    }

    /// Voice answering during the sweep (contract C: "nice-to-have; the one-tap path is the
    /// requirement"). Deliberately NOT a separate sweep-specific mic/parallel `VoiceDone` path:
    /// the ⌃⌥M hotkey / popover mic keep working exactly as they always do while `showSweep` is
    /// true, so "xong cái A" during a sweep flows through the SAME T036
    /// `finishRecording` -> `presentVoiceDoneConfirm` -> `confirmVoiceDone` -> `toggleDone` pipeline
    /// as any other voice-done completion — which already refreshes `tasks` atomically, so
    /// `sweepItems` (read live by whatever mounts `SweepView`) drops the just-completed item on its
    /// own. No extra wiring needed here beyond what T036 already provides.

    // MARK: - Phase 4: settings (T033 VoiceDeliveryMode + global ReminderPolicy)

    /// Persists the delivery-mode choice at the exact key `voiceDeliveryModeKey` documents
    /// `ReminderScheduler`/`VoiceReminderChannel` are expected to read.
    func setVoiceDeliveryMode(_ mode: VoiceDeliveryMode) {
        voiceDeliveryMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.voiceDeliveryModeKey)
    }

    /// Persists the global default `ReminderPolicy` at `globalReminderPolicyKey`.
    func setGlobalReminderPolicy(_ policy: ReminderPolicy) {
        globalReminderPolicy = policy
        if let data = try? JSONEncoder().encode(policy) {
            UserDefaults.standard.set(data, forKey: Self.globalReminderPolicyKey)
        }
    }

    /// Persists the default task duration at `defaultTaskDurationMinutesKey` (2026-07-29). Out of
    /// range (including the `0` `UserDefaults.integer(forKey:)` would report for an unset key —
    /// see this same guard in `init` above) falls back to 30 rather than persisting/using a bogus
    /// value; never clamped to the nearest bound, since a caller passing e.g. `2` or `9000` almost
    /// certainly has a bug, and silently clamping would hide it behind a plausible-looking number.
    func setDefaultTaskDurationMinutes(_ minutes: Int) {
        defaultTaskDurationMinutes = (5...480).contains(minutes) ? minutes : 30
        UserDefaults.standard.set(defaultTaskDurationMinutes, forKey: Self.defaultTaskDurationMinutesKey)
    }

    // MARK: - Service activation (Phase 3: call once from the main window's `.task`)

    /// Starts the global ⌃⌥M toggle-capture hotkey. `HotkeyManager.start` already calls
    /// `appState.handleHotkey()` directly on key-down (see `Sources/Speech/HotkeyManager.swift`);
    /// toggle mode has no use for key-up, so neither `onKeyDown` nor `onKeyUp` needs wiring here.
    /// `HotkeyManager` registers the hotkey via Carbon's `RegisterEventHotKey` — a sandbox-legal
    /// Carbon Event Manager API that needs no Accessibility permission and has no local-monitor
    /// fallback path (unlike the pre-Carbon `NSEvent` monitor it replaced).
    func activateServices() {
        #if os(macOS)
        hotkey.start(appState: self)
        #endif
        // T033 (constitution IV): rebuild the reminder heap from durable storage on every
        // launch — no reminder may exist only in memory. Sleep/wake recovery is handled by
        // `VolarApp.swift`'s `.onReceive(NSWorkspace.shared.notificationCenter.publisher(for:
        // .didWakeNotification))`, which calls `scheduler?.rebuildFromStorage()` directly on wake
        // (m-2: `ReminderScheduler.init` used to register its OWN wake observer, but on the wrong
        // notification center — `NotificationCenter.default` instead of
        // `NSWorkspace.shared.notificationCenter`, where `didWakeNotification` actually posts —
        // so it never fired; that dead observer has been deleted from `ReminderScheduler.swift`,
        // leaving `VolarApp.swift`'s correct path as the only wake trigger).
        scheduler?.rebuildFromStorage()
        // CB-1: `ReminderScheduler` self-assigns as `UNUserNotificationCenter.current().delegate`
        // inside its own `init` (`ReminderScheduler.swift`) — there is no separate
        // `ReminderNotificationDelegate` type for this file to construct/assign (that symbol was
        // referenced here but never defined anywhere in the codebase; removed rather than
        // resurrected, per this fix's instruction). Reassigning it a second time here would only
        // double-assign the same delegate, so this call is deleted, not replaced.
        offerRescheduleForOverdueTasks(now: clock())
        // FIX 2 (re-arm on launch): `scheduleNextResurface`'s local one-shot wake (the sleep
        // continuation inside it) lives only in memory, so it doesn't survive a quit/relaunch —
        // without this call, a task with a future `.afterDate` would sit unregistered (durably
        // AND locally) until some other mutation happened to touch `tasks` first. Idempotent if
        // `activateServices()` is ever called twice: each call bumps `resurfaceSession`, which
        // invalidates any still-pending sleep from the previous call, and every
        // `scheduler?.scheduleResurface` it issues is itself deduped per task (see that method's
        // own doc comment) — so a repeat call just re-arms the same state, never a duplicate.
        scheduleNextResurface(from: tasks.map { $0.snapshot() }, now: clock())
        // T043 (phase6-contract.md §C): starts the minute-scale ambient recheck timer.
        // FIX 3: a persisted `.whisperKit` engine choice used to only ever call `whisper.prepare()`
        // from `setSpeechEngine` (Settings) — so on relaunch, `speechEngineChoice` restores from
        // `UserDefaults` correctly but the model itself was never (re)loaded, silently falling back
        // to Apple on-device for the whole session (see `selectedEngine`'s `isModelReady` gate).
        // `WhisperKitEngine.prepare()` is documented idempotent (self-guards on `.preparing`/`.ready`
        // — see its own doc comment), so no extra guard is needed here.
        if speechEngineChoice == .whisperKit, WhisperKitEngine.isSupported {
            _Concurrency.Task { await whisper.prepare() }
        }
        // FIX 6 (launch/window-reopen path): nothing else runs `reconcile(tasks:)` at launch
        // otherwise — a Mac that slept through a task's deadline changing (e.g. a reminder
        // reschedule while the app wasn't running) would show a stale "Volar" calendar until the
        // next in-app mutation. Idempotent for the same reason every other call site here is: a
        // no-op reconcile costs one filter pass when nothing actually changed.
        syncCalendarMirror()
    }

    // MARK: - Phase 4: overdue-reschedule scan (WG-3, FR-016)

    /// FR-016: on launch, offer a reschedule nudge once per overdue open task — deduped against
    /// any already-outstanding resurface/reschedule record for that task so a re-run of this scan
    /// doesn't pile up a second offer on top of one the user hasn't acted on yet (`offsetKind ==
    /// "resurface"` covers both `scheduleResurface`'s FR-017 afterDate path and
    /// `offerReschedule`'s own records — either way, an outstanding one already covers this task).
    ///
    /// // UNVERIFIED / known gap: this is only reachable from `activateServices()` (launch).
    /// `VolarApp.swift`'s wake handler calls `scheduler?.rebuildFromStorage()` directly rather than
    /// routing back through `AppState` (see that file's own comment on the wake path), and
    /// `VolarApp.swift` is outside this fix's 5 owned files — so a wake-triggered rescan for
    /// newly-overdue tasks isn't wired. Flagged for whoever next touches `VolarApp.swift`'s wake
    /// observer, not written to `backlog.md` per this task's own "do not edit backlog" constraint.
    private func offerRescheduleForOverdueTasks(now: Date) {
        guard let scheduler else { return }
        for task in openTasks {
            guard let deadline = task.deadline, deadline < now else { continue }
            let alreadyOutstanding = scheduler.recordsForTask(task.id).contains {
                $0.offsetKind == "resurface" && $0.state != "satisfied"
            }
            guard !alreadyOutstanding else { continue }
            scheduler.offerReschedule(taskId: task.id)
        }
    }

    /// `VolarApp.swift`'s `.onOpenURL` gọi ngay sau `appLinkHandler?.handle(url)`. Trước đây nó
    /// còn gương `pendingDisambiguation`, đóng dấu `lastAppLinkAt` và làm mới hàng đợi delegation —
    /// cả ba đã bỏ cùng tính năng delegation (2026-08-22). Còn lại đúng một việc, và nó vẫn cần:
    /// `handle(_:)` có thể vừa đổi STORE, mà `tasks` ở file này là một bản chụp riêng.
    func onAppLinkHandled() {
        refreshFromStore()
    }

    // MARK: - Guided tour actions (`TourOverlay.swift`)

    /// The stop currently on screen, or `nil` if `tourStepIndex` ever drifted out of
    /// `TourStop.all`'s bounds. Defensive rather than load-bearing: every mutator below
    /// (`startTourIfNeeded`/`replayTour`/`tourNext`/`tourBack`/`endTour`) keeps `tourStepIndex` in
    /// range by construction, so this should never actually read `nil` while `tourActive` is
    /// `true` — but `TourOverlay` reads THIS instead of subscripting `TourStop.all` directly, so a
    /// future bug here degrades to "the overlay quietly renders nothing" instead of a crash.
    var tourStop: TourStop? {
        TourStop.all.indices.contains(tourStepIndex) ? TourStop.all[tourStepIndex] : nil
    }

    /// Called once, right after onboarding completes (`VolarApp.swift`'s `OnboardingView
    /// onComplete:` and its sheet-dismissal binding) — a no-op if the tour has already run this
    /// install (or a previous one; `hasSeenTour` is persisted), so a relaunch never re-triggers it
    /// uninvited. `replayTour()` below is the explicit, always-runs Settings re-entry point.
    func startTourIfNeeded() {
        guard !hasSeenTour else { return }
        tourStepIndex = 0
        tourActive = true
    }

    /// Settings' "Replay guided tour" row (agent-B-owned call site, `SettingsView.swift`) — always
    /// restarts from the first stop, unconditionally, even though `hasSeenTour` is necessarily
    /// already `true` by the time a user can reach this row at all.
    func replayTour() {
        tourStepIndex = 0
        tourActive = true
    }

    /// "Next →" on every non-final stop. Advances one stop, or — if already on the last stop —
    /// ends the tour exactly like Skip/Esc would. In practice `TourOverlay` never shows a "Next →"
    /// button on the final stop (its footer swaps in the calendar-connect actions instead, each of
    /// which calls `endTour()` directly), so the "past the last stop" branch here is a defensive
    /// fallback, not a normally-reached path.
    func tourNext() {
        let next = tourStepIndex + 1
        if TourStop.all.indices.contains(next) {
            tourStepIndex = next
        } else {
            endTour()
        }
    }

    /// "Back". Clamped at 0 — mirrors `FocusOverlay`'s own `goToPrevious()` clamp (`AppState`
    /// itself has no analogous clamp today since `focusIndex` is clamped view-side; this one lives
    /// here instead so `Tests/TourFlowTests.swift` can exercise it without a view).
    func tourBack() {
        tourStepIndex = max(0, tourStepIndex - 1)
    }

    /// Skip / Esc / the final stop's "Maybe later"/"Finish" — ends the tour and marks it seen for
    /// good, so `startTourIfNeeded()` never auto-starts it again this install. `replayTour()` is
    /// the only way back in once this has run.
    func endTour() {
        tourActive = false
        tourStepIndex = 0
        hasSeenTour = true
        UserDefaults.standard.set(true, forKey: Self.hasSeenTourKey)
    }
}

// MARK: - DefaultCloudParseGate (T024 seam: wires the one-time consent decision into `IntentRouter`)

/// `IntentRouter`'s injected `CloudParseGate` (`Sources/Parsing/IntentParsing.swift`, T019,
/// landed) — the REAL mechanism the Cloud tier is gated by, not a bare shared UserDefaults
/// convention. Deliberately a standalone type (not `AppState` itself conforming) so it can be
/// constructed as a default parameter expression in `AppState.init` before `self` exists.
///
/// `isOptedIn()` reads the exact key `AppState.resolveCloudConsent(allow:)` writes
/// (`AppState.cloudParseConsentKey`, `fileprivate` to this file) — `false` (never opted in, or
/// declined) is the safe default for an unset key, matching "decline ⇒ never cloud."
///
/// `isOnline()` is a best-effort `NWPathMonitor` snapshot. The protocol's own doc comment
/// sanctions "`true` when unknown/unable to determine" as a valid answer (it's "purely an
/// optimization ... not a security gate") — this defaults `pathSatisfied` to `true` until the
/// monitor's first callback lands, rather than blocking `isOnline()` on that first update.
/// `@unchecked Sendable`: the only mutable state (`pathSatisfied`) is lock-protected; `NWPathMonitor`
/// itself delivers `pathUpdateHandler` on an arbitrary background queue, which is exactly why the
/// lock exists instead of, say, `@MainActor`-isolating this type.
final class DefaultCloudParseGate: CloudParseGate, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var pathSatisfied = true

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // Same scoped form as `isOnline()` below — this closure is synchronous so the manual
            // pair would compile here, but keeping one locking idiom means a future edit can't
            // accidentally leave an early return between `lock()` and `unlock()`.
            self.lock.withLock { self.pathSatisfied = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "volar.cloudParseGate.reachability"))
    }

    deinit {
        monitor.cancel()
    }

    /// anh Khôi chốt 2026-09-06: an UNSET key now means "yes" — cloud parsing is the default for
    /// every entry point and nothing pauses to ask any more (`AppState.proceedToCapture`). Only an
    /// explicit `false` (Settings ▸ parse engine, or the onboarding toggle switched off, both
    /// through `AppState.setParseEngine`) keeps text on-device, and it still gates every request
    /// exactly as before. `object(forKey:) as? Bool`, not `bool(forKey:)`: the latter cannot tell
    /// "never answered" from "answered no", which is the whole distinction this default rests on.
    func isOptedIn() async -> Bool {
        UserDefaults.standard.object(forKey: AppState.cloudParseConsentKey) as? Bool ?? true
    }

    /// Scoped `withLock` rather than a manual `lock()`/`defer { unlock() }` pair: `NSLock`'s
    /// `lock()`/`unlock()` are `@available(*, noasync)`, so calling them directly in an `async`
    /// method is a compile error — a suspension between the two could resume on a different
    /// thread and unlock from the wrong one. `withLock`'s body is synchronous and cannot suspend,
    /// which is exactly why it stays available here.
    func isOnline() async -> Bool {
        lock.withLock { pathSatisfied }
    }
}
