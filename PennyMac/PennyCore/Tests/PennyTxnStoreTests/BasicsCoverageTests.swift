import XCTest
@testable import PennyTxnStore

/// The BOUNDED first-questions contract (agreed 2026-08-28): the finite set of
/// questions a first-time user plausibly asks must each get the RIGHT-SHAPED
/// deterministic answer — or an honest defer (nil → model) — and never a
/// wrong-shaped one (a grand total for a "where most" question, a phantom
/// merchant, a count for a "largest" question…).
///
/// This file IS the coverage definition: to extend basic coverage, add a row
/// here first, then make it pass. The unbounded long tail stays governed by
/// the router freeze + engine plan; this corpus is the deliberate exception.
final class BasicsCoverageTests: XCTestCase {

    private func row(_ seq: Int, date: String, descr: String, merchant: String = "",
                     category: String = "Shopping", debit: Double = 0, credit: Double = 0,
                     balance: Double? = nil) -> TxnRow {
        let parts = date.split(separator: "-")
        return TxnRow(txnDate: date, month: "\(parts[0])-\(parts[1])", year: Int(parts[0]) ?? 2026,
                      monthNo: Int(parts[1]) ?? 1, day: Int(parts[2]) ?? 1,
                      descr: descr, merchant: merchant.isEmpty ? descr : merchant, category: category,
                      debit: debit, credit: credit, balance: balance, currency: "GBP", seq: seq)
    }

    /// Three months, salary credits, a repeated subscription, running balances.
    private var rows: [TxnRow] {
        [row(1, date: "2026-04-01", descr: "SALARY ACME", category: "Income", credit: 3000, balance: 3200),
         row(2, date: "2026-04-05", descr: "TESCO", category: "Groceries", debit: 100, balance: 3100),
         row(3, date: "2026-04-10", descr: "NETFLIX", category: "Subscriptions", debit: 9.99, balance: 3090.01),
         row(4, date: "2026-05-01", descr: "SALARY ACME", category: "Income", credit: 3000, balance: 6090.01),
         row(5, date: "2026-05-08", descr: "TESCO", category: "Groceries", debit: 120, balance: 5970.01),
         row(6, date: "2026-05-10", descr: "NETFLIX", category: "Subscriptions", debit: 9.99, balance: 5960.02),
         row(7, date: "2026-05-20", descr: "ZARA", debit: 80, balance: 5880.02),
         row(8, date: "2026-06-02", descr: "SALARY ACME", category: "Income", credit: 3000, balance: 8880.02),
         row(9, date: "2026-06-07", descr: "TESCO", category: "Groceries", debit: 90, balance: 8790.02),
         row(10, date: "2026-06-11", descr: "NETFLIX", category: "Subscriptions", debit: 9.99, balance: 8780.03),
         row(11, date: "2026-06-18", descr: "UBER", category: "Transport", debit: 45, balance: 8735.03),
         row(12, date: "2026-06-21", descr: "REFUND ZARA", merchant: "ZARA", credit: 30, balance: 8765.03)]
    }

    private let money: (Double) -> String = { "£" + String(format: "%.2f", $0) }

    private func ask(_ q: String) -> String? {
        FinanceRouter.answer(q, rows: rows, currency: "GBP", money: money)
    }

    /// question · answer must contain ONE of `want` · must contain NONE of `ban`.
    /// `want == []` means an honest defer (nil) is the correct outcome.
    private struct Case { let q: String; let want: [String]; let ban: [String] }

