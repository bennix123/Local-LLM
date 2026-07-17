// BankParsers — dedicated parsers: DR/CR row layout (parse_pdf), Barclays
// positional, PNB, Wrenfield — ported from parsers.py.
import Foundation

enum BankParsers {
    static let rowRe = PyRegex(
        "^(\\d{2}-\\d{2}-\\d{4})\\s{2,}(\\S.*?)\\s{2,}(DR|CR)\\s+(-?[\\d,]+\\.\\d{2})\\s+(-?[\\d,]+\\.\\d{2})\\s*$")

    // ---- format detectors (run on the head text)

    static func isTransactionStatement(_ text: String) -> Bool {
        let sample = text.pyPrefix(20000)
        let rows = sample.pySplitLines().filter { rowRe.match($0) != nil }.count
        let hasCols = PyRegex("\\bDebit\\b.*\\bCredit\\b.*\\bBalance\\b", ignoreCase: true).search(sample) != nil
        return rows >= 5 || (hasCols && rows >= 1)
    }

    static func isBarclays(_ text: String) -> Bool {
        let low = text.pyLower()
        return low.pyContains("barclays") && (low.pyContains("money out") || low.pyContains("sort code")
                                              || low.pyContains("current account statement"))
    }

    static func isPNB(_ text: String) -> Bool {
        let low = text.pyLower()
        return low.pyContains("pnb") && low.pyContains("particulars")
            && (low.pyContains("withdrawal") || low.pyContains("deposit"))
    }

    static func isWrenfield(_ text: String) -> Bool {
        let low = text.pyLower()
        return low.pyContains("wrenfield") && low.pyContains("outgoings") && low.pyContains("incomings")
    }

    // ---- parse_pdf: DD-MM-YYYY + DR/CR + balance rows

    static func parsePDF(_ doc: PDFTextExtractor, categories: Categories) -> [TxnRow] {
        var out: [TxnRow] = []
        var seq = 0
        for pageIdx in 0..<doc.pageCount {
            guard let page = doc.page(pageIdx) else { continue }
            for line in page.text.pySplitLines() {
                guard let m = rowRe.match(line) else { continue }
                let d = m.group(1)!, descr = m.group(2)!, drcr = m.group(3)!
                let amount = m.group(4)!, balance = m.group(5)!
                let yyyy = d.pySlice(6, 10), mm = d.pySlice(3, 5), dd = d.pySlice(0, 2)
                let iso = "\(yyyy)-\(mm)-\(dd)"
                let (merchant, category) = Classify.classify(descr, isCredit: drcr == "CR",
                                                             categories: categories)
                let amt = money(amount)
                seq += 1
                out.append(TxnRow(txnDate: iso, month: iso.pyPrefix(7),
                                  year: Int(yyyy)!, monthNo: Int(mm)!, day: Int(dd)!,
                                  descr: descr, merchant: merchant, category: category,
                                  debit: drcr == "DR" ? amt : 0.0,
                                  credit: drcr == "CR" ? amt : 0.0,
                                  balance: money(balance), currency: "INR", seq: seq))
            }
        }
        return out
    }

    // ---- Barclays positional parser

    static let barclaysAmt = PyRegex("^-?[\\d,]+\\.\\d{2}$")
    static let barclaysMonRe = "(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*"

