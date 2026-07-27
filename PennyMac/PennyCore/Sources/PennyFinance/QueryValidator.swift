import Foundation
import PennyModel

/// The validation stage of the pipeline (Query → **Validate** → Optimize → Execute).
///
/// Guarantees the execution engine only ever receives a well-formed query: it
/// normalizes filters (flattens nested `all`/`any`, drops no-ops, collapses double
/// negation, de-duplicates), detects structural errors (bad ranges, non-positive
/// `topN`/`page`), and detects logical contradictions (a transaction can't match
/// two different accounts, currencies, or directions at once) — surfacing those as
/// a provably-empty query the engine can short-circuit.
public enum QueryValidator {

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidAmountRange     // lower > upper
        case invalidDateRange       // start > end
        case invalidTopN            // n <= 0
        case invalidPage            // limit < 0 or offset < 0
    }

    /// A validated + optimized query. `isEmpty` means it provably matches nothing.
    public struct Validated: Equatable, Sendable {
        public let query: Query
        public let isEmpty: Bool
    }

    public static func validate(_ query: Query) -> Result<Validated, ValidationError> {
        // Structural checks.
        if case .topN(let n) = query.aggregate, n <= 0 { return .failure(.invalidTopN) }
        if let p = query.page, p.limit < 0 || p.offset < 0 { return .failure(.invalidPage) }
        for filter in query.filters {
            if let e = structuralError(in: filter) { return .failure(e) }
        }

        // Normalize the top-level filters (AND-combined).
        let normalized = normalize(.all(query.filters))
        let topFilters: [Filter]
        switch normalized {
        case .all(let fs): topFilters = fs
        case .any(let fs) where fs.isEmpty: topFilters = []      // any([]) ⇒ matches nothing (handled below)
        default: topFilters = [normalized]
        }

        var out = query
        out.filters = topFilters
        let empty = (normalized.isAlwaysEmpty) || contradicts(topFilters)
        return .success(Validated(query: out, isEmpty: empty))
    }

    // MARK: - structural errors

    private static func structuralError(in filter: Filter) -> ValidationError? {
        switch filter {
        case .amount(let r):
            if let lo = r.lowerBound, let hi = r.upperBound, lo > hi { return .invalidAmountRange }
            return nil
        case .dateRange(let r):
            if r.start > r.end { return .invalidDateRange }
            return nil
        case .not(let f): return structuralError(in: f)
        case .any(let fs), .all(let fs): return fs.lazy.compactMap(structuralError).first
        default: return nil
        }
    }

    // MARK: - normalization / simplification

    static func normalize(_ filter: Filter) -> Filter {
        switch filter {
        case .not(let inner):
            let n = normalize(inner)
            if case .not(let innerInner) = n { return innerInner }   // not(not(x)) ⇒ x
            return .not(n)

        case .all(let fs):
            var flat: [Filter] = []
            for f in fs.map(normalize) {
                if case .all(let inner) = f { flat.append(contentsOf: inner) }   // flatten nested AND
                else { flat.append(f) }
            }
            flat = dedup(flat)
            if flat.count == 1 { return flat[0] }                    // all([x]) ⇒ x
            return .all(flat)

        case .any(let fs):
            var flat: [Filter] = []
            for f in fs.map(normalize) {
                if case .any(let inner) = f { flat.append(contentsOf: inner) }   // flatten nested OR
                else { flat.append(f) }
            }
            flat = dedup(flat)
            if flat.count == 1 { return flat[0] }                    // any([x]) ⇒ x
            return .any(flat)

        default:
            return filter
        }
    }

    private static func dedup(_ fs: [Filter]) -> [Filter] {
        var seen: [Filter] = []
        for f in fs where !seen.contains(f) { seen.append(f) }
        return seen
    }

    // MARK: - contradiction detection

    /// A transaction has exactly one account, currency, and direction — so ANDing
    /// two different values of any of those matches nothing.
    private static func contradicts(_ filters: [Filter]) -> Bool {
        func distinct<T: Hashable>(_ vals: [T]) -> Bool { Set(vals).count > 1 }
        let accounts = filters.compactMap { if case .account(let a) = $0 { return a } else { return nil } }
        let currencies = filters.compactMap { if case .currency(let c) = $0 { return c } else { return nil } }
        let directions = filters.compactMap { if case .direction(let d) = $0 { return d } else { return nil } }
        let statements = filters.compactMap { if case .statement(let s) = $0 { return s } else { return nil } }
        return distinct(accounts) || distinct(currencies) || distinct(directions) || distinct(statements)
    }
}

private extension Filter {
    /// A normalized filter that provably matches nothing (an empty OR).
    var isAlwaysEmpty: Bool {
        if case .any(let fs) = self { return fs.isEmpty }
        return false
    }
}
