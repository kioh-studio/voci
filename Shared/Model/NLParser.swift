// Sources/Model/NLParser.swift — on-device NL parsing: ParsedTask v2, ParsedValue, ParsedCondition,
// NLParser, HeuristicNLParser (specs/002-workflow-command-center/contracts/parsing-contract.md).
//
// OWNERSHIP (Phase 3, feature 002): this file owns `ParsedTask`/`ParsedValue`/`ParsedCondition` —
// the frozen seam other Phase-3 agents (Parsing router, AppState/PopoverView) code against. Do not
// redefine `Recurrence`/`ReminderPolicy`/`TaskKind` here (see `Recurrence.swift`, agent-B Phase-2).
//
// // UNVERIFIED: this file caches several `NSRegularExpression`/`NSDataDetector` instances in
// `static let`s for reuse across calls (perf — regex compilation is the expensive part, not
// matching). Recent Foundation overlays mark these classes `Sendable` (they're immutable after
// init), which should satisfy Swift 6 strict concurrency for a `struct`'s static lets, but this
// needs the real Xcode/Swift 6 toolchain on Mac to confirm no "static property is not
// concurrency-safe" diagnostic — cannot verify on Windows.
import Foundation

// MARK: - ParsedValue<T>

/// Wraps a parsed attribute with its model confidence so the UI can gate it. Conditional
/// `Codable` conformance below (only when `T: Codable`) — needed because `ParsedTask` itself must
/// be `Codable` (constitution II: raw LLM/cloud output decodes into this validated type; a
/// decode/schema violation anywhere falls back to a title-only task, never a crash).
struct ParsedValue<T: Sendable & Equatable>: Sendable, Equatable {
    var value: T
    var confidence: Double // 0…1
    var isUncertain: Bool { confidence < 0.7 } // <0.7 → dashed "uncertain" chip; never auto-committed
}

extension ParsedValue: Codable where T: Codable {}

// MARK: - ParsedCondition

/// A parsed blocking condition BEFORE resolution to `VolarCore.Condition`. `taskDone` references a
/// task by fuzzy title (resolved to a UUID via picker at confirm time, NEVER auto-attached below
/// 0.7 confidence — constitution II).
enum ParsedCondition: Sendable, Equatable {
    case taskDone(titleQuery: String, confidence: Double)
    case afterDate(Date, confidence: Double)
    case external(description: String, confidence: Double)
}

extension ParsedCondition: Codable {
    /// Hand-rolled (same convention as `VolarTask.ConditionDTO` / `Recurrence`'s Codable) so the
    /// wire shape is explicit and a single malformed case fails decode with a clear error rather
    /// than relying on synthesized enum-with-associated-values Codable behavior.
    private enum Kind: String, Codable { case taskDone, afterDate, external }
    private struct Wire: Codable {
        var kind: Kind
        var titleQuery: String?
        var date: Date?
        var description: String?
        var confidence: Double
    }

    init(from decoder: Decoder) throws {
        let wire = try Wire(from: decoder)
        switch wire.kind {
        case .taskDone:
            guard let titleQuery = wire.titleQuery else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "ParsedCondition.taskDone is missing its `titleQuery` payload"
                )
            }
            self = .taskDone(titleQuery: titleQuery, confidence: wire.confidence)
        case .afterDate:
            guard let date = wire.date else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "ParsedCondition.afterDate is missing its `date` payload"
                )
            }
            self = .afterDate(date, confidence: wire.confidence)
        case .external:
            guard let description = wire.description else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "ParsedCondition.external is missing its `description` payload"
                )
            }
            self = .external(description: description, confidence: wire.confidence)
        }
    }

    func encode(to encoder: Encoder) throws {
        let wire: Wire
        switch self {
        case .taskDone(let titleQuery, let confidence):
            wire = Wire(kind: .taskDone, titleQuery: titleQuery, date: nil, description: nil, confidence: confidence)
        case .afterDate(let date, let confidence):
            wire = Wire(kind: .afterDate, titleQuery: nil, date: date, description: nil, confidence: confidence)
        case .external(let description, let confidence):
            wire = Wire(kind: .external, titleQuery: nil, date: nil, description: description, confidence: confidence)
        }
        try wire.encode(to: encoder)
    }
}

// MARK: - ParsedTask (v2)

