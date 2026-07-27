// AccountProfile — bank-name extraction from a statement PDF.
// Port of the bank_name portion of nl_sql_engine.extract_account_profile();
// the conformance contract only depends on bank_name.
import Foundation

enum AccountProfile {
    static let fastTrack: [(PyRegex, String)] = [
        (PyRegex("punjab national bank|pnb", ignoreCase: true), "Punjab National Bank"),
        (PyRegex("barclays", ignoreCase: true), "Barclays Bank"),
        (PyRegex("hdfc bank", ignoreCase: true), "HDFC Bank"),
        (PyRegex("state bank of india|sbi\\b", ignoreCase: true), "State Bank of India"),
        (PyRegex("icici bank", ignoreCase: true), "ICICI Bank"),
        (PyRegex("axis bank", ignoreCase: true), "Axis Bank"),
        (PyRegex("wrenfield bank", ignoreCase: true), "Wrenfield Bank"),
        (PyRegex("kotak mahindra", ignoreCase: true), "Kotak Mahindra Bank"),
        (PyRegex("yes bank", ignoreCase: true), "Yes Bank"),
        (PyRegex("bank of baroda", ignoreCase: true), "Bank of Baroda"),
        (PyRegex("canara bank", ignoreCase: true), "Canara Bank"),
        // Full name only: a bare "union bank" also matches "City Union Bank",
        // "Union Bank (UK)", etc. — those must fall through to header/metadata
        // detection and keep their own names.
        (PyRegex("union bank of india", ignoreCase: true), "Union Bank of India"),
    ]

    /// bank_name from the document (first 4 pages of text + metadata + filename).
    static func bankName(doc: PDFTextExtractor, pdfPath: String) -> String? {
        var text = ""
        for i in 0..<min(4, doc.pageCount) {
            text += doc.page(i)?.text ?? ""
        }

        var bankName: String? = nil
        if !text.isEmpty {
            // 1. fast-track popular names
            for (pat, name) in fastTrack {
                if pat.search(text) != nil {
                    bankName = name
                    break
                }
            }
            // 2. document metadata
            if bankName == nil {
                let meta = doc.metadata
                for key in ["author", "creator", "title"] {
                    guard let val = meta[key] else { continue }
                    let valClean = val.pyStrip()
                    if valClean.isEmpty { continue }
                    if PyRegex("\\bbank\\b", ignoreCase: true).search(valClean) != nil,
                       PyRegex("statement|report|doc", ignoreCase: true).search(valClean) == nil {
                        bankName = valClean
                        break
                    }
                }
            }
            // 3. first-page lines
            if bankName == nil, doc.pageCount > 0 {
                let firstPageText = doc.page(0)?.text ?? ""
                let lines = firstPageText.pySplit("\n").map { $0.pyStrip() }.filter { !$0.isEmpty }
                for line in lines.prefix(15) {
                    if PyRegex("\\b(bank|banking|financial|cooperative|credit union)\\b",
                               ignoreCase: true).search(line) != nil {
                        if PyRegex("\\b(statement|account|e-statement|summary|report|period|details?|date)\\b",
                                   ignoreCase: true).search(line) == nil {
                            if line.count < 60 {
                                bankName = line
                                break
                            }
                        }
                    }
                }
            }
        }

        // 4. filename
        if bankName == nil {
            let filename = (pdfPath as NSString).lastPathComponent
            let nameNoExt = (filename as NSString).deletingPathExtension
            let nameSpaced = PyRegex("[-_.]+").sub(" ", nameNoExt).pyStrip()
            if PyRegex("\\bbank\\b", ignoreCase: true).search(nameSpaced) != nil {
                if let m = PyRegex("^(.*?\\bbank\\b)", ignoreCase: true).match(nameSpaced) {
                    bankName = m.group(1)?.pyTitle()
                }
            }
            if bankName == nil {
                bankName = nameSpaced.pyTitle()
            }
        }

        // cleanup: possessive lead-ins + trailing product words
        if var b = bankName {
            b = PyRegex("^(?:your|welcome\\s+to|about)\\s+", ignoreCase: true).sub("", b)
            b = PyRegex("\\s+(?:current\\s+account|savings?\\s+account|account|statement)\\b.*$",
                        ignoreCase: true).sub("", b)
            b = b.pyStrip()
            bankName = b.isEmpty ? nil : b
        }
        return bankName
    }
}
