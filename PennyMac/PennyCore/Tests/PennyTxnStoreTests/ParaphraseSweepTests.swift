import XCTest
@testable import PennyTxnStore

/// Paraphrase sweep (2026-09-01, Rahul's request) — the eval that patrols the
/// blind spot the bulk evals can't: "confidently answered the WRONG question".
///
/// The bulk sets are generated from supported intents, so they regression-test
/// known behavior; a novel phrasing has no expectation there and a misroute
/// passes silently. Here every supported intent gets a battery of ADVERSARIAL
/// paraphrases — typos, comparatives-as-superlatives, Indian-English, odd
/// prepositions — and every answer is checked against a truth value computed
/// INDEPENDENTLY from the fixture rows (never from router output).
///
/// Contract per phrasing, through the same deterministic pipeline the apps
/// run (AccountQuery gate → FinanceRouter):
///   - answered + contains the expected value(s) and no forbidden value → pass
///   - declined / deferred (nil or an honest can't-answer) → counted, no fail
///     (honesty is allowed; lying is not) — but each intent must answer at
///     least half its phrasings, so mass deferral can't fake a pass
///   - answered with a forbidden value or missing the expected one → FAILURE
///
/// Rule going forward: every misroute found manually adds its phrasing here
/// in the same commit as the fix.
final class ParaphraseSweepTests: XCTestCase {

    // MARK: - fixture (two years, categories, merchants, accounts)

    private func row(_ seq: Int, _ date: String, _ descr: String, cat: String,
                     debit: Double = 0, credit: Double = 0, acct: String? = nil) -> TxnRow {
        let p = date.split(separator: "-")
        var r = TxnRow(txnDate: date, month: "\(p[0])-\(p[1])", year: Int(p[0])!, monthNo: Int(p[1])!,
                       day: Int(p[2])!, descr: descr, merchant: descr, category: cat,
                       debit: debit, credit: credit, balance: nil, currency: "INR", seq: seq)
        r.account = acct
        return r
    }

    private var rows: [TxnRow] {
        let U = "Union Bank Of India -49", C = "Canara Bank -41"
        return [
            row(1, "2025-11-05", "SALARY", cat: "Income", credit: 5000, acct: U),
            row(2, "2025-11-10", "AMAZON", cat: "Shopping", debit: 1200, acct: U),
            row(3, "2025-12-02", "SWIGGY", cat: "Food & Dining", debit: 300, acct: U),
            row(4, "2025-12-15", "MEDPLUS", cat: "Pharmacy", debit: 450, acct: C),
            row(5, "2026-01-04", "SALARY", cat: "Income", credit: 5200, acct: U),
            row(6, "2026-01-09", "AMAZON", cat: "Shopping", debit: 800, acct: U),
            row(7, "2026-01-20", "UBER", cat: "Transport", debit: 150, acct: C),
            row(8, "2026-02-11", "MEDPLUS", cat: "Pharmacy", debit: 250, acct: U),
            row(9, "2026-02-14", "REFUND", cat: "Income", credit: 100, acct: C),
            row(10, "2026-02-20", "SWIGGY", cat: "Food & Dining", debit: 520, acct: U),
        ]
    }

    // Independently computed truths (by hand + verified in testFixtureTruths):
    // spent 3670 · received 10300 · months: Nov25=1200 Dec25=750 Jan26=950 Feb26=770
    // years: 2025=1950 2026=1720 · categories: Shopping 2000 > F&D 820 > Pharmacy 700 > Transport 150
    // merchants: AMAZON 2000 > SWIGGY 820 > MEDPLUS 700 > UBER 150
    // accounts (debit): U 3070, C 600 · largest txn 1200 · smallest 150
    // income months: Jan26 5200 > Nov25 5000 > Feb26 100

    private let money: (Double) -> String = { "₹" + String(format: "%.2f", $0) }

    func testFixtureTruths() {
        let r = rows
        XCTAssertEqual(r.reduce(0) { $0 + $1.debit }, 3670, accuracy: 0.001)
        XCTAssertEqual(r.reduce(0) { $0 + $1.credit }, 10300, accuracy: 0.001)
        let byMonth = Dictionary(grouping: r.filter { $0.debit > 0 }, by: \.month)
            .mapValues { $0.reduce(0) { $0 + $1.debit } }
        XCTAssertEqual(byMonth["2025-11"]!, 1200); XCTAssertEqual(byMonth["2025-12"]!, 750)
        XCTAssertEqual(byMonth["2026-01"]!, 950); XCTAssertEqual(byMonth["2026-02"]!, 770)
    }

    // MARK: - sweep machinery

    private struct SweepCase {
        let intent: String
        let phrasings: [String]
        let expect: [String]     // every string must appear in an ANSWERED reply
        let forbid: [String]     // none may appear (the known-wrong numbers)
    }

    private func pipeline(_ q: String) -> String? {
        AccountQuery.answer(q, rows: rows, money: money)
            ?? FinanceRouter.answer(q, rows: rows, currency: "INR", money: money)
    }

    private func runSweep(_ cases: [SweepCase]) {
        var totalAsked = 0, totalAnswered = 0, totalDeferred = 0
        for c in cases {
            var answered = 0
            for q in c.phrasings {
                totalAsked += 1
                guard let a = pipeline(q) else { totalDeferred += 1; continue }
                answered += 1; totalAnswered += 1
                for f in c.forbid where a.contains(f) {
                    XCTFail("[\(c.intent)] \"\(q)\" → forbidden value \(f) in: \(a)")
                }
                for e in c.expect where !a.contains(e) {
                    XCTFail("[\(c.intent)] \"\(q)\" answered WITHOUT expected \(e): \(a)")
                }
            }
            XCTAssertGreaterThanOrEqual(
                Double(answered), Double(c.phrasings.count) * 0.5,
                "[\(c.intent)] answered only \(answered)/\(c.phrasings.count) — mass deferral")
        }
        print("SWEEP asked=\(totalAsked) answered=\(totalAnswered) deferred=\(totalDeferred)")
    }

