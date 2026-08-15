// UKStatementParsers — dedicated parsers for realistic UK statement layouts the
// generic cascade mangles: the Amex-style card statement (date-pair lines, CR
// marker, no balance column) and the modern column-table statements exported by
// NatWest / Nationwide / Revolut / Monzo.
//
// These layouts are NOT in the conformance fixture set (verified by signature
// scan), and every detector below requires a brand string + a layout signature
// that no fixture contains — so the contract-locked parsers keep their routes.
//
// Design notes:
// - The table engine is word-geometry based (like parseBarclays): cluster words
//   into visual rows, find the header row ("Date … Balance"), derive column
//   x-extents from the header labels, then assign each amount to the nearest
//   money column by right-edge distance (statement amounts are right-aligned).
// - Diagonal "SAMPLE DATA - NOT REAL" watermarks bleed giant rotated words into
//   row bands; they're filtered by height (watermark glyph boxes are 4-14x the
//   median word height).
// - After column assignment, a balance-walk pass re-checks every row against
//   prev balance ± amount and flips debit/credit when the walk proves the
//   column wrong — the layout-independent ground truth.
import Foundation

public struct CardStatementSummary {
    public var closingBalance: Double?   // what the statement itself says you owe / hold
    public var isCard: Bool              // credit-card semantics (balance = owed)
}

enum UKParsers {

    // MARK: - Detectors (brand + layout signature; fixture-collision-checked)

    static func isAmexCard(_ low: String) -> Bool {
        // the letterhead stacks "AMERICAN" / "EXPRESS" on separate lines
        PyRegex("american\\s+express").search(low) != nil && low.pyContains("membership number")
    }
    static func isRevolutTable(_ low: String) -> Bool {
        low.pyContains("revolut") && low.pyContains("exchange rate")
    }
    static func isMonzoTable(_ low: String) -> Bool {
        // Brand + a Monzo table signature. The older "Personal Account Statement"
        // layout and the real app export (Monzo_bank_statement_…pdf) both land
        // here: the export drops that exact phrase but carries "Money In/Out"
        // columns, a "…Account Balance" summary, and "Transfer to Pot" rows — all
        // Monzo-specific. The synthetic specimen (Paid In/Paid Out, no Pot) is
        // intentionally NOT matched: it parses via the generic cascade and must
        // keep that route.
        guard low.pyContains("monzo") else { return false }
        return low.pyContains("personal account statement")
            || low.pyContains("money out") || low.pyContains("money in")
            || low.pyContains("transfer to pot") || low.pyContains("account balance")
    }
    static func isNatWestTable(_ low: String) -> Bool {
        low.pyContains("natwest") && low.pyContains("statement of account")
            && low.pyContains("paid out")
    }
    static func isNationwideTable(_ low: String) -> Bool {
        low.pyContains("nationwide building society") && low.pyContains("your account summary for")
    }

    // MARK: - Shared bits

    static let amountRe = PyRegex("^-?[\\d,]+\\.\\d{2}$")
    static let moneyRe = PyRegex("£\\s*(-?[\\d,]+\\.\\d{2})")

    /// "May" / "June" / "JUN" → month number (via the 3-letter title map).
    static func monthNo(_ s: String) -> Int? {
        DateParse.monTitle[s.pyPrefix(3).pyTitle()]
    }

    /// Statement-period year anchor: a month falls in the end year unless it is
    /// after the end month (then it belongs to the previous year — Dec on a Jan
    /// statement).
    static func yearFor(month: Int, endMonth: Int, endYear: Int) -> Int {
        guard endYear > 0 else { return 0 }
        return month <= endMonth ? endYear : endYear - 1
    }

    static func fullText(_ doc: PDFTextExtractor) -> String {
        var t = ""
        for i in 0..<doc.pageCount { t += (doc.page(i)?.text ?? "") + "\n" }
        return t
    }

