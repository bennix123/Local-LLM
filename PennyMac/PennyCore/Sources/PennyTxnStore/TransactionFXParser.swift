import Foundation
import PennyModel

/// Best-effort foreign-exchange extraction from a transaction's description text
/// (Task 0.5, Decision 2). Populates **only** what is explicitly present — it never
/// infers or fabricates FX values.
///
/// `FXInfo` requires an original amount + currency, so this returns a value only
/// when the description actually carries a foreign-currency amount (e.g.
/// "… €42.00 @ 0.86"). A bare trailing country code with no amount yields `nil`
/// (the legacy parser often didn't preserve the FX detail line — see R2).
public enum TransactionFXParser {

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// FX detail parsed from `descr`, or nil when no explicit foreign amount is present.
    public static func fx(from descr: String) -> FXInfo? {
        guard let (amount, currency) = originalAmountAndCurrency(descr) else { return nil }
        return FXInfo(originalAmount: Money(decimal: amount),
                      originalCurrency: currency,
                      rate: rate(descr),
                      fee: nil,                         // legacy descr rarely itemizes an FX fee
                      country: country(descr))
    }

    // MARK: components

    /// A foreign-currency amount: a symbol (€ $ ¥) or ISO code (USD/EUR/…) with a
    /// number. The account's own currency is not excluded here — the caller only
    /// stores FX when the currency actually differs.
    private static func originalAmountAndCurrency(_ descr: String) -> (Decimal, Currency)? {
        // Symbol form: €42.00 / $50.00 / ¥1,000.00
        let symbols: [(String, String)] = [("€", "EUR"), ("$", "USD"), ("¥", "JPY"), ("₹", "INR")]
        for (symbol, code) in symbols {
            if let g = firstGroup(descr, "\(NSRegularExpression.escapedPattern(for: symbol))\\s*([\\d,]+\\.\\d{2})"),
               let v = Decimal(string: g.replacingOccurrences(of: ",", with: ""), locale: posix) {
                return (v, Currency(code))
            }
        }
        // ISO-code form: USD 50.00 / EUR 42.00
        if let (code, num) = firstTwoGroups(descr, #"\b([A-Z]{3})\s+([\d,]+\.\d{2})\b"#),
           let v = Decimal(string: num.replacingOccurrences(of: ",", with: ""), locale: posix) {
            return (v, Currency(code))
        }
        return nil
    }

    /// An explicit FX rate: "@ 0.86" or "rate 1.16".
    private static func rate(_ descr: String) -> Decimal? {
        if let g = firstGroup(descr, #"(?:@|rate)\s*([\d]+\.[\d]+)"#) {
            return Decimal(string: g, locale: posix)
        }
        return nil
    }

    /// A trailing 2–3 letter uppercase country code ("… PARIS FR").
    private static func country(_ descr: String) -> String? {
        firstGroup(descr, #"\b([A-Z]{2,3})\s*$"#)
    }

    // MARK: regex plumbing

    private static func firstGroup(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func firstTwoGroups(_ s: String, _ pattern: String) -> (String, String)? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges > 2,
              let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s) else { return nil }
        return (String(s[r1]), String(s[r2]))
    }
}
