// PaytmParser — Paytm Payments Bank app-export statements.
//
// Layout (linearized text, one field per line):
//   06 Jan 2023            ← date
//   12:22 PM               ← time
//   Money Sent using UPI   ← transaction kind
//   VPA: nancysingh491-1@okicici
//   A/C No: XX 0046 (PUNB0184410)
//   Transaction ID: S89334367
//   Reference Number: 300694425878
//   -  Rs.50.00            ← signed amount (single column, not Debit|Credit)
//   Rs.228.48              ← available balance
//   Sent to: NANCY SINGH   ← counterparty (after the balance, still this txn)
//
// The signed single AMOUNT column plus the "DATE & TIME / TRANSACTION DETAILS /
// AMOUNT / AVAILABLE BALANCE" banner is what distinguishes this from the
// Debit|Credit columnar layout, so none of the existing parsers can read it.
// Descriptions keep the kind + VPA + counterparty lines and drop bookkeeping
// noise (transaction/reference IDs, page furniture) — IDs are unique per row
// and would defeat descriptor de-duplication downstream.
import Foundation

extension BankParsers {

    /// Detects the Paytm Payments Bank statement LAYOUT, not a mere mention of
    /// Paytm: other banks' UPI narrations routinely contain "@paytm" handles or
    /// the PYTM IFSC, so the column banner is required alongside a bank marker.
    static func isPaytmStatement(_ text: String) -> Bool {
        let low = text.pyLower()
        return low.pyContains("date & time") && low.pyContains("transaction details")
            && low.pyContains("available balance")
            && (low.pyContains("paytm payments bank") || low.pyContains("pytm0")
                || low.pyContains("ppbl"))
    }

    static func parsePaytm(_ doc: PDFTextExtractor, categories: Categories) -> [TxnRow] {
        var lines: [String] = []
        for i in 0..<doc.pageCount {
            lines.append(contentsOf: (doc.page(i)?.text ?? "").pySplitLines().map { $0.pyStrip() })
        }

        let dateRe = PyRegex("^(\\d{1,2}) ([A-Z][a-z]{2}) (\\d{4})$")
        let timeRe = PyRegex("^\\d{1,2}:\\d{2} (AM|PM)$")
        let amtRe = PyRegex("^([+-])\\s*Rs\\.?\\s*([\\d,]+(?:\\.\\d{1,2})?)$")
        let balRe = PyRegex("^Rs\\.?\\s*([\\d,]+(?:\\.\\d{1,2})?)$")
        // Bookkeeping/furniture lines excluded from the description: per-row IDs
        // (unique every row — they'd defeat descriptor dedup), account plumbing,
        // column headers and page banners that leak into page-spanning blocks.
        let junkRe = PyRegex("""
            (?ix)^(
              transaction\\ id | reference\\ n | upi\\ reference | imps\\ reference |
              neft\\ reference | a/c\\ no | from\\ account\\ number |
              bank\\ account\\ linked | remarks\\ ?: |
              date\\ &\\ time | transaction\\ details | amount$ | available\\ balance |
              page\\ \\d+ | never\\ share | gstin | ppbl\\  | need\\ help | \\*{2,} |
              fixed\\ deposit | total\\ deposit | total\\ withdr | available\\ deposit |
              active\\ fixed | booking\\ date | this\\ statement\\ contains
            )
            """)

        // Counterparty extraction: "Sent to: NANCY SINGH", "Received from X",
        // "Paid successfully at Y". ("Received for …" is excluded — it prefixes
        // period notes like "Received for the period 01-01-2023…", not payees.)
        let payeeRe = PyRegex("(?i)^(?:sent to:?|received from:?|paid successfully at|paid to:?)\\s+(.+)$")

        // A transaction block starts at a bare date line immediately followed by
        // a bare time line (the summary box and header dates are inline, so they
        // can't false-start a block).
        var starts: [Int] = []
        for i in 0..<lines.count where dateRe.match(lines[i]) != nil {
            if i + 1 < lines.count, timeRe.match(lines[i + 1]) != nil { starts.append(i) }
        }

        var out: [TxnRow] = []
        var seq = 0
        for (n, start) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1] : lines.count
            let block = Array(lines[start..<end])
            guard let dm = dateRe.match(block[0]),
                  let monthNo = DateParse.monTitle[dm.group(2)!],
                  let day = Int(dm.group(1)!), let year = Int(dm.group(3)!) else { continue }

            // First signed amount, then the first balance line after it.
            guard let amtIdx = block.indices.first(where: { amtRe.match(block[$0]) != nil }),
                  let am = amtRe.match(block[amtIdx]) else { continue }
            let balIdx = block.indices.first { $0 > amtIdx && balRe.match(block[$0]) != nil }
            let balance = balIdx.flatMap { balRe.match(block[$0])?.group(1) }.map { money($0) }

            // Detail lines before the amount (kind, VPA…) and the counterparty
            // line(s) right after the balance, minus bookkeeping noise. The tail
            // stops at the first junk/number line so trailing sections (page
            // footers, the fixed-deposit summary after the last transaction)
            // never leak into the final row's description.
            var details: [String] = []
            for idx in 2..<amtIdx {
                let l = block[idx]
                guard !l.isEmpty, junkRe.search(l) == nil,
                      dateRe.match(l) == nil, timeRe.match(l) == nil,
                      balRe.match(l) == nil else { continue }
                details.append(l)
            }
            var payeeParts: [String] = []
            var tail = (balIdx ?? amtIdx) + 1
            while tail < block.count, payeeParts.count < 8 {
                let l = block[tail]
                guard !l.isEmpty, junkRe.search(l) == nil, dateRe.match(l) == nil,
                      timeRe.match(l) == nil, amtRe.match(l) == nil,
                      balRe.match(l) == nil else { break }
                payeeParts.append(l)
                tail += 1
            }
            // The payee LEADS the description — categorization is merchant-first
            // (who was paid), the "Money Sent using UPI" rail is trailing context.
            let descr = PyRegex("\\s+").sub(" ", (payeeParts + details).joined(separator: " ")).pyStrip()
            guard !descr.isEmpty else { continue }

            let amount = money(am.group(2)!)
            let isCredit = am.group(1)! == "+"
            var (merchant, category) = Classify.classify(descr, isCredit: isCredit,
                                                         categories: categories)
            // The statement names the counterparty outright — that IS the
            // merchant ("Sent to: NANCY SINGH", "Paid successfully at RADHEYSHYAM
            // FRUITS AND SNACKS"), so it beats the slug Classify derives.
            for l in payeeParts {
                if var name = payeeRe.search(l)?.group(1)?.pyStrip(), !name.isEmpty {
                    // "Received from Razorpay Composite 2 A/C No 0047…" — the
                    // account plumbing is not part of the merchant's name.
                    name = PyRegex("(?i)\\s+a/c\\s+no\\b.*$").sub("", name).pyStrip()
                    if !name.isEmpty { merchant = name.pyPrefix(60) }
                    break
                }
            }
            let iso = String(format: "%04d-%02d-%02d", year, monthNo, day)
            seq += 1
            out.append(TxnRow(txnDate: iso, month: iso.pyPrefix(7), year: year,
                              monthNo: monthNo, day: day, descr: descr,
                              merchant: merchant, category: category,
                              debit: isCredit ? 0 : amount, credit: isCredit ? amount : 0,
                              balance: balance, currency: "INR", seq: seq))
        }
        return out
    }
}
