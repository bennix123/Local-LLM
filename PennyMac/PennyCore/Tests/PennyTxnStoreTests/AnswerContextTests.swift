// AnswerContextTests — the scope+receipts behind a factual answer (Fixes 4 & 5).
import XCTest
@testable import PennyTxnStore

final class AnswerContextTests: XCTestCase {

    private func r(_ date: String, _ descr: String, merchant: String = "",
                   category: String = "", debit: Double = 0, credit: Double = 0,
                   seq: Int = 0) -> TxnRow {
        let p = date.split(separator: "-").compactMap { Int($0) }
        return TxnRow(txnDate: date, month: String(date.prefix(7)), year: p[0],
                      monthNo: p[1], day: p[2], descr: descr, merchant: merchant,
                      category: category, debit: debit, credit: credit,
                      balance: nil, currency: "GBP", seq: seq)
    }

    private var rows: [TxnRow] {
        [
            r("2026-06-01", "TESCO", merchant: "Tesco", category: "Groceries", debit: 45.50, seq: 1),
            r("2026-06-10", "AMAZON", merchant: "Amazon", category: "Shopping", debit: 120.00, seq: 2),
            r("2026-06-12", "SALARY", category: "Income", credit: 2500, seq: 3),
            r("2026-07-02", "TESCO", merchant: "Tesco", category: "Groceries", debit: 30.00, seq: 4),
        ]
    }

    func testCategoryScopeReceiptsAndLabel() {
        let ctx = FinanceRouter.context(for: "how much did I spend on groceries", rows: rows)
        XCTAssertNotNil(ctx)
        // Only the two Groceries debits, newest first.
        XCTAssertEqual(ctx?.rows.map(\.seq), [4, 1])
        XCTAssertEqual(ctx?.directionNote, "money out")
        XCTAssertTrue(ctx?.label.lowercased().contains("groceries") == true)
    }

    func testIncomeDirectionExcludesDebits() {
        let ctx = FinanceRouter.context(for: "what income did I receive", rows: rows)
        XCTAssertEqual(ctx?.rows.map(\.seq), [3])          // the salary credit only
        XCTAssertEqual(ctx?.directionNote, "money in")
    }

    func testPeriodScopeNarrows() {
        let ctx = FinanceRouter.context(for: "what did I spend in July", rows: rows)
        XCTAssertEqual(ctx?.rows.map(\.seq), [4])          // only the July Tesco debit
        XCTAssertTrue(ctx?.label.lowercased().contains("jul") == true)
    }

    func testWholeLedgerAnswerHasNoScopeChip() {
        // "balance" names no category/merchant/period/direction → nothing to show.
        XCTAssertNil(FinanceRouter.context(for: "what is my balance", rows: rows))
    }

    func testEmptyRowsIsNil() {
        XCTAssertNil(FinanceRouter.context(for: "spend on groceries", rows: []))
    }

    func testMerchantScope() {
        let ctx = FinanceRouter.context(for: "how much at tesco", rows: rows)
        XCTAssertEqual(ctx?.rows.map(\.seq), [4, 1])
        XCTAssertTrue(ctx?.label.lowercased().contains("tesco") == true)
    }
}
