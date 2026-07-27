// CalendarDateTests — the timezone-free calendar date (Amendment 01): chronological
// ordering, ISO "YYYY-MM-DD" Codable round-trip, and CalendarDateRange containment.
import XCTest
import Foundation
@testable import PennyModel

final class CalendarDateTests: XCTestCase {

    func testComparableOrdersChronologically() {
        let a = CalendarDate(year: 2026, month: 6, day: 15)
        let b = CalendarDate(year: 2026, month: 7, day: 1)
        let c = CalendarDate(year: 2027, month: 1, day: 1)
        XCTAssertTrue(a < b); XCTAssertTrue(b < c)
        XCTAssertEqual([c, a, b].sorted(), [a, b, c])
        XCTAssertEqual(CalendarDate(year: 2026, month: 6, day: 15), a)
    }

    func testCodableIsISOStringRoundTrip() throws {
        let date = CalendarDate(year: 2026, month: 6, day: 5)
        let data = try JSONEncoder().encode(date)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"2026-06-05\"", "zero-padded ISO string")
        XCTAssertEqual(try JSONDecoder().decode(CalendarDate.self, from: data), date)
    }

    func testCodableRejectsMalformed() {
        let bad = "\"2026/06/05\"".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(CalendarDate.self, from: bad))
    }

    func testRangeContainsInclusive() {
        let june = CalendarDateRange(start: CalendarDate(year: 2026, month: 6, day: 1),
                                     end: CalendarDate(year: 2026, month: 6, day: 30))
        XCTAssertTrue(june.contains(CalendarDate(year: 2026, month: 6, day: 1)), "start inclusive")
        XCTAssertTrue(june.contains(CalendarDate(year: 2026, month: 6, day: 30)), "end inclusive")
        XCTAssertTrue(june.contains(CalendarDate(year: 2026, month: 6, day: 15)))
        XCTAssertFalse(june.contains(CalendarDate(year: 2026, month: 5, day: 31)))
        XCTAssertFalse(june.contains(CalendarDate(year: 2026, month: 7, day: 1)))
    }

    func testRangeCodableRoundTrip() throws {
        let range = CalendarDateRange(start: CalendarDate(year: 2026, month: 6, day: 1),
                                      end: CalendarDate(year: 2026, month: 6, day: 30))
        let decoded = try JSONDecoder().decode(CalendarDateRange.self,
                                               from: try JSONEncoder().encode(range))
        XCTAssertEqual(decoded, range)
    }
}
