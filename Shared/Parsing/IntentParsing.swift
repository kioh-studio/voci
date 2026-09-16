// Sources/Parsing/IntentParsing.swift — IntentParser protocol, IntentRouter (Cloud -> FM ->
// title-only floor; see the 2026-07-28 comment on `IntentRouter.init`/`parse` for why the old
// Heuristic bottom tier is disconnected, not deleted), and the shared raw-output decode/
// validation helper both FoundationModelParser (T020) and CloudParser (T021) funnel through
// before ever producing a `ParsedTask`.
//
// Frozen seam: `specs/002-workflow-command-center/contracts/parsing-contract.md`. `ParsedTask`,
// `ParsedValue<T>`, `ParsedCondition`, `Recurrence`, `ReminderPolicy`, `TaskKind` are owned
// elsewhere (NLParser agent / Phase-2) and referenced HERE BY NAME ONLY — nothing in this file
// redefines them. This file will not compile standalone until `Volar/Sources/Model/NLParser.swift`
// lands the v2 `ParsedTask` shape and an `IntentParser`-conforming `HeuristicNLParser` — that is
// expected for this round (see task brief). Windows: cannot build here — every FM-specific claim
// is separately marked `// UNVERIFIED` in `FoundationModelParser.swift`; this file itself has no
// FM-specific API calls to verify.
import Foundation

// MARK: - IntentParser protocol (frozen contract)

/// One utterance -> 1...10 tasks, or one parent title -> 3...9 breakdown step titles. Implemented
/// by `FoundationModelParser`, `CloudParser`, and (elsewhere) `HeuristicNLParser`. Never throws for
/// content reasons — a parser that can't produce anything usable returns `[]` and lets
/// `IntentRouter` fall through to the next tier (constitution II: a parsing failure degrades,
/// never crashes, never silently drops the whole utterance).
protocol IntentParser: Sendable {
    func parse(_ transcript: String, now: Date, openTaskTitles: [String]) async -> [ParsedTask]
    func breakdown(title: String, notes: String?) async -> [String]
}

/// title+done ONLY for an existing subtask (anh Khôi, 2026-07-29 "richer context" addendum) —
/// threaded as extra, OPTIONAL context into `breakdown` calls so a repeat call never
/// regenerates or repeats a step already finished. Mirrors the server's `existing_subtasks` wire
/// shape (`_shared/schema.ts`'s `TaskContextFields`) field-for-field — NEVER a task id, matching
/// the same "titles only, no ids" privacy posture `ResolveCompletionRequest.candidates` already
/// documents for a different field. Declared here (not in `CloudParser.swift`/
/// `FoundationModelParser.swift`) because both of those files, plus `AppState.swift`, need the
/// exact same shape — one type, not three independently-drifting ones.
struct TaskContextSubtask: Sendable, Equatable {
    let title: String
    let done: Bool
}

// MARK: - Cloud opt-in / reachability gate (injected — owned by Settings/AppState/StoreKit agent)

/// Whether Cloud is even allowed to be *attempted* this call. Quota (429) is a per-call SERVER
/// verdict handled inside `CloudParser`/`IntentRouter`, not this gate — this only covers the two
/// preconditions research.md R5 requires before any network request is made: explicit one-time
/// privacy consent (constitution I — text egress requires consent regardless of tier) and basic
/// reachability (avoid a doomed round-trip while offline).
///
/// ASSUMPTION for the reviewer to check against the StoreKit/Settings work: this protocol is
/// deliberately minimal (two booleans, no tier/entitlement info) — tier selection (paid JWS vs
/// free device token) lives entirely inside whatever concrete `ParseCredentialProvider` is
/// injected into `CloudParser` (see `CloudParser.swift`), not here. `IntentRouter` only asks "may
/// I try Cloud at all right now."
protocol CloudParseGate: Sendable {
    /// One-time explicit privacy consent has been granted (never assume true; absent consent,
    /// Cloud must never be attempted even if a valid credential exists).
    func isOptedIn() async -> Bool
    /// Best-effort network reachability. `true` when unknown/unable to determine (a real request
    /// will fail cleanly and fall through anyway — this is purely an optimization to skip an
    /// obviously-doomed request, not a security gate).
    func isOnline() async -> Bool
}

// MARK: - IntentRouter (T019)

/// Routes Cloud (opted-in + online, credential available) -> FM (on-device, if available) ->
/// title-only floor. ALWAYS returns a usable, non-empty `[ParsedTask]`: any route failure
/// (unavailable, decode violation, transport error, 401/5xx) falls through silently to the next
/// tier; the title-only floor is unconditional and always available. The 10-task cap is enforced
/// here regardless of which tier produced the result (defense in depth — each producer is also
/// expected to cap itself).
///
/// anh Khôi chốt 2026-07-28: `HeuristicNLParser` (Sources/Model/NLParser.swift) used to sit
/// beneath Cloud as a third tier — keyword/regex-guessed deadline/priority/recurrence/conditions
/// when neither FM nor Cloud were available. That tier is now DISCONNECTED, deliberately, not
/// deleted: `HeuristicNLParser`'s code is untouched and still fully present in `NLParser.swift`.
/// When FM and Cloud both fail to produce anything, this router now falls straight to a
/// title-only task (see `titleOnlyTask` below) instead of a heuristic guess. To reconnect it:
/// add back a `heuristic: IntentParser` parameter to `init` (defaulting to `HeuristicNLParser()`)
/// and an `await heuristic.parse(...)` / `await heuristic.breakdown(...)` call ahead of the
/// title-only fallback in `parse`/`breakdown` below — this exact shape is preserved in git
/// history (the commit right before this comment landed) if that's ever wanted again.
@MainActor
final class IntentRouter: IntentParser {
    /// Hard cap, all tiers, all call sites (contract: "Enforces the 10-task cap centrally").
    nonisolated static let maxTaskCap = 10

    /// Which tier actually produced the last successful result — diagnostics only, never PII
    /// (no transcript/title content), safe to log.
    ///
    /// `.heuristic` (2026-07-28: removed) used to name the old keyword/regex floor tier below
    /// Cloud. It is gone, not renamed to `.titleOnly`, because the two are different claims:
    /// `.heuristic` meant "a keyword scan guessed at structure"; `.titleOnly` means "no tier
    /// guessed at anything — the task is exactly, and only, the verbatim transcript as its
    /// title." Confirmed by repo-wide grep before this change that nothing reads `lastRoute`
    /// outside this file yet (see `backlog.md`'s "lastCloudQuotaNote/lastRoute chưa có UI đọc"
    /// note) — so no UI copy needs to change alongside this, but whoever eventually wires a
    /// reader should know `.heuristic` no longer exists as a case.
    enum Route: String, Sendable, Equatable {
        case foundationModel, cloud, titleOnly
        /// Transcript was empty/whitespace-only — `parse` returned `[]` without attempting any
        /// tier at all. Distinct from `.titleOnly`: that case always means "here is a task whose
        /// title is the transcript"; this one means there was no transcript to make a title out
        /// of in the first place.
        case empty
    }

    /// Set at the start of every `parse(...)` call; read by the confirm-card owner afterward.
    /// Default mirrors the pre-any-call floor (no call has happened yet, so nothing was actually
    /// title-only) — same role the old `.heuristic` default played.
    private(set) var lastRoute: Route = .titleOnly
    /// `true` for exactly the duration between a `parse(...)` call that hit Cloud's 429 and the
    /// NEXT `parse(...)` call (reset at the top of every call) — the confirm-card/UI owner reads
    /// this once per parse to show the one-line gentle note (FR-012, parse-proxy.md 429). This is
    /// a side channel: the frozen `IntentParser.parse` return type is `[ParsedTask]` only, so the
    /// "quota" signal can't ride in the return value itself.
    private(set) var lastCloudQuotaNote = false

    private let fm: FoundationModelParser?
    private let cloud: CloudParser?
    private let cloudGate: CloudParseGate?

    /// - Parameters:
    ///   - foundationModel: Defaults to the capability-probed singleton-ish factory — `nil` on
    ///     macOS < 26, non-Apple-Silicon, or when the on-device model itself isn't available
    ///     (probe never crashes; see `FoundationModelParser.makeIfAvailable()`).
    ///   - cloud: `nil` disables the Cloud tier entirely (e.g. no `ParseCredentialProvider`
    ///     composite wired up yet) — router falls straight to FM, then the title-only floor.
    ///   - cloudGate: `nil` also disables Cloud (never attempt Cloud without an explicit gate
    ///     that can assert consent).
    ///
    ///   (2026-07-28: this initializer used to also take a `heuristic: IntentParser` parameter,
    ///   defaulting to `HeuristicNLParser()`. Removed along with the tier itself — see the class
    ///   doc comment above for why, and how to bring it back.)
    init(
        foundationModel: FoundationModelParser? = FoundationModelParser.makeIfAvailable(),
        cloud: CloudParser? = nil,
        cloudGate: CloudParseGate? = nil
    ) {
        self.fm = foundationModel
        self.cloud = cloud
        self.cloudGate = cloudGate
    }

    func parse(_ transcript: String, now: Date, openTaskTitles: [String]) async -> [ParsedTask] {
        lastCloudQuotaNote = false
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Nothing to parse. Callers shouldn't invoke this on empty input, but never crash or
            // fabricate a task out of nothing — an empty result here is the one legitimate `[]`.
            // `.empty`, NOT `.titleOnly`: there is no transcript to make a title out of, so this
            // is not the same claim as "the task is exactly the transcript, title-only."
            lastRoute = .empty
            return []
        }

        // R5: openTaskTitles forwarded to a remote/on-device model ONLY on dependency phrasing —
        // applied once here so every tier sees the same (possibly-empty) list.
        let titles = Self.containsDependencyPhrasing(transcript)
            ? Array(openTaskTitles.prefix(100))
            : []

        // Read once per `parse` call (not once per tier) so both tiers below see the exact same
        // number even if a Settings write races between them — negligible in practice, but this is
        // the cheap-and-correct way to write it either way.
        let defaultDurationMinutes = Self.currentDefaultDurationMinutes()

