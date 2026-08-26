// ReconciliationTests — the visible trust handshake's math (Fix 1).
import XCTest
@testable import PennyTxnStore

final class ReconciliationTests: XCTestCase {

    private func r(_ debit: Double = 0, _ credit: Double = 0) -> TxnRow {
        TxnRow(txnDate: "2026-06-01", month: "2026-06", year: 2026, monthNo: 6, day: 1,
               descr: "x", merchant: "", category: "", debit: debit, credit: credit,
               balance: nil, currency: "GBP", seq: 0)
    }
    private let money: (Double) -> String = { String(format: "£%.2f", $0) }

    func testReconcilesWhenTotalsMatchClosing() {
        // opening 1000, +2500 in, −45.50 −120 out ⇒ expected 3334.50
        let rows = [r(0, 2500), r(45.50), r(120)]
        let rep = Reconciliation.check(rows: rows, opening: 1000, closing: 3334.50)
        XCTAssertTrue(rep.reconciles)
        XCTAssertEqual(rep.status, .reconciled)
        XCTAssertEqual(Reconciliation.summaryLine(rep, money: money),
                       "Read 3 transactions · balance reconciles ✓")
    }

    func testMismatchFlagsTheDeltaAndWarns() {
        // A dropped £50 debit: stated closing is 50 lower than the rows imply.
        let rows = [r(0, 2500), r(45.50), r(120)]
        let rep = Reconciliation.check(rows: rows, opening: 1000, closing: 3284.50)
        guard case .mismatch(let d) = rep.status else { return XCTFail("expected mismatch") }
        XCTAssertEqual(d, 50, accuracy: 0.001)          // expected − stated = +50
        XCTAssertTrue(Reconciliation.summaryLine(rep, money: money).contains("⚠︎"))
        XCTAssertTrue(Reconciliation.summaryLine(rep, money: money).contains("£50.00"))
    }

    func testPennyToleranceAbsorbsRounding() {
        let rows = [r(0, 100.005)]                        // half-penny noise
        let rep = Reconciliation.check(rows: rows, opening: 0, closing: 100.00)
        XCTAssertTrue(rep.reconciles, "within 1p should still reconcile")
    }

    func testNoBalanceDataDegradesHonestly() {
        let rep = Reconciliation.check(rows: [r(10), r(0, 20)], opening: nil, closing: nil)
        XCTAssertEqual(rep.status, .noBalanceData)
        XCTAssertFalse(rep.reconciles)
        XCTAssertEqual(Reconciliation.summaryLine(rep, money: money),
                       "Read 2 transactions · no balance line to reconcile against")
        // Totals are still computed even when unverifiable.
        XCTAssertEqual(rep.totalOut, 10, accuracy: 0.001)
        XCTAssertEqual(rep.totalIn, 20, accuracy: 0.001)
    }

    func testMissingOpeningIsUnverifiableEvenWithClosing() {
        // Closing known but no opening ⇒ can't run the identity ⇒ honest "no data".
        let rep = Reconciliation.check(rows: [r(10)], opening: nil, closing: 500)
        XCTAssertEqual(rep.status, .noBalanceData)
    }
}