    /// _barclays_end_anchor(): (end_month, end_year) fallback resolution.
    static func barclaysEndAnchor(_ full: String, pdfPath: String) -> (Int, Int) {
        let M = barclaysMonRe
        if let m = PyRegex("(?:to|through|[-–—])\\s*(?:\\d{1,2}\\s+)?" + M + "\\.?\\s+(\\d{4})",
                           ignoreCase: true).search(full) {
            let mon = DateParse.monTitle[m.group(1)!.pyPrefix(3).pyTitle()]!
            return (mon, Int(m.group(2)!)!)
        }
        let base = (pdfPath as NSString).lastPathComponent
        if let fm = PyRegex("(\\d{1,2})-([A-Za-z]{3})-(\\d{2})\\b").search(base),
           let mon = DateParse.monTitle[fm.group(2)!.pyTitle()] {
            return (mon, 2000 + Int(fm.group(3)!)!)
        }
        if let m = PyRegex("\\b(?:\\d{1,2}\\s+)?" + M + "\\.?\\s+(\\d{4})", ignoreCase: true).search(full) {
            let mon = DateParse.monTitle[m.group(1)!.pyPrefix(3).pyTitle()]!
            return (mon, Int(m.group(2)!)!)
        }
        return (0, 0)
    }

    static func parseBarclays(_ doc: PDFTextExtractor, pdfPath: String,
                              categories: Categories) -> [TxnRow] {
        var full = ""
        for i in 0..<doc.pageCount { full += doc.page(i)?.text ?? "" }

        var em = 0, ey = 0
        if let pm = PyRegex("(\\d{1,2})\\s+([A-Z][a-z]{2})\\s*[-–]\\s*(\\d{1,2})\\s+([A-Z][a-z]{2})\\s+(\\d{4})")
            .search(full) {
            em = DateParse.monTitle[pm.group(4)!] ?? 0
            ey = Int(pm.group(5)!)!
        } else {
            (em, ey) = barclaysEndAnchor(full, pdfPath: pdfPath)
        }

        func yearFor(_ mon: Int) -> Int {
            if ey == 0 { return 0 }
            return mon <= em ? ey : ey - 1
        }

        struct Pending {
            var date: (Int, Int)?    // (day, month)
            var desc: String
            var out: Double?
            var inn: Double?
            var bal: Double?
        }

        var curDate: (Int, Int)? = nil
        var cur: Pending? = nil
        var started = false, done = false
        var pending: [Pending] = []

        for pageIdx in 0..<doc.pageCount {
            guard let page = doc.page(pageIdx) else { continue }
            var lines: [Int: [(Double, String)]] = [:]
            for w in page.words {
                lines[pyRound(w.y0 / 3.0), default: []].append((w.x0, w.text))
            }
            for k in lines.keys.sorted() {
                let row = lines[k]!.sorted { a, b in
                    a.0 != b.0 ? a.0 < b.0 : pyStringLess(a.1, b.1)
                }
                let dcol = row.filter { $0.0 < 90 }.map { $0.1 }
                let desc = row.filter { $0.0 >= 90 && $0.0 < 268 }.map { $0.1 }
                let ocol = row.filter { $0.0 >= 268 && $0.0 < 312 }.map { $0.1 }
                let icol = row.filter { $0.0 >= 312 && $0.0 < 372 }.map { $0.1 }
                let bcol = row.filter { $0.0 >= 372 }.map { $0.1 }
                let day = dcol.first { PyRegex("\\d{1,2}").fullmatch($0) != nil }
                let mon = dcol.first { DateParse.monTitle[$0] != nil }
                if let day, let mon {
                    curDate = (Int(day)!, DateParse.monTitle[mon]!)
                }
                let dtext = desc.joined(separator: " ").pyStrip()
                let out = ocol.first { barclaysAmt.match($0) != nil }.map { money($0) }
                let inn = icol.first { barclaysAmt.match($0) != nil }.map { money($0) }
                let bal = bcol.first { barclaysAmt.match($0) != nil }.map { money($0) }
                if PyRegex("start balance", ignoreCase: true).search(dtext) != nil {
                    started = true
                    continue
                }
                if PyRegex("end balance", ignoreCase: true).search(dtext) != nil {
                    if let c = cur { pending.append(c); cur = nil }
                    done = true
                    break
                }
                if !started || done { continue }
                if out != nil || inn != nil {
                    if let c = cur { pending.append(c) }
                    cur = Pending(date: curDate, desc: dtext, out: out, inn: inn, bal: bal)
                } else if !dtext.isEmpty, cur != nil {
                    cur!.desc = (cur!.desc + " " + dtext).pyStrip()
                }
            }
            if done { break }
        }
        if let c = cur { pending.append(c) }

        var rows: [TxnRow] = []
        var seq = 0
        for c in pending {
            guard let (dd, mm) = c.date else { continue }
            let yr = yearFor(mm)
            let iso = String(format: "%04d-%02d-%02d", yr, mm, dd)
            let out = c.out ?? 0.0
            let inn = c.inn ?? 0.0
            let (merchant, category) = Classify.barclaysMerchant(c.desc, isCredit: inn > 0,
                                                                 categories: categories)
            seq += 1
            rows.append(TxnRow(txnDate: iso, month: iso.pyPrefix(7), year: yr, monthNo: mm, day: dd,
                               descr: c.desc.pyPrefix(200), merchant: merchant, category: category,
                               debit: out, credit: inn, balance: c.bal, currency: "GBP", seq: seq))
        }
        return rows
    }

