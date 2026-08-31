// AccountQuery — deterministic answers for the ACCOUNT dimension and its
// neighbours, shared by both apps' pre-router gates (same pattern as the
// bank-roster gate): "how much did I pay from Union Bank?", "who sent me
// money?", "did I transfer between my own accounts?", "when did X pay me?".
//
// Lives OUTSIDE the frozen FinanceQuery router chain. Everything here is
// summed from parsed rows; nothing is guessed. Answers nil whenever the
// question isn't one of these shapes, so the caller falls through to its
// normal chain.
import Foundation

public enum AccountQuery {

    private static func has(_ low: String, _ pat: String) -> Bool {
        low.range(of: pat, options: [.regularExpression]) != nil
    }

    /// Words too generic to identify one account ("Bank" is in every label).
    private static let genericAccountWords: Set<String> =
        ["bank", "banks", "of", "the", "ltd", "limited", "co", "and"]

    /// Distinctive tokens of an account label — "Union Bank Of India -49"
    /// → ["union", "india", "49"].
    private static func accountTokens(_ label: String) -> [String] {
        label.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !genericAccountWords.contains($0) && $0.count >= 2 }
    }

    /// The accounts a question names, from the accounts present in the rows.
    private static func mentionedAccounts(_ low: String, rows: [TxnRow]) -> [String] {
        let labels = Array(Set(rows.compactMap(\.account))).sorted()
        return labels.filter { label in
            accountTokens(label).contains { has(low, #"\b"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"#) }
        }
    }

    /// Main entry: nil unless the question is an account-dimension /
    /// counterparty / self-transfer lookup this module owns.
    public static func answer(_ question: String, rows: [TxnRow],
                              money: (Double) -> String) -> String? {
        let low = question.lowercased()

        if let a = selfTransferAnswer(low, rows: rows, money: money) { return a }
        if let a = whoSentMoneyAnswer(low, rows: rows, money: money) { return a }
        if let a = perAccountAnswer(low, rows: rows, money: money) { return a }
        return nil
    }

    // MARK: - per-account totals / counts

    private static func perAccountAnswer(_ low: String, rows: [TxnRow],
                                         money: (Double) -> String) -> String? {
        let named = mentionedAccounts(low, rows: rows)
        guard !named.isEmpty,
              has(low, #"how much|how many|total|count|pa(?:y|id)|spen[dt]|sent|receiv|credit|debit|payments?|transactions?|txns?"#)
        else { return nil }

        // Direction: credits when the question is about money coming in,
        // debits otherwise ("payments from X" is money going out).
        let wantsCredits = has(low, #"receiv|credited|\bincome\b|came in|come in|\bgot\b|deposit"#)
        let wantsCount = has(low, #"how many|count|number of"#)

        func describe(_ label: String) -> String {
            let acctRows = rows.filter { $0.account == label }
            let real = acctRows.filter { !$0.isSelfTransfer }
            let selfN = acctRows.count - real.count
            let side = real.filter { wantsCredits ? $0.credit > 0 : $0.debit > 0 }
            let total = side.reduce(0) { $0 + (wantsCredits ? $1.credit : $1.debit) }
            let n = side.count
            let noun = wantsCredits ? (n == 1 ? "credit" : "credits")
                                    : (n == 1 ? "payment" : "payments")
            var out: String
            if n == 0 {
                out = wantsCredits
                    ? "**Nothing came into \(label)** in this statement."
                    : "**No payments went out of \(label)** in this statement."
            } else if wantsCount {
                out = "**\(n) \(noun) \(wantsCredits ? "into" : "from") \(label)**, totalling \(money(total))."
            } else if wantsCredits {
                out = "**You received \(money(total)) into \(label)** across \(n) \(noun)."
            } else {
                out = "**You paid \(money(total)) from \(label)** across \(n) \(noun)."
            }
            if selfN > 0 {
                out += " (\(selfN) transfer\(selfN == 1 ? "" : "s") between your own accounts not counted.)"
            }
            return out
        }

        if named.count == 1 { return describe(named[0]) }
        return named.map(describe).joined(separator: "\n")
    }

    // MARK: - who sent me money

    private static func whoSentMoneyAnswer(_ low: String, rows: [TxnRow],
                                           money: (Double) -> String) -> String? {
        guard has(low, #"who (?:sent|paid|gave|transferred)|who did i (?:receive|get)|where did (?:my |the )?money come from|who.{0,16}money (?:from|came)"#)
        else { return nil }
        let credits = rows.filter { $0.credit > 0 && !$0.isSelfTransfer }
        guard !credits.isEmpty else { return "**No incoming payments in this statement.**" }

        func sender(_ r: TxnRow) -> String {
            var d = r.descr
            for cut in [" UPI ID:", " Note:", " upi id:"] {
                if let range = d.range(of: cut) { d = String(d[..<range.lowerBound]) }
            }
            for prefix in ["Received from ", "received from ", "Refund from ", "Money received from "] {
                if d.hasPrefix(prefix) { d = String(d.dropFirst(prefix.count)) }
            }
            let t = d.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? r.descr : t
        }
        var totals: [String: (total: Double, count: Int)] = [:]
        for r in credits {
            let k = sender(r)
            let cur = totals[k] ?? (0, 0)
            totals[k] = (cur.total + r.credit, cur.count + 1)
        }
        let ranked = totals.sorted { $0.value.total > $1.value.total }
        var lines = ["**Money came in from \(ranked.count) sender\(ranked.count == 1 ? "" : "s"):**"]
        for (name, v) in ranked.prefix(12) {
            lines.append("- \(name) — \(money(v.total))\(v.count > 1 ? " (\(v.count)×)" : "")")
        }
        if ranked.count > 12 { lines.append("_…and \(ranked.count - 12) more._") }
        return lines.joined(separator: "\n")
    }

    // MARK: - self-transfers / UPI Lite

    private static func selfTransferAnswer(_ low: String, rows: [TxnRow],
                                           money: (Double) -> String) -> String? {
        let asksUPILite = has(low, #"upi ?lite"#)
        let asksSelf = has(low, #"self[- ]?transfers?|between my (?:own )?(?:bank )?accounts?|(?:transfer|send|sent|move[d]?).{0,24}(?:my ?self|own account)|own accounts?\b"#)
        guard asksUPILite || asksSelf else { return nil }
        guard asksUPILite || has(low, #"transfer|move|sent|send|did i|how (?:much|many)|between"#) else { return nil }

        let picked = asksUPILite
            ? rows.filter { $0.descr.lowercased().contains("upi lite") }
            : rows.filter(\.isSelfTransfer)
        let what = asksUPILite ? "UPI Lite" : "your own accounts"
        guard !picked.isEmpty else {
            return "**No transfers \(asksUPILite ? "to \(what)" : "between \(what)") found in this statement.**"
        }
        let total = picked.reduce(0) { $0 + max($1.debit, $1.credit) }
        var lines = ["**Yes — \(picked.count) transfer\(picked.count == 1 ? "" : "s") \(asksUPILite ? "to \(what)" : "between \(what)"), totalling \(money(total)):**"]
        for r in picked.sorted(by: { $0.txnDate < $1.txnDate }).prefix(10) {
            var line = "- \(prettyISO(r.txnDate)) — \(money(max(r.debit, r.credit)))"
            if let acct = r.account { line += " via \(acct)" }
            lines.append(line)
        }
        if picked.count > 10 { lines.append("_…and \(picked.count - 10) more._") }
        lines.append("_These aren't counted as spending or income._")
        return lines.joined(separator: "\n")
    }

    // MARK: - timing questions ("when did X pay me?")

    /// True when the question asks WHEN, not how much — the caller's keyword
    /// fallback should answer with dates, not a count/total.
    public static func isTimingQuestion(_ question: String) -> Bool {
        has(question.lowercased(), #"^\s*when\b|what (?:date|day)\b|which (?:date|day)\b|on what (?:date|day)"#)
    }

    /// Date-focused phrasing for rows a keyword/scope fallback already matched.
    /// `label` is the fallback's human scope label ("at Subbireddy · money in").
    public static func timingAnswer(matched: [TxnRow], label: String?,
                                    money: (Double) -> String) -> String {
        let sorted = matched.sorted { $0.txnDate < $1.txnDate }
        let tail = (label?.isEmpty == false) ? " (\(label!))" : ""
        if sorted.count == 1, let r = sorted.first {
            let amt = money(max(r.debit, r.credit))
            let dir = r.credit > 0 ? "came in" : "went out"
            return "**On \(prettyISO(r.txnDate))** — \(amt) \(dir)\(tail)."
        }
        var lines = ["**\(sorted.count) dates\(tail):**"]
        for r in sorted.suffix(10) {
            lines.append("- \(prettyISO(r.txnDate)) — \(money(max(r.debit, r.credit)))")
        }
        return lines.joined(separator: "\n")
    }

    private static func prettyISO(_ iso: String) -> String {
        let p = iso.split(separator: "-")
        guard p.count == 3, let m = Int(p[1]), (1...12).contains(m), let d = Int(p[2]) else { return iso }
        let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(d) \(months[m]) \(p[0])"
    }
}
