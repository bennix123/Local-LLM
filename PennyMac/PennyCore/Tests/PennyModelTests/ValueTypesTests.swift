// ValueTypesTests — Currency, typed IDs, Direction, and ComparableRange:
// equality, hashing (dictionary/set use), Codable round-trips, and range
// containment (inclusive and exclusive bounds).
import XCTest
import Foundation
@testable import PennyModel

final class ValueTypesTests: XCTestCase {

    // MARK: Currency

    func testCurrencyConstantsAndCode() {
        XCTAssertEqual(Currency.gbp.code, "GBP")
        XCTAssertEqual(Currency.usd.code, "USD")
        XCTAssertEqual(Currency.eur.code, "EUR")
        XCTAssertEqual(Currency.inr.code, "INR")
        XCTAssertEqual(Currency("GBP"), .gbp, "same code ⇒ equal")
    }

    func testCurrencyHashableAndCodable() throws {
        XCTAssertEqual(Set([Currency.gbp, Currency("GBP"), Currency.usd]).count, 2, "dedupes by code")
        let decoded = try JSONDecoder().decode(Currency.self,
                                               from: try JSONEncoder().encode(Currency.eur))
        XCTAssertEqual(decoded, .eur)
    }

    // MARK: Typed IDs

    func testIdEqualityHashingAndCodable() throws {
        XCTAssertEqual(AccountID("a-1"), AccountID("a-1"))
        XCTAssertNotEqual(AccountID("a-1"), AccountID("a-2"))
        // Usable as dictionary keys.
        let byId: [TransactionID: Int] = [TransactionID("t1"): 1, TransactionID("t2"): 2]
        XCTAssertEqual(byId[TransactionID("t1")], 1)
        // Codable round-trip for each ID type.
        XCTAssertEqual(try roundTrip(StatementID("s-9")), StatementID("s-9"))
        XCTAssertEqual(try roundTrip(MerchantID("amazon")), MerchantID("amazon"))
        XCTAssertEqual(try roundTrip(CategoryID("groceries")), CategoryID("groceries"))
    }

    // MARK: Direction

    func testDirectionRawValuesCodableAndCases() throws {
        XCTAssertEqual(Direction.debit.rawValue, "debit")
        XCTAssertEqual(Direction.credit.rawValue, "credit")
        XCTAssertEqual(Direction.allCases, [.debit, .credit])
        XCTAssertEqual(try roundTrip(Direction.credit), .credit)
    }

    // MARK: ComparableRange

    func testRangeContainsInclusiveAndExclusive() {
        let over500 = ComparableRange<Decimal>(lowerBound: 500, lowerInclusive: false)  // "over £500"
        XCTAssertFalse(over500.contains(500))
        XCTAssertTrue(over500.contains(500.01))

        let atLeast500 = ComparableRange<Decimal>(lowerBound: 500)                       // inclusive
        XCTAssertTrue(atLeast500.contains(500))

        let under20 = ComparableRange<Decimal>(upperBound: 20, upperInclusive: false)    // "under £20"
        XCTAssertTrue(under20.contains(19.99))
        XCTAssertFalse(under20.contains(20))

        let between = ComparableRange<Decimal>(lowerBound: 20, upperBound: 100)          // "£20–£100"
        XCTAssertTrue(between.contains(20)); XCTAssertTrue(between.contains(100))
        XCTAssertTrue(between.contains(60)); XCTAssertFalse(between.contains(19.99))
        XCTAssertFalse(between.contains(100.01))

        let unbounded = ComparableRange<Decimal>()
        XCTAssertTrue(unbounded.contains(-1_000_000)); XCTAssertTrue(unbounded.contains(1_000_000))
    }

    func testRangeCodableRoundTrip() throws {
        let range = ComparableRange<Decimal>(lowerBound: 20, upperBound: 100,
                                             lowerInclusive: true, upperInclusive: false)
        let decoded = try roundTrip(range)
        XCTAssertEqual(decoded.lowerBound, 20)
        XCTAssertEqual(decoded.upperBound, 100)
        XCTAssertEqual(decoded.lowerInclusive, true)
        XCTAssertEqual(decoded.upperInclusive, false)
    }

    // MARK: helper

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(value))
    }
}