        // anh Khôi chốt 2026-09-06: Cloud is the DEFAULT tier for every entry point (voice, ⌃⌥T,
        // ⌘K), so it runs FIRST and FM became the offline/quota fallback beneath it. Before this,
        // FM answered first whenever Apple Intelligence was available, which meant Cloud (and
        // therefore `taskRefs`/`updates`, which only Cloud can produce) never ran at all on an
        // eligible Mac.
        var cloudSaidNothingActionable = false
        if let cloud, let cloudGate, await cloudGate.isOptedIn(), await cloudGate.isOnline() {
            switch await cloud.parseDetailed(transcript, now: now, openTaskTitles: titles) {
            case .tasks(let tasks) where !tasks.isEmpty:
                lastRoute = .cloud
                // `applyStartTimeDerivation` runs here AND at the FM return below — same static
                // function, one implementation, so the two tiers can never diverge on this rule
                // (see the function's own doc comment for the full rationale).
                return Self.applyStartTimeDerivation(Self.cap(tasks), defaultMinutes: defaultDurationMinutes)
            case .tasks:
                // Decoded fine, but the model found no actionable task in the utterance (small
                // talk). Reachable as of 2026-08-01 — `CloudParser.parseDetailed` used to report
                // this same case as `.unavailable`, making this branch dead code; see that guard's
                // comment. Falls through to the title-only floor below: anh Khôi chốt 2026-08-01
                // that a captured utterance must still become something the user can see and
                // dismiss, never silently nothing.
                //
                // Deliberately SKIPS the FM tier below (2026-09-06): Cloud actually looked at this
                // utterance and said "no task here." Letting the weaker on-device tier then invent
                // one would overrule a real verdict with a guess — the title-only floor is the
                // honest answer. Only "Cloud never answered" (`.unavailable`/`.quotaExceeded`/
                // opted out/offline) falls through to FM.
                cloudSaidNothingActionable = true
            case .quotaExceeded:
                lastCloudQuotaNote = true
            case .unavailable:
                break
            }
        }

        if let fm, !cloudSaidNothingActionable {
            let result = await fm.parse(transcript, now: now, openTaskTitles: titles)
            if !result.isEmpty {
                lastRoute = .foundationModel
                return Self.applyStartTimeDerivation(Self.cap(result), defaultMinutes: defaultDurationMinutes)
            }
        }