/// The validated value the confirm card renders and `confirmSave` materializes. Assistive, never
/// authoritative (constitution II). Replaces the v1 `ParsedTask` (title/details/when/priority/
/// durationMinutes/context) — every v1 call site (`AppState`, `PopoverView`, `SampleData`) needs
/// updating by its owning agent; see this feature's final report for the full break list.
struct ParsedTask: Sendable, Equatable {
    var title: String // required; only guaranteed field
    var notes: String?
    var deadline: ParsedValue<Date>? // resolved absolute instant
    /// When the speaker said they'd START working, as distinct from `deadline` (when it must be
    /// DONE). Populated only for utterances that actually name a starting moment — above all the
    /// urgent case ("làm task X ngay lập tức" -> `startTime` = the instant of speaking, `priority`
    /// 1, and NO deadline, because "urgent" describes when work begins, not when it is due). A
    /// bare clock time stays a `deadline`, exactly as before this field existed.
    ///
    /// `IntentRouter.applyStartTimeDerivation` turns a `startTime`-without-`deadline` task into one
    /// with a derived deadline (`startTime` + `estimateMinutes`, defaulting to 30 minutes). 2026-07-29
    /// (anh Khôi chốt): that derived deadline now carries 0.75 confidence — ABOVE `ParsedValue.
    /// isUncertain`'s 0.7 bar — so it auto-commits on Save instead of requiring a confirm-card tap
    /// first; see `deadlineIsEstimated` right below for how the UI still marks it as a guess without
    /// gating it behind an explicit accept.
    ///
    /// Carried through to `TaskItem.startTime` and persisted, but INERT: it drives no ordering, no
    /// eligibility, no reminders. An urgent task reaches the top of the list purely through its
    /// derived deadline landing today — `VolarCore.NextTask`'s tier 2 (near-term deadline) already
    /// outranks tier 3 (priority), which is why this feature needs no new task kind or engine tier.
    ///
    /// DEFAULTED (`= nil`) on purpose: the synthesized memberwise init is called from many call
    /// sites that predate this field (`HeuristicNLParser.parseOne` twice in this file,
    /// `IntentRouter.titleOnlyTask`, test fixtures), and a default keeps every one of them
    /// compiling untouched. Same reason `Codable` used to stay synthesized for the whole struct — an
    /// `Optional` stored property decodes via `decodeIfPresent`, so payloads written before this
    /// field still decode. (`ParsedTask`'s `Codable` conformance is now hand-rolled below, for
    /// `deadlineIsEstimated`'s sake — see that field's own comment — but this property still keeps
    /// exactly that same `decodeIfPresent` treatment in the new `init(from:)`.)
    var startTime: ParsedValue<Date>? = nil
    /// True only when THIS deadline was machine-DERIVED by `IntentRouter.applyStartTimeDerivation`
    /// from `startTime` (plus an estimate or the 30-minute default) — never true for a deadline the
    /// user actually spoke; a spoken deadline always leaves this `false`. Confidence alone can't
    /// carry this distinction anymore: the derived deadline's confidence is now 0.75 (see
    /// `startTime`'s comment above for why), so `PopoverView.DeadlineControl` needs an explicit
    /// signal — separate from confidence/uncertain styling — to still show the user "this time is
    /// a guess" (its "· est" chip label) even though the value auto-commits on Save. Never drives
    /// dashed/uncertain rendering itself (that would wrongly imply the value needs an accept tap
    /// before it saves, which is no longer true).
    ///
    /// DEFAULTED (`= false`) for the same "many pre-existing call sites" reason `startTime` above
    /// is defaulted. Unlike `startTime`, this is a non-`Optional` `Bool`, so it does NOT get the
    /// free `decodeIfPresent` treatment synthesized `Decodable` gives `Optional` properties — a
    /// payload encoded before this field existed would fail to decode outright if `Codable` were
    /// still left to the compiler. That's why `ParsedTask`'s `Codable` conformance is hand-rolled in
    /// the extension below (same convention as `Recurrence`/`ReminderPolicy`/`ParsedCondition` in
    /// this file/`Recurrence.swift`), decoding this key with `decodeIfPresent(...) ?? false`.
    var deadlineIsEstimated: Bool = false
    var estimateMinutes: ParsedValue<Int>?
    var priority: ParsedValue<Int>? // 1...4
    var reminderOverride: ParsedValue<ReminderPolicy>?
    var recurrence: ParsedValue<Recurrence>?
    var kind: TaskKind = .task // default .task; .review when "review after…"
    var conditions: [ParsedCondition] = [] // taskDone(by fuzzy title ref) / afterDate / external
    var subtasks: [String] = [] // breakdown step titles (may be empty)
    var followUpReview: Bool = false // "when done, review it" → a second .review task
    /// task_cues_v1 (`specs/006-cues-and-waiting/design.md`): populated only when the utterance
    /// anchored this task to a real EVENT in the user's day ("ngủ dậy thì...", "sau khi ăn trưa
    /// thì...") rather than a clock time. A SURFACING signal only (design.md §1) — carries no
    /// eligibility/gating meaning, and MUST NEVER be turned into `deadline`/a `.afterDate`
    /// condition anywhere in this codebase; that exact conflation (forcing an event-anchored
    /// utterance into a fabricated clock time) is the live bug this feature exists to fix.
    /// `TaskCue`/`CueKind` are owned by a parallel agent (`Model/TaskCue.swift`) — referenced
    /// here by name only, never redefined.
    ///
    /// DEFAULTED (`= nil`) for the same "many pre-existing call sites" reason `startTime` above
    /// is defaulted — every call site that predates this field (`HeuristicNLParser.parseOne`
    /// twice in this file, `IntentRouter.titleOnlyTask`, every hand-built test fixture across
    /// `Volar/Tests/`) keeps compiling untouched, and a payload encoded before this field existed
    /// still decodes via `decodeIfPresent` below (same treatment `startTime`/`deadline` get).
    var cue: TaskCue? = nil
    var sourceTranscript: String // verbatim utterance, ALWAYS retained
}

