// Tests/CloudFirstDefaultsAndBreakdownTests.swift — XCTest coverage for the three approved
// client changes:
//   (1) Cloud-first defaults: `AppState.speechEngineChoice`'s `init` fallback (`.groq`, was
//       `.appleOnDevice`) and `parseEnginePreference`'s `nil`-consent display default (`.cloud`,
//       was `.onDevice`) — proven for BOTH the never-persisted case (new default applies) and the
//       already-persisted case (existing choice is untouched).
//   (2) Onboarding cloud-consent toggle: `AppState.setParseEngine(_:)` — the exact method the new
//       onboarding step 3 toggle calls — persists to the SAME `cloudParseConsent` /
//       `cloudParseConsentKey` every other consent surface reads. (`OnboardingView` itself is a
//       SwiftUI view with no view-inspection harness in this codebase — see
//       `CaptureHotkeyAndTitleEditTests.swift`'s own precedent for testing the `AppState` method a
//       control calls rather than the control itself. Flagged UNVERIFIED at the rendering level in
//       the final report.)
//   (3) Real task breakdown: `AppState.openBreakdown(for:)` / `closeBreakdown()` /
//       `applyBreakdownFetchResult(_:heuristicFloor:session:)` / `saveBreakdown(_:)` — the
//       loading -> loaded -> saved and loading -> failed state transitions, the hard-coded-
//       heuristic-floor detection, and the stale-session guard. `applyBreakdownFetchResult` is
//       `AppState.swift`'s synchronous tail of the async `fetchBreakdown`, split out specifically
//       so these scenarios are testable with hand-built `[String]` arrays instead of a real
//       `IntentRouter.breakdown` round trip — same "split for testability" precedent
//       `TextCaptureTests.swift` documents for `applyTextCaptureParseResult`.
//
// Deliberately PURE, no networking anywhere in this file: `AppState()`'s no-argument initializer
// degrades to the no-store fallback, and every breakdown-state test below drives
// `applyBreakdownFetchResult` directly rather than awaiting `fetchBreakdown`'s real
// `_Concurrency.Task` (which would need a live `IntentRouter`/`CloudParser`/network).
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here): not run
// against a real `VolarTests` bundle. Two access-control/environment notes worth flagging:
//   - `speechEngineKey`/`cloudParseConsentKey` are `private`/`fileprivate` to `AppState.swift` —
//     their literal strings are duplicated below, same "know the literal key, not the symbol"
//     approach `TourFlowTests.hasSeenTourKey`/`CaptureHotkeyAndTitleEditTests.cloudParseConsentKey`
//     already use for the same reason.
//   - `AppState.openBreakdown(for:)`'s "signed out -> `.unavailable`, no network" test relies on
//     `ConfigParseCredentialProvider.isConfigured` (a real Keychain read, `KeychainStore
//     .loadSession()`) returning `false` on whatever machine runs this test bundle — true for any
//     account-less CI runner or fresh checkout, but if this Mac happens to have a real Volar
//     session already in its Keychain, that one test's precondition assumption would need
//     revisiting (flagged rather than silently assumed correct).
import XCTest
@testable import Volar

@MainActor
final class CloudFirstDefaultsAndBreakdownTests: XCTestCase {

