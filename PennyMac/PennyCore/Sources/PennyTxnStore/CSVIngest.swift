// CSVIngest — ingest_csv() from parsers.py (_map_csv_headers +
// _rows_from_csv_mapping), extended for real-world exports the way the PDF
// path is: header-row discovery below preamble lines, RFC-4180 field parsing
// (quoted commas, escaped quotes, CRLF, embedded newlines), BOM + latin-1
// decode fallback, per-file day/month-order inference (DateParse), repair of
// UNQUOTED lakh/thousand-grouped amounts that leak extra cells into a row,
// currency detection (Currency column, else symbol/cue sniffing), reverse-
// order normalization and the generic credit-card semantics post-pass —
// so the result flows through the exact same TxnRow shape ingestPDF returns.
import Foundation

enum CSVIngest {

    // MARK: - header-role synonyms (superset of parsers.py _CSV_*_ALIASES)

    static let dateAliases: Set<String> = ["date", "txn date", "transaction date", "value date",
        "tran date", "trans date", "posting date", "post date", "posted date"]
    static let descAliases: Set<String> = ["description", "narration", "particulars", "remarks",
        "details", "transaction remarks", "transaction details", "merchant"]
    static let debitAliases: Set<String> = ["debit", "withdrawal", "withdrawal amt",
        "withdrawal amount", "debit amt", "debit amount", "dr", "money out", "paid out",
        "payments out", "outgoings", "withdrawals"]
    static let creditAliases: Set<String> = ["credit", "deposit", "deposit amt",
        "deposit amount", "credit amt", "credit amount", "cr", "money in", "paid in",
        "payments in", "incomings", "deposits"]
    static let balanceAliases: Set<String> = ["balance", "closing balance", "running balance",
        "outstanding amount (inr)", "balance (inr)"]
    static let amountAliases: Set<String> = ["amount", "transaction amount"]
    static let categoryAliases: Set<String> = ["category", "transaction category", "type",
        "transaction type", "details", "sub-category", "group", "class", "narrative", "remarks"]
    static let currencyAliases: Set<String> = ["currency", "currency code", "ccy"]
    /// Direction-marker column ("Type: DEBIT/CREDIT", "Dr/Cr") — the common
    /// Indian-bank export layout with ONE amount column and the direction in a
    /// separate column. "type" is deliberately in BOTH this set and
    /// categoryAliases: which role the column really plays is decided from its
    /// DATA in `resolveTxnTypeColumn` (some exports use "Type" for categories).
    static let txnTypeAliases: Set<String> = ["type", "transaction type", "txn type",
        "dr/cr", "cr/dr", "dr / cr", "debit/credit", "credit/debit", "d/c", "dr cr"]

    /// Role check order mirrors the Python elif chain: a header maps to the
    /// FIRST role whose alias set contains it and that isn't already mapped
    /// ("details" is a description when free, a category column otherwise).
    static let roleOrder: [(String, Set<String>)] = [
        ("date", dateAliases), ("desc", descAliases), ("debit", debitAliases),
        ("credit", creditAliases), ("balance", balanceAliases), ("amount", amountAliases),
        ("txntype", txnTypeAliases), ("category", categoryAliases), ("currency", currencyAliases),
    ]

    /// Direction words a Type/DrCr column may carry, lowercased.
    static let debitMarkers: Set<String> = ["debit", "dr", "d", "withdrawal", "out", "paid out"]
    static let creditMarkers: Set<String> = ["credit", "cr", "c", "deposit", "in", "paid in"]

    /// A "type" header wins the txntype role at header time, but only its DATA
    /// says whether it truly carries direction markers (DEBIT/CREDIT/DR/CR) or
    /// is actually a category column ("Groceries", "POS", …). When under 80% of
    /// its values are direction words, demote it: hand the column to the (still
    /// free) category role instead.
    static func resolveTxnTypeColumn(_ mapping: inout [String: Int], dataRows: [[String]]) {
        guard let ti = mapping["txntype"] else { return }
        var direction = 0, filled = 0
        for row in dataRows where ti < row.count {
            let v = row[ti].pyStrip().pyLower()
            guard !v.isEmpty else { continue }
            filled += 1
            if debitMarkers.contains(v) || creditMarkers.contains(v) { direction += 1 }
        }
        if filled == 0 || Double(direction) / Double(filled) < 0.8 {
            mapping.removeValue(forKey: "txntype")
            if mapping["category"] == nil { mapping["category"] = ti }
        }
    }

