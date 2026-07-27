import Foundation
import PennyModel

/// The deterministic query engine (Phase 1). A pure function of `(Query, graph)`:
/// **Validate → Optimize → Execute**. No I/O, no AI, no dependency on the parser or
/// UI. Every figure it returns is exact and carries the transactions that produced
/// it (citations). Money aggregations never blend currencies.
public enum QueryEngine {

    /// Execute a query. Invalid queries yield an empty result of the right shape
    /// (never a crash); provably-empty queries short-circuit. `analysis` supplies
    /// pre-computed facts the engine consumes (e.g. recurring detection, Wave A2)
    /// but never derives itself.
    public static func execute(_ query: Query, in graph: FinancialGraph,
                               analysis: AnalysisContext = .empty) -> QueryResult {
        switch QueryValidator.validate(query) {
        case .failure:
            return emptyResult(for: query.aggregate)
        case .success(let validated):
            if validated.isEmpty { return emptyResult(for: query.aggregate) }
            return run(validated.query, in: GraphIndex(graph, analysis: analysis))
        }
    }

    // MARK: - execution

    private static func run(_ query: Query, in index: GraphIndex) -> QueryResult {
        let combined: Filter = query.filters.isEmpty ? .all([]) : .all(query.filters)
        let matched = index.transactions.filter { matches($0, combined, index) }
        if let grouping = query.groupBy {
            return grouped(matched, query: query, grouping: grouping, index: index)
        }
        return aggregate(matched, query: query, index: index)
    }

    // MARK: - filter predicate

    static func matches(_ t: Transaction, _ filter: Filter, _ index: GraphIndex) -> Bool {
        switch filter {
        case .account(let a):     return t.accountID == a
        case .statement(let s):   return t.statementID == s
        case .category(let c):    return t.enrichment.categoryID == c
        case .tag(let tag):       return t.enrichment.tags.contains(tag)
        case .direction(let d):   return t.direction == d
        case .currency(let c):    return t.currency == c
        case .dateRange(let r):   return r.contains(t.date)
        case .amount(let r):      return r.contains(t.amount.magnitude)   // magnitude (Decision 2)
        case .confidence(let s, let min): return (t.enrichment.confidence[s] ?? 0) >= min
        case .text(let needle):   return contains(t, needle)
        case .recurring:          return index.isRecurring(t.id)
        case .merchant(.id(let m)): return t.enrichment.merchantID == m
        case .merchant(.name(let n)):
            if let m = index.merchantID(forName: n) { return t.enrichment.merchantID == m }
            return contains(t, n)                                          // unknown name → text fallback
        case .not(let f):         return !matches(t, f, index)
        case .any(let fs):        return fs.contains { matches(t, $0, index) }
        case .all(let fs):        return fs.allSatisfy { matches(t, $0, index) }
        }
    }

    private static func contains(_ t: Transaction, _ needle: String) -> Bool {
        let n = needle.lowercased()
        return t.rawDescription.lowercased().contains(n)
            || (t.enrichment.cleanDescription?.lowercased().contains(n) ?? false)
    }

    // MARK: - aggregation

    private static func aggregate(_ txns: [Transaction], query: Query, index: GraphIndex) -> QueryResult {
        switch query.aggregate {
        case .list:  return listResult(txns, query: query)
        case .topN(let n): return listResult(txns, query: query, limit: n)
        case .count: return QueryResult(scalar: .count(txns.count), citations: txns.map(\.id))
        case .distinctCount(let f):
            return QueryResult(scalar: .count(distinctCount(txns, f, index)), citations: txns.map(\.id))
        case .sum:     return moneyResult(txns) { $0.reduce(Decimal(0)) { $0 + $1.amount.amount } }
        case .average: return moneyResult(txns) { g in g.isEmpty ? 0 : g.reduce(Decimal(0)) { $0 + $1.amount.amount } / Decimal(g.count) }
        case .min:     return extreme(txns, max: false)
        case .max:     return extreme(txns, max: true)
        case .balance(let kind): return balanceResult(txns, kind, index)
        }
    }

    /// Balance figures read from the model (Wave A2) — stored facts, not derived
    /// from the matched transactions' amounts. Opening/closing come from the scope's
    /// statements; running/at-date from the last in-scope printed running balance.
    private static func balanceResult(_ txns: [Transaction], _ kind: BalanceKind, _ index: GraphIndex) -> QueryResult {
        func money(_ m: Money?, currency: Currency?, citations: [TransactionID]) -> QueryResult {
            guard let m else { return QueryResult(scalar: .none) }
            return QueryResult(scalar: .money(m.amount), citations: citations, currency: currency)
        }
        switch kind {
        case .opening:
            guard let st = index.scopeStatements(txns).min(by: { index.statementOrder($0) < index.statementOrder($1) })
            else { return QueryResult(scalar: .none) }
            return money(st.openingBalance, currency: index.accountCurrency(st.accountID), citations: [])
        case .closing:
            guard let st = index.scopeStatements(txns).max(by: { index.statementOrder($0) < index.statementOrder($1) })
            else { return QueryResult(scalar: .none) }
            return money(st.closingBalance, currency: index.accountCurrency(st.accountID), citations: [])
        case .running:
            guard let t = txns.last(where: { $0.balance != nil }) else { return QueryResult(scalar: .none) }
            return money(t.balance, currency: t.currency, citations: [t.id])
        case .atDate(let d):
            guard let t = txns.last(where: { $0.balance != nil && !($0.date > d) }) else { return QueryResult(scalar: .none) }
            return money(t.balance, currency: t.currency, citations: [t.id])
        }
    }