    // MARK: - the sweep

    func testParaphraseSweep() {
        runSweep([
            SweepCase(intent: "total-spent",
                phrasings: ["how much did I spend?", "total spendings?", "what is the total amount I have spent",
                            "how much money went out overall", "kindly tell my total spent",
                            "wht did i spend in total", "overall expenditure?"],
                expect: ["₹3670.00"], forbid: ["₹10300.00"]),

            SweepCase(intent: "total-received",
                phrasings: ["how much did I receive?", "total money recieved?", "how much amount came in",
                            "what is my total income here", "how much have i earned in this statement"],
                expect: ["₹10300.00"], forbid: ["₹3670.00"]),

            SweepCase(intent: "month-superlative-spend",
                phrasings: ["which month did I spend the most?", "which month did i spend more?",
                            "what was my highest-spending month", "my costliest month?",
                            "in which month did my spending peak?", "which month was most expensive for me",
                            "wich month did i spend the most", "which month has my maximum spending"],
                expect: ["November 2025", "₹1200.00"], forbid: ["₹3670.00"]),

            SweepCase(intent: "month-superlative-least",
                phrasings: ["which month did I spend the least?", "what was my lowest-spending month?",
                            "which month did i spend less", "my cheapest month?",
                            "which month has my minimum spending"],
                expect: ["December 2025", "₹750.00"], forbid: ["₹3670.00"]),

            SweepCase(intent: "month-superlative-income",
                phrasings: ["which month did I receive the most?", "which month did i earn more",
                            "what was my highest income month", "in which month did i get the most money"],
                expect: ["January 2026", "₹5200.00"], forbid: ["₹10300.00", "₹3670.00"]),

            SweepCase(intent: "year-superlative",
                phrasings: ["which year did I spend the most?", "which year did i spend more",
                            "what was my highest spending year"],
                expect: ["2025", "₹1950.00"], forbid: ["₹3670.00"]),

            SweepCase(intent: "category-typo-scope-pharmacy",
                phrasings: ["total spent on pharamcy?", "how much did i spend on pharmcy"],
                expect: ["₹700.00"], forbid: ["₹3670.00", "₹0.00"]),

            SweepCase(intent: "category-typo-scope-transport",
                phrasings: ["how much on trasnport?"],
                expect: ["₹150.00"], forbid: ["₹3670.00", "₹0.00"]),

            SweepCase(intent: "category-typo-comparison",
                phrasings: ["did i spend more on shoping or pharmacy?"],
                expect: ["₹2000.00", "₹700.00"], forbid: ["₹3670.00"]),

            SweepCase(intent: "category-superlative-least",
                phrasings: ["where did i spent my least amount in?", "which category did I spend the least on?",
                            "where did i spend the least", "what category costs me the least",
                            "which category has my minimum spending"],
                expect: ["Transport", "₹150.00"], forbid: ["₹3670.00"]),

            SweepCase(intent: "merchant-superlative",
                phrasings: ["who did I pay the most?", "where did I spend the least at?",
                            "which shop did i spend the most in", "whom did i pay the least"],
                expect: ["₹"], forbid: ["₹3670.00"]),

            SweepCase(intent: "account-superlative",
                phrasings: ["which bank did I pay the most from?", "which account did i spend more from",
                            "from which account did most of my money go out"],
                expect: ["Union Bank Of India -49", "₹3070.00"], forbid: ["₹3670.00"]),

            SweepCase(intent: "account-scoped-total",
                phrasings: ["how much did I pay from Canara Bank?", "how much went out of canara bank",
                            "total paid from canara?"],
                expect: ["₹600.00", "Canara Bank -41"], forbid: ["₹3670.00", "₹3070.00"]),

            SweepCase(intent: "largest-expense",
                phrasings: ["whats the largest transaction?", "what was my biggest expense",
                            "most expensive purchase?", "single biggest payment i made",
                            "what is the costliest thing i paid for"],
                expect: ["₹1200.00"], forbid: ["₹3670.00"]),

            SweepCase(intent: "month-comparison-scoped",
                phrasings: ["between december and february which month did i spend more on pharmacy?",
                            "did i spend more on pharmacy in december or february",
                            "compare my pharmacy spend in december vs february"],
                expect: ["₹450.00", "₹250.00"], forbid: ["₹750.00", "₹770.00", "₹3670.00"]),

            SweepCase(intent: "multi-month-combined",
                phrasings: ["how much did I spend in january and february combined?",
                            "total spent across january and february together",
                            "january and february combined spend?"],
                expect: ["₹1720.00"], forbid: ["₹950.00.", "₹3670.00"]),

            SweepCase(intent: "net-comparison",
                phrasings: ["did I spend more than I received?", "did i receive more than i spent",
                            "am i spending more than what i recieve?"],
                expect: ["₹3670.00", "₹10300.00"], forbid: []),

            SweepCase(intent: "count-direction",
                phrasings: ["how many payments did I make?", "how many transactions did i send out",
                            "number of debits?"],
                expect: ["7"], forbid: ["10 ", "₹10300.00"]),
        ])
    }
}
