// GenericParsers — the layered generic fallback from parsers.py:
// Layer 1 rule-based (_parse_generic_columnar + _parse_generic_dateinherited)
// with running-balance validation. Layers 2/3 are LLM-assisted in the Python
// reference; the deterministic contract fixtures never accept their output
// (the expected JSONs were generated with the LLM unavailable), so here they
// are represented by their no-LLM outcome: no result.
import Foundation

enum GenericParsers {
    static let moneyPat = PyRegex("^-?[\\d,]+\\.\\d{2}$")
    static let curSymRe = PyRegex("[₹£$€]")
    static let crdrSufRe = PyRegex("(cr|dr)\\.?$", ignoreCase: true)

    static let RULE_BASED_MAX_VIOLATION_RATIO = 0.10

    // ---- currency sniffing shared by the layers

    static func sniffCurrency(_ head: String, extraGBP: [String] = []) -> String {
        let low = head.pyLower()
        if ["ifsc", "micr", "state bank", "hdfc", "icici", "₹", "rs.", "pnb"].contains(where: { low.pyContains($0) }) {
            return "INR"
        }
        if (["barclays", "sort code", "£", "iban gb", "wrenfield"] + extraGBP).contains(where: { low.pyContains($0) }) {
            return "GBP"
        }
        if ["oman", "muscat", "omr"].contains(where: { low.pyContains($0) }) {
            return "OMR"
        }
        if ["chase", "routing", "$"].contains(where: { low.pyContains($0) }) {
            return "USD"
        }
        return ""
    }

    static func headText(_ doc: PDFTextExtractor, from startPage: Int, pages: Int = 3) -> String {
        var head = ""
        for i in startPage..<min(startPage + pages, doc.pageCount) {
            head += doc.page(i)?.text ?? ""
        }
        return head
    }

    // ---- _parse_generic_columnar

