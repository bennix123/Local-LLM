import Foundation

/// Statement-dimension superlatives over MULTIPLE imported statements —
/// "to which account did i receive most?", "from which account did i spend
/// most on taxi?", "from which account did i make most of the pharmacy
/// transactions?". When rows carry no per-row account field (every non-Paytm
/// import), the statement IS the account, so these questions rank statements.
///
/// One shared brain: the Mac account-dimension gate and iOS send() both call
/// this, so the platforms answer identically. Honest rule baked in: totals in
/// different currencies are NEVER ranked against each other — ranking happens
/// by amount only when every candidate statement shares one currency,
/// otherwise by transaction count with each total stated in its own currency.
public enum StatementsQuery {

    public struct Statement {
        public let name: String
        public let rows: [TxnRow]
        public let currency: String
        public init(name: String, rows: [TxnRow], currency: String) {
            self.name = name; self.rows = rows; self.currency = currency
        }
    }

    public static func superlative(_ question: String,
                                   statements: [Statement]) -> String? {
        guard statements.count > 1 else { return nil }
        let low = FinanceRouter.normalizeQuestion(question)
        func has(_ p: String) -> Bool {
            low.range(of: p, options: .regularExpression) != nil
        }
        // The question must be ABOUT the account/statement dimension…
        guard has(#"(?:which|what)\s+(?:bank\s+)?(?:accounts?|statements?|banks?)\b|\b(?:accounts?|statements?|banks?)\s+did\s+i\b"#)
        else { return nil }
        // …and be a superlative, not a roster/count/list request.
        guard has(#"\bmost\b|\bleast\b|highest|lowest|\bmore\b|\bless\b|maximum|minimum|\bmax\b|\bmin\b|biggest|smallest"#)
        else { return nil }
        // Balance / single-transaction / when questions belong elsewhere.
        guard !has(#"balance|closing|\bwhen\b|\bthis\b|\bthat\b|largest (?:transaction|credit|debit|expense|payment)"#)
        else { return nil }

        let wantsLeast = has(#"\bleast\b|lowest|\bless\b|minimum|\bmin\b|smallest"#)
        let wantsCredit = has(#"receiv|\bincome\b|\bcame\b|\bcome\b|\binto\b|\bgot\b|\bget\b|deposit|credited|paid in|money in"#)
        let wantsDebit = has(#"spen[dt]|\bpa(?:y|id)\b|debit|money out|outflow|\bmade?\b|\bmake\b"#)
        // "most of the … transactions" ranks by COUNT; money phrasings by sum.
        let countMode = has(#"\btransactions?\b|\bpayments?\b|\btimes\b|\boften\b"#)

        // Resolve the entity (category/merchant) ONCE over the union, then
        // scope each statement to it — a statement without the entity counts
        // zero, it doesn't fall back to its whole ledger.
        let union = statements.flatMap(\.rows)
        let uscope = FinanceRouter.entityScope(low, rows: union)
        if uscope.entity == nil, uscope.unmatchedTarget != nil { return nil }  // router's honest zero handles it

        struct Entry { let name: String; let currency: String; let total: Double; let n: Int }
        var entries: [Entry] = []
        for s in statements {
            var rows = s.rows
            if let entity = uscope.entity {
                let sscope = FinanceRouter.entityScope(low, rows: s.rows)
                rows = sscope.entity == entity ? sscope.rows : []
            }
            // Direction: explicit words filter; an undirected COUNT question
            // ("which account has the most transactions?") counts everything.
            if wantsCredit { rows = rows.filter { $0.credit > 0 } }
            else if wantsDebit || !countMode { rows = rows.filter { $0.debit > 0 } }
            guard !rows.isEmpty else { continue }
            let total = rows.reduce(0) { $0 + (wantsCredit ? $1.credit : $1.debit) }
            entries.append(Entry(name: s.name, currency: s.currency, total: total, n: rows.count))
        }
        guard !entries.isEmpty else { return nil }

        let entityTag = uscope.entity.map { uscope.isCategory ? " on \($0)" : " at \($0)" } ?? ""
        let noun = wantsCredit ? "credit" : "payment"
        func money(_ e: Entry) -> String { FinanceRouter.defaultMoney(e.currency)(e.total) }
        func line(_ e: Entry) -> String { "\(e.name) \(money(e)) across \(e.n) \(noun)\(e.n == 1 ? "" : "s")" }

        if entries.count == 1, let only = entries.first {
            let verb = wantsCredit ? "came into" : "went out of"
            return "**Everything\(entityTag) \(verb) \(only.name)** — \(money(only)) across \(only.n) \(noun)\(only.n == 1 ? "" : "s")."
        }

        if countMode {
            let ranked = entries.sorted { $0.n > $1.n }
            let pick = wantsLeast ? ranked.last! : ranked.first!
            let total = ranked.reduce(0) { $0 + $1.n }
            let rest = ranked.filter { $0.name != pick.name }
                .map { "\($0.name): \($0.n)" }.joined(separator: " · ")
            let what = uscope.entity.map { "your \($0)" } ?? (wantsCredit ? "your incoming" : "your")
            return "**\(wantsLeast ? "Fewest" : "Most") of \(what) transactions were from \(pick.name) — \(pick.n) of \(total).** \(rest)"
        }

        let currencies = Set(entries.map(\.currency))
        if currencies.count == 1 {
            let ranked = entries.sorted { $0.total > $1.total }
            let pick = wantsLeast ? ranked.last! : ranked.first!
            let runner = wantsLeast ? ranked.dropLast().last : ranked.dropFirst().first
            let verb = wantsCredit ? (wantsLeast ? "The least of your money came into" : "Most of your money came into")
                                   : (wantsLeast ? "The least of your money went out of" : "Most of your money went out of")
            var out = "**\(verb) \(pick.name)\(entityTag)** — \(money(pick)) across \(pick.n) \(noun)\(pick.n == 1 ? "" : "s")."
            if let r = runner { out += " \(wantsLeast ? "Next lowest" : "Runner-up"): \(r.name) at \(money(r))." }
            return out
        }

        // Mixed currencies: ₹ vs $ vs £ is not a ranking — say so, then give
        // each account's own-currency total (busiest first).
        let listed = entries.sorted { $0.n > $1.n }.map(line).joined(separator: " · ")
        let dir = wantsCredit ? "received" : "spent"
        return "**Your accounts use different currencies (\(currencies.sorted().joined(separator: ", "))), so I can't rank what you \(dir)\(entityTag) across them without exchange rates.** Per account: \(listed)."
    }
}