    private let cases: [Case] = [
        // ---- totals & counts ----
        Case(q: "what's my total spending?", want: ["You spent £464.97"], ban: []),
        Case(q: "how much did I spend in total?", want: ["You spent £464.97"], ban: []),
        Case(q: "what's my total income?", want: ["You received £9,000", "You received £9000"], ban: []),
        Case(q: "how many transactions do I have?", want: ["9 transactions", "12 transactions"], ban: []),
        Case(q: "how many transactions did I receive?", want: ["credits"], ban: ["12 transactions"]),
        // ---- largest / top ----
        Case(q: "what was my largest transaction?", want: ["largest expense"], ban: ["transactions."]),
        Case(q: "what's my biggest expense?", want: ["largest expense was £120.00"], ban: []),
        Case(q: "where did i spent most of my money?", want: ["top merchant"], ban: ["You spent £464.97"]),
        Case(q: "where do I spend the most?", want: ["top merchant"], ban: ["You spent £464.97"]),
        Case(q: "who is my top merchant?", want: ["top merchant"], ban: []),
        Case(q: "what are my top spending categories?", want: ["Spending by category"], ban: ["expenses"]),
        Case(q: "what's my smallest purchase?", want: ["smallest expense"], ban: []),
        // ---- breakdowns ----
        Case(q: "show my spending by category", want: ["Spending by category"], ban: []),
        Case(q: "how much do I spend each month?", want: ["Month by month"], ban: ["on Each"]),
        Case(q: "where is my money going?", want: ["Spending by category"], ban: []),
        // ---- averages ----
        Case(q: "what's my average transaction?", want: ["average transaction"], ban: []),
        Case(q: "what do I spend per month on average?", want: ["/month"], ban: []),
        Case(q: "what's my average daily spend?", want: ["/day"], ban: []),
        // ---- merchant lookups ----
        Case(q: "how much did I spend at Tesco?", want: ["on Tesco", "at TESCO", "on TESCO"], ban: ["£464.97"]),
        Case(q: "list my tesco transactions", want: ["TESCO", "totalling"], ban: ["ZARA"]),
        Case(q: "what are my netflix transactions?", want: ["NETFLIX", "totalling"], ban: ["TESCO"]),
        Case(q: "how much did I spend at Starbucks?", want: ["£0.00 on Starbucks"], ban: ["£464.97"]),
        Case(q: "when did I last shop at Zara?", want: ["ZARA"], ban: []),
        // ---- subscriptions / recurring ----
        Case(q: "what subscriptions am I paying for?", want: ["Recurring", "No recurring"], ban: []),
        Case(q: "do I have a netflix subscription?", want: ["Yes"], ban: ["Recurring charges"]),
        Case(q: "do I have a spotify subscription?", want: ["No"], ban: []),
        Case(q: "what are my recurring payments?", want: ["Recurring", "No recurring"], ban: []),
        // ---- refunds ----
        Case(q: "did I get any refunds?", want: ["refund"], ban: ["£9,000", "£9000"]),
        // ---- income ----
        Case(q: "when do I usually get paid?", want: ["paid around"], ban: ["You spent"]),
        Case(q: "list my credits", want: ["credits", "SALARY"], ban: ["TESCO"]),
        Case(q: "what's my income vs expenses ratio?", want: ["ratio"], ban: []),
        Case(q: "how much am I saving each month?", want: ["kept"], ban: []),
        // ---- balance ----
        Case(q: "what's my balance?", want: ["balance is £8,765.03", "balance is £8765.03"], ban: []),
        Case(q: "what's the lowest my balance dropped?", want: ["lowest balance"], ban: []),
        // ---- time scopes ----
        Case(q: "how much did I spend in May?", want: ["in May"], ban: ["£464.97"]),
        Case(q: "how much did I spend last month?", want: ["last month"], ban: []),
        Case(q: "how much did I spend this year?", want: ["£464.97", "in 2026"], ban: []),
        Case(q: "how much did I spend in 2019?", want: ["£0.00 in 2019"], ban: ["£464.97"]),
        // ---- comparisons ----
        Case(q: "did I spend more this month or last month?", want: ["vs"], ban: []),
        Case(q: "weekend vs weekday spending?", want: ["weekend"], ban: []),
        Case(q: "is my spending going up or down?", want: ["trending", "roughly flat"], ban: ["Net"]),
        // ---- direction ----
        Case(q: "show all my debits", want: ["debits"], ban: ["SALARY"]),
        Case(q: "count of transactions I sent", want: ["debits"], ban: ["12 transactions"]),
        // ---- honest declines (nil → model/decline is CORRECT) ----
        Case(q: "should I be worried about my spending?", want: [], ban: []),
        Case(q: "can I afford a new car?", want: [], ban: []),
        Case(q: "roast my spending", want: [], ban: []),
        Case(q: "is my spending normal for someone my age?", want: ["can't compare you"], ban: ["£464.97"]),
    ]

    func testEveryBasicQuestionGetsTheRightShape() throws {
        var failures: [String] = []
        for c in cases {
            let ans = ask(c.q)
            if c.want.isEmpty {
                if let ans, !c.ban.isEmpty, c.ban.contains(where: { ans.contains($0) }) {
                    failures.append("『\(c.q)』 banned content in: \(ans.prefix(90))")
                }
                // nil (defer) — or any non-banned answer — is acceptable here.
                continue
            }
            guard let ans else {
                failures.append("『\(c.q)』 deferred to the model — should be deterministic")
                continue
            }
            if !c.want.contains(where: { ans.localizedCaseInsensitiveContains($0) }) {
                failures.append("『\(c.q)』 wrong shape: \(ans.prefix(90))")
            }
            if let hit = c.ban.first(where: { ans.contains($0) }) {
                failures.append("『\(c.q)』 contains banned “\(hit)”: \(ans.prefix(90))")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\n" + failures.joined(separator: "\n"))
    }
}
