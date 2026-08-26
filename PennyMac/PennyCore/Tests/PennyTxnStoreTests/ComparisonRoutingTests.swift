import XCTest
@testable import PennyTxnStore

/// The comparison + ordering fixes from the 34-question manual audit
/// (2026-08-26): questions that used to be swallowed by an earlier, broader
/// pattern ("top 5 categories" → top-5 expenses, "when do I get paid" → total
/// SPENT, "trending up or down" → net) and comparison shapes that previously
/// collapsed into a single total.
final class ComparisonRoutingTests: XCTestCase {

    private func row(_ seq: Int, date: String, descr: String, merchant: String = "",
                     category: String = "Shopping", debit: Double = 0, credit: Double = 0) -> TxnRow {
        let parts = date.split(separator: "-")
        return TxnRow(txnDate: date, month: "\(parts[0])-\(parts[1])", year: Int(parts[0]) ?? 2026,
                      monthNo: Int(parts[1]) ?? 1, day: Int(parts[2]) ?? 1,
                      descr: descr, merchant: merchant.isEmpty ? descr : merchant, category: category,
                      debit: debit, credit: credit, balance: nil, currency: "GBP", seq: seq)
    }

    // Three months (Apr–Jun 2026). June 1 2026 is a Monday, so 2026-06-06 and
    // 2026-06-13 are Saturdays. Spending rises month over month (100 → 200 → 400).
    private var rows: [TxnRow] {
        [row(1, date: "2026-04-01", descr: "SALARY ACME", category: "Income", credit: 3000),
         row(2, date: "2026-04-10", descr: "TESCO", category: "Groceries", debit: 100),
         row(3, date: "2026-05-01", descr: "SALARY ACME", category: "Income", credit: 3000),
         row(4, date: "2026-05-10", descr: "TESCO", category: "Groceries", debit: 120),
         row(5, date: "2026-05-20", descr: "ZARA", debit: 80),
         row(6, date: "2026-06-02", descr: "SALARY ACME", category: "Income", credit: 3000),
         row(7, date: "2026-06-06", descr: "PUB CRAWL", category: "Dining", debit: 150),   // Saturday
         row(8, date: "2026-06-10", descr: "NETFLIX", category: "Subscriptions", debit: 9.99),
         row(9, date: "2026-06-11", descr: "NETFLIX", category: "Subscriptions", debit: 9.99),
         row(10, date: "2026-06-13", descr: "PUB CRAWL", category: "Dining", debit: 160),  // Saturday
         row(11, date: "2026-06-25", descr: "TESCO", category: "Groceries", debit: 70)]
    }

    private let money: (Double) -> String = { "£" + String(format: "%.2f", $0) }

    private func ask(_ q: String, _ r: [TxnRow]? = nil) -> String? {
        FinanceRouter.answer(q, rows: r ?? rows, currency: "GBP", money: money)
    }

    // MARK: - ordering fixes

    func testTopFiveCategoriesIsABreakdownNotExpenses() throws {
        let ans = try XCTUnwrap(ask("What are my top 5 spending categories?"))
        XCTAssertTrue(ans.contains("Spending by category"), "\(ans)")
        XCTAssertTrue(ans.contains("Groceries") && ans.contains("Dining"), "\(ans)")
        XCTAssertFalse(ans.contains("expenses"), "must not be a top-N expense list: \(ans)")
    }

    func testWhenDoIGetPaidIsAboutCreditsNotSpending() throws {
        let ans = try XCTUnwrap(ask("When do I usually get paid — is it consistent?"))
        XCTAssertTrue(ans.contains("paid around"), "\(ans)")
        XCTAssertTrue(ans.contains("day"), "\(ans)")
        XCTAssertFalse(ans.contains("You spent"), "'paid' must not hit the spend catch-all: \(ans)")
    }

    func testTrendingUpOrDownIsATrendNotNet() throws {
        let ans = try XCTUnwrap(ask("Is my spending trending up or down over the last 6 months?"))
        XCTAssertTrue(ans.contains("trending up"), "100→200→400 should trend up: \(ans)")
        XCTAssertFalse(ans.contains("Net"), "must not be the net handler: \(ans)")
    }

    func testUnknownMerchantPerMonthIsNotAFullBreakdown() {
        let ans = ask("How much do I spend on Swiggy per month?")
        if let ans {
            XCTAssertFalse(ans.contains("Month by month"),
                           "unknown merchant must not dump the whole breakdown: \(ans)")
        }
    }

