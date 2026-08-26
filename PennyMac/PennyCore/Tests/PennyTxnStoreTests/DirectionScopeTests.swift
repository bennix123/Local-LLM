import XCTest
@testable import PennyTxnStore

/// Direction-aware answers: "credit" questions must answer with credits only,
/// "debit" questions with debits only — as a total, a list, or LLM grounding —
/// while the compound senses of "credit" (card, limit, score, bill) keep their
/// existing routes. Regression for the "asked whats my credit, got both" bug.
final class DirectionScopeTests: XCTestCase {

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
         row(5, date: "2026-06-12", descr: "CARD PAYMENT RECEIVED", category: "Payments", credit: 500),
         row(6, date: "2026-06-25", descr: "SALARY ACME CORP", category: "Income", credit: 3000)]
    }

    private let money: (Double) -> String = { "£" + String(format: "%.2f", $0) }

    private func ask(_ q: String, _ r: [TxnRow]? = nil) -> String? {
        FinanceRouter.answer(q, rows: r ?? rows, currency: "GBP", money: money)
    }

    // MARK: - directionScope detector

    func testDetectorDirectionNouns() {
        XCTAssertEqual(FinanceRouter.directionScope("list my credits"), .credit)
        XCTAssertEqual(FinanceRouter.directionScope("show me my deposits"), .credit)
        XCTAssertEqual(FinanceRouter.directionScope("whats my credit in this file"), .credit)
        XCTAssertEqual(FinanceRouter.directionScope("list my debits"), .debit)
        XCTAssertEqual(FinanceRouter.directionScope("show me my withdrawals"), .debit)
        XCTAssertEqual(FinanceRouter.directionScope("show me my charges"), .debit)
    }

    func testDetectorCompoundCreditSensesAreNotADirection() {
        XCTAssertNil(FinanceRouter.directionScope("what is my credit limit"))
        XCTAssertNil(FinanceRouter.directionScope("available credit"))
        XCTAssertNil(FinanceRouter.directionScope("what's my credit card bill"))
        XCTAssertNil(FinanceRouter.directionScope("what is my credit score"))
        XCTAssertNil(FinanceRouter.directionScope("which statement is a credit card"))
    }

    func testDetectorBothOrNeitherIsNil() {
        XCTAssertNil(FinanceRouter.directionScope("list my credits and debits"))
        XCTAssertNil(FinanceRouter.directionScope("show all transactions"))
        XCTAssertNil(FinanceRouter.directionScope("list my Groceries transactions"))
    }

    // MARK: - credit / debit totals (existing routes, locked)

    func testCreditQuestionIsCreditsOnlyTotal() throws {
        let ans = try XCTUnwrap(ask("whats my credit in this file"))
        XCTAssertTrue(ans.contains("You received £6000.00"), "\(ans)")
        XCTAssertFalse(ans.contains("£255.00"), "debits must not appear: \(ans)")
    }

    func testHowMuchReceivedInCreditsStaysATotal() throws {
        // Aggregate phrasing must keep the exact total format (parity-pinned).
        let ans = try XCTUnwrap(ask("how much did I receive in credits?"))
        XCTAssertTrue(ans.contains("**You received £6000.00") && ans.contains("across 2 credits"), "\(ans)")
    }

    // MARK: - itemised credit / debit lists (new)

    func testListMyCreditsIsAnItemisedCreditList() throws {
        let ans = try XCTUnwrap(ask("list my credits"))
        XCTAssertTrue(ans.contains("credits") && ans.contains("SALARY ACME CORP"), "\(ans)")
        XCTAssertFalse(ans.contains("ZARA") || ans.contains("TESCO"), "no debit rows: \(ans)")
        XCTAssertTrue(ans.contains("card repayments"), "Payments credit needs the caveat: \(ans)")
    }

    func testShowMeMyDepositsIsACreditList() throws {
        let ans = try XCTUnwrap(ask("show me my deposits"))
        XCTAssertTrue(ans.contains("SALARY ACME CORP"), "\(ans)")
        XCTAssertFalse(ans.contains("ZARA"), "\(ans)")
    }

    func testListMyDebitsIsAnItemisedDebitList() throws {
        let ans = try XCTUnwrap(ask("list my debits"))
        XCTAssertTrue(ans.contains("3 debits") && ans.contains("£255.00"), "\(ans)")
        XCTAssertTrue(ans.contains("ZARA") && ans.contains("TESCO"), "\(ans)")
        XCTAssertFalse(ans.contains("SALARY"), "no credit rows: \(ans)")
    }

    func testShowMeMyChargesIsADebitList() throws {
        let ans = try XCTUnwrap(ask("show me my charges"))
        XCTAssertTrue(ans.contains("ZARA") && !ans.contains("SALARY"), "\(ans)")
    }

    func testCreditListOnDebitOnlyRowsIsHonestZero() throws {
        let debitOnly = [row(1, date: "2026-06-01", descr: "TESCO", category: "Groceries", debit: 50)]
        let ans = try XCTUnwrap(ask("list my credits", debitOnly))
        XCTAssertTrue(ans.contains("No credits"), "\(ans)")
    }

    func testLongListIsCappedAtFifteen() throws {
        var many = rows
        for i in 0..<20 {
            many.append(row(100 + i, date: "2026-07-01", descr: "INTEREST \(i)",
                            category: "Income", credit: 1))
        }
        let ans = try XCTUnwrap(ask("list my credits", many))
        XCTAssertTrue(ans.contains("more._"), "22 credits must be capped with a footer: \(ans)")
    }

    // MARK: - must-not-change routes

    func testDirectDebitsAreNotADebitList() {
        // Recurring-payment vocabulary, not a request for the debit rows.
        let ans = ask("list my direct debits")
        if let ans { XCTAssertFalse(ans.contains("3 debits"), "\(ans)") }
    }

    func testCategoryListStillWorksUnchanged() throws {
        let ans = try XCTUnwrap(ask("list my Groceries transactions"))
        XCTAssertTrue(ans.contains("TESCO"), "\(ans)")
        XCTAssertFalse(ans.contains("SALARY"), "\(ans)")
    }

    func testCreditLimitStillDefersToMetadataLayer() {
        XCTAssertNil(ask("what is my credit limit"), "header metadata must defer to the LLM")
    }
}
