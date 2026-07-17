// Describe — description cleanup, payee extraction, and category hints.
// Line-for-line port of the top of parsers.py (clean_description,
// _payee_from_slug, _nice_case, hint extraction, _normalize_category).
import Foundation

enum Describe {
    static let txnPrefixRe = PyRegex(
        "^(?:card payment(?: to)?|payment to|direct debit(?: to| payment)?|standing order(?: to)?|" +
        "bill payment(?: to)?|faster payment(?:s)?(?: to)?|transfer to|transfer from|received from|" +
        "paid in(?: from)?)\\s+", ignoreCase: true)
    static let bankCodeRe = PyRegex("^[A-Z]{4}\\d*$")
    static let refRe = PyRegex("^(?:ref|rrn|txn|utr)?\\d+$", ignoreCase: true)
    static let leadingSnoDate = PyRegex("^\\s*\\d+\\s+\\d{1,2}[.\\-/]\\d{1,2}[.\\-/]\\d{2,4}\\s+")

    static let slugSkip: Set<String> = ["upi", "neft", "imps", "rtgs", "ach", "pos", "mmt", "dr",
        "cr", "p2m", "p2a", "p2p", "to", "by", "transfer", "payment", "paid", "received", "from",
        "in", "na", "null", "ref", "sent", "collect", "reversal"]
    static let slugRe = PyRegex("\\b(?:UPI|NEFT|IMPS|RTGS|MMT)\\b", ignoreCase: true)

    /// _nice_case(): title-case SHOUTING words, leave mixed-case alone.
    static func niceCase(_ s: String) -> String {
        s.pySplit().map { w in
            (w.pyIsUpper() && w.count > 1) ? w.pyTitle() : w
        }.joined(separator: " ")
    }

    /// _payee_from_slug(): payee NAME from a UPI/NEFT/IMPS narration.
    static func payeeFromSlug(_ descr: String) -> String {
        for tRaw in PyRegex("[/\\-]").split(descr) {
            let t = tRaw.pyStrip()
            if t.isEmpty || t.contains("@") { continue }
            let words = t.pyLower().pySplit()
            if !words.isEmpty, words.allSatisfy({ slugSkip.contains($0) }) { continue }
            if refRe.match(t) != nil { continue }
            if PyRegex("[A-Za-z]").search(t) != nil {
                return t.replacingOccurrences(of: "_", with: " ").pyStrip()
            }
        }
        return ""
    }

    /// clean_description(): human-readable description for the txn table.
    static func cleanDescription(_ descr: String, merchant: String = "") -> String {
        var s = descr.pyStrip()
        if s.isEmpty { return merchant.pyStrip() }
        s = leadingSnoDate.sub("", s)
        s = PyRegex("^\\d{1,2}[\\s/\\-][A-Za-z]{3,9}[\\s/\\-]\\d{2,4}\\s+").sub("", s)
        s = PyRegex("^\\d{1,2}[/\\-]\\d{1,2}[/\\-]\\d{2,4}\\s+").sub("", s)
        // SBI / net-banking narration: "... INB <purpose>"
        let inb = PyRegex("\\bINB\\b[:\\s]+(.+)$", ignoreCase: true).findall(s)
        if let last = inb.last {
            var purpose = PyRegex("\\b(?:inb|neft|imps|rtgs|upi|transfer|utr\\s*no.*|ref\\b.*|inst)\\b",
                                  ignoreCase: true).sub(" ", last)
            purpose = PyRegex("\\d+").sub(" ", purpose)
            purpose = PyRegex("[^A-Za-z& ]").sub(" ", purpose)
            purpose = PyRegex("\\s{2,}").sub(" ", purpose).pyStrip()
            if purpose.replacingOccurrences(of: " ", with: "").count >= 3 {
                return niceCase(purpose)
            }
        }
        // SBI generic transfer wording
        if let mt = PyRegex("^(BY|TO)\\s+TRANSFER\\b", ignoreCase: true).match(s) {
            let rail = PyRegex("\\b(UPI|IMPS|NEFT|RTGS)\\b", ignoreCase: true).search(s)
            let head = (mt.group(1)!.pyUpper() == "BY") ? "Transfer received" : "Transfer sent"
            if let rail, let r = rail.group(1) {
                return head + " (" + r.pyUpper() + ")"
            }
            return head
        }
        // UPI/NEFT/IMPS narration -> parsed merchant or slug payee
        if slugRe.search(s) != nil, PyRegex("[/\\-]").search(s) != nil {
            let m = merchant.pyStrip()
            let mLow = m.pyLower()
            let badPrefix = ["upi", "neft", "imps", "dr", "cr"].contains { mLow.hasPrefix($0) }
            if !m.isEmpty, !badPrefix, !m.contains("/"), refRe.match(m) == nil {
                return niceCase(m)
            }
            let name = payeeFromSlug(s)
            let fallback = !name.isEmpty ? name : (!m.isEmpty ? m : s)
            return niceCase(fallback)
        }
        s = txnPrefixRe.sub("", s)
        s = PyRegex("^(?:DD|SO|VIS|Debit Card|Card Payment)\\s+", ignoreCase: true).sub("", s)
        s = PyRegex("^(?:POS|ECOM|VPS|MPS|IMPS|NEFT|RTGS)\\s+\\d*\\s*", ignoreCase: true).sub("", s)
        s = PyRegex("\\s+On\\s+\\d.*$", ignoreCase: true).sub("", s)
        s = PyRegex("\\b(?:GBR|GBP|IND|INR|USA|USD|EUR|UK)\\b").sub("", s)
        s = PyRegex("\\bref[:. ].*$", ignoreCase: true).sub("", s)
        s = PyRegex("@\\S+").sub("", s)
        s = PyRegex("\\b\\d{4,}\\b").sub("", s)
        s = PyRegex("\\s{2,}").sub(" ", s).pyStrip(" -:/.,")
        if PyRegex("[^A-Za-z]").sub("", s).count < 2 {
            let alt = !merchant.isEmpty ? merchant : descr
            return niceCase(alt.pyStrip())
        }
        return niceCase(s)
    }

