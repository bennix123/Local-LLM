// Classify — merchant + category assignment. Port of _classify(),
// _is_personish(), _slug_name() and _barclays_merchant() from parsers.py.
import Foundation

enum Classify {
    static let personRe = PyRegex("(?:[A-Z][a-z]+|[A-Z]{2,})(?: (?:[A-Z][a-z]+|[A-Z]{2,}|[A-Z]))*$")
    static let bizSuffix: Set<String> = ["ltd", "limited", "pvt", "llp", "store", "stores",
        "traders", "enterprises", "retail", "services", "solutions", "mart", "shop", "foods",
        "restaurant", "cafe", "hotel", "motors", "agencies", "company", "co", "corp", "inc",
        "technologies", "tech", "industries", "works", "supermarket", "pharmacy", "clinic",
        "hospital", "generation"]

    /// _slug_name(): best-effort payee name from a raw description.
    static func slugName(_ descr: String) -> String {
        let p = Describe.payeeFromSlug(descr)
        return !p.isEmpty ? p : descr.pyStrip().pyPrefix(40)
    }

    /// _is_personish(): does the name look like an individual (2-3 words)?
    static func isPersonish(_ name: String) -> Bool {
        let n = name.pyStrip()
        if n.isEmpty || n.contains(where: { $0.isNumber }) { return false }
        let words = n.pySplit()
        if !(2...3).contains(words.count) || bizSuffix.contains(words.last!.pyLower()) {
            return false
        }
        return personRe.fullmatch(n) != nil
    }

    /// _classify(): (merchant, category) for a non-UK description.
    static func classify(_ descr: String, isCredit: Bool, categories: Categories) -> (String, String) {
        let noVpa = PyRegex("@\\S+").sub("", descr).replacingOccurrences(of: "_", with: " ")
        let clean = Describe.leadingSnoDate.sub("", noVpa)
        var name: String? = nil
        var cat: String? = nil
        for rule in categories.merchantRules {
            if rule.pattern.search(clean) != nil {
                name = rule.name
                cat = rule.category
                break
            }
        }
        if cat == nil {
            name = slugName(clean)
            cat = categories.keywordCategory(clean, isCredit: isCredit)
            if cat == "Other", Describe.slugRe.search(clean) != nil, isPersonish(name!) {
                cat = "Transfers"
            }
        }
        if cat == "Income", !isCredit {
            cat = PyRegex("\\btransfer\\b", ignoreCase: true).search(clean) != nil ? "Transfers" : "Other"
        }
        return (name ?? "", cat ?? "Other")
    }

    /// _barclays_merchant(): counterparty + category from a UK narrative line.
    static func barclaysMerchant(_ descr: String, isCredit: Bool, categories: Categories) -> (String, String) {
        let m = PyRegex("(?:Card Payment to|Payment to|Direct Debit to|Standing Order to|Bill Payment to|" +
                        "Transfer to|Faster Payment to|Received From|Paid In(?: from)?|From|to)\\s+(.+)",
                        ignoreCase: true).search(descr)
        var name = m?.group(1) ?? descr
        name = PyRegex("\\s+(?:On\\s+\\d|Ref:|Ref\\b|on\\s+\\d)").split(name, maxsplit: 1)[0]
        name = PyRegex("\\s{2,}").sub(" ", name).pyStrip(" -:")
        var cat = categories.keywordCategory(PyRegex("@\\S+").sub("", descr), isCredit: isCredit)
        if cat == "Income", !isCredit {
            cat = PyRegex("\\btransfer\\b", ignoreCase: true).search(descr) != nil ? "Transfers" : "Other"
        }
        let name60 = name.pyPrefix(60)
        let finalName = !name60.isEmpty ? name60 : (isCredit ? "Income" : "Other")
        return (finalName, cat)
    }
}
