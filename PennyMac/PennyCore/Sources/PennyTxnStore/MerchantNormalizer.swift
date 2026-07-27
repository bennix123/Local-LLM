// MerchantNormalizer — raw card-statement descriptor → clean display name.
//
// Card acquirers prepend their own tags ("DOJO*", "TST-", "NAYAXAU*"), banks
// append the transaction city ("… LONDON"), and gateways bolt on domains/refs
// ("APPLE.COM/BILL HOLLYHILL", "AMAZON PRIME*227DM1GO5"). This turns those into
// the name a person recognises — "The Craft Beer Co", "Apple", "Amazon Prime".
//
// It is a DISPLAY helper only: it never changes a transaction's parsed
// description or category (those are contract-locked). Callers in the UI / graph
// layer opt in; the deterministic parser output is untouched.
import Foundation

public enum MerchantNormalizer {

    /// Best-effort human-readable merchant name for `raw` (a transaction
    /// description). Known merchants resolve through the alias table; everything
    /// else goes through a generic clean-up (strip acquirer prefix, leading
    /// reference, domains, trailing city, ref codes) and is title-cased.
    public static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let low = trimmed.lowercased()

        // 1) Alias table — first match wins (order matters: "amazon prime"
        //    before "amazon", "prime video" before both).
        for (pattern, name) in aliases where regexHit(low, pattern) {
            return name
        }

        // 2) Generic clean-up.
        return generic(trimmed)
    }

    // MARK: - Alias table

    private static let aliases: [(String, String)] = [
        (#"payment received"#, "Payment Received"),
        (#"\btfl\b|tfl\.gov\.uk"#, "TFL"),
        (#"amazon prime"#, "Amazon Prime"),
        (#"prime ?video|primevideo"#, "Amazon Prime Video"),
        (#"\bamazon\b|\bamzn\b"#, "Amazon"),
        (#"apple\.com|itunes"#, "Apple"),
        (#"\blime\b"#, "Lime"),
        (#"care ?dental"#, "Care Dental Platinum"),
        (#"kati roll"#, "The Kati Roll Company"),
        (#"craft beer"#, "The Craft Beer Co"),
        (#"\bbeehive\b"#, "Beehive"),
        (#"kings arms"#, "Kings Arms"),
        (#"tamesis dock"#, "Tamesis Dock"),
        (#"litli dubliner"#, "Litli Dubliner"),
        (#"\bforest\b"#, "Forest"),
        (#"\blokal\b"#, "Lokal"),
        (#"\bpret\b"#, "Pret A Manger"),
        (#"deliveroo"#, "Deliveroo"),
        (#"just ?eat"#, "Just Eat"),
        (#"uber ?eats"#, "Uber Eats"),
        (#"\buber\b"#, "Uber"),
        (#"\bbolt\b"#, "Bolt"),
        (#"free ?now"#, "FREE NOW"),
        (#"citymapper"#, "Citymapper"),
        (#"trainline"#, "Trainline"),
        (#"londis"#, "Londis"),
        (#"netflix"#, "Netflix"),
        (#"spotify"#, "Spotify"),
    ]

    // MARK: - Generic clean-up

    /// UK cities / large towns that banks append as the transaction location.
    /// Districts (Soho, Hammersmith) are deliberately NOT here — only the trailing
    /// *city* token is stripped, so "Latymers - Hammersmith London" keeps
    /// "Hammersmith" and drops "London".
    private static let cities: Set<String> = [
        "LONDON", "WESTMINSTER", "HOUNSLOW", "CRAWLEY", "REYKJAVIK", "HOLLYHILL",
        "MANCHESTER", "BIRMINGHAM", "LEEDS", "GLASGOW", "EDINBURGH", "BRIGHTON",
        "LIVERPOOL", "BRISTOL", "SHEFFIELD", "CARDIFF", "NOTTINGHAM", "LEICESTER",
        "COVENTRY", "READING", "CROYDON", "WATFORD", "SLOUGH", "LUTON", "ILFORD",
        "ROMFORD", "HARROW", "WEMBLEY", "GREENFORD", "SOUTHALL", "UXBRIDGE",
    ]

    private static func generic(_ input: String) -> String {
        var s = input
        // a) acquirer star-prefix: "DOJO*", "NAYAXAU*", "TEYA*", "SUMUP*"
        s = replaceFirst(s, #"^\s*[A-Za-z0-9]{2,}\*\s*"#, "")
        // b) known hyphen acquirer tags: "TST-", "IZ-", "SQ-", "ZTL-"
        s = replaceFirst(s, #"^(?i:tst|izettle|iz|sq|ztl|sumup)-\s*"#, "")
        // c) leading numeric reference: "3500728 Kings Arms" → "Kings Arms"
        s = replaceFirst(s, #"^\d{3,}\s+"#, "")

        // Tokenise; drop domain tokens and trailing city / reference tokens.
        var toks = s.split(separator: " ").map(String.init)
            .filter { !isDomain($0) }
        // trailing city tokens (repeat) then a trailing all-caps ref code
        while let last = toks.last, cities.contains(last.uppercased()) { toks.removeLast() }
        while let last = toks.last, isRefCode(last) { toks.removeLast() }
        // trailing single stray letters left by truncation ("… FRA")
        if toks.count > 1, let last = toks.last, last.count <= 3, last == last.uppercased(),
           !last.contains(where: \.isLowercase) { toks.removeLast() }

        let cleaned = toks.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -:/.,"))
        let out = Describe.niceCase(cleaned)
        // Fallback: if we stripped everything, title-case the original first word.
        if out.replacingOccurrences(of: " ", with: "").count < 2 {
            return Describe.niceCase(input.split(separator: " ").first.map(String.init) ?? input)
        }
        return out
    }

    /// A token that is a domain / URL fragment ("tfl.gov.uk/cp", "amzn.co.uk/pm").
    private static func isDomain(_ t: String) -> Bool {
        regexHit(t.lowercased(), #"\.(?:com|co|gov|org|net|io|uk)\b|/"#)
    }

    /// A reference code: uppercase alphanumerics containing a digit, or a long
    /// hyphenated number ("227DM1GO5", "353-12477661", "DXIZ" stays as it has no digit).
    private static func isRefCode(_ t: String) -> Bool {
        if regexHit(t, #"^[A-Z0-9]{4,}$"#) && t.contains(where: \.isNumber) { return true }
        if regexHit(t, #"^\d[\d-]{4,}$"#) { return true }
        return false
    }

    // MARK: - Regex helpers

    private static func regexHit(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression]) != nil
    }

    private static func replaceFirst(_ s: String, _ pattern: String, _ repl: String) -> String {
        guard let r = s.range(of: pattern, options: [.regularExpression]) else { return s }
        return s.replacingCharacters(in: r, with: repl)
    }
}
