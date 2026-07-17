// Txn — the canonical transaction row every parser yields.
// Mirrors the dict produced by finquery's txn_store parsers.
import Foundation

public struct TxnRow {
    public var txnDate: String      // YYYY-MM-DD
    public var month: String        // YYYY-MM
    public var year: Int
    public var monthNo: Int
    public var day: Int
    public var descr: String
    public var merchant: String
    public var category: String
    public var debit: Double
    public var credit: Double
    public var balance: Double?     // nil = NULL (e.g. Barclays rows without a balance)
    public var currency: String
    public var seq: Int
    public var rawCategory: String? = nil   // hint stripped from the description

    public init(txnDate: String, month: String, year: Int, monthNo: Int, day: Int,
                descr: String, merchant: String, category: String,
                debit: Double, credit: Double, balance: Double?,
                currency: String, seq: Int) {
        self.txnDate = txnDate; self.month = month; self.year = year
        self.monthNo = monthNo; self.day = day
        self.descr = descr; self.merchant = merchant; self.category = category
        self.debit = debit; self.credit = credit; self.balance = balance
        self.currency = currency; self.seq = seq
    }
}

/// Result of the generic cascade: rows plus a confidence grade.
public struct ParseResult {
    public var rows: [TxnRow]
    public var confidence: String   // "high" | "medium" | "low" | "partial"
}

/// _money() from formatters.py: strip a CR/DR suffix and every non-numeric
/// char, then parse; unparseable -> 0.0.
public func money(_ s: String?) -> Double {
    guard let s, !s.pyStrip().isEmpty else { return 0.0 }
    var t = PyRegex("(?i)(cr|dr)\\.?$").sub("", s.pyStrip())
    t = PyRegex("[^\\d.-]").sub("", t)
    return Double(t) ?? 0.0
}
