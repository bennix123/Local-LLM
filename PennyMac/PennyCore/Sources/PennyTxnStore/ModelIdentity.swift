import PennyModel

/// Deterministic, filename-independent identity generation for the translation
/// layer (Task 0.4). Shared by every source adapter — PDF now, CSV / OCR / Open
/// Banking later — so identity is produced one way across all of them.
///
/// Uses **FNV-1a over UTF-8** because Swift's built-in `Hasher` is seeded randomly
/// per process, so its `hashValue` is *not* stable across runs and cannot be used
/// for persisted identity. FNV-1a is a pure arithmetic hash: same input → same
/// output, every run, every process.
public enum ModelIdentity {

    /// 64-bit FNV-1a hash of `string`, rendered as hex.
    public static func hash(_ string: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325            // FNV-1a offset basis
        let prime: UInt64 = 0x100000001b3             // FNV-1a prime
        for byte in string.utf8 {
            h ^= UInt64(byte)
            h = h &* prime                            // wrapping multiply
        }
        return String(h, radix: 16)
    }

    /// Account identity. Task 0.5: when an account number or sort code is available
    /// (parsed from the statement header), the ID keys on those — so two accounts at
    /// the same institution are distinct. When neither is present, it falls back to
    /// the Task 0.4 provisional key (institution + currency).
    public static func accountID(institution: String, currency: Currency,
                                 accountNumber: String? = nil, sortCode: String? = nil) -> AccountID {
        let number = accountNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sort = sortCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !number.isEmpty || !sort.isEmpty {
            return AccountID("acct-" + hash("\(institution)|\(sort)|\(number)"))
        }
        return AccountID("acct-" + hash("\(institution)|\(currency.code)"))   // provisional fallback
    }

    /// Statement identity: a content digest (never the filename) — the owning
    /// account plus the span, size, and closing figure of its rows.
    public static func statementID(accountID: AccountID, firstDate: String, lastDate: String,
                                   rowCount: Int, closingBalance: String) -> StatementID {
        StatementID("stmt-" + hash("\(accountID.raw)|\(firstDate)|\(lastDate)|\(rowCount)|\(closingBalance)"))
    }

    /// Transaction identity: the owning statement, the row's sequence number, and
    /// the row's own content.
    public static func transactionID(statementID: StatementID, seq: Int,
                                     date: String, descr: String, amount: String) -> TransactionID {
        TransactionID("txn-" + hash("\(statementID.raw)|\(seq)|\(date)|\(descr)|\(amount)"))
    }

    /// Merchant identity for the legacy projection: derived from the parser's
    /// merchant string (no alias folding — that is Phase 2.2's job).
    public static func merchantID(_ name: String) -> MerchantID {
        MerchantID("mrch-" + hash("m|" + name))
    }
}
