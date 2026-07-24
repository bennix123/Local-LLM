// DateParse — DATE_PATTERNS / parse_date() / _gen_row_date() from parsers.py.
import Foundation

enum DateParse {
    static let mon3: [String: Int] = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                      "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    /// _PNB_MON / _BARCLAYS_MON: Title-cased month -> number.
    static let monTitle: [String: Int] = ["Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5,
                                          "Jun": 6, "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10,
                                          "Nov": 11, "Dec": 12]

    static let datePatterns: [PyRegex] = [
        PyRegex("^(\\d{4})[-/.](\\d{2})[-/.](\\d{2})$"),
        PyRegex("^(\\d{2})[-/.](\\d{2})[-/.](\\d{4})$"),
        PyRegex("^(\\d{2})-([A-Za-z]{3,9})-(\\d{2,4})$"),
        PyRegex("^(\\d{2})\\s+([A-Za-z]{3,9})\\s+(\\d{2,4})$"),
        PyRegex("^(\\d{2})/(\\d{2})/(\\d{2})$"),
    ]

    /// parse_date(): (year, month, day) or nil. NOTE: mirrors the Python
    /// exactly, including its quirks (no month/day range validation here).
    static func parseDate(_ t: String) -> (Int, Int, Int)? {
        let tClean = t.pyStrip()
        for pat in datePatterns {
            guard let m = pat.match(tClean) else { continue }
            let g = m.groups()
            guard g.count == 3, let g0 = g[0], let g1 = g[1], let g2 = g[2] else { continue }
            if g0.count == 4 {
                return (Int(g0)!, Int(g1)!, Int(g2)!)
            }
            let mon: Int
            if g1.first!.isLetter {
                mon = mon3[g1.pyPrefix(3).pyLower()] ?? 1
            } else {
                mon = Int(g1)!
            }
            let day = Int(g0)!
            var yr = Int(g2)!
            if yr < 100 { yr += 2000 }
            return (yr, mon, day)
        }
        return nil
    }

    /// The two numeric components of an ambiguous numeric date token, in the
    /// order they appear: "06/30/26" -> (6, 30). nil for month-name and
    /// ISO (yyyy-mm-dd) formats, which are unambiguous. Used for per-document
    /// day/month order inference: if any token's SECOND component exceeds 12
    /// while no FIRST component does, the document is month-first (US MM/DD)
    /// and the day-first reading `parseDate`/`genRowDate` mirror from the
    /// Python reference must be swapped.
    static let numericDMRe = PyRegex("^(\\d{1,2})[-/.](\\d{1,2})[-/.](\\d{2,4})$")
    static func numericDayMonth(_ t: String) -> (Int, Int)? {
        guard let m = numericDMRe.match(t.pyStrip()) else { return nil }
        let g = m.groups()
        guard let a = g[0], let b = g[1], let x = Int(a), let y = Int(b) else { return nil }
        return (x, y)
    }

    /// Decide month-first (US) date order from every numeric date in a document.
    static func inferMonthFirst(_ pairs: [(Int, Int)]) -> Bool {
        pairs.contains { $0.1 > 12 } && !pairs.contains { $0.0 > 12 }
    }

    // ---- _gen_row_date machinery (generic date-inherited parser)

    static let genMoneyRe = PyRegex("^-?[£$€₹]?[\\d,]+\\.\\d{2}(?:\\s?(?:cr|dr))?$", ignoreCase: true)
    static let genSummaryRe = PyRegex(
        "start balance|end balance|opening balance|closing balance|total balance|money in|" +
        "money out|at a glance|statement period|brought forward|balance b/?f", ignoreCase: true)

    static func genMoney(_ s: String) -> Double {
        Double(PyRegex("[£$€₹,]|(?:\\s?(?:cr|dr))", ignoreCase: true).sub("", s).pyStrip()) ?? 0.0
    }

    static func genValid(_ mo: Int, _ d: Int) -> Bool {
        (1...12).contains(mo) && (1...31).contains(d)
    }

    /// _gen_row_date(): ((year?, month, day), consumed indices) or (nil, []).
    /// `monthFirst` swaps the numeric day/month reading for US (MM/DD) docs —
    /// decided per-document via `inferMonthFirst`, default keeps the Python
    /// reference's day-first reading.
    static func genRowDate(_ toks: [String], monthFirst: Bool = false) -> ((Int?, Int, Int)?, Set<Int>) {
        let full1 = PyRegex("(\\d{1,2})[/-](\\d{1,2})[/-](\\d{2,4})")
        let full2 = PyRegex("(\\d{4})-(\\d{2})-(\\d{2})")
        for (i, t) in toks.enumerated() {
            let m = full1.fullmatch(t) ?? full2.fullmatch(t)
            guard let m else { continue }
            let g = m.groups()
            guard let g0 = g[0], let g1 = g[1], let g2 = g[2] else { continue }
            let y: Int, mo: Int, d: Int
            if g0.count == 4 {
                y = Int(g0)!; mo = Int(g1)!; d = Int(g2)!
            } else {
                var yy = Int(g2)!
                if yy < 100 { yy += 2000 }
                y = yy
                if monthFirst {
                    mo = Int(g0)!; d = Int(g1)!
                } else {
                    mo = Int(g1)!; d = Int(g0)!
                }
            }
            if genValid(mo, d) {
                return ((y, mo, d), [i])
            }
        }
        guard toks.count >= 2 else { return (nil, []) }
        let dayRe = PyRegex("\\d{1,2}")
        let yearRe = PyRegex("20\\d\\d")
        for i in 0..<(toks.count - 1) {
            let a = toks[i].pyStrip(".,"), b = toks[i + 1].pyStrip(".,")
            var used: Set<Int> = [i, i + 1]
            var yr: Int? = nil
            if i + 2 < toks.count, yearRe.fullmatch(toks[i + 2]) != nil {
                yr = Int(toks[i + 2])!
                used.insert(i + 2)
            }
            let aMon = mon3[a.pyPrefix(3).pyLower()]
            let bMon = mon3[b.pyPrefix(3).pyLower()]
            if dayRe.fullmatch(a) != nil, let bm = bMon, genValid(bm, Int(a)!) {
                return ((yr, bm, Int(a)!), used)
            }
            if let am = aMon, dayRe.fullmatch(b) != nil, genValid(am, Int(b)!) {
                return ((yr, am, Int(b)!), used)
            }
        }
        return (nil, [])
    }
}
