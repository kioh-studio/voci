// Tests/CloudParserTests.swift — regression coverage for the `now`-timezone bug fix in
// `Sources/Parsing/CloudParser.swift`: `CloudParser.makeRequestFormatter()` used to rely on
// `ISO8601DateFormatter()`'s own default `timeZone` (GMT), silently re-stamping the user's LOCAL
// wall clock as if it were UTC — a user at 15:00 local (UTC+7) sent `...T08:00:00Z` (their own
// clock digits, wrongly labeled `Z`), the server then resolved relative phrases like "chiều nay"
// against that mislabeled instant, and the client decoded the resulting deadline exactly 7 hours
// off from what the user meant. This file pins down the two properties that fix depends on:
//   1. The formatted `now` string always satisfies the server's own zone-designator regex
//      (`_shared/schema.ts`'s `isIso8601WithZone`, `/(Z|[+-]\d{2}:\d{2})$/`) — this is the ONE
//      thing standing between this bug and its recurrence, so it is the most important test here.
//   2. Given a FIXED non-GMT timezone, the formatted string reflects THAT zone's wall-clock time
//      and offset, not UTC's — a formatter that always emits `Z` would also pass test (1) while
//      still having the exact bug, so (1) alone is not sufficient.
// Also covers `CloudParser.validatedTimezoneField`, the defensive gate on the new `timezone` wire
// field (parse mode only) — must accept well-formed IANA identifiers and reject anything that
// would fail the server's own validation rule, since the server interpolates this value directly
// into a model prompt (a real injection surface, not just cosmetic validation).
//
// Deliberately NO networking in this file: there is no existing `URLProtocol`-stub test
// infrastructure anywhere in `Volar/Tests/` to reuse (checked: no other test file sets one up),
// and building one from scratch was judged out of scope for this fix. Instead,
// `makeRequestFormatter` and `validatedTimezoneField` were both promoted from `private` to
// `internal` specifically so this file can exercise them directly via `@testable import Volar` —
// the same "pull the pure logic out so it's testable without a live network/AppState" precedent
// `CloudCompletionResolutionTests.swift` already established for `AppState.resolveCloudMatch`.
//
// UNVERIFIED (written entirely on Windows — no Xcode/swift toolchain available in this
// environment): not run against a real `VolarTests` bundle. Compile-by-inspection only.
import XCTest
@testable import Volar

final class CloudParserTests: XCTestCase {

    // MARK: - (1) `now` always satisfies the server's zone-designator regex — the test that
    // actually blocks this bug from recurring.

    func testNowStringMatchesServerZoneRegexOnHostTimezone() {
        let now = Date(timeIntervalSince1970: 1_800_000_000) // arbitrary fixed instant
        let formatter = CloudParser.makeRequestFormatter() // default: TimeZone.current
        let string = formatter.string(from: now)

        XCTAssertNotNil(
            string.range(
                of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression
            ),
            "must match `_shared/schema.ts`'s `isIso8601WithZone` regex exactly, on ANY host " +
            "timezone (including GMT itself, where the offset is legitimately `Z`) — got \(string)"
        )
    }

    func testNowStringMatchesServerZoneRegexOnAFixedNonGMTZone() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        guard let saigon = TimeZone(identifier: "Asia/Ho_Chi_Minh") else {
            return XCTFail("Asia/Ho_Chi_Minh must be a valid TimeZone identifier on any Foundation-backed platform")
        }
        let formatter = CloudParser.makeRequestFormatter(timeZone: saigon)
        let string = formatter.string(from: now)