extension ParsedTask: Codable {
    /// Hand-rolled (2026-07-29, same convention `Recurrence`/`ReminderPolicy`/`ParsedCondition`
    /// already use in this file/`Recurrence.swift`) instead of leaving `Codable` to compiler
    /// synthesis. The trigger is `deadlineIsEstimated`: it's a non-`Optional` `Bool` with a default
    /// value, and synthesized `Decodable` does NOT consult a stored property's default when a key is
    /// missing — it only skips missing keys for `Optional` properties (via an implicit
    /// `decodeIfPresent`). A payload encoded before this field existed would fail to decode outright
    /// under synthesis, exactly the trap `ReminderPolicy.init(from:)`'s own comment documents for
    /// the same reason (see `Recurrence.swift`, READ-ONLY reference for this agent).
    ///
    /// Written explicitly for every field (not just `deadlineIsEstimated`) so this doesn't rely on
    /// the compiler still synthesizing `encode(to:)` around a hand-written `init(from:)` — this also
    /// closes the SAME pre-existing gap for `kind`/`conditions`/`subtasks`/`followUpReview`, which
    /// already had default values before this change and were exposed to the identical risk for any
    /// payload predating THEM (not something this task asked for, but a free correctness fix once
    /// this extension exists at all).
    private enum CodingKeys: String, CodingKey {
        case title, notes, deadline, startTime, deadlineIsEstimated, estimateMinutes, priority,
             reminderOverride, recurrence, kind, conditions, subtasks, followUpReview, cue, sourceTranscript
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        deadline = try container.decodeIfPresent(ParsedValue<Date>.self, forKey: .deadline)
        startTime = try container.decodeIfPresent(ParsedValue<Date>.self, forKey: .startTime)
        deadlineIsEstimated = try container.decodeIfPresent(Bool.self, forKey: .deadlineIsEstimated) ?? false
        estimateMinutes = try container.decodeIfPresent(ParsedValue<Int>.self, forKey: .estimateMinutes)
        priority = try container.decodeIfPresent(ParsedValue<Int>.self, forKey: .priority)
        reminderOverride = try container.decodeIfPresent(ParsedValue<ReminderPolicy>.self, forKey: .reminderOverride)
        recurrence = try container.decodeIfPresent(ParsedValue<Recurrence>.self, forKey: .recurrence)
        kind = try container.decodeIfPresent(TaskKind.self, forKey: .kind) ?? .task
        conditions = try container.decodeIfPresent([ParsedCondition].self, forKey: .conditions) ?? []
        subtasks = try container.decodeIfPresent([String].self, forKey: .subtasks) ?? []
        followUpReview = try container.decodeIfPresent(Bool.self, forKey: .followUpReview) ?? false
        cue = try container.decodeIfPresent(TaskCue.self, forKey: .cue)
        sourceTranscript = try container.decode(String.self, forKey: .sourceTranscript)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(deadline, forKey: .deadline)
        try container.encodeIfPresent(startTime, forKey: .startTime)
        try container.encode(deadlineIsEstimated, forKey: .deadlineIsEstimated)
        try container.encodeIfPresent(estimateMinutes, forKey: .estimateMinutes)
        try container.encodeIfPresent(priority, forKey: .priority)
        try container.encodeIfPresent(reminderOverride, forKey: .reminderOverride)
        try container.encodeIfPresent(recurrence, forKey: .recurrence)
        try container.encode(kind, forKey: .kind)
        try container.encode(conditions, forKey: .conditions)
        try container.encode(subtasks, forKey: .subtasks)
        try container.encode(followUpReview, forKey: .followUpReview)
        try container.encodeIfPresent(cue, forKey: .cue)
        try container.encode(sourceTranscript, forKey: .sourceTranscript)
    }
}

// MARK: - NLParser protocol

/// Abstraction over "turn a transcript into a `ParsedTask`" — kept for the existing synchronous
/// single-task call site (`AppState.parser: NLParser`, frozen elsewhere, not this agent's file).
/// The richer multi-task/async shape lives on `HeuristicNLParser` directly as a second overload
/// (see below) matching `IntentParser.parse(_:now:openTaskTitles:)` from the parsing contract, so
/// the Phase-3 Parsing agent's router can call straight into it as the always-available floor
/// route without an adapter.
protocol NLParser {
    func parse(_ transcript: String) -> ParsedTask
}