    func testWheresMyMoneyGoingIsCategoriesNotMonths() throws {
        let ans = try XCTUnwrap(ask("Where's most of my money going each month?"))
        XCTAssertTrue(ans.contains("Spending by category"), "\(ans)")
    }

    func testSavingEachMonthShowsKeptAmount() throws {
        let ans = try XCTUnwrap(ask("How much am I actually saving each month?"))
        XCTAssertTrue(ans.contains("kept"), "savings phrasing should show the kept amount: \(ans)")
    }

    // MARK: - new comparison handlers

    func testThisMonthVsLastMonth() throws {
        let ans = try XCTUnwrap(ask("How much did I spend this month vs last month?"))
        XCTAssertTrue(ans.contains("Jun 2026") && ans.contains("May 2026"), "\(ans)")
        // June: 150 + 9.99 + 9.99 + 160 + 70 = 399.98 · May: 120 + 80 = 200.
        XCTAssertTrue(ans.contains("£399.98") && ans.contains("£200.00"), "\(ans)")
    }

    func testThisMonthVsSameMonthLastYearWithoutDataIsHonest() throws {
        let ans = try XCTUnwrap(ask("This month vs same month last year"))
        XCTAssertTrue(ans.contains("No data for Jun 2025"), "\(ans)")
    }

    func testFirstVsSecondHalfOfMonth() throws {
        let ans = try XCTUnwrap(ask("Do I spend more in the first half or second half of the month?"))
        // days 1–15: 100+120+150+9.99+9.99+160 = 549.98 · days 16+: 80+70 = 150
        XCTAssertTrue(ans.contains("first half"), "\(ans)")
        XCTAssertTrue(ans.contains("£549.98") && ans.contains("£150.00"), "\(ans)")
    }

    func testDayOfTheWeekAggregates() throws {
        let ans = try XCTUnwrap(ask("Which day of the week do I spend the most?"))
        XCTAssertTrue(ans.contains("Saturdays"), "150+160 on Saturdays beats every other day: \(ans)")
        XCTAssertTrue(ans.contains("£310.00"), "must aggregate ACROSS Saturdays: \(ans)")
    }

    func testIncomeVsExpensesRatio() throws {
        let ans = try XCTUnwrap(ask("What's my income vs expenses ratio?"))
        XCTAssertTrue(ans.contains("ratio"), "\(ans)")
        XCTAssertTrue(ans.contains("£9,000.00") || ans.contains("£9000.00"), "income side: \(ans)")
    }

    // MARK: - duplicates, donations, fixed outflow

    func testDuplicateChargesFound() throws {
        let ans = try XCTUnwrap(ask("Are there any duplicate or suspicious charges?"))
        XCTAssertTrue(ans.contains("NETFLIX"), "9.99 twice a day apart: \(ans)")
        XCTAssertTrue(ans.contains("possible duplicate"), "\(ans)")
    }

    func testNoDuplicatesIsHonest() throws {
        let clean = rows.filter { $0.seq != 9 }   // drop the second NETFLIX
        let ans = try XCTUnwrap(ask("Am I paying for anything twice?", clean))
        XCTAssertTrue(ans.contains("No duplicate-looking charges"), "\(ans)")
    }

    func testDonationsHonestZeroWhenAbsent() throws {
        let ans = try XCTUnwrap(ask("Total charitable donations for tax deduction?"))
        XCTAssertTrue(ans.contains("£0.00"), "\(ans)")
        XCTAssertFalse(ans.contains("You spent £549"), "must not be the whole spend: \(ans)")
    }

    func testDonationsSummedWhenPresent() throws {
        var r = rows
        r.append(row(20, date: "2026-06-20", descr: "UNICEF DONATION", category: "Charity", debit: 50))
        let ans = try XCTUnwrap(ask("total charitable donations?", r))
        XCTAssertTrue(ans.contains("£50.00") && ans.contains("UNICEF"), "\(ans)")
    }

    func testFixedMonthlyOutflowUsesRecurringDetection() throws {
        let ans = try XCTUnwrap(ask("What's my total fixed monthly outflow?"))
        XCTAssertTrue(ans.contains("Recurring") || ans.contains("No recurring"),
                      "fixed = recurring machinery, not total spend: \(ans)")
        XCTAssertFalse(ans.contains("You spent"), "\(ans)")
    }

    // MARK: - unhandled comparisons defer to the model

    func testUnhandledComparisonDefersToLLM() {
        XCTAssertNil(ask("Festival months vs regular months — how much extra do I blow?"))
        XCTAssertNil(ask("Pre-salary week vs post-salary week spending patterns"))
    }