    // ---- PNB parser

    static func parsePNB(_ doc: PDFTextExtractor, categories: Categories) -> [TxnRow] {
        var lines: [String] = []
        for i in 0..<doc.pageCount {
            lines.append(contentsOf: (doc.page(i)?.text ?? "").pySplitLines())
        }
        let dateRe = PyRegex("^(\\d{2})-([A-Za-z]{3})-(\\d{4})$")
        let balRe = PyRegex("^(-?[\\d,]+\\.\\d{2})(CR|DR)\\.?$", ignoreCase: true)

        var out: [TxnRow] = []
        var seq = 0
        var runningBalance = 0.0
        var i = 0
        while i < lines.count {
            let line = lines[i].pyStrip()

            if line.pyLower().pyContains("opening balance"), i + 1 < lines.count {
                let nxt = lines[i + 1].pyStrip()
                if let bm = balRe.match(nxt) {
                    var rb = money(bm.group(1)!)
                    if bm.group(2)!.pyUpper() == "DR" { rb = -rb }
                    runningBalance = rb
                }
            }

            if let dm = dateRe.match(line) {
                let day = Int(dm.group(1)!)!
                let monthNo = DateParse.monTitle[dm.group(2)!.pyPrefix(3).pyTitle()] ?? 1
                let year = Int(dm.group(3)!)!
                let iso = String(format: "%04d-%02d-%02d", year, monthNo, day)

                var descParts: [String] = []
                var amountStr: String? = nil
                var balanceStr: String? = nil
                var j = i + 1
                while j < lines.count {
                    let nextLine = lines[j].pyStrip()
                    if dateRe.match(nextLine) != nil { break }
                    if balRe.match(nextLine) != nil {
                        balanceStr = nextLine
                        if !descParts.isEmpty { amountStr = descParts.removeLast() }
                        break
                    } else {
                        descParts.append(nextLine)
                    }
                    j += 1
                }

                if let amountStr, let balanceStr {
                    var desc = descParts.joined(separator: " ").pyStrip()
                    desc = PyRegex("\\s+").sub(" ", desc)
                    let amt = money(amountStr)
                    let bm = balRe.match(balanceStr)!
                    var curBal = money(bm.group(1)!)
                    if bm.group(2)!.pyUpper() == "DR" { curBal = -curBal }

                    let diff = curBal - runningBalance
                    var isCredit = false
                    if abs(diff - amt) < 0.01 {
                        isCredit = true
                    } else if abs(diff + amt) < 0.01 {
                        isCredit = false
                    } else {
                        isCredit = desc.pyContains("/CR/") || balanceStr.pyContains("CR.")
                                || desc.pyContains("INTT.")
                    }

                    let (merchant, category) = Classify.classify(desc, isCredit: isCredit,
                                                                 categories: categories)
                    seq += 1
                    out.append(TxnRow(txnDate: iso, month: iso.pyPrefix(7), year: year,
                                      monthNo: monthNo, day: day, descr: desc,
                                      merchant: merchant, category: category,
                                      debit: isCredit ? 0.0 : amt, credit: isCredit ? amt : 0.0,
                                      balance: curBal, currency: "INR", seq: seq))
                    runningBalance = curBal
                    i = j
                } else {
                    i += 1
                }
            } else {
                i += 1
            }
        }
        return out
    }

