// QueryValidatorTests — the validate/optimize stage: normalization (flatten,
// collapse, dedup, double-negation), structural errors, and contradiction detection.
import XCTest
import Foundation
@testable import PennyFinance
import PennyModel

final class QueryValidatorTests: XCTestCase {

    private func validated(_ q: Query) -> QueryValidator.Validated? {
        if case .success(let v) = QueryValidator.validate(q) { return v }
        return nil
    }

    func testNormalizeFlattensAndCollapses() {
        // all([all([a, b]), c]) ⇒ all([a, b, c])
        let a = Filter.tag(.salary), b = Filter.direction(.debit), c = Filter.currency(.gbp)
        let n = QueryValidator.normalize(.all([.all([a, b]), c]))
        XCTAssertEqual(n, .all([a, b, c]))
        // all([x]) ⇒ x ; not(not(x)) ⇒ x
        XCTAssertEqual(QueryValidator.normalize(.all([a])), a)
        XCTAssertEqual(QueryValidator.normalize(.not(.not(a))), a)
        // dedup
        XCTAssertEqual(QueryValidator.normalize(.all([a, a, b])), .all([a, b]))
    }

    func testStructuralErrors() {
        // topN(0) invalid
        if case .failure(let e) = QueryValidator.validate(Query(aggregate: .topN(0))) {
            XCTAssertEqual(e, .invalidTopN)
        } else { XCTFail() }
        // amount range lower > upper
        let badAmt = Query(filters: [.amount(ComparableRange(lowerBound: 100, upperBound: 10))])
        if case .failure(let e) = QueryValidator.validate(badAmt) { XCTAssertEqual(e, .invalidAmountRange) } else { XCTFail() }
        // date start > end
        let badDate = Query(filters: [.dateRange(CalendarDateRange(start: CalendarDate(year: 2026, month: 7, day: 1),
                                                                   end: CalendarDate(year: 2026, month: 6, day: 1)))])
        if case .failure(let e) = QueryValidator.validate(badDate) { XCTAssertEqual(e, .invalidDateRange) } else { XCTFail() }
    }

    func testContradictionsAreProvablyEmpty() {
        // two different accounts ANDed ⇒ nothing matches
        let twoAccts = Query(filters: [.account(AccountID("a")), .account(AccountID("b"))], aggregate: .count)
        XCTAssertEqual(validated(twoAccts)?.isEmpty, true)
        // debit AND credit ⇒ empty
        let twoDirs = Query(filters: [.direction(.debit), .direction(.credit)], aggregate: .count)
        XCTAssertEqual(validated(twoDirs)?.isEmpty, true)
        // a single, consistent query is not empty
        XCTAssertEqual(validated(Query(filters: [.direction(.debit)], aggregate: .count))?.isEmpty, false)
    }
}
