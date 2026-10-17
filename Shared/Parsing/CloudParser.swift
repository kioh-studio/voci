// Sources/Parsing/CloudParser.swift — text-only cloud intent parsing client for
// `POST /functions/v1/parse` (contracts/parse-proxy.md). Mirrors the networking/credential-
// provider pattern of `Sources/Speech/GroqTranscriptionClient.swift` (struct, injected provider,
// `URLSession`, no hardcoded secrets) so this stays idiomatic to the codebase.
//
// The server side of this route is ALREADY IMPLEMENTED (`supabase/functions/parse/index.ts` +
// `_shared/{auth,schema,quota}.ts`, T004/T022) — this client is written to match that real,
// already-reviewed wire contract exactly (field names, status codes, auth header shapes), not
// just the prose in parse-proxy.md. See `supabase/README.md` for the curl-level ground truth.
//
// CONSTITUTION I (text-only, no audio egress): this file contains no audio type, no AVFoundation
// import, no multipart/binary upload — the only payload ever sent is a JSON object built from
// `String`/`Date`/`[String]`. Grep-verifiable: no `Data` audio buffer, no `AVAudio*` symbol
// anywhere below.
import Foundation

// MARK: - Credential provider (injected — mirrors GroqCredentialProvider)

/// The single auth shape for `/parse`: `Authorization: Bearer <supabase access_token>`. The server
/// looks up the tier by `user_id`, so the client never decides free vs Pro.
enum ParseAuthHeader: Sendable, Equatable {
    case bearer(String)
}

/// Supplies the parse-proxy base URL + per-request auth, injected so this file never hardcodes a
/// project URL or holds a secret directly — mirrors `GroqCredentialProvider`'s split of
/// `baseURL()`/`authorization()`. The concrete implementation is `ConfigParseCredentialProvider`
/// (account access token as `.bearer`).
///
/// ASSUMPTION for the reviewer to check against that work: `authHeader()` returning `nil` is the
/// ONLY signal `CloudParser` uses for "no credential available right now" — it must never throw
/// to report that state (this file only handles `baseURL()` throwing, for endpoint-resolution
/// failures, e.g. missing config).
protocol ParseCredentialProvider: Sendable {
    /// Base URL of the Supabase project (e.g. `https://<project-ref>.supabase.co`).
    /// `CloudParser` appends `functions/v1/parse`.
    func baseURL() async throws -> URL
    /// `nil` = no credential available right now (not opted in / no active entitlement / device
    /// attestation unavailable) — `CloudParser` treats this as "Cloud unavailable" and NEVER
    /// sends an unauthenticated request.
    func authHeader() async -> ParseAuthHeader?
}

// MARK: - Outcome (non-protocol — lets IntentRouter distinguish quota from any other failure)

/// `CloudParser`'s own richer result, consumed by `IntentRouter.parse` directly (NOT part of the
/// frozen `IntentParser` protocol, whose `parse` returns plain `[ParsedTask]`). This is how the
/// 429 "gentle note" (FR-012) signal reaches the router without changing the frozen return type.
enum CloudParseOutcome: Sendable, Equatable {
    case tasks([ParsedTask])
    /// 429 `{ error, resetAt }`. `resetAt` is best-effort (nil if absent/malformed).
    case quotaExceeded(resetAt: Date?)
    /// Any other non-200 (401 invalid/expired auth, 403, 4xx, 5xx, `config_missing` 503,
    /// `upstream_error` 502), transport failure (offline/DNS/TLS/timeout), or a response that
    /// failed decode/size validation. The router falls through silently — never a user-visible
    /// error beyond the quota note.
    case unavailable
}

// MARK: - CloudParser (T021)