        // anh Khôi chốt 2026-07-28: neither FM nor Cloud produced anything usable — fall straight
        // to the title-only floor instead of the old `HeuristicNLParser` keyword-guess tier (see
        // this class's doc comment above for the full rationale and how to reconnect it;
        // `HeuristicNLParser` itself is untouched in `NLParser.swift`, just no longer wired here).
        //
        // `titleOnlyTask`'s title carries no guess at all — it is the verbatim (trimmed)
        // transcript, which is exactly, not approximately, what the user said. `ParsedTask.title`
        // has no confidence wrapper (it's a plain `String`, documented in `NLParser.swift` as
        // "required; only guaranteed field") so there is no confidence VALUE to pick here; if
        // there were, 1.0 would be correct for the same reason — this isn't a model inferring
        // structure from ambiguous speech, it's the speech itself, unmodified.
        lastRoute = .titleOnly
        return [Self.titleOnlyTask(transcript)]
    }

    /// task_refs_v1 (anh Khôi, 2026-08-02 task-refs design): full-`ParsedCapture` sibling of
    /// `parse` above — same Cloud -> FM -> title-only floor waterfall, same dependency-phrasing
    /// detection, same 10-task cap, same `applyStartTimeDerivation` pass, but also carries
    /// `taskRefs`/`updates` through from the Cloud tier instead of discarding them. Deliberately
    /// NOT part of the frozen `IntentParser` protocol — mirrors `resolveCompletion` above (same
    /// rationale, restated here: a new required protocol method would
    /// force `HeuristicNLParser`, `Sources/Model/NLParser.swift`, off-limits this round, to grow a
    /// case it has nothing honest to answer `taskRefs`/`updates` with).
    ///
    /// `AppState`'s one real call site is expected to migrate from `parse` to this method (per this
    /// task's own instruction to the sibling agent editing `AppState.swift`); `parse` itself is left
    /// completely unchanged and fully working, both for `IntentParser` protocol conformance and for
    /// any other caller.
    ///
    /// FM and the title-only floor have no notion of task references at all — this method wraps
    /// their plain `[ParsedTask]` result in `ParsedCapture(tasks:, taskRefs: [], updates: [])`
    /// rather than attempting to invent refs/updates for a tier that never extracted any
    /// (constitution II: never fabricate). Only the Cloud tier, and only when the server recognizes
    /// `client_caps: ["task_refs_v1"]`, can ever populate a non-empty `taskRefs`/`updates`.
    func parseCapture(_ transcript: String, now: Date, openTaskTitles: [String]) async -> ParsedCapture {
        lastCloudQuotaNote = false
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Same `.empty` semantics as `parse` above — no transcript to make a title (or a
            // capture) out of at all.
            lastRoute = .empty
            return ParsedCapture(tasks: [], taskRefs: [], updates: [])
        }

        let titles = Self.containsDependencyPhrasing(transcript)
            ? Array(openTaskTitles.prefix(100))
            : []
        let defaultDurationMinutes = Self.currentDefaultDurationMinutes()

        // Cloud-first, same rule and same rationale as `parse` above (anh Khôi 2026-09-06) — with
        // one extra reason specific to this method: `taskRefs`/`updates` exist ONLY on the Cloud
        // tier, so an FM-first ladder silently disabled voice task-editing on every Mac with
        // Apple Intelligence turned on.
        var cloudSaidNothingActionable = false
        if let cloud, let cloudGate, await cloudGate.isOptedIn(), await cloudGate.isOnline() {
            switch await cloud.parseCaptureDetailed(transcript, now: now, openTaskTitles: titles) {
            case .capture(let capture) where !capture.tasks.isEmpty || !capture.updates.isEmpty:
                // A pure-update utterance ("task kia phải xong hôm nay", no new task mentioned at
                // all) legitimately produces an EMPTY `tasks[]` alongside a non-empty `updates[]` —
                // that is real, actionable content (per the server's own `TaskUpdateOut` doc
                // comment), so this branch must trigger on EITHER `tasks` or `updates` being
                // non-empty, never `tasks` alone the way `parse`'s analogous check does.
                lastRoute = .cloud
                let derivedTasks = Self.applyStartTimeDerivation(
                    Self.cap(capture.tasks), defaultMinutes: defaultDurationMinutes
                )
                // `taskRefs`/`updates` are already capped/validated inside
                // `ParsedTaskValidation.validateCapture` — no further truncation needed here,
                // unlike `tasks`, which always goes through the shared `Self.cap`/
                // `applyStartTimeDerivation` pass every tier uses.
                return ParsedCapture(tasks: derivedTasks, taskRefs: capture.taskRefs, updates: capture.updates)
            case .capture:
                // Envelope decoded fine but genuinely carries nothing (no tasks, no updates,
                // possibly a `taskRefs` entry with nothing actionable attached to it) — same "small
                // talk" case `parse` documents for its own `.tasks` empty-array branch, including
                // the "don't let FM overrule a real Cloud verdict" rule (see that branch's comment).
                cloudSaidNothingActionable = true
            case .quotaExceeded:
                lastCloudQuotaNote = true
            case .unavailable:
                break
            }
        }

        if let fm, !cloudSaidNothingActionable {
            let result = await fm.parse(transcript, now: now, openTaskTitles: titles)
            if !result.isEmpty {
                lastRoute = .foundationModel
                let derived = Self.applyStartTimeDerivation(Self.cap(result), defaultMinutes: defaultDurationMinutes)
                return ParsedCapture(tasks: derived, taskRefs: [], updates: [])
            }
        }

        lastRoute = .titleOnly
        return ParsedCapture(tasks: [Self.titleOnlyTask(transcript)], taskRefs: [], updates: [])
    }

    /// Frozen `IntentParser` witness. NOTE (anh Khôi, 2026-07-29 "richer context" addendum): the
    /// one real app call site (`AppState.fetchBreakdown`) no longer calls this exact method — it
    /// calls `breakdownWithContext` below instead, so it can also forward `sourceTranscript`/
    /// `deadline`/`existingSubtasks`. This method is kept fully working (protocol conformance
    /// requires it, and `HeuristicNLParser` elsewhere still calls the matching `IntentParser`
    /// shape) but is effectively the "no extra context available" case now.
    func breakdown(title: String, notes: String?) async -> [String] {
        // Cloud-first since 2026-09-06, same rule as `parse`/`parseCapture` above.
        if let cloud, let cloudGate, await cloudGate.isOptedIn(), await cloudGate.isOnline() {
            let steps = await cloud.breakdown(title: title, notes: notes)
            if Self.isValidBreakdown(steps) { return steps }
        }
        if let fm {
            let steps = await fm.breakdown(title: title, notes: notes)
            if Self.isValidBreakdown(steps) { return steps }
        }
        // anh Khôi chốt 2026-07-28: no more `HeuristicNLParser().breakdown(...)` floor here either
        // (see the class doc comment above `init`). Breakdown has no honest on-device fallback —
        // unlike `parse`'s title-only floor (the transcript itself is always a legitimate task
        // title), there is no non-fabricated way to invent 3...9 step titles without a real model.
        // So: neither tier available/usable -> `[]`, and the caller is responsible for telling the
        // user this needs cloud rather than showing invented steps (`breakdownWithContext` below
        // shares this exact same rule for the real app call site).
        return []
    }

    /// Context-enriched sibling of `breakdown(title:notes:)` above (anh Khôi, 2026-07-29 "richer
    /// context" addendum) — same Cloud -> FM -> `[]` shape and same "no fabricated floor" rule,
    /// but also forwards `sourceTranscript`/`deadline`/`existingSubtasks` so the model can ground
    /// steps in the user's own original words and never repeat a step already done. Deliberately a
    /// SEPARATE method rather than adding parameters to `breakdown(title:notes:)` itself: that
    /// method is this class's witness for the frozen `IntentParser` protocol requirement
    /// (`func breakdown(title: String, notes: String?) async -> [String]`), and `HeuristicNLParser`
    /// (`Sources/Model/NLParser.swift`, off-limits to this change) also conforms to that exact
    /// signature — changing it would ripple into a file this task cannot touch. `AppState
    /// .fetchBreakdown` (the one real call site) calls THIS method now, not `breakdown(title:notes:)`.
    func breakdownWithContext(
        title: String,
        notes: String?,
        sourceTranscript: String?,
        deadline: Date?,
        existingSubtasks: [TaskContextSubtask]?
    ) async -> [String] {
        // Cloud-first since 2026-09-06 (same rule as `parse`); this is also the one call site the
        // app actually uses, and the FM tier here is the hardcoded-English 5-step floor backlog.md
        // already flags as poor — so it belongs UNDER the cloud steps, not above them.
        if let cloud, let cloudGate, await cloudGate.isOptedIn(), await cloudGate.isOnline() {
            let steps = await cloud.breakdownDetailed(
                title: title, notes: notes, sourceTranscript: sourceTranscript,
                deadline: deadline, existingSubtasks: existingSubtasks
            ) ?? []
            if Self.isValidBreakdown(steps) { return steps }
        }
        if let fm {
            let steps = await fm.breakdownWithContext(
                title: title, notes: notes, sourceTranscript: sourceTranscript,
                deadline: deadline, existingSubtasks: existingSubtasks
            )
            if Self.isValidBreakdown(steps) { return steps }
        }
        // Same "no fabricated floor" rule as `breakdown(title:notes:)` above.
        return []
    }

    // MARK: - Resolve-completion (T0xx: cloud-only paraphrase rescue for `VoiceDone`'s
    // empty-candidate case)
    //
    // Deliberately a SEPARATE method from `parse` above, not folded into it: `parse` answers "turn
    // this utterance into new tasks"; this answers "which existing task did the user just finish."
    // Different question, different prompt, different failure handling — merging them would
    // degrade both (per this task's own instruction).
    //
    // Cloud-only, no FM/Heuristic tier: FoundationModels and the on-device heuristic parser have
    // nothing to contribute to a semantic-paraphrase match. In fact the HEURISTIC layer here *is*
    // `VoiceDone`'s own Jaccard token-set matcher (`Sources/Speech/VoiceDone.swift`), which already
    // ran, on-device, before the caller (`AppState.resolveCompletionViaCloud`) ever reaches this
    // method — this method only exists for the case that matcher already reported "nothing above
    // the floor." There is no local fallback tier left to try; unavailable Cloud means "no
    // resolution," full stop, and the caller degrades to today's existing "no matching task" UI.
    func resolveCompletion(
        _ transcript: String, now: Date, kind: CloudParser.CompletionKind, candidates: [String]
    ) async -> CloudParser.CompletionResolution {
        // Same cloud opt-in + reachability gate `parse` applies above (R5: explicit one-time
        // privacy consent "regardless of tier" + best-effort reachability) — never sends a
        // transcript or candidate list without both being true, and (like `parse`) `cloud`/
        // `cloudGate` being `nil` (Cloud tier not wired up at all) is treated identically to "not
        // opted in."
        guard let cloud, let cloudGate, await cloudGate.isOptedIn(), await cloudGate.isOnline() else {
            return .unavailable
        }
        // Same defensive cap `parse` applies to `openTaskTitles` before it ever reaches
        // `CloudParser` — belt-and-suspenders alongside `CloudParser.resolveCompletion`'s own
        // internal 100-entry cap, since this is a second, independent call site into that
        // transport.
        let bounded = Array(candidates.prefix(100))
        return await cloud.resolveCompletion(transcript, now: now, kind: kind, candidates: bounded)
    }

    // MARK: - Cap + floor helpers
    //
    // `nonisolated` on these `static func`s is deliberate, not decorative: `IntentRouter` is
    // `@MainActor`, but `CloudParser`/`FoundationModelParser` are NOT (they run their network/FM
    // work off the main actor) and call these helpers directly (`IntentRouter.cap(...)`,
    // `IntentRouter.isValidBreakdown(...)`) without `await`. Each is a pure function over
    // `Sendable` values touching no actor-isolated state, so `nonisolated` is sound — without it,
    // Swift 6 strict concurrency would require every call site to `await`, or these calls would
    // fail to compile at all from a non-`@MainActor` context. `maxTaskCap` needs `nonisolated` for
    // the same reason: a `static let` declared inside a `@MainActor` type inherits that isolation
    // (only statics at global/file scope, outside an isolated type, are implicitly `nonisolated`),
    // so without it the off-main callers hit "cannot be accessed from outside of the actor".

    nonisolated static func cap(_ tasks: [ParsedTask]) -> [ParsedTask] {
        Array(tasks.prefix(maxTaskCap))
    }

    nonisolated static func isValidBreakdown(_ steps: [String]) -> Bool {
        (3...9).contains(steps.count)
            && steps.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: - Default task duration setting (2026-07-29)
    //
    // anh Khôi chốt 2026-07-29: "cái 30ph là estimate trong setting của user ... task cứ default
    // lấy từ setting ra cho duration task" — the 30-minute figure `applyStartTimeDerivation` below
    // used to hard-code is now a real user-configurable `AppState.defaultTaskDurationMinutes`
    // setting, read here via the same "non-`@MainActor`-reachable static helper reads `UserDefaults`
    // directly" seam `ReminderScheduler.currentGlobalReminderPolicy()` (`Sources/Reminders/
    // ReminderScheduler.swift`) already established for the identical problem (a Settings value
    // `AppState` owns, needed from a call site with no frozen init parameter to thread it through).

    /// Reads the user's default-task-duration setting straight out of `UserDefaults`. Reads
    /// `AppState.defaultTaskDurationMinutesKey` BY NAME, never a duplicated string literal, so this
    /// and `AppState`'s own read in `init` can never drift onto two different keys. Same 5...480
    /// bound and same 30-minute fallback as `AppState.setDefaultTaskDurationMinutes` — including the
    /// `UserDefaults.integer(forKey:)` returns-`0`-for-an-absent-key trap that bound also guards
    /// against.
    nonisolated static func currentDefaultDurationMinutes() -> Int {
        let stored = UserDefaults.standard.integer(forKey: AppState.defaultTaskDurationMinutesKey)
        return (5...480).contains(stored) ? stored : 30
    }

    // MARK: - Emergency-utterance deadline derivation (2026-07-28)
    //
    // anh Khôi chốt 2026-07-28: no new "emergency" task kind/flag. Instead, for an urgent
    // utterance ("làm task disposition code ngay lập tức") both the Cloud (Gemini) and on-device
    // tiers report `priority: 1`, `startTime` = "right now", and DELIBERATELY omit `deadline` (see
    // `supabase/functions/_shared/gemini.ts`'s prompt and this file's `FoundationModelParser`
    // prompt rules — never invent a deadline the user didn't imply). Every other part of the app
    // (sort order, reminders, the confirm card's deadline chip) keys off `deadline`, not
    // `startTime` — this function bridges that gap by deriving a PROVISIONAL deadline so a
    // startTime-only task still behaves like every other task downstream, without ever inventing
    // one for a task that already has a real, user-stated deadline.
    nonisolated static func applyStartTimeDerivation(
        _ tasks: [ParsedTask], defaultMinutes: Int = 30
    ) -> [ParsedTask] {
        tasks.map { task in
            // Only derive when there IS a startTime AND there is NOT already a deadline — a task
            // that states both ("làm ngay, 5 giờ chiều phải xong" -> startTime = now AND
            // deadline = 17:00) keeps its user-stated deadline completely untouched (constitution
            // II: never overwrite/second-guess what the user actually said).
            guard let startTime = task.startTime, task.deadline == nil else { return task }

            // `estimateMinutes` wins over the default when the model/user also gave a duration
            // estimate for the task ("ngay lập tức, chắc mất 45 phút" -> startTime + 45', not the
            // flat 30' default). `ParsedTask.estimateMinutes` is `ParsedValue<Int>?` (confirmed by
            // reading `NLParser.swift`'s `ParsedTask` declaration) — `.value` is already an `Int`
            // of minutes, no unit conversion needed here.
            let minutes = task.estimateMinutes?.value ?? defaultMinutes

            // `Calendar.current.date(byAdding: .minute, value:, to:)` — never raw `TimeInterval`
            // second-math (`startTime.value.addingTimeInterval(Double(minutes) * 60)` would also
            // work numerically today, but adding via `Calendar` is the deliberate, DST-safe choice
            // per this task's instruction). Foundation's contract allows this to return `nil`
            // (calendrical overflow); on `nil` the task is returned completely unmodified rather
            // than crashing or fabricating a deadline from a failed computation.
            guard let derivedDeadline = Calendar.current.date(
                byAdding: .minute, value: minutes, to: startTime.value
            ) else {
                return task
            }

            var derived = task
            // 2026-07-29, anh Khôi chốt — REVERSED from this function's original design, on
            // purpose, so read this before touching either number below:
            //
            // This confidence used to be a deliberately LOW 0.35 — well under `ParsedValue.
            // isUncertain`'s `confidence < 0.7` threshold (`Sources/Model/NLParser.swift:25`) — so
            // the confirm card's deadline chip rendered dashed and required an explicit accept tap
            // before the derived deadline would ever commit, exactly like any other low-confidence
            // attribute (constitution II: never silently commit a guess).
            //
            // That was tried, and it broke the very feature it belongs to: `AppState.resolvedValue`
            // (`Sources/App/AppState.swift`, ~line 3208) drops any `ParsedValue` below 0.7 unless the
            // user explicitly taps to accept it. So a user who said "làm task X ngay lập tức" and
            // then just hit Save — the entire point of an "urgent" utterance being fast — got a task
            // persisted with `deadline == nil`: it never sorted to the top, never got a reminder,
            // never did the one thing this feature exists to do. Requiring an extra confirm tap
            // defeats "ngay lập tức" as thoroughly as fabricating the deadline silently would have.
            //
            // Fix: 0.75 — ABOVE the 0.7 bar, so this auto-commits on a plain Save with zero extra
            // taps — plus `deadlineIsEstimated = true` on the task (see that field's own doc comment
            // in `NLParser.swift`), which is the explicit, separate signal `PopoverView.
            // DeadlineControl` uses to still label the chip as a guess (e.g. "· est") without gating
            // it behind an accept. 0.75, not 1.0: this is still a machine estimate, not something the
            // user said — if a future caller ever needs to distinguish "fully certain" from "quite
            // sure, but a guess," 0.75 already tells that story; 1.0 would falsely claim the former.
            //
            // DO NOT drop this back below 0.7 without also re-solving the `resolvedValue` interaction
            // above — that combination is exactly what silently broke the feature the first time.
            derived.deadline = ParsedValue(value: derivedDeadline, confidence: 0.75)
            derived.deadlineIsEstimated = true

            // 2026-07-29, anh Khôi chốt: also fill in `estimateMinutes` itself when the model/user
            // never gave one — this is the "duration" half of the same setting (`AppState.
            // defaultTaskDurationMinutes`), not a second, independent number. Deliberately the SAME
            // 0.75 confidence as `deadline` right above (not the low, pre-reversal confidence this
            // function used to use — see that comment block) for the identical reason: below 0.7,
            // `AppState.resolvedValue` (`Sources/App/AppState.swift`, ~line 3206) drops any
            // unaccepted `ParsedValue`, so a plain Save would persist the derived deadline but leave
            // `TaskItem.durationMinutes` empty — the estimate chip and the deadline chip would then
            // disagree about how long the task takes, exactly the confusion this single-setting
            // design exists to prevent. When the model/user DID supply an estimate, `minutes` above
            // already equals that value and this branch is skipped entirely — `task.estimateMinutes`
            // (with its own original confidence) is preserved completely untouched, per this
            // function's existing "never second-guess what was already stated" rule.
            if task.estimateMinutes == nil {
                derived.estimateMinutes = ParsedValue(value: minutes, confidence: 0.75)
            }

            return derived
        }
    }

    /// The absolute floor: a task with only a title (the source transcript, trimmed) and the
    /// transcript retained verbatim. Never crashes, never discards.
    nonisolated static func titleOnlyTask(_ transcript: String) -> ParsedTask {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedTask(
            title: trimmed.isEmpty ? transcript : trimmed,
            notes: nil,
            deadline: nil,
            startTime: nil,
            estimateMinutes: nil,
            priority: nil,
            reminderOverride: nil,
            recurrence: nil,
            kind: .task,
            conditions: [],
            subtasks: [],
            followUpReview: false,
            sourceTranscript: transcript
        )
    }

    // MARK: - Dependency-phrasing detector (R5)

    /// Best-effort keyword/regex detector for "sau khi", "xong … thì", "after", "when … done" —
    /// deliberately simple (per task brief: "provide a small detector or accept a flag"). False
    /// negatives just mean `openTaskTitles` isn't forwarded (parser falls back to no cross-task
    /// linking, never a crash); false positives just forward a harmless title list.
    nonisolated static func containsDependencyPhrasing(_ transcript: String) -> Bool {
        let lower = transcript.lowercased()
        if lower.contains("sau khi") { return true }
        if lower.range(of: #"\bxong\b[^.!?]{0,40}\bthì\b"#, options: .regularExpression) != nil {
            return true
        }
        if lower.range(of: #"\bafter\b"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"\bwhen\b[^.!?]{0,40}\bdone\b"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }
}

// MARK: - Shared raw wire shape (untrusted) + decode-validation helper

/// Wraps a raw model-reported value with its raw model-reported confidence — mirrors
/// `ConfidenceValue<T>` in `supabase/functions/_shared/schema.ts` (the ALREADY-IMPLEMENTED server
/// wire response for `/functions/v1/parse`). `CloudParser` decodes JSON directly into
/// `RawConfidence<T>`; `FoundationModelParser` constructs it manually from `@Generable` output
/// (each on-device field paired with a model-self-reported confidence). Both funnel into the same
/// `ParsedTaskValidation.validate` below — one validation code path for both remote tiers.
struct RawConfidence<T: Sendable>: Sendable {
    var value: T
    var confidence: Double
}
extension RawConfidence: Decodable where T: Decodable {}

struct RawParsedCondition: Sendable {
    /// "taskDone" | "afterDate" | "external" | "taskStart" (`"taskStart"` added task_refs_v1, anh
    /// Khôi 2026-08-02 task-refs design — mirrors `ParsedConditionOut.kind` in `_shared/schema.ts`;
    /// envelope-mode-only, never present in a bare-array response).
    var kind: String
    var referenceTitle: String?
    /// ISO8601 string.
    var date: String?
    var description: String?
    /// task_refs_v1: 1-based into the envelope's `taskRefs[]`, a precise pointer complementing the
    /// fuzzy `referenceTitle` above. NOT consumed this round — `ParsedCondition`
    /// (`Sources/Model/NLParser.swift`) is off-limits, so there is no structural field to carry it
    /// into; decoded here purely so its presence never causes a decode failure, then left unused.
    /// `referenceTitle` alone already carries everything the v1 `.taskDone` construction / notes-
    /// line fallback below need. Defaulted (`= nil`), NOT bare `Int?`, so the pre-existing
    /// `RawParsedCondition(kind:referenceTitle:date:description:)` call site in
    /// `FoundationModelParser.swift` (off-limits to this change) keeps compiling untouched — same
    /// "bare `Optional` alone doesn't earn a synthesized-memberwise-init default in this codebase"
    /// reasoning `RawParsedTask`'s own hand-rolled `init` right below exists to work around.
    /// `Double`, NOT `Int` (Opus review, 2026-08-02) — same 2026-08-01 rule `RawParsedRecurrence.
    /// everyDays` documents at length: `JSONDecoder` THROWS a non-integer JSON number into an
    /// `Int?` (it does not `nil` out), and one thrown field would kill the whole envelope decode.
    var refIndex: Double? = nil
    /// task_refs_v1: minutes offset relative to the referenced task's completion (`kind ==
    /// "taskDone"`) or start (`kind == "taskStart"`). v1 scope decision (anh Khôi, 2026-08-02):
    /// `ParsedCondition` gets no new enum case/associated value for this round, so
    /// `ParsedTaskValidation.validate` converts a present `offsetMinutes` into a human-visible notes
    /// line instead of silently dropping it — see `ParsedTaskValidation.taskDoneOffsetNoteLine`'s
    /// doc comment for the full rationale. Defaulted for the same reason as `refIndex` above.
    var offsetMinutes: Double? = nil
    /// "exact" | "atLeast" — whether `offsetMinutes` is a precise delay or a floor/"at least".
    /// Defaulted for the same reason as `refIndex` above.
    var offsetKind: String? = nil
}
extension RawParsedCondition: Decodable {}

struct RawParsedRecurrence: Sendable {
    /// "daily" | "weekly" | "monthly" | "every"
    var type: String
    /// `Double`, NOT `Int`, deliberately (2026-08-01): every numeric field on this wire shape is
    /// decoded as `Double` and narrowed to `Int` inside `ParsedTaskValidation.validate` via
    /// `Int(exactly:)`. `JSONDecoder` THROWS when a JSON number doesn't fit the requested integer
    /// type (`2.5` into an `Int?` is a decode failure, not a `nil`), and one thrown field kills the
    /// decode of the ENTIRE `[RawParsedTask]` array in `CloudParser.parseDetailed` — every task in
    /// the batch lost over one bad number, which is precisely what constitution II's "a parsing
    /// error on one attribute MUST NOT discard the others" forbids. The server's own validator
    /// (`_shared/schema.ts`'s `validateRecurrence`) only checks `isFiniteNumber(...) > 0` here, NOT
    /// `Number.isInteger`, so a non-integer really can reach this decoder even though Gemini's
    /// response schema declares `everyDays` as `integer`.
    var everyDays: Double?
}
extension RawParsedRecurrence: Decodable {}

struct RawParsedReminderOverride: Sendable {
    /// Minutes relative to the deadline, NEGATIVE = before (server: `_shared/schema.ts`'s
    /// `ParsedReminderOverrideOut.offsetsMinutes`). Converted to seconds, sign preserved, by
    /// `ParsedTaskValidation.validate` — `ReminderPolicy.offsets` uses the identical convention.
    var offsetsMinutes: [Double]
    /// Repeat cadence AFTER the deadline (`ReminderPolicy.repeatEvery`).
    var repeatEveryMinutes: Double?
    /// Repeat cadence BEFORE the deadline (`ReminderPolicy.remindPeriod`) — "nhắc tôi mỗi 15 phút"
    /// -> `15`. NOT the same thing as `repeatEveryMinutes` right above (that one repeats AFTER the
    /// deadline); the server's prompt has a whole rule teaching the model to keep the two apart
    /// (`_shared/gemini.ts`'s REMINDPERIOD section).
    ///
    /// ADDED 2026-08-01 — this field was MISSING here while every other layer already supported it:
    /// the server emitted it (`gemini.ts` response schema + `schema.ts`'s `validateReminderOverride`)
    /// and the client consumed it (`ReminderRecord.derive` prefers `remindPeriod` over
    /// `fractionsRemaining`; `PopoverView.reminderLabel` renders "Every 15 min"; `AppState`'s
    /// reminder chip writes it by hand). Only the wire DECODE was missing, so a user who actually
    /// said "nhắc tôi mỗi 15 phút" silently got the default proportional cadence instead — the one
    /// place the whole feature could be dropped, and it was.
    var remindPeriodMinutes: Double?
}
extension RawParsedReminderOverride: Decodable {}

/// Wire shape for `cue` (task_cues_v1, `specs/006-cues-and-waiting/design.md` §2) — mirrors
/// `CueOut` in `supabase/functions/_shared/schema.ts` (`{ kind: "wake"|"dayEnd"|"unknown";
/// verbatim: string }`). BOTH fields optional here even though the server always sends
/// `verbatim`: this is the exact "a non-optional key throws the WHOLE decode" trap
/// `RawParsedRecurrence.everyDays`'s 2026-08-01 doc comment already documents for a numeric
/// field — the same trap applies just as much to a missing STRING key, since `JSONDecoder`
/// throws on ANY absent non-optional key, not just a type-mismatched one. `RawParsedTask.cue:
/// RawParsedCue?` only protects against the `cue` KEY being absent (`decodeIfPresent`); a
/// present-but-malformed `cue` object (e.g. missing `verbatim`) would still throw through to the
/// whole task/array/envelope decode if `verbatim` here were non-optional. The REAL fail-open
/// rules live in `ParsedTaskValidation.validateCue` below: missing/empty `verbatim` drops the
/// cue (keeps the task), and an unrecognized `kind` string maps to `CueKind.unknown` rather than
/// dropping anything (`.unknown` is valid and common per that case's own doc comment in
/// `Model/TaskCue.swift`, T2-owned — referenced here BY NAME ONLY, never redefined).
struct RawParsedCue: Sendable {
    // Defaulted (`= nil`), NOT bare `String?`, for the same synthesized-memberwise-init
    // omittability reason `RawParsedTaskRef.assumeExisting` documents at length: a bare
    // `Optional` stored property alone does NOT earn a default in this codebase's observed
    // convention, so any direct-construction test call site that wants to omit one field needs
    // this written explicitly.
    var kind: String? = nil
    var verbatim: String? = nil
}
extension RawParsedCue: Decodable {}

struct RawParsedSubtask: Sendable {
    var title: RawConfidence<String>
    /// OPTIONAL even though the server always sends it (`_shared/schema.ts`'s `validateSubtask`
    /// rejects a subtask without one): `validate` below uses subtask TITLES only and discards this
    /// value entirely, so requiring it here buys nothing and costs everything — a missing/malformed
    /// `estimateMinutes` on one subtask would throw during decode and take the whole batch of tasks
    /// down with it (same "one bad field must not discard the others" reasoning as
    /// `RawParsedRecurrence.everyDays` above).
    var estimateMinutes: RawConfidence<Double>?
}
extension RawParsedSubtask: Decodable {}

/// The untrusted, wire-shaped task both Cloud and FM produce before validation. Mirrors
/// `ParsedTaskOut` in `supabase/functions/_shared/schema.ts` field-for-field. NEVER used
/// directly by app code beyond this file's validator — it exists only to be converted into a
/// validated `ParsedTask` by `ParsedTaskValidation.validate`.
struct RawParsedTask: Sendable {
    var title: RawConfidence<String>
    var notes: RawConfidence<String>?
    /// ISO8601 string.
    var deadline: RawConfidence<String>?
    /// ISO8601 string. The instant the speaker begins WORKING on the task (distinct from
    /// `deadline`, the instant it must be DONE) — only ever emitted for urgent/"do it right now"
    /// phrasing where the server/on-device model reports `priority: 1` and no `deadline` of its
    /// own; `IntentRouter.applyStartTimeDerivation` derives a provisional `deadline` from this
    /// (2026-07-28, anh Khôi chốt: no new task "kind"/flag for this — just this one extra field).
    var startTime: RawConfidence<String>?
    var estimateMinutes: RawConfidence<Double>?
    /// `Double`, not `Int` — same decode-safety reasoning as `RawParsedRecurrence.everyDays`;
    /// narrowed via `Int(exactly:)` in `ParsedTaskValidation.validate`.
    var priority: RawConfidence<Double>?
    var recurrence: RawConfidence<RawParsedRecurrence>?
    var reminderOverride: RawConfidence<RawParsedReminderOverride>?
    var conditions: [RawConfidence<RawParsedCondition>]?
    /// "task" | "review"
    var kind: RawConfidence<String>?
    var subtasks: [RawParsedSubtask]?
    var followUpReview: RawConfidence<Bool>?
    /// task_cues_v1 (`specs/006-cues-and-waiting/design.md`): only ever populated when the
    /// request advertised `"task_cues_v1"` in `client_caps` (`CloudParser.cuesCapability`) — a
    /// server that doesn't recognize the cap simply omits this key, which decodes to `nil` here
    /// either way (back-compat: no cap support yet == no `cue` key == unchanged pre-006
    /// behavior — the exact property `CloudParserTests`'s back-compat cue test pins down). Never
    /// wrapped in `RawConfidence<T>` like the fields above it: `CueOut`/`TaskCue` carry no
    /// model-reported confidence field at all (`design.md` §2's `TaskCue` — kind/verbatim/
    /// createdAt/expiresAt only), so there is nothing to wrap.
    var cue: RawParsedCue?

    init(
        title: RawConfidence<String>,
        notes: RawConfidence<String>? = nil,
        deadline: RawConfidence<String>? = nil,
        startTime: RawConfidence<String>? = nil,
        estimateMinutes: RawConfidence<Double>? = nil,
        priority: RawConfidence<Double>? = nil,
        recurrence: RawConfidence<RawParsedRecurrence>? = nil,
        reminderOverride: RawConfidence<RawParsedReminderOverride>? = nil,
        conditions: [RawConfidence<RawParsedCondition>]? = nil,
        kind: RawConfidence<String>? = nil,
        subtasks: [RawParsedSubtask]? = nil,
        followUpReview: RawConfidence<Bool>? = nil,
        cue: RawParsedCue? = nil
    ) {
        self.title = title
        self.notes = notes
        self.deadline = deadline
        self.startTime = startTime
        self.estimateMinutes = estimateMinutes
        self.priority = priority
        self.recurrence = recurrence
        self.reminderOverride = reminderOverride
        self.conditions = conditions
        self.kind = kind
        self.subtasks = subtasks
        self.followUpReview = followUpReview
        self.cue = cue
    }
}
extension RawParsedTask: Decodable {}

// MARK: - task_refs_v1 wire shapes (anh Khôi, 2026-08-02 task-refs design) — envelope-only
//
// The server sends these ONLY inside the `RawParseEnvelope` shape below (never mixed into the
// legacy bare `[RawParsedTask]` array) — mirrors `TaskRefOut`/`TaskUpdateSetOut`/
// `TaskUpdateConditionOut`/`TaskUpdateOut` in `supabase/functions/_shared/schema.ts` field-for-field.
// Same untrusted-until-validated posture as `RawParsedTask` above: nothing here is used directly by
// app code — `ParsedTaskValidation.validateCapture` is the only consumer.

/// Mirrors `TaskRefOut`.
struct RawParsedTaskRef: Sendable {
    var titleQuery: RawConfidence<String>
    /// `nil`/absent means "no hint either way" — validated down to a plain, non-optional `false`
    /// in `ParsedTaskRef.assumeExisting` (see that field's own doc comment). Defaulted (`= nil`) so
    /// this struct's synthesized memberwise init keeps it omittable at any construction site (this
    /// file's own tests included) — a bare `Bool?` alone does NOT earn a synthesized default in
    /// this codebase's observed convention, see `RawParsedTask`'s hand-rolled `init` above.
    var assumeExisting: Bool? = nil
}
extension RawParsedTaskRef: Decodable {}

/// Mirrors `TaskUpdateSetOut`. Every field independently FAIL-OPEN at validation, same as the
/// matching field on `RawParsedTask` itself. Every field defaulted (`= nil`) for the same
/// synthesized-memberwise-init-omittability reason `RawParsedTaskRef.assumeExisting` documents.
struct RawUpdateSet: Sendable {
    var deadline: RawConfidence<String>? = nil
    var startTime: RawConfidence<String>? = nil
    var notesAppend: RawConfidence<String>? = nil
    /// `Double`, not `Int` — same 2026-08-01 decode-safety precedent as `RawParsedTask.priority`:
    /// narrowed via `Int(exactly:)` at validation, so one fractional wire number can never throw
    /// mid-decode and take the whole envelope (every task, ref, and update in it) down with it.
    var priority: RawConfidence<Double>? = nil
    // `reminderOverride` is DELIBERATELY NOT declared here (anh Khôi, 2026-08-02, client scope
    // decision (c) — see `ParsedCapture.swift`'s header comment): `TaskUpdateSetOut.reminderOverride`
    // (with its wire-first `anchor` field) is out of scope for this round's client runtime. Swift's
    // synthesized `Decodable` ignores JSON keys with no matching stored property, so a
    // `set.reminderOverride` on the wire (with or without an `anchor`) still decodes successfully —
    // it is simply dropped, never causing the surrounding update (or the whole envelope) to fail
    // decode. This is the "lenient decoder that skips unknown keys" the task brief calls for,
    // achieved for free rather than needing any explicit handling.
}
extension RawUpdateSet: Decodable {}

/// Mirrors `TaskUpdateConditionOut` — a NEW dependency an update proposes adding to the REFERENCED
/// (existing) task. `newTaskIndex` is 1-based into this SAME response's `tasks[]` — a DIFFERENT
/// index space from `RawParsedTaskUpdate.refIndex` below (which points into `taskRefs[]`); see
/// `ParsedUpdateCondition`'s own doc comment in `ParsedCapture.swift` for why conflating the two
/// would be a real bug, not just a naming nit.
struct RawUpdateCondition: Sendable {
    /// "taskDone" | "afterDate"
    var kind: String
    /// `Double`, NOT `Int` (Opus review, 2026-08-02) — see `RawParsedRecurrence.everyDays`'s
    /// 2026-08-01 doc comment: a non-integer JSON number THROWS into `Int?`, killing the whole
    /// envelope decode over one bad field. Narrowed via `Int(exactly:)` in `validateTaskUpdates`.
    var newTaskIndex: Double? = nil
    /// ISO8601 string.
    var date: String? = nil
}
extension RawUpdateCondition: Decodable {}

/// Mirrors `TaskUpdateOut`. `refIndex` is FAIL-CLOSED at validation (an update that doesn't point
/// at a real, in-range ref is dangerous to misapply to the wrong task, so the WHOLE element is
/// dropped rather than guessed at) — every other field is independently FAIL-OPEN.
struct RawParsedTaskUpdate: Sendable {
    /// `Double?`, NOT bare `Int` (Opus review, 2026-08-02), for BOTH halves of the same decode-
    /// throw rule `RawParsedRecurrence.everyDays` documents: a non-integer number into `Int`
    /// throws, AND a missing key into a non-optional throws — either would kill the decode of the
    /// entire `updates` array (and with it the whole envelope, dropping the Cloud tier to
    /// fallback) over one malformed element. The server fail-closes elements without an integer
    /// `refIndex` so neither should ever arrive — this is belt-and-suspenders against server/client
    /// version skew, the exact scenario `client_caps` exists for. Absent/fractional -> the element
    /// is dropped in `validateTaskUpdates` via `Int(exactly:)`, never the whole response.
    var refIndex: Double? = nil
    var set: RawUpdateSet? = nil
    var addConditions: [RawUpdateCondition]? = nil
}
extension RawParsedTaskUpdate: Decodable {}

/// The envelope-shape response a server that recognizes `client_caps: ["task_refs_v1"]` returns
/// INSTEAD OF the bare `[RawParsedTask]` array `CloudParser.performParse` used to decode
/// unconditionally. `taskRefs`/`updates` are OPTIONAL on the wire (an envelope-aware server with
/// nothing to report for either still returns valid JSON that simply omits them) — absent means
/// "none," never a decode failure.
struct RawParseEnvelope: Sendable {
    var tasks: [RawParsedTask]
    var taskRefs: [RawParsedTaskRef]? = nil
    var updates: [RawParsedTaskUpdate]? = nil
}
extension RawParseEnvelope: Decodable {}

/// Converts untrusted `RawParsedTask` values into validated `ParsedTask`s (constitution II: "Raw
/// LLM output MUST NEVER be executed or persisted. It MUST be decoded into the validated
/// `ParsedTask`... Any decode/schema violation MUST fall back to a title-only task... A parsing
/// error on one attribute MUST NOT discard the others").
///
/// Two-tier fallback, matching the constitution's wording precisely:
///   1. **Per-attribute**: a malformed/out-of-range field (bad ISO8601 string, confidence outside
///      0...1, priority outside 1...4, empty condition description, etc.) drops ONLY that field —
///      every other attribute on the task is preserved.
///   2. **Per-task title**: if `title` itself is unusable (empty after trimming), the task becomes
///      title-only using the ORIGINAL transcript as its title (never a blank/garbage title).
/// A tier-wide failure (the raw array itself couldn't be decoded at all, e.g. malformed JSON) is
/// NOT handled here — that's reported by the producer (`CloudParser`/`FoundationModelParser`) as
/// "unavailable", so `IntentRouter` falls through to the NEXT tier (which can usually do better
/// than a bare title stub) rather than this helper manufacturing one low-quality task itself.
enum ParsedTaskValidation {
    /// Fresh formatters per call, deliberately not shared `static let`s: `ISO8601DateFormatter`
    /// is a mutable reference type Foundation hasn't marked `Sendable`, and this is called from
    /// multiple non-`@MainActor` contexts (`CloudParser`, `FoundationModelParser`) as well as the
    /// `@MainActor` router — a shared instance would be a Swift 6 strict-concurrency risk for a
    /// cost that's negligible against a parse call's actual work.
    static func parseISO8601(_ string: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        return fractional.date(from: string)
    }

    /// 0...1 inclusive; any other value (including NaN) is a schema violation -> field dropped.
    private static func validConfidence(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    // MARK: Reminder-override bounds (2026-08-01)
    //
    // The server deliberately does NOT bound these (`_shared/schema.ts`'s `validateReminderOverride`
    // checks `isFiniteNumber` and, for the two periods, `> 0` — nothing more), so this client is the
    // only place an absurd-but-finite value gets stopped. Same per-field/per-entry fail-open rule as
    // every other bound in this file: an out-of-range value drops ITSELF, never the task around it.

    /// One year, in minutes. Generous on purpose — "nhắc tôi trước 6 tháng" is unusual but real,
    /// while anything past a year is a glitch, not an intention.
    private static let maxReminderOffsetMinutes: Double = 365 * 24 * 60
    /// Ceiling on how many one-off offset marks a single override may carry. `ReminderScheduler`
    /// has its own system-wide notification-request cap; this stops one task from eating it.
    private static let maxReminderMarks = 10

    /// A repeat cadence (`repeatEveryMinutes` / `remindPeriodMinutes`) must be a real, finite,
    /// positive number of minutes no larger than `maxReminderOffsetMinutes` — a zero/negative period
    /// would make `ReminderRecord.derive`'s walk-back loop meaningless, and an enormous one produces
    /// a single mark so far out it never fires.
    private static func isValidReminderPeriodMinutes(_ minutes: Double) -> Bool {
        minutes.isFinite && minutes > 0 && minutes <= maxReminderOffsetMinutes
    }

    /// `now` (default `Date()`) is the same clock `CloudParser.performParse`/
    /// `FoundationModelParser.parse` already thread through their own `now:` parameter — passed
    /// down here ONLY so a decoded `cue` (task_cues_v1) can stamp `TaskCue.createdAt` at the
    /// instant this response was captured/validated, matching `TaskCue.expiresAt`'s "createdAt +
    /// 48h" contract (`Model/TaskCue.swift`). The default exists purely so every pre-006 call
    /// site (every test in `CloudParserTests.swift` that doesn't touch cue at all) keeps
    /// compiling unchanged — same "defaulted trailing parameter" convention this file already
    /// uses elsewhere (e.g. `RawParsedTaskRef.assumeExisting`).
    static func validateAll(_ raws: [RawParsedTask], sourceTranscript: String, now: Date = Date()) -> [ParsedTask] {
        raws.map { validate($0, sourceTranscript: sourceTranscript, now: now) }
    }

    static func validate(_ raw: RawParsedTask, sourceTranscript: String, now: Date = Date()) -> ParsedTask {
        let trimmedTitle = raw.title.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedTitle.isEmpty
            ? sourceTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmedTitle

        // Renamed from `notes` (was computed here directly) to `baseNotes`: task_refs_v1's
        // taskDone-offset/taskStart notes-line handling (see the `conditions` computation below)
        // needs to APPEND to whatever the model already put in `notes`, so the final `notes` value
        // can only be known once `conditions` has run. See `Self.combinedNotes` below.
        let baseNotes: String? = raw.notes.flatMap { c in
            let trimmed = c.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let deadline: ParsedValue<Date>? = raw.deadline.flatMap { c in
            guard validConfidence(c.confidence), let date = parseISO8601(c.value) else { return nil }
            return ParsedValue(value: date, confidence: c.confidence)
        }

        // `startTime` goes down the EXACT same path as `deadline` above (same `validConfidence` +
        // `parseISO8601` helpers) — per-attribute fallback (constitution II / this enum's own doc
        // comment): a malformed `startTime` (bad ISO8601 string, or confidence outside 0...1) drops
        // ONLY this field, never the rest of the task.
        let startTime: ParsedValue<Date>? = raw.startTime.flatMap { c in
            guard validConfidence(c.confidence), let date = parseISO8601(c.value) else { return nil }
            return ParsedValue(value: date, confidence: c.confidence)
        }

        let estimateMinutes: ParsedValue<Int>? = raw.estimateMinutes.flatMap { c in
            // `Int(_:)` on a `Double` TRAPS when the value is out of `Int`'s representable range
            // (e.g. a well-formed 200 response with `estimateMinutes: 1e300` — the server only
            // validates `isFinite && > 0`, not any upper bound). `Int(exactly:)` returns `nil`
            // instead of trapping, and the `1...1440` bound (mirrors this file's own reminder/
            // heuristic estimate caps — 24h) rejects any in-range-for-Int but nonsensical duration
            // the same way a schema violation is rejected everywhere else in this function: drop
            // only this field, keep the rest of the task (constitution II).
            guard validConfidence(c.confidence), c.value.isFinite, c.value > 0,
                  let est = Int(exactly: c.value.rounded()), (1...1440).contains(est)
            else { return nil }
            return ParsedValue(value: est, confidence: c.confidence)
        }

        let priority: ParsedValue<Int>? = raw.priority.flatMap { c in
            // `Int(exactly:)` WITHOUT `.rounded()` (unlike `estimateMinutes` above, where rounding a
            // duration is harmless): priority is a 4-value enum, not a measurement — a fractional
            // `2.4` is a schema violation, not a value to round, so it drops the field rather than
            // silently picking one of the two neighbouring priorities on the user's behalf.
            guard validConfidence(c.confidence), c.value.isFinite,
                  let level = Int(exactly: c.value), (1...4).contains(level)
            else { return nil }
            return ParsedValue(value: level, confidence: c.confidence)
        }

        let recurrence: ParsedValue<Recurrence>? = raw.recurrence.flatMap { c in
            guard validConfidence(c.confidence) else { return nil }
            let mapped: Recurrence?
            switch c.value.type {
            case "daily": mapped = .daily
            case "weekly": mapped = .weekly
            case "monthly": mapped = .monthly
            case "every":
                // Same strict `Int(exactly:)` narrowing as `priority` above — "every 2.5 days" is a
                // schema violation, not something to round into a plausible-looking cadence.
                if let raw = c.value.everyDays, raw.isFinite,
                   let days = Int(exactly: raw), days > 0 {
                    mapped = .every(days: days)
                } else {
                    mapped = nil
                }
            default: mapped = nil
            }
            guard let mapped else { return nil }
            return ParsedValue(value: mapped, confidence: c.confidence)
        }

        let reminderOverride: ParsedValue<ReminderPolicy>? = raw.reminderOverride.flatMap { c in
            guard validConfidence(c.confidence) else { return nil }
            // Sign is PRESERVED, never flipped: both sides use "negative = before the deadline"
            // (`_shared/schema.ts`'s `offsetsMinutes` comment and `ReminderPolicy.offsets`'s own doc
            // comment agree), so this is a pure minutes -> seconds conversion.
            //
            // `maxReminderOffsetMinutes`/`maxReminderMarks` bound what the server does NOT: its
            // `validateReminderOverride` only checks `isFiniteNumber`, so a hostile/glitched
            // `offsetsMinutes: [1e15]` would otherwise reach `ReminderRecord.derive` and turn into a
            // reminder date ~2 billion years out (plus one scheduled notification per entry, against
            // a hard system cap). Out-of-range entries are dropped INDIVIDUALLY — an utterance that
            // produced one sane offset and one absurd one keeps the sane one.
            let offsets = c.value.offsetsMinutes
                .filter { $0.isFinite && abs($0) <= Self.maxReminderOffsetMinutes }
                .prefix(Self.maxReminderMarks)
                .map { $0 * 60 }
            guard !offsets.isEmpty else { return nil }
            var repeatEvery: TimeInterval?
            if let minutes = c.value.repeatEveryMinutes, Self.isValidReminderPeriodMinutes(minutes) {
                repeatEvery = minutes * 60
            }
            // 2026-08-01: previously dropped on the floor — see `RawParsedReminderOverride
            // .remindPeriodMinutes`'s doc comment for the full story. `remindPeriod` is what
            // `ReminderRecord.derive` prefers over `fractionsRemaining`, so losing it here silently
            // downgraded "nhắc tôi mỗi 15 phút" to the app's default proportional cadence.
            var remindPeriod: TimeInterval?
            if let minutes = c.value.remindPeriodMinutes, Self.isValidReminderPeriodMinutes(minutes) {
                remindPeriod = minutes * 60
            }
            // Called by keyword, skipping `fractionsRemaining` (which keeps its `[]` default) —
            // `ReminderPolicy`'s own doc comment in `Recurrence.swift` pins this memberwise-init
            // shape precisely so this call site keeps compiling. `[]` is correct, not an oversight:
            // an explicit user-stated override replaces the app's proportional default rather than
            // stacking on top of it.
            let policy = ReminderPolicy(
                offsets: offsets, repeatEvery: repeatEvery, remindPeriod: remindPeriod
            )
            return ParsedValue(value: policy, confidence: c.confidence)
        }

        // task_refs_v1 (anh Khôi, 2026-08-02 task-refs design, v1 scope decision): collects the
        // human-visible notes lines a `taskDone` offset / a `taskStart` condition produces, since
        // `ParsedCondition` (`Sources/Model/NLParser.swift`, off-limits this round) has no
        // structural field/case for either — mutated from inside the `compactMap` closure below,
        // then folded into `notes` right after. See `Self.taskDoneOffsetNoteLine`/
        // `Self.taskStartNoteLine` for the full "never silently drop what the user said" rationale.
        var conditionOffsetNotes: [String] = []
        let conditions: [ParsedCondition] = (raw.conditions ?? []).compactMap { c in
            guard validConfidence(c.confidence) else { return nil }
            switch c.value.kind {
            case "taskDone":
                guard let ref = c.value.referenceTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !ref.isEmpty else { return nil }
                // An `offsetMinutes` alongside `taskDone` keeps the normal `.taskDone` condition
                // (the existing dependency-blocking UI keeps working unchanged) AND additionally
                // gets this notes line — nothing the user said about the offset is lost, it just
                // isn't structurally enforced yet.
                if let offsetMinutes = c.value.offsetMinutes, offsetMinutes.isFinite {
                    conditionOffsetNotes.append(
                        Self.taskDoneOffsetNoteLine(
                            title: ref, offsetMinutes: offsetMinutes, atLeast: c.value.offsetKind == "atLeast"
                        )
                    )
                }
                return .taskDone(titleQuery: ref, confidence: c.confidence)
            case "afterDate":
                guard let dateString = c.value.date, let date = parseISO8601(dateString) else { return nil }
                return .afterDate(date, confidence: c.confidence)
            case "external":
                guard let desc = c.value.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !desc.isEmpty else { return nil }
                return .external(description: desc, confidence: c.confidence)
            case "taskStart":
                // v1 scope decision: the client has no structural way to represent "block on
                // another task STARTING" at all (only `.taskDone`'s "block until it's DONE" exists)
                // — never silently drop it; surface as a notes line and emit NO condition, matching
                // the task brief's explicit instruction for this exact case.
                guard let ref = c.value.referenceTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !ref.isEmpty else { return nil }
                conditionOffsetNotes.append(
                    Self.taskStartNoteLine(
                        title: ref, offsetMinutes: c.value.offsetMinutes, atLeast: c.value.offsetKind == "atLeast"
                    )
                )
                return nil
            default:
                return nil
            }
        }

        let notes: String? = Self.combinedNotes(base: baseNotes, appendedLines: conditionOffsetNotes)

        let kind: TaskKind = {
            guard let kindValue = raw.kind?.value else { return .task }
            return kindValue == "review" ? .review : .task
        }()

        // Contract's `subtasks: [String]` carries titles only (no per-step confidence/estimate) —
        // drop empty titles, cap defensively against a hostile/buggy producer flooding this list.
        let subtasks: [String] = (raw.subtasks ?? [])
            .map { $0.title.value.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(20)
            .map { $0 }

        let followUpReview = raw.followUpReview?.value ?? false

        // task_cues_v1: NEVER derived from/converted into `deadline` above — see
        // `Self.validateCue`'s own doc comment for why that conflation is precisely the bug
        // 006-cues-and-waiting exists to fix.
        let cue = Self.validateCue(raw.cue, now: now)

        return ParsedTask(
            title: title,
            notes: notes,
            deadline: deadline,
            startTime: startTime,
            estimateMinutes: estimateMinutes,
            priority: priority,
            reminderOverride: reminderOverride,
            recurrence: recurrence,
            kind: kind,
            conditions: conditions,
            subtasks: subtasks,
            followUpReview: followUpReview,
            cue: cue,
            sourceTranscript: sourceTranscript
        )
    }

    // MARK: - Cue (task_cues_v1, `specs/006-cues-and-waiting/design.md` §1/§2)
    //
    // Cue is a SURFACING signal only — never eligibility, and NEVER converted into a
    // `deadline`/`afterDate` anywhere in this file (that exact conflation is the live bug this
    // feature exists to fix; nothing below ever touches the `deadline`/`conditions` computed
    // above). `TaskCue`/`CueKind` are owned by T2 (`Model/TaskCue.swift`) — referenced here BY
    // NAME ONLY, never redefined (same "PINNED PUBLIC SURFACE" convention `ParsedCapture.swift`
    // already establishes for a cross-agent shared type).

    /// Defensive length cap on `verbatim`, reusing the same 300-char number the server's own
    /// `MAX_TASK_TITLE_CHARS` (`supabase/functions/_shared/schema.ts`) already uses for this
    /// exact field (per `design.md`'s T1.2 instruction to the server-side agent) — same "never
    /// trust a remote response blindly" client-side re-check every other cap in this file already
    /// applies to its own field.
    private static let maxCueVerbatimChars = 300

    /// Fail-open per `design.md` §2 / this feature's own instruction: a `kind` this client
    /// doesn't recognize (or a server that hasn't rolled out task_cues_v1 to full parity yet)
    /// maps to `.unknown` — NEVER dropped, `.unknown` is valid and common (see `CueKind.unknown`'s
    /// own doc comment). A missing/empty `verbatim` drops the WHOLE cue while leaving every other
    /// field on the task untouched (constitution II: "a parsing error on one attribute MUST NOT
    /// discard the others").
    private static func validateCue(_ raw: RawParsedCue?, now: Date) -> TaskCue? {
        guard let raw else { return nil }
        guard let rawVerbatim = raw.verbatim else { return nil }
        let trimmed = rawVerbatim.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let capped = String(trimmed.prefix(Self.maxCueVerbatimChars))
        let kind = raw.kind.flatMap(CueKind.init(rawValue:)) ?? .unknown
        return TaskCue(
            kind: kind, verbatim: capped, createdAt: now, expiresAt: TaskCue.defaultExpiry(from: now)
        )
    }

    // MARK: - task_refs_v1 (anh Khôi, 2026-08-02 task-refs design) — envelope validation
    //
    // Everything below turns the untrusted `RawParseEnvelope` (`CloudParser.performParse`'s new
    // envelope-shape decode branch) into the validated `ParsedCapture` the rest of the app
    // consumes (`IntentRouter.parseCapture`). Same fail-open/fail-closed vocabulary `validate`
    // above already establishes:
    //   - `taskRefs`: per-element FAIL-OPEN on confidence — CLAMPED, not dropped, a deliberate
    //     exception to this file's usual "drop the bad field" rule (this task's own instruction:
    //     "clamp confidence to 0...1"); FAIL-CLOSED on an empty `titleQuery` (nothing left to
    //     search a task store by).
    //   - `updates`: FAIL-CLOSED per element on `refIndex` (an update that can't be traced to a
    //     real, already-validated ref is dangerous to misapply to the wrong task, so the WHOLE
    //     element drops rather than being guessed at — mirrors `TaskUpdateOut.refIndex`'s own doc
    //     comment server-side); FAIL-OPEN per `set` field (identical rules to the matching field on
    //     `ParsedTask` itself, right above); FAIL-CLOSED per `addConditions` element (an element
    //     that doesn't fully validate carries no information).
    //   - Nothing here ever mutates/auto-applies to an existing task — `ParsedTaskUpdate` is inert,
    //     validated data the confirm-card owner surfaces for explicit user confirmation (client
    //     scope decision (b), `ParsedCapture.swift`'s header comment); this file's job stops at
    //     "does this shape validate," never "apply this to a stored task."

    /// Mirrors the server's own `MAX_TASK_REFS` (`_shared/schema.ts`).
    private static let maxTaskRefs = 10
    /// Mirrors the server's own `MAX_UPDATES` (`_shared/schema.ts`).
    private static let maxUpdates = 10
    /// Mirrors the server's own `MAX_NOTES_CHARS` (`_shared/schema.ts`) — reused here for
    /// `notesAppend` per this task's own instruction ("length-capped at the same cap as notes"),
    /// even though the sibling `notes` field above (`raw.notes.flatMap`) has never enforced a
    /// client-side length cap of its own (it has always relied on the server's own `MAX_NOTES_CHARS`
    /// check) — this is that same number's first real client-side enforcement.
    private static let maxNotesAppendChars = 1000

    /// Confidence is CLAMPED here, not dropped-on-violation like `validConfidence` everywhere else
    /// in this file — a deliberate exception per this task's own instruction ("clamp confidence to
    /// 0...1"). Non-finite (NaN/±inf) clamps to 0 (treated as "no real signal" rather than an
    /// arbitrary in-range guess like 0.5 would be).
    private static func clampedConfidence(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// v1 scope decision (anh Khôi, 2026-08-02 task-refs design): `ParsedCondition`
    /// (`Sources/Model/NLParser.swift`) is OFF-LIMITS this round — no new enum case/associated
    /// value for `offsetMinutes`/`offsetKind`/`taskStart`. Rather than silently dropping what the
    /// user actually said (constitution: never do that), a `taskDone` condition carrying an
    /// `offsetMinutes` keeps its normal `.taskDone` condition (the existing dependency-blocking UI
    /// keeps working) AND gets this human-readable line appended to the task's notes.
    ///
    /// // UNVERIFIED backlog: proper support needs a real structural field (a new `ParsedCondition`
    /// associated value for the offset, or a genuinely new condition kind for `taskStart` with its
    /// own scheduling behavior) — out of scope for `NLParser.swift`'s frozen surface this round;
    /// this is a Windows-authored, compile-by-inspection-only string formatter, not risky logic, but
    /// flagged because the FEATURE it stands in for (real offset-aware reminders/blocking) is not
    /// yet built — see `backlog.md`.
    private static func taskDoneOffsetNoteLine(title: String, offsetMinutes: Double, atLeast: Bool) -> String {
        let duration = Self.formattedOffsetDuration(offsetMinutes)
        return atLeast
            ? "Sau khi xong '\(title)' ít nhất \(duration)"
            : "Sau khi xong '\(title)' + \(duration)"
    }

    /// Sibling of `taskDoneOffsetNoteLine` for the `taskStart` condition kind, which the client
    /// cannot represent AT ALL structurally (not even without the offset — there is no
    /// `ParsedCondition` case for "block on another task STARTING", only `.taskDone`'s "block until
    /// it's DONE") — this ALWAYS becomes a notes line, and the caller always emits zero conditions
    /// for it, never a best-effort `.taskDone` substitute (that would silently change the user's
    /// stated meaning, which is worse than clearly saying "not supported yet").
    ///
    /// // UNVERIFIED backlog: same "needs a real structural field" note as `taskDoneOffsetNoteLine`
    /// above — see `backlog.md`.
    private static func taskStartNoteLine(title: String, offsetMinutes: Double?, atLeast: Bool) -> String {
        guard let offsetMinutes, offsetMinutes.isFinite else {
            return "Trước khi làm '\(title)' — chưa hỗ trợ tự nhắc"
        }
        let duration = Self.formattedOffsetDuration(offsetMinutes)
        let lead = atLeast ? "ít nhất \(duration)" : duration
        return "Trước khi làm '\(title)' \(lead) — chưa hỗ trợ tự nhắc"
    }

    /// Shared by both note-line builders above. Sign-agnostic (`abs`) — `taskDone` offsets are
    /// always positive on the wire, `taskStart` offsets may be negative ("before the reference's
    /// start"), and the sign is already expressed in prose (`taskStartNoteLine`'s "Trước khi làm"),
    /// so the number itself is always rendered as a plain, non-negative duration. Whole hours render
    /// as `"2h"`; a non-multiple-of-60 duration over an hour renders as `"1h30p"`; anything under an
    /// hour renders as `"<n> phút"`.
    private static func formattedOffsetDuration(_ minutesValue: Double) -> String {
        let minutes = Int(abs(minutesValue).rounded())
        guard minutes > 0 else { return "0 phút" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 { return "\(hours)h" }
        if hours > 0 { return "\(hours)h\(remainder)p" }
        return "\(minutes) phút"
    }

    /// Appends `appendedLines` (the offset/`taskStart` notes lines collected while validating
    /// `conditions` above) to whatever the model already put in `notes` — one blank-line-free join,
    /// never silently overwriting the model's own notes text.
    private static func combinedNotes(base: String?, appendedLines: [String]) -> String? {
        guard !appendedLines.isEmpty else { return base }
        let appended = appendedLines.joined(separator: "\n")
        if let base, !base.isEmpty { return base + "\n" + appended }
        return appended
    }

    /// Mirrors `validate`'s per-attribute fallback philosophy for `TaskRefOut` -> `ParsedTaskRef`:
    /// trims `titleQuery`, drops an element whose title is empty after trimming (nothing left to
    /// search a task store by), clamps (never drops) confidence, and caps the result at
    /// `maxTaskRefs` — defense-in-depth re-check of the server's own `MAX_TASK_REFS`, same
    /// "never trust a remote response blindly" posture every other cap in this file already follows.
    static func validateTaskRefs(_ raws: [RawParsedTaskRef]) -> [ParsedTaskRef] {
        let mapped: [ParsedTaskRef] = raws.compactMap { raw in
            let trimmed = raw.titleQuery.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return ParsedTaskRef(
                titleQuery: trimmed,
                confidence: Self.clampedConfidence(raw.titleQuery.confidence),
                assumeExisting: raw.assumeExisting ?? false
            )
        }
        return Array(mapped.prefix(Self.maxTaskRefs))
    }

    /// Converts `RawParsedTaskUpdate` elements into validated `ParsedTaskUpdate`s.
    /// - Parameters:
    ///   - refCount: the ALREADY-VALIDATED `taskRefs.count` (post-trim/drop/cap) — every
    ///     `refIndex` is checked against THIS number, matching the server's own "`refIndex` ...
    ///     validated AFTER `taskRefs` truncation" rule (`TaskUpdateOut.refIndex`'s doc comment,
    ///     `_shared/schema.ts`), not the raw/pre-validation count.
    ///   - taskCount: the ALREADY-VALIDATED `tasks.count` for THIS SAME response — what
    ///     `addConditions`' `.taskDoneNewTask(index:)` is checked against (a different index space
    ///     from `refIndex`, see `RawUpdateCondition`'s own doc comment).
    static func validateTaskUpdates(
        _ raws: [RawParsedTaskUpdate], refCount: Int, taskCount: Int
    ) -> [ParsedTaskUpdate] {
        let mapped: [ParsedTaskUpdate] = raws.compactMap { raw in
            // FAIL-CLOSED: `Int(exactly:)` narrowing first (fractional/absent `refIndex` drops the
            // element — see `RawParsedTaskUpdate.refIndex`'s doc comment), then two plain
            // comparisons, not a `ClosedRange` (`1...refCount`) — with `refCount == 0` that range
            // literal TRAPS at construction, and a hostile/glitched response naming a `refIndex`
            // against an empty `taskRefs[]` must degrade to "drop this update," never crash the app
            // (same defensive pattern `CloudParser.resolveCompletion` already uses for its own
            // 1-based `matchIndex` bounds check).
            guard let rawRefIndex = raw.refIndex, rawRefIndex.isFinite,
                  let refIndex = Int(exactly: rawRefIndex),
                  refIndex >= 1, refIndex <= refCount else { return nil }

            let deadline: ParsedValue<Date>? = raw.set?.deadline.flatMap { c in
                guard validConfidence(c.confidence), let date = parseISO8601(c.value) else { return nil }
                return ParsedValue(value: date, confidence: c.confidence)
            }
            let startTime: ParsedValue<Date>? = raw.set?.startTime.flatMap { c in
                guard validConfidence(c.confidence), let date = parseISO8601(c.value) else { return nil }
                return ParsedValue(value: date, confidence: c.confidence)
            }
            let notesAppend: ParsedValue<String>? = raw.set?.notesAppend.flatMap { c in
                guard validConfidence(c.confidence) else { return nil }
                let trimmed = c.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.utf16.count <= Self.maxNotesAppendChars else { return nil }
                return ParsedValue(value: trimmed, confidence: c.confidence)
            }
            let priority: ParsedValue<Int>? = raw.set?.priority.flatMap { c in
                // `Int(exactly:)` WITHOUT `.rounded()` — same reasoning as `ParsedTask.priority`
                // right above: a fractional priority is a schema violation, never rounded into a
                // plausible-looking level on the user's behalf.
                guard validConfidence(c.confidence), c.value.isFinite,
                      let level = Int(exactly: c.value), (1...4).contains(level)
                else { return nil }
                return ParsedValue(value: level, confidence: c.confidence)
            }

            let addConditions: [ParsedUpdateCondition] = (raw.addConditions ?? []).compactMap { cond in
                switch cond.kind {
                case "taskDone":
                    // Same `Int(exactly:)` narrowing as `refIndex` above — fractional index is a
                    // schema violation, dropped, never rounded into a plausible-looking pointer.
                    guard let rawIndex = cond.newTaskIndex, rawIndex.isFinite,
                          let newTaskIndex = Int(exactly: rawIndex),
                          newTaskIndex >= 1, newTaskIndex <= taskCount else { return nil }
                    return .taskDoneNewTask(index: newTaskIndex)
                case "afterDate":
                    guard let dateString = cond.date, let date = parseISO8601(dateString) else { return nil }
                    return .afterDate(date)
                default:
                    return nil
                }
            }

            // An update with nothing left after per-field validation carries no information — drop
            // it entirely rather than surfacing an empty confirm chip with nothing to confirm.
            guard deadline != nil || startTime != nil || notesAppend != nil || priority != nil
                || !addConditions.isEmpty
            else { return nil }

            return ParsedTaskUpdate(
                refIndex: refIndex,
                deadline: deadline,
                startTime: startTime,
                notesAppend: notesAppend,
                priority: priority,
                addConditions: addConditions
            )
        }
        return Array(mapped.prefix(Self.maxUpdates))
    }

    /// Top-level envelope validator — the one entry point `CloudParser.performParse` calls on the
    /// envelope-shape (`RawParseEnvelope`) branch. `tasks` is capped to `IntentRouter.maxTaskCap`
    /// BEFORE validation, identical to the pre-existing bare-array path (`performParse`'s fallback
    /// branch) — one shared cap, applied the same way regardless of which wire shape answered, so
    /// `taskCount` below always means the same thing either way.
    static func validateCapture(
        _ envelope: RawParseEnvelope, sourceTranscript: String, now: Date = Date()
    ) -> ParsedCapture {
        let cappedRawTasks = Array(envelope.tasks.prefix(IntentRouter.maxTaskCap))
        let tasks = Self.validateAll(cappedRawTasks, sourceTranscript: sourceTranscript, now: now)
        let taskRefs = Self.validateTaskRefs(envelope.taskRefs ?? [])
        let updates = Self.validateTaskUpdates(
            envelope.updates ?? [], refCount: taskRefs.count, taskCount: tasks.count
        )
        return ParsedCapture(tasks: tasks, taskRefs: taskRefs, updates: updates)
    }
}
