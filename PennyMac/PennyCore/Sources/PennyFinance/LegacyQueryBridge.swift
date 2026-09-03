import Foundation
import PennyModel

/// Deterministic intent → `Query` bridge (Phase 1). A pure, regex-based recognizer
/// — **no AI** (the LLM intent parser is Phase 3). It exists so the chat layer can
/// route the common deterministic question shapes through the new engine while
/// `FinanceRouter` stays as the fallback for anything it doesn't map
/// (wrap-then-delete). Returns `nil` when it doesn't recognize the question, so the
/// caller falls back to the legacy path.
public enum LegacyQueryBridge {

    /// Interpret a question into a `Query`. `context` supplies the data vocabulary
    /// for scope resolution (Wave B); unscoped aggregate intents (Wave A1) ignore it.
    public static func query(for question: String, context: QueryContext = .empty) -> Query? {
        let q = question.lowercased()

        // Advisory / opinion / open-ended → not a deterministic query; fall back to
        // the model (mirrors FinanceRouter's advisory guard).
        if matches(q, #"\broast\b|\badvice\b|\badvise\b|recommend|worth it|forecast|predict\b|\bwhy\b|worried|healthy|can i afford|help me|save money|\bsuggest\b"#) {
            return nil
        }

        // Shapes FinanceRouter answers with a specialized handler the engine has
        // no capability for yet (comparisons, ratio, trend, payday, day-of-week,
        // month halves, fixed/recurring outflow, donations, duplicates, top-N
        // categories). Mapping them to a plain sum here would make the DEBUG
        // parity guard log false divergences — decline so the router owns them.
        if matches(q, #"\bvs\.?\b|\bversus\b|compared? (?:to|with|against)|\bratio\b|\btrend(?:ing|s)?\b|going (?:up|down)|(?:get|got|getting|being|usually) paid\b|\bpayday\b|day of the week|\bweekday\b|first half|second half|\bfixed\b|donat\w*|charit\w*|duplicat\w*|\btwice\b|(?:top|biggest|largest)\s+(?:\d+\s+)?\w{0,12}\s*categor"#) {
            return nil
        }

        // Direction scope shared by several intents.
        let spendWords = #"\bspen[dt]\w*|\bspending\b|\bexpenditure\b|\boutgoing\b|\bpaid\b|\bcost\b"#
        let incomeWords = #"\bincome\b|\bearn\w*|\breceiv\w*|\bcredited\b|\bsalary\b|\bdeposits?\b"#

        // Structured scope (Wave B1): merchant / category / account / currency / date,
        // resolved from the vocabulary and AND-combined ahead of each intent's own
        // direction filter. Empty when nothing matches (so unscoped intents are
        // unchanged). Balance/recurring intents stay unscoped for now.
        let sf = ScopeResolver.resolve(q, vocabulary: context.vocabulary).filters

        // ---- counts ----
        if matches(q, #"\bhow many\b|\bnumber of\b|\bcount\b"#),
           matches(q, #"transactions?|txns?|purchases?|payments?|credits?|debits?|withdrawals?|charges?"#) {
            if matches(q, incomeWords) || matches(q, #"\bcredits?\b|\bmoney came in\b|\bincoming\b|\bdeposits?\b"#) {
                return Query(filters: sf + [.direction(.credit)], aggregate: .count)
            }
            if matches(q, spendWords) || matches(q, #"\bdebits?\b|\bwithdrawals?\b|\bcharges?\b|\bsent out\b|\bmoney went out\b|\bpayments?\b|\bmade\b"#) {
                return Query(filters: sf + [.direction(.debit)], aggregate: .count)
            }
            return Query(filters: sf, aggregate: .count)
        }

        // ---- largest / biggest expense ----
        if matches(q, #"\b(biggest|largest|highest|most expensive|priciest)\b"#),
           matches(q, #"expense|spend|cost|transaction|payment|purchase|debit|buy"#) {
            return Query(filters: sf + [.direction(.debit)], aggregate: .max)
        }
        // ---- largest credit / income ----
        if matches(q, #"\b(biggest|largest|highest)\b"#), matches(q, #"credit|deposit|income|received"#) {
            return Query(filters: sf + [.direction(.credit)], aggregate: .max)
        }
        // ---- smallest / cheapest expense ----
        if matches(q, #"\b(smallest|lowest|cheapest|least expensive|tiniest)\b"#),
           matches(q, #"expense|spend|cost|transaction|payment|purchase|debit|buy"#),
           !matches(q, #"categor|month|year|merchant|shop|store|place|account|bank|statement|day\b|weekday"#) {
            return Query(filters: sf + [.direction(.debit)], aggregate: .min)
        }

        // ---- top N expenses / merchants ----
        if let n = firstInt(q, #"\btop\s+(\d+)\b"#) {
            if matches(q, #"merchant"#) {
                return Query(filters: sf, aggregate: .topN(n), groupBy: .merchant, sort: [SortKey(.amount, .descending)])
            }
            return Query(filters: sf + [.direction(.debit)], aggregate: .topN(n), sort: [SortKey(.amount, .descending)])
        }

        // ---- average transaction (per-transaction; per-month avg is deferred) ----
        if matches(q, #"\baverage\b|\bavg\b|\bmean\b|\btypical\b"#),
           !matches(q, #"per month|monthly|each month|a month"#) {
            return Query(filters: sf + [.direction(.debit)], aggregate: .average)
        }

        // ---- net cash flow / profit / loss / savings (signed sum of everything) ----
        if matches(q, #"\bnet\b|cash\s*flow|\bprofit\b|\bloss\b|\bsurplus\b|left\s*-?\s*over|net income|made or lost"#)
            || (matches(q, #"\bsav(?:e|ed|ings?)\b"#) && !matches(q, #"rate|target|goal|should|money"#)) {
            return Query(filters: sf, aggregate: .sum)
        }

        // ---- monthly summary (spend grouped by month) ----
        if matches(q, #"by month|per month|monthly|each month|month[- ]by[- ]month"#),
           !matches(q, #"\baverage\b|\bavg\b"#) {
            return Query(filters: sf + [.direction(.debit)], aggregate: .sum, groupBy: .month)
        }

        // ---- recurring charges / subscriptions (Wave A2) ----
        if matches(q, #"subscription|recurr|standing order|direct debit|regular (?:payment|charge)"#) {
            return Query(filters: [.recurring], aggregate: .count)
        }

        // ---- balances (Wave A2). Balance-at-a-date needs date parsing (Wave B). ----
        if matches(q, #"\bbalance\b|how much do i have|money in my account|in my account"#) {
            if matches(q, #"\bopening\b|\bstarting\b|\binitial\b|\bbeginning\b|brought forward"#) {
                return Query(aggregate: .balance(.opening))
            }
            if matches(q, #"\bclosing\b"#) {
                return Query(aggregate: .balance(.closing))
            }
            return Query(aggregate: .balance(.running))
        }

        // ---- spending by category ----
        if matches(q, #"by category|category breakdown|spending by categor|where.*money go"#) {
            return Query(filters: sf + [.direction(.debit)], aggregate: .sum, groupBy: .category)
        }

        // ---- itemised credit/debit list → decline ----
        // FinanceRouter now answers "list my credits / show me my deposits" with
        // an itemised list; the engine has no list capability yet, so mapping
        // those to .sum would make the parity guard log a false divergence.
        if matches(q, #"\blist\b|show (?:me|all|my|the)|itemi[sz]e|let me see"#),
           !matches(q, #"how much|how many|\btotal\b|\bcount\b|average|\bavg\b"#) {
            return nil
        }

        // ---- total income ----
        if matches(q, incomeWords), !matches(q, spendWords) {
            return Query(filters: sf + [.direction(.credit)], aggregate: .sum)
        }

        // ---- total spending (catch-all numeric) ----
        if matches(q, spendWords) || matches(q, #"\btotal\b|\bhow much\b|\baltogether\b"#) {
            return Query(filters: sf + [.direction(.debit)], aggregate: .sum)
        }

        return nil
    }

    // MARK: - helpers

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression]) != nil
    }

    private static func firstInt(_ s: String, _ pattern: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }
}