/// On-device heuristic parser: `NSDataDetector`/keyword scans for dates, dependencies, defers,
/// waits, estimates, recurrence, and reminder overrides. Bilingual (Vietnamese + English). No
/// network calls anywhere (constitution I) — pure text-in/`ParsedTask`-out, no LLM calls (that is
/// the router's job per the parsing contract).
struct HeuristicNLParser: NLParser {
    /// Legacy synchronous single-task entry point. Delegates into `parseOne`, using "now" at call
    /// time (this path never receives an injected clock — matches the v1 protocol's shape).
    func parse(_ transcript: String) -> ParsedTask {
        Self.parseOne(transcript, now: Date(), openTaskTitles: [])
    }

    /// Matches `IntentParser.parse(_:now:openTaskTitles:)` (parsing-contract.md) exactly, so a
    /// conforming `IntentRouter` can call this as its floor route. Declared `async` only to match
    /// that shape — all work here is synchronous, pure, and text-only (no I/O). Never splits a
    /// compound utterance into multiple tasks (out of scope for this heuristic pass — the ≤10-task
    /// cap is trivially satisfied by always returning exactly one).
    func parse(_ transcript: String, now: Date, openTaskTitles: [String]) async -> [ParsedTask] {
        [Self.parseOne(transcript, now: now, openTaskTitles: openTaskTitles)]
    }

    // MARK: - Tuning constants

    /// Defensive bound on how much of the transcript detection regexes actually scan — protects
    /// against adversarial/pathological input (megabyte-scale paste) doing unbounded work. Does
    /// NOT affect `sourceTranscript`, which always retains the full, untruncated input per the
    /// contract ("ALWAYS retained").
    private static let maxWorkingLength = 8_000
    private static let maxTitleLength = 300
    private static let fallbackTitle = "Untitled task"

    // MARK: - Entry point

    private static func parseOne(_ rawTranscript: String, now: Date, openTaskTitles: [String]) -> ParsedTask {
        let sourceTranscript = rawTranscript
        let workingText = String(rawTranscript.prefix(Self.maxWorkingLength))

        guard !workingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Empty/whitespace-only input — never nil, never crash (constitution II): a title-only
            // placeholder carrying whatever (possibly empty) transcript was actually given.
            return ParsedTask(
                title: Self.fallbackTitle,
                notes: nil,
                deadline: nil,
                estimateMinutes: nil,
                priority: nil,
                reminderOverride: nil,
                recurrence: nil,
                sourceTranscript: sourceTranscript
            )
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current // explicit zone, never implicit — constitution "Technology" note

        let title = Self.cleanTitle(from: workingText)
        let priority = Self.detectPriority(in: workingText)
        let estimateMinutes = Self.detectEstimate(in: workingText, excluding: Self.reminderIntervalRange(in: workingText))
        let recurrence = Self.detectRecurrence(in: workingText)
        let reminderOverride = Self.detectReminderOverride(in: workingText)
        let kind = Self.detectKind(in: workingText)
        let followUpReview = Self.detectFollowUpReview(in: workingText)

        // Defer phrasing ("start Monday", "thứ 2 mới làm") takes priority over deadline phrasing
        // for the SAME date token — a defer date means "don't start before", not "due by", so it
        // must never also become the deadline.
        var conditions: [ParsedCondition] = []
        var deadline: ParsedValue<Date>?
        if let deferCondition = Self.detectDeferCondition(in: workingText, now: now, calendar: calendar) {
            conditions.append(deferCondition)
        } else {
            deadline = Self.detectDeadline(in: workingText, now: now, calendar: calendar)
        }
        if let dependency = Self.detectDependencyCondition(in: workingText, openTaskTitles: openTaskTitles) {
            conditions.append(dependency)
        }
        if let external = Self.detectExternalCondition(in: workingText) {
            conditions.append(external)
        }

        return ParsedTask(
            title: title,
            notes: nil,
            deadline: deadline,
            estimateMinutes: estimateMinutes,
            priority: priority,
            reminderOverride: reminderOverride,
            recurrence: recurrence,
            kind: kind,
            conditions: conditions,
            subtasks: [],
            followUpReview: followUpReview,
            sourceTranscript: sourceTranscript
        )
    }

    // MARK: - Title cleanup (EN + VI lead-ins, trailing priority clause strip)

    private static func cleanTitle(from text: String) -> String {
        var title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let leadIns = [
            "remind me to ", "remember to ", "i need to ", "please remember to ", "please ",
            "nhắc tôi ", "nhắc mình ", "làm ơn nhắc tôi ", "tôi cần ", "mình cần ", "nhớ "
        ]
        let lower = title.lowercased()
        for leadIn in leadIns where lower.hasPrefix(leadIn) {
            title = String(title.dropFirst(leadIn.count))
            break
        }
        // Trailing ", high priority" / ", ưu tiên cao" style clauses — drop if present.
        if let commaIndex = title.firstIndex(of: ",") {
            let tail = title[title.index(after: commaIndex)...].lowercased()
            if tail.contains("priority") || tail.contains("urgent") || tail.contains("ưu tiên") {
                title = String(title[..<commaIndex])
            }
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return Self.fallbackTitle }
        if title.count > Self.maxTitleLength {
            title = String(title.prefix(Self.maxTitleLength))
        }
        return title
    }

