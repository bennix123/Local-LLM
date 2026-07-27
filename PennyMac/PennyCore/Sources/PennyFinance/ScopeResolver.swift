import Foundation
import PennyModel

/// One resolved scope constraint — the structured detail behind a filter, so callers
/// (the bridge today, the LLM parser tomorrow) can reason about *what* matched, not
/// just the opaque filter.
public struct ScopeMatch: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case category, merchant, account, currency, date }
    public let kind: Kind
    public let value: String      // the resolved entity / period, human-readable
    public let filter: Filter
}

/// The result of interpreting a question's scope against a vocabulary. Deliberately
/// richer than a `[Filter]`: it carries the matches, a FinanceRouter-compatible label
/// (for activation parity in Wave C), and the ambiguity/unresolved signals produced
/// by disambiguation.
public struct ScopeResolutionResult: Equatable, Sendable {
    public var matches: [ScopeMatch]
    public var label: String            // e.g. " on Groceries at Amazon in June" (leading space) or ""
    public var isAmbiguous: Bool
    public var unresolvedTerms: [String]

    public var filters: [Filter] { matches.map(\.filter) }

    public static let none = ScopeResolutionResult(matches: [], label: "", isAmbiguous: false, unresolvedTerms: [])
}

/// Deterministic scope resolution as a three-stage pipeline:
///
///   Normalize (`ScopeNormalizer`) → Resolve/match (`ScopeMatcher`) → Disambiguate → result
///
/// Matching (finding candidates) and resolution (choosing the final scope) are kept
/// as separate concepts: the matcher emits every candidate; this resolver applies
/// longest-match refinement and ambiguity handling to decide the outcome. Reusable —
/// the bridge and the future LLM parser both call `resolve`.
public enum ScopeResolver {

    public static func resolve(_ question: String, vocabulary: QueryVocabulary) -> ScopeResolutionResult {
        let normalized = ScopeNormalizer.normalize(question)          // 1. Normalize
        let candidates = ScopeMatcher.match(normalized, vocabulary: vocabulary)  // 2. Resolve (match)
        return disambiguate(candidates)                              // 3. Disambiguate
    }

    // MARK: - disambiguation (longest-match refinement + ambiguity handling)

    private static func disambiguate(_ candidates: [ScopeCandidate]) -> ScopeResolutionResult {
        var matches: [ScopeMatch] = []
        var unresolved: [String] = []
        var ambiguous = false

        for kind in ScopeMatch.Kind.allCases {
            let group = candidates.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }

            // Longest-match refinement: drop a candidate whose canonical is a proper
            // substring of another candidate's canonical (keep the more specific one).
            let refined = group.filter { c in
                !group.contains { other in
                    other.canonical != c.canonical
                        && other.canonical.lowercased().contains(c.canonical.lowercased())
                }
            }

            let distinct = Set(refined.map(\.canonical))
            if distinct.count == 1 {
                // pick the strongest evidence: exact > alias > synonym, then longest.
                let best = refined.min { rank($0) < rank($1) }!
                matches.append(ScopeMatch(kind: kind, value: best.canonical, filter: best.filter))
            } else {
                // genuinely competing entities → don't guess (deterministic + safe):
                // emit no filter for this kind, and record it for the caller / B-later.
                ambiguous = true
                unresolved.append(contentsOf: distinct.sorted())
            }
        }

        return ScopeResolutionResult(matches: matches, label: label(matches),
                                     isAmbiguous: ambiguous, unresolvedTerms: unresolved)
    }

    /// Sort key: prefer exact evidence, then longer surface forms.
    private static func rank(_ c: ScopeCandidate) -> (Int, Int) {
        let s: Int
        switch c.source { case .exact, .explicitDate, .relativeDate: s = 0; case .alias: s = 1; case .synonym: s = 2 }
        return (s, -c.length)
    }

    private static func label(_ matches: [ScopeMatch]) -> String {
        var parts: [String] = []
        for m in matches {
            switch m.kind {
            case .category: parts.append("on \(m.value)")
            case .merchant: parts.append("at \(m.value)")
            case .account:  parts.append("in \(m.value)")
            case .currency: break   // the router never labels currency
            case .date:     parts.append(m.value.hasPrefix("on ") ? m.value : "in \(m.value)")
            }
        }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }
}
