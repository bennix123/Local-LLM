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
import NaturalLanguage   // POS gate on target extraction (A1 class 1)

public enum FinanceRouter {

    /// One account's latest balance, for multi-account balance answers.
    /// `isCard` = credit-card semantics: the balance is money OWED, so it
    /// subtracts from the total rather than adding. `currency` (optional, for
    /// callers that know it) lets mixed-currency sessions scope balance answers
    /// to the right partition instead of summing £ with ₹.
    public struct AccountBalance: Sendable {
        public let name: String
        public let balance: Double?
        public let isCard: Bool
        public let currency: String?
        public init(name: String, balance: Double?, isCard: Bool, currency: String? = nil) {
            self.name = name; self.balance = balance; self.isCard = isCard
            self.currency = currency
        }
    }

    /// Deterministically answer `question` from `rows`, or return nil to defer
    /// to the model. `money` formats an amount in the statement's currency
    /// (the app passes its `Money.format`; tests pass a simple formatter).
    /// `accounts` (optional) enables exact multi-account balance answers.
    ///
    /// Mixed currencies NEVER blend: when rows carry more than one currency the
    /// question is answered once per currency (each partition through the full
    /// single-currency router with its own symbol) and the answers are joined —
    /// ₹ + £ is not a sum, and no exchange-rate conversion is ever attempted.
    public static func answer(_ question: String,
                              rows: [TxnRow],
                              currency: String,
                              accounts: [AccountBalance] = [],
                              previousQuestion: String? = nil,
                              money: (Double) -> String) -> String? {
        // B4 — elliptical follow-ups inherit the previous question's scope.
        let question = carryScope(into: question, from: previousQuestion, rows: rows)
        let codes = Set(rows.map { $0.currency.isEmpty ? currency : $0.currency })
        if codes.count > 1 {
            return multiCurrencyAnswer(question, rows: rows,
                                       fallbackCurrency: currency, accounts: accounts)
        }
        return answerSingleCurrency(question, rows: rows, currency: currency,
                                    accounts: accounts, money: money)
    }

    /// B4 — conversation scope carry. "And in July?" / "what about transport?" /
    /// "same for Zara?" are answered as humans mean them: whatever dimension the
    /// follow-up DIDN'T restate (entity or period) is inherited from the previous
    /// question, and an intent-less fragment reuses the previous question's
    /// intent wholesale. Carry only fires on explicit follow-up markers or a
    /// short fragment — a complete question is never contaminated by history.
    ///
    /// Callers should resolve ONCE at the boundary and record the RESOLVED
    /// question as history — recording the raw fragment makes the next
    /// follow-up inherit from an intent-less stem. Idempotent for resolved
    /// questions (a complete question passes through untouched).
    public static func resolveFollowUp(_ question: String, previous: String?,
                                       rows: [TxnRow]) -> String {
        carryScope(into: question, from: previous, rows: rows)
    }

