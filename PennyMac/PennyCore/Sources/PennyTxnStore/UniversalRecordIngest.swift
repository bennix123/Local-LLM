// UniversalRecordIngest — bank-agnostic last-resort statement reader.
//
// Targets the record-block shape no dedicated parser knows: a repeating
// multi-line record opened by a date line ("23 Aug" / "23 Aug 2026" /
// "23/08/2026"), followed by description/ID/amount lines, e.g. app exports
// (Paytm UPI, GPay-style) and unknown banks. NOTHING here is per-bank: the
// layout is inferred from the document itself (repeated furniture lines,
// date anchors, money-token positions, statement-period years).
//
// Safety contract: output is accepted ONLY when the document proves it —
// either every consecutive balance reconciles (balance chain), or the
// statement's own printed totals match the parsed sums. Anything else
// returns nil and the caller keeps its honest rejection. A silent partial
// import is the one failure mode this module is not allowed to have.
import Foundation

public enum UniversalRecordIngest {

    public struct Output {
        public let rows: [TxnRow]
        public let currency: String
        /// How the import proved itself: "balance-chain" or "printed-totals".
        public let verification: String
    }

    // MARK: - regex helpers

    private static func re(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
    private static func firstMatch(_ rx: NSRegularExpression, _ s: String) -> [String?]? {
        guard let m = rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) }
        }
    }
    private static func wholeMatch(_ rx: NSRegularExpression, _ s: String) -> [String?]? {
        guard let g = firstMatch(rx, s), let whole = g[0],
              whole.count == s.count else { return nil }
        return g
    }

    private static let monthNums: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12]

    // "23 Aug", "23 Aug 2026", "23-Aug-26", "23 Aug'25"
    private static let dmyRe = re(#"^(\d{1,2})[ /\-.]([A-Za-z]{3,9})\.?(?:[ /\-.,]*'?(\d{2,4}))?$"#)
    // "Aug 23, 2026" / "Aug 23"
    private static let mdyRe = re(#"^([A-Za-z]{3,9})\.?[ ]+(\d{1,2})(?:[ ,]+'?(\d{2,4}))?$"#)
    // "23/08/2026", "23-08-26"
    private static let numRe = re(#"^(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{2,4})$"#)
    // "2026-08-23"
    private static let isoRe = re(#"^(\d{4})-(\d{2})-(\d{2})$"#)

    private static let timeRe = re(#"^\d{1,2}:\d{2}(:\d{2})?\s*(am|pm)?$"#)
    private static let idLineRe = re(#"(upi ref|order id|transaction id|reference n|ref no\b|\butr\b|txn id|ifsc)"#)
    private static let pageFurnitureRe = re(#"^page( |$)|^\d+ *(of|/) *\d+$|^\d{1,3}$"#)
    private static let moneyRe = re(#"([-+])?\s*(?:rs\.?|inr|₹|\$|£|€|usd|gbp|eur)\s*([\d,]+(?:\.\d{1,2})?)|([-+])\s*([\d,]+\.\d{2})\b|(?<![\d.,-])([\d,]+\.\d{2})\b"#)
    private static let currencySniffRe = re(#"(₹|rs\.?|inr)|(£|gbp)|(\$|usd)|(€|eur)"#)

    private struct DateHit { let day: Int; let month: Int; let year: Int? }

    private static func parseYear(_ raw: String?) -> Int? {
        guard let raw, let n = Int(raw) else { return nil }
        if raw.count == 4 { return n }
        return n + 2000
    }

    private static func dateAnchor(_ line: String) -> DateHit? {
        if let g = wholeMatch(dmyRe, line), let d = Int(g[1] ?? ""),
           let mo = monthNums[String((g[2] ?? "").lowercased().prefix(4))]
               ?? monthNums[String((g[2] ?? "").lowercased().prefix(3))], (1...31).contains(d) {
            return DateHit(day: d, month: mo, year: parseYear(g[3]))
        }
        if let g = wholeMatch(mdyRe, line), let d = Int(g[2] ?? ""),
           let mo = monthNums[String((g[1] ?? "").lowercased().prefix(3))], (1...31).contains(d) {
            return DateHit(day: d, month: mo, year: parseYear(g[3]))
        }
        if let g = wholeMatch(numRe, line), let a = Int(g[1] ?? ""), let b = Int(g[2] ?? ""),
           let y = parseYear(g[3]) {
            // day-first unless impossible
            if a <= 31, b <= 12 { return DateHit(day: a, month: b, year: y) }
            if a <= 12, b <= 31 { return DateHit(day: b, month: a, year: y) }
            return nil
        }
        if let g = wholeMatch(isoRe, line), let y = Int(g[1] ?? ""), let mo = Int(g[2] ?? ""),
           let d = Int(g[3] ?? ""), (1...12).contains(mo), (1...31).contains(d) {
            return DateHit(day: d, month: mo, year: y)
        }
        return nil
    }

    private struct MoneyTok { let value: Double; let sign: Int }   // sign: -1 debit, +1 credit, 0 none

    private static func moneyTokens(_ line: String) -> [MoneyTok] {
        var out: [MoneyTok] = []
        let ns = NSRange(line.startIndex..., in: line)
        moneyRe.enumerateMatches(in: line, range: ns) { m, _, _ in
            guard let m else { return }
            func grp(_ i: Int) -> String? {
                guard m.numberOfRanges > i, let r = Range(m.range(at: i), in: line) else { return nil }
                return String(line[r])
            }
            let signStr = grp(1) ?? grp(3)
            let numStr = (grp(2) ?? grp(4) ?? grp(5) ?? "").replacingOccurrences(of: ",", with: "")
            guard let v = Double(numStr), v < 100_000_000 else { return }
            let sign = signStr == "-" ? -1 : (signStr == "+" ? 1 : 0)
            out.append(MoneyTok(value: v, sign: sign))
        }
        return out
    }

    // MARK: - main

    public static func parse(pages: [String], categories: Categories) -> Output? {
        guard !pages.isEmpty else { return nil }
        let pageLines: [[String]] = pages.map {
            $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        // Furniture: identical lines repeated across most pages are headers/
        // footers, not data. (Only meaningful with 3+ pages.)
        var lineFreq: [String: Int] = [:]
        for lines in pageLines { for l in Set(lines) { lineFreq[l, default: 0] += 1 } }
        let furnitureFloor = max(3, Int(Double(pageLines.count) * 0.5))
        let furniture = Set(lineFreq.filter { pageLines.count >= 3 && $0.value >= furnitureFloor }.map(\.key))

        let allText = pages.joined(separator: "\n")
        let low = allText.lowercased()

        // Currency: majority symbol in the document.
        var curVotes: [String: Int] = [:]
        currencySniffRe.enumerateMatches(in: low, range: NSRange(low.startIndex..., in: low)) { m, _, _ in
            guard let m else { return }
            for (i, cur) in [(1, "INR"), (2, "GBP"), (3, "USD"), (4, "EUR")] {
                if m.range(at: i).location != NSNotFound { curVotes[cur, default: 0] += 1 }
            }
        }
        let currency = curVotes.max { $0.value < $1.value }?.key ?? "INR"

        // Years present anywhere ('25 / 2025 styles) — bounds for bare "23 Aug"
        // dates. A statement period like 27 AUG'25 – 26 AUG'26 spans two years;
        // month decides which one.
        var years: Set<Int> = []
        let yearRx = re(#"'(\d{2})\b|\b(20\d{2})\b"#)
        yearRx.enumerateMatches(in: allText, range: NSRange(allText.startIndex..., in: allText)) { m, _, _ in
            guard let m else { return }
            for i in [1, 2] where m.range(at: i).location != NSNotFound {
                if let r = Range(m.range(at: i), in: allText), let n = Int(allText[r]) {
                    years.insert(n < 100 ? n + 2000 : n)
                }
            }
        }
        // Period edges, when stated: "<d MMM'yy> ... - ... <d MMM'yy>"
        var periodStart: (y: Int, m: Int)? = nil, periodEnd: (y: Int, m: Int)? = nil
        if let g = firstMatch(re(#"(\d{1,2})\s+([A-Za-z]{3,9})\s*'?(\d{2,4})\s*[-–—]|to\s+(\d{1,2})\s+([A-Za-z]{3,9})\s*'?(\d{2,4})"#), allText),
           let mo = monthNums[String((g[2] ?? "").lowercased().prefix(3))], let y = parseYear(g[3]) {
            periodStart = (y, mo)
        }
        if let g = firstMatch(re(#"[-–—]\s*(\d{1,2})\s+([A-Za-z]{3,9})\s*'?(\d{2,4})"#), allText),
           let mo = monthNums[String((g[2] ?? "").lowercased().prefix(3))], let y = parseYear(g[3]) {
            periodEnd = (y, mo)
        }

        func inferYear(month: Int) -> Int {
            if let s = periodStart, let e = periodEnd, s.y != e.y {
                // Two-year window: months >= start-month belong to the first year.
                return month >= s.m ? s.y : e.y
            }
            if let e = periodEnd { return e.y }
            if let s = periodStart { return s.y }
            return years.max() ?? Calendar.current.component(.year, from: Date())
        }

        // ---- segment into records at date-anchor lines --------------------
        struct Record { var date: DateHit; var lines: [String] }
        var records: [Record] = []
        for lines in pageLines {
            for line in lines {
                if furniture.contains(line) { continue }
                if firstMatch(pageFurnitureRe, line.lowercased()) != nil { continue }
                if let hit = dateAnchor(line) {
                    records.append(Record(date: hit, lines: []))
                } else if !records.isEmpty {
                    records[records.count - 1].lines.append(line)
                }
            }
        }
        guard records.count >= 3 else { return nil }

        // ---- interpret each record ----------------------------------------
        struct Parsed {
            let iso: String; let y: Int; let m: Int; let d: Int
            let descr: String; let hint: String?
            let amount: Double; let isCredit: Bool
            let balance: Double?
            let isSelfTransfer: Bool
        }
        var parsed: [Parsed] = []
        for rec in records {
            var toks: [MoneyTok] = []
            var descLines: [String] = []
            var hint: String? = nil
            for l in rec.lines {
                if wholeMatch(timeRe, l.lowercased()) != nil { continue }
                if firstMatch(idLineRe, l.lowercased()) != nil { continue }
                let lineToks = moneyTokens(l)
                if let g = firstMatch(re(#"^tags?\s*:?\s*#?\s*(.+)$"#), l.lowercased()), let h = g[1] {
                    hint = h.trimmingCharacters(in: .whitespaces)
                    continue
                }
                if !lineToks.isEmpty {
                    toks.append(contentsOf: lineToks)
                    // A money line can still carry words ("Amount Rs.60 Cashback") —
                    // keep its words minus the token for description context.
                    continue
                }
                descLines.append(l)
            }
            guard !toks.isEmpty else { continue }

            // Amount: the signed token when present; else the first. Balance:
            // when a record shows an unsigned token AFTER the amount, treat it
            // as a candidate running balance (validated by the chain gate).
            let amountTok = toks.first(where: { $0.sign != 0 }) ?? toks[0]
            var balance: Double? = nil
            if let ai = toks.firstIndex(where: { $0.value == amountTok.value && $0.sign == amountTok.sign }),
               ai + 1 < toks.count, toks[ai + 1].sign == 0 {
                balance = toks[ai + 1].value
            }

            let textLow = rec.lines.joined(separator: " ").lowercased()
            var isCredit: Bool
            switch amountTok.sign {
            case 1:  isCredit = true
            case -1: isCredit = false
            default:
                isCredit = firstMatch(re(#"received|credited|refund|cashback|deposit|interest earned"#), textLow) != nil
            }
            let isSelf = firstMatch(re(#"self[- ]?transfer|own account|added to wallet"#), textLow) != nil

            let y = rec.date.year ?? inferYear(month: rec.date.month)
            let iso = String(format: "%04d-%02d-%02d", y, rec.date.month, rec.date.day)
            let descr = descLines.prefix(3).joined(separator: " ")
            guard !descr.isEmpty else { continue }
            parsed.append(Parsed(iso: iso, y: y, m: rec.date.month, d: rec.date.day,
                                 descr: descr, hint: hint,
                                 amount: amountTok.value, isCredit: isCredit,
                                 balance: balance, isSelfTransfer: isSelf))
        }
        guard parsed.count >= 3 else { return nil }

        // ---- verification gate --------------------------------------------
        var verification: String? = nil

        // (a) balance chain, in document order or reversed.
        let withBal = parsed.filter { $0.balance != nil }
        if withBal.count == parsed.count {
            func chainHolds(_ seq: [Parsed]) -> Bool {
                for i in 1..<seq.count {
                    let expect = seq[i - 1].balance! + (seq[i].isCredit ? seq[i].amount : -seq[i].amount)
                    if abs(expect - seq[i].balance!) > 0.011 { return false }
                }
                return true
            }
            if chainHolds(parsed) || chainHolds(parsed.reversed()) { verification = "balance-chain" }
        }

        // (b) the statement's own printed totals.
        if verification == nil {
            func harvest(_ pattern: String) -> Double? {
                guard let g = firstMatch(re(pattern), low), let raw = g[1] else { return nil }
                return Double(raw.replacingOccurrences(of: ",", with: ""))
            }
            let statedPaid = harvest(#"total (?:money )?(?:paid|debits?|debited|withdrawals?|spent)[^\d]{0,30}([\d,]+(?:\.\d{1,2})?)"#)
            let statedRecv = harvest(#"total (?:money )?(?:received|credits?|credited|deposits?)[^\d]{0,30}([\d,]+(?:\.\d{1,2})?)"#)
            let sumDebit = parsed.filter { !$0.isCredit && !$0.isSelfTransfer }.reduce(0) { $0 + $1.amount }
            let sumCredit = parsed.filter { $0.isCredit && !$0.isSelfTransfer }.reduce(0) { $0 + $1.amount }
            func close(_ a: Double, _ b: Double) -> Bool {
                abs(a - b) <= max(1.0, b * 0.01)
            }
            if let p = statedPaid, close(sumDebit, p),
               statedRecv == nil || close(sumCredit, statedRecv!) {
                verification = "printed-totals"
            }
        }
        guard let verification else { return nil }

        // ---- build rows ----------------------------------------------------
        var rows: [TxnRow] = []
        for (i, p) in parsed.enumerated() {
            let (merchant, category) = Classify.classify(p.descr, isCredit: p.isCredit,
                                                         categories: categories)
            var cat = category
            var rawCat: String? = nil
            if let hint = p.hint, let norm = Describe.normalizeCategory(hint) {
                cat = norm; rawCat = hint
            }
            var row = TxnRow(txnDate: p.iso, month: String(p.iso.prefix(7)),
                             year: p.y, monthNo: p.m, day: p.d,
                             descr: p.descr, merchant: merchant, category: cat,
                             debit: p.isCredit ? 0 : p.amount,
                             credit: p.isCredit ? p.amount : 0,
                             balance: p.balance, currency: currency, seq: i)
            if let rawCat { row.rawCategory = rawCat }
            rows.append(row)
        }
        return Output(rows: rows, currency: currency, verification: verification)
    }
}
