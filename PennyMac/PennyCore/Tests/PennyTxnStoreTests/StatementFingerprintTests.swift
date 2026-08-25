import XCTest
@testable import PennyTxnStore

final class StatementFingerprintTests: XCTestCase {

    private func row(_ seq: Int, date: String = "2026-06-01", descr: String = "TESCO",
                     debit: Double = 10, credit: Double = 0, balance: Double? = 100) -> TxnRow {
        TxnRow(txnDate: date, month: String(date.prefix(7)), year: 2026, monthNo: 6, day: 1,
               descr: descr, merchant: "", category: "Groceries",
               debit: debit, credit: credit, balance: balance, currency: "GBP", seq: seq)
    }

    func testIdenticalRowsMatch() {
        let a = [row(1), row(2, descr: "ASDA", debit: 20)]
        let b = [row(1), row(2, descr: "ASDA", debit: 20)]
        XCTAssertEqual(StatementFingerprint.compute(a), StatementFingerprint.compute(b))
    }

    func testOrderIndependent() {
        // Same statement exported newest-first vs oldest-first must match.
        let a = [row(1), row(2, descr: "ASDA", debit: 20)]
        let b = [row(2, descr: "ASDA", debit: 20), row(1)]
        XCTAssertEqual(StatementFingerprint.compute(a), StatementFingerprint.compute(b))
    }

    func testBalanceIgnored() {
        // Different export windows can shift running balances; identity is the txns.
        let a = [row(1, balance: 100)]
        let b = [row(1, balance: 900)]
        XCTAssertEqual(StatementFingerprint.compute(a), StatementFingerprint.compute(b))
    }

    func testAmountChangeDiffers() {
        XCTAssertNotEqual(StatementFingerprint.compute([row(1, debit: 10)]),
                          StatementFingerprint.compute([row(1, debit: 10.01)]))
    }

    func testDifferentMonthDiffers() {
        XCTAssertNotEqual(StatementFingerprint.compute([row(1, date: "2026-06-01")]),
                          StatementFingerprint.compute([row(1, date: "2026-07-01")]))
    }
}
