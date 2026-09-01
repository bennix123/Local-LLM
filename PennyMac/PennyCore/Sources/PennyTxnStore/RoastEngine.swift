// RoastEngine — the deterministic skeleton of "Roast me" (design B, 2026-08-28).
//
// The model was doing stand-up unsupervised: repetition loops, invented figures,
// occasional refusals. Now the ENGINE computes the roast-worthy facts (exact
// figures, discretionary spending only) and renders a complete template roast.
// The app may hand the same facts to the on-device model for fancier phrasing,
// but every number comes from here, and when the model loops / invents /
// refuses, the template roast ships instead. The model garnishes; it never cooks.
//
// POLICY (Rahul, 2026-08-28): tease, never shame. Roast only discretionary
// spending — dining, delivery, shopping, subscriptions, rides, entertainment.
// NEVER healthcare, rent, utilities, loans, insurance, education, taxes, or
// income. Close with one genuinely useful number (charm, then the pitch).
import Foundation

public enum RoastEngine {

    /// Categories that may be roasted. Everything else is off-limits — either
    /// essential (rent, utilities), sensitive (healthcare), or not spending at
    /// all (income, transfers, card repayments).
    static let roastable: Set<String> = [
        "Food & Dining", "Dining", "Food Delivery", "Fast Food", "Cafe",
        "Shopping", "Online Marketplace", "Clothing", "Electronics",
        "Subscriptions", "Entertainment", "Ride Hailing", "Transport",
    ]

    /// Merchant-name words that mark a row as essential even inside a roastable
    /// category (fuel and commuting ride inside Transport, for example, are
    /// life logistics — the roast targets choices, not obligations).
    static let essentialMerchantWords = ["fuel", "petrol", "gas station", "metro",
                                         "rail", "train", "bus ", "toll", "parking"]

    public struct Output: Sendable, Equatable {
        /// Exact facts, one per line — the ONLY numbers the model may use.
        public let bullets: [String]
        /// A complete, ready-to-ship roast built from templates + real figures.
        public let fallback: String
    }

