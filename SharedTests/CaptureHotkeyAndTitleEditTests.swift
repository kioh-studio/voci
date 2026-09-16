// Tests/CaptureHotkeyAndTitleEditTests.swift — XCTest coverage for the two hotkey/confirm-card
// fixes tracked by this task:
//   (1) `AppState.handleHotkey()` — the real ⌃⌥M / sidebar-mic / morning-frog-CTA entry point,
//       which (unlike the older `toggleCapture()`) SAVES a pending confirm card (`.parsed`)
//       instead of blowing it away for a fresh recording, and never answers a pending yes/no
//       question (voice-done confirm/no-match, cloud/server consent) on the user's behalf.
//   (2) `ConfirmDraft.editedTitle`/`effectiveTitle` + `AppState.updateDraftTitle(_:forDraft:)` —
//       the confirm card's title becomes editable before Save, without ever mutating the
//       underlying (contract-owned, "never mutated in place") `ParsedTask`.
//
// Deliberately PURE where possible, same split TourFlowTests.swift/ReminderSchedulerTests.swift
// already document: `AppState()`'s no-argument initializer degrades to the no-store fallback
// (`store: TaskStore? = nil`), which is exactly what every test below wants — none of this needs
// a real `TaskStore`, EventKit, or a live view hierarchy.
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here): not run
// against a real `VolarTests` bundle. Two access-control notes worth flagging explicitly:
//   - `pendingCloudConsent`/`pendingServerConsent` are `private(set) var` on `AppState` (private to
//     `AppState.swift`), so this file — a different source file — cannot set either directly, even
//     via `@testable import` (that only relaxes `internal`, not `private`). `testPendingCloudConsent
//     GuardBlocksHandleHotkey` below reaches `pendingCloudConsent == true` indirectly instead, by
//     calling the real (synchronous, pure-for-this-input) `finishRecording(transcript:)` path with
//     `cloudParseConsent` at its fresh-install default (`nil`) — the same "never asked yet" branch
//     `proceedToCapture` documents. `pendingServerConsent` has no equally simple synchronous trigger
//     (its only setter is inside `handleCaptureError`, reached from a real `SpeechCapture`/`GroqEngine`
//     error callback) — NOT covered here; flagged in the final report rather than left silently
//     untested.
//   - `AppState.cloudParseConsentKey` is `fileprivate` to `AppState.swift` — its literal string is
//     duplicated below as `Self.cloudParseConsentKey`, same "know the literal key, not the symbol"
//     approach `TourFlowTests.hasSeenTourKey` already uses for the same reason.
import XCTest
@testable import Volar

@MainActor
final class CaptureHotkeyAndTitleEditTests: XCTestCase {

