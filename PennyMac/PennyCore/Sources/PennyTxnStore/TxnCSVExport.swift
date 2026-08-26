// TxnCSVExport — deterministic CSV serialization of the canonical ledger.
//
// Fix 7 (export). This is pure, platform-free, and unit-tested: it turns the
// exact rows the user is looking at into a spreadsheet/accountant-ready CSV.
// It touches neither the regex router nor the model — it serializes data the
// app already holds, so it is as reliable as arithmetic. The app layer owns the
// file-save affordance; this owns the bytes.
import Foundation

public enum TxnCSVExport {

    /// Canonical, human-legible header. Order is stable — downstream consumers
    /// (Excel, accountants, re-import) can rely on it.
    public static let columns = [
        "Date", "Description", "Merchant", "Category",
        "Money In", "Money Out", "Balance", "Currency",
    ]

    /// Serialize rows to an RFC 4180 CSV string (CRLF line endings, quoted
    /// fields where needed). Rows are emitted in the order given — the caller
    /// sorts (the app exports in the same order the ledger shows).
    ///
    /// `moneyIn`/`moneyOut` are the credit/debit split, printed to 2dp and left
    /// blank (not "0.00") when zero, so a column reads as "the amounts that
    /// happened" rather than a wall of zeros. Balance is blank when the row
    /// carries none (e.g. Barclays rows without a running balance).
    public static func string(from rows: [TxnRow]) -> String {
        var lines: [String] = [columns.map(field).joined(separator: ",")]
        for r in rows {
            let cells = [
                r.txnDate,
                r.descr,
                r.merchant,
                r.category,
                r.credit > 0 ? amount(r.credit) : "",
                r.debit  > 0 ? amount(r.debit)  : "",
                r.balance.map(amount) ?? "",
                r.currency,
            ]
            lines.append(cells.map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// UTF-8 bytes, BOM-prefixed so Excel opens £/€ and non-ASCII merchants in
    /// the right encoding instead of mojibake.
    public static func data(from rows: [TxnRow]) -> Data {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        return Data(bom) + Data(string(from: rows).utf8)
    }

    // MARK: - internals

    /// Two-decimal plain number, no thousands separators, no currency symbol —
    /// a spreadsheet wants a parseable value, not a formatted one.
    static func amount(_ v: Double) -> String { String(format: "%.2f", v) }

    /// RFC 4180 quoting: a field containing a comma, double-quote, CR or LF is
    /// wrapped in double-quotes with inner quotes doubled. Everything else is
    /// emitted bare.
    static func field(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else {
            return s
        }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
