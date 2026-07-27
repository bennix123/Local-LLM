import Foundation
import PennyModel

/// How a candidate was found — kept so disambiguation and callers can prefer exact
/// evidence over aliases/synonyms.
public enum MatchSource: Equatable, Sendable { case exact, alias, synonym, explicitDate, relativeDate }

/// One thing the matcher found in the text. Matching produces candidates; it does
/// **not** decide the final scope — that is resolution/disambiguation's job. `length`
/// is the surface-form length, used for longest-match refinement.
public struct ScopeCandidate: Equatable, Sendable {
    public let kind: ScopeMatch.Kind
    public let canonical: String
    public let filter: Filter
    public let length: Int
    public let source: MatchSource
}

/// The **matching** stage (Resolve step): scan a normalized question for every entity
/// and date it could refer to, against the vocabulary + lexicon. Emits all candidates
/// (including competing ones); picking winners is disambiguation's job. Pure.
public enum ScopeMatcher {

    public static func match(_ nq: NormalizedQuery, vocabulary v: QueryVocabulary) -> [ScopeCandidate] {
        let q = nq.text
        var out: [ScopeCandidate] = []

        // categories — exact name (word) + synonym (word-stem), resolved to present ones
        for name in v.categories where word(q, name) {
            out.append(.init(kind: .category, canonical: name, filter: .category(CategoryID(name)),
                             length: name.count, source: .exact))
        }
        for (stem, category) in ScopeLexicon.categorySynonyms where wordStem(q, stem) {
            if let present = v.categories.first(where: { $0.caseInsensitiveCompare(category) == .orderedSame }) {
                out.append(.init(kind: .category, canonical: present, filter: .category(CategoryID(present)),
                                 length: stem.count, source: .synonym))
            }
        }

        // merchants — exact name (word) + alias (word), resolved to present ones
        for name in v.merchants where word(q, name) {
            out.append(.init(kind: .merchant, canonical: name, filter: .merchant(.name(name)),
                             length: name.count, source: .exact))
        }
        for (alias, needle) in ScopeLexicon.merchantAliases where word(q, alias) {
            if let present = v.merchants.first(where: { $0.lowercased().contains(needle) }) {
                out.append(.init(kind: .merchant, canonical: present, filter: .merchant(.name(present)),
                                 length: alias.count, source: .alias))
            }
        }

        // accounts — exact name, resolved to id
        for a in v.accounts where word(q, a.name) {
            out.append(.init(kind: .account, canonical: a.name, filter: .account(AccountID(a.id)),
                             length: a.name.count, source: .exact))
        }

        // currency — code or symbol, only if present in the data
        if let cur = currency(q, present: Set(v.currencies)) {
            out.append(.init(kind: .currency, canonical: cur, filter: .currency(Currency(cur)),
                             length: 3, source: .exact))
        }

        // date — explicit forms first, else a relative form anchored to the data's months
        if let c = explicitDate(q) { out.append(c) }
        else if let c = relativeDate(q, months: v.months) { out.append(c) }

        return out
    }

    // MARK: - text matching

    /// Whole-word containment (letter/digit boundaries): "rent" never hits "current".
    static func word(_ q: String, _ needle: String) -> Bool {
        let n = needle.lowercased()
        guard !n.isEmpty else { return false }
        return q.range(of: "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: n) + "(?![a-z0-9])",
                       options: .regularExpression) != nil
    }

    /// Word-STEM match: a whole word that *starts* with the stem ("grocer" →
    /// "grocery"/"groceries"), never a stem buried mid-word ("rent" in "current").
    static func wordStem(_ q: String, _ stem: String) -> Bool {
        let n = stem.lowercased()
        guard !n.isEmpty else { return false }
        return q.range(of: "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: n) + "[a-z]*(?![a-z0-9])",
                       options: .regularExpression) != nil
    }

    private static let currencyByCode = ["gbp": "GBP", "usd": "USD", "eur": "EUR", "inr": "INR"]
    private static let currencyBySymbol = ["£": "GBP", "$": "USD", "€": "EUR", "\u{20B9}": "INR"]

    private static func currency(_ q: String, present: Set<String>) -> String? {
        for (code, iso) in currencyByCode where present.contains(iso) && word(q, code) { return iso }
        for (sym, iso) in currencyBySymbol where present.contains(iso) && q.contains(sym) { return iso }
        return nil
    }

    // MARK: - dates

