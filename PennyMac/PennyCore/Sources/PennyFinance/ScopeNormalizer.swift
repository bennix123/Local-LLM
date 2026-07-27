import Foundation

/// The normalized form of a question — the first stage of scope resolution
/// (Normalize → Resolve → Disambiguate). A pure, deterministic text transform:
/// lowercase, fold apostrophes/possessives, drop commas, collapse whitespace. It
/// **prepares text for matching**; it never decides what anything means (that's
/// resolution). Currency symbols, digits, `/`, `-`, and `&` are preserved.
public struct NormalizedQuery: Equatable, Sendable {
    public let text: String        // normalized, lowercased
    public let original: String
}

public enum ScopeNormalizer {

    public static func normalize(_ question: String) -> NormalizedQuery {
        var t = question.lowercased()
        // fold curly/smart apostrophes to straight, then drop possessives ("amazon's" → "amazon")
        t = t.replacingOccurrences(of: "\u{2019}", with: "'")
             .replacingOccurrences(of: "\u{2018}", with: "'")
        t = t.replacingOccurrences(of: "'s ", with: " ")
        if t.hasSuffix("'s") { t = String(t.dropLast(2)) }
        t = t.replacingOccurrences(of: "'", with: "")
        // commas are noise for matching ("June 15, 2026" still parses via optional-comma regexes)
        t = t.replacingOccurrences(of: ",", with: " ")
        // collapse all runs of whitespace to single spaces
        t = t.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).joined(separator: " ")
        return NormalizedQuery(text: t, original: question)
    }
}
