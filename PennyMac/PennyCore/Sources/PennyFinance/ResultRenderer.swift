import Foundation
import PennyModel

/// Deterministic `QueryResult` → answer text. The LLM never touches this: every
/// figure comes from the engine, currencies never blend (mixed-currency scalars
/// arrive pre-split as groups), and dates render human ("8th September 2026").
public enum ResultRenderer {

    /// `money` formats an amount in a currency code (nil code → caller's default).
    /// `vocabulary` resolves account ids back to display names for the label.
    public static func render(_ result: QueryResult, query: Query,
                              vocabulary: QueryVocabulary,
                              money: (Decimal, String?) -> String) -> String? {
        let label = scopeLabel(query, vocabulary: vocabulary)
        let wantsCredit = query.filters.contains(.direction(.credit))
        let wantsDebit = query.filters.contains(.direction(.debit))

        // Grouped output — either an explicit groupBy or a mixed-currency split.
        if let groups = result.groups, !groups.isEmpty {
            if let grouping = query.groupBy {
                var lines = ["**By \(grouping.rawValue)\(label):**"]
                for (i, g) in groups.prefix(8).enumerated() {
                    lines.append("\(i + 1). \(g.key) — \(scalarText(g.result, money: money))")
                }
                if groups.count > 8 { lines.append("_…and \(groups.count - 8) more_") }
                return lines.joined(separator: "\n")
            }
            // Per-currency split of a scalar: one figure per currency, joined.
            let parts = groups.map { "\($0.key) \(scalarText($0.result, money: money))" }
            let verb = wantsCredit ? "You received" : (wantsDebit ? "You spent" : "Net")
            return "**\(verb)\(label):** " + parts.joined(separator: " · ")
        }

        switch result.scalar {
        case .some(.count(let n)):
            let noun = wantsCredit ? "credit" : (wantsDebit ? "debit" : "transaction")
            return "**\(n) \(noun)\(n == 1 ? "" : "s")\(label).**"
        case .some(.money(let m)):
            let cur = result.currency?.code
            let n = result.citations.count
            switch query.aggregate {
            case .average:
                return "**Average: \(money(m, cur)) per transaction\(label)** across \(n) transaction\(n == 1 ? "" : "s")."
            case .min, .max:
                let superlative = query.aggregate == .max
                    ? (wantsCredit ? "largest credit" : "largest expense")
                    : (wantsCredit ? "smallest credit" : "smallest expense")
                if let t = result.rows.first {
                    return "**Your \(superlative) was \(money(m, cur))** — \(descr(t)) (\(pretty(t.date)))."
                }
                return "**Your \(superlative) was \(money(m, cur))\(label).**"
            default:
                if wantsCredit {
                    return "**You received \(money(m, cur))\(label)** across \(n) transaction\(n == 1 ? "" : "s")."
                }
                if wantsDebit {
                    return "**You spent \(money(m, cur))\(label)** across \(n) transaction\(n == 1 ? "" : "s")."
                }
                return "**Net\(label): \(money(m, cur))** (income − spend, \(n) transaction\(n == 1 ? "" : "s"))."
            }
        case .some(.none):
            return "**Nothing matching\(label.isEmpty ? " that" : label) in your data.**"
        case nil:
            break
        }

        // list / topN
        if !result.rows.isEmpty {
            let shown = result.rows.prefix(10)
            var lines = ["**\(result.rows.count) transaction\(result.rows.count == 1 ? "" : "s")\(label):**"]
            for t in shown {
                let dir = t.direction == .credit ? " in" : ""
                lines.append("- \(pretty(t.date)) — \(descr(t)): \(money(t.amount.magnitude, t.currency.code))\(dir)")
            }
            if result.rows.count > shown.count {
                lines.append("_showing \(shown.count) of \(result.rows.count)_")
            }
            return lines.joined(separator: "\n")
        }
        if query.aggregate == .list || {
            if case .topN = query.aggregate { return true }; return false
        }() {
            return "**No transactions\(label.isEmpty ? "" : label) in your data.**"
        }
        return nil
    }

    // MARK: - pieces

    private static func scalarText(_ r: QueryResult, money: (Decimal, String?) -> String) -> String {
        switch r.scalar {
        case .money(let m):
            let n = r.citations.count
            return "\(money(m, r.currency?.code)) (\(n) txn\(n == 1 ? "" : "s"))"
        case .count(let n): return "\(n)"
        default: return "—"
        }
    }

    /// A FinanceRouter-style label from the query's own filters:
    /// " on Pharmacy at Amazon in Hdfc Savings from 1st … to …".
    public static func scopeLabel(_ query: Query, vocabulary: QueryVocabulary) -> String {
        var parts: [String] = []
        for f in query.filters {
            switch f {
            case .category(let id): parts.append("on \(id.raw)")
            case .merchant(.name(let n)): parts.append("at \(n)")
            case .account(let id):
                let name = vocabulary.accounts.first { $0.id == id.raw }?.name ?? id.raw
                parts.append("from \(name)")
            case .text(let t): parts.append("matching “\(t)”")
            case .dateRange(let r):
                parts.append(r.start == r.end ? "on \(pretty(r.start))"
                                              : "from \(pretty(r.start)) to \(pretty(r.end))")
            case .amount(let r):
                if let lo = r.lowerBound, r.upperBound == nil { parts.append("over \(lo)") }
                else if let hi = r.upperBound, r.lowerBound == nil { parts.append("under \(hi)") }
            default: break
            }
        }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }

    private static func descr(_ t: Transaction) -> String {
        t.enrichment.cleanDescription ?? t.rawDescription
    }

    /// "8th September 2026" — local pretty-printer (PennyFinance deliberately
    /// depends only on PennyModel; keep in step with PennyTxnStore.PrettyDate).
    static func pretty(_ d: CalendarDate) -> String {
        let months = ["January", "February", "March", "April", "May", "June", "July",
                      "August", "September", "October", "November", "December"]
        let suffix: String
        switch d.day {
        case 11, 12, 13: suffix = "th"
        case let n where n % 10 == 1: suffix = "st"
        case let n where n % 10 == 2: suffix = "nd"
        case let n where n % 10 == 3: suffix = "rd"
        default: suffix = "th"
        }
        let month = (1...12).contains(d.month) ? months[d.month - 1] : "?"
        return "\(d.day)\(suffix) \(month) \(d.year)"
    }
}
