// CategoryMopup — the pure graph-rewrite half of the AI category fallback
// (Engine v2, Step 3). `ClaudeCategorizer` (network) scores the long-tail
// "Other" merchant descriptors the deterministic engine couldn't place; this
// applies those scores back onto the canonical `FinancialGraph`.
//
// It is PURE and OFFLINE — no network, no I/O — so the app layer owns only the
// HTTPS call + API key, and the rewrite logic is unit-testable on its own. With
// no AI results (the common, key-less case) the graph is returned untouched, so
// the deterministic contract and the 15-fixture suite are unaffected.
import PennyModel

public enum CategoryMopup {

    /// Confidence at/above which an AI category replaces the existing label.
    /// Mirrors the spec's thresholds (≥0.90 accept · 0.70–0.89 accept+log ·
    /// <0.70 keep), accepting everything from the accept+log band up.
    public static let acceptThreshold = 0.70

    /// Which debit rows an AI pass may (re)categorize. Credits are never in
    /// scope: the mop-up targets spend categorization only, matching `ai-mopup`.
    public enum Scope: Sendable {
        /// Rows nothing has placed: "Other", or no category at all (OCR rows).
        case unresolved
        /// `unresolved` plus rows an EARLIER AI pass placed (they carry a
        /// `.category` confidence signal) — lets a fresh, possibly smarter pass
        /// revise a wrong AI verdict. Deterministic labels stay untouchable.
        case unresolvedOrAIRelabeled
        /// Every debit row the AI hasn't placed yet — including deterministic
        /// labels, which here are only placeholders. This is the API-primary
        /// steady state: idempotent, because AI-placed rows are skipped.
        case withoutAIVerdict
        /// Every debit row, AI-placed ones included — the manual full re-check.
        case allDebits
    }

