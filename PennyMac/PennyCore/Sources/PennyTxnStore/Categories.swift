// Categories — deterministic categorization from contract/categories.json.
// Port of the MERCHANT_MAP/_CATEGORY_RULES loading + keyword_category() in
// parsers.py. Order matters: the merchant map is first-match-wins in the JSON
// file's key order (Python dicts preserve insertion order), so the file is
// scanned textually rather than through an order-losing JSON dictionary.
import Foundation

public final class Categories {
    public struct MerchantRule {
        let pattern: PyRegex     // leading word boundary, case-insensitive
        let name: String
        let category: String
    }
    public struct CategoryRule {
        let category: String
        let pattern: PyRegex     // \b(?:t1|t2|...) case-insensitive
    }

    public let merchantRules: [MerchantRule]
    public let categoryRules: [CategoryRule]

    public init(categoriesJSONPath: String) throws {
        // Read the bytes once and derive both the text scan and the JSON from the
        // same snapshot: the cached copy is refreshed with an atomic replace, so a
        // read-twice could otherwise pair one file version's key order with
        // another's values.
        let data = try Data(contentsOf: URL(fileURLWithPath: categoriesJSONPath))
        let raw = String(decoding: data, as: UTF8.self)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        // merchant_map: {"token": ["Name", "Category"], ...} — preserve file order
        // by scanning key positions textually, values via JSONSerialization.
        let mm = obj["merchant_map"] as? [String: [String]] ?? [:]
        var ordered: [(String, String, String)] = []
        if let mmRange = raw.range(of: "\"merchant_map\"") {
            // The merchant_map object spans from here to the next top-level key
            // ("category_rules") or end-of-text. Crucially, "category_rules" can
            // come *before* "merchant_map": the cached copy is written from an
            // unordered dictionary via JSONSerialization, which does not preserve
            // key order. So only treat it as the section end when it actually
            // follows merchant_map — searching within the text *after* merchant_map.
            // (Slicing raw[mmRange.upperBound..<rulesRange.lowerBound] with a
            // category_rules that precedes merchant_map forms an inverted Range and
            // traps — the source of the intermittent import crash.)
            let afterMM = raw[mmRange.upperBound...]
            let section: Substring
            if let rulesRange = afterMM.range(of: "\"category_rules\"") {
                section = afterMM[..<rulesRange.lowerBound]
            } else {
                section = afterMM
            }
            let keyRx = PyRegex("\"((?:[^\"\\\\]|\\\\.)*)\"\\s*:")
            for m in keyRx.finditer(String(section)) {
                if let key = m.group(1), let val = mm[key], val.count == 2 {
                    ordered.append((key, val[0], val[1]))
                }
            }
        }
        // Compile with the non-trapping `safe` path and drop any rule whose pattern
        // won't compile: this vocabulary comes from the central categories server,
        // so one malformed token must skip that rule, never crash statement import.
        merchantRules = ordered.compactMap { (tok, name, cat) in
            let pat = "\\b" + PyRegex.escape(tok.replacingOccurrences(of: "_", with: " "))
            guard let rx = PyRegex.safe(pat, ignoreCase: true) else { return nil }
            return MerchantRule(pattern: rx, name: name, category: cat)
        }

        // category_rules: [["Category", ["t1", "t2", ...]], ...] — array order kept.
        let cr = obj["category_rules"] as? [[Any]] ?? []
        categoryRules = cr.compactMap { entry -> CategoryRule? in
            guard entry.count == 2, let cat = entry[0] as? String,
                  let terms = entry[1] as? [String], !terms.isEmpty else { return nil }
            let alt = terms.map { PyRegex.escape($0) }.joined(separator: "|")
            guard let rx = PyRegex.safe("\\b(?:" + alt + ")", ignoreCase: true) else { return nil }
            return CategoryRule(category: cat, pattern: rx)
        }
    }

    /// Full deterministic categorisation for a merchant/description string —
    /// merchant-map rules first (first-match-wins, file order), then the
    /// keyword rules. Mirrors the core of `Classify.classify` for clean merchant
    /// names (without the UPI/slug person-detection used for messy narrations).
    public func categorize(_ text: String, isCredit: Bool = false) -> String {
        for rule in merchantRules where rule.pattern.search(text) != nil {
            return rule.category
        }
        return keywordCategory(text, isCredit: isCredit)
    }

    /// keyword_category(): deterministic category from a description string.
    public func keywordCategory(_ text: String, isCredit: Bool = false) -> String {
        let low = text.replacingOccurrences(of: "_", with: " ")
        for rule in categoryRules {
            if rule.pattern.search(low) != nil { return rule.category }
        }
        return isCredit ? "Income" : "Other"
    }
}