    // ---- Wrenfield parser

    static func parseWrenfield(_ doc: PDFTextExtractor, categories: Categories) -> [TxnRow] {
        var lines: [String] = []
        for i in 0..<doc.pageCount {
            lines.append(contentsOf: (doc.page(i)?.text ?? "").pySplitLines())
        }
        let dateRe = PyRegex("^(\\d{2})/(\\d{2})/(\\d{4})$")
        let numRe = PyRegex("^-?[\\d,]+\\.\\d{2}$")

        var out: [TxnRow] = []
        var seq = 0
        var i = 0
        while i < lines.count {
            let line = lines[i].pyStrip()
            if let dm = dateRe.match(line) {
                let day = Int(dm.group(1)!)!
                let monthNo = Int(dm.group(2)!)!
                let year = Int(dm.group(3)!)!
                let iso = String(format: "%04d-%02d-%02d", year, monthNo, day)

                var descParts: [String] = []
                var amountStr: String? = nil
                var balanceStr: String? = nil
                var j = i + 1
                while j < lines.count {
                    let nextLine = lines[j].pyStrip()
                    if dateRe.match(nextLine) != nil { break }
                    if numRe.match(nextLine) != nil,
                       j + 1 < lines.count, numRe.match(lines[j + 1].pyStrip()) != nil {
                        amountStr = nextLine
                        balanceStr = lines[j + 1].pyStrip()
                        j += 2
                        break
                    }
                    descParts.append(nextLine)
                    j += 1
                }

                if let amountStr, let balanceStr {
                    var desc = descParts.joined(separator: " ")
                    desc = PyRegex("Wrenfield Bank\\s*?\\s*Statement\\s*?\\s*Page \\d+ of \\d+").sub("", desc)
                    desc = PyRegex("Date\\s+Description\\s+\\(GBP\\)\\s+Amount\\s+\\(GBP\\)\\s+Balance").sub("", desc)
                    desc = PyRegex("\\s+").sub(" ", desc).pyStrip()

                    let amt = money(amountStr)
                    let bal = money(balanceStr)
                    let debit: Double, credit: Double
                    if amountStr.hasPrefix("-") {
                        debit = abs(amt); credit = 0.0
                    } else {
                        debit = 0.0; credit = amt
                    }
                    let (merchant, category) = Classify.barclaysMerchant(desc, isCredit: credit > 0,
                                                                         categories: categories)
                    seq += 1
                    out.append(TxnRow(txnDate: iso, month: iso.pyPrefix(7), year: year,
                                      monthNo: monthNo, day: day, descr: desc,
                                      merchant: merchant, category: category,
                                      debit: debit, credit: credit, balance: bal,
                                      currency: "GBP", seq: seq))
                    i = j
                } else {
                    i += 1
                }
            } else {
                i += 1
            }
        }
        return out
    }
}

/// Python string comparison (code-point lexicographic) for tuple sorts.
func pyStringLess(_ a: String, _ b: String) -> Bool {
    let au = Array(a.unicodeScalars), bu = Array(b.unicodeScalars)
    for i in 0..<min(au.count, bu.count) {
        if au[i].value != bu[i].value { return au[i].value < bu[i].value }
    }
    return au.count < bu.count
}

extension String {
    /// Python s[a:b] by characters.
    func pySlice(_ a: Int, _ b: Int) -> String {
        let chars = Array(self)
        let lo = max(0, min(a, chars.count)), hi = max(lo, min(b, chars.count))
        return String(chars[lo..<hi])
    }
}