    /// Build the roast facts + template roast for one currency's rows (callers
    /// pass the dominant currency's partition; mixing currencies would mix
    /// symbols). Returns nil only when there are no debit rows at all.
    public static func roast(rows: [TxnRow], money: (Double) -> String,
                             seed: UInt64 = 0) -> Output? {
        let debits = rows.filter { $0.debit > 0 }
        guard !debits.isEmpty else { return nil }

        func isRoastable(_ r: TxnRow) -> Bool {
            guard roastable.contains(r.category) else { return false }
            let name = (r.merchant.isEmpty ? r.descr : r.merchant).lowercased()
            return !essentialMerchantWords.contains { name.contains($0) }
        }
        let vices = debits.filter(isRoastable)

        var rng = SplitMix(seed: seed == 0 ? UInt64(debits.count) &* 2654435761 : seed)
        func pick(_ options: [String]) -> String { options[Int(rng.next() % UInt64(options.count))] }

        var bullets: [String] = []
        var lines: [String] = []

        guard !vices.isEmpty else {
            let text = pick([
                "I went through every line looking for something to roast and found… responsibility. Rent, bills, essentials. Honestly? Disgusting. Come back when you've bought something you regret.",
                "Nothing to roast. No impulse buys, no 79 delivery orders, no subscription graveyard. Either you're incredibly disciplined or this is your accountant's statement.",
            ])
            return Output(bullets: ["No discretionary spending found — the roast has nothing to work with."],
                          fallback: text)
        }

        // ---- top vice merchant by total --------------------------------------
        var byMerchant: [String: (total: Double, count: Int)] = [:]
        for r in vices {
            let key = r.merchant.isEmpty ? r.descr : r.merchant
            let cur = byMerchant[key] ?? (0, 0)
            byMerchant[key] = (cur.total + r.debit, cur.count + 1)
        }
        if let top = byMerchant.max(by: { $0.value.total < $1.value.total }) {
            let visitNoun = top.value.count == 1 ? "visit" : "visits"
            bullets.append("Top discretionary merchant: \(top.key) — \(money(top.value.total)) across \(top.value.count) \(visitNoun)")
            lines.append(pick([
                "Let's start with \(top.key): \(money(top.value.total)) over \(top.value.count) \(visitNoun). At this point you're not a customer, you're an investor.",
                "\(top.key) took \(money(top.value.total)) off you in \(top.value.count) \(visitNoun). They should name a chair after you.",
                "\(money(top.value.total)) at \(top.key). \(top.value.count) \(visitNoun). Somewhere, their regional manager has your photo framed.",
            ]))
        }

        // ---- frequency habit -------------------------------------------------
        if let habit = byMerchant.filter({ $0.value.count >= 8 })
            .max(by: { $0.value.count < $1.value.count }) {
            bullets.append("Most frequent: \(habit.key) — \(habit.value.count) transactions")
            lines.append(pick([
                "\(habit.value.count) separate transactions at \(habit.key). That's not a habit, that's a subscription you're paying manually.",
                "You visited \(habit.key) \(habit.value.count) times. I've seen marriages with less commitment.",
            ]))
        }

        // ---- biggest single splurge ------------------------------------------
        if let big = vices.max(by: { $0.debit < $1.debit }) {
            let name = big.merchant.isEmpty ? big.descr : big.merchant
            bullets.append("Biggest single splurge: \(money(big.debit)) at \(name) on \(PrettyDate.long(big.txnDate))")
            lines.append(pick([
                "And \(PrettyDate.long(big.txnDate)): \(money(big.debit)) at \(name), in one go. I hope it was worth it. It wasn't, but I hope.",
                "One transaction. \(money(big.debit)). \(name). I'm not angry, I'm impressed — mostly at the confidence.",
            ]))
        }

        // ---- subscription load (recurring, roastable only) -------------------
        let recurring = FinanceRouter.recurringCharges(rows).filter { charge in
            let dominant = rows.first {
                ($0.merchant.isEmpty ? $0.descr : $0.merchant) == charge.name
            }?.category ?? ""
            return roastable.contains(dominant)
        }
        if recurring.count >= 2 {
            let monthly = recurring.reduce(0.0) { $0 + $1.amount }
            bullets.append("Recurring discretionary charges: \(recurring.count) of them, about \(money(monthly))/month")
            lines.append(pick([
                "You have \(recurring.count) subscriptions quietly taking \(money(monthly)) a month. Name three of them. I'll wait.",
                "\(money(monthly)) a month across \(recurring.count) recurring charges — a small salary for services you'd struggle to list.",
            ]))
        }

        // ---- weekend blowout -------------------------------------------------
        let weekend = vices.filter { isWeekendISO($0.txnDate) }.reduce(0) { $0 + $1.debit }
        let weekday = vices.filter { !isWeekendISO($0.txnDate) }.reduce(0) { $0 + $1.debit }
        if weekday > 0, weekend > weekday * 1.5 {
            bullets.append("Weekend discretionary spend \(money(weekend)) vs weekday \(money(weekday))")
            lines.append(pick([
                "Weekends: \(money(weekend)). Weekdays: \(money(weekday)). Monday-you keeps writing cheques Saturday-you already cashed.",
                "Your weekend spending (\(money(weekend))) treats your weekday spending (\(money(weekday))) like a rounding error.",
            ]))
        }

        // ---- the Saul close: one genuinely useful number ---------------------
        let months = max(1, Set(vices.map(\.month)).count)
        let viceTotal = vices.reduce(0) { $0 + $1.debit }
        let monthlyVice = viceTotal / Double(months)
        bullets.append("Total discretionary: \(money(viceTotal)) over \(months) month(s) — about \(money(monthlyVice))/month; 15% less would keep \(money(monthlyVice * 0.15))/month")
        lines.append(pick([
            "Here's the free advice, and it IS free: that's \(money(monthlyVice)) a month on the fun stuff. Trim 15% — you won't feel it — and you keep \(money(monthlyVice * 0.15)) a month. Call it a retainer. For me.",
            "The bill: \(money(monthlyVice))/month on wants. Shave 15% and \(money(monthlyVice * 0.15)) a month stays yours. You didn't need a finance app for that — but here we are.",
        ]))

        return Output(bullets: bullets, fallback: lines.joined(separator: "\n\n"))
    }

    /// Model-output safety check (design B): the garnished roast may only use
    /// figures that appear in the bullets, must not loop, and must not be a
    /// refusal. Fails → the caller ships the template fallback.
    public static func garnishAcceptable(_ text: String, bullets: [String]) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 40 else { return false }
        let lower = t.lowercased()
        if lower.contains("i cannot") || lower.contains("i can't roast")
            || lower.contains("i'm sorry") || lower.contains("as an ai") { return false }
        // Repetition: any 5-word window occurring 3+ times is a degeneration loop.
        let words = lower.split(separator: " ").map(String.init)
        if words.count >= 15 {
            var seen: [String: Int] = [:]
            for i in 0...(words.count - 5) {
                let window = words[i..<(i + 5)].joined(separator: " ")
                seen[window, default: 0] += 1
                if seen[window]! >= 3 { return false }
            }
        }
        // Figure honesty: every number with 2 decimals in the garnish must appear
        // in some bullet (the model may not invent amounts).
        let allowed = bullets.joined(separator: " ")
        let numberPattern = #"\d[\d,]*\.\d{2}"#
        var search = t[t.startIndex...]
        while let r = search.range(of: numberPattern, options: .regularExpression) {
            if !allowed.contains(t[r]) { return false }
            search = t[r.upperBound...]
        }
        return true
    }

    private static func isWeekendISO(_ iso: String) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let p = iso.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3,
              let d = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) else { return false }
        return cal.isDateInWeekend(d)
    }

    /// Tiny deterministic RNG so template choice is reproducible in tests
    /// (seed) but varies naturally across datasets.
    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}
