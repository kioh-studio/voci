// Tests/TourFlowTests.swift — XCTest coverage for the guided coach-mark tour's pure state machine
// (`AppState`'s `tourActive`/`tourStepIndex`/`hasSeenTour`/`startTourIfNeeded`/`replayTour`/
// `tourNext`/`tourBack`/`endTour`) and `TourOverlay.cardOrigin`'s pure placement math
// (`Sources/Views/Tour/TourModel.swift` / `TourOverlay.swift`).
//
// Deliberately PURE, mirroring `ReminderSchedulerTests.swift`'s own split between store-backed and
// pure-model tests: nothing here touches `TaskStore`, EventKit (`CalendarAccess`), or a live view
// hierarchy. `AppState()`'s no-argument initializer already degrades to the no-store fallback (see
// `AppState.init`'s `store: TaskStore? = nil` default), which is exactly what every test below
// wants — the tour's own state machine has no dependency on tasks existing at all.
//
// UNVERIFIED (written entirely on Windows — no Xcode/xcodegen/simulator available here): not run
// against a real `VolarTests` bundle. `setUp`/`tearDown`'s `UserDefaults` cleanup is the one thing
// that matters for correctness across REPEATED local runs (see `hasSeenTour`'s own persistence —
// without it, a second run of this file would see `hasSeenTour == true` left over from the first),
// but the actual XCTest bundle wiring itself (`VolarTests` target in `project.yml`) is the same
// still-unconfirmed-on-Mac gap `ReminderSchedulerTests.swift`'s own header already flags. Also
// inherited from that file: `AppState.init` (called plainly, `AppState()`, by every test below —
// the same no-store/no-argument construction every `#Preview` in this codebase already uses) kicks
// off `startAccountLifecycle()`, a fire-and-forget `_Concurrency.Task` that awaits real
// `Entitlements`/`AccountService` actor calls in the background. None of it is awaited here (every
// assertion below only reads synchronously-set properties), but confirm on Mac this doesn't hang or
// flake the `VolarTests` bundle when run offline/unsigned.
import XCTest
@testable import Volar

@MainActor
final class TourFlowTests: XCTestCase {

