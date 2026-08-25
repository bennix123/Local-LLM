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
        let lines = rows.map { r in
            "\(r.txnDate)|\(r.descr)|\(String(format: "%.2f", r.debit))|\(String(format: "%.2f", r.credit))"
        }.sorted()
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
