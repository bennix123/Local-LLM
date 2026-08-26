// Reconciliation — the visible trust handshake (Fix 1).
//
// After a statement is parsed, we prove the numbers add up before the app
// answers any question from them: opening balance, plus money in, minus money
// out, should equal the closing balance the statement itself prints. When it
// does, the app can say so ("balance reconciles ✓") and the anxious first-run
// user relaxes. When it doesn't, that is the app's cue to STOP trusting the
// parse — a mismatch means rows were dropped or misread, and answering "£0 on
// groceries" off a broken ledger is the one unforgivable finance-app bug.
//
// This is pure arithmetic on already-parsed rows — no regex router, no model —
// so it is as reliable as addition. It degrades honestly: with no balance line
// to check against, it says so rather than pretending success.
import Foundation

public enum Reconciliation {

    public enum Status: Equatable {
        /// Opening + in − out matches the stated closing within tolerance.
        case reconciled
        /// It doesn't match — off by this signed amount (expected − stated).
        /// A non-zero delta means the parse is suspect.
        case mismatch(Double)
        /// Not enough balance data on this statement to check (common for CSV /
        /// app exports that carry no opening/closing line). Not a failure — just
        /// unverifiable, and the app should say so plainly.
        case noBalanceData
    }

    public struct Report: Equatable {
        public let rowCount: Int
        public let totalIn: Double        // Σ credits
        public let totalOut: Double       // Σ debits
        public let opening: Double?
        public let closing: Double?
        public let expectedClosing: Double?   // opening + in − out, when opening known
        public let delta: Double?             // expectedClosing − closing, when both known
        public let status: Status

        public var reconciles: Bool { status == .reconciled }
    }

    /// Check a statement's rows against its own opening/closing balances.
    /// `tolerance` is in the same currency unit (default 1p) to absorb rounding.
    public static func check(rows: [TxnRow],
                             opening: Double?,
                             closing: Double?,
                             tolerance: Double = 0.01) -> Report {
        let totalIn  = rows.reduce(0) { $0 + $1.credit }
        let totalOut = rows.reduce(0) { $0 + $1.debit }

        guard let opening, let closing else {
            return Report(rowCount: rows.count, totalIn: totalIn, totalOut: totalOut,
                          opening: opening, closing: closing,
                          expectedClosing: opening.map { $0 + totalIn - totalOut },
                          delta: nil, status: .noBalanceData)
        }

        let expected = opening + totalIn - totalOut
        let delta = expected - closing
        let status: Status = abs(delta) <= tolerance ? .reconciled : .mismatch(delta)
        return Report(rowCount: rows.count, totalIn: totalIn, totalOut: totalOut,
                      opening: opening, closing: closing,
                      expectedClosing: expected, delta: delta, status: status)
    }

    /// A short, plain-language line for the UI. `money` formats a figure the way
    /// the rest of the app does (currency symbol, 2dp).
    public static func summaryLine(_ r: Report, money: (Double) -> String) -> String {
        let n = r.rowCount
        let txns = "\(n) transaction\(n == 1 ? "" : "s")"
        switch r.status {
        case .reconciled:
            return "Read \(txns) · balance reconciles ✓"
        case .mismatch(let d):
            return "Read \(txns) · ⚠︎ totals are off by \(money(abs(d))) — I may have misread this statement"
        case .noBalanceData:
            return "Read \(txns) · no balance line to reconcile against"
        }
    }
}
