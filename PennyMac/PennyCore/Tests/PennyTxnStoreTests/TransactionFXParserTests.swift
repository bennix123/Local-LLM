// TransactionFXParserTests — best-effort FX from a transaction description
// (Task 0.5, Decision 2): populate only what's explicitly present, never fabricate.
import XCTest
import Foundation
@testable import PennyTxnStore
import PennyModel

final class TransactionFXParserTests: XCTestCase {

    private func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }

    func testExtractsForeignAmountCurrencyRateCountry() {
        let fx = TransactionFXParser.fx(from: "LE PETIT BISTRO PARIS €42.00 @ 0.86 FR")
        XCTAssertEqual(fx?.originalAmount.amount, dec("42.00"))
        XCTAssertEqual(fx?.originalCurrency, .eur)
        XCTAssertEqual(fx?.rate, dec("0.86"))
        XCTAssertEqual(fx?.country, "FR")
    }

    func testIsoCodeForm() {
        let fx = TransactionFXParser.fx(from: "AMAZON USD 50.00")
        XCTAssertEqual(fx?.originalAmount.amount, dec("50.00"))
        XCTAssertEqual(fx?.originalCurrency, .usd)
    }

    func testNilWhenNoForeignAmountPresent() {
        // A bare country code with no foreign amount can't build FXInfo (honest nil).
        XCTAssertNil(TransactionFXParser.fx(from: "LE PETIT BISTRO PARIS FR"))
        XCTAssertNil(TransactionFXParser.fx(from: "TESCO STORES 2481 LONDON"))
    }
}
