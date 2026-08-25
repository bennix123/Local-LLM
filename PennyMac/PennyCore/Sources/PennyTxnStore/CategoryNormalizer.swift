// CategoryNormalizer — the taxonomy's gatekeeper: every model-proposed category
// name passes through here before it can touch the ledger, so one concept can
// never fragment into spelling variants ("Ride Hailing" / "ride-hailing" /
// "Ride Hailings" / "Hailing Ride" are all the same category).
//
// Lives in PennyTxnStore (beside Categories/ClaudeCategorizer) rather than the
// LLM layer: normalization is a property of the taxonomy, not of any one model.
import Foundation

public enum CategoryNormalizer {

    /// Tidy a model-proposed category name: strip quotes/punctuation, collapse
    /// whitespace, snap any seed match to the seed's canonical spelling —
    /// case-, hyphen-, word-order- and plural-insensitive — Title-Case genuinely
    /// new names, and fall back to "Other" for empty or rambling (>3 words /
    /// >28 chars) answers.
    public static func normalize(_ raw: String, seeds: [String]) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,:;"))
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !s.isEmpty else { return "Other" }
        if let seed = seeds.first(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) { return seed }
        let k = key(s)
        if let seed = seeds.first(where: { key($0) == k }) { return seed }
        let words = s.split(separator: " ")
        guard words.count <= 3, s.count <= 28 else { return "Other" }
        return words.enumerated().map { i, w -> String in
            let lw = w.lowercased()
            if i > 0, ["&", "and", "of", "the"].contains(lw) { return lw }
            return w.prefix(1).uppercased() + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// Fuzzy identity for a category name: lowercase tokens, punctuation-split,
    /// trailing plural "s" stripped (len > 3 so "Gas"/"Fees" survive sensibly),
    /// sorted so word order can't fork ("Hailing Ride" ≡ "Ride Hailing").
    static func key(_ s: String) -> String {
        s.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { token -> String in
                var t = String(token)
                if t.count > 3, t.hasSuffix("s"), !t.hasSuffix("ss") { t.removeLast() }
                return t
            }
            .sorted()
            .joined(separator: " ")
    }
}