    /// list / topN: sorted rows + citations. Default sort is amount-descending.
    private static func listResult(_ txns: [Transaction], query: Query, limit: Int? = nil) -> QueryResult {
        var rows = sorted(txns, by: query.sort.isEmpty ? [SortKey(.amount, .descending)] : query.sort)
        if let page = query.page { rows = Array(rows.dropFirst(page.offset).prefix(page.limit)) }
        if let limit { rows = Array(rows.prefix(limit)) }
        return QueryResult(rows: rows, citations: rows.map(\.id))
    }

    /// Money aggregation with the per-currency guard: single currency ⇒ a scalar;
    /// mixed currencies ⇒ no blended total, a per-currency `groups` breakdown instead.
    private static func moneyResult(_ txns: [Transaction], _ reduce: ([Transaction]) -> Decimal) -> QueryResult {
        let byCurrency = Dictionary(grouping: txns, by: \.currency)
        if byCurrency.count <= 1 {
            return QueryResult(scalar: .money(reduce(txns)), citations: txns.map(\.id), currency: txns.first?.currency)
        }
        let groups = byCurrency.sorted { $0.key.code < $1.key.code }.map { cur, ts in
            GroupResult(key: cur.code, result: QueryResult(scalar: .money(reduce(ts)), citations: ts.map(\.id), currency: cur))
        }
        return QueryResult(scalar: nil, groups: groups, citations: txns.map(\.id), currency: nil)
    }

    /// min/max by magnitude — returns the extreme amount + the transaction behind it.
    private static func extreme(_ txns: [Transaction], max: Bool) -> QueryResult {
        let pick = max ? txns.max { $0.amount.magnitude < $1.amount.magnitude }
                       : txns.min { $0.amount.magnitude < $1.amount.magnitude }
        guard let t = pick else { return QueryResult(scalar: .none) }
        return QueryResult(scalar: .money(t.amount.magnitude), rows: [t], citations: [t.id], currency: t.currency)
    }

    private static func distinctCount(_ txns: [Transaction], _ field: Field, _ index: GraphIndex) -> Int {
        switch field {
        case .account:   return Set(txns.map(\.accountID)).count
        case .statement: return Set(txns.map(\.statementID)).count
        case .merchant:  return Set(txns.compactMap(\.enrichment.merchantID)).count
        case .category:  return Set(txns.compactMap(\.enrichment.categoryID)).count
        case .currency:  return Set(txns.map(\.currency)).count
        case .tag:       return Set(txns.flatMap(\.enrichment.tags)).count
        case .month:     return Set(txns.map { monthKey($0) }).count
        case .day:       return Set(txns.map { dayKey($0) }).count
        }
    }

    // MARK: - grouping

    private static func grouped(_ txns: [Transaction], query: Query, grouping: Grouping, index: GraphIndex) -> QueryResult {
        // Partition (tags are multi-valued: a txn joins each of its tag groups).
        var buckets: [String: [Transaction]] = [:]
        for t in txns {
            for key in groupKeys(t, grouping, index) { buckets[key, default: []].append(t) }
        }
        // Within-group aggregate: `topN`/`list` groups rank by sum; others use the aggregate itself.
        let inner: Aggregation = { switch query.aggregate { case .topN, .list: return .sum; default: return query.aggregate } }()
        var groups = buckets.map { key, ts -> GroupResult in
            GroupResult(key: key, result: aggregate(ts, query: Query(aggregate: inner), index: index))
        }
        groups.sort { scalarMagnitude($0.result) > scalarMagnitude($1.result) }
        if case .topN(let n) = query.aggregate { groups = Array(groups.prefix(n)) }
        return QueryResult(groups: groups, citations: txns.map(\.id),
                           currency: Set(txns.map(\.currency)).count == 1 ? txns.first?.currency : nil)
    }

    private static func groupKeys(_ t: Transaction, _ g: Grouping, _ index: GraphIndex) -> [String] {
        switch g {
        case .account:   return [index.accountName(t.accountID) ?? t.accountID.raw]
        case .statement: return [index.statementName(t.statementID) ?? t.statementID.raw]
        case .merchant:  return [index.merchantName(t.enrichment.merchantID) ?? "Unknown"]
        case .category:  return [index.categoryName(t.enrichment.categoryID) ?? "Uncategorized"]
        case .currency:  return [t.currency.code]
        case .month:     return [monthKey(t)]
        case .day:       return [dayKey(t)]
        case .tag:       return t.enrichment.tags.isEmpty ? ["untagged"] : t.enrichment.tags.map(\.rawValue).sorted()
        }
    }

