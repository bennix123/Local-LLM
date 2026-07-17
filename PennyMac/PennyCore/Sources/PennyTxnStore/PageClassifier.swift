// PageClassifier — classify_page() / find_table_start_page() from parsers.py.
import Foundation

enum PageClassifier {
    static let dateDensityRe = PyRegex(
        "\\b\\d{1,2}[-/]\\d{1,2}[-/]\\d{2,4}\\b|\\b\\d{4}-\\d{2}-\\d{2}\\b" +
        "|\\b\\d{1,2}[-/ ][A-Za-z]{3}[-/ ]\\d{2,4}\\b", ignoreCase: true)
    static let headerKeywords = PyRegex(
        "\\b(date|narration|particulars|description|debit|credit|withdrawal|deposit|balance|amount|remarks)\\b",
        ignoreCase: true)
    static let summaryRe = PyRegex(
        "\\b(opening balance|closing balance|statement period|total debit|total credit" +
        "|account summary|account holder|branch|ifsc|micr|sort code|account number" +
        "|statement of account|terms|conditions|page \\d+ of \\d+)\\b", ignoreCase: true)
    static let moneyTokenRe = PyRegex("^-?[£$€₹]?[\\d,]+\\.\\d{2}$")
    static let symbolStrip = PyRegex("[£$€₹]")

    /// classify_page(): (label, confidence).
    static func classifyPage(_ pageText: String) -> (String, Double) {
        let lines = pageText.pySplitLines().map { $0.pyStrip() }.filter { !$0.isEmpty }
        if lines.isEmpty { return ("unknown", 0.0) }
        let total = Double(lines.count)

        let dateHits = lines.filter { dateDensityRe.search($0.pyPrefix(30)) != nil }.count
        let dateDensity = Double(dateHits) / total

        let tokens = pageText.pySplit()
        let moneyHits = tokens.filter {
            moneyTokenRe.match(symbolStrip.sub("", $0).pyStrip()) != nil
        }.count
        let numericDensity = min(Double(moneyHits) / Double(max(tokens.count, 1)), 1.0)

        let headerLine = lines.prefix(8).contains { headerKeywords.count($0) >= 3 }
        let hasHeader = headerLine ? 1.0 : 0.0

        // dominant = max(set(tcounts), key=tcounts.count); Python set-of-small-ints
        // iterates ascending, and max() keeps the FIRST maximum — so ties resolve
        // to the smallest token count.
        let tcounts = lines.map { $0.pySplit().count }
        var repRatio = 0.0
        if !tcounts.isEmpty {
            var freq: [Int: Int] = [:]
            for c in tcounts { freq[c, default: 0] += 1 }
            var dominant = 0
            var bestCount = -1
            for value in freq.keys.sorted() {
                if freq[value]! > bestCount {
                    bestCount = freq[value]!
                    dominant = value
                }
            }
            repRatio = Double(tcounts.filter { abs($0 - dominant) <= 2 }.count) / total
        }

        let summaryDensity = Double(lines.filter { summaryRe.search($0) != nil }.count) / total

        let txnScore = dateDensity * 0.30 +
                       numericDensity * 0.20 +
                       hasHeader * 0.25 +
                       repRatio * 0.15 -
                       summaryDensity * 0.25

        if txnScore >= 0.30, dateDensity >= 0.05 {
            return ("transaction_table", min(txnScore, 1.0))
        }
        if summaryDensity >= 0.20 {
            return ("account_summary", summaryDensity)
        }
        if lines.count <= 5 {
            return ("banner", 0.7)
        }
        return ("unknown", 0.0)
    }

    /// find_table_start_page(): first page classified as a transaction table.
    static func findTableStart(_ doc: PDFTextExtractor) -> Int {
        for pageIdx in 0..<doc.pageCount {
            let text = doc.page(pageIdx)?.text ?? ""
            let (label, conf) = classifyPage(text)
            if label == "transaction_table", conf >= 0.20 {
                return pageIdx
            }
        }
        return 0
    }
}
