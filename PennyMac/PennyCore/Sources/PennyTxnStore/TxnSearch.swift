// TxnSearch — deterministic transaction search (Fix 3).
//
// "What was that £47 thing last Tuesday?" is one of the most common real
// questions, and the honest way to answer it on-device is NOT to route free
// text through the small model (flaky) but to filter the ledger directly. This
// is a structured search: every token must match, matching is exact and
// explainable, and there is no model in the path — so it is instant and never
// hallucinates a transaction that isn't there.
import Foundation

public enum TxnSearch {

    /// Filter `rows` to those matching every token in `query` (AND semantics),
    /// newest first. An empty/whitespace query returns the rows unchanged
    /// (newest first) so the search field doubles as a full, browsable list.
    ///
    /// A token matches a row when it appears in the row's text (merchant,
    /// description, category, date) OR — when the token is numeric — when it
    /// matches the row's amount (money in or out). So "tesco 45" finds the
    /// £45 Tesco line, and "coffee" finds every coffee row.
    public static func search(_ query: String, in rows: [TxnRow]) -> [TxnRow] {
        let tokens = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init).filter { !$0.isEmpty }
        let sorted = rows.sorted { ($0.txnDate, $0.seq) > ($1.txnDate, $1.seq) }
        guard !tokens.isEmpty else { return sorted }
        return sorted.filter { row in tokens.allSatisfy { matches($0, row) } }
    }

    // MARK: - internals

    static func matches(_ token: String, _ row: TxnRow) -> Bool {
        let haystack = "\(row.merchant) \(row.descr) \(row.category) \(row.txnDate)".lowercased()
        if haystack.contains(token) { return true }
        // Numeric token: match the debit or credit. "£47" / "47" / "47.00" all
        // match a 47.00 amount; a bare integer also matches by whole-pound value.
        if let amt = amountValue(token) {
            for money in [row.debit, row.credit] where money > 0 {
                if abs(money - amt) < 0.005 { return true }
                let printed = String(format: "%.2f", money)
                if printed.hasPrefix(token) || printed == token { return true }
            }
        }
        return false
    }

    /// Parse a money-ish token ("£47", "47", "47.50", "$1,299.00") to a value,
    /// or nil when it isn't numeric.
    static func amountValue(_ token: String) -> Double? {
        let cleaned = token.filter { $0.isNumber || $0 == "." }
        guard !cleaned.isEmpty, token.contains(where: { $0.isNumber }) else { return nil }
        return Double(cleaned)
    }
}