    /// Map a currency name printed in a statement's foreign-spend block to an ISO
    /// 4217 code. Passes an already-ISO 3-letter code straight through; returns nil
    /// for an empty/unknown-shaped input (so the caller stores FX only when it has a
    /// currency). Unknown multi-word names are upper-cased and returned verbatim
    /// rather than dropped — the amount is still worth preserving.
    static func normalizeCurrencyName(_ raw: String?) -> String? {
        guard let trimmed = raw?.pyStrip(), !trimmed.isEmpty else { return nil }
        let up = trimmed.pyUpper()
        if up.count == 3, up.allSatisfy({ $0.isLetter }) { return up }   // already an ISO code
        let map: [String: String] = [
            "ICELANDIC KRONA": "ISK", "ICELAND KRONA": "ISK",
            "US DOLLAR": "USD", "US DOLLARS": "USD", "UNITED STATES DOLLAR": "USD",
            "EURO": "EUR", "EUROS": "EUR",
            "POUND": "GBP", "POUNDS": "GBP", "POUND STERLING": "GBP", "POUNDS STERLING": "GBP",
            "INDIAN RUPEE": "INR", "INDIAN RUPEES": "INR",
            "JAPANESE YEN": "JPY", "SWISS FRANC": "CHF", "SWISS FRANCS": "CHF",
            "CANADIAN DOLLAR": "CAD", "AUSTRALIAN DOLLAR": "AUD",
            "UAE DIRHAM": "AED", "SAUDI RIYAL": "SAR", "OMANI RIAL": "OMR",
        ]
        return map[up] ?? up
    }

    // MARK: - Amex-style card statement (positional)

