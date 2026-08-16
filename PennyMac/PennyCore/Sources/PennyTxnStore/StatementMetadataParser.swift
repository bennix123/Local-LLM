import Foundation
import PennyModel

/// Statement header metadata parsed from statement text (Task 0.5). Every field is
/// optional: a bank that omits one yields `nil` — never a fabricated value.
public struct StatementMetadata: Sendable, Equatable {
    public var openingBalance: Money?
    // (Phase 0.8 cleanup: `closingBalance` removed — the statement's closing balance
    // comes from the parser figure, not header text, since Task 0.6. The low-level
    // `Balances.closing` reader remains available for a future deliberate consumer.)
    public var availableBalance: Money?
    public var creditLimit: Money?
    public var period: CalendarDateRange?
    public var statementDate: CalendarDate?
    public var accountNumber: String?
    public var sortCode: String?
    public var holder: String?

    public static let empty = StatementMetadata()

    public init(openingBalance: Money? = nil,
                availableBalance: Money? = nil, creditLimit: Money? = nil,
                period: CalendarDateRange? = nil, statementDate: CalendarDate? = nil,
                accountNumber: String? = nil, sortCode: String? = nil, holder: String? = nil) {
        self.openingBalance = openingBalance
        self.availableBalance = availableBalance; self.creditLimit = creditLimit
        self.period = period; self.statementDate = statementDate
        self.accountNumber = accountNumber; self.sortCode = sortCode; self.holder = holder
    }
}

/// Extracts statement header metadata from statement text (Task 0.5).
///
/// **Option B:** operates on the app's existing `StatementText` (PDFKit) text, so
/// the extraction behaves exactly as the code it replaces in `AppModel`. Pure and
/// total — returns `nil` for anything it can't find, never throwing or guessing.
///
/// Structured as focused components (`Balances`, `CreditSummary`, `Dates`,
/// `AccountDetails`) behind one public `parse`. The low-level label readers are
/// public so `AppModel` can delegate to them (single source of truth).
public enum StatementMetadataParser {

    /// The one public entry point: all header metadata for a statement's text.
    public static func parse(text: String) -> StatementMetadata {
        let summary = CreditSummary.parse(text)
        return StatementMetadata(
            openingBalance: Balances.opening(text).map(Money.init(decimal:)),
            availableBalance: summary.available.map(Money.init(decimal:)),
            creditLimit: summary.limit.map(Money.init(decimal:)),
            period: Dates.period(text),
            statementDate: Dates.statementDate(text),
            accountNumber: AccountDetails.accountNumber(text),
            sortCode: AccountDetails.sortCode(text),
            holder: AccountDetails.holder(text))
    }

    // MARK: - Focused component: balances

    enum Balances {
        static func opening(_ text: String) -> Decimal? {
            moneyAfterLabel(in: text, labels: [
                #"opening\s+balance"#, #"start(?:ing)?\s+balance"#, #"initial\s+balance"#,
                #"beginning\s+balance"#, #"balance\s+brought\s+forward"#, #"brought\s+forward"#,
                #"balance\s+b/?f(?:wd)?"#, #"previous\s+balance"#, #"balance\s+from\s+previous\s+statement"#,
            ])
        }
        static func closing(_ text: String) -> Decimal? {
            moneyAfterLabel(in: text, labels: [
                #"closing\s+balance"#, #"balance\s+carried\s+forward"#, #"new\s+balance"#,
                #"end(?:ing)?\s+balance"#, #"closing\s+bal"#, #"carried\s+forward"#,
            ])
        }
    }

    // MARK: - Focused component: credit-card summary (columnar)

