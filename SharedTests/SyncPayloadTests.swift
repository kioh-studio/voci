// Tests/SyncPayloadTests.swift — XCTest coverage for `Shared/Sync/SyncPayload.swift`: the
// `SyncDate` parse/format pair (client-contract.md §6) and the `TaskPayload` wire codec
// (client-contract.md §3.1's per-element shape).
//
// Group D (Test) — written against code already on disk by groups A/B/C
// (specs/008-sync/client-contract.md §0). Does NOT touch `Shared/Sync/*.swift` itself.
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here): confirm
// on Mac that `xcodebuild test` picks this file up and every assertion below still holds once
// compiled for real.
import XCTest
import Foundation
import VolarCore
@testable import Volar

final class SyncPayloadTests: XCTestCase {
    // MARK: - SyncDate.parse — client-contract.md §6: Postgres emits up to 6 fractional digits;
    // `ISO8601DateFormatter` accepts at most 3 and rejects the rest outright.

    /// A UTC instant built via `Calendar`/`DateComponents` (not via `SyncDate` itself — that would
    /// just be testing the implementation against itself) so the fixture is independent of the
    /// code under test. `2026-08-09T10:00:00Z` + 123ms.
    private func referenceInstant() -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let wholeSecond = utc.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 10, minute: 0, second: 0))!
        return wholeSecond.addingTimeInterval(0.123)
    }

    func testParseAcceptsSixFractionalDigitsWithNumericOffset() throws {
        // Postgres's actual emitted shape (client-contract.md §3.1's own example literal).
        let parsed = try XCTUnwrap(SyncDate.parse("2026-08-09T10:00:00.123456+00:00"))
        XCTAssertEqual(parsed.timeIntervalSince1970, referenceInstant().timeIntervalSince1970, accuracy: 0.001)
    }

    func testParseAcceptsSixFractionalDigitsWithZ() throws {
        let parsed = try XCTUnwrap(SyncDate.parse("2026-08-09T10:00:00.123456Z"))
        XCTAssertEqual(parsed.timeIntervalSince1970, referenceInstant().timeIntervalSince1970, accuracy: 0.001)
    }

    func testParseAcceptsNoFractionalPartAtAll() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let wholeSecond = utc.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 10, minute: 0, second: 0))!
        let parsedZ = try XCTUnwrap(SyncDate.parse("2026-08-09T10:00:00Z"))
        let parsedOffset = try XCTUnwrap(SyncDate.parse("2026-08-09T10:00:00+00:00"))
        XCTAssertEqual(parsedZ.timeIntervalSince1970, wholeSecond.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(parsedOffset.timeIntervalSince1970, wholeSecond.timeIntervalSince1970, accuracy: 0.001)
    }

    func testParseTruncatesRatherThanRoundsPastThreeDigits() throws {
        // .1239996 would ROUND to .124, but truncation (the documented behavior — "never round")
        // must land on .123.
        let parsed = try XCTUnwrap(SyncDate.parse("2026-08-09T10:00:00.1239996+00:00"))
        XCTAssertEqual(parsed.timeIntervalSince1970, referenceInstant().timeIntervalSince1970, accuracy: 0.001)
    }

    /// Postgres drops trailing zeros, so 1-2 digit fractions occur on the wire.
    func testParsePadsShortFractions() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let base = utc.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 10, minute: 0, second: 0))!.timeIntervalSince1970
        let cases: [(String, Double)] = [
            ("2026-08-09T10:00:00.12+00:00", 0.12),
            ("2026-08-09T10:00:00.5+00:00", 0.5),
            ("2026-08-09T10:00:00.120+00:00", 0.12),
            ("2026-08-09T10:00:00+00:00", 0)
        ]
        for (text, fraction) in cases {
            let parsed = try XCTUnwrap(SyncDate.parse(text), text)
            XCTAssertEqual(parsed.timeIntervalSince1970, base + fraction, accuracy: 0.0005, text)
        }
    }

    func testParseUnparseableStringReturnsNil() {
        XCTAssertNil(SyncDate.parse("not a timestamp at all"))
        XCTAssertNil(SyncDate.parse(""))
    }

    // MARK: - SyncDate.string(from:) round-trips through SyncDate.parse

    func testStringFromDateRoundTripsThroughParseWithinAMillisecond() throws {
        let original = referenceInstant()
        let wireString = SyncDate.string(from: original)
        let roundTripped = try XCTUnwrap(SyncDate.parse(wireString))
        XCTAssertEqual(roundTripped.timeIntervalSince1970, original.timeIntervalSince1970, accuracy: 0.001)
    }

    func testStringFromDateAlwaysEmitsExactlyThreeFractionalDigits() {
        // Contract: "Always emits exactly 3 fractional digits + `Z`." A sub-millisecond-precision
        // Date must still serialize to exactly 3 digits, not more.
        let subMillisecond = Date(timeIntervalSince1970: 1_785_000_000.123_456_789)
        let wireString = SyncDate.string(from: subMillisecond)
        let fractionalPart = wireString.split(separator: ".").last.map(String.init) ?? ""
        // Strip the trailing "Z"/offset to count only the digit run.
        let digitsOnly = fractionalPart.prefix { $0.isNumber }
        XCTAssertEqual(digitsOnly.count, 3, "expected exactly 3 fractional digits in \(wireString)")
    }

    // MARK: - TaskPayload round-trip — client-contract.md's own reason this type exists: a
    // field-for-field mirror of `TaskItem` that must reconstruct EVERY field, including all three
    // `Condition` kinds, `recurrence`, `reminderOverride`, `delegation`, `cue`, `parentId`, `frog`,
    // `switchAwayCount`.

    func testTaskPayloadRoundTripPreservesEveryField() {
        let parentId = UUID()
        let dependencyId = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let cue = TaskCue(
            kind: .wake,
            verbatim: "ngủ dậy thì làm cái này",
            createdAt: createdAt,
            expiresAt: TaskCue.defaultExpiry(from: createdAt)
        )
        let delegation = DelegationMeta(
            label: "AI đang xử lý",
            checkBackAt: Date(timeIntervalSince1970: 1_760_000_000),
            backoffStage: 1,
            cwdHint: "/repo/subdir",
            delegatedAt: Date(timeIntervalSince1970: 1_755_000_000)
        )
        let reminderOverride = ReminderPolicy(
            offsets: [0, -1800], repeatEvery: 900, fractionsRemaining: [0.5, 1.0 / 3.0], remindPeriod: 3600
        )

        let item = TaskItem(
            title: "full round trip task",
            details: "some details",
            priority: .high,
            status: .inProgress,
            deadline: Date(timeIntervalSince1970: 1_800_000_000),
            startTime: Date(timeIntervalSince1970: 1_799_000_000),
            conditions: [
                .taskDone(dependencyId),
                .afterDate(Date(timeIntervalSince1970: 1_720_000_000)),
                .external(description: "waiting on legal", satisfied: true),
            ],
            createdAt: createdAt,
            when: .now,
            durationMinutes: 45,
            frog: true,
            notes: "some notes",
            sourceTranscript: "verbatim spoken text",
            kind: .review,
            recurrence: .every(days: 5),
            reminderOverride: reminderOverride,
            resumeNote: "pick up here",
            switchAwayCount: 3,
            completedAt: Date(timeIntervalSince1970: 1_750_000_000),
            parentId: parentId,
            delegation: delegation,
            cue: cue
        )

        let payload = TaskPayload(item)
        let roundTripped = payload.asTaskItem
        XCTAssertEqual(roundTripped, item, "every field of TaskItem must survive TaskPayload round-trip")
    }

    func testTaskPayloadRoundTripPreservesEachRecurrenceCase() {
        for recurrence in [Recurrence.daily, .weekly, .monthly, .every(days: 9)] {
            var item = TaskItem(title: "recurring", priority: .medium, when: .later)
            item.recurrence = recurrence
            let roundTripped = TaskPayload(item).asTaskItem
            XCTAssertEqual(roundTripped.recurrence, recurrence)
        }
    }

    func testTaskPayloadRoundTripWithNoOptionalFieldsSet() {
        // The opposite extreme from the "everything set" test above — every optional field left
        // at its default (`nil`/empty) must also round-trip cleanly, not crash or substitute junk.
        let item = TaskItem(title: "bare task", priority: .low, when: .later)
        let roundTripped = TaskPayload(item).asTaskItem
        XCTAssertEqual(roundTripped, item)
    }

    // MARK: - JSON-level decode tolerance (client-contract.md/SyncPayload.swift header: "a payload
    // written by an OLDER or NEWER build... still decodes into *something* instead of taking down
    // the whole record")

    func testTaskPayloadDecodeToleratesMissingAndUnknownFields() throws {
        let id = UUID()
        let json: [String: Any] = [
            "id": id.uuidString,
            "createdAt": "2026-08-09T10:00:00.000000+00:00",
            // title, details, priority, status, conditions, frog, kind, switchAwayCount,
            // schemaVersion — all deliberately OMITTED to exercise every `decodeIfPresent`
            // fallback in `TaskPayload.init(from:)`.
            "somethingThisBuildHasNeverHeardOf": "must be ignored, not thrown on",
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoder = SyncCoding.makeDecoder()
        let payload = try decoder.decode(TaskPayload.self, from: data)

        XCTAssertEqual(payload.id, id)
        XCTAssertEqual(payload.title, "")
        XCTAssertEqual(payload.details, "")
        XCTAssertEqual(payload.priority, .medium)
        XCTAssertEqual(payload.status, .todo)
        XCTAssertEqual(payload.conditions, [])
        XCTAssertFalse(payload.frog)
        XCTAssertEqual(payload.kind, .task)
        XCTAssertEqual(payload.switchAwayCount, 0)
        XCTAssertEqual(payload.schemaVersion, 1)
        XCTAssertNil(payload.notes)
        XCTAssertNil(payload.recurrence)
    }

    func testTaskPayloadDecodeMissingIdThrowsRatherThanSubstitutingOne() {
        // Per the file's own doc comment: `id`/`title` are the only two fields with no safe
        // fallback — a genuinely missing `id` must throw so the caller (`SyncClient`'s per-row
        // lenient decode) can drop just this one row instead of inventing an identity for it.
        let json: [String: Any] = ["title": "no id here"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let decoder = SyncCoding.makeDecoder()
        XCTAssertThrowsError(try decoder.decode(TaskPayload.self, from: data))
    }
}