    /// The exact `UserDefaults` key `AppState` persists `hasSeenTour` under (private to that file,
    /// so duplicated here rather than exposed — same "know the literal key, not a symbol" approach
    /// `ReminderSchedulerTests.swift`'s own fixtures don't need since none of ITS persisted keys
    /// are exercised across test runs the way this one is).
    // `nonisolated`: read from non-isolated `setUp`/`tearDown` under Swift 6 (CI 2026-10-11).
    private nonisolated static let hasSeenTourKey = "volar.hasSeenTourV1"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.hasSeenTourKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.hasSeenTourKey)
        super.tearDown()
    }

    // MARK: - TourStop.all

    func testAllHasFourStopsAndOnlyTheLastIsFinal() {
        let stops = TourStop.all
        XCTAssertEqual(stops.count, 4)
        for (index, stop) in stops.enumerated() {
            XCTAssertEqual(stop.isFinal, index == stops.count - 1, "only the LAST stop (index \(stops.count - 1)) may be final; \(stop.id) at index \(index) disagrees")
        }
    }

    func testEveryStopHasNonEmptyTitleAndBody() {
        for stop in TourStop.all {
            XCTAssertFalse(stop.title.isEmpty, "\(stop.id) has an empty title")
            XCTAssertFalse(stop.body.isEmpty, "\(stop.id) has an empty body")
        }
    }

    func testOnlyTheFocusStopDeclaresAFallbackAnchor() {
        // Contract: `.focusPrimary`/`.focusFallback` are a pair for exactly one stop (the "Start
        // focus" button only renders once a task is NOW-eligible; the frog pill's "Focus" button
        // is what a brand-new/empty-task user actually sees instead) — every other stop's anchor
        // either always renders unconditionally or doesn't exist at all (the calendar stop).
        let withFallback = TourStop.all.filter { $0.fallbackAnchor != nil }
        XCTAssertEqual(withFallback.map(\.id), ["focus"])
    }

    func testCalendarStopHasNoAnchor() {
        XCTAssertNil(TourStop.all.last?.anchor)
        XCTAssertNil(TourStop.all.last?.fallbackAnchor)
    }

    // MARK: - startTourIfNeeded / replayTour

    func testStartTourIfNeededActivatesOnAFreshInstall() {
        let state = AppState()
        XCTAssertFalse(state.hasSeenTour, "a fresh install (cleaned UserDefaults key) must never report the tour already seen")
        XCTAssertFalse(state.tourActive)

        state.startTourIfNeeded()

        XCTAssertTrue(state.tourActive)
        XCTAssertEqual(state.tourStepIndex, 0)
    }

    func testStartTourIfNeededNoOpsOnceAlreadySeen() {
        let state = AppState()
        state.startTourIfNeeded()
        state.endTour() // marks hasSeenTour and deactivates, per endTour's own contract below
        XCTAssertTrue(state.hasSeenTour)

        state.startTourIfNeeded()

        XCTAssertFalse(state.tourActive, "startTourIfNeeded must stay a no-op once the tour has already been seen")
    }

    func testReplayTourAlwaysRestartsEvenAfterAlreadySeen() {
        let state = AppState()
        state.startTourIfNeeded()
        state.tourNext()
        state.endTour()
        XCTAssertTrue(state.hasSeenTour)
        XCTAssertFalse(state.tourActive)

        state.replayTour()

        XCTAssertTrue(state.tourActive, "replayTour must restart unconditionally, unlike startTourIfNeeded")
        XCTAssertEqual(state.tourStepIndex, 0, "replayTour must always restart from the FIRST stop")
    }

    // MARK: - tourNext / tourBack

    func testTourNextAdvancesThroughEveryStop() {
        let state = AppState()
        state.startTourIfNeeded()

        for expectedIndex in 1..<TourStop.all.count {
            state.tourNext()
            XCTAssertEqual(state.tourStepIndex, expectedIndex)
            XCTAssertTrue(state.tourActive, "must still be active before the LAST stop's own Next")
        }
    }

    func testTourNextPastTheLastStopEndsTheTour() {
        let state = AppState()
        state.startTourIfNeeded()
        for _ in 0..<(TourStop.all.count - 1) {
            state.tourNext()
        }
        XCTAssertEqual(state.tourStepIndex, TourStop.all.count - 1, "sanity: now on the final stop")

        state.tourNext()

        XCTAssertFalse(state.tourActive, "advancing past the final stop must end the tour")
        XCTAssertEqual(state.tourStepIndex, 0, "endTour must reset the index, not leave it out of range")
        XCTAssertTrue(state.hasSeenTour)
    }

    func testTourBackClampsAtZero() {
        let state = AppState()
        state.startTourIfNeeded()
        XCTAssertEqual(state.tourStepIndex, 0)

        state.tourBack()

        XCTAssertEqual(state.tourStepIndex, 0, "tourBack must clamp at 0, never go negative")
    }

    func testTourBackReturnsToThePreviousStop() {
        let state = AppState()
        state.startTourIfNeeded()
        state.tourNext()
        state.tourNext()
        XCTAssertEqual(state.tourStepIndex, 2)

        state.tourBack()

        XCTAssertEqual(state.tourStepIndex, 1)
    }

    // MARK: - endTour

    func testEndTourResetsIndexDeactivatesAndPersistsHasSeenTour() {
        let state = AppState()
        state.startTourIfNeeded()
        state.tourNext()

        state.endTour()

        XCTAssertFalse(state.tourActive)
        XCTAssertEqual(state.tourStepIndex, 0)
        XCTAssertTrue(state.hasSeenTour)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Self.hasSeenTourKey), "endTour must persist the seen flag, not just flip the in-memory property")
    }

    func testASecondAppStateInstanceObservesThePersistedHasSeenTour() {
        // Mirrors the real launch flow: `endTour()` on one `AppState` (this run) must be visible to
        // the NEXT `AppState` construction (the next launch) via `UserDefaults`, not just in-memory.
        let first = AppState()
        first.startTourIfNeeded()
        first.endTour()

        let second = AppState()

        XCTAssertTrue(second.hasSeenTour)
    }

    // MARK: - tourStop

    func testTourStopReflectsTheCurrentIndex() {
        let state = AppState()
        state.startTourIfNeeded()
        XCTAssertEqual(state.tourStop?.id, TourStop.all[0].id)

        state.tourNext()

        XCTAssertEqual(state.tourStop?.id, TourStop.all[1].id)
    }

    // MARK: - TourOverlay.cardOrigin (pure placement math)

    private let bounds = CGSize(width: 900, height: 600)
    private let cardSize = CGSize(width: 300, height: 200)

    func testCardOriginCentersWhenThereIsNoAnchor() {
        let origin = TourOverlay.cardOrigin(for: nil, cardSize: cardSize, in: bounds)

        XCTAssertEqual(origin.x, (bounds.width - cardSize.width) / 2)
        XCTAssertEqual(origin.y, (bounds.height - cardSize.height) / 2)
    }

    func testCardOriginPlacesBelowARectNearTheTop() {
        let rect = CGRect(x: 400, y: 40, width: 120, height: 40) // maxY = 80, well under 60% of 600
        let origin = TourOverlay.cardOrigin(for: rect, cardSize: cardSize, in: bounds)

        XCTAssertEqual(origin.y, rect.maxY + 14, "must sit BELOW the rect when there's room beneath it")
        XCTAssertGreaterThanOrEqual(origin.x, 16)
        XCTAssertLessThanOrEqual(origin.x + cardSize.width, bounds.width - 16)
    }

    func testCardOriginPlacesAboveARectNearTheBottom() {
        let rect = CGRect(x: 400, y: 520, width: 120, height: 40) // maxY = 560, over 60% of 600
        let origin = TourOverlay.cardOrigin(for: rect, cardSize: cardSize, in: bounds)

        XCTAssertEqual(origin.y, rect.minY - 14 - cardSize.height, "must sit ABOVE the rect once there's no room beneath it")
    }

    func testCardOriginClampsHorizontallyForARectAtTheLeftEdge() {
        let rect = CGRect(x: -20, y: 40, width: 60, height: 40)
        let origin = TourOverlay.cardOrigin(for: rect, cardSize: cardSize, in: bounds)

        XCTAssertGreaterThanOrEqual(origin.x, 16, "must never render partially off the LEFT edge")
    }

    func testCardOriginClampsHorizontallyForARectAtTheRightEdge() {
        let rect = CGRect(x: bounds.width - 40, y: 40, width: 60, height: 40)
        let origin = TourOverlay.cardOrigin(for: rect, cardSize: cardSize, in: bounds)

        XCTAssertLessThanOrEqual(origin.x + cardSize.width, bounds.width - 16, "must never render partially off the RIGHT edge")
    }

    func testCardOriginStaysInBoundsForARectInEveryCorner() {
        let corners: [CGRect] = [
            CGRect(x: -20, y: -20, width: 50, height: 30), // top-left
            CGRect(x: bounds.width - 30, y: -20, width: 50, height: 30), // top-right
            CGRect(x: -20, y: bounds.height - 10, width: 50, height: 30), // bottom-left
            CGRect(x: bounds.width - 30, y: bounds.height - 10, width: 50, height: 30), // bottom-right
        ]

        for rect in corners {
            let origin = TourOverlay.cardOrigin(for: rect, cardSize: cardSize, in: bounds)
            XCTAssertGreaterThanOrEqual(origin.x, 0, "corner \(rect) produced a negative x")
            XCTAssertGreaterThanOrEqual(origin.y, 0, "corner \(rect) produced a negative y")
            XCTAssertLessThanOrEqual(origin.x + cardSize.width, bounds.width, "corner \(rect) overflowed the right edge")
            XCTAssertLessThanOrEqual(origin.y + cardSize.height, bounds.height, "corner \(rect) overflowed the bottom edge")
        }
    }

    func testCardOriginDoesNotCrashOnADegenerateTinyWindow() {
        // The window a real card would never fit in without margins — must degrade to centering,
        // never divide-by-zero/produce NaN or an inverted (max < min) clamp range.
        let tinyBounds = CGSize(width: 100, height: 100)
        let origin = TourOverlay.cardOrigin(for: CGRect(x: 10, y: 10, width: 20, height: 20), cardSize: cardSize, in: tinyBounds)

        XCTAssertFalse(origin.x.isNaN)
        XCTAssertFalse(origin.y.isNaN)
    }
}
