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

    /// The "Date | Narration | Debit | Credit | Balance" column layout used by
    /// most Indian banks (Kotak, Axis, HDFC, ICICI, SBI, …) and lookalikes.
    /// Detected by the column *structure* — a description column plus SEPARATE
    /// Debit and Credit columns and a Balance column — not by any bank name, so it
    /// works for every issuer that ships this format. The separate debit/credit
    /// columns are the discriminator (UK/EU statements use "Money in/out",
    /// "Paid in/out", "Payments/Receipts" — never a distinct Debit *and* Credit
    /// header). Because direction is positional (an amount in the Credit column is
    /// income), we never guess it from a running-balance delta. Also tolerant of
    /// the rupee glyph (₹) that some PDF subsets mis-decode as a stray leading
    /// letter on every amount.
    static let columnarDescHeaders = ["narration", "particulars", "description", "details", "transaction"]
    static func isColumnarDebitCredit(_ text: String) -> Bool {
        let low = text.pyLower()
        return columnarDescHeaders.contains { low.pyContains($0) }
            && low.pyContains("debit") && low.pyContains("credit") && low.pyContains("balance")
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

    // ---- Universal positional Debit/Credit/Balance columnar parser (bank-agnostic)
    //
    // One parser for every statement built on the Date | Narration/Description |
    // Debit | Credit | Balance layout — Kotak, Axis, HDFC, ICICI, SBI and the many
    // lookalikes. It reads the words by shared y, learns the Debit/Credit/Balance
    // column x-centres from the header row, and assigns each amount to a column by
    // nearest x. Direction is therefore positional (an amount in the Credit column
    // is income) — never a running-balance guess, which the generic parser gets
    // wrong on the first row (a salary credit) when no opening balance seeds the
    // walk. Deliberately tolerant of every variation these statements throw:
    //   • amounts with OR without decimals ("85,000" and "45,820.50")
    //   • a mis-decoded ₹ glyph prefixing amounts ("n85,000.00")
    //   • the year in the date cell ("01-Oct-2026"), or only in a section header
    //     with a bare "DD-MMM" / "DD/MM" date cell — the document year fills in
    //   • multiple monthly sections in one document (repeated headers)
    // An x-proximity gate keeps stray numbers (account numbers, years, phone
    // numbers) from being read as amounts: a token only counts as money if it sits
    // within half a column-gap of the Debit/Credit/Balance columns.
    static let columnarMonthDateRe = PyRegex("^(\\d{1,2})-([A-Za-z]{3})(?:-(\\d{2,4}))?$")
    static let columnarNumDateRe = PyRegex("^(\\d{1,2})[/.-](\\d{1,2})(?:[/.-](\\d{2,4}))?$")
    static let columnarYearRe = PyRegex("^(19|20)\\d{2}$")
    // Money: comma-grouped (with optional decimals), or any-length decimal. Rejects
    // ungrouped 4+ digit blobs (account/reference numbers). A leading currency glyph
    // (₹, or its "n" mis-decode, or $/£/€) is stripped first.
    static let columnarMoneyRe = PyRegex("^(\\d{1,3}(,\\d{3})*(\\.\\d{1,2})?|\\d+\\.\\d{1,2})$")

    /// (year?, month, day) for a date-column token — year is nil when the cell
    /// carries no year (filled from the document later). Returns nil if not a date.
    private static func columnarDate(_ token: String) -> (year: Int?, month: Int, day: Int)? {
        if let m = columnarMonthDateRe.match(token) {
            guard let mon = DateParse.monTitle[m.group(2)!.pyPrefix(3).pyTitle()] else { return nil }
            let day = Int(m.group(1)!)!
            guard (1...31).contains(day) else { return nil }
            return (normYear(m.group(3)), mon, day)
        }
        if let m = columnarNumDateRe.match(token) {
            let day = Int(m.group(1)!)!, mon = Int(m.group(2)!)!
            guard (1...31).contains(day), (1...12).contains(mon) else { return nil }
            return (normYear(m.group(3)), mon, day)
        }
        return nil
    }
    private static func normYear(_ s: String?) -> Int? {
        guard let s, var y = Int(s) else { return nil }
        if y < 100 { y += 2000 }
        return y
    }

    /// A money value if `token` is an amount cell, else nil. Strips a leading
    /// currency glyph (real or the "n" mis-decode of ₹) before matching.
    private static func columnarMoney(_ token: String) -> Double? {
        let stripped = PyRegex("^[₹$£€n]").sub("", token)
        guard columnarMoneyRe.match(stripped) != nil else { return nil }
        return abs(money(token))
    }

    static func parseColumnarDebitCredit(_ doc: PDFTextExtractor, categories: Categories,
                                         currency: String) -> [TxnRow] {
        // Document year: statements often print the year only in a section header,
        // leaving date cells as bare "DD-MMM". Use the most common year token.
        var yearCounts: [Int: Int] = [:]
        for i in 0..<doc.pageCount {
            for w in doc.page(i)?.words ?? [] where columnarYearRe.match(w.text) != nil {
                yearCounts[Int(w.text)!, default: 0] += 1
            }
        }
        let docYear = yearCounts.max { $0.value < $1.value }?.key

        var out: [TxnRow] = []
        var seq = 0
        // Column x-centres carry ACROSS pages: a statement's later pages often
        // continue the table without repeating the header, so a page with no header
        // reuses the last-known columns (the layout is fixed document-wide).
        var dX: Double?, cX: Double?, bX: Double?

        for pageIdx in 0..<doc.pageCount {
            guard let page = doc.page(pageIdx) else { continue }

            // Cluster words into visual rows by y (within ~3pt).
            var rows: [(y: Double, words: [(x: Double, t: String)])] = []
            for w in page.words.sorted(by: { $0.y0 != $1.y0 ? $0.y0 < $1.y0 : $0.x0 < $1.x0 }) {
                if let last = rows.last, abs(w.y0 - last.y) <= 3 {
                    rows[rows.count - 1].words.append((w.x0, w.text))
                    rows[rows.count - 1].y = w.y0
                } else {
                    rows.append((w.y0, [(w.x0, w.text)]))
                }
            }

            // Learn column x-centres from this page's header row (first row carrying
            // all three), updating the carried-over columns when present.
            for row in rows {
                var d: Double?, c: Double?, b: Double?
                for (x, t) in row.words {
                    switch t.pyLower() {
                    case "debit":   d = x
                    case "credit":  c = x
                    case "balance": b = x
                    default: break
                    }
                }
                if let d, let c, let b { dX = d; cX = c; bX = b; break }
            }
            guard let dX, let cX, let bX else { continue }

            // Proximity gate: half the smallest inter-column gap. A money token must
            // land inside one column's band to be assigned; description numbers
            // (further left) are left as text.
            let sortedX = [dX, cX, bX].sorted()
            let gate = max(1.0, min(sortedX[1] - sortedX[0], sortedX[2] - sortedX[1]) / 2)
            func column(_ x: Double) -> Int? {   // 0 = debit, 1 = credit, 2 = balance
                let d = [abs(x - dX), abs(x - cX), abs(x - bX)]
                let i = d.firstIndex(of: d.min()!)!
                return d[i] <= gate ? i : nil
            }

            for row in rows {
                let words = row.words.sorted { $0.x < $1.x }
                guard let dateWord = words.first(where: { columnarDate($0.t) != nil }),
                      let parsed = columnarDate(dateWord.t) else { continue }
                guard let year = parsed.year ?? docYear else { continue }

                var debit = 0.0, credit = 0.0, balance = 0.0
                var sawAmount = false, sawBalance = false
                var descParts: [String] = []
                for (x, t) in words {
                    if t == dateWord.t { continue }
                    if let v = columnarMoney(t), let col = column(x) {
                        switch col {
                        case 0: debit = v;  sawAmount = true
                        case 1: credit = v; sawAmount = true
                        default: balance = v; sawBalance = true
                        }
                    } else {
                        descParts.append(t)
                    }
                }
                // A real transaction row has a debit-or-credit amount and a balance.
                guard sawAmount, sawBalance else { continue }

                let iso = String(format: "%04d-%02d-%02d", year, parsed.month, parsed.day)
                var desc = descParts.joined(separator: " ")
                desc = PyRegex("\\s+").sub(" ", desc).pyStrip()

                let isCredit = credit > 0
                let (merchant, category) = Classify.classify(desc, isCredit: isCredit, categories: categories)
                seq += 1
                out.append(TxnRow(txnDate: iso, month: iso.pyPrefix(7), year: year,
                                  monthNo: parsed.month, day: parsed.day, descr: desc,
                                  merchant: merchant, category: category,
                                  debit: debit, credit: credit, balance: balance,
                                  currency: currency.isEmpty ? "INR" : currency, seq: seq))
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