    /// American Express prints its transaction table in fixed columns:
    ///   [txn-date] [process-date]  DESCRIPTION …  [foreign spend]  AMOUNT  [CR]
    /// where the two dates are `Mon DD` cells on the far left (x < 95), the amount
    /// is right-aligned in its own column (x ≳ 450) and a "CR" tag marks a credit.
    /// This MUST be read positionally, not from the linearized page text: the text
    /// linearizer detaches the right-hand amount column from its row (and can splice
    /// the account-summary Credit Limit into the first transaction), which is why the
    /// old line-based reader saw a handful of rows with the credit limit as an amount.
    /// The x-gate on the amount column also keeps summary figures (credit limit,
    /// available credit) and the foreign-spend column out of the transaction amounts.
    static func parseAmexCard(_ doc: PDFTextExtractor,
                              categories: Categories) -> ([TxnRow], CardStatementSummary) {
        let full = fullText(doc)

        // Statement-period year anchor: "…From 16 February to 15 March 2026" (with or
        // without a "Statement Period:" label), else the header "Date 15/03/26".
        var em = 0, ey = 0
        if let m = PyRegex("from\\s+\\d{1,2}\\s+([A-Za-z]+)\\s+to\\s+\\d{1,2}\\s+([A-Za-z]+)\\s+(\\d{4})",
                           ignoreCase: true).search(full) {
            em = monthNo(m.group(2)!) ?? 0
            ey = Int(m.group(3)!) ?? 0
        } else if let m = PyRegex("(\\d{2})/(\\d{2})/(\\d{2})\\b").search(full) {
            em = Int(m.group(2)!) ?? 0
            ey = 2000 + (Int(m.group(3)!) ?? 0)
        }

        let monthTok = PyRegex("^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)$")
        let dayTok = PyRegex("^\\d{1,2}$")
        let numTok = PyRegex("^-?[\\d,]+(?:\\.\\d+)?$")   // a bare foreign amount ("550", "1,234.56")
        let rateRe = PyRegex("exchange rate\\s*([\\d.]+)", ignoreCase: true)
        let feeRe = PyRegex("transaction fee\\s*([\\d.,]+)", ignoreCase: true)
        let AMOUNT_X = 450.0   // left edge of the amount column
        let FOREIGN_X = 360.0  // left edge of the "Foreign Spend" column (sits between desc and amount)
        let DESC_MIN = 95.0    // description band starts after the date cells

        struct Amex {
            var mon: Int; var day: Int; var desc: String; var amount: Double?; var credit: Bool
            // Foreign-spend detail, when the row carries one (e.g. an ISK charge).
            var fgnAmount: Double? = nil; var fgnCurrency: String? = nil
            var fxRate: Double? = nil; var fxFee: Double? = nil
        }
        var txns: [Amex] = []
        var cur: Amex? = nil

        for pageIdx in 0..<doc.pageCount {
            guard let page = doc.page(pageIdx) else { continue }
            // Cluster words into visual rows by top-y (merge within 5pt): the amount
            // and its date row sometimes differ by ~1pt, a trailing "CR" by ~12pt.
            let sorted = page.words.sorted { $0.y0 != $1.y0 ? $0.y0 < $1.y0 : $0.x0 < $1.x0 }
            var rows: [[PDFWord]] = []
            var runY = -Double.infinity
            for w in sorted {
                if w.y0 - runY <= 5, !rows.isEmpty { rows[rows.count - 1].append(w) }
                else { rows.append([w]) }
                runY = w.y0
            }

            for row in rows {
                let ws = row.sorted { $0.x0 < $1.x0 }
                let left = ws.filter { $0.x0 < DESC_MIN }
                let datePair = left.count >= 4
                    && monthTok.match(left[0].text) != nil && dayTok.match(left[1].text) != nil
                    && monthTok.match(left[2].text) != nil
                // rightmost money token IN the amount column (keeps summary/foreign out)
                var amount: Double? = nil
                for w in ws where w.x0 >= AMOUNT_X && amountRe.match(w.text) != nil { amount = money(w.text) }
                let hasCR = ws.contains { $0.text.pyUpper() == "CR" }
                // Description stops at the Foreign-Spend column, so a bare foreign
                // amount ("550") in that column is never swept into the merchant text.
                let desc = ws.filter { $0.x0 >= DESC_MIN && $0.x0 < FOREIGN_X && amountRe.match($0.text) == nil }
                             .map(\.text).joined(separator: " ")

                // Foreign-Spend column [FOREIGN_X, AMOUNT_X): the original-currency amount
                // ("550") and/or its currency name ("ICELANDIC KRONA"). CR and the £
                // amount sit at/after AMOUNT_X and are excluded by the x-gate.
                var fgnAmt: Double? = nil, fgnCur: String? = nil
                for w in ws where w.x0 >= FOREIGN_X && w.x0 < AMOUNT_X {
                    if numTok.match(w.text) != nil {
                        fgnAmt = Double(w.text.replacingOccurrences(of: ",", with: ""))
                    } else if w.text.count >= 3, w.text.allSatisfy({ $0.isLetter }) {
                        fgnCur = fgnCur.map { $0 + " " + w.text } ?? w.text
                    }
                }
                // FX detail line: "Exchange Rate 163.2047 +Nonsterling Transaction Fee .10"
                let joined = ws.map(\.text).joined(separator: " ")
                var fxRate: Double? = nil, fxFee: Double? = nil
                if let m = rateRe.search(joined), let g = m.group(1) { fxRate = Double(g) }
                if let m = feeRe.search(joined), let g = m.group(1) {
                    fxFee = Double(g.hasPrefix(".") ? "0" + g : g)
                }

                if datePair, let mon = monthNo(left[0].text), let day = Int(left[1].text) {
                    if let c = cur { txns.append(c) }
                    cur = Amex(mon: mon, day: day, desc: desc, amount: amount, credit: hasCR,
                               fgnAmount: fgnAmt, fgnCurrency: fgnCur, fxRate: fxRate, fxFee: fxFee)
                } else if cur != nil {
                    // continuation row: fill the amount/CR and the foreign detail, and
                    // append detail text only BEFORE the amount is locked in (so page
                    // footers can't stitch on).
                    if let a = amount, cur!.amount == nil { cur!.amount = a }
                    if hasCR { cur!.credit = true }
                    if let f = fgnAmt, cur!.fgnAmount == nil { cur!.fgnAmount = f }
                    if let c = fgnCur, cur!.fgnCurrency == nil { cur!.fgnCurrency = c }
                    if let r = fxRate, cur!.fxRate == nil { cur!.fxRate = r }
                    if let f = fxFee, cur!.fxFee == nil { cur!.fxFee = f }
                    if !desc.isEmpty, cur!.amount == nil { cur!.desc = (cur!.desc + " " + desc).pyStrip() }
                }
            }
        }
        if let c = cur { txns.append(c) }

        var out: [TxnRow] = []
        var seq = 0
        for t in txns {
            guard let amt = t.amount, !t.desc.isEmpty else { continue }
            let yr = yearFor(month: t.mon, endMonth: em, endYear: ey)
            let iso = String(format: "%04d-%02d-%02d", yr, t.mon, t.day)
            let desc = PyRegex("\\s+").sub(" ", t.desc).pyStrip()
            let merchant: String, category: String
            if PyRegex("payment received", ignoreCase: true).search(desc) != nil {
                // repaying your own card is a transfer, not income
                (merchant, category) = ("Payment Received", "Payments")
            } else {
                (merchant, category) = Classify.barclaysMerchant(desc, isCredit: t.credit, categories: categories)
            }
            seq += 1
            var row = TxnRow(txnDate: iso, month: iso.pyPrefix(7), year: yr, monthNo: t.mon, day: t.day,
                             descr: desc.pyPrefix(200), merchant: merchant, category: category,
                             debit: t.credit ? 0.0 : amt, credit: t.credit ? amt : 0.0,
                             balance: nil, currency: "GBP", seq: seq)
            if let fa = t.fgnAmount, let cur = normalizeCurrencyName(t.fgnCurrency) {
                row.fxForeignAmount = fa
                row.fxForeignCurrency = cur
                row.fxRate = t.fxRate
                row.fxFee = t.fxFee
            }
            out.append(row)
        }

        return (out, CardStatementSummary(closingBalance: amexClosingBalance(doc), isCard: true))
    }