    static func carryScope(into question: String, from previous: String?,
                           rows: [TxnRow]) -> String {
        guard let previous, !previous.isEmpty, !rows.isEmpty else { return question }
        let low = question.lowercased()
        let hasMarker = matches(low, #"^\s*(?:and|what about|how about|what abt|same for|also|now|ok(?:ay)?,?\s+and)\b"#)
        let wordCount = low.split(whereSeparator: { $0.isWhitespace }).count
        guard hasMarker || wordCount <= 3 else { return question }

        let newScope = parseScope(low, rows: rows)
        let prevScope = parseScope(previous.lowercased(), rows: rows)
        let restatesEntity = newScope.hasCategory || newScope.hasMerchant || newScope.unmatchedTarget != nil
        let restatesPeriod = newScope.hasPeriod || newScope.dayISO != nil
        guard restatesEntity || restatesPeriod else { return question }   // nothing scoped — not a follow-up we understand

        let intentPattern = #"how much|how many|\btotal\b|spen[dt]|biggest|largest|smallest|average|\bavg\b|median|\bcount\b|\blist\b|balance|income|receiv|refund|percent|compare|breakdown"#
        var effective: String
        if matches(low, intentPattern) {
            effective = question
        } else {
            // Intent-less fragment ("and in July?"): reuse the previous question,
            // with the dimension the fragment replaces stripped out of it.
            var stem = previous.lowercased()
            if restatesPeriod, let p = prevScope.periodText {
                stem = stem.replacingOccurrences(of: p.lowercased(), with: " ")
            }
            if restatesEntity, let e = prevScope.entity {
                stem = stem.replacingOccurrences(of: e.lowercased(), with: " ")
            }
            let fragment = low.replacingOccurrences(
                of: #"^\s*(?:and|what about|how about|what abt|same for|also|now|ok(?:ay)?,?\s+and)\b"#,
                with: "", options: .regularExpression)
            effective = stem + " " + fragment
        }
        // Inherit whatever the fragment did not restate.
        if !restatesPeriod, let p = prevScope.periodText { effective += " " + p }
        if !restatesEntity, let e = prevScope.entity {
            effective += (prevScope.hasCategory ? " on " : " at ") + e
        }
        return effective
    }

    /// One answer per currency, largest ledger first. Honest-zero sections
    /// ("couldn't find X") are dropped when another currency has real hits, so
    /// "spend at Zara" with Zara only on the Indian statement answers in ₹ alone.
    static func multiCurrencyAnswer(_ question: String, rows: [TxnRow],
                                    fallbackCurrency: String,
                                    accounts: [AccountBalance]) -> String? {
        let partitions = Dictionary(grouping: rows) {
            $0.currency.isEmpty ? fallbackCurrency : $0.currency
        }
        let ordered = partitions.sorted {
            $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count
        }
        var sections: [(code: String, answer: String, isZero: Bool)] = []
        for (code, part) in ordered {
            // Accounts scoped to this currency; untagged accounts are excluded in
            // mixed mode (including them would re-blend balances across sections).
            let accts = accounts.filter { $0.currency == code }
            guard let ans = answerSingleCurrency(question, rows: part, currency: code,
                                                 accounts: accts, money: defaultMoney(code)) else { continue }
            let isZero = ans.contains("I couldn't find any transactions matching")
                || ans.hasPrefix("**No transactions for")
                || ans.hasPrefix("**No —")
            sections.append((code, ans, isZero))
        }
        guard !sections.isEmpty else { return nil }
        let substantive = sections.filter { !$0.isZero }
        if substantive.isEmpty { return sections[0].answer }   // one honest zero, not three
        if substantive.count == 1 { return substantive[0].answer }
        return substantive.map { "**\($0.code)**\n\($0.answer)" }.joined(separator: "\n\n")
    }

    /// Symbol-correct formatter for a currency partition (grouped, 2 dp).
    /// Locale is pinned per currency — the machine's own locale must not leak
    /// (an en_IN system would lakh-group dollars: "$2,88,153.34").
    static func defaultMoney(_ code: String) -> (Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2; f.maximumFractionDigits = 2
        f.locale = Locale(identifier: code.uppercased() == "INR" ? "en_IN" : "en_US")
        let symbol: String
        switch code.uppercased() {
        case "GBP": symbol = "£"; case "INR": symbol = "₹"
        case "EUR": symbol = "€"; case "USD": symbol = "$"
        default: symbol = code + " "
        }
        return { symbol + (f.string(from: NSNumber(value: $0)) ?? String(format: "%.2f", $0)) }
    }

    /// Context assembly for the on-device model (B2): the rows RELEVANT to the
    /// question, selected by the router's own scope parse (category / merchant /
    /// period) instead of "the first N rows of the file". When the question
    /// scopes nothing, the most recent rows win — recency beats file order as a
    /// relevance prior. `total` is the scoped population size BEFORE the limit,
    /// so callers can disclose truncation honestly ("showing X of Y").
    public static func relevantRows(for question: String, in rows: [TxnRow],
                                    limit: Int = 400)
        -> (rows: [TxnRow], scopeLabel: String, total: Int) {
        let low = question.lowercased()
        let scope = parseScope(low, rows: rows)
        let scoped = (scope.hasCategory || scope.hasMerchant || scope.hasPeriod) ? scope.rows : rows
        guard scoped.count > limit else {
            return (scoped, scope.label.trimmingCharacters(in: .whitespaces), scoped.count)
        }
        let recent = scoped.sorted { ($0.txnDate, $0.seq) > ($1.txnDate, $1.seq) }.prefix(limit)
        // Chronological order restored — models reason better over time-ordered ledgers.
        return (recent.sorted { ($0.txnDate, $0.seq) < ($1.txnDate, $1.seq) },
                scope.label.trimmingCharacters(in: .whitespaces), scoped.count)
    }

    /// Money direction a question is scoped to: credits (money in) or debits
    /// (money out). Shared by the router, the app's transaction-table branch,
    /// and the LLM-digest context builder, so "credit vs debit" is decided by
    /// exactly one vocabulary everywhere.
    public enum TxnDirection: Sendable, Equatable { case credit, debit }

    // Noun patterns name the rows themselves ("credits", "deposits", "charges");
    // verb patterns describe flow ("received", "spent"). The itemised-list
    // handler only fires on an explicit noun — a bare verb like "spent" appears
    // in far too many aggregate questions to mean "give me a list".
    // `\bcredits?\b` excludes the compound-noun senses that aren't money-in:
    // "credit card", "credit limit/line/score/rating", "available credit".
    static let creditNounPattern = #"(?<!available\s)\bcredits?\b(?!\s+(?:cards?|limits?|lines?|scores?|ratings?)\b)|\bdeposits?\b|\bincomings?\b|money (?:in|received)\b|paid in\b"#
    static let debitNounPattern = #"\bdebits?\b(?!\s+cards?\b)|\bwithdrawals?\b|\bcharges?\b|\boutgoings?\b|money (?:out|spent)\b|paid out\b"#
    private static let creditVerbPattern = #"\bcredited\b|\breceived\b|\bincome\b|\bincoming\b|came in\b|come in\b|coming in\b"#
    private static let debitVerbPattern = #"\bdebited\b|\bspent\b|\bspending\b|\bcharged\b|\bwithdrew\b|\bwithdrawn\b|(?:i|we)\s+sent\b|\bsent\s+(?:to|out)\b"#

    /// Credit-only / debit-only intent, or nil when neither or both directions
    /// are named ("credits and debits" scopes nothing).
    public static func directionScope(_ question: String) -> TxnDirection? {
        let low = question.lowercased()
        let credit = matches(low, creditNounPattern) || matches(low, creditVerbPattern)
        let debit = matches(low, debitNounPattern) || matches(low, debitVerbPattern)
        if credit == debit { return nil }
        return credit ? .credit : .debit
    }

    /// The transactions and human scope behind a factual answer (Fixes 4 & 5).
    ///
    /// Runs the SAME scope + direction parsing the answer path uses, and returns
    /// the in-scope, direction-filtered rows plus a short label of the filter —
    /// so the UI can show WHICH transactions a figure came from ("Show 12
    /// transactions") and WHAT it was scoped to ("Groceries in June · money
    /// out"). Additive: it does not alter `answer()`.
    ///
    /// Returns nil when nothing distinguishing applies (a whole-ledger answer
    /// with no category/merchant/period/direction) or the scope is empty — in
    /// those cases there is no meaningful subset to show.
    public struct AnswerScope: Sendable, Equatable {
        public let rows: [TxnRow]        // in-scope, direction-filtered, newest first
        public let label: String         // e.g. "on Groceries in June · money out"
        public let directionNote: String?  // "money out" | "money in" | nil
    }

    public static func context(for question: String, rows: [TxnRow],
                               previousQuestion: String? = nil) -> AnswerScope? {
        guard !rows.isEmpty else { return nil }
        let q = carryScope(into: question, from: previousQuestion, rows: rows)
        let low = q.lowercased()
        let scope = parseScope(low, rows: rows)
        var scoped = scope.rows
        var parts: [String] = []

        if scope.hasCategory || scope.hasMerchant || scope.hasPeriod {
            let l = scope.label.trimmingCharacters(in: .whitespaces)
            if !l.isEmpty { parts.append(l) }
        }

        var directionNote: String?
        switch directionScope(q) {
        case .debit:
            scoped = scoped.filter { $0.debit > 0 }
            directionNote = "money out"; parts.append("money out")
        case .credit:
            scoped = scoped.filter { $0.credit > 0 && $0.category != "Payments" }
            directionNote = "money in"; parts.append("money in")
        case nil:
            // `directionScope` is conservative and doesn't treat the base verb
            // "spend" as a direction (only "spent"/"spending"). For receipts we
            // want the debit rows behind the most common question — "how much
            // did I spend on X" — so mirror that here, locally (this never
            // affects the shared answer path or the eval).
            if matches(low, #"\bspend\b"#) {
                scoped = scoped.filter { $0.debit > 0 }
                directionNote = "money out"; parts.append("money out")
            }
        }

        guard !parts.isEmpty, !scoped.isEmpty else { return nil }
        return AnswerScope(
            rows: scoped.sorted { ($0.txnDate, $0.seq) > ($1.txnDate, $1.seq) },
            label: parts.joined(separator: " · "),
            directionNote: directionNote)
    }

    static func answerSingleCurrency(_ question: String,
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
                            ("expences", "expenses"), ("groceies", "groceries"),
                            ("recieved", "received"), ("recieve", "receive")] {
            low = low.replacingOccurrences(of: #"\b"# + typo + #"\b"#, with: fix,
                                           options: .regularExpression)
        }

        // ---- statement-header metadata → defer -----------------------------
        // Rewards points, credit limit, interest rates, minimum payment, due date,
        // fees, membership/sort/IBAN numbers etc. live in the statement HEADER, not
        // in the transaction rows this router sums. Answering them from rows would
        // be misleading (e.g. "£0 on Minimum"), so defer to the LLM / metadata layer.
        if isHeaderMetadataQuery(low) { return nil }

        // ---- foreign / abroad spend → defer --------------------------------
        // "How much did I spend abroad / overseas / in foreign currency" needs
        // geo/FX knowledge the row set doesn't carry (a merchant in Reykjavik
        // isn't flagged as foreign). Answering deterministically would either
        // invent a phantom "£0 on Abroad" merchant or wrongly report the whole
        // total — so defer to the model, which can reason about locations.
        if matches(low, #"\babroad\b|\boverseas\b|\bforeign\b|internationa\w*|another country|different country|outside the (?:uk|country|us)|non[- ]?sterling"#) {
            return nil
        }

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

        // ---- payday: "when do I usually get paid — is it consistent?" -------
        // "paid" alone means SPENDING everywhere else in this router (the total
        // catch-all matches it), so the get-paid sense must be caught first,
        // from the credit side: the biggest credit of each month is the salary.
        if matches(low, #"(?:get|got|getting|being|usually|normally|when am i|when do i get) paid\b|\bpayday\b|salary (?:date|day|arrive\w*|come\w*|credited|land\w*)|when .{0,24}(?:salary|wages)"#),
           !matches(low, #"\bpaid (?:off|for|out|back)\b|repay"#) {
            let salaryish = rows.filter { $0.credit > 0 && $0.category != "Payments" }
            guard !salaryish.isEmpty else {
                return "**No incoming credits in this statement** — I can't see a payday here."
            }
            // One "main credit" per month (the largest); its day-of-month is payday.
            let mains = Dictionary(grouping: salaryish, by: \.month)
                .compactMapValues { $0.max(by: { $0.credit < $1.credit }) }
                .sorted { $0.key < $1.key }
            let days = mains.map(\.value.day)
            let lo = days.min() ?? 0, hi = days.max() ?? 0
            let consistent = hi - lo <= 5
            let dayLabel = lo == hi ? "day \(lo)" : "days \(lo)–\(hi)"
            var out = "**You're usually paid around \(dayLabel) of the month**"
                + (consistent ? " — consistent across \(mains.count) month\(mains.count == 1 ? "" : "s")."
                              : " — it varies (spread of \(hi - lo) days over \(mains.count) months).")
            let recent = mains.suffix(6).map { "\(prettyDate($0.value.txnDate)) (\(money($0.value.credit)))" }
            out += "\nRecent paydays: " + recent.joined(separator: ", ") + "."
            return out
        }

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
            // lowest / highest the running balance ever reached, with the date
            if matches(low, #"lowest|minimum|\bdipped\b|dropped|\blow point\b|bottomed"#) {
                if let r = rows.filter({ $0.balance != nil })
                    .min(by: { $0.balance! < $1.balance! }) {
                    return "**Your lowest balance was \(money(r.balance!))** — on \(prettyDate(r.txnDate))."
                }
                return "This statement doesn't show a running balance, so I can't find the low point."
            }
            if matches(low, #"highest|maximum|\bpeak(?:ed)?\b|high point"#) {
                if let r = rows.filter({ $0.balance != nil })
                    .max(by: { $0.balance! < $1.balance! }) {
                    return "**Your highest balance was \(money(r.balance!))** — on \(prettyDate(r.txnDate))."
                }
                return "This statement doesn't show a running balance, so I can't find the peak."
            }
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
            // A1 class 3 — a credit is a refund only with EVIDENCE: money-back
            // markers printed on the row, a "Refund" category, or a prior DEBIT at
            // the same merchant (the return-without-marker pattern). Salary and
            // other income structurally can't qualify — the old logic counted
            // every non-repayment credit, so payroll showed up as a "refund".
            let markers = #"refund|reversal|\brvsl\b|charge\s?back|cash\s?back|\brebate\b|money\s?back|\breturn(?:ed|s)?\b|\brtn\b"#
            let debitMerchants = Set(sr.filter { $0.debit > 0 && !$0.merchant.isEmpty }
                .map { $0.merchant.lowercased() })
            let refunds = credits.filter { r in
                if r.category == "Refund" { return true }
                if matches(r.descr.lowercased(), markers) { return true }
                if !r.merchant.isEmpty, debitMerchants.contains(r.merchant.lowercased()),
                   !["Income", "Salary", "Interest", "Transfers"].contains(r.category) { return true }
                return false
            }
            if refunds.isEmpty {
                return "**No refunds\(scope.label) — \(money(0)).** I don't see any money-back credits on this statement."
            }
            let total = refunds.reduce(0) { $0 + $1.credit }
            let noun = refunds.count == 1 ? "refund" : "refunds"
            if matches(low, #"how much|total|worth|value|\bsum\b"#),
               !matches(low, #"how many|number of|\blist\b|show|which|what were"#) {
                return "**You received \(money(total)) in \(noun)\(scope.label)** across \(grp(refunds.count)) credit\(refunds.count == 1 ? "" : "s")."
            }
            var lines = ["**\(grp(refunds.count)) \(noun)\(scope.label), totalling \(money(total)):**"]
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
           !matches(low, #"between\s+£?\s*\d+(?:\.\d+)?\s+and\s+£?\s*\d+"#),
           // an amount threshold ("how many transactions over £5") is a filtered
           // count — defer to the dedicated threshold handler, don't answer the
           // grand total here.
           !matches(low, #"(?:over|above|more than|greater than|bigger than|exceed\w*|at least|under|below|less than|cheaper than|no more than|beneath|at most)\s*£?\s*\d"#) {
            // Direction-aware: "count of transactions I sent / received", "how
            // many debits" — the shared detector decides, so the count agrees
            // with every other direction-scoped answer. No direction → all rows.
            let dir = directionScope(low)
            let counted: [TxnRow]
            switch dir {
            case .credit: counted = sr.filter { $0.credit > 0 }
            case .debit: counted = sr.filter { $0.debit > 0 }
            case nil: counted = sr
            }
            let n = counted.count
            // per-week frequency: "how many times a week do I use X"
            if matches(low, #"times (?:a|per) week|(?:a|per) week do i"#), n > 0 {
                let weeks = max(1, Int((Double(spanDays(rows)) / 7.0).rounded(.up)))
                let freq = Double(n) / Double(weeks)
                return "**About \(String(format: "%.1f", freq)) times a week\(scope.label)** — \(grp(n)) transactions over \(weeks) week\(weeks == 1 ? "" : "s")."
            }
            let nounStem = dir == .credit ? "credit" : dir == .debit ? "debit" : "transaction"
            let noun = "\(nounStem)\(n == 1 ? "" : "s")"
            // "How much have I sent to X, and how many times?" — a two-part
            // question; the count alone silently drops the amount half.
            if matches(low, #"how much"#), n > 0 {
                let tot = dir == .credit ? income : dir == .debit ? spent : (spent > 0 ? spent : income)
                return "**\(grp(n)) \(noun)\(scope.label), totalling \(money(tot)).**"
            }
            return "**\(grp(n)) \(noun)\(scope.label).**"
        }

        // ---- top merchant(s) by TOTAL spend (A1 class 2: group-by, dimension
        // merchant) — must precede every largest-EXPENSE branch: "top merchant"
        // aggregates across visits, it is not the single biggest transaction.
        // (\b after the noun group: "biggest shop" is a merchant question, but
        // "biggest Shopping charge" is the largest-expense branch's — without the
        // boundary, `shops?` matches the prefix of "shopping".)
        if matches(low, #"(?:top|biggest|largest|highest|most)\s+(?:\d+\s+)?(?:merchants?|shops?|stores?|retailers?|vendors?|payees?|places?|brands?|compan(?:y|ies))\b|where do i spend (?:the )?most|who(?:m)? do i pay (?:the )?most|most (?:money |often )?(?:spent|spend|goes?) (?:at|to|with)"#),
           !debits.isEmpty {
            var byMerchant: [String: (total: Double, count: Int)] = [:]
            for r in debits {
                let key = r.merchant.isEmpty ? r.descr : r.merchant
                let cur = byMerchant[key] ?? (0, 0)
                byMerchant[key] = (cur.total + r.debit, cur.count + 1)
            }
            let ranked = byMerchant.sorted { $0.value.total > $1.value.total }
            let n = firstGroup(low, #"top\s+(\d+)"#).flatMap(Int.init) ?? 1
            if n <= 1, let top = ranked.first {
                return "**Your top merchant\(scope.label) is \(top.key)** — \(money(top.value.total)) across \(grp(top.value.count)) transaction\(top.value.count == 1 ? "" : "s")."
            }
            var lines = ["**Top \(min(n, ranked.count)) merchants by spend\(scope.label):**"]
            for (i, e) in ranked.prefix(n).enumerated() {
                lines.append("\(i + 1). \(e.key) — \(money(e.value.total)) (\(grp(e.value.count))×)")
            }
            return lines.joined(separator: "\n")
        }

        // ---- top N expenses (plural / "top 5") -----------------------------
        // "top 5 spending CATEGORIES" is a breakdown, not a transaction list —
        // let it fall through to the category-breakdown handler below.
        if let n = topN(low), !debits.isEmpty, !matches(low, #"categor"#) {
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

        // ---- duplicate charges ("charged twice?", "any duplicates?") --------
        // Deterministic duplicate test: same descriptor, same amount, within 3
        // days. "Suspicious" beyond exact duplicates is a judgement call the
        // model handles; this answers the checkable part honestly.
        if matches(low, #"duplicat\w*|double[- ]?charg\w*|charged twice|(?:pay(?:ing)?|paid|charg\w*) .{0,20}\btwice\b|\btwice\b .{0,24}(?:charged|paid)"#) {
            var groups: [String: [TxnRow]] = [:]
            for r in sr where r.debit > 0 {
                let key = String(r.descr.lowercased().filter { $0.isLetter || $0.isNumber })
                groups["\(key)|\(String(format: "%.2f", r.debit))", default: []].append(r)
            }
            var dupes: [(a: TxnRow, b: TxnRow)] = []
            for (_, g) in groups where g.count >= 2 {
                let ordered = g.sorted { $0.txnDate < $1.txnDate }
                for (x, y) in zip(ordered, ordered.dropFirst())
                where spanDays([x, y]) <= 4 {   // inclusive span: 3 days apart
                    dupes.append((x, y))
                }
            }
            if dupes.isEmpty {
                return "**No duplicate-looking charges found\(scope.label)** — no two debits with the "
                    + "same description and amount within 3 days of each other."
            }
            var lines = ["**\(grp(dupes.count)) possible duplicate\(dupes.count == 1 ? "" : "s")\(scope.label)** (same description & amount, ≤3 days apart):"]
            for d in dupes.sorted(by: { $0.a.txnDate < $1.a.txnDate }).prefix(10) {
                lines.append("- \(d.a.descr) — \(money(d.a.debit)) on \(prettyDate(d.a.txnDate)) and \(prettyDate(d.b.txnDate))")
            }
            lines.append("_These may be legitimate repeat purchases — worth a look, not proof._")
            return lines.joined(separator: "\n")
        }

        // ---- fixed monthly outflow ("total fixed monthly costs") ------------
        // "Fixed" = the auto-detected recurring charges (steady cadence, stable
        // amount) — the same machinery as the subscriptions answer.
        if matches(low, #"\bfixed\b"#),
           matches(low, #"outflow|out[- ]flow|costs?|expenses?|spend\w*|payments?|outgoings?"#) {
            return recurringAnswer(rows, money: money)
        }

        // ---- charitable donations (80G/tax questions) -----------------------
        // "donations" wasn't a category synonym, so these fell into the total-
        // spent catch-all and answered with the WHOLE spend figure.
        if matches(low, #"donat\w*|charit\w*|\btithe\b"#) {
            let charity = sr.filter { $0.debit > 0 && ($0.category == "Charity"
                || matches($0.descr.lowercased(), #"donat|charity|foundation|ngo|relief fund"#)) }
            guard !charity.isEmpty else {
                return "**You spent \(money(0)) on charitable donations\(scope.label)** — nothing "
                    + "matching charity or donations in this statement."
            }
            let tot = charity.reduce(0) { $0 + $1.debit }
            var lines = ["**Charitable donations\(scope.label): \(money(tot))** across \(grp(charity.count)) transaction\(charity.count == 1 ? "" : "s"):"]
            for r in charity.sorted(by: { $0.txnDate < $1.txnDate }).prefix(8) {
                lines.append("- \(prettyDate(r.txnDate)) — \(r.descr) (\(money(r.debit)))")
            }
            return lines.joined(separator: "\n")
        }

        // ---- month vs month comparison --------------------------------------
        // "this month vs last month", "food this month vs last month", "this
        // month vs same month last year". parseScope reads "this month" as a
        // single period, so the comparison re-scopes from the full row set with
        // the month phrases stripped (keeping any category/merchant scope).
        if matches(low, #"(?:this|current) month"#),
           matches(low, #"(?:last|previous|prior) month|same month (?:last|previous) year"#) {
            let stripped = low.replacingOccurrences(
                of: #"(?:this|current|last|previous|prior|same) month(?: (?:last|previous) year)?"#,
                with: " ", options: .regularExpression)
            let cmpScope = parseScope(stripped, rows: rows)
            let base = (cmpScope.hasCategory || cmpScope.hasMerchant) ? cmpScope.rows : rows
            if let latest = base.map(\.month).max() {
                let parts = latest.split(separator: "-").compactMap { Int($0) }
                let yearMode = matches(low, #"same month (?:last|previous) year"#)
                let other: String? = parts.count == 2 ? {
                    let (y, m) = (parts[0], parts[1])
                    if yearMode { return String(format: "%04d-%02d", y - 1, m) }
                    return m == 1 ? String(format: "%04d-12", y - 1)
                                  : String(format: "%04d-%02d", y, m - 1)
                }() : nil
                if let other {
                    let a = base.filter { $0.month == latest }
                    let b = base.filter { $0.month == other }
                    func label(_ key: String) -> String {
                        let p = key.split(separator: "-").compactMap { Int($0) }
                        return p.count == 2 ? "\(monthAbbr(p[1])) \(p[0])" : key
                    }
                    guard !b.isEmpty else {
                        return "**No data for \(label(other))** — this statement doesn't cover it. "
                            + "\(label(latest))\(cmpScope.label): \(money(a.reduce(0) { $0 + $1.debit })) spent."
                    }
                    let sa = a.reduce(0) { $0 + $1.debit }, sb = b.reduce(0) { $0 + $1.debit }
                    let delta = sa - sb
                    let pct = sb > 0 ? abs(delta) / sb * 100 : 0
                    let verdict = delta == 0 ? "the same"
                        : "\(money(abs(delta))) (\(String(format: "%.0f", pct))%) \(delta > 0 ? "more" : "less")"
                    return "**\(label(latest)) vs \(label(other))\(cmpScope.label): \(money(sa)) vs \(money(sb))** — you spent \(verdict) \(delta == 0 ? "in both" : "this month")."
                }
            }
        }

        // ---- monthly breakdown ("spend each month", "monthly summary") -------
        // A1 class 2: the group-by capability, dimension = month. "Each month"
        // used to fall into the target-extractor and answer "£0.00 on Each".
        if matches(low, #"(?:each|every|per|by)\s+month|month(?:ly)?\s*(?:breakdown|summary|report|totals?|spend(?:ing)?)|month[\s-]?wise|over the months|month (?:by|on) month"#),
           !matches(low, #"\baverage\b|\bavg\b|\bmean\b|\btypical\b"#),
           // "on Swiggy each month" with no Swiggy rows is an honest zero, not a
           // full breakdown; "where's my money going each month" is a category
           // question — both fall through to their own handlers below.
           scope.unmatchedTarget == nil,
           !matches(low, #"where\b.{0,26}(?:money|it).{0,10}go(?:ing)?"#) {
            let byMonth = Dictionary(grouping: sr, by: \.month).sorted { $0.key < $1.key }
            func prettyMonth(_ m: String) -> String {
                let parts = m.split(separator: "-")
                guard parts.count == 2, let no = Int(parts[1]), (1...12).contains(no) else { return m }
                return ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug",
                        "Sep", "Oct", "Nov", "Dec"][no] + " " + parts[0]
            }
            if byMonth.count == 1, let only = byMonth.first {
                let sp = only.value.reduce(0) { $0 + $1.debit }
                return "**Everything here falls in \(prettyMonth(only.key))** — \(money(sp)) spent\(scope.label). Add another month's statement for a month-by-month view."
            }
            // "how much am I SAVING each month" wants the kept amount, not just
            // the raw spent/received pair — show it whenever income is present.
            let wantsSavings = matches(low, #"\bsav(?:e|ed|es|ing|ings)\b|keep|kept|left over"#)
            var lines = ["**Month by month\(scope.label):**"]
            for (m, monthRows) in byMonth.prefix(24) {
                let sp = monthRows.reduce(0) { $0 + $1.debit }
                let inc = monthRows.filter { $0.credit > 0 && $0.category != "Payments" }
                    .reduce(0) { $0 + $1.credit }
                var line = "- \(prettyMonth(m)) — spent \(money(sp))"
                if inc > 0 {
                    line += ", received \(money(inc))"
                    if wantsSavings { line += ", kept \(money(inc - sp))" }
                }
                lines.append(line)
            }
            return lines.joined(separator: "\n")
        }

        // ---- by-category breakdown -----------------------------------------
        // ("what did I spend on <a date>" is a day-total, not a breakdown — the
        // "spend on" phrasing only means categories when no day was parsed)
        if matches(low, #"by category|category breakdown|categor\w*\s*(?:report|summary)|categories|each category|split.*categor|breakdown of|where.*money go|(?:which|what|top|biggest) category|(?:single\s+)?(?:biggest|largest|top|highest|main)\s+(?:spending\s+)?categor"#)
            || (scope.dayISO == nil && matches(low, #"what.*spend.*on\b"#)
                && !matches(low, #"\baverage\b|\bavg\b|on average|per month|per day|monthly"#)
                // An explicit amount ("what did I spend 100 pounds on") is a
                // reverse-lookup, never a breakdown. (Previously a bare number
                // became a phantom unmatchedTarget, which suppressed this branch
                // by accident; the A1 target gates removed that accident.)
                && !matches(low, #"£\s?\d|\d+\.\d{1,2}\b|\d+\s*(?:pounds|quid|pence|dollars|bucks|euros|rupees)\b"#)
                && scope.unmatchedTarget == nil && !scope.hasCategory && !scope.hasMerchant),
           !debits.isEmpty {
            return categoryBreakdown(debits, total: spent, scopeLabel: scope.label,
                                     limit: topN(low) ?? 8, money: money)
        }

        // ---- itemised credit / debit list -----------------------------------
        // "list my credits", "show me my deposits", "show my debits" — an
        // explicit money-direction NOUN plus a list word means enumerate those
        // rows, not sum them. Must precede the income handler, whose
        // `\bcredits?\b` would otherwise swallow every list phrasing as a
        // one-line total. Direct debits / standing orders are recurring-payment
        // vocabulary, not a request for the debit rows.
        if let dir = directionScope(low),
           matches(low, dir == .credit ? creditNounPattern : debitNounPattern),
           matches(low, #"\blist\b|show (?:me|all|my|the)|itemi[sz]e|let me see|what (?:are|were)\b|which (?:are|were)\b"#),
           !matches(low, #"how much|how many|\btotal\b|number of|\bcount\b|average|\bavg\b|\bmedian\b|biggest|largest|highest|smallest|\bsum\b|percent"#),
           !matches(low, #"direct debits?|standing orders?|subscriptions?|recurring"#) {
            let listRows = (dir == .credit ? sr.filter { $0.credit > 0 }
                                           : sr.filter { $0.debit > 0 })
                .sorted { ($0.txnDate, $0.seq) < ($1.txnDate, $1.seq) }
            let noun = dir == .credit ? "credit" : "debit"
            guard !listRows.isEmpty else {
                return "**No \(noun)s\(scope.label)** — nothing found in this statement."
            }
            let tot = listRows.reduce(0) { $0 + (dir == .credit ? $1.credit : $1.debit) }
            var lines = ["**\(grp(listRows.count)) \(noun)\(listRows.count == 1 ? "" : "s")\(scope.label), totalling \(money(tot)):**"]
            for r in listRows.prefix(15) {
                lines.append("- \(prettyDate(r.txnDate)) — \(r.descr) (\(money(dir == .credit ? r.credit : r.debit)))")
            }
            if listRows.count > 15 { lines.append("_…and \(grp(listRows.count - 15)) more._") }
            if dir == .credit, cardRepayments > 0 {
                lines.append("_Includes \(money(cardRepayments)) of card repayments — your own money, not income._")
            }
            return lines.joined(separator: "\n")
        }

        // ---- income / credits ----------------------------------------------
        // `\bcredits?\b` deliberately excludes the compound-noun senses of "credit"
        // that aren't money-in: "credit card" (the physical card), "credit
        // limit/line/score/rating", and "available credit" (a card's headroom).
        // "pre-salary week vs post-salary week" and friends are comparisons this
        // handler can't answer — the bare word "salary" must not collapse them
        // into an income total (they defer to the model further down).
        if matches(low, #"\bincome\b|earn|receiv(?:e|ed|ing)|credited|\bsalary\b|deposits?\b|money (?:in|received)|came in|come in|coming in|money came|(?<!available\s)\bcredits?\b(?!\s+(?:cards?|limits?|lines?|scores?|ratings?)\b)|paid in"#),
           !matches(low, #"\bvs\.?\b|\bversus\b|\bcompare\b|compared? (?:to|with|against)"#) {
            let noun = credits.count == 1 ? "credit" : "credits"
            var out = "**You received \(money(income))\(scope.label)** across \(grp(credits.count)) \(noun)."
            if cardRepayments > 0 {
                out += " (Card repayments of \(money(cardRepayments)) aren't counted — that's your own money.)"
            }
            return out
        }

        // ---- income vs expenses ratio ---------------------------------------
        // Account-wide by definition — the word "income" would otherwise scope
        // the rows to the Income CATEGORY and report "£0.00 out".
        if matches(low, #"\bratio\b"#),
           matches(low, #"income|earn|expense|spend|outgoing|in.{0,4}out"#) {
            let allSpent = rows.filter { $0.debit > 0 }.reduce(0) { $0 + $1.debit }
            let allIncome = rows.filter { $0.credit > 0 && $0.category != "Payments" }
                .reduce(0) { $0 + $1.credit }
            guard allIncome > 0 || allSpent > 0 else { return nil }
            var out = "**Income vs expenses: \(money(allIncome)) in vs \(money(allSpent)) out**"
            if allSpent > 0, allIncome > 0 {
                out += " — a ratio of \(String(format: "%.2f", allIncome / allSpent)) : 1"
                out += " (you spend \(String(format: "%.0f", allSpent / allIncome * 100))% of what you earn)."
            } else {
                out += "."
            }
            return out
        }

        // ---- spending trend (up or down) ------------------------------------
        // Must precede the net handler, whose "up or down" pattern used to
        // swallow "is my spending trending up or down?" and answer with NET.
        if matches(low, #"\btrend(?:ing|s)?\b|going (?:up|down)|(?:spend\w*|expense\w*) (?:increas|decreas)\w*|(?:increas|decreas)\w*.{0,12}(?:spend|spending)"#),
           matches(low, #"spend|spending|expense|outgoing|costs?"#) {
            var series = Dictionary(grouping: sr.filter { $0.debit > 0 }, by: \.month)
                .mapValues { $0.reduce(0) { $0 + $1.debit } }
                .sorted { $0.key < $1.key }
            if let n = firstGroup(low, #"last\s+(\d{1,2})\s+months"#).flatMap(Int.init), series.count > n {
                series = Array(series.suffix(n))
            }
            guard series.count >= 2 else {
                return "**Only one month of data here** — I need at least two months to read a trend."
            }
            let half = series.count / 2
            let early = series.prefix(series.count - half).map(\.value)
            let late = series.suffix(half).map(\.value)
            let earlyAvg = early.reduce(0, +) / Double(early.count)
            let lateAvg = late.reduce(0, +) / Double(late.count)
            let pct = earlyAvg > 0 ? abs(lateAvg - earlyAvg) / earlyAvg * 100 : 0
            let dir = lateAvg > earlyAvg * 1.05 ? "trending up"
                    : lateAvg < earlyAvg * 0.95 ? "trending down" : "roughly flat"
            let span = "\(series.count) months"
            return "**Your spending is \(dir)\(scope.label)** over the last \(span) — "
                + "averaging \(money(earlyAvg))/month earlier vs \(money(lateAvg))/month recently"
                + (dir == "roughly flat" ? "." : " (\(String(format: "%.0f", pct))% \(lateAvg > earlyAvg ? "higher" : "lower")).")
        }

        // ---- net / profit / loss / savings ----------------------------------
        // Only the VERB "save/saved/saving" signals a net calculation. The bare
        // NOUN "savings" is almost always an account or payee ("transfer to
        // Savings", "average charge at Savings") — a spend/transfer lookup, not a
        // net question — so it must not trigger this handler.
        if matches(low, #"\bnet\b|how much did i save|left over|left-over|surplus|net income|\bprofit\b|\bloss\b|\bp\s*&\s*l\b|profit and loss|made or lost|up or down|ahead or behind|in the black"#)
            || (matches(low, #"\bsav(?:e|ed|es|ing)\b"#)
                && !matches(low, #"rate|target|goal|should|advice|advise|\bhelp\b|recommend|how (?:can|do)"#)) {
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

        // ---- day-of-week spend ("which day of the week do I spend most?") ---
        // Distinct from "biggest spending day" (a calendar date): this aggregates
        // across ALL Mondays, ALL Tuesdays, … and names the weekday.
        if matches(low, #"day of the week|(?:which|what) weekday|weekday do i spend"#), !debits.isEmpty {
            var byDow: [Int: (amt: Double, n: Int)] = [:]
            for r in debits {
                let w = weekdayIndex(r.txnDate)
                var e = byDow[w] ?? (0, 0); e.amt += r.debit; e.n += 1; byDow[w] = e
            }
            let wantLeast = matches(low, #"least|lowest|smallest|quietest"#)
            guard let pick = wantLeast ? byDow.min(by: { $0.value.amt < $1.value.amt })
                                       : byDow.max(by: { $0.value.amt < $1.value.amt }) else { return nil }
            let ranked = byDow.sorted { $0.value.amt > $1.value.amt }
                .map { "\(weekdayNames[$0.key]) \(money($0.value.amt))" }
            return "**You spend the \(wantLeast ? "least" : "most") on \(weekdayNames[pick.key])s\(scope.label)** — "
                + "\(money(pick.value.amt)) across \(grp(pick.value.n)) transaction\(pick.value.n == 1 ? "" : "s").\n"
                + "Full week: " + ranked.joined(separator: " · ") + "."
        }

        // ---- first vs second half of the month -------------------------------
        // Days 1–15 vs 16–end aggregated across every month on record. Uses the
        // FULL row set: parseScope reads "first half" as a date range over the
        // statement, which is a different (wrong) question here.
        if matches(low, #"first half"#), matches(low, #"second half|2nd half|latter half"#),
           matches(low, #"month"#) {
            let all = rows.filter { $0.debit > 0 }
            let h1 = all.filter { $0.day <= 15 }
            let h2 = all.filter { $0.day >= 16 }
            let s1 = h1.reduce(0) { $0 + $1.debit }, s2 = h2.reduce(0) { $0 + $1.debit }
            let months = Set(all.map(\.month)).count
            let winner = s1 >= s2 ? "first half (days 1–15)" : "second half (days 16–end)"
            return "**You spend more in the \(winner) of the month** — "
                + "\(money(s1)) (\(grp(h1.count)) txns) vs \(money(s2)) (\(grp(h2.count)) txns), across \(months) month\(months == 1 ? "" : "s")."
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
        // A "how many / number of" threshold phrasing wants just the count, not a list.
        let thresholdWantsCount = matches(low, #"\bhow many\b|\bnumber of\b|\bcount\b"#)

        // ---- threshold ("transactions over £50", "above 5,000", "over 5k") ----
        // A1 class 4: one amount-literal reader — separators and spoken
        // multipliers included. The old `\d+` stopped at a comma, so "over
        // 5,000" parsed as threshold 5 and listed nearly every transaction.
        if let g = firstTwoGroups(low, #"(?:over|above|more than|greater than|bigger than|exceed\w*|at least)\s*£?\s*(\d[\d,]*(?:\.\d+)?)\s*(k|thousand|lakhs?|lacs?|crores?|m|million)?\b"#),
           let thr = amountLiteral(g.0, suffix: g.1), !debits.isEmpty {
            let hits = debits.filter { $0.debit > thr }.sorted { $0.debit > $1.debit }
            if hits.isEmpty {
                return "**No transactions over \(money(thr))\(scope.label).** Your largest was \(money(debits.map(\.debit).max() ?? 0))."
            }
            if thresholdWantsSum {
                let sum = hits.reduce(0) { $0 + $1.debit }
                return "**You spent \(money(sum)) across \(grp(hits.count)) transaction\(hits.count == 1 ? "" : "s") over \(money(thr))\(scope.label).**"
            }
            if thresholdWantsCount {
                return "**\(grp(hits.count)) transaction\(hits.count == 1 ? "" : "s") over \(money(thr))\(scope.label).**"
            }
            var lines = ["**\(grp(hits.count)) transaction\(hits.count == 1 ? "" : "s") over \(money(thr))\(scope.label):**"]
            for h in hits.prefix(10) { lines.append("- \(money(h.debit)) — \(h.descr) (\(h.txnDate))") }
            return lines.joined(separator: "\n")
        }

        // ---- threshold BELOW ("transactions under £5", "less than a tenner") ----
        if let pair = firstTwoGroups(low, #"(?:under|below|less than|cheaper than|no more than|at most|beneath)\s*£?\s*(\d[\d,]*(?:\.\d+)?)\s*(k|thousand|lakhs?|lacs?|crores?|m|million)?\b"#)
                ?? (matches(low, #"\ba fiver\b"#) ? ("5", String?.none) : nil)
                ?? (matches(low, #"\ba tenner\b"#) ? ("10", String?.none) : nil),
           let thr = amountLiteral(pair.0, suffix: pair.1), !debits.isEmpty {
            let hits = debits.filter { $0.debit < thr }.sorted { $0.debit < $1.debit }
            if hits.isEmpty {
                return "**No transactions under \(money(thr))\(scope.label).** Your smallest was \(money(debits.map(\.debit).min() ?? 0))."
            }
            if thresholdWantsSum {
                let sum = hits.reduce(0) { $0 + $1.debit }
                return "**You spent \(money(sum)) across \(grp(hits.count)) transaction\(hits.count == 1 ? "" : "s") under \(money(thr))\(scope.label).**"
            }
            if thresholdWantsCount {
                return "**\(grp(hits.count)) transaction\(hits.count == 1 ? "" : "s") under \(money(thr))\(scope.label).**"
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
           // "for 2025" / "in 2024" is a YEAR scope, not a ₹2,025 amount lookup.
           !matches(low, #"(?:in|for|of|during|year)\s+(?:19|20)\d\d\b|year to date|\bytd\b|\bq[1-4]\b"#),
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
        // "July 2025 than June 2025", "July 2025 vs July 2024") ---------------
        // Year-aware: each named month keeps the year written right after it, so
        // a multi-year statement never sums July 2024 + July 2025 into one side,
        // and the SAME month in two different years is a valid comparison.
        if matches(low, #"\bcompare\b|\bvs\.?\b|versus|more in|less in|higher in|which month|\bthan\b|difference between"#) {
            var pairs: [(mo: Int, yr: Int?)] = []
            if let re = try? NSRegularExpression(pattern: #"\b([a-z]{3,9})\.?(?:\s+((?:19|20)\d\d))?\b"#) {
                for m in re.matches(in: low, range: NSRange(low.startIndex..., in: low)) {
                    guard let r1 = Range(m.range(at: 1), in: low),
                          let mo = monthNames.first(where: { $0.0 == String(low[r1]) })?.1 else { continue }
                    var yr: Int?
                    if m.range(at: 2).location != NSNotFound, let r2 = Range(m.range(at: 2), in: low) {
                        yr = Int(low[r2])
                    }
                    if !pairs.contains(where: { $0.mo == mo && $0.yr == yr }) { pairs.append((mo, yr)) }
                }
            }
            if pairs.count >= 2 {
                func label(_ p: (mo: Int, yr: Int?)) -> String {
                    monthAbbr(p.mo) + (p.yr.map { " \($0)" } ?? "")
                }
                var parts: [String] = []
                var totals: [((mo: Int, yr: Int?), Double)] = []
                for p in pairs {
                    let t = rows.filter { $0.monthNo == p.mo && (p.yr == nil || $0.year == p.yr!)
                                          && $0.debit > 0 }
                        .reduce(0) { $0 + $1.debit }
                    totals.append((p, t))
                    parts.append("\(label(p)) \(money(t))")
                }
                let hi = totals.max(by: { $0.1 < $1.1 })!
                var out = "**You spent more in \(label(hi.0)) (\(money(hi.1))).** " + parts.joined(separator: " vs ") + "."
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
                .filter { $0.count >= 3 && !isStopword($0) && !monthWords.contains($0) }
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

            // Category combine FIRST: scan the FULL question for category names /
            // synonyms — independent of the merchant-stopword-filtered `toks`, so
            // category words that are also merchant-stopwords ("subscriptions",
            // "income") are still detected. This must precede the merchant-token
            // path so "Food & Dining and Rent" isn't mis-read as merchants (the
            // token "food" would otherwise word-match "CO-OP FOOD" descriptions).
            // Ordered by first appearance for a natural "A + B" / "A vs B" render.
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

            // Merchant-token path: each content token that word-names ≥1 row's
            // description becomes a side (handles multi-word merchants like
            // "craft beer" named partially).
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
           matches(low, #"\blist\b|show me|show all|show my|let me see|itemi[sz]e|what (?:are|were) (?:my|the)\b|what (?:did|have) i (?:buy|bought|purchase|get)\b|all (?:my|the) .{0,20}(?:transactions|purchases|payments|charges)|(?:transactions?|purchases?|charges?|payments?)\s+(?:in|on|for|at|from)\b"#),
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

        // ---- peer benchmarking → honest limitation ---------------------------
        // "Is my spending normal for someone my age?" — there is no peer data
        // here; saying so beats both a made-up comparison and a raw total.
        if matches(low, #"normal for|people my age|someone my age|average person|typical person|people like me|others spend|compared? (?:to|with) (?:other|most) people"#) {
            return "**I can't compare you with other people — I only see your own statements.** "
                + "Ask me for your own totals, averages or trends instead."
        }

        // Advisory / opinion / open-ended that no deterministic handler caught →
        // let the LLM handle it (before the broad total-spent catch-all below).
        if isAdvisory(low) { return nil }

        // ---- unhandled comparison → defer -----------------------------------
        // A question shaped "X vs Y" ("festival months vs regular months",
        // "pre-salary week vs post-salary week") that none of the comparison
        // handlers above recognized must never collapse into a single total or
        // a phantom zero — hand it to the model, which sees the digest.
        if matches(low, #"\bvs\.?\b|\bversus\b|compared? (?:to|with|against)"#) { return nil }

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
        var periodText: String?  // the period as a re-parseable phrase ("in June") — B4 scope carry
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
            let ml = merch.lowercased()
            // Prefer an exact merchant-FIELD match: "Tesco" must not swallow "Tesco
            // Express", nor "Amazon" pull in "Amazon Prime". Only when no row carries
            // that merchant name do we fall back to the raw description — and then
            // with WORD BOUNDARIES, so "TfL" can't match "neTFLix" or "EE" match
            // "coffEE" via a bare substring.
            let exact = s.rows.filter { $0.merchant.lowercased() == ml }
            if !exact.isEmpty {
                s.rows = exact
            } else {
                let pat = #"\b"# + NSRegularExpression.escapedPattern(for: ml)
                    .replacingOccurrences(of: #"\ "#, with: #"\s+"#)
                s.rows = s.rows.filter { $0.descr.lowercased().range(of: pat, options: .regularExpression) != nil }
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
            let text = range.label.trimmingCharacters(in: .whitespaces)
            labelParts.append(text)
            s.periodText = text
        } else if let day = matchDay(low, rows: s.rows) {
            s.rows = day.rows
            s.hasPeriod = true
            s.dayISO = day.iso
            s.dayLabel = day.dayLabel
            labelParts.append("on \(day.dayLabel)")
            s.periodText = "on \(day.dayLabel)"
        } else if let (rowsInPeriod, plabel) = matchPeriod(low, rows: s.rows) {
            s.rows = rowsInPeriod
            s.hasPeriod = true
            labelParts.append(plabel)
            s.periodText = plabel
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
        // A word right after "at/to/from" is a spend TARGET whatever the POS
        // tagger thinks — NLTagger reads "starbucks" as an adverb and "walmart"
        // as a verb, which silently dropped them and turned "how much at
        // Starbucks?" into the whole-account total.
        var prepTargets: Set<String> = []
        if let re = try? NSRegularExpression(pattern: #"\b(?:at|to|from)\s+([a-z0-9]{3,})"#) {
            for m in re.matches(in: low, range: NSRange(low.startIndex..., in: low)) {
                if let r = Range(m.range(at: 1), in: low) { prepTargets.insert(String(low[r])) }
            }
        }
        let toks = low.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter {
                $0.count >= 3 && !$0.allSatisfy(\.isNumber)
                    && !isStopword($0) && !months.contains($0)
                    && (prepTargets.contains($0) || !isGrammarWord($0))
            }
        // A genuine "spend at <X>" names a merchant/category in 1–2 tokens. Three or
        // more leftover content words means the question wasn't a clean spend lookup
        // (e.g. "how much were the new debits this period", "verify the ISK
        // conversion") — defer to the model rather than inventing a £0 "merchant".
        guard !toks.isEmpty, toks.count <= 2 else { return nil }
        return merchantDisplay(toks.joined(separator: " "))
    }

    /// A1 class 4 — the one amount-literal reader every threshold/range branch
    /// uses: thousands separators ("5,000", "1,00,000") and spoken multipliers
    /// ("5k", "1.2 lakh", "2 crore", "1m"). Currency symbol optional.
    static func amountLiteral(_ number: String, suffix: String?) -> Double? {
        guard var value = Double(number.replacingOccurrences(of: ",", with: "")) else { return nil }
        switch (suffix ?? "").lowercased() {
        case "k", "thousand": value *= 1_000
        case "lakh", "lakhs", "lac", "lacs": value *= 100_000
        case "m", "million": value *= 1_000_000
        case "crore", "crores": value *= 10_000_000
        default: break
        }
        return value
    }

    /// A1 class 1a — stopword lookup with plural folding, so "accounts" is
    /// caught by "account" and no list has to enumerate both forms.
    static func isStopword(_ token: String) -> Bool {
        if merchantStopwords.contains(token) { return true }
        if token.count > 3, token.hasSuffix("s"), !token.hasSuffix("ss"),
           merchantStopwords.contains(String(token.dropLast())) { return true }
        return false
    }

    /// A1 class 1b — part-of-speech gate: determiners ("each", "every"),
    /// pronouns ("everything"), prepositions, conjunctions, adverbs, particles
    /// and bare numbers are CLOSED word classes — grammar can enumerate what a
    /// merchant name can never be, where no stopword list can enumerate every
    /// merchant. A word these tags catch must never become a phantom "£0.00 on
    /// Each" target.
    static func isGrammarWord(_ token: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = token
        let (tag, _) = tagger.tag(at: token.startIndex, unit: .word, scheme: .lexicalClass)
        switch tag {
        case .some(.determiner), .some(.pronoun), .some(.preposition),
             .some(.conjunction), .some(.adverb), .some(.particle),
             .some(.interjection), .some(.number), .some(.verb):
            // .verb included: "were"/"getting"-type auxiliaries survive stopword
            // lists but are never merchant names ("how much WERE the new debits").
            return true
        default:
            return false
        }
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
        // Merchant names the question actually mentions — so a category synonym
        // that is only a fragment of a named merchant ("gym" inside "Pure Gym",
        // "apple" inside a merchant) doesn't hijack a merchant question into a
        // category. A merchant is "named" if its full name appears in the question.
        let namedMerchants = Set(rows.map { $0.merchant.lowercased() })
            .filter { !$0.isEmpty && low.contains($0) }
        // synonym → canonical, if that canonical is present
        for (word, canonical) in categorySynonyms where low.contains(word) {
            // "shop / shopping AT <merchant>" is a verb + object ("did I shop at
            // Netflix?"), NOT a request for the Shopping category — let it fall
            // through to merchant / absent-target handling.
            if (word == "shop" || word == "shopping"),
               matches(low, #"shop(?:ping)?\s+(?:at|from|in)\b|(?:how many|number of|different|distinct|separate|several|unique)\s+shops?\b"#) { continue }
            // Skip when the synonym is only present as part of a merchant the
            // question names (e.g. "gym" in "how much at Pure Gym").
            if namedMerchants.contains(where: { $0.contains(word) }) { continue }
            if let hit = present.first(where: { $0.caseInsensitiveCompare(canonical) == .orderedSame }) {
                return hit
            }
        }
        // partial: a distinctive query word matches a WORD of exactly one present
        // category name. This resolves an AI-coined multi-word category that the
        // exact-name and synonym passes miss — "dental" → "Dental Care", "streaming"
        // → "Streaming Services", "transit" → "Public Transit". Guarded so it can't
        // over-reach: the word must be ≥4 letters and not a generic connector, it
        // must identify ONE category (never guess when several share it), and it
        // must not be a word the user used to name a merchant.
        let generic: Set<String> = ["care", "services", "service", "other", "general",
            "misc", "miscellaneous", "expenses", "expense", "payment", "payments",
            "charge", "charges", "bills", "bill", "spending", "spend", "shop",
            "shopping", "store", "stuff", "things", "cost", "costs"]
        let qWords = Set(low.split { !$0.isLetter }.map(String.init))
            .filter { $0.count >= 4 && !generic.contains($0) }
        if !qWords.isEmpty {
            let hits = present.filter { cat in
                let catWords = Set(cat.lowercased().split { !$0.isLetter }.map(String.init))
                    .subtracting(generic)
                let shared = qWords.intersection(catWords)
                guard !shared.isEmpty else { return false }
                // don't fire when a shared word is only there because the user named
                // a merchant ("how much at Care Dental Platinum" is a merchant ask).
                return !namedMerchants.contains { m in shared.contains(where: m.contains) }
            }
            if hits.count == 1 { return hits.first }
        }
        return nil
    }

    private static func matchMerchant(_ low: String, rows: [TxnRow],
                                      allowDescription: Bool) -> String? {
        // 1) merchant-field candidates (populated by most parsers) — longest wins.
        // Match on WORD BOUNDARIES (not bare substring) so short names like "EE"
        // are found without also matching "coffEE"/"betwEEn", and a two-letter
        // real merchant isn't dropped by an over-eager length floor.
        let merchants = Set(rows.map(\.merchant).filter { $0.count >= 2 })
        if let hit = merchants.filter({ m in
            let pat = #"\b"# + NSRegularExpression.escapedPattern(for: m.lowercased())
                .replacingOccurrences(of: " ", with: #"\s+"#) + #"\b"#
            return low.range(of: pat, options: .regularExpression) != nil
        }).max(by: { $0.count < $1.count }) {
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
            // A bare number is never a merchant — most importantly a 4-digit YEAR
            // ("spend in September 2024"), which would otherwise match any description
            // carrying that number and wrongly scope the rows to a phantom merchant.
            .filter { $0.count >= 3 && !merchantStopwords.contains($0) && !months.contains($0)
                      && !$0.allSatisfy(\.isNumber) }
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
        "account", "balance", "statement", "card", "credit", "credits", "debit",
        "debits", "withdrawal", "withdrawals", "deposited", "what", "whats",
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
        "quarter", "half", "across", "whole", "entire", "throughout", "altogether",
        "sum", "out", "outgoing", "outgoings", "overall", "went", "came", "total",
        // quantity vocabulary — "my most AMOUNT", "highest VALUE" — never merchants
        "amount", "amounts", "value", "values", "figure", "figures",
        "owe", "owed", "owing", "outstanding", "due",
        "altogether", "overall", "everything", "anything", "something", "stuff", "things",
        "new", "old", "this", "these", "those", "here",
        "which", "who", "where", "when", "why", "whose", "than", "versus", "compare",
        "against", "most", "least", "fewest", "fewer", "portion", "fraction", "share",
        "pounds", "quid", "pence", "dollars", "euros", "rupees",
        // belt-and-braces alongside the POS gate (isGrammarWord) — quantifiers
        // and router-vocabulary nouns that must never become a phantom target
        "each", "every", "both", "either", "neither", "none", "several", "various",
        "multiple", "single", "merchant", "merchants", "wise",
        // time-span vocabulary ("this period", "the whole term") — router words,
        // never merchants
        "period", "window", "term", "range", "fortnight", "duration", "span",
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
        // whole-category total. Exception: bare "may" is ambiguous with the modal
        // verb, so for an EMPTY month only honour it when there's clear month
        // context ("in May", "during May", "May 2026") — otherwise require data.
        for (name, no) in monthNames where matches(low, #"\b"# + name + #"\b"#) {
            var inMonth = rows.filter { $0.monthNo == no }
            // Honor an explicit year ("September 2024") so a statement spanning two
            // years scopes to the right one; ignored when that year has no such month.
            var yearLabel = ""
            if let r = low.range(of: #"\b20\d\d\b"#, options: .regularExpression),
               let y = Int(low[r]) {
                let byYear = inMonth.filter { $0.year == y }
                if !byYear.isEmpty { inMonth = byYear; yearLabel = " \(y)" }
            }
            let mayIsMonth = name != "may"
                || matches(low, #"\b(?:in|during|for|of|through|this|last|next)\s+may\b|\bmay\s+(?:20\d\d|month)\b"#)
            if !inMonth.isEmpty || mayIsMonth {
                return (inMonth, "in " + name.prefix(1).uppercased() + name.dropFirst() + yearLabel)
            }
        }
        // quarter: "Q2 2025", "second quarter of 2025" — three calendar months,
        // year-filtered when named. An empty result still scopes (honest zero).
        let quarterWords = ["first": 1, "1st": 1, "second": 2, "2nd": 2,
                            "third": 3, "3rd": 3, "fourth": 4, "4th": 4]
        var quarter: Int?
        if let qs = firstGroup(low, #"\bq([1-4])\b"#) { quarter = Int(qs) }
        else if let w = firstGroup(low, #"\b(first|1st|second|2nd|third|3rd|fourth|4th)\s+quarter\b"#) {
            quarter = quarterWords[w]
        }
        if let q = quarter {
            let monthsInQ = ((q - 1) * 3 + 1)...(q * 3)
            var inQ = rows.filter { monthsInQ.contains($0.monthNo) }
            var label = "in Q\(q)"
            if let ys = firstGroup(low, #"\b((?:19|20)\d\d)\b"#), let y = Int(ys) {
                inQ = inQ.filter { $0.year == y }
                label += " \(y)"
            }
            return (inQ, label)
        }
        // year-to-date / "this year": the latest year on record.
        if matches(low, #"year to date|\bytd\b|this year|so far (?:this|in the) year"#),
           let maxYear = rows.map(\.year).max() {
            return (rows.filter { $0.year == maxYear }, "in \(maxYear) so far")
        }
        // bare year ("in 2019", "for 2025", "2025 so far") — no month name made it
        // here, so the year IS the period. An absent year scopes to zero rows and
        // downstream handlers answer an honest "₹0.00 in 2019" instead of the
        // whole-history total.
        if let ys = firstGroup(low, #"\b(?:in|for|of|during|year)\s+((?:19|20)\d\d)\b"#)
                    ?? firstGroup(low, #"\b((?:19|20)\d\d)\s+so far\b"#),
           let y = Int(ys) {
            return (rows.filter { $0.year == y }, "in \(y)")
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

        // ---- "do I have a [merchant] subscription?" -------------------------
        // A yes/no about ONE named service — NOT a request to enumerate every
        // recurring charge. Answer specifically about that merchant; only the
        // merchant-less "what are my subscriptions?" gets the full cadence list.
        if matches(low, #"\bdo i (?:have|pay|use)\b|\bam i (?:paying|subscribed|still on|on)\b|\bhave i got\b|\bdo i still\b|\bis there a\b"#),
           matches(low, #"subscription|subscribed|recurr|paying for|\bmember\w*\b|\bplan\b"#) {
            // Resolve the named service: a real merchant in the data, else the
            // word the user typed before "subscription/plan/membership" — so an
            // ABSENT service ("do I have Spotify?") gets an honest "no", not the
            // generic recurring list.
            let named = matchMerchant(low, rows: allRows, allowDescription: true)
                ?? firstGroup(low, #"\b(?:a|an|any|my|the)\s+([a-z][a-z0-9&'. -]{1,28}?)\s+(?:subscriptions?|plans?|memberships?|member)\b"#)?
                    .trimmingCharacters(in: .whitespaces)
            if let merch = named, !merch.isEmpty,
               !["recurring", "monthly", "regular", "active"].contains(merch.lowercased()) {
                let needle = merch.lowercased()
                let hits = allRows.filter {
                    $0.debit > 0 &&
                    ($0.merchant.caseInsensitiveCompare(merch) == .orderedSame
                     || $0.merchant.lowercased().contains(needle)
                     || $0.descr.lowercased().contains(needle))
                }
                guard !hits.isEmpty else {
                    return "**No — I don't see any \(merch) charges in your statements.**"
                }
                let total = hits.reduce(0) { $0 + $1.debit }
                let months = Set(hits.map(\.month)).count
                let cadence = months >= 2 ? " — looks recurring across \(months) months" : ""
                return "**Yes — \(grp(hits.count)) \(merch) payment\(hits.count == 1 ? "" : "s") totalling \(money(total))\(cadence).**"
            }
        }

        // ---- recurring charges & subscriptions ------------------------------
        // Deferred when the question is a direct "how much did I spend on
        // subscriptions" total (a category-spend lookup) OR a count like "how
        // many subscriptions" (a category-count lookup) — both are handled by
        // the scoped catch-alls below, not a request to enumerate the cadence.
        if matches(low, #"subscription|recurr|repeat\w*|regular (?:payment|charge)|standing order|direct debit"#),
           !matches(low, #"\bhow much\b|\btotal\b|\bspend(?:s|ing)?\b|\bspent\b|\baverage\b|\bhow many\b|\bnumber of\b|\bcount\b|how often|\bbiggest\b|\blargest\b|\bsmallest\b|\bcheapest\b|\bpriciest\b|most expensive|most costly|dearest|\bhighest\b|\blowest\b|\bpercent\w*\b|\bshare\b|\bwhat percentage\b|\btypical\b"#) {
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
                                          scopeLabel: String, limit: Int = 8,
                                          money: (Double) -> String) -> String {
        var totals: [String: Double] = [:]
        for t in debits { totals[t.category.isEmpty ? "Other" : t.category, default: 0] += t.debit }
        let ranked = totals.sorted { $0.value > $1.value }.prefix(limit)
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

    /// 1...7 = Sunday...Saturday (Calendar's own numbering); 0 when unparseable.
    private static let weekdayNames = ["?", "Sunday", "Monday", "Tuesday", "Wednesday",
                                       "Thursday", "Friday", "Saturday"]
    private static func weekdayIndex(_ iso: String) -> Int {
        guard let c = parseISO(iso), let d = isoCal.date(from: c) else { return 0 }
        return isoCal.component(.weekday, from: d)
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
