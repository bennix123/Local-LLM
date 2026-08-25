import XCTest
@testable import PennyTxnStore

/// A1 — the four general router-fix classes, using the FINDINGS.md failures as
/// regression cases: phantom targets (class 1), missing group-by capabilities
/// (class 2), keyword-triggered refunds (class 3), amount literals (class 4).
final class RouterGeneralFixTests: XCTestCase {

    private func row(_ seq: Int, date: String, descr: String, merchant: String = "",
                     category: String = "Shopping", debit: Double = 0, credit: Double = 0) -> TxnRow {
        let parts = date.split(separator: "-")
        return TxnRow(txnDate: date, month: "\(parts[0])-\(parts[1])", year: Int(parts[0]) ?? 2026,
                      monthNo: Int(parts[1]) ?? 1, day: Int(parts[2]) ?? 1,
                      descr: descr, merchant: merchant.isEmpty ? descr : merchant, category: category,
                      debit: debit, credit: credit, balance: nil, currency: "GBP", seq: seq)
    }

    private var rows: [TxnRow] {
        [row(1, date: "2026-05-03", descr: "ZARA", debit: 120),
         row(2, date: "2026-05-10", descr: "TESCO", category: "Groceries", debit: 55),
         row(3, date: "2026-05-28", descr: "SALARY ACME CORP", category: "Income", credit: 3000),
         row(4, date: "2026-06-04", descr: "ZARA", debit: 80),
         row(5, date: "2026-06-05", descr: "ZARA REFUND", merchant: "ZARA", credit: 40),
         row(6, date: "2026-06-12", descr: "TESCO", category: "Groceries", debit: 6200),
         row(7, date: "2026-06-25", descr: "SALARY ACME CORP", category: "Income", credit: 3000)]
    }

    private let money: (Double) -> String = { "£" + String(format: "%.2f", $0) }

    private func ask(_ q: String) -> String? {
        FinanceRouter.answer(q, rows: rows, currency: "GBP", money: money)
    }

    // MARK: class 1 — no phantom targets

    func testEachMonthIsNotAMerchant() throws {
        let ans = try XCTUnwrap(ask("How much do I spend each month?"))
        XCTAssertFalse(ans.contains("on Each"), "grammar word became a target: \(ans)")
        XCTAssertTrue(ans.contains("May 2026") && ans.contains("Jun 2026"),
                      "should be a month-by-month breakdown: \(ans)")
    }

    func testAcrossAllAccountsIsNotAMerchant() throws {
        let ans = try XCTUnwrap(ask("How much did I spend across all accounts?"))
        XCTAssertFalse(ans.contains("on Accounts"), "\(ans)")
        XCTAssertTrue(ans.contains("£6455.00") || ans.contains("6455") || ans.contains("6,455"),
                      "should be the real total: \(ans)")
    }

    func testGenuineAbsentMerchantStillHonestZero() throws {
        let ans = try XCTUnwrap(ask("How much did I spend at Ferrari?"))
        XCTAssertTrue(ans.contains("Ferrari") && ans.contains("£0.00"), "\(ans)")
    }

    // MARK: class 2 — group-by capabilities

    func testTopMerchantAggregatesAcrossVisits() throws {
        let ans = try XCTUnwrap(ask("What is my top merchant by spend?"))
        // TESCO total 6255 beats ZARA 200 — and the single-largest-expense branch
        // (which would answer £6,200 alone) must not have caught this.
        XCTAssertTrue(ans.contains("TESCO"), "\(ans)")
        XCTAssertTrue(ans.contains("£6255.00"), "aggregate, not single expense: \(ans)")
    }

    func testTopThreeMerchantsList() throws {
        let ans = try XCTUnwrap(ask("Top 3 merchants"))
        XCTAssertTrue(ans.contains("1.") && ans.contains("TESCO") && ans.contains("ZARA"), "\(ans)")
    }

    func testMonthlyBreakdownFigures() throws {
        let ans = try XCTUnwrap(ask("Give me a monthly breakdown"))
        XCTAssertTrue(ans.contains("May 2026") && ans.contains("£175.00"), "\(ans)")
        XCTAssertTrue(ans.contains("Jun 2026") && ans.contains("£6280.00"), "\(ans)")
    }

    // MARK: class 3 — refunds by evidence

    func testSalaryIsNeverARefund() throws {
        let ans = try XCTUnwrap(ask("How much did I get in refunds?"))
        XCTAssertTrue(ans.contains("£40.00"), "only the ZARA return credit: \(ans)")
        XCTAssertFalse(ans.contains("6,040") || ans.contains("3,000"),
                       "salary credits must not count: \(ans)")
    }

    func testNoEvidenceMeansNoRefunds() throws {
        let salaryOnly = [row(1, date: "2026-06-25", descr: "SALARY ACME CORP",
                              category: "Income", credit: 3000),
                          row(2, date: "2026-06-26", descr: "TESCO", category: "Groceries", debit: 50)]
        let ans = try XCTUnwrap(FinanceRouter.answer("Any refunds?", rows: salaryOnly,
                                                     currency: "GBP", money: money))
        XCTAssertTrue(ans.contains("No refunds"), "\(ans)")
    }

    // MARK: class 4 — amount literals

    func testCommaSeparatedThreshold() throws {
        let ans = try XCTUnwrap(ask("Show transactions over 5,000"))
        XCTAssertTrue(ans.contains("£6200.00"), "\(ans)")
        XCTAssertFalse(ans.contains("£120.00"), "threshold must be 5000, not 5: \(ans)")
    }

    func testKSuffixThreshold() throws {
        let ans = try XCTUnwrap(ask("Any transactions above 5k?"))
        XCTAssertTrue(ans.contains("£6200.00"), "\(ans)")
        XCTAssertFalse(ans.contains("£120.00"), "\(ans)")
    }

    func testLakhSuffixThreshold() throws {
        let ans = try XCTUnwrap(ask("anything over 1 lakh?"))
        XCTAssertTrue(ans.contains("No transactions over"), "\(ans)")
    }
}