    /// The account-summary "Closing Balance" (amount owed): find that column header
    /// on the first page (it sits in the right half, x > 350) and take the money
    /// figure directly beneath it. Best-effort — nil if the summary isn't found.
    private static func amexClosingBalance(_ doc: PDFTextExtractor) -> Double? {
        guard let page = doc.page(0) else { return nil }
        let ws = page.words
        var colX: Double? = nil, labelY: Double? = nil
        for i in 0..<ws.count where ws[i].text == "Closing" && ws[i].x0 > 350 {
            if i + 1 < ws.count, ws[i + 1].text == "Balance" { colX = ws[i].x0; labelY = ws[i].y0 }
        }
        guard let cx = colX, let ly = labelY else { return nil }
        let moneyTok = PyRegex("^£?\\s*([\\d,]+\\.\\d{2})$")
        var best: (y: Double, v: Double)? = nil
        for w in ws where w.y0 > ly && abs(w.x0 - cx) < 60 {
            if let m = moneyTok.match(w.text.pyStrip()) {
                let v = money(m.group(1)!)
                if best == nil || w.y0 < best!.y { best = (w.y0, v) }
            }
        }
        return best?.v
    }

    // MARK: - Column-table engine (NatWest / Nationwide / Revolut / Monzo)

    private struct Columns {
        var descStart: Double        // left edge of the description zone
        var descEnd: Double          // right edge of the description zone
        var moneyLabels: [(name: String, x0: Double, x1: Double, kind: MoneyKind)]
    }