    /// Bracketed qualifiers banks append to header names — "Withdrawal (Dr)",
    /// "Amount (INR)" — stripped for a second alias lookup.
    static let headerParenRe = PyRegex("\\s*\\([^)]*\\)\\s*$")

    /// _map_csv_headers(): {role: column index}, first match wins per role.
    static func mapHeaders(_ headers: [String]) -> [String: Int] {
        var mapping: [String: Int] = [:]
        for (idx, h) in headers.enumerated() {
            let hl = h.pyStrip().pyLower()
            let stripped = headerParenRe.sub("", hl).pyStrip()
            for (role, aliases) in roleOrder where mapping[role] == nil {
                if aliases.contains(hl) || aliases.contains(stripped) {
                    mapping[role] = idx
                    break
                }
            }
        }
        return mapping
    }

    // MARK: - decoding + record parsing

    /// utf-8-sig with a latin-1 fallback, like the Python reader pair.
    static func decode(_ data: Data) -> String {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        if text.unicodeScalars.first == "\u{FEFF}" {
            return String(text.unicodeScalars.dropFirst())
        }
        return text
    }

    /// csv.reader semantics: comma-separated, `"` quotes fields (commas, CRLF
    /// and doubled `""` escapes inside), \r\n / \n / \r each end a record.
    static func parseRecords(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                        field.unicodeScalars.append("\"")
                        i += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    field.unicodeScalars.append(c)
                }
                i += 1
                continue
            }
            switch c {
            case "\"":
                inQuotes = true
            case ",":
                record.append(field)
                field = ""
            case "\r", "\n":
                if c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                record.append(field)
                records.append(record)
                record = []
                field = ""
            default:
                field.unicodeScalars.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }

    // MARK: - unquoted grouped-amount repair

    // "₹1,34,550.00" written without quotes splits into "₹1" / "34" / "550.00".
    // When a data row carries MORE cells than the header, merge a money-looking
    // cell with digit-group continuations until the widths agree again.
    static let splitMoneyHeadRe = PyRegex("^[₹£$€]?-?[\\d,]*\\d$")
    static let splitMoneyContRe = PyRegex("^\\d{2,3}(?:\\.\\d{2})?$")

    static func repairSplitAmounts(_ row: [String], target: Int) -> [String] {
        var r = row
        var i = 0
        while r.count > target, i < r.count - 1 {
            if splitMoneyHeadRe.fullmatch(r[i].pyStrip()) != nil,
               splitMoneyContRe.fullmatch(r[i + 1].pyStrip()) != nil {
                r[i] = r[i].pyStrip() + "," + r[i + 1].pyStrip()
                r.remove(at: i + 1)
                // stay on i: "₹1" + "34" may still need "+ 550.00"
            } else {
                i += 1
            }
        }
        return r
    }

    // MARK: - money / date / currency cell parsing

    /// _money() plus accountant negatives: "(1,234.56)" → -1234.56.
    static func csvMoney(_ s: String) -> Double {
        let t = s.pyStrip()
        if t.count >= 2, t.hasPrefix("("), t.hasSuffix(")") {
            return -abs(money(String(t.dropFirst().dropLast())))
        }
        return money(t)
    }

    /// Trailing Cr/Dr marker on a single-amount column ("1,200.00 Dr").
    static let crdrAmountRe = PyRegex("(cr|dr)\\.?$", ignoreCase: true)

    /// parse_date() with the per-file month-first swap, plus a single-digit
    /// numeric fallback ("6/30/25") the two-digit reference patterns reject.
    static func parseCSVDate(_ raw: String, monthFirst: Bool) -> (Int, Int, Int)? {
        let t = raw.pyStrip()
        if let (yr, mon, day) = DateParse.parseDate(t) {
            // parseDate reads ambiguous numeric dates day-first; swap for US files.
            if monthFirst, DateParse.numericDayMonth(t) != nil {
                return (yr, day, mon)
            }
            return (yr, mon, day)
        }
        if let m = DateParse.numericDMRe.match(t) {
            let g = m.groups()
            guard let a = g[0].flatMap({ Int($0) }), let b = g[1].flatMap({ Int($0) }),
                  let yRaw = g[2].flatMap({ Int($0) }) else { return nil }
            let yr = yRaw < 100 ? yRaw + 2000 : yRaw
            let (mon, day) = monthFirst ? (a, b) : (b, a)
            return DateParse.genValid(mon, day) ? (yr, mon, day) : nil
        }
        return nil
    }

    static let isoCodeRe = PyRegex("^[A-Za-z]{3}$")

    /// A Currency-column cell → ISO code ("inr" / "₹" → "INR"), "" if unusable.
    static func normalizeCurrencyCode(_ raw: String) -> String {
        let t = raw.pyStrip()
        if isoCodeRe.fullmatch(t) != nil { return t.pyUpper() }
        switch t {
        case "₹": return "INR"
        case "£": return "GBP"
        case "€": return "EUR"
        case "$": return "USD"
        default: return ""
        }
    }

    /// CSV bodies carry the symbol on (nearly) every amount, so the majority
    /// symbol beats cue words; then the PDF path's cue sniffing; then the
    /// Python default parameter ("INR").
    static func sniffCurrency(_ text: String) -> String {
        var best = ""
        var bestN = 0
        for (sym, code) in [("₹", "INR"), ("£", "GBP"), ("€", "EUR"), ("$", "USD")] {
            let n = text.components(separatedBy: sym).count - 1
            if n > bestN { bestN = n; best = code }
        }
        if bestN > 0 { return best }
        let cueGuess = GenericParsers.sniffCurrency(text)
        return cueGuess.isEmpty ? "INR" : cueGuess
    }

    // MARK: - ingest

    static let maxHeaderScan = 10

    static func ingest(path: String, categories: Categories) throws -> IngestOutput {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return ingest(text: decode(data), categories: categories)
    }

    static func ingest(text: String, categories: Categories) -> IngestOutput {
        ingest(records: parseRecords(text), categories: categories, rawText: text)
    }

    /// Shared core: a pre-parsed cell matrix (CSV records or XLSX sheet rows) →
    /// transactions. Everything downstream of raw-text parsing lives here so
    /// Excel ingestion inherits header discovery, date-order inference, currency
    /// sniffing and categorization unchanged. `rawText` feeds the free-text
    /// passes (currency symbol sniffing, card-statement detection); when absent
    /// (XLSX) it's synthesized by joining the cells.
    static func ingest(records: [[String]], categories: Categories, rawText: String? = nil) -> IngestOutput {
        let text = rawText ?? records.map { $0.joined(separator: " ") }.joined(separator: "\n")
        // Header discovery: the first row that maps a date column and at least
        // one money column. Real exports put branding/summary lines above it.
        var headerIdx: Int? = nil
        var mapping: [String: Int] = [:]
        for (i, rec) in records.prefix(maxHeaderScan).enumerated() {
            let m = mapHeaders(rec)
            if m["date"] != nil, m["debit"] != nil || m["credit"] != nil || m["amount"] != nil {
                headerIdx = i
                mapping = m
                break
            }
        }
        guard let headerIdx else {
            return IngestOutput(rows: [], bankName: nil, confidence: "low",
                                detectedCurrency: "INR", closingBalance: nil, isCard: false)
        }
        let headerCount = records[headerIdx].count
        let dataRows = records[(headerIdx + 1)...].map { row in
            row.count > headerCount ? repairSplitAmounts(row, target: headerCount) : row
        }

        // Decide from the data whether a "Type" column is direction or category.
        resolveTxnTypeColumn(&mapping, dataRows: dataRows)

        // day/month order inferred over every ambiguous numeric date in the file
        var dmPairs: [(Int, Int)] = []
        if let di = mapping["date"] {
            for row in dataRows where di < row.count {
                if let p = DateParse.numericDayMonth(row[di]) { dmPairs.append(p) }
            }
        }
        let monthFirst = DateParse.inferMonthFirst(dmPairs)

        // file-level currency: a Currency column wins, else symbol/cue sniffing
        var detectedCur = ""
        if let ci = mapping["currency"] {
            for row in dataRows where ci < row.count {
                let code = normalizeCurrencyCode(row[ci])
                if !code.isEmpty { detectedCur = code; break }
            }
        }
        if detectedCur.isEmpty { detectedCur = sniffCurrency(text) }

        // _rows_from_csv_mapping()
        var txns: [TxnRow] = []
        for row in dataRows {
            if row.isEmpty || row.allSatisfy({ $0.pyStrip().isEmpty }) { continue }
            func cell(_ role: String) -> String {
                guard let idx = mapping[role], idx < row.count else { return "" }
                return row[idx].pyStrip()
            }

            guard let (yr, mon, day) = parseCSVDate(cell("date"), monthFirst: monthFirst) else {
                continue   // footer disclaimers / section headings land here
            }
            let iso = String(format: "%04d-%02d-%02d", yr, mon, day)

            let desc = cell("desc")
            let rawCat = cell("category")

            // separate debit/credit columns OR a single signed amount column
            let debitRaw = cell("debit")
            let creditRaw = cell("credit")
            let amountRaw = cell("amount")
            var debit = 0.0
            var credit = 0.0
            if !debitRaw.isEmpty || !creditRaw.isEmpty {
                debit = debitRaw.isEmpty ? 0.0 : abs(csvMoney(debitRaw))
                credit = creditRaw.isEmpty ? 0.0 : abs(csvMoney(creditRaw))
            } else if !amountRaw.isEmpty {
                let val = csvMoney(amountRaw)
                let suffix = crdrAmountRe.search(amountRaw)?.group(1)?.pyLower()
                let marker = cell("txntype").pyLower()
                if suffix == "cr" {
                    credit = abs(val)
                } else if suffix == "dr" {
                    debit = abs(val)
                } else if Self.debitMarkers.contains(marker) {
                    // "Type: DEBIT" column + positive amount — without this,
                    // every row of the common Indian export layout was a credit.
                    debit = abs(val)
                } else if Self.creditMarkers.contains(marker) {
                    credit = abs(val)
                } else {
                    debit = val < 0 ? abs(val) : 0.0
                    credit = val > 0 ? val : 0.0
                }
            } else {
                continue   // no money cell — skip row
            }

            let balRaw = cell("balance")
            let balance: Double? = balRaw.isEmpty ? nil : csvMoney(balRaw)

            let (merchant, guessedCat) = Classify.classify(desc, isCredit: credit > 0,
                                                           categories: categories)
            var category = guessedCat
            if let norm = Describe.normalizeCategory(rawCat) { category = norm }

            var rowCur = normalizeCurrencyCode(cell("currency"))
            if rowCur.isEmpty { rowCur = detectedCur }

            var txn = TxnRow(txnDate: iso, month: iso.pyPrefix(7), year: yr, monthNo: mon,
                             day: day, descr: desc.pyPrefix(200), merchant: merchant,
                             category: category, debit: debit, credit: credit,
                             balance: balance, currency: rowCur, seq: txns.count + 1)
            if !rawCat.isEmpty { txn.rawCategory = rawCat }
            txns.append(txn)
        }

        // reverse-chronological detection, exactly like the PDF path
        var isRev = false
        if txns.count >= 2 {
            let firstDate = txns[0].txnDate
            let lastDate = txns[txns.count - 1].txnDate
            if firstDate > lastDate {
                isRev = true
            } else if firstDate == lastDate {
                let balCurr = txns[0].balance
                let balNext = txns[1].balance
                let amtCurr = txns[0].credit - txns[0].debit
                if let bc = balCurr, let bn = balNext {
                    if abs((bn + amtCurr) - bc) < 0.01 {
                        isRev = true
                    }
                }
            }
        }
        if isRev { txns.reverse() }

        // card exports: owed-balance polarity + repayment recategorization.
        // Runs AFTER order normalization (balance deltas only mean charge vs
        // payment on chronologically ordered rows), same as ingestPDF.
        var closingBalance: Double? = nil
        var isCard = false
        if !txns.isEmpty, CardStatement.detect(text) {
            txns = CardStatement.applyCardSemantics(txns)
            isCard = true
            closingBalance = CardStatement.statedClosingBalance(text)
                ?? txns.last(where: { $0.balance != nil })?.balance
        }

        for i in txns.indices { txns[i].seq = i + 1 }

        return IngestOutput(rows: txns, bankName: nil,
                            confidence: txns.isEmpty ? "low" : "high",
                            detectedCurrency: detectedCur,
                            closingBalance: closingBalance, isCard: isCard)
    }
}
