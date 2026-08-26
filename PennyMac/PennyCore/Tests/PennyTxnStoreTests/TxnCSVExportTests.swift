// TxnCSVExportTests — the deterministic export core (Fix 7).
import XCTest
@testable import PennyTxnStore

final class TxnCSVExportTests: XCTestCase {

    private func r(_ date: String, _ descr: String, merchant: String = "",
                   category: String = "", debit: Double = 0, credit: Double = 0,
                   balance: Double? = nil, currency: String = "GBP") -> TxnRow {
        let p = date.split(separator: "-").compactMap { Int($0) }
        return TxnRow(txnDate: date, month: String(date.prefix(7)), year: p[0],
                      monthNo: p[1], day: p[2], descr: descr, merchant: merchant,
                      category: category, debit: debit, credit: credit,
                      balance: balance, currency: currency, seq: 0)
    }

    func testHeaderAndRowShape() {
        let csv = TxnCSVExport.string(from: [
            r("2026-06-01", "TESCO", merchant: "Tesco", category: "Groceries",
              debit: 45.50, balance: 954.50),
        ])
        let lines = csv.split(separator: "\r\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines[0], "Date,Description,Merchant,Category,Money In,Money Out,Balance,Currency")
        // Debit fills Money Out; Money In (credit) is blank, not "0.00".
        XCTAssertEqual(lines[1], "2026-06-01,TESCO,Tesco,Groceries,,45.50,954.50,GBP")
    }

    func testCreditFillsMoneyInAndBlankBalance() {
        let csv = TxnCSVExport.string(from: [
            r("2026-06-05", "SALARY", category: "Income", credit: 2500),   // no balance
        ])
        let line = csv.split(separator: "\r\n")[1]
        XCTAssertEqual(line, "2026-06-05,SALARY,,Income,2500.00,,,GBP")
    }

    func testRFC4180QuotingOfCommasAndQuotes() {
        // A description with a comma and an embedded quote must be quoted, with
        // the inner quote doubled — or the CSV shifts columns / corrupts.
        let csv = TxnCSVExport.string(from: [
            r("2026-06-10", "AMAZON, MKTPLACE \"PRIME\"", debit: 12.99),
        ])
        let line = csv.split(separator: "\r\n")[1]
        XCTAssertTrue(line.contains("\"AMAZON, MKTPLACE \"\"PRIME\"\"\""),
                      "comma+quote field must be RFC-4180 quoted; got: \(line)")
    }

    func testTrailingNewlineAndRowCount() {
        let rows = [r("2026-06-01", "A", debit: 1), r("2026-06-02", "B", credit: 2)]
        let csv = TxnCSVExport.string(from: rows)
        XCTAssertTrue(csv.hasSuffix("\r\n"))
        // header + 2 rows + trailing terminator → 3 non-empty lines.
        let nonEmpty = csv.split(separator: "\r\n").count
        XCTAssertEqual(nonEmpty, 3)
    }

    func testUTF8BOMForExcel() {
        let data = TxnCSVExport.data(from: [r("2026-06-01", "CAFÉ", debit: 3.20)])
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF], "Excel needs a BOM to read £/accents")
    }

    func testEmptyLedgerIsHeaderOnly() {
        let csv = TxnCSVExport.string(from: [])
        XCTAssertEqual(csv, "Date,Description,Merchant,Category,Money In,Money Out,Balance,Currency\r\n")
    }
}