    static func parseGenericColumnar(_ doc: PDFTextExtractor, categories: Categories) -> [TxnRow] {
        let startPage = PageClassifier.findTableStart(doc)
        let head = headText(doc, from: startPage)
        let localCur = sniffCurrency(head)

        struct RawRow {
            var dateVal: (Int, Int, Int)
            var moneyTokens: [(Int, String)]
            var desc: String
        }
        var rawRows: [RawRow] = []

        for pageIdx in startPage..<doc.pageCount {
            guard let page = doc.page(pageIdx) else { continue }
            var lines: [Int: [(Double, String)]] = [:]
            for w in page.words {
                lines[pyRound(w.y0 / 2.0) * 2, default: []].append((w.x0, w.text))
            }
            for y in lines.keys.sorted() {
                let rowWords = lines[y]!.sorted { a, b in
                    a.0 != b.0 ? a.0 < b.0 : pyStringLess(a.1, b.1)
                }
                let tokens = rowWords.map { $0.1 }

                var dateIdx = -1
                var dateVal: (Int, Int, Int)? = nil
                for (idx, t) in tokens.enumerated() {
                    if let d = DateParse.parseDate(t) {
                        dateIdx = idx
                        dateVal = d
                        break
                    }
                }
                guard dateIdx != -1, let dateVal else { continue }

                var moneyTokens: [(Int, String)] = []
                var otherTokens: [String] = []
                for (idx, t) in tokens.enumerated() {
                    if idx == dateIdx { continue }
                    let tClean = curSymRe.sub("", t).pyStrip()
                    let tCleanNum = crdrSufRe.sub("", tClean).pyStrip()
                    if moneyPat.match(tCleanNum) != nil {
                        moneyTokens.append((idx, t))
                    } else {
                        otherTokens.append(t)
                    }
                }
                let desc = otherTokens.joined(separator: " ").pyStrip()
                let descLow = desc.pyLower()
                if moneyTokens.isEmpty ||
                    ["statement period", "opening balance", "closing balance", "total balance"]
                        .contains(where: { descLow.pyContains($0) }) {
                    continue
                }
                rawRows.append(RawRow(dateVal: dateVal, moneyTokens: moneyTokens, desc: desc))
            }
        }

        if rawRows.isEmpty { return [] }

        if tuple3Greater(rawRows[0].dateVal, rawRows[rawRows.count - 1].dateVal) {
            rawRows.reverse()
        }

        var out: [TxnRow] = []
        var seq = 0
        var runningBalance: Double? = nil

        for row in rawRows {
            let moneyTokens = row.moneyTokens
            let desc = row.desc
            var amt = 0.0
            var bal = 0.0
            var isCredit = false

            if moneyTokens.count >= 2 {
                let amtStr = moneyTokens[0].1
                let balStr = moneyTokens[moneyTokens.count - 1].1
                amt = abs(money(amtStr))
                bal = money(balStr)
                if balStr.pyLower().pyContains("dr") { bal = -bal }

                let descLow = desc.pyLower()
                if let rb = runningBalance {
                    let diff = bal - rb
                    if diff > 0.01 {
                        isCredit = true
                    } else if diff < -0.01 {
                        isCredit = false
                    } else if amtStr.hasPrefix("-") {
                        isCredit = false
                    } else if descLow.pyContains("/cr/") || descLow.pyContains("/cr ") || descLow.pyContains("cr/") {
                        isCredit = true
                    } else if descLow.pyContains("/dr/") || descLow.pyContains("/dr ") || descLow.pyContains("dr/") {
                        isCredit = false
                    } else if amtStr.pyLower().pyContains("cr") || balStr.pyLower().pyContains("cr") {
                        isCredit = true
                    } else {
                        isCredit = false
                    }
                } else {
                    if amtStr.hasPrefix("-") {
                        isCredit = false
                    } else if descLow.pyContains("/cr/") || descLow.pyContains("/cr ") || descLow.pyContains("cr/") {
                        isCredit = true
                    } else if descLow.pyContains("/dr/") || descLow.pyContains("/dr ") || descLow.pyContains("dr/") {
                        isCredit = false
                    } else if amtStr.pyLower().pyContains("cr") || balStr.pyLower().pyContains("cr")
                                || descLow.pyContains("deposit") {
                        isCredit = true
                    } else {
                        isCredit = false
                    }
                }
                runningBalance = bal
            } else if moneyTokens.count == 1 {
                let amtStr = moneyTokens[0].1
                let val = money(amtStr)
                // a lone value equal to the running balance is a balance-display line
                if let rb = runningBalance, abs(abs(val) - rb) < 0.005 { continue }
                amt = abs(val)
                isCredit = !amtStr.hasPrefix("-")
                if let rb = runningBalance {
                    bal = rb + (isCredit ? amt : -amt)
                    runningBalance = bal
                } else {
                    bal = 0.0
                }
            }

            let (yr, mon, day) = row.dateVal
            let iso = String(format: "%04d-%02d-%02d", yr, mon, day)
            seq += 1

            let (merchant, category) = localCur == "GBP"
                ? Classify.barclaysMerchant(desc, isCredit: isCredit, categories: categories)
                : Classify.classify(desc, isCredit: isCredit, categories: categories)

            out.append(TxnRow(txnDate: iso, month: iso.pyPrefix(7), year: yr, monthNo: mon, day: day,
                              descr: desc, merchant: merchant, category: category,
                              debit: isCredit ? 0.0 : amt, credit: isCredit ? amt : 0.0,
                              balance: bal, currency: localCur.isEmpty ? "INR" : localCur, seq: seq))
        }
        return out
    }

    // ---- _gen_rows: cluster a page's words into visual rows