    enum CreditSummary {
        /// The two-column "Credit Summary" block — labels on one line, the two
        /// aligned amounts (limit, then available) on the next.
        static func parse(_ text: String) -> (limit: Decimal?, available: Decimal?) {
            let pattern = #"credit\s+limit[^\n]*?available\s+credit[^\n]*\n\s*([\d,]+\.\d{2})\s+([\d,]+\.\d{2})"#
            guard let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
                // Fall back to single-label reads when there's no columnar block.
                return (limit: moneyAfterLabel(in: text, labels: [#"(?:total\s+)?credit\s+limit"#, #"credit\s+line"#]),
                        available: moneyAfterLabel(in: text, labels: [#"available\s+credit(?:\s+limit)?"#, #"available\s+to\s+spend"#]))
            }
            let nums = moneyValues(in: String(text[r]))
            guard nums.count >= 2 else { return (nil, nil) }
            return (limit: nums[0], available: nums[1])
        }
    }

    // MARK: - Focused component: dates

    enum Dates {
        static func period(_ text: String) -> CalendarDateRange? {
            // Amex/UK-card style: a "Statement Period" label then a "From 16 February
            // to 15 March 2026" line — the START date's year is OMITTED and shared
            // from the end (so the generic year-bearing `dateExpr` patterns below
            // can't see it). Tried first, and anchored to "statement period" so the
            // interest-calc "Period 09/02/26 to 08/03/26" line never matches.
            if let r = amexPeriod(text) { return r }

            let d = dateExpr
            let patterns = [
                #"statement\s+period[:\s]+"# + "(\(d))\\s*(?:to|through|until|[-–—])\\s*(\(d))",
                #"(?:for\s+the\s+)?period[:\s]+"# + "(\(d))\\s*(?:to|[-–—])\\s*(\(d))",
                #"statement\s+(?:from|dates?)[:\s]+"# + "(\(d))\\s*(?:to|[-–—])\\s*(\(d))",
            ]
            for p in patterns {
                guard let (a, b) = firstTwoGroups(text, p),
                      let start = parseDate(a), let end = parseDate(b) else { continue }
                return CalendarDateRange(start: start, end: end)
            }
            return nil
        }

        /// "Statement Period … From 16 February [2026] to 15 March 2026". The start
        /// year, when absent, is taken from the end (rolling back a year if the start
        /// month is later than the end month — a Dec→Jan statement).
        private static func amexPeriod(_ text: String) -> CalendarDateRange? {
            let p = #"statement\s+period\s*[:\-–—]?\s*from\s+(\d{1,2})\s+([A-Za-z]{3,9})(?:\s+(\d{4}))?\s+(?:to|through|until|[-–—])\s+(\d{1,2})\s+([A-Za-z]{3,9})\s+(\d{4})"#
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { return nil }
            guard let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            func g(_ i: Int) -> String? {
                guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: text) else { return nil }
                return String(text[r])
            }
            guard let sd = g(1).flatMap({ Int($0) }), let sm = g(2).flatMap(monthNumber),
                  let ed = g(4).flatMap({ Int($0) }), let em = g(5).flatMap(monthNumber),
                  let ey = g(6).flatMap({ Int($0) }) else { return nil }
            let sy = g(3).flatMap { Int($0) } ?? (sm > em ? ey - 1 : ey)
            return CalendarDateRange(start: CalendarDate(year: sy, month: sm, day: sd),
                                     end: CalendarDate(year: ey, month: em, day: ed))
        }

        static func statementDate(_ text: String) -> CalendarDate? {
            let d = dateExpr
            let patterns = [
                #"statement\s+date[:\s]+"# + "(\(d))",
                #"date\s+of\s+statement[:\s]+"# + "(\(d))",
                #"statement\s+issued[:\s]+"# + "(\(d))",
                #"\bissued[:\s]+"# + "(\(d))",
                // Amex prints no "Statement date:" label; its closing date is the one
                // charges are "received by", then repeated as DD/MM/YY on the header
                // value row under the "Prepared for … Date" columns.
                #"charges\s+received\s+by\s+"# + "(\(d))",
                #"prepared\s+for\b[\s\S]{0,80}?(\d{1,2}/\d{1,2}/\d{2,4})"#,
            ]
            for p in patterns {
                if let g = firstGroup(text, p), let date = parseDate(g) { return date }
            }
            return nil
        }
    }

    // MARK: - Focused component: account details

    enum AccountDetails {
        static func accountNumber(_ text: String) -> String? {
            // Digits/mask on a single line (no newline in the capture class).
            if let g = firstGroup(text, #"account\s+(?:number|no\.?|#)[:\s]+([0-9Xx*•\- ]{4,20})"#) {
                let cleaned = g.trimmingCharacters(in: .whitespaces)
                return cleaned.isEmpty ? nil : cleaned
            }
            return nil
        }
        static func sortCode(_ text: String) -> String? {
            if let g = firstGroup(text, #"sort\s+code[:\s]+(\d\d[-\s]?\d\d[-\s]?\d\d)"#) {
                return g.trimmingCharacters(in: .whitespaces)
            }
            if let g = firstGroup(text, #"\b(\d\d-\d\d-\d\d)\b"#) { return g }
            return nil
        }
        static func holder(_ text: String) -> String? {
            // Conservative: only an explicit "Account holder:" label (name detection
            // is otherwise unreliable — R4). nil when not confidently present.
            // Name on a single line — the capture excludes newline so it stops at EOL.
            if let g = firstGroup(text, #"account\s+holder[:\s]+([A-Z][A-Za-z.'\- ]{2,40})"#) {
                let name = g.trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : name
            }
            // Amex "Prepared for" header: the name sits on the value row immediately
            // before the masked membership number
            // ("PIYUSH MISHRA  xxxx-xxxxxx-01001  15/03/26"). Anchored on that mask/
            // number boundary so it can't run past the name — still conservative.
            if let g = firstGroup(text,
                #"prepared\s+for(?:\s+membership\s+number)?(?:\s+date)?\s+([A-Za-z][A-Za-z.'\- ]{1,40}?)\s+(?:[x*]{2,}[- ]?[x*\d]|\d)"#) {
                let name = g.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
            return nil
        }
    }

    // MARK: - Shared low-level readers (public: AppModel delegates to these)

    /// The first money amount following any of `labels` on/near the same line.
    /// Ported verbatim from the former `AppModel.moneyAfterLabel`, returning
    /// `Decimal` (exact) instead of `Double`.
    public static func moneyAfterLabel(in text: String, labels: [String]) -> Decimal? {
        let amount = #"[-−]?\s*[£$€₹]?\s*(\d[\d,]*\.\d{2})"#
        for label in labels {
            let pattern = label + #"[^0-9£$€₹-]{0,40}"# + amount
            guard let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive])
            else { continue }
            let matched = String(text[r])
            if let m = matched.range(of: amount, options: .regularExpression) {
                let digits = matched[m].filter { $0.isNumber || $0 == "." || $0 == "-" }
                if let v = Decimal(string: digits, locale: posix) { return v }
            }
        }
        return nil
    }

    /// Every plain money amount (thousands + 2 decimals) in `text`, in order.
    public static func moneyValues(in text: String) -> [Decimal] {
        var out: [Decimal] = []
        var idx = text.startIndex
        while let r = text.range(of: #"\d[\d,]*\.\d{2}"#, options: .regularExpression, range: idx..<text.endIndex) {
            let digits = text[r].filter { $0.isNumber || $0 == "." }
            if let v = Decimal(string: digits, locale: posix) { out.append(v) }
            idx = r.upperBound
        }
        return out
    }

    /// The declared opening balance (public convenience for AppModel delegation).
    public static func openingBalance(in text: String) -> Decimal? { Balances.opening(text) }

    /// The credit-summary (limit, available) figures (public convenience).
    public static func creditSummary(in text: String) -> (limit: Decimal?, available: Decimal?) {
        CreditSummary.parse(text)
    }

    /// The statement period (public convenience for AppModel delegation).
    public static func statementPeriod(in text: String) -> CalendarDateRange? { Dates.period(text) }
    public static func statementDate(in text: String) -> CalendarDate? { Dates.statementDate(text) }
    public static func holder(in text: String) -> String? { AccountDetails.holder(text) }

    // MARK: - Date parsing helpers

    private static let posix = Locale(identifier: "en_US_POSIX")

    private static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    /// A single date token: "15 June 2026", "June 15, 2026", "15/06/2026",
    /// "2026-06-15".
    private static let dateExpr =
        #"(?:\d{1,2}\s+[A-Za-z]{3,9}\.?,?\s+\d{4}|[A-Za-z]{3,9}\.?\s+\d{1,2},?\s+\d{4}|\d{1,2}/\d{1,2}/\d{2,4}|\d{4}-\d{2}-\d{2})"#

    /// Parse one date token into a `CalendarDate`, or nil. Public so callers can
    /// validate a model-extracted date string (accepts only a bare, well-formed date).
    public static func parseDate(_ s: String) -> CalendarDate? {
        let t = s.trimmingCharacters(in: .whitespaces)
        // ISO: 2026-06-15
        if let g = firstThreeGroups(t, #"^(\d{4})-(\d{2})-(\d{2})$"#),
           let y = Int(g.0), let m = Int(g.1), let d = Int(g.2) {
            return CalendarDate(year: y, month: m, day: d)
        }
        // DD/MM/YYYY (UK order)
        if let g = firstThreeGroups(t, #"^(\d{1,2})/(\d{1,2})/(\d{2,4})$"#),
           let d = Int(g.0), let m = Int(g.1), var y = Int(g.2) {
            if y < 100 { y += 2000 }
            return CalendarDate(year: y, month: m, day: d)
        }
        // DD Month YYYY
        if let g = firstThreeGroups(t, #"^(\d{1,2})\s+([A-Za-z]{3,9})\.?,?\s+(\d{4})$"#),
           let d = Int(g.0), let m = monthNumber(g.1), let y = Int(g.2) {
            return CalendarDate(year: y, month: m, day: d)
        }
        // Month DD YYYY
        if let g = firstThreeGroups(t, #"^([A-Za-z]{3,9})\.?\s+(\d{1,2}),?\s+(\d{4})$"#),
           let m = monthNumber(g.0), let d = Int(g.1), let y = Int(g.2) {
            return CalendarDate(year: y, month: m, day: d)
        }
        return nil
    }

    private static func monthNumber(_ name: String) -> Int? {
        months[String(name.lowercased().prefix(3))]
    }

    // MARK: - Regex plumbing

    private static func firstGroup(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func firstTwoGroups(_ s: String, _ pattern: String) -> (String, String)? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges > 2,
              let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s) else { return nil }
        return (String(s[r1]), String(s[r2]))
    }

    private static func firstThreeGroups(_ s: String, _ pattern: String) -> (String, String, String)? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges > 3,
              let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s),
              let r3 = Range(m.range(at: 3), in: s) else { return nil }
        return (String(s[r1]), String(s[r2]), String(s[r3]))
    }
}
