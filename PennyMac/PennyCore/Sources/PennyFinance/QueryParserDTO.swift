import Foundation
import PennyModel

/// The restricted vocabulary an LLM parser maps a question onto (Rahul's design,
/// 2026-09-03): a FLAT, small-model-friendly shape — the model never does date
/// math (it emits a period TOKEN our code resolves against today), never invents
/// operations (enum-constrained), and never sees transactions. The deterministic
/// mapper below turns a DTO into a validated `Query`; anything it can't resolve
/// becomes a `MappingError` whose message is fed back to the model for ONE retry.
public struct ParsedQueryDTO: Codable, Equatable, Sendable {
    /// sum | count | average | min | max | top_n | list
    public var aggregate: String
    /// debit | credit — omit when the question doesn't imply a direction.
    public var direction: String?
    /// Entity names as the user said them (the mapper resolves typos/synonyms).
    public var category: String?
    public var merchant: String?
    public var account: String?
    /// Period token: all | today | yesterday | this_week | last_week | this_month |
    /// last_month | this_year | last_year | last_7_days | last_30_days |
    /// last_90_days | YYYY | YYYY-MM | YYYY-MM-DD | YYYY-MM-DD..YYYY-MM-DD |
    /// a month name, optionally with a year ("november", "november 2025").
    public var period: String?
    public var amountMin: Double?
    public var amountMax: Double?
    /// month | day | category | merchant | account | currency
    public var groupBy: String?
    /// Required when aggregate is top_n.
    public var topN: Int?
    /// Free-text needle when no structured entity fits ("upi", "refund").
    public var text: String?

    public init(aggregate: String, direction: String? = nil, category: String? = nil,
                merchant: String? = nil, account: String? = nil, period: String? = nil,
                amountMin: Double? = nil, amountMax: Double? = nil, groupBy: String? = nil,
                topN: Int? = nil, text: String? = nil) {
        self.aggregate = aggregate; self.direction = direction; self.category = category
        self.merchant = merchant; self.account = account; self.period = period
        self.amountMin = amountMin; self.amountMax = amountMax; self.groupBy = groupBy
        self.topN = topN; self.text = text
    }
}

/// Why a DTO could not become a `Query` — the message is model-readable and is
/// appended to the retry prompt ("'summ' is invalid; allowed: sum, count, …").
public struct QueryMappingError: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public enum QueryDTOMapper {

    /// Deterministically map a parsed DTO to an executable `Query`, resolving
    /// entities against the data's vocabulary and the period token against
    /// `today`. Pure and total: same inputs, same output, no I/O.
    public static func map(_ dto: ParsedQueryDTO, vocabulary: QueryVocabulary,
                           today: CalendarDate) -> Result<Query, QueryMappingError> {
        var filters: [Filter] = []
        var sort: [SortKey] = []

        // aggregate
        let aggregate: Aggregation
        switch dto.aggregate.lowercased() {
        case "sum": aggregate = .sum
        case "count": aggregate = .count
        case "average", "avg", "mean": aggregate = .average
        case "min": aggregate = .min
        case "max": aggregate = .max
        case "list": aggregate = .list
        case "top_n", "topn":
            guard let n = dto.topN, n > 0, n <= 100 else {
                return .failure(QueryMappingError("aggregate top_n requires topN between 1 and 100"))
            }
            aggregate = .topN(n)
            sort = [SortKey(.amount, .descending)]
        default:
            return .failure(QueryMappingError(
                "invalid aggregate '\(dto.aggregate)'; allowed: sum, count, average, min, max, top_n, list"))
        }

        // direction
        if let d = dto.direction?.lowercased(), !d.isEmpty {
            switch d {
            case "debit", "out", "spend": filters.append(.direction(.debit))
            case "credit", "in", "income": filters.append(.direction(.credit))
            default:
                return .failure(QueryMappingError("invalid direction '\(d)'; allowed: debit, credit"))
            }
        }

        // category (typo/synonym tolerant — the same forgiveness the router has)
        if let raw = dto.category?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            guard let cat = resolveCategory(raw, in: vocabulary.categories) else {
                let sample = vocabulary.categories.prefix(12).joined(separator: ", ")
                return .failure(QueryMappingError(
                    "unknown category '\(raw)'; categories present in the data: \(sample)"))
            }
            filters.append(.category(CategoryID(cat)))
        }

        // merchant — engine resolves names itself and text-falls-back, so pass through.
        if let m = dto.merchant?.trimmingCharacters(in: .whitespaces), !m.isEmpty {
            filters.append(.merchant(.name(m)))
        }