    static let monthNames: [(String, Int)] = [
        ("january", 1), ("february", 2), ("march", 3), ("april", 4), ("may", 5), ("june", 6),
        ("july", 7), ("august", 8), ("september", 9), ("october", 10), ("november", 11), ("december", 12),
        ("jan", 1), ("feb", 2), ("mar", 3), ("apr", 4), ("jun", 6), ("jul", 7), ("aug", 8),
        ("sep", 9), ("sept", 9), ("oct", 10), ("nov", 11), ("dec", 12),
    ]
    static let monthAbbr = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private static func explicitDate(_ q: String) -> ScopeCandidate? {
        func dateCand(_ range: CalendarDateRange, _ value: String, _ len: Int) -> ScopeCandidate {
            ScopeCandidate(kind: .date, canonical: value, filter: .dateRange(range), length: len, source: .explicitDate)
        }
        if let g = groups(q, #"\b(\d{4})-(\d{2})-(\d{2})\b"#),
           let y = Int(g[1]), let m = Int(g[2]), let d = Int(g[3]), valid(y, m, d) {
            return dateCand(day(y, m, d), "on \(d) \(monthAbbr[m]) \(y)", 10)
        }
        if let g = groups(q, #"\b(\d{1,2})/(\d{1,2})/(\d{4})\b"#),
           let d = Int(g[1]), let m = Int(g[2]), let y = Int(g[3]), valid(y, m, d) {
            return dateCand(day(y, m, d), "on \(d) \(monthAbbr[m]) \(y)", 10)
        }
        for (name, no) in monthNames {
            if let g = groups(q, #"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?"# + name + #"\s+(\d{4})\b"#),
               let d = Int(g[1]), let y = Int(g[2]), valid(y, no, d) {
                return dateCand(day(y, no, d), "on \(d) \(monthAbbr[no]) \(y)", 10)
            }
            if let g = groups(q, #"\b"# + name + #"\s+(\d{1,2})(?:st|nd|rd|th)?\s+(\d{4})\b"#),
               let d = Int(g[1]), let y = Int(g[2]), valid(y, no, d) {
                return dateCand(day(y, no, d), "on \(d) \(monthAbbr[no]) \(y)", 10)
            }
        }
        for (name, no) in monthNames {
            if let g = groups(q, #"\b"# + name + #"\s+(\d{4})\b"#), let y = Int(g[1]) {
                return dateCand(month(y, no), "\(name.prefix(1).uppercased() + name.dropFirst()) \(y)", 8)
            }
        }
        if let g = groups(q, #"\b(\d{4})-(\d{2})\b"#), let y = Int(g[1]), let m = Int(g[2]), (1...12).contains(m) {
            return dateCand(month(y, m), "\(monthAbbr[m]) \(y)", 7)
        }
        if let g = groups(q, #"\b((?:19|20)\d{2})\b"#), let y = Int(g[1]) {
            return dateCand(CalendarDateRange(start: CalendarDate(year: y, month: 1, day: 1),
                                              end: CalendarDate(year: y, month: 12, day: 31)), "\(y)", 4)
        }
        return nil
    }

    /// Relative periods anchored to the DATA's months/years (deterministic — no
    /// wall clock), mirroring FinanceRouter.matchPeriod's this/last-month semantics.
    private static func relativeDate(_ q: String, months: [String]) -> ScopeCandidate? {
        func ym(_ s: String) -> (Int, Int)? {
            let p = s.split(separator: "-"); guard p.count == 2, let y = Int(p[0]), let m = Int(p[1]) else { return nil }
            return (y, m)
        }
        func cand(_ range: CalendarDateRange, _ value: String) -> ScopeCandidate {
            ScopeCandidate(kind: .date, canonical: value, filter: .dateRange(range), length: value.count, source: .relativeDate)
        }
        guard !months.isEmpty else { return nil }
        let sorted = months.sorted()
        let years = sorted.compactMap { ym($0)?.0 }
        if word(q, "this month") || word(q, "current month"), let (y, m) = ym(sorted.last!) {
            return cand(month(y, m), "this month")
        }
        if word(q, "last month") || word(q, "previous month") {
            let pick = sorted.count >= 2 ? sorted[sorted.count - 2] : sorted[0]
            if let (y, m) = ym(pick) { return cand(month(y, m), "last month") }
        }
        if word(q, "this year") || word(q, "current year"), let y = years.max() {
            return cand(year(y), "this year")
        }
        if word(q, "last year") || word(q, "previous year") {
            let distinct = Array(Set(years)).sorted()
            let y = distinct.count >= 2 ? distinct[distinct.count - 2] : (distinct.last ?? 0)
            if y > 0 { return cand(year(y), "last year") }
        }
        return nil
    }

    // MARK: - date helpers

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> CalendarDateRange {
        let date = CalendarDate(year: y, month: m, day: d); return CalendarDateRange(start: date, end: date)
    }
    private static func month(_ y: Int, _ m: Int) -> CalendarDateRange {
        CalendarDateRange(start: CalendarDate(year: y, month: m, day: 1),
                          end: CalendarDate(year: y, month: m, day: daysIn(y, m)))
    }
    private static func year(_ y: Int) -> CalendarDateRange {
        CalendarDateRange(start: CalendarDate(year: y, month: 1, day: 1),
                          end: CalendarDate(year: y, month: 12, day: 31))
    }
    private static func valid(_ y: Int, _ m: Int, _ d: Int) -> Bool {
        y > 0 && (1...12).contains(m) && (1...daysIn(y, m)).contains(d)
    }
    private static func daysIn(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default: return (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28
        }
    }
    private static func groups(_ s: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
    }
}