    private static let speechEngineKey = "volar.speechEngine"
    private static let cloudParseConsentKey = "volar.cloudParseConsent"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.speechEngineKey)
        UserDefaults.standard.removeObject(forKey: Self.cloudParseConsentKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.speechEngineKey)
        UserDefaults.standard.removeObject(forKey: Self.cloudParseConsentKey)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeTask(title: String = "Launch landing page", notes: String? = nil) -> TaskItem {
        TaskItem(title: title, priority: .medium, when: .now, notes: notes)
    }

    // MARK: - (1) Cloud-first defaults: speechEngineChoice

    func testSpeechEngineChoiceDefaultsToGroqWhenNeverPersisted() {
        // Nothing written to `volar.speechEngine` (setUp cleared it) — a truly fresh install.
        let state = AppState()

        XCTAssertEqual(state.speechEngineChoice, .groq, "a user who has never picked an engine must now default to cloud (Groq), not Apple on-device")
    }

    func testSpeechEngineChoicePreservesAnExistingPersistedChoice() {
        // Simulates a returning user who previously picked Apple on-device in Settings — the
        // exact string `setSpeechEngine(.appleOnDevice)` would have written.
        UserDefaults.standard.set(SpeechEngineChoice.appleOnDevice.rawValue, forKey: Self.speechEngineKey)

        let state = AppState()

        XCTAssertEqual(state.speechEngineChoice, .appleOnDevice, "the new cloud-first default must only apply to the `??` fallback for a NEVER-persisted value — an explicit prior choice must survive untouched")
    }

    func testSpeechEngineChoicePreservesAnExistingExplicitCloudChoice() {
        UserDefaults.standard.set(SpeechEngineChoice.groq.rawValue, forKey: Self.speechEngineKey)

        let state = AppState()

        XCTAssertEqual(state.speechEngineChoice, .groq)
    }

    // MARK: - (1) Cloud-first defaults: parseEnginePreference

    func testParseEnginePreferenceDefaultsToCloudWhenNeverAsked() {
        // `cloudParseConsent` reads as `nil` (setUp cleared the key) — "never asked" per
        // `AppState.init`'s `UserDefaults.standard.object(forKey:) as? Bool`.
        let state = AppState()

        XCTAssertNil(state.cloudParseConsent, "sanity check: the underlying consent flag itself must still read nil/never-asked — only the DISPLAY default (`parseEnginePreference`) changes")
        XCTAssertEqual(state.parseEnginePreference, .cloud, "a user who has never answered the consent question must now see Cloud pre-highlighted in Settings, matching the new onboarding default")
    }

    func testParseEnginePreservesAnExplicitDecline() {
        UserDefaults.standard.set(false, forKey: Self.cloudParseConsentKey)

        let state = AppState()

        XCTAssertEqual(state.cloudParseConsent, false)
        XCTAssertEqual(state.parseEnginePreference, .onDevice, "an explicit prior decline (false, not nil) must NEVER be silently flipped to Cloud by the new default")
    }

    func testParseEnginePreservesAnExplicitOptIn() {
        UserDefaults.standard.set(true, forKey: Self.cloudParseConsentKey)

        let state = AppState()

        XCTAssertEqual(state.cloudParseConsent, true)
        XCTAssertEqual(state.parseEnginePreference, .cloud)
    }

    // MARK: - (1b) The gate the router actually reads (anh Khôi chốt 2026-09-06)

    // `parseEnginePreference` above is only the Settings DISPLAY default. The bit that decides
    // whether a request actually leaves the device is `DefaultCloudParseGate.isOptedIn()`, which
    // used to read `bool(forKey:)` — i.e. "never answered" behaved like "no". These two pin the
    // new rule: unset means yes, and an explicit decline still means no.

    func testCloudGateIsOptedInByDefaultWhenNeverAnswered() async {
        // setUp cleared `cloudParseConsentKey` — a fresh install.
        let allowed = await DefaultCloudParseGate().isOptedIn()

        XCTAssertTrue(allowed, "cloud parsing is the default on every entry point now — an unanswered consent key must not disable it")
    }

    func testCloudGateHonoursAnExplicitDecline() async {
        UserDefaults.standard.set(false, forKey: Self.cloudParseConsentKey)

        let allowed = await DefaultCloudParseGate().isOptedIn()

        XCTAssertFalse(allowed, "turning the parse engine to on-device in Settings/onboarding must still keep every transcript on the device")
    }

    // MARK: - (2) Onboarding consent toggle writes the SAME shared flag

    func testSetParseEngineCloudWritesTheSharedConsentKeyTrue() {
        let state = AppState()

        // This is the exact call the new onboarding step-3 toggle's "Continue" button makes
        // (`appState.setParseEngine(cloudConsentOn ? .cloud : .onDevice)`), and the exact call
        // `SettingsView`'s parse-engine picker already made before this change — proving both
        // surfaces (and now onboarding) drive the one shared flag, never a second one.
        state.setParseEngine(.cloud)

        XCTAssertEqual(state.cloudParseConsent, true)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Self.cloudParseConsentKey), "must persist to the SAME `cloudParseConsentKey` the router's `DefaultCloudParseGate.isOptedIn()` reads — not a second, independently-tracked consent bit")
    }

    func testSetParseEngineOnDeviceWritesTheSharedConsentKeyFalse() {
        let state = AppState()
        state.setParseEngine(.cloud)

        // Simulates the user flipping the pre-selected-ON onboarding toggle OFF before continuing.
        state.setParseEngine(.onDevice)

        XCTAssertEqual(state.cloudParseConsent, false)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: Self.cloudParseConsentKey))
        XCTAssertEqual(state.parseEnginePreference, .onDevice)
    }

    // MARK: - (3) Breakdown: openBreakdown(for:) / closeBreakdown()

    func testOpenBreakdownRecordsTheRealTaskAndOpensTheSheet() {
        let state = AppState()
        let task = makeTask(title: "Ship the release notes")

        state.openBreakdown(for: task)

        XCTAssertEqual(state.breakdownTask?.id, task.id, "the sheet must carry the REAL task that was right-clicked, not silently show unrelated/sample content")
        XCTAssertTrue(state.showBreakdown)
    }

    func testOpenBreakdownIsUnavailableWhenNotSignedIn() {
        // Fresh AppState: `cloudParseConsent` is nil AND (per this test bundle's environment,
        // see the file header's UNVERIFIED note) `ConfigParseCredentialProvider.isConfigured` is
        // false — the "not signed in" degrade-honestly case (Change 3, point 5). Crucially, this
        // must resolve SYNCHRONOUSLY to `.unavailable` — never spawn a network attempt, and never
        // show the hard-coded heuristic template as if it were real.
        let state = AppState()

        state.openBreakdown(for: makeTask())

        XCTAssertEqual(state.breakdownFetchState, .unavailable)
    }

    func testCloseBreakdownResetsTaskAndFetchState() {
        let state = AppState()
        state.openBreakdown(for: makeTask())

        state.closeBreakdown()

        XCTAssertNil(state.breakdownTask, "every dismissal path (`TaskBreakdownView.onDisappear`) must clear the task so the next open can never inherit a stale one")
        XCTAssertEqual(state.breakdownFetchState, .idle)
    }

    func testTriageBreakdownRoutesThroughTheSameRealTaskEntryPoint() {
        // `AppState.triageBreakdown(_:)` (`TriageView`'s "Break down" action) used to just set
        // `showBreakdown = true` with no per-task target — the same bug the context-menu call
        // sites had. It must now go through `openBreakdown(for:)` like everything else.
        let state = AppState()
        let task = makeTask(title: "Renew the domain")

        state.triageBreakdown(task)

        XCTAssertEqual(state.breakdownTask?.id, task.id)
        XCTAssertTrue(state.showBreakdown)
    }

    // MARK: - (3) Breakdown: applyBreakdownFetchResult — the fetch's synchronous tail

    func testApplyBreakdownFetchResultLoadedWithRealSteps() {
        let state = AppState()
        state.breakdownFetchState = .loading

        state.applyBreakdownFetchResult(
            ["Draft the outline", "Write the first section", "Proofread"],
            heuristicFloor: ["Gather what's needed for X", "Start the first small piece", "Work through the middle of it", "Check the result", "Wrap up X"],
            session: 0 // fresh AppState's untouched `breakdownSession` — see file header note.
        )

        guard case .loaded(let steps) = state.breakdownFetchState else {
            return XCTFail("expected .loaded, got \(state.breakdownFetchState)")
        }
        XCTAssertEqual(steps.map(\.title), ["Draft the outline", "Write the first section", "Proofread"])
        XCTAssertEqual(steps.map(\.id), [0, 1, 2], "step ids must preserve the router's ordering")
    }

    func testApplyBreakdownFetchResultFailsOnEmptySteps() {
        let state = AppState()
        state.breakdownFetchState = .loading

        state.applyBreakdownFetchResult([], heuristicFloor: [], session: 0)

        XCTAssertEqual(state.breakdownFetchState, .failed)
    }

    func testApplyBreakdownFetchResultFailsWhenResultMatchesTheHardCodedHeuristicFloor() {
        // Simulates the exact failure mode `fetchBreakdown`'s doc comment warns about: cloud
        // preconditions were met, but the live call failed at request time, so `router.breakdown`
        // silently fell back to `HeuristicNLParser`'s fixed template. That template must NEVER be
        // shown as if it were a real, generated-for-this-task breakdown.
        let state = AppState()
        state.breakdownFetchState = .loading
        let hardCodedTemplate = [
            "Gather what's needed for Launch landing page",
            "Start the first small piece",
            "Work through the middle of it",
            "Check the result",
            "Wrap up Launch landing page",
        ]

        state.applyBreakdownFetchResult(hardCodedTemplate, heuristicFloor: hardCodedTemplate, session: 0)

        XCTAssertEqual(state.breakdownFetchState, .failed, "content identical to the hard-coded heuristic floor must never be presented as a real breakdown")
    }

    func testApplyBreakdownFetchResultIgnoresAStaleSession() {
        let state = AppState()
        state.breakdownFetchState = .loading

        // Any session other than the untouched fresh-`AppState` value (0) is stale by
        // construction — mirrors a user closing the sheet (`closeBreakdown()` bumps the counter)
        // while an earlier fetch was still in flight.
        state.applyBreakdownFetchResult(["Some step"], heuristicFloor: [], session: 999)

        XCTAssertEqual(state.breakdownFetchState, .loading, "a stale result must be dropped, not applied on top of whatever the sheet is doing now")
    }

    // MARK: - (3) Breakdown: loaded -> saved, and that a failed fetch leaves nothing saveable

    func testSavingALoadedBreakdownPersistsTheRealStepsAndResetsState() {
        let state = AppState()
        let task = makeTask(title: "Launch landing page")
        state.openBreakdown(for: task) // -> .unavailable in this test environment (not signed in)

        // Directly drive the loaded state (bypassing the unreachable-in-tests network call) to
        // exercise the SAME `saveBreakdown(_:)` a real success would call — proving it persists
        // the real titles, not the OLD hard-coded 5-row sample ("Open Framer", …).
        state.applyBreakdownFetchResult(
            ["Open Framer", "Draft the real headline"],
            heuristicFloor: [],
            session: 0
        )
        guard case .loaded(let steps) = state.breakdownFetchState else {
            return XCTFail("setup failed to reach .loaded")
        }

        state.saveBreakdown(steps.map(\.title))

        XCTAssertTrue(state.tasks.contains { $0.title == "Open Framer" })
        XCTAssertTrue(state.tasks.contains { $0.title == "Draft the real headline" })
        XCTAssertFalse(state.showBreakdown, "saving must close the sheet")
        XCTAssertNil(state.breakdownTask, "saving must reset the breakdown task so the next open starts clean")
        XCTAssertEqual(state.breakdownFetchState, .idle)
    }

    func testAFailedFetchLeavesNothingForSaveBreakdownToPersist() {
        // `TaskBreakdownView`'s Save button is `.disabled(!isSaveEnabled)`, and `isSaveEnabled`
        // is `false` for every `breakdownFetchState` except `.loaded` with a non-empty array —
        // this proves the STATE a `.failed` fetch leaves behind offers nothing to save, i.e. the
        // button-disabled condition the view expresses is backed by real state, not just a UI
        // flag. (The SwiftUI `.disabled(...)` binding itself is UNVERIFIED at the rendering level
        // — no Xcode/simulator here — this is the state-machine half of that guarantee.)
        let state = AppState()
        state.breakdownFetchState = .loading

        state.applyBreakdownFetchResult([], heuristicFloor: [], session: 0)

        if case .loaded = state.breakdownFetchState {
            XCTFail("a failed fetch must never leave `breakdownFetchState` as `.loaded`")
        }
    }
}