    // MARK: - Priority ("urgent" / "khẩn cấp" / "low priority" / "không gấp" ...)

    private static func detectPriority(in text: String) -> ParsedValue<Int>? {
        let lower = text.lowercased()
        let highPhrases = ["high priority", "ưu tiên cao", "quan trọng nhất"]
        let highWords = ["urgent", "asap", "critical", "khẩn cấp", "gấp"]
        let lowPhrases = ["low priority", "ưu tiên thấp", "không gấp"]
        let lowWords = ["whenever", "no rush", "not urgent", "rảnh thì làm", "khi nào rảnh"]
        let mediumPhrases = ["medium priority", "normal priority", "ưu tiên trung bình"]

        // Only ever set when the transcript SAYS a priority (constitution II — never fabricate a
        // default when nothing was said).
        if highPhrases.contains(where: lower.contains) { return ParsedValue(value: 1, confidence: 0.85) }
        if lowPhrases.contains(where: lower.contains) { return ParsedValue(value: 3, confidence: 0.85) }
        if mediumPhrases.contains(where: lower.contains) { return ParsedValue(value: 2, confidence: 0.8) }
        if highWords.contains(where: lower.contains) { return ParsedValue(value: 1, confidence: 0.72) }
        if lowWords.contains(where: lower.contains) { return ParsedValue(value: 3, confidence: 0.7) }
        return nil
    }

    // MARK: - Estimate ("45 min", "1 hr", "nửa tiếng", "~30 phút", "chắc 30 phút")

    private static let estimateRegex = try? NSRegularExpression(
        pattern: #"(\d+)\s*(minutes?|mins?|hours?|hrs?|phút|tiếng|giờ)"#,
        options: [.caseInsensitive]
    )

    private static let hedgeWords = ["chắc", "có lẽ", "khoảng", "tầm", "cỡ", "maybe", "probably", "about", "around", "~"]

    private static func isHedged(before range: Range<String.Index>, in lower: String) -> Bool {
        let start = lower.index(range.lowerBound, offsetBy: -20, limitedBy: lower.startIndex) ?? lower.startIndex
        let context = lower[start..<range.lowerBound]
        return Self.hedgeWords.contains { context.contains($0) }
    }

    /// `excluding`: range of the reminder-cadence phrase ("remind me every 30 minutes") — a
    /// duration match inside it is the cadence, not an estimate.
    private static func detectEstimate(in text: String, excluding: NSRange? = nil) -> ParsedValue<Int>? {
        let lower = text.lowercased()

        // Fixed-phrase table first — these don't carry an explicit digit for the regex below.
        let halfHourPhrases = ["nửa tiếng", "nửa giờ", "half an hour", "half hour"]
        for phrase in halfHourPhrases {
            if let range = lower.range(of: phrase) {
                return ParsedValue(value: 30, confidence: Self.isHedged(before: range, in: lower) ? 0.6 : 0.75)
            }
        }
        let ninetyPhrases = ["một tiếng rưỡi", "1 tiếng rưỡi", "hour and a half", "an hour and a half", "1.5 hours", "1.5 hour"]
        for phrase in ninetyPhrases {
            if let range = lower.range(of: phrase) {
                return ParsedValue(value: 90, confidence: Self.isHedged(before: range, in: lower) ? 0.6 : 0.75)
            }
        }

        guard let regex = Self.estimateRegex else { return nil }
        // Matched against `lower` (not `text`) throughout, including the range used for the hedge
        // lookback below — `text.lowercased()` can shift grapheme-cluster boundaries for some
        // Unicode input, so a `Range<String.Index>` produced against one string is not safely
        // reusable against the other; staying entirely in `lower`'s index space avoids that trap.
        let nsLower = lower as NSString
        let found = regex.matches(in: lower, range: NSRange(location: 0, length: nsLower.length))
            .first { m in excluding.map { NSIntersectionRange(m.range, $0).length == 0 } ?? true }
        guard let match = found,
              match.range(at: 1).location != NSNotFound,
              match.range(at: 2).location != NSNotFound
        else { return nil }

        let valueString = nsLower.substring(with: match.range(at: 1))
        // `Int(_:)` returns nil (never traps) on overflow — a defensive bound against an
        // adversarial huge digit string ("999999999999 minutes").
        guard let value = Int(valueString), value > 0, value <= 1440 else { return nil }
        let unit = nsLower.substring(with: match.range(at: 2))
        let minutes = (unit.hasPrefix("h") || unit.hasPrefix("t") || unit.hasPrefix("g")) ? value * 60 : value

        let matchRange = Range(match.range, in: lower) ?? lower.startIndex..<lower.startIndex
        let hedged = Self.isHedged(before: matchRange, in: lower)
        return ParsedValue(value: min(minutes, 24 * 60), confidence: hedged ? 0.62 : 0.85)
    }

