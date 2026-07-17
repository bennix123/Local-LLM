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
        let raw = try String(contentsOfFile: categoriesJSONPath, encoding: .utf8)
        let data = try Data(contentsOf: URL(fileURLWithPath: categoriesJSONPath))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        // merchant_map: {"token": ["Name", "Category"], ...} — preserve file order
        // by scanning key positions textually, values via JSONSerialization.
        let mm = obj["merchant_map"] as? [String: [String]] ?? [:]
        var ordered: [(String, String, String)] = []
        if let mmRange = raw.range(of: "\"merchant_map\"") {
            let section: Substring
            if let rulesRange = raw.range(of: "\"category_rules\"") {
                section = raw[mmRange.upperBound..<rulesRange.lowerBound]
            } else {
                section = raw[mmRange.upperBound...]
            }
            let keyRx = PyRegex("\"((?:[^\"\\\\]|\\\\.)*)\"\\s*:")
            for m in keyRx.finditer(String(section)) {
                if let key = m.group(1), let val = mm[key], val.count == 2 {
                    ordered.append((key, val[0], val[1]))
                }
            }
        }
        merchantRules = ordered.map { (tok, name, cat) in
            let pat = "\\b" + PyRegex.escape(tok.replacingOccurrences(of: "_", with: " "))
            return MerchantRule(pattern: PyRegex(pat, ignoreCase: true), name: name, category: cat)
        }

        // category_rules: [["Category", ["t1", "t2", ...]], ...] — array order kept.
        let cr = obj["category_rules"] as? [[Any]] ?? []
        categoryRules = cr.compactMap { entry in
            guard entry.count == 2, let cat = entry[0] as? String,
                  let terms = entry[1] as? [String], !terms.isEmpty else { return nil }
            let alt = terms.map { PyRegex.escape($0) }.joined(separator: "|")
            return CategoryRule(category: cat, pattern: PyRegex("\\b(?:" + alt + ")", ignoreCase: true))
        }
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
