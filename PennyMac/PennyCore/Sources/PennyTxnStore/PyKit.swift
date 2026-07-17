// PyKit — tiny Python-semantics shims so the parsers can be ported line-for-line
// from finquery/backend/src/services/txn_store/parsers.py. Exactness matters:
// the contract conformance suite exact-matches JSON, so round() must be
// banker's rounding, title() must follow Python word rules, and regexes must
// behave like `re` (named groups, \b, etc.).
import Foundation

/// Python `round(x)` — round-half-to-even, returns Int.
@inline(__always) public func pyRound(_ x: Double) -> Int {
    Int(x.rounded(.toNearestOrEven))
}

/// Python `int(x)` for floats — truncation toward zero.
@inline(__always) public func pyInt(_ x: Double) -> Int {
    Int(x.rounded(.towardZero))
}

// ------------------------------------------------------------------ string shims

extension StringProtocol {
    /// Python `s.strip()` (ASCII + unicode whitespace; our data is ASCII).
    public func pyStrip() -> String {
        String(self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Python `s.strip(chars)`.
    public func pyStrip(_ chars: String) -> String {
        let set = CharacterSet(charactersIn: chars)
        return String(self).trimmingCharacters(in: set)
    }

    /// Python `s.lower()`.
    public func pyLower() -> String { String(self).lowercased() }
    public func pyUpper() -> String { String(self).uppercased() }

    /// Python `sub in s`.
    public func pyContains(_ sub: String) -> Bool {
        sub.isEmpty ? true : String(self).contains(sub)
    }

    /// Python `s.title()`: uppercase every cased char that follows a non-alpha
    /// char, lowercase the rest ("h3 2vx" -> "H3 2Vx", "don't" -> "Don'T").
    public func pyTitle() -> String {
        var out = ""
        var prevAlpha = false
        for ch in String(self) {
            if ch.isLetter {
                out.append(prevAlpha ? Character(ch.lowercased()) : Character(ch.uppercased()))
                prevAlpha = true
            } else {
                out.append(ch)
                prevAlpha = false
            }
        }
        return out
    }

    /// Python `s.isupper()`: at least one cased char and no lowercase chars.
    public func pyIsUpper() -> Bool {
        var hasCased = false
        for ch in String(self) {
            if ch.isLowercase { return false }
            if ch.isUppercase { hasCased = true }
        }
        return hasCased
    }

    /// Python `s.isdigit()` (ASCII digits; our data is ASCII).
    public func pyIsDigit() -> Bool {
        !isEmpty && allSatisfy { $0.isNumber }
    }

    /// Python `s.split()` — split on runs of whitespace, no empty parts.
    public func pySplit() -> [String] {
        String(self).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Python `s.split(sep)` — literal separator, keeps empty parts.
    public func pySplit(_ sep: String) -> [String] {
        String(self).components(separatedBy: sep)
    }

    /// Python `s.rsplit(maxsplit=n)` — whitespace split from the right.
    public func pyRSplit(maxsplit: Int) -> [String] {
        var parts: [String] = []
        var rest = String(self)
        for _ in 0..<maxsplit {
            // find last whitespace run in `rest`
            guard let r = rest.rangeOfCharacter(from: .whitespaces, options: .backwards) else { break }
            // expand to the whole whitespace run
            var lo = r.lowerBound
            while lo > rest.startIndex {
                let prev = rest.index(before: lo)
                if rest[prev].isWhitespace { lo = prev } else { break }
            }
            let tail = String(rest[r.upperBound...])
            parts.insert(tail, at: 0)
            rest = String(rest[..<lo])
            if rest.rangeOfCharacter(from: .whitespaces) == nil { break }
        }
        parts.insert(rest, at: 0)
        return parts
    }

    /// Python `s.splitlines()` (only \n and \r\n occur in our data).
    public func pySplitLines() -> [String] {
        var lines: [String] = []
        var cur = ""
        var i = String(self).startIndex
        let s = String(self)
        while i < s.endIndex {
            let ch = s[i]
            if ch == "\n" || ch == "\r" {
                lines.append(cur); cur = ""
                if ch == "\r" {
                    let nxt = s.index(after: i)
                    if nxt < s.endIndex, s[nxt] == "\n" { i = nxt }
                }
            } else {
                cur.append(ch)
            }
            i = s.index(after: i)
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines
    }

    /// Python `s[:n]` by characters.
    public func pyPrefix(_ n: Int) -> String { String(String(self).prefix(n)) }
}

// ------------------------------------------------------------------ regex shim

/// A `re`-alike over NSRegularExpression. Patterns are written in Python `re`
/// syntax; `(?P<name>` is translated to ICU's `(?<name>`.
public final class PyRegex {
    public let pattern: String
    let rx: NSRegularExpression

    public struct Match {
        let text: String
        let result: NSTextCheckingResult
        let rx: NSRegularExpression

        public func group(_ i: Int = 0) -> String? {
            let r = result.range(at: i)
            guard r.location != NSNotFound, let rr = Range(r, in: text) else { return nil }
            return String(text[rr])
        }
        public func group(_ name: String) -> String? {
            let r = result.range(withName: name)
            guard r.location != NSNotFound, let rr = Range(r, in: text) else { return nil }
            return String(text[rr])
        }
        /// Python `m.groups()` — 1...n, nil for non-participating groups.
        public func groups() -> [String?] {
            (1...max(1, result.numberOfRanges - 1)).map { group($0) }
        }
        /// Python `m.groupdict()` for named groups.
        public func groupDict(_ names: [String]) -> [String: String] {
            var d: [String: String] = [:]
            for n in names { if let v = group(n) { d[n] = v } }
            return d
        }
        /// UTF-16 offset of the match start/end (Python m.start()/m.end() analog).
        public var start: Int { result.range.location }
        public var end: Int { result.range.location + result.range.length }
    }

    public init(_ pattern: String, ignoreCase: Bool = false) {
        self.pattern = pattern
        let icu = pattern.replacingOccurrences(of: "(?P<", with: "(?<")
        var opts: NSRegularExpression.Options = []
        if ignoreCase { opts.insert(.caseInsensitive) }
        // Parsers only use valid patterns; a crash here is a port bug we want loud.
        self.rx = try! NSRegularExpression(pattern: icu, options: opts)
    }

    /// re.search — first match anywhere.
    public func search(_ s: String) -> Match? {
        let ns = NSRange(s.startIndex..., in: s)
        guard let m = rx.firstMatch(in: s, options: [], range: ns) else { return nil }
        return Match(text: s, result: m, rx: rx)
    }

    /// re.match — anchored at the start.
    public func match(_ s: String) -> Match? {
        let ns = NSRange(s.startIndex..., in: s)
        guard let m = rx.firstMatch(in: s, options: [.anchored], range: ns) else { return nil }
        return Match(text: s, result: m, rx: rx)
    }

    /// re.fullmatch — must consume the whole string.
    public func fullmatch(_ s: String) -> Match? {
        guard let m = match(s) else { return nil }
        return m.end == (s as NSString).length ? m : nil
    }

    /// re.sub — replacement is a LITERAL string (no backrefs needed by the port
    /// unless template=true, in which case $1-style templates are honored).
    public func sub(_ replacement: String, _ s: String, template: Bool = false) -> String {
        let ns = NSRange(s.startIndex..., in: s)
        let tmpl = template ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        return rx.stringByReplacingMatches(in: s, options: [], range: ns, withTemplate: tmpl)
    }

    /// re.split with maxsplit.
    public func split(_ s: String, maxsplit: Int = 0) -> [String] {
        let ns = NSRange(s.startIndex..., in: s)
        var parts: [String] = []
        var last = 0
        var count = 0
        let nss = s as NSString
        for m in rx.matches(in: s, options: [], range: ns) {
            if maxsplit > 0 && count >= maxsplit { break }
            let r = m.range
            parts.append(nss.substring(with: NSRange(location: last, length: r.location - last)))
            last = r.location + r.length
            count += 1
        }
        parts.append(nss.substring(from: last))
        return parts
    }

    /// re.findall for zero/one-group patterns (returns whole match or group 1).
    public func findall(_ s: String) -> [String] {
        let ns = NSRange(s.startIndex..., in: s)
        let nss = s as NSString
        return rx.matches(in: s, options: [], range: ns).map { m in
            let r = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range
            return nss.substring(with: r)
        }
    }

    /// re.finditer.
    public func finditer(_ s: String) -> [Match] {
        let ns = NSRange(s.startIndex..., in: s)
        return rx.matches(in: s, options: [], range: ns).map { Match(text: s, result: $0, rx: rx) }
    }

    /// Count of matches (used for `len(re.findall(...))`).
    public func count(_ s: String) -> Int {
        let ns = NSRange(s.startIndex..., in: s)
        return rx.numberOfMatches(in: s, options: [], range: ns)
    }

    public static func escape(_ s: String) -> String {
        NSRegularExpression.escapedPattern(for: s)
    }
}