    // MARK: - Date resolution shared by deadline + defer

    private struct DateToken {
        var date: Date
        var isExplicitTime: Bool
    }

    private static let dateDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// Vietnamese + English weekday keywords → `Calendar.component(.weekday)` values
    /// (Sunday = 1 ... Saturday = 7, matching `Calendar`'s own convention).
    private static let weekdayKeywords: [(String, Int)] = [
        ("chủ nhật", 1), ("chúa nhật", 1), ("sunday", 1),
        ("thứ hai", 2), ("thứ 2", 2), ("monday", 2),
        ("thứ ba", 3), ("thứ 3", 3), ("tuesday", 3),
        ("thứ tư", 4), ("thứ 4", 4), ("wednesday", 4),
        ("thứ năm", 5), ("thứ 5", 5), ("thursday", 5),
        ("thứ sáu", 6), ("thứ 6", 6), ("friday", 6),
        ("thứ bảy", 7), ("thứ 7", 7), ("saturday", 7)
    ]

    private static func nextOccurrence(ofWeekday targetWeekday: Int, from now: Date, calendar: Calendar) -> Date {
        let currentWeekday = calendar.component(.weekday, from: now)
        // When the spoken weekday equals today's weekday, `(target - current + 7) % 7` is 0 —
        // that must mean "next <weekday>" (7 days out), NEVER "today" (a no-op that would make
        // "thứ 2 mới làm"/"do it Monday" said ON a Monday silently resolve to right now).
        let d = (targetWeekday - currentWeekday + 7) % 7
        let daysToAdd = d == 0 ? 7 : d
        return calendar.date(byAdding: .day, value: daysToAdd, to: now) ?? now
    }

    /// Best-effort date/time resolution, tried in order: `NSDataDetector` (best signal — resolves
    /// explicit day+time phrases), then a Vietnamese/English weekday keyword scan, then coarse
    /// relative keywords ("tomorrow"/"mai", "next week"/"tuần sau", "today"/"hôm nay").
    ///
    /// // UNVERIFIED: `NSDataDetector`'s `.date` type is English-locale-tuned; matching quality for
    /// Vietnamese phrasing on macOS 14 needs Mac verification — the keyword table below is the
    /// deliberate fallback for exactly that gap.
    private static func resolveDateToken(in text: String, now: Date, calendar: Calendar) -> DateToken? {
        let lower = text.lowercased()

        if let detector = Self.dateDetector {
            let nsText = text as NSString
            let range = NSRange(location: 0, length: nsText.length)
            if let match = detector.firstMatch(in: text, options: [], range: range), let date = match.date {
                let matchedText = nsText.substring(with: match.range).lowercased()
                let hasTimeSignal = matchedText.contains(":") || matchedText.contains(" at ")
                    || matchedText.contains("am") || matchedText.contains("pm")
                return DateToken(date: date, isExplicitTime: hasTimeSignal)
            }
        }

        for (keyword, weekday) in Self.weekdayKeywords where lower.contains(keyword) {
            let date = Self.nextOccurrence(ofWeekday: weekday, from: now, calendar: calendar)
            return DateToken(date: date, isExplicitTime: false)
        }

        if lower.contains("tomorrow") || lower.contains("ngày mai") || lower.contains(" mai ") || lower.hasSuffix(" mai") || lower.hasPrefix("mai ") {
            let date = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return DateToken(date: date, isExplicitTime: false)
        }
        if lower.contains("next week") || lower.contains("tuần sau") || lower.contains("tuần tới") {
            let date = calendar.date(byAdding: .day, value: 7, to: now) ?? now
            return DateToken(date: date, isExplicitTime: false)
        }
        if lower.contains("today") || lower.contains("hôm nay") {
            return DateToken(date: now, isExplicitTime: false)
        }

        return nil
    }

    // MARK: - Defer phrasing → ParsedCondition.afterDate

    private static let deferCueRegex = try? NSRegularExpression(
        pattern: #"\bstart(?:ing)?\s+(?:on\s+)?(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|next\s+week)\b"#,
        options: [.caseInsensitive]
    )

    private static func detectDeferCondition(in text: String, now: Date, calendar: Calendar) -> ParsedCondition? {
        let lower = text.lowercased()
        let hasVietnameseCue = lower.contains("mới làm") || lower.contains("để tuần sau") || lower.contains("để thứ")
        let hasEnglishCue: Bool = {
            if lower.contains("not until") || lower.contains("wait until") { return true }
            guard let regex = Self.deferCueRegex else { return false }
            let nsText = text as NSString
            return regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) != nil
        }()

