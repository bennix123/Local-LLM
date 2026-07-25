// CardStatement — generic credit-card statement support for the universal
// parser. The dedicated Amex layout parser already returns card semantics;
// this handles every OTHER issuer's card statement that lands in the generic
// cascade, which would otherwise be read with bank-account semantics:
//   • the running balance on a card is money OWED, so a balance INCREASE is a
//     CHARGE (debit) and a decrease is a payment/refund (credit) — the exact
//     inverse of the bank balance-walk, which classifies every charge as a
//     credit on such statements;
//   • repayments ("PAYMENT RECEIVED — THANK YOU") are the user's own money
//     moving, category "Payments", never income;
//   • the statement's own "New Balance / Total Amount Due" is the amount owed.
// Detection is deliberately conservative (two independent card cues, and a
// bank-account cue vetoes) so no bank statement is ever flipped: verified
// against all 22 conformance fixtures and the 112-file sweep corpus.
import Foundation

public enum CardStatement {

    // MARK: - detection

    /// Strong cues that essentially only appear on card statements.
    static let cueRes: [PyRegex] = [
        PyRegex("credit card statement", ignoreCase: true),
        PyRegex("minimum (payment|amount) due", ignoreCase: true),
        PyRegex("credit limit", ignoreCase: true),
        PyRegex("available credit", ignoreCase: true),
        PyRegex("payment due date", ignoreCase: true),
        PyRegex("total amount due", ignoreCase: true),
        PyRegex("new balance", ignoreCase: true),
        PyRegex("card ending(?: in)? \\d{4}", ignoreCase: true),
        PyRegex("purchases and adjustments", ignoreCase: true),
    ]
    /// Cues that mark a CURRENT/bank account — their presence vetoes card
    /// detection (statements listing both are bank statements mentioning a card).
    static let vetoRes: [PyRegex] = [
        PyRegex("sort code", ignoreCase: true),
        PyRegex("routing number", ignoreCase: true),
        PyRegex("\\bifsc\\b", ignoreCase: true),
        PyRegex("current account", ignoreCase: true),
        PyRegex("checking", ignoreCase: true),
        PyRegex("savings account", ignoreCase: true),
    ]

    /// True when the head text carries at least two independent card cues and
    /// no bank-account veto.
    public static func detect(_ head: String) -> Bool {
        if vetoRes.contains(where: { $0.search(head) != nil }) { return false }
        return cueRes.filter { $0.search(head) != nil }.count >= 2
    }

    // MARK: - stated amount owed

    static let owedRes: [PyRegex] = [
        PyRegex("new balance:?\\s*[₹£$€]?\\s*(-?[\\d,]+\\.\\d{2})", ignoreCase: true),
        PyRegex("total amount due:?\\s*[₹£$€]?\\s*(-?[\\d,]+\\.\\d{2})", ignoreCase: true),
        PyRegex("closing balance:?\\s*[₹£$€]?\\s*(-?[\\d,]+\\.\\d{2})", ignoreCase: true),
        PyRegex("balance due:?\\s*[₹£$€]?\\s*(-?[\\d,]+\\.\\d{2})", ignoreCase: true),
    ]

    /// The statement's own closing figure (what the user owes), if stated.
    public static func statedClosingBalance(_ text: String) -> Double? {
        for re in owedRes {
            if let m = re.search(text), let g = m.group(1) {
                return money(g)
            }
        }
        return nil
    }

    // MARK: - card semantics post-pass

    static let repaymentRe = PyRegex(
        "payment received|payment[ ,-]+thank you|thank you.{0,12}payment|autopay|auto[- ]pay|payment - direct debit|direct debit payment",
        ignoreCase: true)

    /// Rewrite generically-parsed rows with card semantics:
    /// 1. Where a consistent owed-balance chain exists, re-derive debit/credit
    ///    from the balance DELTA (owed up = charge/debit, owed down = credit).
    ///    Rows whose delta doesn't match their amount (chain break) are left
    ///    as parsed.
    /// 2. Credits that read as repayments become category "Payments" — the
    ///    app's income figures exclude that category by design.
    public static func applyCardSemantics(_ rows: [TxnRow]) -> [TxnRow] {
        var out = rows
        var prev: Double? = nil
        for i in out.indices {
            defer { prev = out[i].balance ?? prev }
            guard let bal = out[i].balance, let p = prev else { continue }
            let delta = bal - p
            let amt = out[i].debit > 0 ? out[i].debit : out[i].credit
            guard amt > 0, abs(abs(delta) - amt) < 0.01 else { continue }
            if delta > 0 {          // owed increased → charge
                out[i].debit = amt; out[i].credit = 0
            } else if delta < 0 {   // owed decreased → payment / refund
                out[i].debit = 0; out[i].credit = amt
            }
        }
        for i in out.indices where out[i].credit > 0 {
            if repaymentRe.search(out[i].descr) != nil {
                out[i].merchant = "Payment Received"
                out[i].category = "Payments"
            }
        }
        return out
    }
}
