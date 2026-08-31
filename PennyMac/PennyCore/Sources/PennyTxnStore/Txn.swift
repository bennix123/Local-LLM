// Txn — the canonical transaction row every parser yields.
// Mirrors the dict produced by finquery's txn_store parsers.
import Foundation

public struct TxnRow: Equatable, Sendable {
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

    /// Which of the user's accounts this row moved through, when the statement
    /// states it per record (aggregator exports print a bank footer per
    /// transaction, e.g. "Union Bank Of India -49"). nil when not stated.
    public var account: String? = nil
    /// True when the statement itself marks the row as a transfer between the
    /// user's own accounts/wallets (not real spending or income).
    public var isSelfTransfer: Bool = false

    // Foreign-exchange detail, when the statement itemizes a foreign spend on the
    // row (e.g. Amex "Foreign Spend" column + FX detail line). Populated by the
    // parsers that read it; nil on domestic rows. ModelAssembler maps these into
    // the canonical `FXInfo` (preferred over description-scraped FX). Defaulted so
    // every existing TxnRow construction site is unchanged.
    public var fxForeignAmount: Double? = nil    // amount in the original currency (e.g. 550 ISK)
    public var fxForeignCurrency: String? = nil  // ISO code or raw name (e.g. "ISK")
    public var fxRate: Double? = nil             // printed exchange rate, when stated
    public var fxFee: Double? = nil              // itemized non-sterling / FX fee, when stated

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