    static func genRows(_ page: ExtractedPage) -> [[String]] {
        var ws: [(Int, Int, String)] = page.words.map { (pyRound($0.y0), pyRound($0.x0), $0.text) }
        ws.sort { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1 != b.1 { return a.1 < b.1 }
            return pyStringLess(a.2, b.2)
        }
        var out: [(Int, [(Int, String)])] = []
        for (y, x, w) in ws {
            if !out.isEmpty, y - out[out.count - 1].0 <= 3 {
                out[out.count - 1].1.append((x, w))
                out[out.count - 1].0 = y
            } else {
                out.append((y, [(x, w)]))
            }
        }
        return out.map { row in
            row.1.sorted { a, b in
                a.0 != b.0 ? a.0 < b.0 : pyStringLess(a.1, b.1)
            }.map { $0.1 }
        }
    }

    // ---- _parse_generic_dateinherited

    static func parseGenericDateInherited(_ doc: PDFTextExtractor, categories: Categories) -> [TxnRow] {
        let startPage = PageClassifier.findTableStart(doc)
        let head = headText(doc, from: startPage)
        let low = head.pyLower()
        let cur: String
        if ["barclays", "sort code", "£", "iban gb", "castlemere", "wrenfield"].contains(where: { low.pyContains($0) }) {
            cur = "GBP"
        } else if ["oman", "muscat", "omr"].contains(where: { low.pyContains($0) }) {
            cur = "OMR"
        } else if low.pyContains("$") {
            cur = "USD"
        } else {
            cur = "INR"
        }
        let years = PyRegex("\\b(20\\d\\d)\\b").findall(head).compactMap { Int($0) }
        let baseYear = years.min() ?? 2000

        struct GTxn {
            var date: (Int?, Int, Int)
            var desc: String
            var money: [String]
            var iso: (Int, Int, Int) = (0, 0, 0)
        }
        var txns: [GTxn] = []
        var curDate: (Int?, Int, Int)? = nil
        var curTxn: GTxn? = nil

        for pageIdx in startPage..<doc.pageCount {
            guard let page = doc.page(pageIdx) else { continue }
            for toks in genRows(page) {
                let moneyToks = toks.filter { DateParse.genMoneyRe.match($0) != nil }
                let (dt, used) = DateParse.genRowDate(toks)
                let text = toks.enumerated()
                    .filter { !used.contains($0.offset) && DateParse.genMoneyRe.match($0.element) == nil }
                    .map { $0.element }
                    .joined(separator: " ").pyStrip()
                if let dt { curDate = dt }
                if !moneyToks.isEmpty, let cd = curDate, DateParse.genSummaryRe.search(text) == nil {
                    if let t = curTxn { txns.append(t) }
                    curTxn = GTxn(date: cd, desc: text, money: moneyToks)
                } else if !text.isEmpty, curTxn != nil, dt == nil, DateParse.genSummaryRe.search(text) == nil {
                    curTxn!.desc = (curTxn!.desc + " " + text).pyStrip()
                }
            }
        }
        if let t = curTxn { txns.append(t) }
        if txns.isEmpty { return [] }

        // chronological year rollover for yearless dates
        var prevM: Int? = nil
        var yr = baseYear
        for i in 0..<txns.count {
            let (y0, m, d) = txns[i].date
            if let y0 { yr = y0 } else if let pm = prevM, m < pm { yr += 1 }
            prevM = m
            txns[i].iso = (yr, m, d)
        }
        if tuple3Greater(txns[0].iso, txns[txns.count - 1].iso) {
            txns.reverse()
        }

        var out: [TxnRow] = []
        var seq = 0
        var running: Double? = nil
        for t in txns {
            let mny = t.money
            let amt = abs(DateParse.genMoney(mny[0]))
            let bal = DateParse.genMoney(mny[mny.count - 1])
            let isCredit: Bool
            if let r = running {
                let diff = bal - r
                if abs(diff) > 0.005 {
                    isCredit = diff > 0.005
                } else {
                    // mny[0].lower().rstrip().endswith("cr")
                    var s = mny[0].pyLower()
                    while let last = s.last, last.isWhitespace { s.removeLast() }
                    isCredit = s.hasSuffix("cr")
                }
            } else {
                isCredit = mny[0].pyLower().pyContains("cr") || t.desc.pyLower().pyContains("deposit")
            }
            running = bal
            let (y, mm, dd) = t.iso
            seq += 1
            let desc = t.desc.pyPrefix(80)
            let (merchant, category) = cur == "GBP"
                ? Classify.barclaysMerchant(desc, isCredit: isCredit, categories: categories)
                : Classify.classify(desc, isCredit: isCredit, categories: categories)
            out.append(TxnRow(txnDate: String(format: "%04d-%02d-%02d", y, mm, dd),
                              month: String(format: "%04d-%02d", y, mm),
                              year: y, monthNo: mm, day: dd, descr: desc,
                              merchant: merchant, category: category,
                              debit: isCredit ? 0.0 : amt, credit: isCredit ? amt : 0.0,
                              balance: bal, currency: cur, seq: seq))
        }
        return out
    }