    private static let cloudParseConsentKey = "volar.cloudParseConsent"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.cloudParseConsentKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.cloudParseConsentKey)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeParsedTask(title: String = "Buy milk", transcript: String = "buy milk") -> ParsedTask {
        ParsedTask(
            title: title,
            notes: nil,
            deadline: nil,
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

    // MARK: - handleHotkey(): captureState branching (no guard active)

    func testHandleHotkeyStopsWhileRecording() {
        let state = AppState()
        state.captureState = .recording

        state.handleHotkey()

        // `stopCapture()`'s "mic never actually started" branch: no `runningEngine`, so it just
        // backs out to `.idle` (see `stopCapture()`'s own doc comment) — the observable proof this
        // routed to stop-semantics rather than starting a second recording on top.
        XCTAssertEqual(state.captureState, .idle)
    }

    func testHandleHotkeySavesAPendingParsedDraftInsteadOfStartingAFreshRecording() {
        let state = AppState()
        let draft = ConfirmDraft(task: makeParsedTask())
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        state.handleHotkey()

        // `confirmSave()`'s no-store fallback inserts materialized items into `tasks` synchronously
        // and clears the confirm state — the opposite of what a fresh `startCapture()` would do
        // (which would reset `liveTranscript`/bump `captureSession`, leaving `confirmDrafts` alone).
        XCTAssertTrue(state.tasks.contains { $0.title == "Buy milk" }, "a hotkey press during .parsed must SAVE the pending draft, not discard it")
        XCTAssertTrue(state.confirmDrafts.isEmpty, "the saved draft must be cleared, same as a normal Save-button tap")
    }

    func testHandleHotkeyIsANoOpWhileParsing() {
        let state = AppState()
        state.captureState = .parsing

        state.handleHotkey()

        XCTAssertEqual(state.captureState, .parsing, "mid-flight parsing must not be disturbed by a stray hotkey press")
    }

    func testHandleHotkeyIsANoOpWhileSaving() {
        let state = AppState()
        state.captureState = .saving

        state.handleHotkey()

        XCTAssertEqual(state.captureState, .saving, "mid-flight saving must not be disturbed by a stray hotkey press")
    }

    func testHandleHotkeyStartsAFreshCaptureWhenIdle() {
        let state = AppState()
        XCTAssertEqual(state.captureState, .idle)

        state.handleHotkey()

        // `startCapture()`'s effects are engine/authorization-dependent (async), but it always
        // moves capture state off `.idle` synchronously as its first observable step.
        XCTAssertNotEqual(state.captureState, .idle, "an idle hotkey press must kick off a fresh capture")
    }

    func testHandleHotkeyStartsAFreshCaptureWhenDone() {
        let state = AppState()
        state.captureState = .done

        state.handleHotkey()

        XCTAssertNotEqual(state.captureState, .done)
    }

    func testHandleHotkeyStartsAFreshCaptureWhenError() {
        let state = AppState()
        state.captureState = .error

        state.handleHotkey()

        XCTAssertNotEqual(state.captureState, .error)
    }

    // MARK: - handleHotkey(): the four "pending yes/no question" guards

    func testVoiceDoneConfirmGuardBlocksHandleHotkey() {
        let state = AppState()
        state.captureState = .parsed
        state.voiceDoneConfirm = VoiceDoneConfirm(action: .complete, candidates: [])

        state.handleHotkey()

        XCTAssertEqual(state.captureState, .parsed, "a pending voice-done confirm must never be silently answered by a hotkey press")
        XCTAssertNotNil(state.voiceDoneConfirm)
    }

    func testVoiceDoneNoMatchGuardBlocksHandleHotkey() {
        let state = AppState()
        state.captureState = .parsed
        state.voiceDoneNoMatchTranscript = "mark the report done"

        state.handleHotkey()

        XCTAssertEqual(state.captureState, .parsed)
        XCTAssertEqual(state.voiceDoneNoMatchTranscript, "mark the report done")
    }

    /// Replaces `testPendingCloudConsentGuardBlocksHandleHotkey` (anh Khôi chốt 2026-09-06: cloud
    /// parsing is the default on every entry point, so `proceedToCapture` no longer pauses to ask
    /// and `pendingCloudConsent` is unreachable from this path). The `handleHotkey` guard that test
    /// exercised is untouched and still load-bearing for `pendingServerConsent`/`voiceDoneConfirm`;
    /// what is asserted here is the NEW contract — a fresh install's very first utterance goes
    /// straight to parsing instead of stopping on a privacy question.
    func testFirstCaptureOnAFreshInstallParsesWithoutAskingForCloudConsent() {
        let state = AppState()
        // Fresh install: `cloudParseConsent` reads nil (never answered) — see setUp's
        // `cloudParseConsentKey` cleanup.
        XCTAssertNil(state.cloudParseConsent)

        state.finishRecording(transcript: "buy milk tomorrow")

        XCTAssertFalse(state.pendingCloudConsent, "cloud parsing is the default now — the first capture must never stop to ask")
        XCTAssertEqual(state.captureState, .parsing, "the utterance must go straight into `runParse` instead of `.error`-as-consent-prompt")
    }

    // MARK: - ConfirmDraft.effectiveTitle

    func testEffectiveTitleFallsBackToParsedTitleWhenNeverEdited() {
        let draft = ConfirmDraft(task: makeParsedTask(title: "Buy milk"))
        XCTAssertNil(draft.editedTitle)
        XCTAssertEqual(draft.effectiveTitle, "Buy milk")
    }

    func testEffectiveTitleUsesTheTrimmedEditWhenPresent() {
        var draft = ConfirmDraft(task: makeParsedTask(title: "Buy milk"))
        draft.editedTitle = "  Buy oat milk  "
        XCTAssertEqual(draft.effectiveTitle, "Buy oat milk")
    }

    /// The title field wraps (`axis: .vertical`) so long voice-parsed titles stay readable, which
    /// means a Return that slips past `PopoverView`'s `.onKeyPress` interception would land in the
    /// text rather than saving. A task title is single-line by nature, so the break is flattened to
    /// a space here — the list must never render a title with a hole in it.
    func testEffectiveTitleFlattensNewlinesIntoSpaces() {
        var draft = ConfirmDraft(task: makeParsedTask(title: "Buy milk"))
        draft.editedTitle = "Buy oat milk
for the office"
        XCTAssertEqual(draft.effectiveTitle, "Buy oat milk for the office")
    }

    func testEffectiveTitleFallsBackWhenTheEditIsOnlyWhitespaceAndNewlines() {
        var draft = ConfirmDraft(task: makeParsedTask(title: "Buy milk"))
        draft.editedTitle = " 
  
 "
        XCTAssertEqual(draft.effectiveTitle, "Buy milk")
    }

    func testEffectiveTitleFallsBackToParsedTitleWhenEditIsBlank() {
        var draft = ConfirmDraft(task: makeParsedTask(title: "Buy milk"))
        draft.editedTitle = "   "
        XCTAssertEqual(draft.effectiveTitle, "Buy milk", "a whitespace-only edit must silently fall back, never block/blank the title")

        draft.editedTitle = ""
        XCTAssertEqual(draft.effectiveTitle, "Buy milk")
    }

    // MARK: - AppState.updateDraftTitle(_:forDraft:) — the value-type/array-mutation trap

    func testUpdateDraftTitleMutatesTheArrayElementInPlace() {
        let state = AppState()
        let draft = ConfirmDraft(task: makeParsedTask(title: "Buy milk"))
        state.confirmDrafts = [draft]

        state.updateDraftTitle("Buy oat milk", forDraft: draft.id)

        // The whole point of the test: reading back through `confirmDrafts` (the array `PopoverView`/
        // `materialize` actually observe), NOT through the local `draft` fixture above, which is a
        // value-type snapshot from before the mutation and must NOT have changed.
        XCTAssertEqual(state.confirmDrafts.first?.editedTitle, "Buy oat milk")
        XCTAssertEqual(state.confirmDrafts.first?.effectiveTitle, "Buy oat milk")
        XCTAssertNil(draft.editedTitle, "the original local `draft` value must be untouched — struct semantics")
    }

    func testUpdateDraftTitleForAnUnknownDraftIDIsANoOp() {
        let state = AppState()
        let draft = ConfirmDraft(task: makeParsedTask())
        state.confirmDrafts = [draft]

        state.updateDraftTitle("should not apply", forDraft: UUID())

        XCTAssertNil(state.confirmDrafts.first?.editedTitle)
    }

    // MARK: - materialize (via confirmSave): the saved TaskItem carries the edited title

    func testConfirmSaveMaterializesTheEditedTitleNotTheParsedOne() {
        let state = AppState()
        var draft = ConfirmDraft(task: makeParsedTask(title: "Buy milk"))
        draft.editedTitle = "Buy oat milk before 6pm"
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        state.confirmSave()

        XCTAssertTrue(state.tasks.contains { $0.title == "Buy oat milk before 6pm" })
        XCTAssertFalse(state.tasks.contains { $0.title == "Buy milk" })
    }

    func testConfirmSaveMaterializesTheParsedTitleWhenNeverEdited() {
        let state = AppState()
        let draft = ConfirmDraft(task: makeParsedTask(title: "Buy milk"))
        state.confirmDrafts = [draft]
        state.captureState = .parsed

        state.confirmSave()

        XCTAssertTrue(state.tasks.contains { $0.title == "Buy milk" })
    }
}
