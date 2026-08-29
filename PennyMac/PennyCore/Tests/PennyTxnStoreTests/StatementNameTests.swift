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

    func testUnderlyingAccountsHarvest() {
        let text = """
        Paytm Statement for
        Union Bank Of India - 49 Rs.44,119.16
        Canara Bank - 41 Rs.345
        Union Bank Of India - 49 Rs.102
        """
        XCTAssertEqual(StatementName.underlyingAccounts(in: text),
                       ["Union Bank Of India -49", "Canara Bank -41"])
        XCTAssertEqual(StatementName.underlyingAccounts(in: "just a normal statement"), [])
    }

    func testAllDigitsNameSurvives() {
        // Nothing nameable — must still return something non-empty, no extension.
        let out = StatementName.pretty("2026-01.csv")
        XCTAssertFalse(out.isEmpty)
        XCTAssertFalse(out.contains(".csv"))
    }
}