    // MARK: - year / quarter scope (from the Downloads eval kit, 2026-08-26)

    func testBareYearScopes() throws {
        let ans = try XCTUnwrap(ask("How much did I spend in 2019?"))
        XCTAssertTrue(ans.contains("£0.00 in 2019"), "absent year must be an honest zero: \(ans)")
    }

    func testYearToDateScopesToLatestYear() throws {
        let ans = try XCTUnwrap(ask("What's my year-to-date spending for 2026?"))
        XCTAssertTrue(ans.contains("in 2026"), "\(ans)")
        XCTAssertFalse(ans.contains("2,025.00"), "2026 must not be read as an amount: \(ans)")
    }

    func testQuarterScopes() throws {
        let ans = try XCTUnwrap(ask("How much did I spend in Q2 2026?"))
        // Apr+May+Jun debits: 100 + 200 + 399.98 = 699.98
        XCTAssertTrue(ans.contains("in Q2 2026") && ans.contains("£699.98"), "\(ans)")
    }

    func testMonthComparisonIsYearAware() throws {
        var r = rows
        r.append(row(30, date: "2025-06-15", descr: "OLD ZARA", debit: 5000))
        let ans = try XCTUnwrap(ask("Did I spend more in June 2026 than May 2026?", r))
        XCTAssertTrue(ans.contains("Jun 2026") && ans.contains("£399.98"),
                      "June 2025's £5000 must not leak into June 2026: \(ans)")
        let yoy = try XCTUnwrap(ask("Compare June 2026 vs June 2025", r))
        XCTAssertTrue(yoy.contains("Jun 2025") && yoy.contains("£5000.00"), "\(yoy)")
    }

    // MARK: - balance extremes, POS-gate targets, benchmark decline

    func testLowestBalanceWithDate() throws {
        var r = rows
        for i in r.indices { r[i].balance = 1000 + Double(i) }
        r[3].balance = 42.42
        let ans = try XCTUnwrap(ask("What's the lowest my balance dropped, and when?", r))
        XCTAssertTrue(ans.contains("£42.42") && ans.contains("10 May 2026"), "\(ans)")
    }

    func testBrandNamesSurviveThePOSTagger() throws {
        // NLTagger reads "starbucks" as an adverb and "walmart" as a verb —
        // both used to fall out of the target extractor and answer the TOTAL.
        for q in ["How much have I spent at Starbucks?", "How much did I spend at Walmart?"] {
            let ans = try XCTUnwrap(ask(q))
            XCTAssertTrue(ans.contains("£0.00"), "\(q) → \(ans)")
            XCTAssertFalse(ans.contains("£549.98") || ans.contains("£699.98"),
                           "must not be the whole-account total: \(ans)")
        }
    }

    func testPeerBenchmarkDeclinesHonestly() throws {
        let ans = try XCTUnwrap(ask("Is my spending normal for someone my age?"))
        XCTAssertTrue(ans.contains("can't compare you with other people"), "\(ans)")
        XCTAssertFalse(ans.contains("£"), "no figures — nothing to benchmark against: \(ans)")
    }

    func testHowMuchAndHowManyAnswersBoth() throws {
        let ans = try XCTUnwrap(ask("How much have I sent to TESCO, and how many times?"))
        XCTAssertTrue(ans.contains("3 transactions") && ans.contains("totalling £290.00"), "\(ans)")
    }

    // MARK: - must-not-change

    func testPlainTopFiveExpensesUnchanged() throws {
        let ans = try XCTUnwrap(ask("top 5 expenses"))
        XCTAssertTrue(ans.contains("top 5 expenses"), "\(ans)")
    }

    func testBiggestSpendingDayStillACalendarDate() throws {
        let ans = try XCTUnwrap(ask("What was my biggest spending day?"))
        XCTAssertTrue(ans.contains("13 Jun 2026"), "single date, not a weekday: \(ans)")
    }

    func testPaidOffCardStillNotPayday() {
        let ans = ask("Have I paid off my card?")
        if let ans { XCTAssertFalse(ans.contains("paid around"), "\(ans)") }
    }

    func testMonthlyBreakdownUnchanged() throws {
        let ans = try XCTUnwrap(ask("Give me a monthly breakdown"))
        XCTAssertTrue(ans.contains("Month by month"), "\(ans)")
        XCTAssertFalse(ans.contains("kept"), "no savings wording without a savings cue: \(ans)")
    }
}