        // account
        if let raw = dto.account?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            let low = raw.lowercased()
            let hits = vocabulary.accounts.filter {
                $0.name.lowercased().contains(low) || low.contains($0.name.lowercased())
            }
            guard hits.count == 1, let hit = hits.first else {
                let names = vocabulary.accounts.map(\.name).joined(separator: ", ")
                return .failure(QueryMappingError(hits.isEmpty
                    ? "unknown account '\(raw)'; accounts present: \(names)"
                    : "ambiguous account '\(raw)' (matches \(hits.map(\.name).joined(separator: " & "))); accounts present: \(names)"))
            }
            filters.append(.account(AccountID(hit.id)))
        }

        // period token → date range (OUR date math, anchored on `today`).
        // A bare GRAIN word here ("month", "monthly") is a mis-slotted groupBy
        // ("spending by month" → period:"month" is a common small-model slip) —
        // absorb it instead of failing the parse.
        var groupByRaw = dto.groupBy
        if let token = dto.period?.trimmingCharacters(in: .whitespaces).lowercased(),
           !token.isEmpty, token != "all" {
            if ["month", "months", "monthly", "day", "days", "daily"].contains(token), groupByRaw == nil {
                groupByRaw = token.hasPrefix("d") ? "day" : "month"
            } else {
                switch resolvePeriod(token, today: today, months: vocabulary.months) {
                case .success(let range): filters.append(.dateRange(range))
                case .failure(let e): return .failure(e)
                }
            }
        }

        // amount bounds (magnitude)
        if dto.amountMin != nil || dto.amountMax != nil {
            filters.append(.amount(ComparableRange(
                lowerBound: dto.amountMin.map { Decimal($0) },
                upperBound: dto.amountMax.map { Decimal($0) })))
        }

        // free text — but never intent-word noise: a leaked "spending"/"money"
        // would text-filter descriptions and produce a confidently wrong zero.
        let textNoise: Set<String> = ["spending", "spend", "spent", "money", "amount",
                                      "total", "transaction", "transactions", "payment",
                                      "payments", "expense", "expenses", "income",
                                      "purchases", "cost", "debit", "debits", "credit",
                                      "credits"]
        if let t = dto.text?.trimmingCharacters(in: .whitespaces), !t.isEmpty,
           !textNoise.contains(t.lowercased()) {
            filters.append(.text(t))
        }

        // group by ("monthly" → month; small-model slips are absorbed above)
        var groupBy: Grouping?
        if var g = groupByRaw?.lowercased(), !g.isEmpty {
            if g.hasSuffix("ly") { g = String(g.dropLast(2)) }        // monthly/daily
            if g == "dai" { g = "day" }
            guard let grouping = Grouping(rawValue: g) else {
                return .failure(QueryMappingError(
                    "invalid groupBy '\(g)'; allowed: \(Grouping.allCases.map(\.rawValue).joined(separator: ", "))"))
            }
            groupBy = grouping
        }

        return .success(Query(filters: filters, aggregate: aggregate, groupBy: groupBy, sort: sort))
    }

    // MARK: - category resolution (exact → synonym stem → edit distance)

    static func resolveCategory(_ raw: String, in present: [String]) -> String? {
        let low = raw.lowercased()
        if let exact = present.first(where: { $0.lowercased() == low }) { return exact }
        // Space-insensitive ("fastfood" → "Fast Food").
        let squashed = low.replacingOccurrences(of: " ", with: "")
        if let hit = present.first(where: { $0.lowercased().replacingOccurrences(of: " ", with: "") == squashed }) {
            return hit
        }
        for (stem, canonical) in ScopeLexicon.categorySynonyms
        where low.hasPrefix(stem) || low.split(separator: " ").contains(where: { $0.hasPrefix(stem) }) {
            if let hit = present.first(where: { $0.caseInsensitiveCompare(canonical) == .orderedSame }) {
                return hit
            }
        }
        // Typo tolerance — same Damerau-Levenshtein thresholds as the router's
        // nearMatch (duplicated here because PennyFinance deliberately depends
        // only on PennyModel; keep the thresholds in sync).
        return present.first { nearMatch(low, $0.lowercased()) }
    }

    static func nearMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        let n = x.count, m = y.count
        let maxDist = Swift.min(n, m) >= 9 ? 2 : (Swift.min(n, m) >= 5 ? 1 : 0)
        guard maxDist > 0, abs(n - m) <= maxDist else { return false }
        var prev2 = [Int](repeating: 0, count: m + 1)
        var prev = Array(0...m)
        var cur = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            cur[0] = i
            for j in 1...m {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    cur[j] = Swift.min(cur[j], prev2[j - 2] + 1)
                }
            }
            (prev2, prev, cur) = (prev, cur, prev2)
        }
        return prev[m] <= maxDist
    }

    // MARK: - period tokens (the model NEVER does date math)

    static func resolvePeriod(_ token: String, today: CalendarDate,
                              months: [String]) -> Result<CalendarDateRange, QueryMappingError> {
        func monthRange(_ year: Int, _ month: Int) -> CalendarDateRange {
            CalendarDateRange(start: CalendarDate(year: year, month: month, day: 1),
                              end: CalendarDate(year: year, month: month, day: daysIn(year, month)))
        }
        func yearRange(_ y: Int) -> CalendarDateRange {
            CalendarDateRange(start: CalendarDate(year: y, month: 1, day: 1),
                              end: CalendarDate(year: y, month: 12, day: 31))
        }
        switch token {
        case "today": return .success(CalendarDateRange(start: today, end: today))
        case "yesterday":
            let d = addDays(today, -1); return .success(CalendarDateRange(start: d, end: d))
        case "this_week", "last_week":
            let end = token == "this_week" ? today : addDays(today, -7)
            return .success(CalendarDateRange(start: addDays(end, -6), end: end))
        case "this_month": return .success(monthRange(today.year, today.month))
        case "last_month":
            let (y, m) = today.month == 1 ? (today.year - 1, 12) : (today.year, today.month - 1)
            return .success(monthRange(y, m))
        case "this_year": return .success(yearRange(today.year))
        case "last_year": return .success(yearRange(today.year - 1))
        case "last_7_days": return .success(CalendarDateRange(start: addDays(today, -6), end: today))
        case "last_30_days": return .success(CalendarDateRange(start: addDays(today, -29), end: today))
        case "last_90_days": return .success(CalendarDateRange(start: addDays(today, -89), end: today))
        default: break
        }
        // YYYY / YYYY-MM / YYYY-MM-DD / YYYY-MM-DD..YYYY-MM-DD
        if let y = Int(token), (1990...2100).contains(y) { return .success(yearRange(y)) }
        let isoParts = token.split(separator: "-").compactMap { Int($0) }
        if isoParts.count == 2, (1...12).contains(isoParts[1]) {
            return .success(monthRange(isoParts[0], isoParts[1]))
        }
        if token.contains("..") {
            let sides = token.components(separatedBy: "..")
            if sides.count == 2, let s = isoDate(sides[0]), let e = isoDate(sides[1]) {
                return .success(CalendarDateRange(start: Swift.min(s, e), end: Swift.max(s, e)))
            }
        }
        if let d = isoDate(token) { return .success(CalendarDateRange(start: d, end: d)) }
        // Month name, optional year. Bare month name → the LATEST matching month
        // present in the data (router semantics), else that month of today's year.
        let words = token.split(separator: "_").flatMap { $0.split(separator: " ") }.map(String.init)
        if let first = words.first, let m = monthNumber(first) {
            if words.count >= 2, let y = Int(words[1]) { return .success(monthRange(y, m)) }
            let key = String(format: "-%02d", m)
            if let present = months.last(where: { $0.hasSuffix(key) }),
               let y = Int(present.prefix(4)) {
                return .success(monthRange(y, m))
            }
            return .success(monthRange(today.year, m))
        }
        return .failure(QueryMappingError(
            "invalid period '\(token)'; use tokens like last_month, this_year, last_30_days, 2025-11, november 2025, or YYYY-MM-DD..YYYY-MM-DD"))
    }

    // MARK: - date helpers (pure, no Foundation Calendar — deterministic everywhere)

    static func daysIn(_ year: Int, _ month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        }
    }

    static func addDays(_ d: CalendarDate, _ delta: Int) -> CalendarDate {
        var (y, m, day) = (d.year, d.month, d.day + delta)
        while day < 1 {
            m -= 1
            if m < 1 { m = 12; y -= 1 }
            day += daysIn(y, m)
        }
        while day > daysIn(y, m) {
            day -= daysIn(y, m)
            m += 1
            if m > 12 { m = 1; y += 1 }
        }
        return CalendarDate(year: y, month: m, day: day)
    }

    private static func isoDate(_ s: String) -> CalendarDate? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...12).contains(p[1]), (1...31).contains(p[2]) else { return nil }
        return CalendarDate(year: p[0], month: p[1], day: p[2])
    }

    private static func monthNumber(_ w: String) -> Int? {
        let names = ["january", "february", "march", "april", "may", "june", "july",
                     "august", "september", "october", "november", "december"]
        let low = w.lowercased()
        if let i = names.firstIndex(where: { $0 == low || ($0.hasPrefix(low) && low.count >= 3) }) {
            return i + 1
        }
        return nil
    }
}
