import XCTest
@testable import PennyTxnStore

/// Sidebar/list labels must read like bank names, never technical filenames
/// (2026-08-29 request: "no csv, pdf or anything technical").
final class StatementNameTests: XCTestCase {

    func testPaytmUPIStatementFilename() {
        XCTAssertEqual(StatementName.pretty("Paytm_UPI_Statement_27_Aug'25_-_26_Aug'26.xlsx"),
                       "Paytm UPI")
    }

    func testPlainLowercaseCSV() {
        XCTAssertEqual(StatementName.pretty("chase.csv"), "Chase")
        XCTAssertEqual(StatementName.pretty("barclays.csv"), "Barclays")
    }

    func testUnderscoresAndExtensionGone() {
        let out = StatementName.pretty("acme_corp_expenses.pdf")
        XCTAssertEqual(out, "Acme Corp Expenses")
        XCTAssertFalse(out.contains(".pdf") || out.contains("_"))
    }

    func testAllDigitsNameSurvives() {
        // Nothing nameable — must still return something non-empty, no extension.
        let out = StatementName.pretty("2026-01.csv")
        XCTAssertFalse(out.isEmpty)
        XCTAssertFalse(out.contains(".csv"))
    }
}
