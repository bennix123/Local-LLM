import Foundation

/// Human-readable labels for statement files. The sidebar/list should read like
/// "Paytm UPI" or "Chase", never "Paytm_UPI_Statement_27_Aug'25_-_26_Aug'26.xlsx" —
/// no extensions, no underscores, no date junk. Used by BOTH apps as the last
/// resort when no real issuer/bank name was detected for a document.
public enum StatementName {

    /// Underlying bank accounts an aggregator statement (Paytm/GPay-style
    /// export) reveals in its summary — "Union Bank Of India - 49" → the
    /// banks the money actually moved through. Empty for plain single-bank
    /// statements. Used by BOTH apps to answer "whats the bank name?".
    public static func underlyingAccounts(in text: String) -> [String] {
        let rx = try! NSRegularExpression(
            pattern: #"((?:[A-Z][A-Za-z&.]+ ){0,3}Bank(?: [A-Z][A-Za-z]+){0,3}) *[-–] *(\d{1,4})"#)
        let t = String(text.prefix(4_000))
        var seen: [String] = []
        rx.enumerateMatches(in: t, range: NSRange(t.startIndex..., in: t)) { m, _, _ in
            guard let m, let r1 = Range(m.range(at: 1), in: t),
                  let r2 = Range(m.range(at: 2), in: t) else { return }
            let label = "\(t[r1].trimmingCharacters(in: .whitespaces)) -\(t[r2])"
            if !seen.contains(label), seen.count < 4 { seen.append(label) }
        }
        return seen
    }

    public static func pretty(_ raw: String) -> String {
        var s = raw
        // Drop a short trailing extension (.csv, .pdf, .xlsx …) — but not a
        // dotted phrase that happens to contain a long tail.
        if let dot = s.lastIndex(of: "."), s.distance(from: dot, to: s.endIndex) <= 6 {
            s = String(s[..<dot])
        }
        s = s.replacingOccurrences(of: #"[_\-]+"#, with: " ", options: .regularExpression)
        // "X Statement …" filenames: everything after the word is date/range noise.
        if let r = s.range(of: #"(?i)\b(?:bank\s+)?(?:e-?)?statements?\b"#, options: .regularExpression) {
            let head = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            if head.count >= 3 { s = head }
        }
        // Stop at the first date-ish token ("27", "Aug'25", "2026") — what
        // precedes it is the name.
        let words = s.split(separator: " ").map(String.init)
        var kept = Array(words.prefix(while: { $0.rangeOfCharacter(from: .decimalDigits) == nil }))
        if kept.isEmpty { kept = words }
        var out = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if out.isEmpty { out = raw }
        out = out.split(separator: " ").map { w -> String in
            let word = String(w)
            guard let first = word.first, first.isLowercase else { return word }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
        return out
    }
}
