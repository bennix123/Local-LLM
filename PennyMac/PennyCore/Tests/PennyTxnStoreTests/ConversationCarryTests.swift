import XCTest
@testable import PennyTxnStore

/// B4 — elliptical follow-ups inherit the previous question's scope: the
/// dimension the fragment restates replaces, the dimension it omits carries.
final class ConversationCarryTests: XCTestCase {

    private func row(_ seq: Int, date: String, descr: String, category: String,
                     debit: Double) -> TxnRow {
        let parts = date.split(separator: "-")
        return TxnRow(txnDate: date, month: "\(parts[0])-\(parts[1])", year: Int(parts[0]) ?? 2026,
                      monthNo: Int(parts[1]) ?? 1, day: Int(parts[2]) ?? 1,
                      descr: descr, merchant: descr, category: category,
                      debit: debit, credit: 0, balance: nil, currency: "GBP", seq: seq)
    }

    private var rows: [TxnRow] {
        [row(1, date: "2026-06-02", descr: "TESCO", category: "Groceries", debit: 100),
         row(2, date: "2026-06-15", descr: "ZARA", category: "Shopping", debit: 80),
         row(3, date: "2026-07-03", descr: "TESCO", category: "Groceries", debit: 40),
         row(4, date: "2026-07-20", descr: "ZARA", category: "Shopping", debit: 60)]
    }

    private let money: (Double) -> String = { "£" + String(format: "%.2f", $0) }

    private func ask(_ q: String, after prev: String? = nil) -> String? {
        FinanceRouter.answer(q, rows: rows, currency: "GBP",
                             previousQuestion: prev, money: money)
    }

    func testFollowUpInheritsEntityWhenRestatingPeriod() throws {
        let ans = try XCTUnwrap(ask("and in July?",
                                    after: "How much did I spend on groceries in June?"))
        XCTAssertTrue(ans.contains("£40.00"), "July groceries, not July total: \(ans)")
        XCTAssertTrue(ans.lowercased().contains("groceries"), "\(ans)")
    }

    func testFollowUpInheritsPeriodWhenRestatingEntity() throws {
        let ans = try XCTUnwrap(ask("what about Zara?",
                                    after: "How much did I spend on groceries in June?"))
        XCTAssertTrue(ans.contains("£80.00"), "Zara in June, not Zara overall: \(ans)")
    }

    func testCompleteQuestionIgnoresHistory() throws {
        let ans = try XCTUnwrap(ask("How much did I spend on shopping in July?",
                                    after: "How much did I spend on groceries in June?"))
        XCTAssertTrue(ans.contains("£60.00"), "history must not contaminate: \(ans)")
    }

    func testNoPreviousQuestionBehavesAsBefore() throws {
        let ans = try XCTUnwrap(ask("How much did I spend on groceries in June?"))
        XCTAssertTrue(ans.contains("£100.00"), "\(ans)")
    }

    func testScopelessFragmentIsLeftAlone() {
        // "and?" restates nothing parseable — no carry, and no phantom answer.
        let ans = ask("and?", after: "How much did I spend on groceries in June?")
        if let ans { XCTAssertFalse(ans.contains("£0.00 on"), "no phantom target: \(ans)") }
    }
}