    // MARK: - helpers

    private static func sorted(_ txns: [Transaction], by keys: [SortKey]) -> [Transaction] {
        txns.sorted { a, b in
            for key in keys {
                let asc = key.order == .ascending
                switch key.by {
                case .amount:
                    if a.amount.magnitude != b.amount.magnitude { return asc ? a.amount.magnitude < b.amount.magnitude : a.amount.magnitude > b.amount.magnitude }
                case .date:
                    if a.date != b.date { return asc ? a.date < b.date : a.date > b.date }
                case .count: break
                }
            }
            return a.id.raw < b.id.raw   // stable tiebreak
        }
    }

    private static func scalarMagnitude(_ r: QueryResult) -> Decimal {
        switch r.scalar {
        case .money(let m): return abs(m)
        case .count(let c): return Decimal(c)
        default: return 0
        }
    }

    private static func monthKey(_ t: Transaction) -> String { String(format: "%04d-%02d", t.date.year, t.date.month) }
    private static func dayKey(_ t: Transaction) -> String { String(format: "%04d-%02d-%02d", t.date.year, t.date.month, t.date.day) }

    private static func emptyResult(for aggregate: Aggregation) -> QueryResult {
        switch aggregate {
        case .count, .distinctCount: return QueryResult(scalar: .count(0))
        case .list, .topN:           return QueryResult(rows: [])
        default:                     return QueryResult(scalar: .none)
        }
    }
}

/// Cached lookups over a `FinancialGraph` — built once per execution.
struct GraphIndex {
    let transactions: [Transaction]
    private let merchantIdByName: [String: MerchantID]
    private let merchantNameById: [MerchantID: String]
    private let categoryNameById: [CategoryID: String]
    private let accountNameById: [AccountID: String]
    private let statementNameById: [StatementID: String]
    private let statementById: [StatementID: Statement]
    private let accountCurrencyById: [AccountID: Currency]
    private let recurringIDs: Set<TransactionID>

    init(_ graph: FinancialGraph, analysis: AnalysisContext = .empty) {
        transactions = graph.transactions
        merchantIdByName = Dictionary(graph.merchants.map { ($0.canonicalName.lowercased(), $0.id) }, uniquingKeysWith: { a, _ in a })
        merchantNameById = Dictionary(graph.merchants.map { ($0.id, $0.canonicalName) }, uniquingKeysWith: { a, _ in a })
        categoryNameById = Dictionary(graph.categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        accountNameById = Dictionary(graph.accounts.map { ($0.id, $0.institution) }, uniquingKeysWith: { a, _ in a })
        statementNameById = Dictionary(graph.statements.map { ($0.id, $0.sourceName) }, uniquingKeysWith: { a, _ in a })
        statementById = Dictionary(graph.statements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        accountCurrencyById = Dictionary(graph.accounts.map { ($0.id, $0.currency) }, uniquingKeysWith: { a, _ in a })
        recurringIDs = analysis.recurringTransactionIDs
    }

    // MARK: balances & recurring (Wave A2)

    func isRecurring(_ id: TransactionID) -> Bool { recurringIDs.contains(id) }
    func accountCurrency(_ id: AccountID) -> Currency? { accountCurrencyById[id] }

    /// The distinct statements referenced by a set of matched transactions.
    func scopeStatements(_ txns: [Transaction]) -> [Statement] {
        var seen = Set<StatementID>()
        return txns.compactMap { seen.insert($0.statementID).inserted ? statementById[$0.statementID] : nil }
    }

    /// A total, stable chronological key for a statement (issue date, else period
    /// end/start, else none) — earliest opens, latest closes; sourceName breaks ties.
    func statementOrder(_ s: Statement) -> String {
        let anchor = s.statementDate ?? s.period?.end ?? s.period?.start
        let key = anchor.map { String(format: "%04d%02d%02d", $0.year, $0.month, $0.day) } ?? "00000000"
        return key + "|" + s.sourceName
    }

    /// Resolve a merchant name (case-insensitive, exact or contained) to an id.
    func merchantID(forName name: String) -> MerchantID? {
        let n = name.lowercased()
        if let exact = merchantIdByName[n] { return exact }
        return merchantIdByName.first { $0.key.contains(n) || n.contains($0.key) }?.value
    }
    func merchantName(_ id: MerchantID?) -> String? { id.flatMap { merchantNameById[$0] } }
    func categoryName(_ id: CategoryID?) -> String? { id.flatMap { categoryNameById[$0] } }
    func accountName(_ id: AccountID) -> String? { accountNameById[id] }
    func statementName(_ id: StatementID) -> String? { statementNameById[id] }
}
