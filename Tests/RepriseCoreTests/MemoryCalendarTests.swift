import XCTest
@testable import RepriseCore

final class MemoryCalendarTests: XCTestCase {
    func testLocalDayHandlesBothDSTBoundariesAndMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        let fall = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))!
        let spring = calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 12))!
        XCTAssertEqual(MemoryCalendar.dayRange(containing: fall, calendar: calendar).upperBound.timeIntervalSince(MemoryCalendar.dayRange(containing: fall, calendar: calendar).lowerBound), 25 * 3600)
        XCTAssertEqual(MemoryCalendar.dayRange(containing: spring, calendar: calendar).upperBound.timeIntervalSince(MemoryCalendar.dayRange(containing: spring, calendar: calendar).lowerBound), 23 * 3600)
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13))!
        let range = MemoryCalendar.dayRange(containing: midnight, calendar: calendar)
        XCTAssertTrue(range.contains(midnight))
        XCTAssertFalse(range.contains(midnight.addingTimeInterval(-1)))
        XCTAssertFalse(range.contains(range.upperBound))
    }
}
