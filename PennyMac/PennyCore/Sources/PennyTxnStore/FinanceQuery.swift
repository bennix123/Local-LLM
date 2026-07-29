// FinanceQuery — deterministic natural-language answers over parsed rows.
//
// A focused Swift port of the highest-frequency intents in
// finquery/scripts/test_server/{router,analytics}.py: balance, count,
// largest / top expenses, total spent / income / net, category & merchant
// spend, by-category breakdown, and average — each with optional
// category / merchant / period scoping.
//
// Every figure is summed straight from `[TxnRow]` — NO model. The router
// returns nil when a question isn't a factual numeric lookup (advisory /
// opinion / open-ended), so the caller can fall back to the LLM.
import Foundation

public enum FinanceRouter {

    /// One account's latest balance, for multi-account balance answers.
    /// `isCard` = credit-card semantics: the balance is money OWED, so it
    /// subtracts from the total rather than adding.
    public struct AccountBalance: Sendable {
        public let name: String
        public let balance: Double?
        public let isCard: Bool
        public init(name: String, balance: Double?, isCard: Bool) {
            self.name = name; self.balance = balance; self.isCard = isCard
        }
    }

    /// Deterministically answer `question` from `rows`, or return nil to defer
    /// to the model. `money` formats an amount in the statement's currency
    /// (the app passes its `Money.format`; tests pass a simple formatter).
    /// `accounts` (optional) enables exact multi-account balance answers.
    public static func answer(_ question: String,
                              rows: [TxnRow],
                              currency: String,
                              accounts: [AccountBalance] = [],
                              money: (Double) -> String) -> String? {
        var low = question.lowercased()
        guard !rows.isEmpty else { return nil }

        // Normalise a few very common misspellings of intent words up-front, so a
        // typo like "mcuh"/"totl" doesn't get mistaken for an (absent) merchant and
        // answered as a misleading "£0 on Mcuh".
        for (typo, fix) in [("mcuh", "much"), ("muhc", "much"), ("moch", "much"),
                            ("totl", "total"), ("toatl", "total"), ("transprot", "transport"),
                            ("trasnport", "transport"), ("expence", "expense"),
                            ("expences", "expenses"), ("groceies", "groceries")] {
            low = low.replacingOccurrences(of: #"\b"# + typo + #"\b"#, with: fix,
                                           options: .regularExpression)
        }

        // ---- statement-header metadata → defer -----------------------------
        // Rewards points, credit limit, interest rates, minimum payment, due date,
        // fees, membership/sort/IBAN numbers etc. live in the statement HEADER, not
        // in the transaction rows this router sums. Answering them from rows would
        // be misleading (e.g. "£0 on Minimum"), so defer to the LLM / metadata layer.
        if isHeaderMetadataQuery(low) { return nil }

        // ---- document identity: "which statement is a credit card / current
        // account?" — answered from each account's `isCard` flag, not the merged
        // rows. Must run before the income handler, whose `\bcredits?\b` would
        // otherwise read "credit card" as a request for credit transactions.
        if let ans = accountTypeAnswer(low, accounts: accounts) { return ans }

        let scope = parseScope(low, rows: rows)
        let sr = scope.rows
        let debits = sr.filter { $0.debit > 0 }
        // Card repayments (category "Payments") are you moving your own money,
        // not earnings — they never count as income.
        let credits = sr.filter { $0.credit > 0 && $0.category != "Payments" }
        let cardRepayments = sr.filter { $0.credit > 0 && $0.category == "Payments" }
            .reduce(0) { $0 + $1.credit }
        let spent = debits.reduce(0) { $0 + $1.debit }
        let income = credits.reduce(0) { $0 + $1.credit }

        // ---- what-if: "if I cut Shopping by 20%, how much would I save?" ----
        if let (frac, pctText) = whatIfPercent(low), let name = scope.entity,
           scope.hasCategory || scope.hasMerchant, spent > 0 {
            let months = max(1, Set(sr.map(\.month)).count)
            let saved = spent * frac
            return "**Cutting \(name) by \(pctText)% would save \(money(saved))** — about "
                + "\(money(saved / Double(months)))/month, \(money(saved / Double(months) * 12))/year. "
                + "(\(name) is currently \(money(spent)) over \(months) month\(months == 1 ? "" : "s").)"
        }

        // ---- financial-reasoning block (savings/runway/risky/trend/recurring) ----
        // These are account-wide (period-scoped only, never category/merchant) —
        // matching analytics.py, and so a stray word like "income" in "without
        // income" can't wrongly narrow the scope.
        if let ans = financialReasoning(low, allRows: rows, money: money) {
            return ans
        }

        // ---- exclusion ("how much excluding food", "spend apart from rent") --
        // A category was scoped, but the intent is the total WITHOUT it — invert.
        if scope.hasCategory, let cat = scope.entity,
           matches(low, #"\bexcluding\b|\bexcept(?:ing)?\b|apart from|other than|\bbesides\b|not counting|\bwithout\b|aside from|\bminus\b|\bexclude\b"#) {
            let all = rows.filter { $0.debit > 0 }
            let kept = all.filter { $0.category != cat }
            let tot = kept.reduce(0) { $0 + $1.debit }
            return "**You spent \(money(tot)) excluding \(cat)** across \(grp(kept.count)) transaction\(kept.count == 1 ? "" : "s") "
                + "(\(cat) itself was \(money(spent)))."
        }

        // ---- balance -------------------------------------------------------
        // Defers on "opening / starting balance" — that's a statement-header figure
        // (often with no running balance on the rows at all), handled upstream from
        // the document text, never the latest all-account total.
        // "owe / owed / owing / outstanding" are the credit-card phrasing of the same
        // question ("how much do I owe?") — route them to the balance answer, which
        // renders card closing balances with owed semantics.
        if matches(low, #"\bbalance\b|how much do i have|money in my account|in my account|\bowe[ds]?\b|\bowing\b|\boutstanding\b|how much is (?:due|owed)|left to pay|to pay off|pay off the card|card bill|credit[\s-]?card bill|amount to pay|balance owing|still owe"#),
           !matches(low, #"\b(opening|starting|start|initial|beginning)\s+balance\b|balance\s+(?:brought|carried)\s+forward"#) {
            // balance as of a specific date: last running balance up to that day
            if let iso = scope.dayISO {
                if let bal = rows.filter({ $0.txnDate <= iso })
                    .last(where: { $0.balance != nil })?.balance {
                    return "**Your balance at the end of \(scope.dayLabel ?? iso) was \(money(bal)).**"
                }
                return "This statement doesn't show a running balance on or before \(scope.dayLabel ?? iso)."
            }
            // multi-account: per-account latest balances, cards subtract (owed)
            let withBal = accounts.filter { $0.balance != nil }
            if withBal.count > 1 {
                let banks = withBal.filter { !$0.isCard }.reduce(0) { $0 + $1.balance! }
                let cards = withBal.filter { $0.isCard }.reduce(0) { $0 + $1.balance! }
                var lines = ["**Your total balance is \(money(banks - cards))** across \(withBal.count) accounts:"]
                for a in withBal {
                    lines.append("- \(a.name): \(money(a.balance!))\(a.isCard ? " owed (card)" : "")")
                }
                if cards > 0 { lines.append("_Total = bank balances − card balances._") }
                return lines.joined(separator: "\n")
            }
            if withBal.count == 1, let a = withBal.first, a.isCard {
                return "**You currently owe \(money(a.balance!)) on \(a.name)** (statement closing balance)."
            }
            if let bal = rows.last(where: { $0.balance != nil })?.balance {
                return "**Your latest balance is \(money(bal)).**"
            }
            if let a = withBal.first, let b = a.balance {
                return "**Your latest balance is \(money(b))** (\(a.name), statement closing balance)."
            }
            return "This statement doesn't show a running balance, so I can't give you a current figure."
        }

        // ---- refunds / cashback / reversals ---------------------------------
        // A refund is money BACK — a credit that isn't a card repayment. "How many
        // refunds" must count THESE, not every transaction, and "did I get a refund"
        // is a yes/no over them; both would otherwise be mis-caught by the generic
        // count / income handlers below.
        if matches(low, #"\brefund\w*|\bcashback\b|\bcash\s?back\b|\breversal\w*|\breversed\b|\bchargeback\b|money back|\brebate\b"#) {
            let refunds = credits   // `credits` already excludes card repayments
            if refunds.isEmpty {
                return "**No refunds\(scope.label) — \(money(0)).** I don't see any money-back credits on this statement."
            }
            let noun = refunds.count == 1 ? "refund" : "refunds"
            if matches(low, #"how much|total|worth|value|\bsum\b"#),
               !matches(low, #"how many|number of|\blist\b|show|which|what were"#) {
                return "**You received \(money(income)) in \(noun)\(scope.label)** across \(grp(refunds.count)) credit\(refunds.count == 1 ? "" : "s")."
            }
            var lines = ["**\(grp(refunds.count)) \(noun)\(scope.label), totalling \(money(income)):**"]
            for r in refunds.prefix(10) { lines.append("- \(money(r.credit)) — \(r.descr) (\(prettyDate(r.txnDate)))") }
            return lines.joined(separator: "\n")
        }

        // ---- card repayment ("how much did I pay off / repay the card?") ----
        // Distinct from balance ("how much do I still OWE") — this is the repayment
        // you MADE, i.e. the card-repayment credits (category "Payments").
        if matches(low, #"\bpaid off\b|\bpay(?:ing)?\s+off\b|\brepay\w*|payments?\s+(?:made|to the card)|how much did i (?:pay|put)\s+(?:back|towards?)"#),
           !matches(low, #"\bowe\b|left to pay|still (?:owe|to pay)|how much (?:do|to) i (?:have|owe)"#) {
            if cardRepayments > 0 {
                return "**You paid off \(money(cardRepayments))\(scope.label)** in card repayments on this statement."
            }
            return "**No card repayments\(scope.label) on this statement.**"
        }

        // ---- days-with-spending count ("how many days did I spend money") ----
        if matches(low, #"how many days|on how many days"#),
           matches(low, #"spend|spent|purchase|buy|bought|money|transaction|shop"#),
           !debits.isEmpty {
            let days = Set(debits.map(\.txnDate)).count
            let span = spanDays(sr)
            // inverted: "how many days did I NOT spend anything"
            if matches(low, #"\bnot\b|\bno\b|didn'?t|did not|without"#) {
                let zero = max(0, span - days)
                return "**\(grp(zero)) no-spend day\(zero == 1 ? "" : "s")\(scope.label)** — you spent on \(grp(days)) of \(span) days."
            }
            return "**You spent money on \(grp(days)) day\(days == 1 ? "" : "s")\(scope.label)** (out of \(span) days in the period)."
        }

        // ---- distinct merchant count ("how many different shops did I use") --
        if matches(low, #"how many|number of"#),
           matches(low, #"(?:different|unique|distinct|separate)\s+(?:merchant|shop|store|place|retailer|business|compan)|(?:merchant|shop|store|retailer)s?\s+did i (?:use|visit|pay)"#),
           !debits.isEmpty {
            let n = Set(debits.map { merchantKey($0.descr) }).count
            return "**You paid \(grp(n)) different merchants\(scope.label).**"
        }

        // ---- count ---------------------------------------------------------
        // ("how many transactions on my busiest day" belongs to the busiest-day
        // handler below; "how many pounds" is a SUM, not a count)
        if matches(low, #"\bhow many\b|\bnumber of\b|\bno\.? of\b|\bcount\b|\bhow often\b"#),
           !matches(low, #"busiest day|biggest spending day|most expensive day"#),
           !matches(low, #"how many (?:pounds|quid|pence|dollars|euros|rupees)"#),
           !matches(low, #"\bversus\b|\bvs\.?\b|compared to"#),
           !matches(low, #"between\s+£?\s*\d+(?:\.\d+)?\s+and\s+£?\s*\d+"#) {
            let n = sr.count
            // per-week frequency: "how many times a week do I use X"
            if matches(low, #"times (?:a|per) week|(?:a|per) week do i"#), n > 0 {
                let weeks = max(1, Int((Double(spanDays(rows)) / 7.0).rounded(.up)))
                let freq = Double(n) / Double(weeks)
                return "**About \(String(format: "%.1f", freq)) times a week\(scope.label)** — \(grp(n)) transactions over \(weeks) week\(weeks == 1 ? "" : "s")."
            }
            let noun = n == 1 ? "transaction" : "transactions"
            return "**\(grp(n)) \(noun)\(scope.label).**"
        }

        // ---- top N expenses (plural / "top 5") -----------------------------
        if let n = topN(low), !debits.isEmpty {
            let top = debits.sorted { $0.debit > $1.debit }.prefix(n)
            var lines = ["**Your top \(top.count) \(top.count == 1 ? "expense" : "expenses")\(scope.label):**"]
            for (i, t) in top.enumerated() {
                lines.append("\(i + 1). \(money(t.debit)) — \(t.descr) (\(t.txnDate))")
            }
            return lines.joined(separator: "\n")
        }

        // ---- Nth-largest expense ("second biggest", "3rd largest") ----------
        if let n = ordinalN(low),
           matches(low, #"\b(biggest|largest|highest|most expensive|priciest)\b"#),
           matches(low, #"expen[cs]\w*|spend|spent|cost|transaction|payment|purchase|debit|buy|bought|item|thing|charge"#),
           !matches(low, #"\bday\b|\bdate\b"#),
           debits.count >= n {
            let t = debits.sorted { $0.debit > $1.debit }[n - 1]
            let word = ["", "", "second", "third", "fourth", "fifth"][n]
            return "**Your \(word)-largest expense\(scope.label) was \(money(t.debit))** — \(t.descr) on \(t.txnDate)."
        }

        // ---- single largest expense (not "biggest spending DAY" — see below) --
        // Also fires on "the most I've paid … in one go/transaction".
        if matches(low, #"\b(biggest|largest|highest|most expensive|priciest|dearest|top)\b"#)
            || matches(low, #"\bmost\b.{0,26}\bin one (?:go|transaction|purchase|payment)\b|most i'?ve? (?:paid|spent)"#),
           matches(low, #"expen[cs]\w*|spend|spent|cost|transaction|payment|purchase|debit|buy|bought|item|thing|charge|amount|paid|trip|ride|journey|meal|drink|coffee|visit"#),
           !matches(low, #"\bday\b|\bdate\b"#),
           // "biggest/highest category", "rank my categories" are breakdown
           // questions, not a single-transaction lookup — let them fall through.
           !matches(low, #"\bcategor|\brank\b"#),
           let t = debits.max(by: { $0.debit < $1.debit }) {
            return "**Your largest expense\(scope.label) was \(money(t.debit))** — \(t.descr) on \(t.txnDate)."
        }

        // ---- single smallest expense ---------------------------------------
        if matches(low, #"\b(smallest|cheapest|lowest|least expensive|tiniest)\b"#),
           matches(low, #"expen[cs]\w*|spend|spent|cost|transaction|payment|purchase|debit|buy|bought|item|thing|charge|amount|trip|ride|journey|meal|drink|coffee|visit"#),
           !matches(low, #"\bday\b|\bdate\b"#),
           !matches(low, #"\bcategor|\brank\b"#),
           let t = debits.min(by: { $0.debit < $1.debit }) {
            return "**Your smallest expense\(scope.label) was \(money(t.debit))** — \(t.descr) on \(t.txnDate)."
        }

        // ---- first / last (earliest / latest) transaction -------------------
        let firstCue = matches(low, #"\b(first|earliest|oldest)\b|start(?:ed)? spending|spending start|statement start|start.*spend"#)
        let lastCue = matches(low, #"\b(last|latest|most recent)\b|final transaction"#)
        if firstCue || lastCue,
           matches(low, #"transaction|purchase|payment|charge|\bbuy\b|bought|expense|spending|start.*spend|\btrip\b|\bride\b|journey|\bmeal\b|\bvisit\b"#),
           !matches(low, #"\d|\btop\b|biggest|largest|how many|number of|last month|last week|this month|last day|first day|final day|weekend|weekday"#),
           !sr.isEmpty {
            let ordered = sr.sorted { $0.txnDate < $1.txnDate }
            let wantLast = lastCue && !firstCue
            let t = wantLast ? ordered.last! : ordered.first!
            let ord = wantLast ? "last" : "first"
            let amt = t.debit > 0 ? t.debit : t.credit
            if matches(low, #"\bwhen\b|what date|which date|start"#) {
                return "**Your \(ord) transaction\(scope.label) was on \(prettyDate(t.txnDate))** — \(t.descr) (\(money(amt)))."
            }
            return "**Your \(ord) transaction\(scope.label) was \(money(amt))** — \(t.descr) on \(prettyDate(t.txnDate))."
        }

        // ---- percentage / share of total spend on a category or merchant ----
        if matches(low, #"percent|percentage|what\s*%|\bshare\b|proportion|portion|fraction|how much of"#),
           scope.hasCategory || scope.hasMerchant {
            let name = scope.entity ?? "That"
            // count share: "what percentage of my TRANSACTIONS were TFL?"
            if matches(low, #"of (?:my |the )?(?:transactions|purchases|payments)"#) {
                let allN = rows.filter { $0.debit > 0 }.count
                let pct = allN > 0 ? Double(debits.count) / Double(allN) * 100 : 0
                return "**\(name) was \(String(format: "%.1f", pct))% of your transactions** — \(grp(debits.count)) of \(grp(allN))."
            }
            let allSpent = rows.filter { $0.debit > 0 }.reduce(0) { $0 + $1.debit }
            let pct = allSpent > 0 ? spent / allSpent * 100 : 0
            return "**\(name) was \(String(format: "%.1f", pct))% of your total spending** — \(money(spent)) of \(money(allSpent))."
        }

        // ---- by-category breakdown -----------------------------------------
        // ("what did I spend on <a date>" is a day-total, not a breakdown — the
        // "spend on" phrasing only means categories when no day was parsed)
        if matches(low, #"by category|category breakdown|categor\w*\s*(?:report|summary)|categories|each category|split.*categor|breakdown of|where.*money go|(?:which|what|top|biggest) category"#)
            || (scope.dayISO == nil && matches(low, #"what.*spend.*on\b"#)
                && !matches(low, #"\baverage\b|\bavg\b|on average|per month|per day|monthly"#)
                && scope.unmatchedTarget == nil && !scope.hasCategory && !scope.hasMerchant),
           !debits.isEmpty {
            return categoryBreakdown(debits, total: spent, scopeLabel: scope.label, money: money)
        }

        // ---- income / credits ----------------------------------------------
        // `\bcredits?\b` deliberately excludes the compound-noun senses of "credit"
        // that aren't money-in: "credit card" (the physical card), "credit
        // limit/line/score/rating", and "available credit" (a card's headroom).
        if matches(low, #"\bincome\b|earn|receiv(?:e|ed|ing)|credited|\bsalary\b|deposits?\b|money (?:in|received)|came in|come in|coming in|money came|(?<!available\s)\bcredits?\b(?!\s+(?:cards?|limits?|lines?|scores?|ratings?)\b)|paid in"#) {
            let noun = credits.count == 1 ? "credit" : "credits"
            var out = "**You received \(money(income))\(scope.label)** across \(grp(credits.count)) \(noun)."
            if cardRepayments > 0 {
                out += " (Card repayments of \(money(cardRepayments)) aren't counted — that's your own money.)"
            }
            return out
        }

        // ---- net / profit / loss / savings ----------------------------------
        if matches(low, #"\bnet\b|how much did i save|left over|left-over|surplus|net income|\bprofit\b|\bloss\b|\bp\s*&\s*l\b|profit and loss|made or lost|up or down|ahead or behind|in the black"#)
            || (matches(low, #"\bsav(?:e|ed|ings?)\b"#) && !matches(low, #"rate|target|goal|should|advice|advise|\bhelp\b|recommend|how (?:can|do)"#)) {
            let net = income - spent
            let verb = net >= 0 ? "kept" : "overspent by"
            return "**Net\(scope.label): \(money(net))** — \(money(income)) in minus \(money(spent)) out. You \(verb) \(money(abs(net)))."
        }

        // ---- median ---------------------------------------------------------
        if matches(low, #"\bmedian\b"#), !debits.isEmpty {
            let s = debits.map(\.debit).sorted()
            let mid = s.count / 2
            let med = s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
            return "**Your median transaction\(scope.label) is \(money(med))** across \(grp(debits.count)) debits."
        }

        // ---- average --------------------------------------------------------
        if matches(low, #"\baverage\b|\bavg\b|\bmean\b|\btypical\b|on average"#), !debits.isEmpty {
            if matches(low, #"per month|monthly|a month|each month"#) {
                let months = max(1, Set(sr.map(\.month)).count)
                return "**You spend about \(money(spent / Double(months)))/month\(scope.label)** on average (over \(months) month\(months == 1 ? "" : "s"))."
            }
            if matches(low, #"per day|\bdaily\b|a day|each day"#) {
                let days = spanDays(sr)
                return "**You spend about \(money(spent / Double(days)))/day\(scope.label)** on average (over \(days) days)."
            }
            if matches(low, #"per week|\bweekly\b|a week|each week"#) {
                let weeks = max(1, Int((Double(spanDays(sr)) / 7.0).rounded(.up)))
                return "**You spend about \(money(spent / Double(weeks)))/week\(scope.label)** on average (over \(weeks) week\(weeks == 1 ? "" : "s"))."
            }
            let avg = spent / Double(debits.count)
            return "**Your average transaction\(scope.label) is \(money(avg))** across \(grp(debits.count)) debits."
        }

        // ---- biggest / busiest day ------------------------------------------
        // "biggest spending day" ranks by £; "busiest day" / "most transactions"
        // ranks by transaction COUNT.
        if matches(low, #"(?:which|what)\s+day\b|most expensive day|biggest spending day|busiest day|day did i spend|highest daily|biggest daily|(?:quietest|lightest|cheapest|slowest)\s+(?:spending\s+)?day"#),
           matches(low, #"\bmost\b|biggest|highest|busiest|expensive|spend|\bleast\b|lowest|smallest|cheapest|quietest"#),
           !debits.isEmpty {
            var byDay: [String: (amt: Double, n: Int)] = [:]
            for r in debits { var e = byDay[r.txnDate] ?? (0, 0); e.amt += r.debit; e.n += 1; byDay[r.txnDate] = e }
            let byCount = matches(low, #"most transactions|most purchases|busiest|most visits|how many"#)
            let byLeast = matches(low, #"\bleast\b|lowest|smallest|cheapest|quietest"#)
            if byCount, let top = byDay.max(by: { $0.value.n < $1.value.n }) {
                return "**Your busiest day\(scope.label) was \(prettyDate(top.key)): \(grp(top.value.n)) transactions** totalling \(money(top.value.amt))."
            }
            if byLeast, let low_ = byDay.min(by: { $0.value.amt < $1.value.amt }) {
                return "**Your lightest spending day\(scope.label) was \(prettyDate(low_.key)): \(money(low_.value.amt))** across \(low_.value.n) transaction\(low_.value.n == 1 ? "" : "s") (days with no spending excluded)."
            }
            if let top = byDay.max(by: { $0.value.amt < $1.value.amt }) {
                return "**Your biggest spending day\(scope.label) was \(prettyDate(top.key)): \(money(top.value.amt))** across \(top.value.n) transaction\(top.value.n == 1 ? "" : "s")."
            }
        }

        // ---- weekend vs weekday comparison ----------------------------------
        if matches(low, #"weekend"#), matches(low, #"weekday|week day"#), !debits.isEmpty {
            let wk = debits.filter { isWeekend($0.txnDate) }
            let wd = debits.filter { !isWeekend($0.txnDate) }
            let ws = wk.reduce(0) { $0 + $1.debit }
            let ds = wd.reduce(0) { $0 + $1.debit }
            let winner = ws >= ds ? "weekends" : "weekdays"
            return "**You spend more on \(winner)\(scope.label)** — weekends \(money(ws)) (\(wk.count) txns) vs weekdays \(money(ds)) (\(wd.count) txns)."
        }

        // ---- weekend / weekday spend ----------------------------------------
        if matches(low, #"weekend"#), !debits.isEmpty {
            let wk = debits.filter { isWeekend($0.txnDate) }
            let total = wk.reduce(0) { $0 + $1.debit }
            return "**You spent \(money(total)) at weekends\(scope.label)** across \(grp(wk.count)) transaction\(wk.count == 1 ? "" : "s")."
        }
        if matches(low, #"weekday|week day|during the week|on weekdays"#), !debits.isEmpty {
            let wd = debits.filter { !isWeekend($0.txnDate) }
            let total = wd.reduce(0) { $0 + $1.debit }
            return "**You spent \(money(total)) on weekdays\(scope.label)** across \(grp(wd.count)) transaction\(wd.count == 1 ? "" : "s")."
        }

        // ---- amount range ("transactions between £10 and £20") --------------
        if matches(low, #"between\s+£?\s*\d+(?:\.\d+)?\s+and\s+£?\s*\d+(?:\.\d+)?"#),
           matches(low, #"pounds?|quid|pence|dollars?|euros?|rupees?|£"#),
           let g = firstTwoGroups(low, #"between\s+£?\s*(\d+(?:\.\d+)?)\s+and\s+£?\s*(\d+(?:\.\d+)?)"#),
           let a = Double(g.0), let bStr = g.1, let b = Double(bStr), !debits.isEmpty {
            let lo = Swift.min(a, b), hi = Swift.max(a, b)
            let hits = debits.filter { $0.debit >= lo && $0.debit <= hi }.sorted { $0.debit < $1.debit }
            if matches(low, #"how many|number of|count"#) {
                return "**\(grp(hits.count)) transaction\(hits.count == 1 ? "" : "s") between \(money(lo)) and \(money(hi))\(scope.label).**"
            }
            if hits.isEmpty { return "**No transactions between \(money(lo)) and \(money(hi))\(scope.label).**" }
            var lines = ["**\(grp(hits.count)) transaction\(hits.count == 1 ? "" : "s") between \(money(lo)) and \(money(hi))\(scope.label):**"]
            for h in hits.prefix(10) { lines.append("- \(money(h.debit)) — \(h.descr) (\(h.txnDate))") }
            return lines.joined(separator: "\n")
        }

        // ---- "how many pounds (did I spend) on X" is a SUM, not a count ------
        if matches(low, #"how many (?:pounds|quid|pence|dollars|euros|rupees)"#), !debits.isEmpty {
            let noun = debits.count == 1 ? "transaction" : "transactions"
            return "**You spent \(money(spent))\(scope.label)** across \(grp(debits.count)) \(noun)."
        }

        // A "how much / total" phrasing on a threshold wants the SUM of the
        // matching charges, not an itemised list.
        let thresholdWantsSum = matches(low, #"how much|\btotal\b|\bsum\b|added up|all together|altogether|combined|in total"#)
            && !matches(low, #"how many|number of"#)

        // ---- threshold ("transactions over £50", "did I spend above 100") ----
        if let g = firstGroup(low, #"(?:over|above|more than|greater than|bigger than|exceed\w*|at least)\s*£?\s*(\d+(?:\.\d+)?)"#),
           let thr = Double(g), !debits.isEmpty {
            let hits = debits.filter { $0.debit > thr }.sorted { $0.debit > $1.debit }
            if hits.isEmpty {
                return "**No transactions over \(money(thr))\(scope.label).** Your largest was \(money(debits.map(\.debit).max() ?? 0))."
            }
            if thresholdWantsSum {
                let sum = hits.reduce(0) { $0 + $1.debit }
                return "**You spent \(money(sum)) across \(grp(hits.count)) transaction\(hits.count == 1 ? "" : "s") over \(money(thr))\(scope.label).**"
            }
            var lines = ["**\(grp(hits.count)) transaction\(hits.count == 1 ? "" : "s") over \(money(thr))\(scope.label):**"]
            for h in hits.prefix(10) { lines.append("- \(money(h.debit)) — \(h.descr) (\(h.txnDate))") }
            return lines.joined(separator: "\n")
        }

        // ---- threshold BELOW ("transactions under £5", "less than a tenner") ----
        if let g = firstGroup(low, #"(?:under|below|less than|cheaper than|no more than|at most|beneath)\s*£?\s*(\d+(?:\.\d+)?)"#)
                ?? (matches(low, #"\ba fiver\b"#) ? "5" : nil)
                ?? (matches(low, #"\ba tenner\b"#) ? "10" : nil),
           let thr = Double(g), !debits.isEmpty {
            let hits = debits.filter { $0.debit < thr }.sorted { $0.debit < $1.debit }
            if hits.isEmpty {
                return "**No transactions under \(money(thr))\(scope.label).** Your smallest was \(money(debits.map(\.debit).min() ?? 0))."
            }
            if thresholdWantsSum {
                let sum = hits.reduce(0) { $0 + $1.debit }
                return "**You spent \(money(sum)) across \(grp(hits.count)) transaction\(hits.count == 1 ? "" : "s") under \(money(thr))\(scope.label).**"
            }
            var lines = ["**\(grp(hits.count)) transaction\(hits.count == 1 ? "" : "s") under \(money(thr))\(scope.label):**"]
            for h in hits.prefix(10) { lines.append("- \(money(h.debit)) — \(h.descr) (\(h.txnDate))") }
            return lines.joined(separator: "\n")
        }

        // ---- amount reverse-lookup ("what was the £34.99 charge?", "which
        // transaction was 40.70?", "what did I spend 100 pounds on?") ---------
        // The amount is recognised from a currency SYMBOL (£100), an explicit
        // two-decimal figure (40.70 — clearly money, not a count), a currency WORD
        // (100 pounds), or a "for £X" phrasing — so bare small integers like "top 5"
        // never register as an amount.
        if matches(low, #"(?:what|which|who).*(?:charge|transaction|payment|purchase|debit|cost|was|spend|buy|bought|pay|paid)|what did i (?:buy|pay|get|purchase|spend) (?:for|on)|the £?\s?\d+(?:\.\d{1,2})? (?:charge|transaction|payment|purchase)"#),
           !matches(low, #"\bover\b|\babove\b|\bunder\b|\bbelow\b|more than|less than|biggest|largest|smallest|highest|lowest|\bfirst\b|\blast\b|latest|earliest|how many|how much did i spend\b(?!\s+£?\s?\d)"#),
           let g = firstGroup(low, #"£\s*(\d+(?:\.\d{1,2})?)"#)
                ?? firstGroup(low, #"\b(\d+\.\d{2})\b"#)
                ?? firstGroup(low, #"\b(\d+(?:\.\d{1,2})?)\s*(?:pounds?|quid|pence|dollars?|euros?|rupees?)\b"#)
                ?? firstGroup(low, #"\bfor\s+£?\s*(\d+(?:\.\d{1,2})?)\b"#),
           let amt = Double(g) {
            let hits = sr.filter { abs($0.debit - amt) < 0.005 || abs($0.credit - amt) < 0.005 }
            if hits.isEmpty {
                return "**No transaction for \(money(amt))\(scope.label).** Nothing on this statement matches that amount."
            }
            if hits.count == 1, let t = hits.first {
                let kind = t.credit > 0 ? "credit" : "charge"
                return "**The \(money(amt)) \(kind) was \(t.descr)** on \(prettyDate(t.txnDate))."
            }
            var lines = ["**\(grp(hits.count)) transactions for \(money(amt))\(scope.label):**"]
            for t in hits.prefix(10) { lines.append("- \(t.descr) (\(prettyDate(t.txnDate)))") }
            return lines.joined(separator: "\n")
        }

        // ---- month-vs-month comparison ("did I spend more in Feb or March",
        // "how much more in Feb than March") ----------------------------------
        if matches(low, #"\bcompare\b|\bvs\.?\b|versus|more in|less in|higher in|which month|\bthan\b|difference between"#) {
            let ms = monthNames.filter { matches(low, #"\b"# + $0.0 + #"\b"#) }.map(\.1)
            let uniq = Array(Set(ms)).sorted()
            if uniq.count >= 2 {
                var parts: [String] = []
                var totals: [(Int, Double)] = []
                for mo in uniq {
                    let t = rows.filter { $0.monthNo == mo && $0.debit > 0 }.reduce(0) { $0 + $1.debit }
                    totals.append((mo, t))
                    parts.append("\(monthAbbr(mo)) \(money(t))")
                }
                let hi = totals.max(by: { $0.1 < $1.1 })!
                var out = "**You spent more in \(monthAbbr(hi.0)) (\(money(hi.1))).** " + parts.joined(separator: " vs ") + "."
                if totals.count == 2 {
                    out += " Difference: \(money(abs(totals[0].1 - totals[1].1)))."
                }
                return out
            }
        }

        // ---- merchant / category compare, combined-sum, or count-compare ----
        // "Did I spend more at TFL or Deliveroo?" (compare by £); "TFL and Lime
        // combined" / "how much on X and Y" (sum); "how many food vs transport"
        // or "did I use Lime or Forest more" (compare by count). Every content
        // token that names ≥1 row becomes a side; identical row-signatures merge
        // so two tokens for one merchant ("craft" + "beer") don't fake a side.
        if matches(low, #"\bor\b|\bvs\.?\b|versus|\bcompare\b|\band\b|which (?:cost|was|is)|cost me more|\bthan\b|\bdifference\b|combined|together|altogether"#),
           !rows.isEmpty {
            // Search ALL debit rows — parseScope may have narrowed to one contender.
            let allDebits = rows.filter { $0.debit > 0 }
            let monthWords = Set(monthNames.map(\.0))
            let toks = low.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 3 && !merchantStopwords.contains($0) && !monthWords.contains($0) }
            let compareWord = matches(low, #"\bmore\b|\bor\b|\bvs\.?\b|versus|\bcompare\b|\bthan\b|which (?:cost|was|is)|cost me more|\bless\b|higher|lower|bigger|smaller|greater|\bdifference\b|\bgap\b"#)
            let wantsDiff = matches(low, #"\bdifference\b|how much (?:more|less)|\bgap\b"#)
            let wantsCount = matches(low, #"how many|number of|how often|more often|\buse[ds]?\b|\bvisit\w*"#)
            let wantsCombined = matches(low, #"combined|together|altogether|\bplus\b|sum of"#)
                || (matches(low, #"\band\b"#) && !compareWord)

            func render(_ gs: [(name: String, amt: Double, n: Int)], at: Bool) -> String {
                if wantsCombined {
                    let tot = gs.reduce(0) { $0 + $1.amt }, cnt = gs.reduce(0) { $0 + $1.n }
                    return "**You spent \(money(tot)) on \(gs.map(\.name).joined(separator: " + ")) combined** "
                        + "across \(grp(cnt)) transaction\(cnt == 1 ? "" : "s")."
                }
                if wantsCount {
                    let ranked = gs.sorted { $0.n > $1.n }
                    let parts = ranked.map { "\($0.name) \(grp($0.n)) (\(money($0.amt)))" }.joined(separator: " vs ")
                    return "**You had more transactions \(at ? "at" : "in") \(ranked[0].name)** — \(parts)."
                }
                let ranked = gs.sorted { $0.amt > $1.amt }
                let parts = ranked.map { "\($0.name) \(money($0.amt)) (\($0.n) txn\($0.n == 1 ? "" : "s"))" }
                    .joined(separator: " vs ")
                var out = "**You spent more \(at ? "at" : "on") \(ranked[0].name)** — \(parts)."
                if wantsDiff, ranked.count == 2 {
                    out += " Difference: \(money(ranked[0].amt - ranked[1].amt))."
                }
                return out
            }

            var groups: [(name: String, amt: Double, n: Int)] = []
            var sigs = Set<String>()
            for t in Array(Set(toks)) {
                let pat = #"\b"# + t + (t.count >= 5 ? "" : #"\b"#)
                let rs = allDebits.filter { $0.descr.lowercased().range(of: pat, options: .regularExpression) != nil }
                guard !rs.isEmpty else { continue }
                let amt = rs.reduce(0) { $0 + $1.debit }
                if sigs.insert("\(rs.count)|\(amt)").inserted {
                    groups.append((merchantDisplay(t), amt, rs.count))
                }
            }
            if groups.count >= 2 { return render(groups, at: true) }
            // Category fallback: scan the FULL question for category names /
            // synonyms — independent of the merchant-stopword-filtered `toks`, so
            // category words that are also merchant-stopwords ("subscriptions",
            // "income") are still detected as a combine side. Ordered by first
            // appearance for a natural "A vs B" / "A + B" rendering.
            let present = Set(allDebits.map(\.category))
            var catHits: [(cat: String, pos: Int)] = []
            var seenCats = Set<String>()
            for cat in present {
                if let rng = low.range(of: cat.lowercased()), seenCats.insert(cat).inserted {
                    catHits.append((cat, low.distance(from: low.startIndex, to: rng.lowerBound)))
                }
            }
            for (word, canonical) in categorySynonyms
            where present.contains(canonical) && !seenCats.contains(canonical) {
                if let rng = low.range(of: word.trimmingCharacters(in: .whitespaces)), seenCats.insert(canonical).inserted {
                    catHits.append((canonical, low.distance(from: low.startIndex, to: rng.lowerBound)))
                }
            }
            let catGroups = catHits.sorted { $0.pos < $1.pos }.map { h -> (name: String, amt: Double, n: Int) in
                let rs = allDebits.filter { $0.category == h.cat }
                return (h.cat, rs.reduce(0) { $0 + $1.debit }, rs.count)
            }
            if catGroups.count >= 2 { return render(catGroups, at: false) }
        }

        // ---- most-spent / most-used merchant --------------------------------
        // "which merchant did I spend the most at?", "who did I pay most often?" —
        // ranks debits by a description-derived merchant key. Placed before the
        // catch-all so it isn't swallowed as a plain total.
        if !debits.isEmpty {
            let wantsFreq = matches(low, #"most (?:frequent|used|common|visited|regular)|(?:merchant|shop|store|place) .*most often|paid most often|most often"#)
            let wantsMost = matches(low, #"which (?:merchant|shop|store|place|retailer|company|business)|who did i (?:spend|pay)|where did i spend the most|most (?:spent|expensive) (?:merchant|shop|store)|biggest merchant|top merchant"#)
            let wantsLeast = matches(low, #"which (?:merchant|shop|store|place|retailer|company|business)|where did i spend the least|least (?:spent|expensive) (?:merchant|shop|store)|smallest merchant|bottom merchant"#)
                && matches(low, #"\bleast\b|\blowest\b|\bfewest\b|\bsmallest\b"#)
            if wantsFreq || wantsMost || wantsLeast {
                return merchantRanking(debits, byCount: wantsFreq, least: wantsLeast && !wantsFreq,
                                       scopeLabel: scope.label, money: money)
            }
        }

        // ---- existence yes/no ("did I use TFL in March?", "any Amazon in Feb?")
        // Only for merchant/category-scoped questions ("did I…" alone stays a
        // day-total), and never for compare/threshold phrasings.
        if matches(low, #"^\s*(?:did|have|has|do)\s+i\b|^\s*any\b"#),
           matches(low, #"\buse\b|\border\b|\bgo\b|\bvisit\b|\bbuy\b|\bshop\b|\bspend\b|\bpay\b|\bpaid\b|charges?\b|purchases?\b|\beat\b|transactions?\b"#),
           !matches(low, #"\bor\b|\bvs\.?\b|versus|\bover\b|\babove\b|more than"#),
           scope.hasMerchant || scope.hasCategory || scope.unmatchedTarget != nil {
            if let target = scope.unmatchedTarget {
                return "**No — \(money(0)).** I couldn't find any transactions matching “\(target)” in this statement."
            }
            // A month was named but matchPeriod couldn't apply it (it only scopes
            // to non-empty months) → the merchant/category has NO rows there.
            if !scope.hasPeriod,
               let m = monthNames.first(where: { matches(low, #"\b"# + $0.0 + #"\b"#) }) {
                let name = m.0.prefix(1).uppercased() + m.0.dropFirst()
                return "**No\(scope.label) in \(name) — \(money(0)).**"
            }
            if sr.isEmpty {
                return "**No\(scope.label) — nothing found.** (\(money(0)))"
            }
            let noun = sr.count == 1 ? "transaction" : "transactions"
            return "**Yes — \(grp(sr.count)) \(noun)\(scope.label)**, totalling \(money(spent))."
        }

        // ---- date lookup ("when did I go to the dentist?") -------------------
        // Merchant/category-scoped only; a few rows are listed, many are
        // summarised as first–last. ("which day did I spend the most" was already
        // taken by the biggest-day handler above.)
        if matches(low, #"\bwhen did i\b|(?:what|which) (?:dates?|days?) did i|on what dates?"#),
           scope.hasMerchant || scope.hasCategory, !sr.isEmpty {
            let ordered = sr.sorted { $0.txnDate < $1.txnDate }
            let name = scope.entity ?? "that"
            if ordered.count <= 6 {
                let items = ordered.map { "\(prettyDate($0.txnDate)) (\(money($0.debit > 0 ? $0.debit : $0.credit)))" }
                return "**\(name): \(grp(ordered.count)) transaction\(ordered.count == 1 ? "" : "s")** — \(items.joined(separator: ", "))."
            }
            return "**\(name): \(grp(ordered.count)) times between \(prettyDate(ordered.first!.txnDate)) and \(prettyDate(ordered.last!.txnDate))**, totalling \(money(spent))."
        }

        // ---- itemised list of a category / merchant's transactions ----------
        // "list my Food & Dining transactions", "show me all my transport
        // transactions", "what did I buy on Amazon" — enumerate the scoped rows
        // (capped) rather than only summing them. Scoped-only, and never for the
        // aggregate phrasings (how much / how many / biggest …) handled above.
        if (scope.hasCategory || scope.hasMerchant), !sr.isEmpty,
           matches(low, #"\blist\b|show me|show all|show my|let me see|itemi[sz]e|what (?:did|have) i (?:buy|bought|purchase|get)\b|all (?:my|the) .{0,20}(?:transactions|purchases|payments|charges)|(?:transactions?|purchases?|charges?|payments?)\s+(?:in|on|for|at|from)\b"#),
           !matches(low, #"how much|how many|\btotal\b|average|\bavg\b|biggest|largest|smallest|percent|\bover\b|\babove\b|\bunder\b|more than"#) {
            let ordered = sr.sorted { $0.txnDate < $1.txnDate }
            let creditOnly = ordered.allSatisfy { $0.debit == 0 }
            let tot = creditOnly ? income : spent
            var lines = ["**\(grp(ordered.count)) transaction\(ordered.count == 1 ? "" : "s")\(scope.label), totalling \(money(tot)):**"]
            for r in ordered.prefix(15) {
                let amt = r.debit > 0 ? r.debit : r.credit
                lines.append("- \(prettyDate(r.txnDate)) — \(r.descr) (\(money(amt)))")
            }
            if ordered.count > 15 { lines.append("_…and \(grp(ordered.count - 15)) more._") }
            return lines.joined(separator: "\n")
        }

        // Advisory / opinion / open-ended that no deterministic handler caught →
        // let the LLM handle it (before the broad total-spent catch-all below).
        if isAdvisory(low) { return nil }

        // ---- named-but-absent target → honest zero --------------------------
        // "how much on rent?" / "how much at Netflix?" when neither exists here:
        // answer £0 with the reason, rather than the misleading full total.
        if let target = scope.unmatchedTarget {
            if matches(low, #"how many|how often|number of|\bcount\b"#) {
                return "**No transactions for \(target) in this statement.**"
            }
            return "**You spent \(money(0)) on \(target).** I couldn't find any transactions matching “\(target)” in this statement."
        }

        // ---- total spent (catch-all numeric) -------------------------------
        if matches(low, #"\bhow much\b|\btotal\b|\baltogether\b|\bin all\b|spent|spend|spending|expenditure|outgoing|costs?\b|paid|\bpay\b|\bsum of\b|\bsum\b.*\b(?:purchases|spend|charges|transactions)|charged to|burn(?:ed|t)?\s+through"#) {
            let noun = debits.count == 1 ? "transaction" : "transactions"
            var out = "**You spent \(money(spent))\(scope.label)** across \(grp(debits.count)) \(noun)."
            if scope.hasMerchant || scope.hasCategory, income > 0 {
                out += " (You also received \(money(income)) here.)"
            }
            return out
        }

        return nil
    }

    // MARK: - Scope (category / merchant / period)

    private struct Scope {
        var rows: [TxnRow]
        var label: String        // e.g. " on Groceries in March" (leading space) or ""
        var entity: String?      // the matched category or merchant name (for what-if labels)
        var hasCategory = false
        var hasMerchant = false
        var hasPeriod = false
        var dayISO: String?      // exact-day scope, "YYYY-MM-DD" (for balance-as-of)
        var dayLabel: String?    // "4 Jun 2026"
        var unmatchedTarget: String?   // a named category/merchant absent from the data
    }

    private static func parseScope(_ low: String, rows: [TxnRow]) -> Scope {
        var s = Scope(rows: rows, label: "")
        var labelParts: [String] = []

        // category: match a category actually present in the data (+ synonyms)
        if let cat = matchCategory(low, rows: rows) {
            s.rows = s.rows.filter { $0.category.caseInsensitiveCompare(cat) == .orderedSame }
            s.hasCategory = true
            s.entity = cat
            labelParts.append("on \(cat)")
        }

        // merchant: longest distinct merchant name mentioned in the question.
        // Description matching is only allowed when no category already scoped the
        // rows, so a category question ("food") never gets narrowed to a merchant.
        if let merch = matchMerchant(low, rows: s.rows, allowDescription: !s.hasCategory) {
            s.rows = s.rows.filter {
                $0.merchant.lowercased() == merch.lowercased()
                    || $0.descr.lowercased().contains(merch.lowercased())
            }
            s.hasMerchant = true
            if s.entity == nil { s.entity = merch }
            labelParts.append("at \(merch)")
        }

        // period: a date RANGE first ("between 16 and 28 Feb", "first/last week"),
        // then an exact day ("on 4 June"), then month name / this-last month.
        if let range = matchDateRange(low, rows: s.rows) {
            s.rows = range.rows
            s.hasPeriod = true
            // range labels carry a leading space for direct use; strip it here
            // because labelParts joining adds its own.
            labelParts.append(range.label.trimmingCharacters(in: .whitespaces))
        } else if let day = matchDay(low, rows: s.rows) {
            s.rows = day.rows
            s.hasPeriod = true
            s.dayISO = day.iso
            s.dayLabel = day.dayLabel
            labelParts.append("on \(day.dayLabel)")
        } else if let (rowsInPeriod, plabel) = matchPeriod(low, rows: s.rows) {
            s.rows = rowsInPeriod
            s.hasPeriod = true
            labelParts.append(plabel)
        }

        // Named-but-absent target: the user clearly scoped to something ("on rent",
        // "at Netflix") that isn't in this statement. Remember it so a spend/count
        // question answers an honest zero instead of the whole-account total.
        if !s.hasCategory, !s.hasMerchant, !s.hasPeriod {
            s.unmatchedTarget = unmatchedTarget(low, rows: rows)
        }

        s.label = labelParts.isEmpty ? "" : " " + labelParts.joined(separator: " ")
        return s
    }

    /// A category / merchant the question named but that no row matches — used to
    /// answer "£0, none found" instead of silently returning the full total.
    private static func unmatchedTarget(_ low: String, rows: [TxnRow]) -> String? {
        // (a) a known category word whose canonical category isn't in the data.
        let present = Set(rows.map(\.category))
        for (word, canonical) in categorySynonyms where low.contains(word) {
            if !present.contains(canonical) { return canonical }
        }
        // (b) a content noun (after stripping intent words) that names no row — only
        // when the question is actually asking about spending on / visiting something.
        guard matches(low, #"spen[dt]|how much|paid|\bpay\b|\bcost\b|\bat\b|\bon\b|\buse[ds]?\b|\bvisit\w*|\bgo\b|\bwent\b|\beat\b|\border\w*|\bshop\w*|\bbuy\b|\bbought\b"#) else { return nil }
        let months = Set(monthNames.map(\.0))
        let toks = low.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !merchantStopwords.contains($0) && !months.contains($0) }
        // A genuine "spend at <X>" names a merchant/category in 1–2 tokens. Three or
        // more leftover content words means the question wasn't a clean spend lookup
        // (e.g. "how much were the new debits this period", "verify the ISK
        // conversion") — defer to the model rather than inventing a £0 "merchant".
        guard !toks.isEmpty, toks.count <= 2 else { return nil }
        return merchantDisplay(toks.joined(separator: " "))
    }

    /// Exact-day scope: "on 4 June", "June 4th 2026", "the 4th of June", "4/6".
    /// Returns the matching rows (possibly empty — "nothing on that date" is a
    /// valid, exact answer), a display label, and the resolved ISO date.
    private static func matchDay(_ low: String,
                                 rows: [TxnRow]) -> (rows: [TxnRow], dayLabel: String, iso: String)? {
        var d = 0, m = 0, y = 0
        var found = false
        for (name, no) in monthNames {
            // "4 June [2026]" / "4th of June"
            if let g = firstTwoGroups(low, #"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?"# + name + #"[a-z]*\b(?:\s+(\d{4}))?"#) {
                d = Int(g.0) ?? 0; m = no; y = g.1.flatMap(Int.init) ?? 0
                found = true; break
            }
            // "June 4[th][, 2026]"
            if let g = firstTwoGroups(low, #"\b"# + name + #"[a-z]*\s+(\d{1,2})(?:st|nd|rd|th)?\b(?:,?\s+(\d{4}))?"#) {
                d = Int(g.0) ?? 0; m = no; y = g.1.flatMap(Int.init) ?? 0
                found = true; break
            }
        }
        // numeric "4/6[/2026]" (day/month, UK order)
        if !found, let g = firstTwoGroups(low, #"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b"#) {
            d = Int(g.0) ?? 0
            m = g.1.flatMap(Int.init) ?? 0
            if let ym = firstGroup(low, #"\b\d{1,2}/\d{1,2}/(\d{2,4})\b"#), let yv = Int(ym) {
                y = yv < 100 ? 2000 + yv : yv
            }
            found = true
        }
        guard found, (1...31).contains(d), (1...12).contains(m) else { return nil }

        // resolve the year from the data when the question doesn't give one
        if y == 0 {
            y = rows.filter { $0.monthNo == m && $0.day == d }.map(\.year).max()
                ?? rows.filter { $0.monthNo == m }.map(\.year).max()
                ?? rows.map(\.year).max() ?? 0
        }
        guard y > 0 else { return nil }

        let iso = String(format: "%04d-%02d-%02d", y, m, d)
        let abbr = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][m]
        let scoped = rows.filter { $0.year == y && $0.monthNo == m && $0.day == d }
        return (scoped, "\(d) \(abbr) \(y)", iso)
    }

    /// Common category words → the canonical category, but only if that category
    /// is actually present in the parsed rows (so we never invent a scope).
    private static let categorySynonyms: [(String, String)] = [
        ("grocer", "Groceries"), ("food", "Food & Dining"), ("dining", "Food & Dining"),
        ("restaurant", "Food & Dining"), ("eating out", "Food & Dining"), ("eating", "Food & Dining"),
        ("eat out", "Food & Dining"), ("takeaway", "Food & Dining"), ("take away", "Food & Dining"),
        ("coffee", "Food & Dining"), ("drink", "Food & Dining"), ("pub", "Food & Dining"),
        ("transport", "Transport"), ("travel", "Transport"), ("tube", "Transport"),
        ("scooter", "Transport"), ("commut", "Transport"),
        ("fuel", "Transport"), ("shopping", "Shopping"), ("shop", "Shopping"),
        ("bill", "Bills & Utilities"), ("utilit", "Bills & Utilities"),
        ("cash", "Cash & ATM"), ("atm", "Cash & ATM"), ("transfer", "Transfers"),
        ("entertain", "Entertainment"), ("health", "Health"), ("rent", "Rent"),
        ("dentist", "Healthcare"), ("dental", "Healthcare"), ("doctor", "Healthcare"),
        ("medical", "Healthcare"), ("pharmacy", "Healthcare"), ("healthcare", "Healthcare"),
        ("streaming", "Subscriptions"), ("gym", "Subscriptions"),
        // "fees"/" fee" (leading space so "coffee" can't match) / "charges"
        ("fees", "Fees & Charges"), (" fee", "Fees & Charges"), ("charges", "Fees & Charges"),
        ("education", "Education"), ("school", "Education"), ("tuition", "Education"),
        // "subs " (trailing space so "subsequent"/"subsidy" can't match)
        ("subscription", "Subscriptions"), ("subs ", "Subscriptions"), ("recurring", "Subscriptions"),
    ]

    private static func matchCategory(_ low: String, rows: [TxnRow]) -> String? {
        // "Payments" is the internal card-repayment bucket, never a user-facing
        // spend category — excluding it stops "two largest payments" / "Dojo
        // payments" from wrongly scoping to the single repayment row.
        let present = Set(rows.map(\.category).filter { !$0.isEmpty && $0 != "Payments" })
        // direct: the question names a category exactly as it appears in the data
        if let direct = present.first(where: { low.contains($0.lowercased()) }) { return direct }
        // synonym → canonical, if that canonical is present
        for (word, canonical) in categorySynonyms where low.contains(word) {
            // "shop / shopping AT <merchant>" is a verb + object ("did I shop at
            // Netflix?"), NOT a request for the Shopping category — let it fall
            // through to merchant / absent-target handling.
            if (word == "shop" || word == "shopping"),
               matches(low, #"shop(?:ping)?\s+(?:at|from|in)\b|(?:how many|number of|different|distinct|separate|several|unique)\s+shops?\b"#) { continue }
            if let hit = present.first(where: { $0.caseInsensitiveCompare(canonical) == .orderedSame }) {
                return hit
            }
        }
        return nil
    }

    private static func matchMerchant(_ low: String, rows: [TxnRow],
                                      allowDescription: Bool) -> String? {
        // 1) merchant-field candidates (populated by most parsers) — longest wins.
        let merchants = Set(rows.map(\.merchant).filter { $0.count >= 4 })
        if let hit = merchants.filter({ low.contains($0.lowercased()) })
            .max(by: { $0.count < $1.count }) {
            return hit
        }
        guard allowDescription else { return nil }

        // 2) description-derived: card statements often carry NO merchant field
        // (Amex/Revolut layouts), so match the question's content words against the
        // raw descriptions. Strip intent/filler words, then take the most specific
        // token (or contiguous phrase) that actually names ≥1 row.
        let months = Set(monthNames.map(\.0))
        let tokens = low.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !merchantStopwords.contains($0) && !months.contains($0) }
        guard !tokens.isEmpty else { return nil }

        // Whole-WORD match against descriptions (not substring): "net" must not
        // match "NETFLIX", "receive" must not match "PAYMENT RECEIVED". A token is
        // only a merchant if it names a row as its own word.
        let descs = rows.map { $0.descr.lowercased() }
        func namesRow(_ needle: String) -> Bool {
            let pat = #"\b"# + needle.replacingOccurrences(of: " ", with: #"\s+"#) + #"\b"#
            return descs.contains { $0.range(of: pat, options: .regularExpression) != nil }
        }
        let phrase = tokens.joined(separator: " ")
        if tokens.count > 1, namesRow(phrase) { return merchantDisplay(phrase) }
        // Longer tokens (≥5) may also match as a word PREFIX, so "Nayax" finds the
        // card descriptor "NAYAXAU*…"; short tokens stay whole-word only so "net"
        // never matches "Netflix".
        func namesRowLoose(_ t: String) -> Bool {
            if namesRow(t) { return true }
            guard t.count >= 5 else { return false }
            let pat = #"\b"# + t
            return descs.contains { $0.range(of: pat, options: .regularExpression) != nil }
        }
        if let tok = tokens.sorted(by: { $0.count > $1.count }).first(where: namesRowLoose) {
            return merchantDisplay(tok)
        }
        return nil
    }

    /// Words that are intent/filler, not a merchant name — dropped before matching
    /// the question against transaction descriptions.
    private static let merchantStopwords: Set<String> = [
        "how", "much", "many", "did", "does", "the", "and", "for", "from", "with",
        "spend", "spent", "spending", "pay", "paid", "total", "all", "was", "are",
        "have", "has", "get", "got", "this", "that", "last", "per", "average", "avg",
        "cost", "costs", "transaction", "transactions", "purchase", "purchases",
        "payment", "payments", "expense", "expenses", "charge", "charges", "charged", "money",
        "account", "balance", "statement", "card", "credit", "debit", "what", "whats",
        "times", "time", "use", "used", "using", "order", "ordered", "buy", "bought", "most",
        "biggest", "largest", "smallest", "any", "some", "there", "give", "show", "tell",
        // verbs of spending/visiting that are never merchant names
        "shop", "shopping", "shops", "store", "stores", "visit", "visited", "visiting",
        "eat", "ate", "eating", "went", "off", "list", "receive",
        // politeness / filler that must never become a phantom merchant target
        "please", "thanks", "thank", "kindly", "okay", "just", "really", "actually",
        // intent words that could otherwise match a description as a whole word
        "receive", "received", "receiving", "income", "earn", "earned", "earning",
        "save", "saved", "saving", "savings", "net", "gross", "profit", "loss",
        "surplus", "deposit", "deposits", "credited", "salary", "dividend", "refund",
        "subscription", "subscriptions", "recurring", "breakdown", "summary", "overall",
        "category", "categories", "percentage", "percent", "frequent", "different",
        "weekend", "weekends", "day", "days", "week", "month", "months", "year", "years",
        "owe", "owed", "owing", "outstanding", "due",
        "altogether", "overall", "everything", "anything", "something", "stuff", "things",
        "new", "old", "this", "these", "those", "here",
        "which", "who", "where", "when", "why", "whose", "than", "versus", "compare",
        "against", "most", "least", "fewest", "fewer", "portion", "fraction", "share",
        "pounds", "quid", "pence", "dollars", "euros", "rupees",
    ]

    /// Title-case a derived merchant token for display; short tokens (≤3 chars,
    /// e.g. "TFL") read better fully uppercased.
    private static func merchantDisplay(_ s: String) -> String {
        s.split(separator: " ").map { w -> String in
            w.count <= 3 ? w.uppercased() : w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }

    /// A description-derived merchant key for ranking: strips a leading card-acquirer
    /// prefix ("DOJO*", "TST-") and a numeric reference token, skips "THE"/"A", then
    /// keeps the leading letters of the first real word.
    private static func merchantKey(_ descr: String) -> String {
        var s = descr.trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: #"^[A-Za-z0-9]{2,}[\*\-]"#, options: .regularExpression) {
            s = String(s[r.upperBound...])
        }
        let skip: Set<String> = ["THE", "A", "AN", "OF", "-"]
        let toks = s.split(separator: " ").map { $0.uppercased() }
        let first = toks.first(where: { !$0.allSatisfy(\.isNumber) && !skip.contains($0) })
            ?? toks.first ?? s.uppercased()
        let letters = String(first.prefix { $0.isLetter })
        return letters.isEmpty ? first : letters
    }

    private static func merchantRanking(_ debits: [TxnRow], byCount: Bool,
                                        least: Bool = false,
                                        scopeLabel: String, money: (Double) -> String) -> String {
        // Group by the PARSED merchant field so the ranking matches the per-merchant
        // totals ("how much at X") exactly — a merchant whose rows have varied raw
        // descriptions (e.g. CAREDENTALPLATINUM.COM + CARE DENTAL PLATINUM) stays one
        // merchant. Fall back to the description-derived key only when merchant is empty.
        var tot: [String: (amount: Double, count: Int, name: String)] = [:]
        for r in debits {
            let usesMerchant = !r.merchant.isEmpty
            let key = usesMerchant ? r.merchant.lowercased() : merchantKey(r.descr)
            let name = usesMerchant ? r.merchant : merchantKey(r.descr).capitalized
            var e = tot[key] ?? (0, 0, name)
            e.amount += r.debit; e.count += 1
            tot[key] = e
        }
        let ranked = tot.sorted {
            let a = byCount ? Double($0.value.count) : $0.value.amount
            let b = byCount ? Double($1.value.count) : $1.value.amount
            return least ? a < b : a > b
        }
        guard let top = ranked.first else { return "No spending to rank." }
        let name = top.value.name
        if byCount {
            let sup = least ? "least-used" : "most-used"
            return "**Your \(sup) merchant\(scopeLabel) is \(name)** — \(top.value.count) transaction\(top.value.count == 1 ? "" : "s") totalling \(money(top.value.amount))."
        }
        let verb = least ? "least" : "most"
        return "**You spent the \(verb) at \(name)\(scopeLabel): \(money(top.value.amount))** across \(top.value.count) transaction\(top.value.count == 1 ? "" : "s")."
    }

    private static let monthNames: [(String, Int)] = [
        ("january", 1), ("jan", 1), ("february", 2), ("feb", 2), ("march", 3), ("mar", 3),
        ("april", 4), ("apr", 4), ("may", 5), ("june", 6), ("jun", 6), ("july", 7), ("jul", 7),
        ("august", 8), ("aug", 8), ("september", 9), ("sep", 9), ("sept", 9), ("october", 10),
        ("oct", 10), ("november", 11), ("nov", 11), ("december", 12), ("dec", 12),
    ]

    /// A date RANGE scope: "between 16 and 28 February", "from 1 March to 10 March",
    /// "Feb 16 to Feb 20", "first/last week", "first/second half of March". Returns
    /// the rows inside [start, end] and a readable label, or nil if no range parsed.
    private static func matchDateRange(_ low: String, rows: [TxnRow]) -> (rows: [TxnRow], label: String)? {
        // "between 10 and 20 pounds" is an AMOUNT range, not a date range — let the
        // amount-range handler own it, don't scope to the 10th–20th of the month.
        if matches(low, #"between\s+£?\s*\d+(?:\.\d+)?\s+and\s+£?\s*\d+(?:\.\d+)?"#),
           matches(low, #"pounds?|quid|pence|dollars?|euros?|rupees?|£"#) { return nil }
        let allDates = rows.map(\.txnDate).sorted()
        guard let minD = allDates.first, let maxD = allDates.last else { return nil }
        func inRange(_ a: String, _ b: String) -> [TxnRow] {
            let lo = min(a, b), hi = max(a, b)
            return rows.filter { $0.txnDate >= lo && $0.txnDate <= hi }
        }

        // ---- relative windows ----------------------------------------------
        if matches(low, #"first week"#) {
            return (inRange(minD, addDays(minD, 6)), " in the first week")
        }
        if matches(low, #"last week"#) {
            return (inRange(addDays(maxD, -6), maxD), " in the last week")
        }
        // "first/second half of <month>" (or of the statement)
        if matches(low, #"first half|1st half|second half|2nd half|latter half"#) {
            let firstHalf = matches(low, #"first half|1st half"#)
            if let mo = monthNames.first(where: { matches(low, #"\b"# + $0.0 + #"\b"#) })?.1 {
                let y = rows.filter { $0.monthNo == mo }.map(\.year).max()
                    ?? rows.map(\.year).max() ?? 0
                let lo = String(format: "%04d-%02d-%02d", y, mo, firstHalf ? 1 : 16)
                let hi = String(format: "%04d-%02d-%02d", y, mo, firstHalf ? 15 : 31)
                let lbl = " in the \(firstHalf ? "first" : "second") half of \(monthAbbr(mo))"
                return (inRange(lo, hi), lbl)
            }
            // half of the whole statement
            let mid = addDays(minD, spanDays(rows) / 2)
            return firstHalf ? (inRange(minD, mid), " in the first half")
                             : (inRange(addDays(mid, 1), maxD), " in the second half")
        }

        // ---- rolling N-day windows ("last 7 days", "first 10 days") ---------
        if let g = firstGroup(low, #"(?:last|past|previous)\s+(\d{1,3})\s+days"#), let n = Int(g), n > 0 {
            return (inRange(addDays(maxD, -(n - 1)), maxD), " in the last \(n) days")
        }
        if let g = firstGroup(low, #"first\s+(\d{1,3})\s+days"#), let n = Int(g), n > 0 {
            return (inRange(minD, addDays(minD, n - 1)), " in the first \(n) days")
        }

        // ---- single relative day ("the last day", "my first day") -----------
        if matches(low, #"\b(?:the\s+)?(?:last|final)\s+day\b"#) {
            return (inRange(maxD, maxD), " on the last day (\(maxD))")
        }
        if matches(low, #"\b(?:the\s+|my\s+)?first\s+day\b"#) {
            return (inRange(minD, minD), " on the first day (\(minD))")
        }

        // ---- open-ended: since/after X → …end; before/until/up to X ← start --
        let openKinds: [(String, String)] = [
            (#"\bsince\b"#, "since"), (#"\bafter\b"#, "after"),
            (#"\bbefore\b"#, "before"), (#"\buntil\b"#, "until"), (#"\bup to\b"#, "upto"),
        ]
        for (pat, kind) in openKinds {
            guard let r = low.range(of: pat, options: .regularExpression) else { continue }
            let tail = String(low[r.upperBound...])
            var d = 0, mo = 0
            // "until the end of <month>" → the month's final day (day 31 is a safe
            // inclusive upper bound under string comparison).
            if matches(tail, #"^\s*(?:the\s+)?end of\b"#),
               let m = monthNames.first(where: { matches(tail, #"\b"# + $0.0 + #"\b"#) })?.1 {
                d = 31; mo = m
            } else if let (dd, mm) = parseDayMonth(tail) {
                d = dd
                mo = mm ?? (rows.map(\.monthNo).max() ?? 1)
            } else { continue }
            let y = rows.filter { $0.monthNo == mo }.map(\.year).max()
                ?? rows.map(\.year).max() ?? 0
            guard y > 0 else { continue }
            let iso = String(format: "%04d-%02d-%02d", y, mo, d)
            let dayLbl = d == 31 && matches(tail, #"^\s*(?:the\s+)?end of\b"#)
                ? "the end of \(monthAbbr(mo))" : "\(d) \(monthAbbr(mo))"
            switch kind {
            case "since":  return (inRange(iso, maxD), " since \(dayLbl)")
            case "after":  return (inRange(addDays(iso, 1), maxD), " after \(dayLbl)")
            case "before": return (inRange(minD, addDays(iso, -1)), " before \(dayLbl)")
            default:       return (inRange(minD, iso), " up to \(dayLbl)")
            }
        }

        // ---- explicit two-date range ---------------------------------------
        guard matches(low, #"\bbetween\b|\bfrom\b.*\bto\b|\bto\b|\bthrough\b|\d\s*[-–]\s*\d"#) else { return nil }
        // Split into two sides on the range operator (prefer "and" when "between").
        let sepPattern = matches(low, #"\bbetween\b"#) ? #"\band\b"#
            : matches(low, #"\bto\b"#) ? #"\bto\b"#
            : matches(low, #"\bthrough\b"#) ? #"\bthrough\b"#
            : #"\s*[-–]\s*"#
        guard let r = low.range(of: sepPattern, options: .regularExpression) else { return nil }
        let leftS = String(low[low.startIndex..<r.lowerBound])
        let rightS = String(low[r.upperBound...])
        guard let (d1, m1) = parseDayMonth(leftS), let (d2, m2) = parseDayMonth(rightS) else { return nil }
        // inherit a missing month from the other side, else the data's month.
        let dataMonth = rows.map(\.monthNo).max() ?? 1
        let mo1 = m1 ?? m2 ?? dataMonth
        let mo2 = m2 ?? m1 ?? dataMonth
        let y1 = rows.filter { $0.monthNo == mo1 }.map(\.year).max() ?? rows.map(\.year).max() ?? 0
        let y2 = rows.filter { $0.monthNo == mo2 }.map(\.year).max() ?? y1
        let start = String(format: "%04d-%02d-%02d", y1, mo1, d1)
        let end = String(format: "%04d-%02d-%02d", y2, mo2, d2)
        let label = " between \(d1) \(monthAbbr(mo1)) and \(d2) \(monthAbbr(mo2))"
        return (inRange(start, end), label)
    }

    /// Extract (day, monthNo?) from a fragment like "28 february", "feb 20", "from 1 march".
    private static func parseDayMonth(_ s: String) -> (Int, Int?)? {
        let mo = monthNames.first(where: { s.range(of: #"\b"# + $0.0 + #"\b"#, options: .regularExpression) != nil })?.1
        guard let dg = firstGroup(s, #"\b(\d{1,2})(?:st|nd|rd|th)?\b"#), let d = Int(dg), (1...31).contains(d) else {
            return nil
        }
        return (d, mo)
    }

    private static func matchPeriod(_ low: String, rows: [TxnRow]) -> ([TxnRow], String)? {
        let sortedMonths = Set(rows.map(\.month)).sorted()   // "YYYY-MM"
        // relative: this / last month, anchored to the latest month in the data
        if matches(low, #"this month|current month"#), let m = sortedMonths.last {
            return (rows.filter { $0.month == m }, "this month")
        }
        if matches(low, #"last month|previous month"#), sortedMonths.count >= 1 {
            let m = sortedMonths.count >= 2 ? sortedMonths[sortedMonths.count - 2] : sortedMonths[0]
            return (rows.filter { $0.month == m }, "last month")
        }
        // named month (matches whole word so "mar" doesn't hit "market"). Apply
        // the scope even when the month has no rows in the (possibly already
        // category/merchant-scoped) set, so "Entertainment in February" honestly
        // answers £0 instead of silently dropping the month and reporting the
        // whole-category total. Exception: "may" is highly ambiguous with the
        // modal verb, so only honour it when it actually matches data.
        for (name, no) in monthNames where matches(low, #"\b"# + name + #"\b"#) {
            let inMonth = rows.filter { $0.monthNo == no }
            if !inMonth.isEmpty || name != "may" {
                return (inMonth, "in " + name.prefix(1).uppercased() + name.dropFirst())
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// "Which of my statements is a credit card / current account?" — a
    /// document-identity question, answered from each account's `isCard` flag
    /// rather than the merged rows. Fires only when an account-TYPE phrase
    /// ("credit card", "current account", …) is paired with an identity cue
    /// (which / belongs / "is X a …" / identify), so ordinary "spent on my
    /// credit card" spend questions fall through. Returns nil (defer) when no
    /// account context was supplied, so the router still works in row-only tests.
    private static func accountTypeAnswer(_ low: String,
                                          accounts: [AccountBalance]) -> String? {
        guard !accounts.isEmpty else { return nil }

        // A spend / bill / balance question that merely mentions "credit card" is
        // NOT an identity lookup — don't let "how much is my credit card bill?"
        // answer with "X is your credit-card statement."
        if matches(low, #"how much|\bbill\b|\bowe|\bbalance\b|spen[dt]|\bpaid\b|left to pay"#) {
            return nil
        }

        // Credit-card side.
        if matches(low, #"credit[\s-]?cards?"#),
           matches(low, #"\bwhich\b|\bbelongs?\b|\b(?:is|are)\b.*credit[\s-]?card|\bidentif\w*"#) {
            return namedList(accounts.filter(\.isCard),
                             singular: "is your credit-card statement",
                             plural: "These are your credit-card statements:",
                             none: "**None of your imported statements is a credit card** — they all read as bank / current accounts.")
        }

        // Current / bank-account side (everything that isn't a card).
        if matches(low, #"\b(?:current|checking|chequing)\s+accounts?\b|\bbank\s+accounts?\b"#),
           matches(low, #"\bwhich\b|\bbelongs?\b|\b(?:is|are)\b.*account|\bidentif\w*"#) {
            return namedList(accounts.filter { !$0.isCard },
                             singular: "is your current account",
                             plural: "These are your current (bank) accounts:",
                             none: "**None of your imported statements is a current account** — they all read as credit cards.")
        }

        return nil
    }

    /// Render the matched accounts as an identity answer: an honest "none" line
    /// when empty, a single-line statement for one, else a bulleted list. Names
    /// are sorted so the order is stable and readable.
    private static func namedList(_ accounts: [AccountBalance],
                                  singular: String, plural: String, none: String) -> String {
        guard !accounts.isEmpty else { return none }
        let names = accounts.map(\.name).sorted()
        if names.count == 1 { return "**\(names[0]) \(singular).**" }
        return (["**\(plural)**"] + names.map { "- \($0)" }).joined(separator: "\n")
    }

    /// True when the question asks for a statement-header field the transaction
    /// router cannot compute from rows (rewards, credit line, rates, fees, payment
    /// schedule, account identifiers). These defer to the LLM / metadata layer.
    private static func isHeaderMetadataQuery(_ low: String) -> Bool {
        // Membership Rewards / points.
        if matches(low, #"\bpoints?\b|\brewards?\b"#) { return true }
        // Credit line.
        if matches(low, #"credit limit|available credit|remaining credit|spending limit"#) { return true }
        // Payment schedule (minimum payment, due date, how/when/whom to pay).
        if matches(low, #"\bminimum\b|need to pay|have to pay|amount due|payment due|due date|least i can pay|when (?:should|do|can|is|are).*(?:pay|due)|how (?:can|do) i pay|how to pay|can i pay|pay (?:using|by|via|from)|payment method|paperless|direct debit enrol"#) { return true }
        // Interest & fees (rates and fee amounts — none are transaction rows here).
        // Interest — but NOT "interest earned/credited" (that's income the router can sum).
        if matches(low, #"\binterest\b|interest[- ]free"#),
           !matches(low, #"interest (?:earned|credited|received)|earned.*interest"#) { return true }
        if matches(low, #"\bapr\b|annual rate|monthly rate|foreign transaction fee|non[- ]?sterling|exchange rate|late payment fee|returned payment fee|annual fee|cardmembership fee|membership fee|copy statement fee|compound|simple rate|cash advance|balance transfer"#) { return true }
        // Header identity / non-closing balances / account identifiers.
        if matches(low, #"previous (?:closing )?balance|opening balance|starting balance|statement period|statement date|statement issued|billing period|membership number|account number|sort code|\biban\b|\bswift\b|next.*fee date|fee date|prepared for|customer service|who issued|regulated|registered office|how many pages|instal?ment|allocat|complain|\bagreement\b|ombudsman|(?:update|change).{0,10}address|included by|charges (?:received|included)"#) { return true }
        return false
    }

    private static func isAdvisory(_ low: String) -> Bool {
        matches(low, #"\broast\b|\badvice\b|\badvise\b|recommend|worth it|\bopinion\b|feel about|forecast|predict\b|\bwhy\b|worried|\bworry\b|\bhealthy\b|can i afford|help me|are my finances|cut back|cutback|under control|on track|do you think|too much|how can i|how do i|what can i|better off|should i (?:cut|reduce|stop|be|spend|budget)"#)
    }

    // MARK: - Financial-reasoning handlers (savings, runway, risky, trend, recurring)

    private struct MonthAgg { let month: String; let debit: Double; let credit: Double; let count: Int }

    private static func byMonth(_ rows: [TxnRow]) -> [MonthAgg] {
        var acc: [String: (Double, Double, Int)] = [:]
        for r in rows {
            var e = acc[r.month] ?? (0, 0, 0)
            e.0 += r.debit; e.1 += r.credit; e.2 += 1
            acc[r.month] = e
        }
        return acc.keys.sorted().map { MonthAgg(month: $0, debit: acc[$0]!.0, credit: acc[$0]!.1, count: acc[$0]!.2) }
    }

    /// "2026-06" → "Jun 2026".
    private static func mlabel(_ ym: String) -> String {
        let p = ym.split(separator: "-")
        guard p.count == 2, let mo = Int(p[1]), (1...12).contains(mo) else { return ym }
        let abbr = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][mo]
        return "\(abbr) \(p[0])"
    }

    private static func signedPct(_ a: Double, _ b: Double) -> String {
        let v = b != 0 ? (a - b) / b * 100 : 0
        return "\(v >= 0 ? "+" : "")\(String(format: "%.1f", v))%"
    }

    /// what-if "cut … by N%": returns (fraction, "N") or nil.
    private static func whatIfPercent(_ low: String) -> (Double, String)? {
        guard matches(low, #"\b(?:cut|reduce|trim|lower|slash|decreas\w*|drop)\b.*?\bby\s+\d"#),
              let n = firstGroup(low, #"\bby\s+(\d+(?:\.\d+)?)\s*%"#), let v = Double(n) else { return nil }
        return (v / 100.0, n)
    }

    private static func financialReasoning(_ low: String, allRows: [TxnRow],
                                           money: (Double) -> String) -> String? {
        // Gate: only enter for savings / income / trend / risk / consistency /
        // recurring questions (mirrors analytics.py's trigger regex).
        let gate = #"\bsav(?:e|ed|es|ing|ings)?\b|runway|survive|income stop|\brisky?\b|overspent|deficit|in the red|financ|consisten|stable|steady|volatil|erratic|fluctuat|predictab|\bvary\b|variab|earning|\bincome\b|salary|subscription|recurr|repeat\w*|\btrend\b|spending profile|spending style|last\s+\d+\s+months?"#
        guard matches(low, gate) else { return nil }

        // Period-only scope (never category/merchant): these questions are account-wide.
        let periodRows: [TxnRow]
        let sfx: String
        if let (rowsInPeriod, plabel) = matchPeriod(low, rows: allRows) {
            periodRows = rowsInPeriod; sfx = " " + plabel
        } else {
            periodRows = allRows; sfx = ""
        }

        let bm = byMonth(periodRows)
        let mset = bm.filter { $0.debit > 0 || $0.credit > 0 }
        let nmon = max(1, mset.count)
        let totalDebit = periodRows.reduce(0) { $0 + $1.debit }
        let totalCredit = periodRows.reduce(0) { $0 + $1.credit }

        // ---- period-vs-period: "last 6 months vs the previous 6 months" -----
        if let m = firstTwoGroups(low, #"last\s+(\d+)\s+months?\s+(?:with|to|and|vs\.?|versus|against|compared?\s+(?:to|with))\s+(?:the\s+)?(?:previous|prior|preceding|last|earlier)\s*(\d+)?\s*months?"#) {
            let allm = byMonth(allRows)
            let n1 = Int(m.0) ?? 0
            let n2 = m.1.flatMap(Int.init) ?? n1
            if n1 > 0, allm.count >= n1 + n2 {
                let rec = Array(allm.suffix(n1))
                let prev = Array(allm[(allm.count - n1 - n2)..<(allm.count - n1)])
                let rd = rec.reduce(0) { $0 + $1.debit }, rc = rec.reduce(0) { $0 + $1.credit }
                let pd = prev.reduce(0) { $0 + $1.debit }, pc = prev.reduce(0) { $0 + $1.credit }
                let rl = "\(mlabel(rec.first!.month))–\(mlabel(rec.last!.month))"
                let pl = "\(mlabel(prev.first!.month))–\(mlabel(prev.last!.month))"
                return "**Last \(n1) months (\(rl)) vs previous \(n2) (\(pl)):**\n"
                    + "- Spending: \(money(pd)) → \(money(rd)) (\(signedPct(rd, pd)))\n"
                    + "- Income: \(money(pc)) → \(money(rc)) (\(signedPct(rc, pc)))\n"
                    + "- Net: \(money(pc - pd)) → \(money(rc - rd)) (\(signedPct(rc - rd, pc - pd)))"
            }
        }

        // ---- savings rate ---------------------------------------------------
        if matches(low, #"\bsav(?:e|ed|es|ing|ings)\b"#),
           matches(low, #"\b(rate|percent|percentage|%|ratio|proportion)\b"#),
           !matches(low, #"\b(target|goal|should)\b"#) {
            guard totalCredit > 0 else { return "**Savings rate\(sfx):** no income recorded." }
            let saved = totalCredit - totalDebit
            return "**Savings rate\(sfx): \(String(format: "%.1f", saved / totalCredit * 100))%** — saved \(money(saved)) of \(money(totalCredit)) income (spent \(money(totalDebit)))."
        }

        // ---- savings target (20% guideline) ---------------------------------
        if matches(low, #"sav(?:ing|ings)?\s+(?:target|goal)|how much should i save|monthly savings target|how much.*should.*save"#) {
            let minc = totalCredit / Double(nmon)
            let cur = (totalCredit - totalDebit) / Double(nmon)
            let curPct = totalCredit > 0 ? (totalCredit - totalDebit) / totalCredit * 100 : 0
            return "**Suggested monthly savings target\(sfx): \(money(minc * 0.20))** — 20% of your average monthly income (\(money(minc))). You already save about \(money(cur))/month (\(String(format: "%.1f", curPct))% of income)."
        }

        // ---- survival runway ------------------------------------------------
        if matches(low, #"how (?:long|many months).*(survive|last|go|cover)|\b(runway|emergency fund)\b|if (?:my )?income (?:stop|stopped|stops|dried)|without (?:any )?income|no income"#) {
            let bal = periodRows.last(where: { $0.balance != nil })?.balance
            let avgSp = totalDebit / Double(nmon)
            if let bal, avgSp > 0 {
                return "**Survival runway\(sfx): about \(String(format: "%.1f", bal / avgSp)) months** — closing balance \(money(bal)) ÷ average monthly spend \(money(avgSp))."
            }
        }

        // ---- financially risky months (spending > income) -------------------
        if matches(low, #"\b(risky|risk|overspent|over[-\s]?spent|deficit|in the red)\b"#),
           matches(low, #"\bmonths?\b"#) {
            let neg = bm.filter { $0.credit - $0.debit < 0 }
            if !neg.isEmpty {
                let body = neg.map { "\(mlabel($0.month)) (\(money($0.credit - $0.debit)))" }.joined(separator: ", ")
                return "**Financially risky months\(sfx)** (spending beat income): \(body)"
            }
            let tight = bm.sorted { ($0.credit - $0.debit) < ($1.credit - $1.debit) }.prefix(3)
            let body = tight.map { "\(mlabel($0.month)) (net \(money($0.credit - $0.debit)))" }.joined(separator: ", ")
            return "**No risky months\(sfx)** — income exceeded spending every month. Tightest: \(body)."
        }

        // ---- spending consistency (coefficient of variation) ----------------
        if matches(low, #"\b(consisten|stable|steady|volatil|erratic|predictab|fluctuat|regular|vary|variab)\w*"#),
           matches(low, #"spend|spending|expense"#) {
            let vals = mset.map(\.debit)
            if !vals.isEmpty {
                let mean = vals.reduce(0, +) / Double(vals.count)
                let std = (vals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(vals.count)).squareRoot()
                let cv = mean != 0 ? std / mean * 100 : 0
                let verdict = cv < 10 ? "very consistent" : cv < 20 ? "fairly consistent" : cv < 35 ? "somewhat variable" : "highly variable"
                return "**Spending consistency\(sfx): \(verdict)** — averages \(money(mean))/month, ranging \(money(vals.min()!))–\(money(vals.max()!)) (variation ±\(String(format: "%.0f", cv))%)."
            }
        }

        // ---- income trend / growth ------------------------------------------
        if matches(low, #"\b(earning|earnings|income|salary)\b"#),
           matches(low, #"\b(grow|growing|grew|increas\w*|rising|risen|trend|over time|going up|improv\w*|declin\w*|drop\w*)\b"#) {
            let creds = bm.map(\.credit)
            if creds.count >= 2 {
                let half = creds.count / 2
                let h1 = creds.prefix(half).reduce(0, +)
                let h2 = creds.suffix(creds.count - half).reduce(0, +)
                if h1 > 0 {
                    let chg = (h2 - h1) / h1 * 100
                    let dir = chg > 2 ? "growing" : chg < -2 ? "declining" : "broadly flat"
                    return "**Income trend\(sfx): \(dir)** — earlier half \(money(h1)) vs later half \(money(h2)) (\(signedPct(h2, h1)))."
                }
            }
        }

        // ---- recurring charges & subscriptions ------------------------------
        // Deferred when the question is a direct "how much did I spend on
        // subscriptions" total (a category-spend lookup) OR a count like "how
        // many subscriptions" (a category-count lookup) — both are handled by
        // the scoped catch-alls below, not a request to enumerate the cadence.
        if matches(low, #"subscription|recurr|repeat\w*|regular (?:payment|charge)|standing order|direct debit"#),
           !matches(low, #"\bhow much\b|\btotal\b|\bspen[dt]\b|\baverage\b|\bhow many\b|\bnumber of\b|\bcount\b|how often"#) {
            return recurringAnswer(periodRows, money: money)
        }

        return nil
    }

    /// One auto-detected recurring charge / subscription.
    public struct RecurringCharge: Sendable {
        public let name: String
        public let months: Int      // distinct months it appeared in
        public let amount: Double    // typical (mean) amount
        public let count: Int        // number of occurrences
        public let confidence: Double // 0…1 (1 − coefficient of variation)
    }

    /// Deterministic recurring-charge detector: a merchant that appears in ≥3
    /// distinct months with a stable amount (coefficient of variation ≤ 25%).
    /// Powers both the "subscriptions" answer and the sidebar's Ghosts badge —
    /// so that badge shows a REAL count, never a hardcoded placeholder.
    public static func recurringCharges(_ rows: [TxnRow]) -> [RecurringCharge] {
        var byMerchant: [String: [TxnRow]] = [:]
        for r in rows where r.debit > 0 {
            let key = r.merchant.isEmpty ? r.descr : r.merchant
            guard key.count >= 3 else { continue }
            byMerchant[key, default: []].append(r)
        }
        var found: [RecurringCharge] = []
        for (name, txns) in byMerchant {
            let months = Set(txns.map(\.month)).count
            guard txns.count >= 3, months >= 3 else { continue }
            let amts = txns.map(\.debit)
            let mean = amts.reduce(0, +) / Double(amts.count)
            guard mean > 0 else { continue }
            let std = (amts.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(amts.count)).squareRoot()
            let cv = std / mean
            guard cv <= 0.25 else { continue }
            found.append(RecurringCharge(name: name, months: months, amount: mean, count: txns.count, confidence: 1 - cv))
        }
        return found.sorted { $0.count > $1.count }
    }

    private static func recurringAnswer(_ rows: [TxnRow], money: (Double) -> String) -> String? {
        let found = recurringCharges(rows)
        guard !found.isEmpty else {
            return "**No recurring charges or subscriptions detected.** Nothing repeats at a steady cadence and stable amount."
        }
        let monthly = found.reduce(0.0) { $0 + $1.amount }
        var lines = ["**Recurring charges & subscriptions** — payments repeating at a regular cadence and similar amount (about \(money(monthly))/month):", ""]
        for r in found.prefix(15) {
            lines.append("- **\(r.name)** — ~\(money(r.amount)) × \(r.count) (\(r.months) months, \(Int(r.confidence * 100))% confidence)")
        }
        return lines.joined(separator: "\n")
    }

    /// Ordinal cue for Nth-largest questions ("second biggest", "3rd largest").
    private static func ordinalN(_ low: String) -> Int? {
        if matches(low, #"\b(?:second|2nd)\b"#) { return 2 }
        if matches(low, #"\b(?:third|3rd)\b"#) { return 3 }
        if matches(low, #"\b(?:fourth|4th)\b"#) { return 4 }
        if matches(low, #"\b(?:fifth|5th)\b"#) { return 5 }
        return nil
    }

    /// top-N intent: explicit "top 5" / "biggest 3", or a plural "expenses/transactions"
    /// paired with a superlative. Returns the N (default 5) or nil.
    private static let wordNumbers: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]

    private static func topN(_ low: String) -> Int? {
        if let m = firstGroup(low, #"\b(?:top|biggest|largest|highest)\s+(\d{1,2})\b"#), let n = Int(m) {
            return max(1, min(n, 50))
        }
        // word numbers: "top five expenses", "biggest three purchases"
        if let m = firstGroup(low, #"\b(?:top|biggest|largest|highest)\s+(one|two|three|four|five|six|seven|eight|nine|ten)\b"#),
           let n = wordNumbers[m] {
            return n
        }
        if matches(low, #"\b(top|biggest|largest|highest|most expensive)\b"#),
           matches(low, #"expenses|transactions|purchases|payments|spends|debits"#) {
            return 5
        }
        return nil
    }

    private static func categoryBreakdown(_ debits: [TxnRow], total: Double,
                                          scopeLabel: String, money: (Double) -> String) -> String {
        var totals: [String: Double] = [:]
        for t in debits { totals[t.category.isEmpty ? "Other" : t.category, default: 0] += t.debit }
        let ranked = totals.sorted { $0.value > $1.value }.prefix(8)
        var lines = ["**Spending by category\(scopeLabel):**"]
        for (cat, amt) in ranked {
            let pct = total > 0 ? amt / total * 100 : 0
            lines.append("- **\(cat)**: \(money(amt)) (\(String(format: "%.1f", pct))%)")
        }
        return lines.joined(separator: "\n")
    }

    /// Thousands grouping for plain counts (Python's grp()).
    private static func grp(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - Date helpers (span, weekday, pretty-print)

    private static let isoCal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static func parseISO(_ s: String) -> DateComponents? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return DateComponents(year: p[0], month: p[1], day: p[2])
    }

    /// Calendar-day span (inclusive) covered by the rows — for per-day/week averages.
    private static func spanDays(_ rows: [TxnRow]) -> Int {
        let ds = rows.map(\.txnDate).sorted()
        guard let f = ds.first, let l = ds.last,
              let fc = parseISO(f), let lc = parseISO(l),
              let fd = isoCal.date(from: fc), let ld = isoCal.date(from: lc),
              let d = isoCal.dateComponents([.day], from: fd, to: ld).day else {
            return max(1, Set(rows.map(\.txnDate)).count)
        }
        return max(1, d + 1)
    }

    private static func isWeekend(_ iso: String) -> Bool {
        guard let c = parseISO(iso), let d = isoCal.date(from: c) else { return false }
        return isoCal.isDateInWeekend(d)
    }

    /// "2026-02-15" + n days → ISO (n may be negative).
    private static func addDays(_ iso: String, _ n: Int) -> String {
        guard let c = parseISO(iso), let d = isoCal.date(from: c),
              let nd = isoCal.date(byAdding: .day, value: n, to: d) else { return iso }
        let e = isoCal.dateComponents([.year, .month, .day], from: nd)
        return String(format: "%04d-%02d-%02d", e.year ?? 0, e.month ?? 0, e.day ?? 0)
    }

    private static let monthAbbrs = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private static func monthAbbr(_ m: Int) -> String {
        (1...12).contains(m) ? monthAbbrs[m] : "\(m)"
    }

    /// "2026-02-17" → "17 Feb 2026".
    private static func prettyDate(_ iso: String) -> String {
        let p = iso.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...12).contains(p[1]) else { return iso }
        return "\(p[2]) \(monthAbbrs[p[1]]) \(p[0])"
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func firstGroup(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// First match's group 1 and (optional) group 2.
    private static func firstTwoGroups(_ s: String, _ pattern: String) -> (String, String?)? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges > 1,
              let r1 = Range(m.range(at: 1), in: s) else { return nil }
        var g2: String? = nil
        if m.numberOfRanges > 2, let r2 = Range(m.range(at: 2), in: s) { g2 = String(s[r2]) }
        return (String(s[r1]), g2)
    }
}
