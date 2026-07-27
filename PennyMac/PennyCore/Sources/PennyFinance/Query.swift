import Foundation
import PennyModel

/// A composable, deterministic query over a `FinancialGraph` (Phase 1). An
/// immutable value — the same query always yields the same result. `Codable` so a
/// future intent layer (Phase 3) can emit one as JSON. No question has its own code
/// path: every deterministic answer is a `Query`.
public struct Query: Equatable, Sendable, Codable {
    public var filters: [Filter]        // AND-combined at the top level
    public var aggregate: Aggregation
    public var groupBy: Grouping?
    public var sort: [SortKey]
    public var page: Page?

    public init(filters: [Filter] = [], aggregate: Aggregation = .list,
                groupBy: Grouping? = nil, sort: [SortKey] = [], page: Page? = nil) {
        self.filters = filters; self.aggregate = aggregate
        self.groupBy = groupBy; self.sort = sort; self.page = page
    }
}

/// A predicate over a transaction. `merchant`/`category` names resolve through the
/// graph's indices; unknown names fall back to a `text` match (never fabricated).
public indirect enum Filter: Equatable, Sendable, Codable {
    case account(AccountID)
    case statement(StatementID)
    case merchant(MerchantRef)
    case category(CategoryID)
    case tag(Tag)
    case dateRange(CalendarDateRange)
    /// Amount predicate on the transaction's **magnitude** (unsigned) — "over £500"
    /// ignores direction (Decision 2). Sign is expressed separately via `.direction`.
    case amount(ComparableRange<Decimal>)
    case direction(Direction)
    case currency(Currency)
    case confidence(Signal, min: Double)
    case text(String)
    /// Matches transactions the `RecurringAnalyzer` flagged as part of a recurring
    /// charge. The engine **consumes** that analysis (via `AnalysisContext`) — it
    /// never runs the detection itself (Wave A2).
    case recurring
    case not(Filter)
    case any([Filter])   // OR
    case all([Filter])   // AND
}

/// How a merchant filter names its target.
public enum MerchantRef: Equatable, Sendable, Codable {
    case id(MerchantID)
    case name(String)
}

/// What the query returns.
public enum Aggregation: Equatable, Sendable, Codable {
    case list
    case count
    case sum
    case average
    case min
    case max
    case topN(Int)
    case distinctCount(Field)
    /// A balance figure read from the model (Wave A2) — a stored fact, not a
    /// transaction aggregate. The scope's statements/rows supply it.
    case balance(BalanceKind)
}

/// Which balance a `.balance` aggregation reports.
public enum BalanceKind: Equatable, Sendable, Codable {
    case opening            // scope's earliest statement's declared opening balance
    case closing            // scope's latest statement's declared closing balance
    case running            // the last in-scope transaction that prints a balance
    case atDate(CalendarDate) // the last in-scope printed balance on or before a date
}

/// A field for grouping / distinct-count.
public enum Field: String, Equatable, Sendable, Codable, CaseIterable {
    case account, statement, merchant, category, tag, month, day, currency
}

public enum Grouping: String, Equatable, Sendable, Codable, CaseIterable {
    case account, statement, merchant, category, tag, month, day, currency
}

public struct SortKey: Equatable, Sendable, Codable {
    public enum By: String, Sendable, Codable { case amount, date, count }
    public enum Order: String, Sendable, Codable { case ascending, descending }
    public var by: By
    public var order: Order
    public init(_ by: By, _ order: Order = .descending) { self.by = by; self.order = order }
}

public struct Page: Equatable, Sendable, Codable {
    public var limit: Int
    public var offset: Int
    public init(limit: Int, offset: Int = 0) { self.limit = limit; self.offset = offset }
}
