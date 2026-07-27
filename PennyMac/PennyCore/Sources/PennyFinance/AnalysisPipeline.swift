import Foundation
import PennyModel

/// Produces an `AnalysisContext` from a `FinancialGraph` by running the deterministic
/// analyzers in sequence. The single place the pre-computation the engine *consumes*
/// is assembled — today the `RecurringAnalyzer`, tomorrow anomaly/forecast passes —
/// so callers (the app, tests) never wire analyzers together by hand.
public enum AnalysisPipeline {

    /// Run every analyzer over the graph and project the results into the context
    /// the `QueryEngine` reads.
    public static func run(_ graph: FinancialGraph) -> AnalysisContext {
        .from(recurring: RecurringAnalyzer.analyze(graph))
    }
}