        XCTAssertNotNil(
            string.range(
                of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression
            ),
            "got \(string)"
        )
        XCTAssertTrue(
            string.hasSuffix("+07:00"),
            "Asia/Ho_Chi_Minh has no DST and a fixed +07:00 offset year-round — must never come back as Z/UTC, got \(string)"
        )
    }

    // MARK: - (2) A fixed non-GMT timezone reflects wall-clock time, not UTC — the bug's actual
    // symptom (a 7-hour shift for a +07:00 user).

    func testNowStringReflectsLocalWallClockNotUTC() {
        // 1_800_000_000 unix seconds == 2027-01-15T08:00:00Z in UTC (verified independently, not
        // just asserted). In Asia/Ho_Chi_Minh (UTC+7, no DST), the same instant's wall clock is
        // 2027-01-15T15:00:00 — 7 hours later, matching this bug's real-world symptom exactly.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        guard let saigon = TimeZone(identifier: "Asia/Ho_Chi_Minh") else {
            return XCTFail("Asia/Ho_Chi_Minh must be a valid TimeZone identifier on any Foundation-backed platform")
        }
        let formatter = CloudParser.makeRequestFormatter(timeZone: saigon)
        let string = formatter.string(from: now)

        XCTAssertTrue(
            string.hasPrefix("2027-01-15T15:00:00"),
            "must emit the LOCAL wall clock (15:00 in UTC+7 for this instant), not the UTC clock " +
            "(08:00) — the exact bug this fix closes; got \(string)"
        )
    }

    // MARK: - (3) `validatedTimezoneField` — the defensive gate before `timezone` ever reaches
    // the wire (the server interpolates it directly into a model prompt).

    func testValidatedTimezoneFieldAcceptsWellFormedIANAIdentifiers() {
        XCTAssertEqual(CloudParser.validatedTimezoneField("Asia/Ho_Chi_Minh"), "Asia/Ho_Chi_Minh")
        XCTAssertEqual(CloudParser.validatedTimezoneField("UTC"), "UTC")
        XCTAssertEqual(
            CloudParser.validatedTimezoneField("America/Argentina/Buenos_Aires"),
            "America/Argentina/Buenos_Aires",
            "up to 3 slash-separated segments must be accepted"
        )
    }

    func testValidatedTimezoneFieldRejectsEmptyString() {
        XCTAssertNil(CloudParser.validatedTimezoneField(""))
    }

    func testValidatedTimezoneFieldRejectsOverLengthIdentifier() {
        let tooLong = String(repeating: "A", count: 65)
        XCTAssertNil(CloudParser.validatedTimezoneField(tooLong))
    }

    func testValidatedTimezoneFieldAcceptsExactlyMaxLength() {
        let exactlyMax = String(repeating: "A", count: 64)
        XCTAssertEqual(CloudParser.validatedTimezoneField(exactlyMax), exactlyMax)
    }

    func testValidatedTimezoneFieldRejectsDisallowedCharacters() {
        // A malformed/hostile string here would be interpolated directly into the server's model
        // prompt — this is what stands between that and the wire.
        XCTAssertNil(CloudParser.validatedTimezoneField("Asia/Ho Chi Minh"), "space is not allowed")
        XCTAssertNil(CloudParser.validatedTimezoneField("Asia/Ho_Chi_Minh\""), "quote is not allowed")
        XCTAssertNil(CloudParser.validatedTimezoneField("../../etc/passwd"), "dots are not allowed")
    }

    func testValidatedTimezoneFieldRejectsTooManySegments() {
        // The regex allows at most 3 slash-separated segments (1 + `{0,2}` repetitions) — a
        // 4-segment string must be rejected even though every individual character is legal.
        XCTAssertNil(CloudParser.validatedTimezoneField("A/B/C/D"))
    }

    // MARK: - `resolveCompletion` keeps using the same (now-fixed) formatter — a regression check
    // that the fix wasn't applied to `parseDetailed` alone. `resolveCompletion` itself performs
    // real networking so its full round trip isn't exercised here (see file header), but the
    // formatter it calls is the exact same `makeRequestFormatter()` covered by tests (1)/(2) above
    // — there is no second, un-fixed formatter anywhere in this file to regress to.
    func testOnlyOneRequestFormatterExistsInThisFile() {
        // This is intentionally a documentation-style assertion rather than a behavioral one: it
        // records that `resolveCompletion`'s `now` field is fixed FOR FREE by fixing
        // `makeRequestFormatter` once, since both call sites share the one function.
        XCTAssertEqual(
            CloudParser.makeRequestFormatter(timeZone: TimeZone(identifier: "UTC")!).string(from: Date(timeIntervalSince1970: 0)),
            "1970-01-01T00:00:00Z"
        )
    }

    // MARK: - `startTime` (2026-07-28: "làm task disposition code ngay lập tức" — no new task
    // "kind"/flag, just a new `startTime` field the server/on-device model reports for urgent
    // utterances, plus `IntentRouter.applyStartTimeDerivation` which derives a provisional
    // `deadline` from it). These tests live here per this task's own file-ownership instructions
    // (append to the pre-existing `CloudParserTests.swift` rather than adding a new test file),
    // even though `applyStartTimeDerivation` and the `RawParsedTask`/`ParsedTaskValidation` decode
    // path it covers are declared in `Sources/Parsing/IntentParsing.swift`, not `CloudParser.swift`
    // itself — both are still part of this same Parsing-tier ownership slice.
    //
    // Deliberately routes every fixture through `ParsedTaskValidation.validate(_:sourceTranscript:)`
    // (building a `RawParsedTask` — declared and fully owned in `IntentParsing.swift`) rather than
    // constructing a `ParsedTask` directly: `ParsedTask` itself is owned by a different, parallel
    // agent's file (`Sources/Model/NLParser.swift`, not touched here), so its exact stored-property
    // order (and therefore its memberwise-init argument order) is NOT something this file controls
    // or should guess at — going through `validate` sidesteps that entirely and only ever reads
    // `ParsedTask.startTime`/`.deadline`/`.title`/`.priority` by name.

    private func makeRawTask(
        title: String = "Test task",
        deadline: String? = nil,
        deadlineConfidence: Double = 0.9,
        startTime: String? = nil,
        startTimeConfidence: Double = 0.9,
        estimateMinutes: Double? = nil,
        priority: Int? = nil
    ) -> RawParsedTask {
        RawParsedTask(
            title: RawConfidence(value: title, confidence: 0.9),
            deadline: deadline.map { RawConfidence(value: $0, confidence: deadlineConfidence) },
            startTime: startTime.map { RawConfidence(value: $0, confidence: startTimeConfidence) },
            estimateMinutes: estimateMinutes.map { RawConfidence(value: $0, confidence: 0.9) },
            // `Double($0)`: `RawParsedTask.priority` became `RawConfidence<Double>?` on 2026-08-01 so
            // a fractional priority from the wire can't throw mid-decode and discard the whole
            // batch — this helper still takes a plain `Int` since every caller below writes a whole
            // number, and `validate` narrows it back with `Int(exactly:)`.
            priority: priority.map { RawConfidence(value: Double($0), confidence: 0.9) }
        )
    }

    // MARK: `IntentRouter.applyStartTimeDerivation`

    /// 1. `startTime` present, no `deadline` -> derived `deadline` = `startTime` + the 30-minute
    /// default (no `estimateMinutes` given).
    func testApplyStartTimeDerivationAddsDefaultThirtyMinuteDeadline() throws {
        let raw = makeRawTask(startTime: "2026-07-28T09:00:00+07:00")
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test")
        let startTime = try XCTUnwrap(task.startTime)

        let derived = try XCTUnwrap(IntentRouter.applyStartTimeDerivation([task]).first)

        let expected = try XCTUnwrap(
            Calendar.current.date(byAdding: .minute, value: 30, to: startTime.value)
        )
        XCTAssertEqual(derived.deadline?.value, expected)
    }

    /// 2. `startTime` + `estimateMinutes: 45` -> derived `deadline` = `startTime` + 45 minutes, NOT
    /// the 30-minute default (estimate wins over the default).
    func testApplyStartTimeDerivationPrefersEstimateMinutesOverDefault() throws {
        let raw = makeRawTask(startTime: "2026-07-28T09:00:00+07:00", estimateMinutes: 45)
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test")
        let startTime = try XCTUnwrap(task.startTime)
        XCTAssertEqual(task.estimateMinutes?.value, 45, "sanity: estimate must have survived validate()")

        let derived = try XCTUnwrap(IntentRouter.applyStartTimeDerivation([task]).first)

        let expected = try XCTUnwrap(
            Calendar.current.date(byAdding: .minute, value: 45, to: startTime.value)
        )
        XCTAssertEqual(derived.deadline?.value, expected)
    }

    /// 3. `startTime` + an ALREADY-PRESENT `deadline` -> completely untouched (e.g. "làm ngay, 5
    /// giờ chiều phải xong" — the explicit user-stated deadline must never be overwritten).
    func testApplyStartTimeDerivationLeavesExistingDeadlineUntouched() throws {
        let raw = makeRawTask(
            deadline: "2026-07-28T17:00:00+07:00",
            startTime: "2026-07-28T09:00:00+07:00"
        )
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test")
        let originalDeadline = try XCTUnwrap(task.deadline)

        let derived = try XCTUnwrap(IntentRouter.applyStartTimeDerivation([task]).first)

        XCTAssertEqual(derived.deadline?.value, originalDeadline.value)
        XCTAssertEqual(derived.deadline?.confidence, originalDeadline.confidence)
    }

    /// 4. No `startTime` at all -> the task returned by `applyStartTimeDerivation` is identical
    /// (not just deadline-equal) to the input — the ordinary, overwhelming-majority case must be a
    /// complete no-op.
    func testApplyStartTimeDerivationIsNoOpWithoutStartTime() throws {
        let raw = makeRawTask(deadline: "2026-07-28T17:00:00+07:00")
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test")

        let derived = try XCTUnwrap(IntentRouter.applyStartTimeDerivation([task]).first)

        XCTAssertEqual(derived, task)
    }

    /// 5. 2026-07-29 REVERSED (anh Khôi chốt — see `applyStartTimeDerivation`'s own comment in
    /// `IntentParsing.swift` for the full story): the derived deadline's confidence used to be
    /// deliberately UNDER `ParsedValue.isUncertain`'s `< 0.7` threshold so the confirm card required
    /// an explicit accept tap before it would commit. That broke the feature itself — a user who
    /// said "làm ngay lập tức" and just hit Save got a task with NO deadline persisted at all, since
    /// `AppState.resolvedValue` drops any uncertain, unaccepted value. Now the derived deadline must
    /// be confident ENOUGH to auto-commit on a plain Save (>= 0.7), and `deadlineIsEstimated` is the
    /// separate signal (`ParsedTask.deadlineIsEstimated`'s own doc comment) that lets the UI still
    /// mark it as a guess without gating it behind an accept.
    func testApplyStartTimeDerivationDeadlineConfidenceCommitsByDefaultAndIsFlaggedEstimated() throws {
        let raw = makeRawTask(startTime: "2026-07-28T09:00:00+07:00")
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test")

        let derived = try XCTUnwrap(IntentRouter.applyStartTimeDerivation([task]).first)
        let deadline = try XCTUnwrap(derived.deadline)

        XCTAssertGreaterThanOrEqual(
            deadline.confidence, 0.7,
            "must clear `ParsedValue.isUncertain`'s 0.7 bar so `AppState.resolvedValue` commits it " +
            "on a plain Save with no extra confirm-card tap — the whole point of this feature"
        )
        XCTAssertFalse(deadline.isUncertain)
        XCTAssertTrue(
            derived.deadlineIsEstimated,
            "a machine-derived deadline must be flagged so the confirm card can still label it as " +
            "a guess (e.g. \"· est\") even though it now auto-commits"
        )
    }

    /// A deadline the model/user ALREADY stated (not derived from `startTime`) must never be
    /// flagged `deadlineIsEstimated` — that flag means "this app guessed this," never "the user said
    /// this." Covers both `ParsedTaskValidation.validate` (which never sets the flag) and
    /// `applyStartTimeDerivation`'s own early-return guard (existing deadline -> completely
    /// untouched, flag included).
    func testExistingDeadlineIsNeverFlaggedAsEstimated() throws {
        let raw = makeRawTask(
            deadline: "2026-07-28T17:00:00+07:00",
            startTime: "2026-07-28T09:00:00+07:00"
        )
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test")
        XCTAssertFalse(task.deadlineIsEstimated, "sanity: validate() itself never sets this flag")

        let derived = try XCTUnwrap(IntentRouter.applyStartTimeDerivation([task]).first)
        XCTAssertFalse(
            derived.deadlineIsEstimated,
            "a deadline the user/model already stated must stay unflagged even after " +
            "applyStartTimeDerivation's no-op pass"
        )
    }

    /// An ordinary task with no `startTime` at all (the overwhelming common case) never touches
    /// `deadlineIsEstimated` — it stays at its `false` default.
    func testOrdinaryTaskWithoutStartTimeKeepsDeadlineIsEstimatedFalse() throws {
        let raw = makeRawTask(deadline: "2026-07-28T17:00:00+07:00")
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test")

        let derived = try XCTUnwrap(IntentRouter.applyStartTimeDerivation([task]).first)

        XCTAssertFalse(derived.deadlineIsEstimated)
    }

    // MARK: - `applyStartTimeDerivation` also fills in `estimateMinutes` (2026-07-29, anh Khôi
    // chốt — "cái 30ph là estimate trong setting của user ... task cứ default lấy từ setting ra cho
    // duration task"). ONE setting (`AppState.defaultTaskDurationMinutes`) now drives BOTH the
    // derived deadline AND the task's `estimateMinutes` when neither was supplied — these three
    // tests pin that down. `defaultMinutes` is passed explicitly (not read from `UserDefaults`) in
    // every case here, same as every test above: `applyStartTimeDerivation` stays a pure function of
    // its parameter, never reaching into global state itself (see that function's own doc comment) —
    // `IntentRouter.currentDefaultDurationMinutes()`, the piece that DOES read `UserDefaults`, is
    // exercised separately from `AppState`/Settings-owning code, not here.

    /// 1. No `estimateMinutes` given, `defaultMinutes: 45` -> derived deadline = `startTime` + 45',
    /// AND `estimateMinutes` itself becomes 45 (not left `nil`) — the deadline chip and the estimate
    /// chip must always show the same number.
    func testApplyStartTimeDerivationWithCustomDefaultAlsoFillsInEstimateMinutes() throws {
        let raw = makeRawTask(startTime: "2026-07-28T09:00:00+07:00")
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test")
        XCTAssertNil(task.estimateMinutes, "sanity: this fixture supplies no estimate")
        let startTime = try XCTUnwrap(task.startTime)

        let derived = try XCTUnwrap(
            IntentRouter.applyStartTimeDerivation([task], defaultMinutes: 45).first
        )

        let expectedDeadline = try XCTUnwrap(
            Calendar.current.date(byAdding: .minute, value: 45, to: startTime.value)
        )
        XCTAssertEqual(derived.deadline?.value, expectedDeadline)
        XCTAssertEqual(
            derived.estimateMinutes?.value, 45,
            "estimateMinutes must be filled in with the SAME number used for the derived deadline"
        )
    }

    /// 2. A task that ALREADY has `estimateMinutes` = 20 keeps it untouched even when
    /// `defaultMinutes` is a different number (45) — the user/model-stated estimate always wins over
    /// the setting default, and the derived deadline is computed from THAT estimate, not the default.
    func testApplyStartTimeDerivationPreservesExistingEstimateOverDefault() throws {
        let raw = makeRawTask(startTime: "2026-07-28T09:00:00+07:00", estimateMinutes: 20)
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test")
        let startTime = try XCTUnwrap(task.startTime)

        let derived = try XCTUnwrap(
            IntentRouter.applyStartTimeDerivation([task], defaultMinutes: 45).first
        )

        let expectedDeadline = try XCTUnwrap(
            Calendar.current.date(byAdding: .minute, value: 20, to: startTime.value)
        )
        XCTAssertEqual(derived.deadline?.value, expectedDeadline, "deadline must use the EXISTING estimate (20'), not the 45' default")
        XCTAssertEqual(derived.estimateMinutes?.value, 20, "an already-present estimate must never be overwritten by the default")
    }

    /// 3. The derived `estimateMinutes` must clear `ParsedValue.isUncertain`'s 0.7 bar, exactly like
    /// the derived `deadline` — otherwise `AppState.resolvedValue` silently drops it on a plain Save
    /// and `TaskItem.durationMinutes` ends up nil despite `deadline` having committed.
    func testApplyStartTimeDerivationEstimateMinutesConfidenceCommitsByDefault() throws {
        let raw = makeRawTask(startTime: "2026-07-28T09:00:00+07:00")
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test")

        let derived = try XCTUnwrap(IntentRouter.applyStartTimeDerivation([task]).first)
        let estimate = try XCTUnwrap(derived.estimateMinutes)

        XCTAssertGreaterThanOrEqual(
            estimate.confidence, 0.7,
            "must clear the 0.7 bar so a plain Save (no accept tap) still persists TaskItem.durationMinutes"
        )
        XCTAssertFalse(estimate.isUncertain)
    }

    // MARK: `ParsedTask` Codable — `deadlineIsEstimated` backward-compat (2026-07-29)
    //
    // `ParsedTask`'s `Codable` conformance is hand-rolled in `NLParser.swift` (not synthesized)
    // specifically because `deadlineIsEstimated` is a non-`Optional` `Bool` with a default value —
    // synthesized `Decodable` does NOT fall back to a property's default for a missing key (it only
    // gets that treatment for free on `Optional` properties). This test is the one thing standing
    // between that fact and a real regression: a payload encoded before this field existed (or any
    // hand-built JSON that simply omits it) must still decode successfully, defaulting to `false`.
    func testDecodeParsedTaskWithoutDeadlineIsEstimatedKeyDefaultsToFalse() throws {
        let json = """
        {
          "title": "Test task",
          "sourceTranscript": "test task"
        }
        """.data(using: .utf8)!

        let task = try JSONDecoder().decode(ParsedTask.self, from: json)

        XCTAssertEqual(task.title, "Test task")
        XCTAssertEqual(task.sourceTranscript, "test task")
        XCTAssertFalse(task.deadlineIsEstimated, "missing key must decode as false, never throw")
        // Sanity: every other defaulted field survives the same missing-key payload too (this
        // hand-rolled `init(from:)` covers all of them, not just `deadlineIsEstimated`).
        XCTAssertEqual(task.kind, .task)
        XCTAssertEqual(task.conditions, [])
        XCTAssertEqual(task.subtasks, [])
        XCTAssertFalse(task.followUpReview)
        XCTAssertNil(task.deadline)
        XCTAssertNil(task.startTime)
    }

    // MARK: `RawParsedTask` decode (`startTime` wire field)

    /// 6a. A response that DOES include `startTime` decodes it correctly.
    func testDecodeRawParsedTaskWithStartTimePresent() throws {
        let json = """
        {
          "title": {"value": "Test task", "confidence": 0.9},
          "startTime": {"value": "2026-07-28T09:00:00+07:00", "confidence": 0.85}
        }
        """.data(using: .utf8)!

        let raw = try JSONDecoder().decode(RawParsedTask.self, from: json)

        XCTAssertEqual(raw.startTime?.value, "2026-07-28T09:00:00+07:00")
        XCTAssertEqual(raw.startTime?.confidence, 0.85)
    }

    /// 6b. A response that does NOT include `startTime` (the old server shape, before this field
    /// existed, or simply a task where the model didn't emit one) must decode `startTime` as `nil`
    /// — never throw, never crash — while every other field decodes exactly as before. This is the
    /// concrete backward-compatibility check: an as-yet-undeployed server must not break the client.
    func testDecodeRawParsedTaskWithoutStartTimeDefaultsToNilOtherFieldsIntact() throws {
        let json = """
        {
          "title": {"value": "Test task", "confidence": 0.9},
          "deadline": {"value": "2026-07-28T17:00:00+07:00", "confidence": 0.8},
          "priority": {"value": 2, "confidence": 0.7}
        }
        """.data(using: .utf8)!

        let raw = try JSONDecoder().decode(RawParsedTask.self, from: json)

        XCTAssertNil(raw.startTime, "server not yet returning startTime must decode as nil, not fail")
        XCTAssertEqual(raw.title.value, "Test task")
        XCTAssertEqual(raw.deadline?.value, "2026-07-28T17:00:00+07:00")
        XCTAssertEqual(raw.priority?.value, 2)
    }

    // MARK: `ParsedTaskValidation.validate` per-attribute fallback for `startTime`

    /// 7a. A `startTime` that isn't valid ISO8601 must drop ONLY `startTime` — `title`/`deadline`/
    /// `priority` on the same task must all survive untouched (constitution II: "a parsing error on
    /// one attribute must not discard the others").
    func testValidateDropsOnlyMalformedStartTimeStringKeepingOtherFields() {
        let raw = makeRawTask(
            deadline: "2026-07-28T17:00:00+07:00",
            startTime: "not-a-valid-iso8601-string",
            priority: 1
        )

        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test transcript")

        XCTAssertNil(task.startTime)
        XCTAssertEqual(task.title, "Test task")
        XCTAssertEqual(task.deadline?.value, ParsedTaskValidation.parseISO8601("2026-07-28T17:00:00+07:00"))
        XCTAssertEqual(task.priority?.value, 1)
    }

    /// 7b. A `startTime` with an out-of-range confidence (outside 0...1) must likewise drop ONLY
    /// `startTime`, keeping every other field.
    func testValidateDropsStartTimeWithOutOfRangeConfidenceKeepingOtherFields() {
        let raw = makeRawTask(
            startTime: "2026-07-28T09:00:00+07:00",
            startTimeConfidence: 1.5,
            priority: 2
        )

        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test transcript")

        XCTAssertNil(task.startTime)
        XCTAssertEqual(task.title, "Test task")
        XCTAssertEqual(task.priority?.value, 2)
    }

    // MARK: - `reminderOverride` decode (2026-08-01 review findings)
    //
    // The bug these pin down: `RawParsedReminderOverride` had no `remindPeriodMinutes` field at
    // all, so the server's "nhắc tôi mỗi 15 phút" answer — which `_shared/gemini.ts` has a whole
    // prompt rule dedicated to producing, and `ReminderRecord.derive`/`PopoverView.reminderLabel`
    // both already consume — was silently dropped at the wire boundary. Nothing crashed and no
    // other field was affected, which is exactly why it went unnoticed: the user just quietly got
    // the app's default proportional cadence instead of the one they asked for out loud.

    private func makeRawReminderTask(
        offsetsMinutes: [Double] = [-60],
        repeatEveryMinutes: Double? = nil,
        remindPeriodMinutes: Double? = nil,
        confidence: Double = 0.9
    ) -> RawParsedTask {
        RawParsedTask(
            title: RawConfidence(value: "Test task", confidence: 0.9),
            reminderOverride: RawConfidence(
                value: RawParsedReminderOverride(
                    offsetsMinutes: offsetsMinutes,
                    repeatEveryMinutes: repeatEveryMinutes,
                    remindPeriodMinutes: remindPeriodMinutes
                ),
                confidence: confidence
            )
        )
    }

    /// `remindPeriodMinutes: 15` ("nhắc tôi mỗi 15 phút") must reach `ReminderPolicy.remindPeriod`
    /// as 900 SECONDS — the unit `ReminderRecord.derive` walks the deadline back by.
    func testValidateCarriesRemindPeriodMinutesIntoTheReminderPolicy() throws {
        let raw = makeRawReminderTask(remindPeriodMinutes: 15)

        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "nhắc tôi mỗi 15 phút")

        let policy = try XCTUnwrap(task.reminderOverride?.value)
        XCTAssertEqual(policy.remindPeriod, 15 * 60)
    }

    /// Absent `remindPeriodMinutes` (the overwhelmingly common case) stays `nil` — the app then
    /// falls back to its own proportional cadence, per `ReminderPolicy.remindPeriod`'s contract.
    func testValidateLeavesRemindPeriodNilWhenTheServerDidNotSendOne() throws {
        let raw = makeRawReminderTask()

        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test")

        let policy = try XCTUnwrap(task.reminderOverride?.value)
        XCTAssertNil(policy.remindPeriod)
    }

    /// `repeatEveryMinutes` (repeat AFTER the deadline) and `remindPeriodMinutes` (cadence BEFORE
    /// it) are different fields with different meanings — `_shared/schema.ts` says so explicitly.
    /// This pins that they never get crossed.
    func testValidateKeepsRepeatEveryAndRemindPeriodDistinct() throws {
        let raw = makeRawReminderTask(repeatEveryMinutes: 30, remindPeriodMinutes: 15)

        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test")

        let policy = try XCTUnwrap(task.reminderOverride?.value)
        XCTAssertEqual(policy.repeatEvery, 30 * 60)
        XCTAssertEqual(policy.remindPeriod, 15 * 60)
    }

    /// Offset sign is PRESERVED, not flipped: both the server (`offsetsMinutes`, "negative =
    /// before") and `ReminderPolicy.offsets` use the same convention, so a flip here would fire
    /// every reminder AFTER the deadline instead of before it.
    func testValidatePreservesNegativeOffsetSignInSeconds() throws {
        let raw = makeRawReminderTask(offsetsMinutes: [-60, -15])

        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test")

        let policy = try XCTUnwrap(task.reminderOverride?.value)
        XCTAssertEqual(policy.offsets, [-3600, -900])
    }

    /// An absurd-but-finite offset (the server bounds neither magnitude nor count) drops ITSELF and
    /// keeps its sane neighbours — same per-field fail-open rule as every other bound here.
    func testValidateDropsOnlyTheOutOfRangeOffsets() throws {
        let raw = makeRawReminderTask(offsetsMinutes: [-60, 1e15, .infinity, -30])

        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test")

        let policy = try XCTUnwrap(task.reminderOverride?.value)
        XCTAssertEqual(policy.offsets, [-3600, -1800])
    }

    /// A non-positive cadence would make `ReminderRecord.derive`'s walk-back loop meaningless —
    /// drop the cadence, keep the rest of the override.
    func testValidateDropsNonPositiveRemindPeriodKeepingOffsets() throws {
        let raw = makeRawReminderTask(offsetsMinutes: [-60], remindPeriodMinutes: 0)

        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test")

        let policy = try XCTUnwrap(task.reminderOverride?.value)
        XCTAssertNil(policy.remindPeriod)
        XCTAssertEqual(policy.offsets, [-3600])
    }

    // MARK: - Non-integer wire numbers must not discard the whole task (2026-08-01)
    //
    // `priority`/`everyDays` are decoded as `Double` and narrowed with `Int(exactly:)` precisely so
    // a fractional value can't throw inside `JSONDecoder` — that throw would abort the decode of the
    // ENTIRE `[RawParsedTask]` array in `parseDetailed`, losing every task in the batch over one bad
    // number. The server's own validator permits a non-integer `everyDays` (it checks only
    // `isFiniteNumber(...) > 0`), so this is reachable, not theoretical.

    func testValidateDropsFractionalPriorityKeepingTheTask() {
        let raw = RawParsedTask(
            title: RawConfidence(value: "Test task", confidence: 0.9),
            priority: RawConfidence(value: 2.4, confidence: 0.9)
        )

        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test transcript")

        XCTAssertNil(task.priority, "a fractional priority is a schema violation, never rounded")
        XCTAssertEqual(task.title, "Test task")
    }

    func testValidateDropsFractionalEveryDaysKeepingTheTask() {
        let raw = RawParsedTask(
            title: RawConfidence(value: "Test task", confidence: 0.9),
            recurrence: RawConfidence(
                value: RawParsedRecurrence(type: "every", everyDays: 2.5), confidence: 0.9
            )
        )

        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test transcript")

        XCTAssertNil(task.recurrence)
        XCTAssertEqual(task.title, "Test task")
    }

    func testValidateAcceptsWholeNumberEveryDays() throws {
        let raw = RawParsedTask(
            title: RawConfidence(value: "Test task", confidence: 0.9),
            recurrence: RawConfidence(
                value: RawParsedRecurrence(type: "every", everyDays: 3), confidence: 0.9
            )
        )

        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test transcript")

        XCTAssertEqual(try XCTUnwrap(task.recurrence?.value), .every(days: 3))
    }

    // MARK: - task_refs_v1 (anh Khôi, 2026-08-02 task-refs design)
    //
    // Everything below is exercised at the SAME layer every other test in this file already uses
    // for decode/validation coverage — `JSONDecoder` straight into the `Raw*` wire structs, then
    // `ParsedTaskValidation.validate`/`validateCapture` — never a live network call, for the exact
    // same reason the file header gives ("no `URLProtocol`-stub test infrastructure exists in this
    // target"). That reasoning also covers item (h) of this task's own test list — "assert the
    // request body includes `client_caps`": there is no seam here to intercept the actual
    // `URLRequest` `CloudParser.performParse` builds, so this file cannot assert on the wire body
    // directly. What CAN be pinned, and is, below: the capability string literal itself
    // (`CloudParser.taskRefsCapability`) never silently drifts from `"task_refs_v1"`, which is the
    // one thing `performParse`'s envelope-vs-bare-array decode fallback depends on matching the
    // server's own handshake (`_shared/schema.ts`) — see `testTaskRefsCapabilityWireLiteralIsStable`
    // near the end of this section.
    //
    // `RawParsedCondition(...)` below is ALWAYS constructed with every parameter passed explicitly
    // by name (never omitting `date`/`description`/`refIndex`/etc even where they're conceptually
    // irrelevant to a given fixture) — deliberately sidesteps any ambiguity about whether a bare
    // `Optional` stored property earns a default in Swift's synthesized memberwise initializer
    // (this file is written without a Swift toolchain to compile-check that assumption against).

    /// (a) The envelope shape decodes: 1 task + 1 ref + 1 update carrying `deadline`,
    /// `notesAppend`, and an `addConditions` entry pointing at the response's own `tasks[1]`.
    func testEnvelopeJSONDecodesTaskRefAndUpdateTogether() throws {
        let json = """
        {
          "tasks": [
            {"title": {"value": "New task", "confidence": 0.9}}
          ],
          "taskRefs": [
            {"titleQuery": {"value": "Old task", "confidence": 0.8}, "assumeExisting": true}
          ],
          "updates": [
            {
              "refIndex": 1,
              "set": {
                "deadline": {"value": "2026-08-02T10:00:00+07:00", "confidence": 0.9},
                "notesAppend": {"value": "extra note", "confidence": 0.85}
              },
              "addConditions": [
                {"kind": "taskDone", "newTaskIndex": 1}
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(RawParseEnvelope.self, from: json)
        let capture = ParsedTaskValidation.validateCapture(envelope, sourceTranscript: "test transcript")

        XCTAssertEqual(capture.tasks.count, 1)
        XCTAssertEqual(capture.tasks.first?.title, "New task")

        XCTAssertEqual(capture.taskRefs.count, 1)
        XCTAssertEqual(capture.taskRefs.first?.titleQuery, "Old task")
        XCTAssertEqual(capture.taskRefs.first?.assumeExisting, true)

        let update = try XCTUnwrap(capture.updates.first)
        XCTAssertEqual(capture.updates.count, 1)
        XCTAssertEqual(update.refIndex, 1)
        XCTAssertEqual(update.deadline?.value, ParsedTaskValidation.parseISO8601("2026-08-02T10:00:00+07:00"))
        XCTAssertEqual(update.notesAppend?.value, "extra note")
        XCTAssertEqual(update.addConditions, [.taskDoneNewTask(index: 1)])
    }

    /// An empty-title ref in the MIDDLE compacts `taskRefs`; `refIndex` (1-based into the raw array)
    /// must follow its ref to the compacted position, and an update aimed at the dropped ref is dropped.
    func testEmptyTitleTaskRefRemapsRefIndexAndDropsDeadUpdate() throws {
        let json = """
        {
          "tasks": [],
          "taskRefs": [
            {"titleQuery": {"value": "First", "confidence": 0.9}},
            {"titleQuery": {"value": "   ", "confidence": 0.9}},
            {"titleQuery": {"value": "Third", "confidence": 0.9}}
          ],
          "updates": [
            {"refIndex": 3, "set": {"notesAppend": {"value": "for third", "confidence": 0.9}}},
            {"refIndex": 2, "set": {"notesAppend": {"value": "for dropped", "confidence": 0.9}}}
          ]
        }
        """.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(RawParseEnvelope.self, from: json)
        let capture = ParsedTaskValidation.validateCapture(envelope, sourceTranscript: "t")
        XCTAssertEqual(capture.taskRefs.map(\.titleQuery), ["First", "Third"])
        XCTAssertEqual(capture.updates.count, 1)
        XCTAssertEqual(capture.updates.first?.refIndex, 2)
        XCTAssertEqual(capture.updates.first?.notesAppend?.value, "for third")
    }

    /// (b) A bare `[RawParsedTask]` array (today's shape, or an old/rolled-back server that never
    /// recognized `client_caps`) still decodes — as `ParsedCapture` with empty `taskRefs`/`updates`
    /// — the back-compat/rollback path `CloudParser.performParse` falls back to. Also pins the
    /// actual mechanism that fallback depends on: a bare JSON array can never satisfy
    /// `RawParseEnvelope`'s object-keyed container, so the envelope decode attempt fails cleanly
    /// (never partially/incorrectly parses array elements as envelope fields) and `performParse`
    /// moves on to the array decode.
    func testBareArrayResponseDecodesToCaptureWithEmptyRefsAndUpdates() throws {
        let json = """
        [
          {"title": {"value": "Task A", "confidence": 0.9}}
        ]
        """.data(using: .utf8)!

        XCTAssertThrowsError(
            try JSONDecoder().decode(RawParseEnvelope.self, from: json),
            "a bare array must never satisfy the object-keyed envelope decode"
        )

        let raws = try JSONDecoder().decode([RawParsedTask].self, from: json)
        let capture = ParsedCapture(
            tasks: ParsedTaskValidation.validateAll(raws, sourceTranscript: "test transcript"),
            taskRefs: [],
            updates: []
        )

        XCTAssertEqual(capture.tasks.count, 1)
        XCTAssertEqual(capture.tasks.first?.title, "Task A")
        XCTAssertTrue(capture.taskRefs.isEmpty)
        XCTAssertTrue(capture.updates.isEmpty)
    }

    /// (c) An update whose `refIndex` doesn't land inside the validated `taskRefs` is dropped
    /// WHOLE — never guessed at, never misapplied to the wrong (or no) ref — while the unrelated
    /// task and ref it arrived alongside are both kept untouched.
    func testUpdateWithOutOfRangeRefIndexIsDroppedKeepingTaskAndRef() throws {
        let json = """
        {
          "tasks": [{"title": {"value": "T1", "confidence": 0.9}}],
          "taskRefs": [{"titleQuery": {"value": "Ref1", "confidence": 0.8}}],
          "updates": [
            {"refIndex": 5, "set": {"priority": {"value": 2, "confidence": 0.8}}}
          ]
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(RawParseEnvelope.self, from: json)
        let capture = ParsedTaskValidation.validateCapture(envelope, sourceTranscript: "test transcript")

        XCTAssertEqual(capture.tasks.count, 1, "an unrelated update's own failure must not cost the task")
        XCTAssertEqual(capture.taskRefs.count, 1, "an unrelated update's own failure must not cost the ref")
        XCTAssertTrue(capture.updates.isEmpty, "refIndex 5 is out of range against a 1-element taskRefs")
    }

    /// (d) A fractional `priority` on an update drops ONLY that field — same per-attribute
    /// fail-open rule `ParsedTask.priority` itself already follows (`testValidateDropsFractional
    /// PriorityKeepingTheTask` above) — while `deadline` on the SAME `set` survives untouched.
    func testUpdatePriorityFractionalValueIsDroppedKeepingDeadline() throws {
        let json = """
        {
          "tasks": [{"title": {"value": "T1", "confidence": 0.9}}],
          "taskRefs": [{"titleQuery": {"value": "Ref1", "confidence": 0.8}}],
          "updates": [
            {
              "refIndex": 1,
              "set": {
                "deadline": {"value": "2026-08-02T10:00:00+07:00", "confidence": 0.9},
                "priority": {"value": 2.5, "confidence": 0.8}
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(RawParseEnvelope.self, from: json)
        let capture = ParsedTaskValidation.validateCapture(envelope, sourceTranscript: "test transcript")

        let update = try XCTUnwrap(capture.updates.first)
        XCTAssertNil(update.priority, "a fractional priority is a schema violation, never rounded")
        XCTAssertEqual(update.deadline?.value, ParsedTaskValidation.parseISO8601("2026-08-02T10:00:00+07:00"))
    }

    /// (e) A `taskDone` condition carrying `offsetMinutes` keeps its normal `.taskDone` condition
    /// (the existing dependency-blocking UI keeps working) AND gets a human-readable notes line —
    /// `ParsedCondition` (`Sources/Model/NLParser.swift`) has no structural field for the offset
    /// this round, so this is how the app avoids silently dropping what the user said about it.
    func testTaskDoneConditionWithOffsetMinutesKeepsConditionAndAddsNotesLine() throws {
        let raw = RawParsedTask(
            title: RawConfidence(value: "Test task", confidence: 0.9),
            conditions: [
                RawConfidence(
                    value: RawParsedCondition(
                        kind: "taskDone",
                        referenceTitle: "Old task",
                        date: nil,
                        description: nil,
                        refIndex: nil,
                        offsetMinutes: 120,
                        offsetKind: nil
                    ),
                    confidence: 0.8
                )
            ]
        )

        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test transcript")

        XCTAssertEqual(task.conditions.count, 1)
        guard case .taskDone(let titleQuery, _) = try XCTUnwrap(task.conditions.first) else {
            return XCTFail("expected .taskDone to survive alongside its offset note")
        }
        XCTAssertEqual(titleQuery, "Old task")
        XCTAssertEqual(task.notes, "Sau khi xong 'Old task' + 2h")
    }

    /// `offsetKind: "atLeast"` renders the "ít nhất" (at-least) wording instead of the exact "+"
    /// wording — the two must never read the same, since they mean different things to the user.
    func testTaskDoneConditionWithAtLeastOffsetKindUsesAtLeastWording() throws {
        let raw = RawParsedTask(
            title: RawConfidence(value: "Test task", confidence: 0.9),
            conditions: [
                RawConfidence(
                    value: RawParsedCondition(
                        kind: "taskDone",
                        referenceTitle: "Old task",
                        date: nil,
                        description: nil,
                        refIndex: nil,
                        offsetMinutes: 90,
                        offsetKind: "atLeast"
                    ),
                    confidence: 0.8
                )
            ]
        )

        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test transcript")

        XCTAssertEqual(task.notes, "Sau khi xong 'Old task' ít nhất 1h30p")
    }

    /// (f) A `taskStart` condition has NO structural representation this round at all (unlike
    /// `taskDone`, which at least keeps its condition even with an offset) — it must produce ZERO
    /// conditions and a notes line naming what was asked for and that it isn't supported yet, never
    /// a best-effort `.taskDone` substitute (which would silently misrepresent what the user said).
    func testTaskStartConditionProducesNoConditionButAddsNotesLine() throws {
        let raw = RawParsedTask(
            title: RawConfidence(value: "Test task", confidence: 0.9),
            conditions: [
                RawConfidence(
                    value: RawParsedCondition(
                        kind: "taskStart",
                        referenceTitle: "Other task",
                        date: nil,
                        description: nil,
                        refIndex: nil,
                        offsetMinutes: 120,
                        offsetKind: "atLeast"
                    ),
                    confidence: 0.8
                )
            ]
        )

        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test transcript")

        XCTAssertTrue(task.conditions.isEmpty, "taskStart never becomes a condition this round")
        XCTAssertEqual(task.notes, "Trước khi làm 'Other task' ít nhất 2h — chưa hỗ trợ tự nhắc")
    }

    /// A `taskStart` condition with NO `offsetMinutes` at all still produces a notes line (never
    /// silently dropped for lack of a number) — just without a duration clause.
    func testTaskStartConditionWithoutOffsetStillAddsNotesLine() throws {
        let raw = RawParsedTask(
            title: RawConfidence(value: "Test task", confidence: 0.9),
            conditions: [
                RawConfidence(
                    value: RawParsedCondition(
                        kind: "taskStart",
                        referenceTitle: "Other task",
                        date: nil,
                        description: nil,
                        refIndex: nil,
                        offsetMinutes: nil,
                        offsetKind: nil
                    ),
                    confidence: 0.8
                )
            ]
        )

        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test transcript")

        XCTAssertTrue(task.conditions.isEmpty)
        XCTAssertEqual(task.notes, "Trước khi làm 'Other task' — chưa hỗ trợ tự nhắc")
    }

    /// (g) `reminderOverride.anchor` (wire-first, client scope decision (c): decode-tolerate-and-
    /// ignore this round) must never fail the decode of the override it rides along on — every
    /// other field on that SAME override survives exactly as if `anchor` had never been sent. This
    /// exercises the pre-existing `RawParsedReminderOverride` (untouched by this task) directly,
    /// proving the "lenient decoder skips unknown keys" claim empirically rather than by inspection.
    func testReminderOverrideDecodeToleratesUnknownAnchorField() throws {
        let json = """
        {
          "title": {"value": "Test task", "confidence": 0.9},
          "reminderOverride": {
            "value": {
              "offsetsMinutes": [-60],
              "repeatEveryMinutes": 30,
              "anchor": {"refIndex": 1, "event": "done"}
            },
            "confidence": 0.8
          }
        }
        """.data(using: .utf8)!

        let raw = try JSONDecoder().decode(RawParsedTask.self, from: json)
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test transcript")

        let policy = try XCTUnwrap(task.reminderOverride?.value)
        XCTAssertEqual(policy.offsets, [-3600], "an unrecognized `anchor` key must not fail decode or drop its sibling fields")
        XCTAssertEqual(policy.repeatEvery, 30 * 60)
    }

    /// Same tolerance, but for `set.reminderOverride` on an UPDATE (`RawUpdateSet` doesn't even
    /// declare a `reminderOverride` stored property at all — see that struct's own doc comment) —
    /// an `anchor`-bearing `set.reminderOverride` must not fail the update's decode, and every OTHER
    /// field in that same `set` must still validate normally.
    func testUpdateSetReminderOverrideWithAnchorDoesNotFailTheUpdateDecode() throws {
        let json = """
        {
          "tasks": [{"title": {"value": "T1", "confidence": 0.9}}],
          "taskRefs": [{"titleQuery": {"value": "Ref1", "confidence": 0.8}}],
          "updates": [
            {
              "refIndex": 1,
              "set": {
                "priority": {"value": 2, "confidence": 0.8},
                "reminderOverride": {
                  "value": {"offsetsMinutes": [-900], "anchor": {"refIndex": 1, "event": "start"}},
                  "confidence": 0.7
                }
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(RawParseEnvelope.self, from: json)
        let capture = ParsedTaskValidation.validateCapture(envelope, sourceTranscript: "test transcript")

        let update = try XCTUnwrap(capture.updates.first)
        XCTAssertEqual(
            update.priority?.value, 2,
            "an unrecognized set.reminderOverride (anchor or not) must not fail the whole update"
        )
    }

    /// (h) See this section's own header comment above for why a real HTTP request body can't be
    /// asserted on in this file — this pins the one thing that CAN be: the capability literal
    /// itself never silently drifts from what the server's own handshake expects.
    func testTaskRefsCapabilityWireLiteralIsStable() {
        XCTAssertEqual(CloudParser.taskRefsCapability, "task_refs_v1")
    }

    // MARK: - task_cues_v1 (`specs/006-cues-and-waiting/design.md`, 2026-08-08)
    //
    // Same layer every other decode/validation test in this file already uses (`JSONDecoder`
    // straight into the `Raw*` wire structs, then `ParsedTaskValidation.validate`/
    // `.validateCapture` — never a live network call, see this file's own header). `now` is
    // passed explicitly and FIXED throughout so `TaskCue.createdAt`/`.expiresAt` are
    // deterministic to assert against, never a `Date()` read at test-run time.

    private static let cueTestNow = Date(timeIntervalSince1970: 1_800_000_000)

    /// task_cues_v1's wire capability literal never silently drifts — mirrors
    /// `testTaskRefsCapabilityWireLiteralIsStable` right above for the sibling cap.
    func testCuesCapabilityWireLiteralIsStable() {
        XCTAssertEqual(CloudParser.cuesCapability, "task_cues_v1")
    }

    /// Both caps are sent SIDE BY SIDE on every parse request, never one replacing the other —
    /// pins the exact literal array `performParse` builds (`CloudParser.swift`'s `client_caps`
    /// payload field), since there's no `URLRequest`-interception seam in this file to assert on
    /// the real wire body (same limitation this file's task_refs_v1 section documents for its own
    /// analogous "(h)" test).
    func testBothCapabilitiesAreDistinctStableLiterals() {
        XCTAssertNotEqual(CloudParser.taskRefsCapability, CloudParser.cuesCapability)
    }

    /// (a) All three `CueKind` values decode correctly: `wake`.
    func testDecodeCueWakeKind() throws {
        let json = """
        {
          "title": {"value": "Test feature", "confidence": 0.9},
          "cue": {"kind": "wake", "verbatim": "ngủ dậy thì test feature này"}
        }
        """.data(using: .utf8)!

        let raw = try JSONDecoder().decode(RawParsedTask.self, from: json)
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test", now: Self.cueTestNow)

        let cue = try XCTUnwrap(task.cue)
        XCTAssertEqual(cue.kind, .wake)
        XCTAssertEqual(cue.verbatim, "ngủ dậy thì test feature này")
        XCTAssertEqual(cue.createdAt, Self.cueTestNow)
        XCTAssertEqual(cue.expiresAt, TaskCue.defaultExpiry(from: Self.cueTestNow), "expiresAt must follow TaskCue's own pinned 48h default, never a second hand-rolled copy of that constant")
    }

    /// (a) `dayEnd`.
    func testDecodeCueDayEndKind() throws {
        let json = """
        {
          "title": {"value": "Read a book", "confidence": 0.9},
          "cue": {"kind": "dayEnd", "verbatim": "tối trước khi ngủ thì đọc sách"}
        }
        """.data(using: .utf8)!

        let raw = try JSONDecoder().decode(RawParsedTask.self, from: json)
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test", now: Self.cueTestNow)

        XCTAssertEqual(task.cue?.kind, .dayEnd)
        XCTAssertEqual(task.cue?.verbatim, "tối trước khi ngủ thì đọc sách")
    }

    /// (a) `unknown` — a machine-unresolvable anchor ("tới văn phòng thì...") is still a VALID,
    /// common cue (never dropped for being unresolvable — `CueKind.unknown`'s own doc comment).
    func testDecodeCueUnknownKind() throws {
        let json = """
        {
          "title": {"value": "Ask Nam", "confidence": 0.9},
          "cue": {"kind": "unknown", "verbatim": "tới văn phòng thì hỏi Nam"}
        }
        """.data(using: .utf8)!

        let raw = try JSONDecoder().decode(RawParsedTask.self, from: json)
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test", now: Self.cueTestNow)

        XCTAssertEqual(task.cue?.kind, .unknown)
        XCTAssertEqual(task.cue?.verbatim, "tới văn phòng thì hỏi Nam")
    }

    /// (b) An unrecognized `kind` string (schema drift, a future server value this client
    /// doesn't know yet) maps to `.unknown` — NEVER dropped, since `verbatim` (not `kind`) is
    /// the thing actually read back to the user.
    func testDecodeCueUnrecognizedKindMapsToUnknown() throws {
        let json = """
        {
          "title": {"value": "Test task", "confidence": 0.9},
          "cue": {"kind": "some_future_kind_this_client_does_not_know", "verbatim": "khi nào đó thì làm"}
        }
        """.data(using: .utf8)!

        let raw = try JSONDecoder().decode(RawParsedTask.self, from: json)
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test", now: Self.cueTestNow)

        XCTAssertEqual(task.cue?.kind, .unknown, "an unrecognized kind must map to .unknown, never be dropped")
        XCTAssertEqual(task.cue?.verbatim, "khi nào đó thì làm")
    }

    /// A `cue` object present but MISSING its `kind` key entirely (not just an unrecognized
    /// value) must ALSO map to `.unknown`, not throw — `RawParsedCue.kind` is `String?`
    /// specifically so an absent key never kills the decode.
    func testDecodeCueMissingKindKeyMapsToUnknown() throws {
        let json = """
        {
          "title": {"value": "Test task", "confidence": 0.9},
          "cue": {"verbatim": "một mốc nào đó"}
        }
        """.data(using: .utf8)!

        let raw = try JSONDecoder().decode(RawParsedTask.self, from: json)
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test", now: Self.cueTestNow)

        XCTAssertEqual(task.cue?.kind, .unknown)
        XCTAssertEqual(task.cue?.verbatim, "một mốc nào đó")
    }

    /// (c) Back-compat: a response with NO `cue` key at all (server hasn't redeployed
    /// task_cues_v1 yet, or a rollback) decodes `cue` as `nil` and leaves every OTHER field on
    /// the task completely untouched — the exact "server chưa deploy vẫn chạy y nguyên" contract
    /// this feature's own instruction requires a test for.
    func testDecodeMissingCueKeyDefaultsToNilOtherFieldsIntact() throws {
        let json = """
        {
          "title": {"value": "Test task", "confidence": 0.9},
          "deadline": {"value": "2026-08-08T17:00:00+07:00", "confidence": 0.8}
        }
        """.data(using: .utf8)!

        let raw = try JSONDecoder().decode(RawParsedTask.self, from: json)
        XCTAssertNil(raw.cue, "server not yet returning cue must decode as nil, not fail")

        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test", now: Self.cueTestNow)

        XCTAssertNil(task.cue)
        XCTAssertEqual(task.title, "Test task")
        XCTAssertEqual(task.deadline?.value, ParsedTaskValidation.parseISO8601("2026-08-08T17:00:00+07:00"))
    }

    /// (d) Empty `verbatim` drops the WHOLE cue (nothing worth surfacing) but keeps the task —
    /// mirrors every other per-attribute fail-open rule in this file.
    func testDecodeCueWithEmptyVerbatimDropsCueKeepsTask() throws {
        let json = """
        {
          "title": {"value": "Test task", "confidence": 0.9},
          "cue": {"kind": "wake", "verbatim": ""}
        }
        """.data(using: .utf8)!

        let raw = try JSONDecoder().decode(RawParsedTask.self, from: json)
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test", now: Self.cueTestNow)

        XCTAssertNil(task.cue, "empty verbatim carries nothing worth surfacing")
        XCTAssertEqual(task.title, "Test task", "the task itself must survive a dropped cue")
    }

    /// Whitespace-only `verbatim` is treated the same as empty — trimmed first, then dropped.
    func testDecodeCueWithWhitespaceOnlyVerbatimDropsCueKeepsTask() throws {
        let json = """
        {
          "title": {"value": "Test task", "confidence": 0.9},
          "cue": {"kind": "wake", "verbatim": "   "}
        }
        """.data(using: .utf8)!

        let raw = try JSONDecoder().decode(RawParsedTask.self, from: json)
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test", now: Self.cueTestNow)

        XCTAssertNil(task.cue)
        XCTAssertEqual(task.title, "Test task")
    }

    /// A `cue` object present but MISSING its `verbatim` key entirely (not just empty) must not
    /// throw through the whole decode — `RawParsedCue.verbatim` is `String?`, not `String`,
    /// specifically to guard against the "non-optional key throws the whole envelope" trap this
    /// repo has hit before (`RawParsedRecurrence.everyDays`, 2026-08-01).
    func testDecodeCueObjectMissingVerbatimKeyDropsCueKeepsTask() throws {
        let json = """
        {
          "title": {"value": "Test task", "confidence": 0.9},
          "cue": {"kind": "wake"}
        }
        """.data(using: .utf8)!

        let raw = try JSONDecoder().decode(RawParsedTask.self, from: json)
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test", now: Self.cueTestNow)

        XCTAssertNil(task.cue)
        XCTAssertEqual(task.title, "Test task")
    }

    /// Defensive length cap: a verbatim over 300 chars (`MAX_TASK_TITLE_CHARS` server-side) is
    /// TRUNCATED, never dropped entirely — the cue is still worth partially surfacing.
    func testDecodeCueVerbatimOverCapIsTruncatedNotDropped() throws {
        let longVerbatim = String(repeating: "a", count: 400)
        let raw = RawParsedTask(
            title: RawConfidence(value: "Test task", confidence: 0.9),
            cue: RawParsedCue(kind: "wake", verbatim: longVerbatim)
        )

        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test", now: Self.cueTestNow)

        let cue = try XCTUnwrap(task.cue)
        XCTAssertEqual(cue.verbatim.count, 300)
    }

    /// A cue NEVER becomes a `deadline`/`.afterDate` condition — the exact conflation
    /// 006-cues-and-waiting exists to fix. A task carrying both a real spoken deadline AND a cue
    /// on the SAME response must keep both, completely independent of each other.
    func testCueNeverBecomesDeadlineOrCondition() throws {
        let json = """
        {
          "title": {"value": "Meeting prep", "confidence": 0.9},
          "deadline": {"value": "2026-08-08T15:00:00+07:00", "confidence": 0.9},
          "cue": {"kind": "wake", "verbatim": "ngủ dậy thì chuẩn bị họp"}
        }
        """.data(using: .utf8)!

        let raw = try JSONDecoder().decode(RawParsedTask.self, from: json)
        let task = ParsedTaskValidation.validate(raw, sourceTranscript: "test", now: Self.cueTestNow)

        XCTAssertEqual(task.deadline?.value, ParsedTaskValidation.parseISO8601("2026-08-08T15:00:00+07:00"), "the real spoken deadline must survive untouched")
        XCTAssertEqual(task.cue?.verbatim, "ngủ dậy thì chuẩn bị họp")
        XCTAssertTrue(task.conditions.isEmpty, "a cue must never manifest as a .afterDate/.taskDone condition")
    }

    /// (e) Envelope carrying BOTH `task_refs_v1`-shape fields (`taskRefs`/`updates`) and a `cue`
    /// on its `tasks[]` entry AT THE SAME TIME still decodes correctly — the two caps are
    /// independent and neither one's presence should perturb the other's decode path.
    func testEnvelopeWithBothTaskRefsAndCueDecodeTogether() throws {
        let json = """
        {
          "tasks": [
            {
              "title": {"value": "New task", "confidence": 0.9},
              "cue": {"kind": "wake", "verbatim": "ngủ dậy thì làm task này"}
            }
          ],
          "taskRefs": [
            {"titleQuery": {"value": "Old task", "confidence": 0.8}}
          ],
          "updates": [
            {"refIndex": 1, "set": {"priority": {"value": 2, "confidence": 0.8}}}
          ]
        }
        """.data(using: .utf8)!

        let envelope = try JSONDecoder().decode(RawParseEnvelope.self, from: json)
        let capture = ParsedTaskValidation.validateCapture(envelope, sourceTranscript: "test transcript", now: Self.cueTestNow)

        XCTAssertEqual(capture.tasks.count, 1)
        XCTAssertEqual(capture.tasks.first?.cue?.kind, .wake)
        XCTAssertEqual(capture.tasks.first?.cue?.verbatim, "ngủ dậy thì làm task này")
        XCTAssertEqual(capture.taskRefs.count, 1)
        XCTAssertEqual(capture.taskRefs.first?.titleQuery, "Old task")
        XCTAssertEqual(capture.updates.count, 1)
        XCTAssertEqual(capture.updates.first?.priority?.value, 2)
    }

    /// `ParsedTask`'s hand-rolled `Codable` (`Model/NLParser.swift`) must round-trip `cue` through
    /// encode/decode, and a payload that PREDATES this field (or any hand-built JSON that simply
    /// omits it) must still decode, defaulting to `nil` — same "missing key never throws"
    /// contract `deadlineIsEstimated`'s own back-compat test pins down elsewhere in this file.
    func testParsedTaskCodableRoundTripsCueAndDefaultsToNilWhenMissing() throws {
        let cue = TaskCue(
            kind: .wake, verbatim: "ngủ dậy thì test", createdAt: Self.cueTestNow,
            expiresAt: TaskCue.defaultExpiry(from: Self.cueTestNow)
        )
        var task = ParsedTaskValidation.validate(
            RawParsedTask(title: RawConfidence(value: "Test task", confidence: 0.9)),
            sourceTranscript: "test", now: Self.cueTestNow
        )
        task.cue = cue

        let encoded = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(ParsedTask.self, from: encoded)
        XCTAssertEqual(decoded.cue, cue)

        let jsonWithoutCue = """
        {
          "title": "Test task",
          "sourceTranscript": "test task"
        }
        """.data(using: .utf8)!
        let decodedWithoutCue = try JSONDecoder().decode(ParsedTask.self, from: jsonWithoutCue)
        XCTAssertNil(decodedWithoutCue.cue, "missing cue key must decode as nil, never throw")
    }

    /// "remind me every 30 minutes" is a reminder cadence, not a duration estimate.
    func testReminderCadenceIsNotEstimate() {
        let parsed = HeuristicNLParser().parse("call mom remind me every 30 minutes")
        XCTAssertNil(parsed.estimateMinutes)
        XCTAssertEqual(parsed.reminderOverride?.value.repeatEvery, 1800)
    }
}