    private enum MoneyKind { case out_, in_, signed, balance }

    /// One parsed visual row.
    private struct Line {
        var words: [PDFWord]
        var joined: String { words.map(\.text).joined(separator: " ") }
    }

    /// Cluster a page's words into visual rows (3-pt y buckets, like Barclays),
    /// dropping watermark words by height (watermark glyph boxes measure 4-14x
    /// the median word height; real row words never do).
    private static func lines(of page: ExtractedPage) -> [Line] {
        let raw = page.words
        guard !raw.isEmpty else { return [] }
        let heights = raw.map { $0.y1 - $0.y0 }.sorted()
        let median = heights[heights.count / 2]
        let cutoff = max(median * 1.6, 20.0)
        let kept = raw.filter { ($0.y1 - $0.y0) <= cutoff }

        // Cluster on the shared BASELINE (y1), not the glyph top: mixed font
        // sizes in one visual row (Monzo prints the description smaller than the
        // date/amount cells) give different y0s but the same baseline. Sort by
        // baseline then sweep, merging words within 2.5pt of the running row.
        let sorted = kept.sorted { $0.y1 != $1.y1 ? $0.y1 < $1.y1 : $0.x0 < $1.x0 }
        var rows: [[PDFWord]] = []
        var curY = -Double.infinity
        for w in sorted {
            if w.y1 - curY <= 2.5, !rows.isEmpty {
                rows[rows.count - 1].append(w)
            } else {
                rows.append([w])
            }
            curY = w.y1
        }
        return rows.map { r in
            Line(words: r.sorted { a, b in
                a.x0 != b.x0 ? a.x0 < b.x0 : pyStringLess(a.text, b.text)
            })
        }
    }

    /// Locate a label phrase ("paid out", "amount (gbp)", "£ out") inside a
    /// header row; returns the x-extent of the matched word run. Matches the
    /// phrase both as a word-per-word run and as a single fused word.
    private static func findLabel(_ line: Line, _ phrase: String) -> (Double, Double)? {
        let want = phrase.pySplit()
        let fused = phrase.replacingOccurrences(of: " ", with: "")
        let words = line.words
        guard !want.isEmpty, !words.isEmpty else { return nil }
        for s in 0..<words.count {
            if words[s].text.pyLower() == fused {
                return (words[s].x0, words[s].x1)
            }
            guard s + want.count <= words.count else { continue }
            var ok = true
            for (o, w) in want.enumerated() where words[s + o].text.pyLower() != w {
                _ = w; ok = false; break
            }
            if ok { return (words[s].x0, words[s + want.count - 1].x1) }
        }
        return nil
    }

    /// Try the known date-cell shapes; returns (day, month, year|0).
    private static func parseDateCell(_ text: String) -> (Int, Int, Int)? {
        let t = text.pyStrip()
        if let m = PyRegex("^(\\d{1,2})/(\\d{1,2})/(\\d{4})$").match(t) {           // 16/05/2026
            return (Int(m.group(1)!)!, Int(m.group(2)!)!, Int(m.group(3)!)!)
        }
        if let m = PyRegex("^(\\d{1,2})\\s+([A-Za-z]{3,9})\\s+(\\d{4})$").match(t), // 16 May 2026
           let mon = monthNo(m.group(2)!) {
            return (Int(m.group(1)!)!, mon, Int(m.group(3)!)!)
        }
        if let m = PyRegex("^(\\d{1,2})-([A-Za-z]{3,9})$").match(t),                // 17-May
           let mon = monthNo(m.group(2)!) {
            return (Int(m.group(1)!)!, mon, 0)
        }
        if let m = PyRegex("^(\\d{1,2})\\s+([A-Za-z]{3,9})$").match(t),             // 16 May
           let mon = monthNo(m.group(2)!) {
            return (Int(m.group(1)!)!, mon, 0)
        }
        return nil
    }

