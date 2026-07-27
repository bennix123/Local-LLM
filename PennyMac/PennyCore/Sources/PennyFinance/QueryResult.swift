import Foundation
import PennyModel

/// A single computed value returned by an aggregation.
public enum ScalarValue: Equatable, Sendable {
    case money(Decimal)     // sum/average/min/max — paired with `QueryResult.currency`
    case count(Int)         // count / distinctCount
    case none               // no data (e.g. min/max over an empty set)
}

/// The result of executing a `Query` — the value(s) plus the exact transactions
/// that produced them (free provenance / citations).
public struct QueryResult: Equatable, Sendable {
    /// Scalar aggregations (sum/average/min/max/count/distinctCount).
    public var scalar: ScalarValue?
    /// Row-returning aggregations (list / topN).
    public var rows: [Transaction]
    /// Grouped results, keyed by the group's display key (present when `groupBy` is set).
    public var groups: [GroupResult]?
    /// Every transaction that contributed to this result.
    public var citations: [TransactionID]
    /// The currency of a scalar money value; `nil` when the inputs span multiple
    /// currencies (a blended sum is never produced — see `groups` for the split).
    public var currency: Currency?

    public init(scalar: ScalarValue? = nil, rows: [Transaction] = [],
                groups: [GroupResult]? = nil, citations: [TransactionID] = [],
                currency: Currency? = nil) {
        self.scalar = scalar; self.rows = rows; self.groups = groups
        self.citations = citations; self.currency = currency
    }
}

/// One group of a grouped query (kept as an ordered list so sort order is meaningful).
public struct GroupResult: Equatable, Sendable {
    public var key: String            // display key: category/merchant name, "2026-06", etc.
    public var result: QueryResult
    public init(key: String, result: QueryResult) { self.key = key; self.result = result }
}
