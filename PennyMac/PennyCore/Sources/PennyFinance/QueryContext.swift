import Foundation
import PennyModel

/// The vocabulary a natural-language query is interpreted *against* — the set of
/// entity names and the date span actually present in the data. It is a small,
/// value-typed projection of the graph (NOT the graph itself): the bridge and the
/// future LLM parser interpret *language* against this, they never traverse the
/// model. Populated by the app from the selected `FinancialGraph`; empty is valid
/// (unscoped intents don't consult it).
public struct QueryVocabulary: Equatable, Sendable {
    /// A named entity that a filter needs an identity for (accounts). Merchants
    /// resolve by name in the engine, and a category's id *is* its name, so only
    /// accounts need to carry an id alongside their display name.
    public struct Entity: Equatable, Sendable {
        public let name: String
        public let id: String
        public init(name: String, id: String) { self.name = name; self.id = id }
    }

    public var categories: [String]
    public var merchants: [String]
    public var accounts: [Entity]
    public var currencies: [String]     // currency codes present in the data
    public var months: [String]         // distinct "YYYY-MM" present, ascending (relative-date anchor)
    public var dateRange: CalendarDateRange?

    public init(categories: [String] = [], merchants: [String] = [],
                accounts: [Entity] = [], currencies: [String] = [],
                months: [String] = [], dateRange: CalendarDateRange? = nil) {
        self.categories = categories
        self.merchants = merchants
        self.accounts = accounts
        self.currencies = currencies
        self.months = months
        self.dateRange = dateRange
    }

    public static let empty = QueryVocabulary()

    /// Project a graph into the vocabulary a query is interpreted against. Built
    /// once by the app (and tests) — the bridge/resolver never see the graph itself.
    public static func from(_ graph: FinancialGraph) -> QueryVocabulary {
        let dates = graph.transactions.map(\.date).sorted()
        let range = dates.first.flatMap { lo in dates.last.map { CalendarDateRange(start: lo, end: $0) } }
        let months = Set(graph.transactions.map { String(format: "%04d-%02d", $0.date.year, $0.date.month) }).sorted()
        return QueryVocabulary(
            categories: graph.categories.map(\.name),
            merchants: graph.merchants.map(\.canonicalName),
            accounts: graph.accounts.map { Entity(name: $0.institution, id: $0.id.raw) },
            currencies: Array(Set(graph.transactions.map(\.currency.code))).sorted(),
            months: months,
            dateRange: range)
    }
}

/// Everything an intent recognizer needs beyond the raw question string. Kept
/// deliberately thin so recognizers stay pure language→`Query` functions and are
/// reusable by the Wave-B `ScopeResolver` and the future LLM parser alike.
public struct QueryContext: Equatable, Sendable {
    public var vocabulary: QueryVocabulary

    public init(vocabulary: QueryVocabulary = .empty) {
        self.vocabulary = vocabulary
    }

    public static let empty = QueryContext()
}
