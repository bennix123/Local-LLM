// TxnSearchTests — deterministic search (Fix 3).
import XCTest
@testable import PennyTxnStore

final class TxnSearchTests: XCTestCase {

    private func r(_ date: String, _ descr: String, merchant: String = "",
                   category: String = "", debit: Double = 0, credit: Double = 0,
                   seq: Int = 0) -> TxnRow {
        let p = date.split(separator: "-").compactMap { Int($0) }
        return TxnRow(txnDate: date, month: String(date.prefix(7)), year: p[0],
                      monthNo: p[1], day: p[2], descr: descr, merchant: merchant,
                      category: category, debit: debit, credit: credit,
                      balance: nil, currency: "GBP", seq: seq)
    }

    private var sample: [TxnRow] {
        [
            r("2026-06-01", "TESCO STORES", merchant: "Tesco", category: "Groceries", debit: 45.50, seq: 1),
            r("2026-06-03", "BLUE BOTTLE COFFEE", merchant: "Blue Bottle", category: "Food & Dining", debit: 4.20, seq: 2),
            r("2026-06-10", "AMAZON", merchant: "Amazon", category: "Shopping", debit: 47.00, seq: 3),
            r("2026-06-12", "SALARY", category: "Income", credit: 2500, seq: 4),
            r("2026-06-15", "TESCO PETROL", merchant: "Tesco", category: "Transport", debit: 60.00, seq: 5),
        ]
    }

    func testTextTokenMatchesMerchantAndDescription() {
        let hits = TxnSearch.search("tesco", in: sample)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.map(\.seq), [5, 1])   // newest first
    }

    func testAndSemanticsNarrows() {
        // Both tokens must match → only the Tesco Transport (petrol) row.
        let hits = TxnSearch.search("tesco transport", in: sample)
        XCTAssertEqual(hits.map(\.seq), [5])
    }

    func testNumericTokenMatchesAmount() {
        let hits = TxnSearch.search("47", in: sample)
        XCTAssertEqual(hits.map(\.merchant), ["Amazon"])
    }

    func testCurrencyPrefixedAmount() {
        let hits = TxnSearch.search("£45.50", in: sample)
        XCTAssertEqual(hits.map(\.merchant), ["Tesco"])
        XCTAssertEqual(hits.first?.debit, 45.50)
    }

    func testCategorySearch() {
        let hits = TxnSearch.search("groceries", in: sample)
        XCTAssertEqual(hits.map(\.seq), [1])
    }

    func testEmptyQueryReturnsAllNewestFirst() {
        let hits = TxnSearch.search("   ", in: sample)
        XCTAssertEqual(hits.count, 5)
        XCTAssertEqual(hits.first?.seq, 5)        // newest
        XCTAssertEqual(hits.last?.seq, 1)         // oldest
    }

    func testNoMatchIsEmpty() {
        XCTAssertTrue(TxnSearch.search("netflix", in: sample).isEmpty)
    }

    func testDateTokenMatches() {
        let hits = TxnSearch.search("2026-06-12", in: sample)
        XCTAssertEqual(hits.map(\.category), ["Income"])
    }
}
