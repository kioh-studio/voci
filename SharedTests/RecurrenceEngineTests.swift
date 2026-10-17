import XCTest
@testable import Volar

final class RecurrenceEngineTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ day: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 3, day: day, hour: 9))!
    }

    private func next(deadline: Date, completedAt: Date) -> Date? {
        RecurrenceEngine.reset(
            recurrence: .weekly, deadline: deadline, conditions: [], completedAt: completedAt, calendar: cal
        ).deadline
    }

    func testWeeklyCompletedEarlyAdvancesOneWeek() {
        XCTAssertEqual(next(deadline: date(10), completedAt: date(8)), date(17))
    }

    func testWeeklyCompletedOnTimeAdvancesOneWeek() {
        XCTAssertEqual(next(deadline: date(10), completedAt: date(10)), date(17))
    }

    func testWeeklyCompletedFiveDaysLateLandsInFuture() {
        XCTAssertEqual(next(deadline: date(10), completedAt: date(15)), date(17))
    }
}