    // ---- category hints stripped from the end of descriptions (ingest_pdf)

    static let hintWords2: Set<String> = ["transfer in", "transfer out", "direct debit",
                                          "standing order", "card payment"]
    static let hintWords1: Set<String> = ["groceries", "grocer", "salary", "income", "transport",
        "travel", "dining", "food", "utilities", "bills", "shopping", "rent", "subscriptions",
        "subscription", "entertainment", "healthcare", "health", "insurance", "pension", "refund",
        "interest", "deposit", "transfer", "outgoings", "incomings", "fees", "fee", "bonus",
        "cash", "fuel"]

    /// _extract_description_category_hint(): (clean_desc, hint?).
    static func extractCategoryHint(_ desc: String) -> (String, String?) {
        if desc.isEmpty { return (desc, nil) }
        let parts = desc.pyRSplit(maxsplit: 2)
        if parts.count >= 3 {
            let twoWords = "\(parts[parts.count - 2]) \(parts[parts.count - 1])".pyStrip().pyStrip(".,()")
            if hintWords2.contains(twoWords.pyLower()) {
                // clean = desc[:desc.lower().rfind(two_words.lower())].strip()
                let low = desc.pyLower()
                if let r = low.range(of: twoWords.pyLower(), options: .backwards) {
                    let idx = low.distance(from: low.startIndex, to: r.lowerBound)
                    let clean = desc.pyPrefix(idx).pyStrip()
                    return (clean, twoWords)
                }
            }
        }
        let parts1 = desc.pyRSplit(maxsplit: 1)
        if parts1.count == 2 {
            let lastWord = parts1[1].pyStrip().pyStrip(".,()")
            if hintWords1.contains(lastWord.pyLower()) {
                return (parts1[0].pyStrip(), lastWord)
            }
        }
        return (desc, nil)
    }

    /// _normalize_category(): map a raw hint to a standard category.
    static func normalizeCategory(_ val: String?) -> String? {
        guard let val, !val.isEmpty else { return nil }
        let vl = val.pyStrip().pyLower()
        func anyIn(_ keys: [String]) -> Bool { keys.contains { vl.pyContains($0) } }
        if anyIn(["dining", "restaurant", "cafe", "food", "eat", "takeaway", "pub", "bar"]) {
            return "Food & Dining"
        }
        if anyIn(["utilities", "gas", "water", "electricity", "bills", "energy", "power", "telecom", "mobile"]) {
            return "Utilities"
        }
        if anyIn(["groceries", "supermarket", "grocery", "sainsbury", "tesco", "waitrose", "m&s", "coop", "stores"]) {
            return "Groceries"
        }
        if anyIn(["transport", "travel", "fuel", "petrol", "train", "bus", "tube", "tfl", "uber", "taxi"]) {
            return "Transport"
        }
        if anyIn(["shopping", "retail", "clothing", "amazon", "argos", "boots", "john lewis", "ebay"]) {
            return "Shopping"
        }
        if anyIn(["subscriptions", "subscription", "entertainment", "netflix", "spotify", "gym", "pure gym", "cinema"]) {
            return "Entertainment"
        }
        if anyIn(["salary", "income", "freelance", "interest", "refund", "dividend", "bonus", "pension"]) {
            return "Income"
        }
        if anyIn(["insurance", "investment", "isa", "savings", "shares", "stocks", "bond"]) {
            return "Investment & Insurance"
        }
        if anyIn(["healthcare", "health", "pharmacy", "doctor", "dentist", "medical"]) {
            return "Healthcare"
        }
        return nil
    }
}
