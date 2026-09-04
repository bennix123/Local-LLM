// StatementFingerprint — stable content identity for a parsed statement, so a
// re-uploaded statement is recognized and rejected instead of silently doubling
// every total (the same file re-exported under a different name still matches:
// identity comes from the rows, never the filename).
import Foundation
import CryptoKit

public enum StatementFingerprint {

    /// SHA-256 over the sorted canonical row lines. Sorting makes the identity
    /// order-independent (some banks export newest-first, some oldest-first);
    /// balance is EXCLUDED because the same transactions exported over two
    /// different ranges can carry different running balances.
    public static func compute(_ rows: [TxnRow]) -> String {
        computeLines(rows.map { r in
            "\(r.txnDate)|\(r.descr)|\(String(format: "%.2f", r.debit))|\(String(format: "%.2f", r.credit))"
        })
    }

    /// Format-blind identity: dates + amounts ONLY. The same statement exported
    /// as xlsx and pdf parses to cosmetically different descriptions (case,
    /// spacing, truncation) but identical dates and amounts — the strict
    /// fingerprint missed it and every total doubled (2026-09-04 manual bug).
    /// Callers should only trust this above a minimum row count: two genuinely
    /// different tiny statements can collide on dates+amounts.
    public static func computeLoose(_ rows: [TxnRow]) -> String {
        computeLines(rows.map { r in
            "\(r.txnDate)|\(String(format: "%.2f", r.debit))|\(String(format: "%.2f", r.credit))"
        })
    }

    /// The shared hash: sorted lines → SHA-256 hex. Public so the Mac app can
    /// fingerprint canonical-model transactions with the same identity rules.
    public static func computeLines(_ lines: [String]) -> String {
        let digest = SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