/// Pure network + decode layer for the `/functions/v1/parse` route. No app state, no UI —
/// unit-testable by injecting a `URLSession` (mirrors `GroqTranscriptionClient`). Never retries
/// (contract: one round trip per parse; a 5xx here just means "fall through to Heuristic now",
/// not "retry the network").
struct CloudParser: Sendable {
    let credentials: ParseCredentialProvider
    var session: URLSession = .shared
    /// Contract: "text, ≤2000 chars". Truncated client-side before sending — never rejected
    /// outright, since a truncated transcript is still better than discarding the utterance.
    var maxTranscriptChars = 2000
    /// Sanity cap on the RESPONSE body before attempting to decode it — bounds memory/CPU spent
    /// decoding a hostile or corrupted (e.g. MITM-tampered, or a buggy future server change)
    /// response BEFORE `JSONDecoder` ever runs, independent of the 10-task cap applied after
    /// decode. 10 tasks at the contract's own per-field caps (300-char titles, 1000-char notes,
    /// etc.) comfortably fit well under this.
    var maxResponseBytes = 256 * 1024
    var timeout: TimeInterval = 20
    /// Client-side truncation cap for the OPTIONAL `sourceTranscript` context field (anh Khôi,
    /// 2026-07-29 "richer context" addendum) — mirrors the server's own `MAX_CONTEXT_TRANSCRIPT_CHARS`
    /// (`_shared/schema.ts`) so truncation happens (cheaply, and before the request ever leaves the
    /// device) on this side too, not just server-side — same "client truncates too, belt-and-
    /// suspenders" convention `maxTranscriptChars` already establishes for the primary `transcript`
    /// field in `parseDetailed` above.
    var maxContextTranscriptChars = 1000
    /// Mirrors the server's own `MAX_EXISTING_SUBTASKS` (`_shared/schema.ts`) — same number, so
    /// client and server never silently disagree about "how many subtasks are worth telling the
    /// model about."
    var maxExistingSubtasks = 20
    /// Fresh instance per call, deliberately not a shared `static let`: `ISO8601DateFormatter` is
    /// a mutable reference type Foundation has not audited/marked `Sendable`, and this struct's
    /// methods run off the main actor — sharing one instance across concurrent calls would be a
    /// Swift 6 strict-concurrency risk (and a real, if unlikely, data race) for a cost that's
    /// negligible next to the network round trip itself.
    ///
    /// Emits the caller's OWN local wall-clock time with its REAL UTC offset (e.g.
    /// `2026-07-28T15:00:00+07:00` for a user in Vietnam) — deliberately NOT `Z`/UTC. This is
    /// intentional, not an oversight: the server prompt asks the model to resolve relative phrases
    /// like "sáng nay"/"chiều nay" ("this morning"/"this afternoon") against the caller's actual
    /// wall clock, so `now` must actually BE that wall clock, offset and all — sending UTC would
    /// make every such phrase resolve against the wrong clock. `timeZone` defaults to `.current`,
    /// re-read fresh on EVERY call (never cached in a stored property) — a user who changes
    /// timezone (e.g. mid-flight) gets the correct offset on their very next request. The
    /// parameter exists so tests can inject a fixed zone instead of depending on whatever timezone
    /// happens to be set on the machine running the test suite.
    ///
    /// BUG THIS FIXES: `ISO8601DateFormatter()`'s own default `timeZone` is GMT, so the previous
    /// code here silently RE-STAMPED local time as if it were UTC — a user at 15:00 local
    /// (UTC+7) sent `...T08:00:00Z` (their own clock digits, wrongly labeled `Z`), the server then
    /// resolved "this afternoon" against that mislabeled instant, and the client decoded the
    /// resulting deadline exactly 7 hours off from what the user meant. Explicitly setting
    /// `timeZone = .current` (or the injected zone) is the fix.
    ///
    /// `formatOptions = [.withInternetDateTime]` is required, not just conventional: the server
    /// rejects any `now` that fails `isIso8601WithZone` (`_shared/schema.ts`) —
    /// `/(Z|[+-]\d{2}:\d{2})$/` — which requires the UTC offset to include the colon (`+07:00`,
    /// NOT `+0700`). `.withInternetDateTime` includes `.withColonSeparatorInTimeZone`, so this is
    /// already satisfied, but `formatOptions` is set explicitly (rather than left at
    /// `ISO8601DateFormatter`'s own default, which happens to match today) so a future edit can
    /// never silently drop the colon by "simplifying" this line — that would 400 every
    /// parse/resolve_completion request server-side.
    ///
    /// Not `private`: exposed at `internal` (package-default) visibility so `CloudParserTests` can
    /// call it directly via `@testable import Volar` — mirrors the precedent
    /// `CloudCompletionResolutionTests.swift` already documents for pulling `AppState
    /// .resolveCloudMatch` out to a testable `static` function rather than leaving pure logic
    /// trapped behind a live network/UI call.
    static func makeRequestFormatter(timeZone: TimeZone = .current) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter
    }

    /// Defensive gate on the new `timezone` wire field (parse mode only — see `parseDetailed`
    /// below). The server interpolates this value directly into the model prompt (a parallel,
    /// not-yet-landed piece of server work as of this writing) — an unvalidated string here would
    /// be a real prompt-injection surface, not defense-in-depth theater, so this mirrors the
    /// server's OWN locked validation rule for this field rather than trusting
    /// `TimeZone.current.identifier` to always be well-formed: 1...64 characters, matching
    /// `^[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+){0,2}$` (letters/digits/`_`/`+`/`-`, 1-3 `/`-separated
    /// segments — covers real IANA ids like `Asia/Ho_Chi_Minh`, `UTC`,
    /// `America/Argentina/Buenos_Aires`). Returns `nil` (never a best-effort sanitized/truncated
    /// string) on any mismatch — the caller then OMITS the `timezone` field entirely rather than
    /// risk sending something the server would 400 on, which would otherwise kill the ENTIRE parse
    /// request over a field that's only ever a hint.
    ///
    /// Not `private`, same testability rationale as `makeRequestFormatter` above.
    static func validatedTimezoneField(_ identifier: String) -> String? {
        guard (1...64).contains(identifier.utf16.count) else { return nil }
        guard identifier.range(
            of: "^[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+){0,2}$", options: .regularExpression
        ) != nil else {
            return nil
        }
        return identifier
    }

    /// Truncates by UTF-16 code units — matching the server's validation (`_shared/schema.ts`
    /// checks JS string `.length`, which counts UTF-16 units, not Unicode scalars or grapheme
    /// clusters). Swift's `String.prefix(_:)`/`.count` count `Character`s (extended grapheme
    /// clusters): a single emoji (optionally with skin-tone/ZWJ modifiers) is ONE `Character` but
    /// can be MANY UTF-16 units, so emoji-heavy input could pass this client's old `Character`-
    /// count cap while still exceeding the server's UTF-16-based cap — the server then 400s and
    /// `IntentRouter` silently falls back to Heuristic, degrading quality for no visible reason.
    /// Walks `Character`-by-`Character`, accumulating UTF-16 width, and stops BEFORE the running
    /// total would exceed `maxUnits` — this never splits a grapheme cluster (unlike truncating the
    /// raw UTF-16 view directly, which could cut a surrogate pair or a ZWJ sequence in half and
    /// produce a different, possibly invalid, string). O(n) in the string's `Character` count.
    private static func utf16Prefix(_ s: String, _ maxUnits: Int) -> String {
        guard maxUnits > 0 else { return "" }
        var result = String()
        var used = 0
        for ch in s {
            let width = String(ch).utf16.count
            guard used + width <= maxUnits else { break }
            result.append(ch)
            used += width
        }
        return result
    }

    /// Shared context-payload builder (anh Khôi, 2026-07-29 "richer context" addendum) — appends
    /// `source_transcript`/`deadline`/`existing_subtasks` to an in-progress request `payload` IN
    /// PLACE, dùng bởi `breakdownDetailed` (trước đây còn hai chế độ "stuck" nữa, đã bỏ 2026-08-22). An instance method (not `static`, unlike `utf16Prefix` above) purely
    /// so it can read `self.maxContextTranscriptChars`/`self.maxExistingSubtasks`.
    ///
    /// `sourceTranscript` is UNTRUSTED input (the user's own speech, captured verbatim at
    /// task-creation time) — exactly like `notes`/`title` on every call site already, it is added
    /// here as a plain JSON DATA field on the SAME envelope, never concatenated into any kind of
    /// instruction string (that discipline is entirely server-side, in `gemini.ts`'s
    /// `build*Contents` — this file only ever builds an inert `[String: Any]` dictionary that
    /// becomes a JSON body, so there is no "prompt" for it to be smuggled into on this side at
    /// all). `deadline` is formatted via `Self.makeRequestFormatter()` — the SAME formatter/offset
    /// convention `now` already uses elsewhere in this file (local wall-clock time with its real
    /// UTC offset, never `Z`/UTC — see that function's own doc comment for why silently mislabeling
    /// local time as UTC would shift every downstream date reasoning the server does).
    private func appendContext(
        to payload: inout [String: Any],
        sourceTranscript: String?,
        deadline: Date?,
        existingSubtasks: [TaskContextSubtask]?
    ) {
        if let sourceTranscript {
            let trimmed = Self.utf16Prefix(sourceTranscript, maxContextTranscriptChars)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                payload["source_transcript"] = trimmed
            }
        }
        if let deadline {
            payload["deadline"] = Self.makeRequestFormatter().string(from: deadline)
        }
        if let existingSubtasks, !existingSubtasks.isEmpty {
            payload["existing_subtasks"] = Array(existingSubtasks.prefix(maxExistingSubtasks)).map {
                ["title": Self.utf16Prefix($0.title, 300), "done": $0.done]
            }
        }
    }

    // MARK: Parse mode

    /// Wire capability the client advertises via `"client_caps": ["task_refs_v1"]` on every parse
    /// request (anh Khôi, 2026-08-02 task-refs design; server side: `_shared/schema.ts`'s
    /// `ParseRequest.clientCaps`, `MAX_TASK_REFS`/`MAX_UPDATES`). Additive, two-way handshake —
    /// NOT a version number (App Store clients fragment across versions while this Edge Function
    /// redeploys freely; see `ParseRequest.clientCaps`'s own doc comment server-side for the same
    /// reasoning spelled out in full): a server that does NOT yet recognize this string (not
    /// redeployed yet, or a rollback) ignores the field entirely and returns today's bare
    /// `[RawParsedTask]` array; a server that DOES recognize it returns the richer envelope object
    /// `{ tasks, taskRefs, updates }` instead (`RawParseEnvelope`, `IntentParsing.swift`). BOTH
    /// response shapes MUST decode without throwing — see `performParse`'s `200` branch below,
    /// which tries the envelope shape first and falls back to the bare array, so an utterance is
    /// never lost to a decode failure regardless of which server version answers.
    static let taskRefsCapability = "task_refs_v1"

    /// Wire capability for `cue` (implementation-intention surfacing, `specs/006-cues-and-waiting/
    /// design.md`) — sent ALONGSIDE `taskRefsCapability` in `"client_caps"`, never replacing it
    /// (both are independent, additive handshakes; a server can recognize either, both, or
    /// neither). Same additive-handshake contract as `taskRefsCapability` documents in full above:
    /// a server that doesn't yet recognize this string (not redeployed, or a rollback) simply
    /// never populates `cue` on its response, which decodes as `nil` here either way — see
    /// `RawParsedTask.cue`'s own doc comment for the back-compat mechanics this depends on.
    static let cuesCapability = "task_cues_v1"

    /// task_refs_v1: the full-`ParsedCapture` sibling of `CloudParseOutcome` — identical
    /// quota/unavailable semantics, but the success case carries the full validated `ParsedCapture`
    /// (tasks + taskRefs + updates) instead of just `[ParsedTask]`. A SEPARATE type from
    /// `CloudParseOutcome` (never a payload-type change to that one) so `parseDetailed`'s existing
    /// `[ParsedTask]`-only contract — and every call site that already depends on it — never has to
    /// change shape; see `performParse` below for the one shared network/decode path both
    /// `parseDetailed` and `parseCaptureDetailed` delegate to (never two network round trips for
    /// what is, on the wire, one request).
    enum CloudParseCaptureOutcome: Sendable, Equatable {
        case capture(ParsedCapture)
        /// Identical meaning to `CloudParseOutcome.quotaExceeded`.
        case quotaExceeded(resetAt: Date?)
        /// Identical meaning to `CloudParseOutcome.unavailable`.
        case unavailable
    }

    func parseDetailed(_ transcript: String, now: Date, openTaskTitles: [String]) async -> CloudParseOutcome {
        switch await performParse(transcript, now: now, openTaskTitles: openTaskTitles) {
        case .capture(let capture):
            return .tasks(capture.tasks)
        case .quotaExceeded(let resetAt):
            return .quotaExceeded(resetAt: resetAt)
        case .unavailable:
            return .unavailable
        }
    }

    /// task_refs_v1 sibling of `parseDetailed` above — same network call (via the shared
    /// `performParse` below), but returns the FULL `ParsedCapture` (`taskRefs`/`updates` included)
    /// instead of discarding them down to `[ParsedTask]`. The one real call site is
    /// `IntentRouter.parseCapture` (`IntentParsing.swift`).
    func parseCaptureDetailed(
        _ transcript: String, now: Date, openTaskTitles: [String]
    ) async -> CloudParseCaptureOutcome {
        await performParse(transcript, now: now, openTaskTitles: openTaskTitles)
    }

    /// Shared network + decode path for `parseDetailed`/`parseCaptureDetailed` (anh Khôi, 2026-08-02
    /// task-refs design: factored out of what used to be `parseDetailed`'s own body, verbatim, so a
    /// second public-facing shape could be added without a second round trip). Every pre-existing
    /// behavior this refactor must NOT disturb: the consent/credential gate, the `timezone`/
    /// `open_task_titles` payload fields, the 429 quota/`resetAt` handling, the `maxResponseBytes`
    /// pre-decode size gate, and the 2026-08-01 "`200 []` is a well-formed answer, not
    /// `.unavailable`" fix (see the inline comment at the `200` case below — unchanged, just now
    /// reached via an empty `ParsedCapture` instead of an empty `[ParsedTask]` directly).
    private func performParse(
        _ transcript: String, now: Date, openTaskTitles: [String]
    ) async -> CloudParseCaptureOutcome {
        let trimmed = Self.utf16Prefix(transcript, maxTranscriptChars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unavailable }

        guard let base = try? await credentials.baseURL(),
              let header = await credentials.authHeader() else {
            // No consent / no entitlement / no device token available — never send an
            // unauthenticated request (the server would 401 it anyway, but we shouldn't even try:
            // that would count as a network attempt while "offline"/"not opted in" from the
            // user's perspective, and could leak the transcript to the wire before auth fails).
            return .unavailable
        }

        var payload: [String: Any] = [
            "transcript": trimmed,
            "now": Self.makeRequestFormatter().string(from: now),
            // task_refs_v1 (anh Khôi, 2026-08-02) + task_cues_v1 (006-cues-and-waiting, 2026-08-08):
            // both advertised on EVERY parse request, unconditionally, side by side — see
            // `taskRefsCapability`'s own doc comment for the additive-handshake contract this
            // relies on (a server that doesn't recognize a given string yet, or has been rolled
            // back, simply ignores THAT field and answers exactly as before; the two caps are
            // independent, neither gates the other).
            "client_caps": [Self.taskRefsCapability, Self.cuesCapability],
        ]
        if !openTaskTitles.isEmpty {
            payload["open_task_titles"] = Array(openTaskTitles.prefix(100)).map { Self.utf16Prefix($0, 200) }.filter { !$0.isEmpty }
        }
        // `timezone`: parse mode ONLY (locked contract — `resolveCompletion` below deliberately
        // does NOT send this; the server only reads it in parse mode). IANA identifier, gated
        // through `validatedTimezoneField` — omit the field entirely rather than send a malformed
        // value and risk a 400 on the whole request over what is only ever a hint.
        if let timezone = Self.validatedTimezoneField(TimeZone.current.identifier) {
            payload["timezone"] = timezone
        }

        guard let request = Self.makeRequest(base: base, header: header, timeout: timeout, jsonPayload: payload) else {
            return .unavailable
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Transport failure (offline/DNS/TLS/timeout) — silent fall-through, no user-visible
            // error. Deliberately not logging `error.localizedDescription`: it can echo request
            // details on some platforms, and this route's privacy contract is "no transcript
            // logging" — err on the side of logging nothing here rather than auditing every OS's
            // error string for leakage.
            return .unavailable
        }
        guard let http = response as? HTTPURLResponse else { return .unavailable }

        switch http.statusCode {
        case 200:
            guard data.count <= maxResponseBytes else { return .unavailable }
            // 2026-08-01: an EMPTY array is no longer folded into `.unavailable`. `200 []` is a
            // well-formed, deliberate server answer — "the model read the utterance and found no
            // actionable task in it" (small talk) — and `supabase/functions/_shared/schema.ts`'s
            // `validateParsedTaskArray` documents it as such explicitly, returning `200 []` rather
            // than a 502 on purpose. Reporting it as `.unavailable` claimed the Cloud tier had
            // FAILED when it had actually succeeded: `IntentRouter.lastRoute` recorded the wrong
            // tier, and the router's `.cloud` empty branch was unreachable dead code.
            //
            // What the user sees is UNCHANGED (anh Khôi chốt 2026-08-01): the router still falls
            // through to its title-only floor either way, so an utterance never silently vanishes —
            // only the diagnosis of WHY it fell through is now honest.
            //
            // task_refs_v1 (anh Khôi, 2026-08-02): the ENVELOPE shape is tried FIRST. A server that
            // doesn't recognize `client_caps` (not yet redeployed, or a rollback) ignores that field
            // and returns the OLD bare `[RawParsedTask]` array — decoding THAT as `RawParseEnvelope`
            // fails outright (a top-level JSON array can never satisfy an object-keyed container),
            // so this always falls through cleanly to the bare-array branch below on an old server,
            // never silently misreads array elements as envelope fields. Both branches must decode
            // without throwing — this is the one thing standing between a server-version mismatch
            // and losing the user's utterance entirely.
            if let envelope = try? JSONDecoder().decode(RawParseEnvelope.self, from: data) {
                // `now: now` (task_cues_v1): the SAME instant this request declared as its own
                // wall clock — see `ParsedTaskValidation.validate`'s `now:` doc comment for why
                // this, not a fresh `Date()` read at decode time, is what stamps a decoded cue's
                // `TaskCue.createdAt`.
                let capture = ParsedTaskValidation.validateCapture(envelope, sourceTranscript: transcript, now: now)
                return .capture(capture)
            }
            guard let raws = try? JSONDecoder().decode([RawParsedTask].self, from: data) else {
                return .unavailable
            }
            let capped = Array(raws.prefix(IntentRouter.maxTaskCap))
            let validated = ParsedTaskValidation.validateAll(capped, sourceTranscript: transcript, now: now)
            return .capture(ParsedCapture(tasks: validated, taskRefs: [], updates: []))
        case 429:
            let quota = try? JSONDecoder().decode(QuotaResponse.self, from: data)
            let resetAt = quota?.resetAt.flatMap { ParsedTaskValidation.parseISO8601($0) }
            return .quotaExceeded(resetAt: resetAt)
        default:
            // 401 (invalid/expired auth -> fallback, prompt re-validation in Settings elsewhere),
            // 403, 5xx (`upstream_error`/`config_missing`/`internal_error`), or any other 4xx —
            // all fall through the same way per contract ("401 -> fallback"; "5xx -> fallback").
            return .unavailable
        }
    }

    // MARK: Breakdown mode (same route, `mode: "breakdown"`)

    /// `sourceTranscript`/`deadline`/`existingSubtasks` (anh Khôi, 2026-07-29 "richer context"
    /// addendum) are OPTIONAL, defaulting to `nil` so every pre-addendum call site keeps compiling
    /// and behaving exactly as before — see `appendContext(to:sourceTranscript:deadline:
    /// existingSubtasks:)` for how they're added to the wire payload.
    func breakdownDetailed(
        title: String,
        notes: String?,
        sourceTranscript: String? = nil,
        deadline: Date? = nil,
        existingSubtasks: [TaskContextSubtask]? = nil
    ) async -> [String]? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        guard let base = try? await credentials.baseURL(),
              let header = await credentials.authHeader() else { return nil }

        var payload: [String: Any] = [
            "mode": "breakdown",
            "task_title": Self.utf16Prefix(trimmedTitle, 300),
        ]
        if let notes, !notes.isEmpty {
            payload["notes"] = Self.utf16Prefix(notes, 1000)
        }
        appendContext(
            to: &payload, sourceTranscript: sourceTranscript, deadline: deadline, existingSubtasks: existingSubtasks
        )

        guard let request = Self.makeRequest(base: base, header: header, timeout: timeout, jsonPayload: payload) else {
            return nil
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return nil
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard data.count <= maxResponseBytes else { return nil }
        guard let decoded = try? JSONDecoder().decode(BreakdownResponse.self, from: data) else { return nil }

        let steps = decoded.steps
            .map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Re-check the contract's own bound (3...9) client-side too, even though the server
        // already enforces it (`_shared/schema.ts`) — never trust a remote response blindly.
        guard (3...9).contains(steps.count) else { return nil }
        return steps
    }

    // MARK: - Resolve-completion mode (T0xx: cloud paraphrase rescue for `VoiceDone`'s
    // empty-candidate case — see `Sources/App/AppState.swift`'s `resolveCompletionViaCloud`).
    //
    // WHY this exists: `VoiceDone.classify` (Sources/Speech/VoiceDone.swift) matches a completion
    // utterance against open-task titles with on-device Jaccard token-set overlap. A paraphrase
    // ("xong cái vụ report rồi" vs. the real title "Viết báo cáo Q3") shares no tokens and scores
    // 0.0 — `VoiceDone` correctly reports "phrase present, nothing matched" (empty candidates), and
    // THIS is the one place that empty-candidates outcome gets a second, semantic-match attempt
    // before the app gives up and tells the user "no matching task."
    //
    // LOCKED wire contract (`mode: "resolve_completion"`, a new mode alongside parse/breakdown on
    // the same `/functions/v1/parse` route — a parallel agent implements the server half against
    // this identical contract, so the field names/shapes below are NOT open to renegotiation):
    //   Request:  { mode, transcript, now, kind: "complete"|"clear_external", candidates: [String] }
    //   Response: { intent: "complete"|"clear_external"|"none", matchIndex?: Int (1-BASED),
    //               matchTitle?: String, confidence: Double (0...1) }
    // `matchIndex` is 1-BASED: `candidates[matchIndex - 1]` is the chosen title. Every touch point
    // below comments this loudly — getting it wrong marks the WRONG task done.

    /// Wire `kind` for `resolve_completion` — mirrors `VoiceDoneAction`'s two actionable cases
    /// (`AppState.swift`) at the transport boundary. Kept as its own type here rather than reusing
    /// `VoiceDoneAction` directly so this file never depends on `VoiceDone.swift`'s frozen seam
    /// (same separation `CloudParser` already keeps from `ParsedTask`'s owning module elsewhere).
    enum CompletionKind: Sendable, Equatable {
        case complete
        case clearExternal

        /// The exact wire literal the locked contract specifies.
        fileprivate var wireValue: String {
            switch self {
            case .complete: return "complete"
            case .clearExternal: return "clear_external"
            }
        }
    }

    /// `resolveCompletion`'s result. Deliberately keeps `.none` ("the model looked at the
    /// candidates and confidently reported no match, or the 200 response failed a defensive
    /// validation check") distinct from `.unavailable` ("we never got a trustworthy answer at all:
    /// no consent/credential, offline, timeout, non-200, oversized body, or undecodable JSON").
    /// Both collapse to the SAME caller behavior today (`AppState` presents "no matching task"
    /// either way — see `resolveCompletionViaCloud`), but conflating them here would destroy
    /// information a future retry-only-on-`.none` or telemetry-only-on-`.unavailable` decision
    /// would need, per this task's own instruction not to blur that distinction in the transport
    /// layer.
    enum CompletionResolution: Sendable, Equatable {
        /// `index` is 1-BASED into the `candidates` array THIS CALL was given (already re-checked
        /// against `1...candidates.count` below before this case is ever produced) —
        /// `candidates[index - 1]` is `title`, echoed verbatim (trimmed) from the wire response.
        /// The caller (`IntentRouter.resolveCompletion` / `AppState.resolveCompletionViaCloud`) is
        /// still responsible for re-validating `index`/`title` against ITS OWN local snapshot
        /// before acting — this case only guarantees the WIRE-LEVEL checks below already passed,
        /// not that the caller's candidate list is still the same one that was sent (constitution
        /// II: never trust a remote response transitively).
        case resolved(index: Int, title: String, confidence: Double)
        /// Well-formed 200 with `intent == "none"`, OR a 200 that failed one of the defensive
        /// checks below (unrecognized `intent`, non-finite/out-of-range `confidence`,
        /// missing/non-integer/out-of-range `matchIndex`, missing/empty `matchTitle`) — the server
        /// DID answer, so this is "found nothing," never a transport failure.
        case none
        /// No trustworthy answer: no consent/credential available (`ParseCredentialProvider` gate),
        /// transport failure (offline/DNS/TLS/timeout), non-200 status, oversized body, or a
        /// response that failed to decode at all.
        case unavailable
    }

    private struct ResolveCompletionResponse: Decodable {
        var intent: String
        var matchIndex: Int?
        var matchTitle: String?
        var confidence: Double
    }

    /// Cloud-only semantic-match attempt for a completion/clear-external utterance that `VoiceDone`
    /// already tried and failed to match locally. Reuses `parseDetailed`'s exact machinery: the
    /// same credential/consent guard (never sends anything without a resolved `baseURL`/auth
    /// header), the same `makeRequest`/timeout/formatter helpers, the same `utf16Prefix`
    /// truncation, and the same 100-entry cap on the candidate-titles list `parseDetailed` applies
    /// to `open_task_titles`.
    func resolveCompletion(
        _ transcript: String, now: Date, kind: CompletionKind, candidates: [String]
    ) async -> CompletionResolution {
        let trimmed = Self.utf16Prefix(transcript, maxTranscriptChars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unavailable }

        guard let base = try? await credentials.baseURL(),
              let header = await credentials.authHeader() else {
            // Identical consent/entitlement/credential gate as `parseDetailed` (same doc comment
            // applies verbatim): never send an unauthenticated request, not even the candidate
            // titles, when there is no consent/entitlement/token available right now.
            return .unavailable
        }

        // Same defensive cap + per-title truncation `parseDetailed` applies to `open_task_titles`
        // — this wire field is the same shape (a list of open-task titles), just under the locked
        // `candidates` name for this mode. `boundedCandidates.count` is what `matchIndex` gets
        // validated against below, so this MUST be the exact list actually sent on the wire.
        let boundedCandidates = Array(candidates.prefix(100)).map { Self.utf16Prefix($0, 200) }.filter { !$0.isEmpty }

        let payload: [String: Any] = [
            "mode": "resolve_completion",
            "transcript": trimmed,
            "now": Self.makeRequestFormatter().string(from: now),
            "kind": kind.wireValue,
            "candidates": boundedCandidates,
        ]

        guard let request = Self.makeRequest(base: base, header: header, timeout: timeout, jsonPayload: payload) else {
            return .unavailable
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Transport failure — silent fall-through, no logging (same privacy rationale as
            // `parseDetailed`'s identical catch block: never log error strings that could echo
            // request details on some platforms).
            return .unavailable
        }
        guard let http = response as? HTTPURLResponse else { return .unavailable }
        guard http.statusCode == 200 else {
            // Follows `parseDetailed`'s existing degrade convention: every non-200 (401 invalid/
            // expired auth, 403, 429, 5xx) falls through to unavailable. This mode's result shape
            // has no quota-note case (unlike `CloudParseOutcome.quotaExceeded`) — a 429 here is
            // just "not available right now," not a distinct signal the caller acts on.
            return .unavailable
        }
        guard data.count <= maxResponseBytes else { return .unavailable }
        guard let decoded = try? JSONDecoder().decode(ResolveCompletionResponse.self, from: data) else {
            return .unavailable
        }

        // TRUST BOUNDARY — this decides which of the user's tasks gets completed. Every violation
        // below maps to `.none`, never to a patched-up/defaulted `.resolved`.
        switch decoded.intent {
        case "complete", "clear_external":
            break
        case "none":
            return .none
        default:
            // Unrecognized literal — schema drift or a hostile/corrupted response. Never guess.
            return .none
        }

        guard decoded.confidence.isFinite, (0...1).contains(decoded.confidence) else { return .none }

        // `matchIndex` is 1-BASED (locked contract) — bounds-checked against `boundedCandidates`,
        // the EXACT list this call sent, so `candidates[matchIndex - 1]` (whenever a caller does
        // that arithmetic) is always in range for THIS response.
        // Two plain comparisons, not `(1...boundedCandidates.count).contains(matchIndex)`: an
        // empty `boundedCandidates` (caller passed no candidates at all) makes `1...0` an invalid
        // `ClosedRange` that TRAPS at construction, before `.contains` ever runs — a hostile/buggy
        // server response with a non-nil `matchIndex` on a zero-candidate request must degrade to
        // `.none`, never crash the app.
        guard let matchIndex = decoded.matchIndex,
              matchIndex >= 1, matchIndex <= boundedCandidates.count else { return .none }

        guard let matchTitle = decoded.matchTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !matchTitle.isEmpty else { return .none }

        return .resolved(index: matchIndex, title: matchTitle, confidence: decoded.confidence)
    }

    // MARK: - Shared request builder

    private static func makeRequest(
        base: URL, header: ParseAuthHeader, timeout: TimeInterval, jsonPayload: [String: Any]
    ) -> URLRequest? {
        guard let body = try? JSONSerialization.data(withJSONObject: jsonPayload) else { return nil }
        // TLS is whatever `base` specifies — this file never downgrades to `http://` and never
        // installs a custom `URLSessionDelegate` that would bypass certificate validation
        // (default `URLSession.shared`/system trust store is used as-is).
        let url = base.appendingPathComponent("functions/v1/parse")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch header {
        case .bearer(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // Text-only body: `jsonPayload` is built exclusively from `String`/`Date`-derived values
        // above (transcript, ISO8601 timestamp, titles, task_title, notes) — there is no audio
        // parameter anywhere in this file, no multipart body, no binary upload (constitution I).
        request.httpBody = body
        return request
    }

    private struct QuotaResponse: Decodable {
        var error: String?
        var resetAt: String?
    }

    private struct BreakdownResponse: Decodable {
        struct Step: Decodable {
            var title: String
            var estimateMinutes: Double
        }
        var steps: [Step]
    }
}

// MARK: - IntentParser conformance (frozen protocol surface)

extension CloudParser: IntentParser {
    func parse(_ transcript: String, now: Date, openTaskTitles: [String]) async -> [ParsedTask] {
        if case .tasks(let tasks) = await parseDetailed(transcript, now: now, openTaskTitles: openTaskTitles) {
            return tasks
        }
        return []
    }

    func breakdown(title: String, notes: String?) async -> [String] {
        await breakdownDetailed(title: title, notes: notes) ?? []
    }
}