    // ---- _generic_breaks

    static func genericBreaks(_ rows: [TxnRow]) -> Int {
        func chk(_ seq: [TxnRow]) -> Int {
            var prev: Double? = nil
            var b = 0
            for r in seq {
                let bal = r.balance ?? 0.0
                if let p = prev, abs(bal - (p + r.credit - r.debit)) > 0.005 {
                    b += 1
                }
                prev = bal
            }
            return b
        }
        if rows.count < 2 { return 1_000_000_000 }
        return min(chk(rows), chk(rows.reversed()))
    }

    // ---- cascade

    static func parseGenericStatement(_ doc: PDFTextExtractor, categories: Categories) -> ParseResult {
        // Layer 1: rule-based columnar / date-inherited
        var columnar = parseGenericColumnar(doc, categories: categories)
        if !columnar.isEmpty {
            let numDescs = columnar.filter { $0.descr.pyStrip().pyIsDigit() }.count
            if Double(numDescs) / Double(columnar.count) > 0.30 { columnar = [] }
        }
        var inherited = parseGenericDateInherited(doc, categories: categories)
        if !inherited.isEmpty {
            let numDescs = inherited.filter { $0.descr.pyStrip().pyIsDigit() }.count
            if Double(numDescs) / Double(inherited.count) > 0.30 { inherited = [] }
        }

        var bestL1: [TxnRow]? = nil
        var bestL1Breaks = 1_000_000_000
        if !columnar.isEmpty {
            bestL1 = columnar
            bestL1Breaks = genericBreaks(columnar)
        }
        if !inherited.isEmpty {
            let inheritedBreaks = genericBreaks(inherited)
            if bestL1 == nil || inheritedBreaks < bestL1Breaks {
                bestL1 = inherited
                bestL1Breaks = inheritedBreaks
            }
        }

        if let best = bestL1, best.count >= 3 {
            let violationRatio = Double(bestL1Breaks) / Double(best.count)
            if bestL1Breaks == 0 {
                return ParseResult(rows: best, confidence: "high")
            }
            if violationRatio <= RULE_BASED_MAX_VIOLATION_RATIO {
                return ParseResult(rows: best, confidence: "medium")
            }
            // else: escalate — Layers 2/3 (LLM) produce nothing here, fall through
        }

        // Layers 2/3 unavailable (no LLM): final fallback grades L1 honestly.
        if let best = bestL1 {
            let finalViolationRatio = bestL1Breaks > 0 ? Double(bestL1Breaks) / Double(best.count) : 0.0
            let conf = finalViolationRatio > RULE_BASED_MAX_VIOLATION_RATIO ? "low" : "medium"
            return ParseResult(rows: best, confidence: conf)
        }
        return ParseResult(rows: [], confidence: "low")
    }
}

/// Python tuple comparison (a > b) for (y, m, d) triples.
func tuple3Greater(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
    if a.0 != b.0 { return a.0 > b.0 }
    if a.1 != b.1 { return a.1 > b.1 }
    return a.2 > b.2
}