        guard hasVietnameseCue || hasEnglishCue else { return nil }
        // A defer cue with no resolvable date is left unset rather than fabricating a date
        // (constitution II — never silently guess a specific instant).
        guard let token = Self.resolveDateToken(in: text, now: now, calendar: calendar) else { return nil }
        return .afterDate(token.date, confidence: token.isExplicitTime ? 0.8 : 0.72)
    }

    // MARK: - Deadline (only considered when no defer condition won above)

    private static func detectDeadline(in text: String, now: Date, calendar: Calendar) -> ParsedValue<Date>? {
        guard let token = Self.resolveDateToken(in: text, now: now, calendar: calendar) else { return nil }
        // No explicit clock time → we're guessing a time-of-day (e.g. defaulting to the moment
        // resolved from a bare weekday/relative-day match), so this is genuinely ambiguous and
        // must render as an uncertain chip (constitution II).
        return ParsedValue(value: token.date, confidence: token.isExplicitTime ? 0.85 : 0.65)
    }

    // MARK: - Dependency phrasing → ParsedCondition.taskDone

    private static let dependencyPatterns: [NSRegularExpression] = [
        #"(?:after|once)\s+(.+?)\s+is\s+done"#,
        #"when\s+(.+?)\s+is\s+done"#,
        #"sau\s+khi\s+(.+?)\s+xong"#,
        #"(.+?)\s+xong\s+thì"#,
        #"after\s+(.+?)(?=,|\.|$)"#,
        #"sau\s+khi\s+(.+?)(?=,|thì|\.|$)"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static func firstCapturedGroup(_ regex: NSRegularExpression, in text: String) -> String? {
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound
        else { return nil }
        return nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Confidence reflects match certainty: a titleQuery that fuzzy-matches one of the caller's
    /// currently-open task titles is a much stronger signal than a bare heuristic phrase match —
    /// only the former clears the 0.7 auto-attach-adjacent bar (still gated by the confirm-card
    /// picker per constitution II regardless).
    private static func dependencyConfidence(for titleQuery: String, openTaskTitles: [String]) -> Double {
        let normalizedQuery = titleQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return 0.5 }
        let matched = openTaskTitles.contains { candidate in
            let normalizedCandidate = candidate.lowercased()
            return normalizedCandidate.contains(normalizedQuery) || normalizedQuery.contains(normalizedCandidate)
        }
        return matched ? 0.78 : 0.55
    }

    private static func detectDependencyCondition(in text: String, openTaskTitles: [String]) -> ParsedCondition? {
        for regex in Self.dependencyPatterns {
            guard let titleQuery = Self.firstCapturedGroup(regex, in: text), titleQuery.count > 1 else { continue }
            let confidence = Self.dependencyConfidence(for: titleQuery, openTaskTitles: openTaskTitles)
            return .taskDone(titleQuery: titleQuery, confidence: confidence)
        }
        return nil
    }

    // MARK: - Wait phrasing → ParsedCondition.external

    private static let externalPatterns: [NSRegularExpression] = [
        #"waiting\s+(?:for|on)\s+(.+?)(?=,|\.|$)"#,
        #"(?:chờ|đợi)\s+(.+?)(?=,|\.|$)"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static func detectExternalCondition(in text: String) -> ParsedCondition? {
        for regex in Self.externalPatterns {
            guard let description = Self.firstCapturedGroup(regex, in: text), description.count > 1 else { continue }
            let wordCount = description.split(separator: " ").count
            return .external(description: description, confidence: wordCount <= 4 ? 0.72 : 0.62)
        }
        return nil
    }

    // MARK: - Recurrence

    private static let everyNDaysRegex = try? NSRegularExpression(
        pattern: #"(?:every|mỗi|cứ)\s+(\d+)\s+(?:days?|ngày)"#,
        options: [.caseInsensitive]
    )

    private static func everyNDays(in lower: String) -> Int? {
        guard let regex = Self.everyNDaysRegex else { return nil }
        let nsText = lower as NSString
        guard let match = regex.firstMatch(in: lower, range: NSRange(location: 0, length: nsText.length)),
              match.range(at: 1).location != NSNotFound
        else { return nil }
        guard let days = Int(nsText.substring(with: match.range(at: 1))), days > 0, days <= 365 else { return nil }
        return days
    }

    private static func detectRecurrence(in text: String) -> ParsedValue<Recurrence>? {
        let lower = text.lowercased()
        let dailyPhrases = ["every day", "daily", "mỗi ngày", "hằng ngày", "hàng ngày"]
        let weeklyPhrases = ["every week", "weekly", "mỗi tuần", "hằng tuần", "hàng tuần"]
        let monthlyPhrases = ["every month", "monthly", "mỗi tháng", "hằng tháng", "hàng tháng"]
        // Approximate mappings onto the 4-case `Recurrence` enum — flagged uncertain since "every
        // morning" isn't literally "every day" (no time-of-day concept in `Recurrence`).
        let looseDailyPhrases = ["every morning", "mỗi sáng", "every evening", "mỗi tối"]

        if dailyPhrases.contains(where: lower.contains) { return ParsedValue(value: .daily, confidence: 0.82) }
        if weeklyPhrases.contains(where: lower.contains) { return ParsedValue(value: .weekly, confidence: 0.82) }
        if monthlyPhrases.contains(where: lower.contains) { return ParsedValue(value: .monthly, confidence: 0.8) }
        if looseDailyPhrases.contains(where: lower.contains) { return ParsedValue(value: .daily, confidence: 0.62) }
        if let days = Self.everyNDays(in: lower) { return ParsedValue(value: .every(days: days), confidence: 0.78) }
        return nil
    }

    // MARK: - Reminder override ("remind me every 30 minutes", "nhắc mỗi 30 phút")

    private static let reminderIntervalRegex = try? NSRegularExpression(
        pattern: #"(?:remind(?:\s+me)?(?:\s+every)?|nhắc(?:\s+lại)?\s+mỗi)\s+(\d+)\s*(minutes?|mins?|hours?|hrs?|phút|giờ)"#,
        options: [.caseInsensitive]
    )

    private static func reminderIntervalRange(in text: String) -> NSRange? {
        guard let regex = Self.reminderIntervalRegex else { return nil }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))?.range
    }

    private static func detectReminderOverride(in text: String) -> ParsedValue<ReminderPolicy>? {
        let lower = text.lowercased()
        guard lower.contains("remind") || lower.contains("nhắc") else { return nil }
        guard let regex = Self.reminderIntervalRegex else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              match.range(at: 1).location != NSNotFound,
              match.range(at: 2).location != NSNotFound
        else { return nil }
        guard let value = Int(nsText.substring(with: match.range(at: 1))), value > 0, value <= 1440 else { return nil }
        let unit = nsText.substring(with: match.range(at: 2)).lowercased()
        let seconds: TimeInterval = (unit.hasPrefix("h") || unit.hasPrefix("g")) ? TimeInterval(value) * 3600 : TimeInterval(value) * 60
        let policy = ReminderPolicy(offsets: [0], repeatEvery: seconds)
        return ParsedValue(value: policy, confidence: 0.8)
    }

    // MARK: - Kind (.review) + followUpReview

    private static func detectKind(in text: String) -> TaskKind {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("review ") || lower.hasPrefix("review after") || lower.contains(" review after ") {
            return .review
        }
        if lower.hasPrefix("xem lại ") {
            return .review
        }
        return .task
    }

    private static func detectFollowUpReview(in text: String) -> Bool {
        let lower = text.lowercased()
        let phrases = [
            "when done, review", "when it's done, review", "once done, review", "then review it",
            "xong thì xem lại", "làm xong thì xem lại", "xong rồi xem lại"
        ]
        return phrases.contains { lower.contains($0) }
    }
}