    /// The distinct raw descriptors of the debit rows in `scope` — exactly the
    /// set to hand the AI categorizer. In file order, de-duplicated. Empty when
    /// nothing is in scope (so the caller can skip the AI call entirely).
    /// `includeCredits: true` widens every scope to credit rows too — used by the
    /// API-primary path, where EVERY transaction's label must come from the model.
    public static func unresolvedDescriptors(in graph: FinancialGraph,
                                             scope: Scope = .unresolved,
                                             includeCredits: Bool = false) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in graph.transactions where inScope(t, scope, includeCredits: includeCredits) {
            let d = t.rawDescription
            if !d.isEmpty, seen.insert(d).inserted { out.append(d) }
        }
        return out
    }

    /// The in-`scope` descriptors of a graph, grouped by the issuing bank and
    /// currency of the statements they appear on, each with a ready-made
    /// location sentence for the categorizer's system prompt. One group per
    /// (institution, currency) pair, in first-appearance order; descriptors are
    /// de-duplicated within their group.
    public struct DescriptorGroup: Sendable, Equatable {
        public let institution: String   // e.g. "Kotak Mahindra Bank"; may be empty
        public let currencyCode: String  // ISO-4217, e.g. "INR"
        public var descriptors: [String]

        /// The country/region implied by the account currency, when known.
        public var country: String? { CategoryMopup.currencyCountry[currencyCode] }

        /// One sentence naming the statement's bank + location, appended to the
        /// AI system prompt so region-specific merchants resolve correctly.
        public var locationContext: String {
            let bank = institution.trimmingCharacters(in: .whitespaces)
            let issuer = bank.isEmpty ? "a bank" : bank
            let place = country.map { " based in \($0)" } ?? ""
            return """
                These merchant descriptors are all from a \(issuer) statement\(place) \
                (currency \(currencyCode)). Use that location when judging each \
                merchant: prefer the local reading of region-specific names — \
                grocery and retail chains, transit systems, food-delivery apps, \
                wallets, utilities and banks of that country — over lookalikes \
                from elsewhere.
                """
        }
    }

    /// Country/region names for the currencies Penny commonly sees. Display-only
    /// hint text for the AI prompt — an unknown code just omits the country.
    static let currencyCountry: [String: String] = [
        "INR": "India", "GBP": "the United Kingdom", "USD": "the United States",
        "EUR": "the Eurozone", "AED": "the United Arab Emirates",
        "SGD": "Singapore", "AUD": "Australia", "CAD": "Canada",
        "JPY": "Japan", "CHF": "Switzerland", "NZD": "New Zealand",
    ]

    /// Like `unresolvedDescriptors`, but grouped per issuing bank so each AI
    /// request can carry the right location context. A descriptor seen under two
    /// banks lands in the first group only — one verdict per descriptor.
    public static func descriptorGroups(in graph: FinancialGraph,
                                        scope: Scope = .unresolved,
                                        includeCredits: Bool = false) -> [DescriptorGroup] {
        let accountsByID = Dictionary(graph.accounts.map { ($0.id, $0) },
                                      uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()               // global — one verdict per descriptor
        var order: [String] = []               // group keys in first-appearance order
        var groups: [String: DescriptorGroup] = [:]
        for t in graph.transactions where inScope(t, scope, includeCredits: includeCredits) {
            let d = t.rawDescription
            guard !d.isEmpty, seen.insert(d).inserted else { continue }
            let account = accountsByID[t.accountID]
            let institution = account?.institution ?? ""
            let currency = (account?.currency ?? t.currency).code
            let key = institution.lowercased() + "|" + currency
            if groups[key] == nil {
                groups[key] = DescriptorGroup(institution: institution,
                                              currencyCode: currency, descriptors: [])
                order.append(key)
            }
            groups[key]?.descriptors.append(d)
        }
        return order.compactMap { groups[$0] }
    }

    /// Rewrite every in-`scope` debit row whose descriptor scored ≥
    /// `acceptThreshold` (and to a real, non-"Other" category) with the
    /// AI-assigned category, recording a `.category` confidence signal so the UI
    /// can tell an AI-derived label from a deterministic one. Rows below
    /// threshold — or outside the scope — are untouched. Returns a new graph;
    /// when nothing clears the bar the original graph is returned unchanged.
    public static func apply(_ results: [ClaudeCategorization],
                             to graph: FinancialGraph,
                             scope: Scope = .unresolved,
                             minConfidence: Double = acceptThreshold,
                             includeCredits: Bool = false) -> FinancialGraph {
        // descriptor → (category, confidence) for accepted, non-"Other" verdicts.
        var verdicts: [String: (category: String, confidence: Double)] = [:]
        for r in results where r.confidence >= minConfidence && r.category != "Other" {
            verdicts[r.merchant] = (r.category, r.confidence)
        }
        guard !verdicts.isEmpty else { return graph }

        var categoriesByID = Dictionary(graph.categories.map { ($0.id, $0) },
                                        uniquingKeysWith: { a, _ in a })
        var changed = false
        let transactions = graph.transactions.map { t -> Transaction in
            guard inScope(t, scope, includeCredits: includeCredits),
                  let v = verdicts[t.rawDescription] else { return t }
            changed = true
            let id = CategoryID(v.category)
            categoriesByID[id] = Category(id: id, name: v.category)
            var conf = t.enrichment.confidence
            conf[.category] = v.confidence
            let enrichment = Enrichment(
                merchantID: t.enrichment.merchantID,
                cleanDescription: t.enrichment.cleanDescription,
                categoryID: id,
                tags: t.enrichment.tags,
                recurringID: t.enrichment.recurringID,
                transferPairID: t.enrichment.transferPairID,
                confidence: conf)
            return Transaction(
                id: t.id, accountID: t.accountID, statementID: t.statementID,
                date: t.date, processDate: t.processDate, rawDescription: t.rawDescription,
                amount: t.amount, balance: t.balance, currency: t.currency,
                fx: t.fx, enrichment: enrichment)
        }
        guard changed else { return graph }

        return FinancialGraph(
            accounts: graph.accounts,
            statements: graph.statements,
            transactions: transactions,
            merchants: graph.merchants,
            categories: categoriesByID.values.sorted { $0.id.raw < $1.id.raw })
    }

    /// Final guarantee for the user's "no Other" preference: re-label every debit
    /// row the AI pass still left as "Other" (or unlabeled) with a concrete
    /// category. Transfer-shaped descriptors (UPI / IMPS / NEFT / RTGS, or a
    /// "name@bank" VPA) become "Transfers"; anything else takes `fallback` — by
    /// this point the model has already placed every merchant it could recognise.
    /// App-only: the deterministic ingest never calls this, so the offline
    /// 15-fixture contract is unaffected.
    public static func assignConcreteToResidualOther(_ graph: FinancialGraph,
                                                     fallback: String = "Transfers") -> FinancialGraph {
        func concreteCategory(for descr: String) -> String {
            let s = descr.lowercased()
            if s.contains("@")
                || s.range(of: #"\b(upi|imps|neft|rtgs|ach|p2p|vpa|trf|transfer|paytm|gpay|phonepe|bhim)\b"#,
                           options: .regularExpression) != nil {
                return "Transfers"
            }
            return fallback
        }
        var categoriesByID = Dictionary(graph.categories.map { ($0.id, $0) },
                                        uniquingKeysWith: { a, _ in a })
        var changed = false
        let transactions = graph.transactions.map { t -> Transaction in
            guard t.amount.isDebit else { return t }
            let cat = t.enrichment.categoryID?.raw
            guard cat == nil || cat == "Other" else { return t }
            changed = true
            let name = concreteCategory(for: t.rawDescription)
            let id = CategoryID(name)
            categoriesByID[id] = Category(id: id, name: name)
            let e = t.enrichment
            let enrichment = Enrichment(
                merchantID: e.merchantID, cleanDescription: e.cleanDescription,
                categoryID: id, tags: e.tags, recurringID: e.recurringID,
                transferPairID: e.transferPairID, confidence: e.confidence)
            return Transaction(
                id: t.id, accountID: t.accountID, statementID: t.statementID,
                date: t.date, processDate: t.processDate, rawDescription: t.rawDescription,
                amount: t.amount, balance: t.balance, currency: t.currency,
                fx: t.fx, enrichment: enrichment)
        }
        guard changed else { return graph }
        return FinancialGraph(
            accounts: graph.accounts,
            statements: graph.statements,
            transactions: transactions,
            merchants: graph.merchants,
            categories: categoriesByID.values.sorted { $0.id.raw < $1.id.raw })
    }

    /// Whether an AI pass with the given `scope` may (re)write this row's
    /// category. Debits always qualify; credits only when `includeCredits`
    /// (the API-primary "every transaction from the API" mode). See `Scope`.
    private static func inScope(_ t: Transaction, _ scope: Scope,
                                includeCredits: Bool = false) -> Bool {
        guard t.amount.isDebit || includeCredits else { return false }
        let cat = t.enrichment.categoryID?.raw
        let unresolved = cat == nil || cat == "Other"
        let aiLabeled = t.enrichment.confidence[.category] != nil
        switch scope {
        case .unresolved:              return unresolved
        case .unresolvedOrAIRelabeled: return unresolved || aiLabeled
        case .withoutAIVerdict:        return unresolved || !aiLabeled
        case .allDebits:               return true
        }
    }
}
