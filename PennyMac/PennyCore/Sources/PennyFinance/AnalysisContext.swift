import Foundation
import PennyModel

/// Pre-computed analytical facts the `QueryEngine` **consumes** but does not derive
/// itself (Wave A2). Detection algorithms (recurring-charge clustering, and later
/// anomaly/forecast passes) live in their own analyzers; their output is projected
/// here so the engine stays a pure, deterministic reducer over `(Query, graph,
/// analysis)`. Empty is valid — a query that references no analysis ignores it.
public struct AnalysisContext: Equatable, Sendable {
    /// Transactions the `RecurringAnalyzer` attributed to a recurring charge.
    public var recurringTransactionIDs: Set<TransactionID>

    public init(recurringTransactionIDs: Set<TransactionID> = []) {
        self.recurringTransactionIDs = recurringTransactionIDs
    }

    public static let empty = AnalysisContext()

    /// Project a recurring analysis into the context the engine reads.
    public static func from(recurring charges: [RecurringCharge]) -> AnalysisContext {
        AnalysisContext(recurringTransactionIDs: Set(charges.flatMap(\.transactionIDs)))
    }
}