    /// The shared table parser. Finds the header row, maps columns, parses rows,
    /// then balance-walk-repairs debit/credit assignment.
    static func parseColumnTable(_ doc: PDFTextExtractor,
                                 categories: Categories) -> ([TxnRow], CardStatementSummary) {
        let full = fullText(doc)
        let low = full.pyLower()

        // ---- statement-period year anchor (for year-less date cells) ----
        var em = 0, ey = 0
        for pat in [
            "statement period:?\\s*\\d{1,2}\\s+[A-Za-z]+\\s+\\d{4}\\s*-\\s*\\d{1,2}\\s+([A-Za-z]+)\\s+(\\d{4})",
            "account summary for\\s+\\d{1,2}\\s+[A-Za-z]+\\s+to\\s+\\d{1,2}\\s+([A-Za-z]+)\\s+(\\d{4})",
        ] {
            if let m = PyRegex(pat, ignoreCase: true).search(full),
               let mon = monthNo(m.group(1)!), let yr = Int(m.group(2)!) {
                em = mon; ey = yr
                break
            }
        }

        // ---- summary figures: opening seed for the walk + stated closing ----
        var opening: Double? = nil
        var closing: Double? = nil
        if let m = PyRegex("balance brought forward\\s*paid in\\s*paid out\\s*balance carried forward\\s*£([\\d,]+\\.\\d{2})\\s*£([\\d,]+\\.\\d{2})\\s*£([\\d,]+\\.\\d{2})\\s*£([\\d,]+\\.\\d{2})",
                           ignoreCase: true).search(full) {
            opening = money(m.group(1)!); closing = money(m.group(4)!)      // NatWest
        } else if let m = PyRegex("opening balance\\s*money in\\s*money out\\s*closing balance\\s*£([\\d,]+\\.\\d{2})\\s*£([\\d,]+\\.\\d{2})\\s*£([\\d,]+\\.\\d{2})\\s*£([\\d,]+\\.\\d{2})",
                                  ignoreCase: true).search(full) {
            opening = money(m.group(1)!); closing = money(m.group(4)!)      // Revolut
        } else {
            if let m = PyRegex("start balance\\s*£([\\d,]+\\.\\d{2})", ignoreCase: true).search(full) {
                opening = money(m.group(1)!)                                // Nationwide
            }
            if let m = PyRegex("end balance\\s*£([\\d,]+\\.\\d{2})", ignoreCase: true).search(full) {
                closing = money(m.group(1)!)
            }
            if closing == nil,
               let m = PyRegex("£([\\d,]+\\.\\d{2})\\s*personal account balance",
                               ignoreCase: true).search(full) {
                closing = money(m.group(1)!)                                // Monzo
            }
        }

        // ---- money-column vocabulary (per known layout family) ----
        let outPhrases = ["paid out", "money out", "£ out", "out"]
        let inPhrases = ["paid in", "money in", "£ in", "in"]
        let signedPhrases = ["amount (gbp)", "amount"]
        let signed = low.pyContains("amount (gbp)")   // Monzo: one signed column

        struct Pending {
            var day: Int, mon: Int, yr: Int
            var desc: String
            var debit: Double, credit: Double
            var balance: Double?
        }

        var columns: Columns? = nil
        var pending: [Pending] = []
        var cur: Pending? = nil
        func flush() { if let c = cur { pending.append(c) }; cur = nil }

        for pageIdx in 0..<doc.pageCount {
            guard let page = doc.page(pageIdx) else { continue }
            let pageLines = lines(of: page)
            var startIdx = 0

            // find (or re-find) the header row on this page
            for (idx, ln) in pageLines.enumerated() {
                let j = ln.joined.pyLower()
                guard j.pyContains("balance"), j.pyContains("date") else { continue }
                guard let bal = findLabel(ln, "balance") else { continue }
                var labels: [(String, Double, Double, MoneyKind)] = [("balance", bal.0, bal.1, .balance)]
                if signed {
                    for p in signedPhrases {
                        if let r = findLabel(ln, p) { labels.append((p, r.0, r.1, .signed)); break }
                    }
                } else {
                    for p in outPhrases where findLabel(ln, p) != nil {
                        let r = findLabel(ln, p)!
                        labels.append((p, r.0, r.1, .out_)); break
                    }
                    for p in inPhrases where findLabel(ln, p) != nil {
                        let r = findLabel(ln, p)!
                        // "in" must not re-match the "out" run
                        if !labels.contains(where: { abs($0.1 - r.0) < 1 }) {
                            labels.append((p, r.0, r.1, .in_)); break
                        }
                    }
                    // No separate in/out columns (only "balance" so far) → the layout
                    // may carry a single signed "Amount" column with no "(GBP)" suffix
                    // (some Monzo exports). Fall back to it; unreachable when in/out
                    // labels exist, so the in/out families are untouched. The
                    // balance-walk repair below fixes any sign ambiguity.
                    if labels.count < 2 {
                        for p in signedPhrases {
                            if let r = findLabel(ln, p) { labels.append((p, r.0, r.1, .signed)); break }
                        }
                    }
                }
                guard labels.count >= 2 else { continue }
                let moneyStart = labels.map(\.1).min()!

                // desc zone: from the 2nd header label (Type/Description) to the
                // exchange-rate column (if present) or the first money column
                var descStart = 0.0
                if let dateL = findLabel(ln, "date") {
                    descStart = dateL.1 + 6
                }
                var descEnd = moneyStart - 6
                if let ex = findLabel(ln, "exchange rate") {
                    descEnd = min(descEnd, ex.0 - 6)
                }
                columns = Columns(descStart: descStart, descEnd: descEnd,
                                  moneyLabels: labels.map { (name: $0.0, x0: $0.1, x1: $0.2, kind: $0.3) })
                startIdx = idx + 1
                break
            }

            guard let cols = columns else { continue }   // no header seen yet in the doc

            for ln in pageLines[startIdx...] {
                // split the row into zones
                var dateWords: [PDFWord] = []
                var descWords: [PDFWord] = []
                var moneyWords: [PDFWord] = []
                let moneyStart = cols.moneyLabels.map(\.x0).min()!
                for w in ln.words {
                    if w.x1 < cols.descStart { dateWords.append(w) }
                    else if w.x1 < moneyStart - 4 {
                        if w.x0 <= cols.descEnd { descWords.append(w) }
                        // words between descEnd and the money zone (exchange rate) are dropped
                    } else if amountRe.match(w.text) != nil || w.text.pyUpper() == "CR" {
                        moneyWords.append(w)
                    }
                    // non-numeric words inside the money zone (footers) are ignored
                }

                let dateText = (dateWords.map(\.text) + descWords.map(\.text))
                    .joined(separator: " ")
                // Monzo puts date+desc flush left: try the leading words as a date
                var parsedDate: (Int, Int, Int)? = nil
                var descFromDate: [String] = []
                if let d = parseDateCell(dateWords.map(\.text).joined(separator: " ")) {
                    parsedDate = d
                    descFromDate = descWords.map(\.text)
                } else {
                    // date may be fused into the desc zone's leading words
                    let all = (dateWords + descWords)
                    for take in stride(from: min(3, all.count), through: 1, by: -1) {
                        if let d = parseDateCell(all.prefix(take).map(\.text).joined(separator: " ")) {
                            parsedDate = d
                            descFromDate = all.dropFirst(take).map(\.text)
                            break
                        }
                    }
                }
                _ = dateText

                // amounts → nearest money label by right-edge distance
                var out: Double? = nil, inn: Double? = nil, bal: Double? = nil, sgn: Double? = nil
                for w in ln.words where amountRe.match(w.text) != nil {
                    guard w.x1 >= moneyStart - 4 else { continue }
                    var best: (Double, MoneyKind)? = nil
                    for lab in cols.moneyLabels {
                        let d = abs(w.x1 - lab.x1)
                        if best == nil || d < best!.0 { best = (d, lab.kind) }
                    }
                    switch best!.1 {
                    case .out_: out = money(w.text)
                    case .in_: inn = money(w.text)
                    case .signed: sgn = Double(w.text.replacingOccurrences(of: ",", with: ""))
                    case .balance: bal = money(w.text)
                    }
                }

                if let d = parsedDate {
                    flush()
                    var debit = out ?? 0.0, credit = inn ?? 0.0
                    if let s = sgn {
                        if s < 0 { debit = -s } else { credit = s }
                    }
                    let desc = descFromDate.joined(separator: " ").pyStrip()
                    // skip pure "start/end balance" marker rows
                    if PyRegex("^(start|end|opening|closing) balance$", ignoreCase: true)
                        .match(desc.pyLower()) != nil { continue }
                    cur = Pending(day: d.0, mon: d.1, yr: d.2, desc: desc,
                                  debit: debit, credit: credit, balance: bal)
                } else if cur != nil {
                    // continuation: desc-zone-only rows extend the current txn
                    let hasAmount = out != nil || inn != nil || bal != nil || sgn != nil
                    if hasAmount {
                        if cur!.debit == 0, cur!.credit == 0 {
                            if let o = out { cur!.debit = o }
                            if let i2 = inn { cur!.credit = i2 }
                            if let s = sgn { if s < 0 { cur!.debit = -s } else { cur!.credit = s } }
                        }
                        if cur!.balance == nil { cur!.balance = bal }
                    } else if !descFromDate.isEmpty, dateWords.isEmpty {
                        let extra = descFromDate.joined(separator: " ").pyStrip()
                        if !extra.isEmpty { cur!.desc = (cur!.desc + " " + extra).pyStrip() }
                    }
                }
            }
            flush()
        }
        flush()

        // ---- balance-walk repair: the walk is ground truth for debit vs credit ----
        var prev = opening
        for i in 0..<pending.count {
            guard let bal = pending[i].balance else { continue }
            if let p = prev {
                let delta = bal - p
                let recorded = pending[i].credit - pending[i].debit
                if abs(delta - recorded) > 0.005 {
                    let amt = max(pending[i].debit, pending[i].credit)
                    if abs(delta - amt) < 0.005 {
                        pending[i].credit = amt; pending[i].debit = 0
                    } else if abs(delta + amt) < 0.005 {
                        pending[i].debit = amt; pending[i].credit = 0
                    }
                }
            }
            prev = bal
        }

        // ---- emit ----
        var rows: [TxnRow] = []
        var seq = 0
        for p in pending {
            guard p.debit > 0 || p.credit > 0 else { continue }   // marker rows carry no amount
            let yr = p.yr != 0 ? p.yr : yearFor(month: p.mon, endMonth: em, endYear: ey)
            guard yr > 0 else { continue }
            let iso = String(format: "%04d-%02d-%02d", yr, p.mon, p.day)
            let desc = PyRegex("\\s+").sub(" ", p.desc).pyStrip()
            guard !desc.isEmpty else { continue }
            let isCredit = p.credit > 0
            let (merchant, category) = Classify.barclaysMerchant(desc, isCredit: isCredit,
                                                                 categories: categories)
            seq += 1
            rows.append(TxnRow(txnDate: iso, month: iso.pyPrefix(7), year: yr,
                               monthNo: p.mon, day: p.day,
                               descr: desc.pyPrefix(200), merchant: merchant, category: category,
                               debit: p.debit, credit: p.credit, balance: p.balance,
                               currency: "GBP", seq: seq))
        }

        return (rows, CardStatementSummary(closingBalance: closing, isCard: false))
    }
}