// MARK: - IntentParser conformance (parsing-contract.md)

/// `HeuristicNLParser` already implements `parse(_:now:openTaskTitles:)` above, matching
/// `IntentParser.parse` exactly. This adds the other required method so the type can serve as
/// `IntentRouter`'s always-available floor route (`IntentParsing.swift`'s `heuristic: IntentParser`
/// default arg + `heuristic.breakdown(...)` call).
extension HeuristicNLParser: IntentParser {
    /// DEAD-CODE CLEANUP (`specs/006-cues-and-waiting/design.md` §0.1, 2026-08-08): this used to
    /// return a hard-coded 5-step English scaffold ("Gather what's needed for X", "Start the
    /// first small piece", "Work through the middle of it", "Check the result", "Wrap up X") so
    /// the confirm card always had SOMETHING to show even when FM and Cloud both fell through.
    /// It never actually reached a user: `IntentRouter.breakdown`/`.breakdownWithContext` stopped
    /// calling into `HeuristicNLParser` entirely on 2026-07-28 (anh Khôi chốt — see
    /// `IntentParsing.swift`'s `IntentRouter` class doc comment), and the one real app call site
    /// (`AppState.fetchBreakdown`) passes `heuristicFloor: []`. Repo-wide grep before this change
    /// confirmed there is no remaining production call site for this method — `design.md` §0.1
    /// verified this precisely so this cleanup wouldn't be a guess.
    ///
    /// Returning `[]` instead of deleting the method (still required for `IntentParser`
    /// conformance, which `IntentRouter`'s dormant reconnect path — see that class's doc comment
    /// — depends on `HeuristicNLParser` still satisfying) follows the SAME reasoning anh Khôi
    /// already applied 2026-07-29 when he rejected a hard-coded 3-to-9-step `too_big` floor: a
    /// pure keyword/regex parser with no model has no honest way to know what the physical steps
    /// of an arbitrary task actually are, so a fixed English template dressed up as "the plan" is
    /// fabrication, not a floor (constitution II — never silently guess). `[]` is the honest
    /// answer; a caller that ever reconnects this tier is responsible for telling the user
    /// breakdown needs a real model, never for showing invented steps.
    func breakdown(title: String, notes: String?) async -> [String] {
        []
    }
}
