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
    public static func unresolvedDescriptors(in graph: FinancialGraph,
                                             scope: Scope = .unresolved) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in graph.transactions where inScope(t, scope) {
            let d = t.rawDescription
            if !d.isEmpty, seen.insert(d).inserted { out.append(d) }
        }
        return out
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
                             minConfidence: Double = acceptThreshold) -> FinancialGraph {
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
            guard inScope(t, scope), let v = verdicts[t.rawDescription] else { return t }
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
    /// category. Only debits ever qualify; see `Scope` for the tiers.
    private static func inScope(_ t: Transaction, _ scope: Scope) -> Bool {
        guard t.amount.isDebit else { return false }
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
