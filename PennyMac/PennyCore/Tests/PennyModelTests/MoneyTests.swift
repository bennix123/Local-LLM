// MoneyTests — pins the value-object contract for `Money`: exact `Decimal`
// arithmetic (no `Double` precision loss), signed debit/credit semantics, the
// additive-identity + AdditiveArithmetic behaviour, signed ordering, and a
// lossless Codable round-trip via its POSIX-string encoding.
import XCTest
import Foundation
@testable import PennyModel

final class MoneyTests: XCTestCase {

    /// Exact `Decimal` from a string, POSIX-parsed (never a Double float literal,
    /// which would be imprecise).
    private func dec(_ s: String) -> Decimal {
        Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))!
    }

    func testInitializersAreEquivalent() {
        XCTAssertEqual(Money(decimal: dec("12.34")), Money(dec("12.34")))
        XCTAssertEqual(Money(decimal: 5).amount, Decimal(5))
    }

    func testSignedSemantics() {
        XCTAssertTrue(Money(dec("-5.00")).isDebit, "negative = money out")
        XCTAssertFalse(Money(dec("5.00")).isDebit, "positive = money in")
        XCTAssertFalse(Money.zero.isDebit, "zero is not a debit")
        XCTAssertEqual(Money(dec("-42.20")).magnitude, dec("42.20"), "magnitude is unsigned")
    }

    func testAdditiveArithmeticAndZero() {
        XCTAssertEqual(Money.zero.amount, Decimal(0))
        XCTAssertEqual(Money(dec("10.00")) + Money(dec("2.50")), Money(dec("12.50")))
        XCTAssertEqual(Money(dec("10.00")) - Money(dec("2.50")), Money(dec("7.50")))
        XCTAssertEqual(-Money(dec("10.00")), Money(dec("-10.00")), "unary negation flips sign")
        XCTAssertEqual(Money.zero + Money(dec("9.99")), Money(dec("9.99")), "zero is the additive identity")
        // reduce over the additive identity — the pattern the query engine will use.
        let sum = [Money(dec("1.10")), Money(dec("2.20")), Money(dec("3.30"))].reduce(.zero, +)
        XCTAssertEqual(sum, Money(dec("6.60")))
    }

    func testNoDoublePrecisionLoss() {
        // The canonical Double-precision trap: 0.1 + 0.2 must equal 0.3 exactly.
        let total = Money(dec("0.1")) + Money(dec("0.2"))
        XCTAssertEqual(total, Money(dec("0.3")))
        XCTAssertEqual(total.amount, dec("0.3"))
    }

    func testComparableOrdersBySignedValue() {
        XCTAssertTrue(Money(dec("-1000.00")) < Money(dec("5.00")),
                      "a large debit sorts below a small credit (signed ordering)")
        let sorted = [Money(dec("5.00")), Money(dec("-1000.00")), Money(dec("0.00"))].sorted()
        XCTAssertEqual(sorted, [Money(dec("-1000.00")), Money.zero, Money(dec("5.00"))])
    }

    func testCodableRoundTripIsLossless() throws {
        let cases = [dec("0.3"), dec("-42.20"), dec("12345678901234.56"),
                     dec("0.01"), dec("0"), dec("-0.00000001")]
        let enc = JSONEncoder(); let dec = JSONDecoder()
        for value in cases {
            let original = Money(decimal: value)
            let data = try enc.encode(original)
            let decoded = try dec.decode(Money.self, from: data)
            XCTAssertEqual(decoded, original, "round-trip must preserve \(value) exactly")
            XCTAssertEqual(decoded.amount, value)
        }
    }

    func testCodableEncodesAsStringNotDouble() throws {
        // The design choice: Money serializes as a locale-independent String, so no
        // encoder can route it through Double.
        let data = try JSONEncoder().encode(Money(decimal: dec("12.34")))
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"12.34\"")
    }
}
