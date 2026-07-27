// EngineRouter — Phase 1.1 runtime integration seam.
//
//   User question → LegacyQueryBridge → QueryEngine → (router-shaped answer)
//
// This is the app-side adapter that turns a natural-language question into a
// deterministic `QueryEngine` answer *string*, formatted to reconcile with the
// legacy `FinanceRouter` for the intents the engine covers today (count, total
// spend, income). `AppModel.send` adopts this answer ONLY when it exactly equals
// the router's answer (a runtime parity guard), so the engine can never change a
// user-visible reply — it can only prove parity or fall back. No AI here; pure
// value logic over the canonical graph.
import Foundation
import PennyModel
import PennyFinance

enum EngineRouter {

    /// The engine's answer to `question` over `graph`, phrased to match the legacy
    /// router. Returns nil when the bridge doesn't recognise the question or the
    /// result isn't one of the reconciled shapes — the caller then falls back.
    static func answer(for question: String, graph: FinancialGraph,
                       money: (Double) -> String) -> String? {
        let context = QueryContext(vocabulary: QueryVocabulary.from(graph))
        guard let query = LegacyQueryBridge.query(for: question, context: context) else { return nil }
        let result = QueryEngine.execute(query, in: graph, analysis: AnalysisPipeline.run(graph))
        return format(result, query: query, money: money)
    }

    // MARK: - router-shaped formatting

    private static func format(_ result: QueryResult, query: Query,
                               money: (Double) -> String) -> String? {
        switch query.aggregate {
        case .count:
            guard case .count(let n)? = result.scalar else { return nil }
            let noun = n == 1 ? "transaction" : "transactions"
            return "**\(grp(n)) \(noun).**"

        case .sum:
            guard case .money(let m)? = result.scalar else { return nil }
            let amount = money(dbl(abs(m)))
            let n = result.citations.count
            if direction(of: query) == .credit {
                let noun = n == 1 ? "credit" : "credits"
                return "**You received \(amount)** across \(grp(n)) \(noun)."
            }
            let noun = n == 1 ? "transaction" : "transactions"
            return "**You spent \(amount)** across \(grp(n)) \(noun)."

        default:
            // Largest / top-N / by-category are answered upstream by
            // crossDocumentAnswer before this stage; leave them to the fallback.
            return nil
        }
    }

    /// The direction a query filters on (income vs. spend), if any.
    private static func direction(of query: Query) -> Direction? {
        for f in query.filters { if case .direction(let d) = f { return d } }
        return nil
    }

    // MARK: - primitives (mirror FinanceRouter's, so strings match by construction)

    /// Decimal → Double via the string form, avoiding NSDecimalNumber's binary drift
    /// (e.g. 15470.46 → 15470.460000000001) so the formatted money matches the router.
    private static func dbl(_ d: Decimal) -> Double {
        Double(d.description) ?? (d as NSDecimalNumber).doubleValue
    }

    private static func grp(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = ","
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
