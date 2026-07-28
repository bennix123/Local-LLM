// FinanceRouterCrossTests — cross-cutting "date-wise" question types added for the
// real Amex statement: date RANGES ("between X and Y", first/last week), first/last
// (earliest/latest) transaction, and biggest-£-day vs busiest-by-count day.
import XCTest
@testable import PennyTxnStore

final class FinanceRouterCrossTests: XCTestCase {

    private static let gbp: (Double) -> String = { String(format: "£%.2f", $0) }

    private static func row(_ date: String, _ descr: String, debit: Double, seq: Int) -> TxnRow {
        let p = date.split(separator: "-").compactMap { Int($0) }
        return TxnRow(txnDate: date, month: String(date.prefix(7)), year: p[0], monthNo: p[1],
                      day: p[2], descr: descr, merchant: "", category: "", debit: debit,
                      credit: 0, balance: nil, currency: "GBP", seq: seq)
    }

    // June 2026: day 02 = 2 txns/£25, day 08 = 1 txn/£100 (biggest £),
    // day 15 = 3 txns/£40 (busiest by count). Span 1–20 June.
    private static let rows: [TxnRow] = [
        row("2026-06-01", "ALPHA", debit: 10, seq: 1),
        row("2026-06-02", "BRAVO", debit: 20, seq: 2),
        row("2026-06-02", "CHARLIE", debit: 5, seq: 3),
        row("2026-06-08", "DELTA", debit: 100, seq: 4),
        row("2026-06-15", "ECHO", debit: 30, seq: 5),
        row("2026-06-15", "FOXTROT", debit: 5, seq: 6),
        row("2026-06-15", "GOLF", debit: 5, seq: 7),
        row("2026-06-20", "HOTEL", debit: 15, seq: 8),
    ]

    private func ask(_ q: String) -> String? {
        FinanceRouter.answer(q, rows: Self.rows, currency: "GBP", money: Self.gbp)
    }

    func testDateRangeBetween() {
        // 1–8 June = 10 + 20 + 5 + 100 = £135 across 4.
        let a = ask("how much did i spend between 1 and 8 june")
        XCTAssertEqual(a?.contains("£135.00"), true, "range answer: \(a ?? "nil")")
    }

    func testDateRangeFromTo() {
        // 15–20 June = 30 + 5 + 5 + 15 = £55.
        XCTAssertEqual(ask("what did i spend from 15 june to 20 june")?.contains("£55.00"), true)
    }

    func testFirstAndLastWeek() {
        // first week (1–7 June) = 10 + 20 + 5 = £35; last week (14–20) = 30+5+5+15 = £55.
        XCTAssertEqual(ask("how much in the first week")?.contains("£35.00"), true)
        XCTAssertEqual(ask("how much did i spend in the last week")?.contains("£55.00"), true)
    }

    func testFirstAndLastTransaction() {
        let first = ask("what was my first transaction")
        XCTAssertEqual(first?.contains("£10.00"), true, "first: \(first ?? "nil")")
        XCTAssertEqual(first?.contains("ALPHA"), true)
        let last = ask("what was my last transaction")
        XCTAssertEqual(last?.contains("£15.00"), true, "last: \(last ?? "nil")")
        XCTAssertEqual(last?.contains("HOTEL"), true)
        // "when was my first purchase" → date-focused phrasing still resolves.
        XCTAssertEqual(ask("when was my first purchase")?.contains("1 Jun 2026"), true)
    }

    func testBiggestSpendingDayByAmount() {
        // 8 June is the biggest by £ (£100), even though 15 June has more transactions.
        let a = ask("which day did i spend the most")
        XCTAssertEqual(a?.contains("8 Jun 2026"), true, "biggest £ day: \(a ?? "nil")")
        XCTAssertEqual(a?.contains("£100.00"), true)
    }

    func testBusiestDayByCount() {
        // 15 June is busiest by COUNT (3 transactions), not the biggest by £.
        let a = ask("which day had the most transactions")
        XCTAssertEqual(a?.contains("15 Jun 2026"), true, "busiest day: \(a ?? "nil")")
        XCTAssertEqual(a?.contains("3 transactions"), true)
    }

    /// "how much did i spend last month" must NOT be hijacked by the first/last-
    /// transaction handler (regression guard for the overloaded word "last").
    func testLastMonthNotHijacked() {
        let a = ask("how much did i spend last month")
        XCTAssertEqual(a?.hasPrefix("**You spent"), true, "last-month spend: \(a ?? "nil")")
        XCTAssertEqual(a?.contains("transaction was"), false, "must not be a first/last-txn answer")
    }

    // MARK: - Round 2: ordinals, open-ended ranges, compares, existence

    func testSecondAndThirdLargest() {
        // Debits sorted: 100, 30, 20, 15, 10, 5, 5, 5.
        XCTAssertEqual(ask("what was my second biggest expense")?.contains("£30.00"), true)
        XCTAssertEqual(ask("what's the 3rd largest transaction")?.contains("£20.00"), true)
    }

    func testOpenEndedRanges() {
        // since 8 June (incl) = 100+30+5+5+15 = £155; before (excl) = £35;
        // after (excl) = £55; up to (incl) = £135.
        XCTAssertEqual(ask("how much did i spend since 8 june")?.contains("£155.00"), true)
        XCTAssertEqual(ask("how much did i spend before 8 june")?.contains("£35.00"), true)
        XCTAssertEqual(ask("how much did i spend after 8 june")?.contains("£55.00"), true)
        XCTAssertEqual(ask("what did i spend up to 8 june")?.contains("£135.00"), true)
    }

    func testLastNDaysWindow() {
        // last 10 days of the span (11–20 June) = 30+5+5+15 = £55.
        XCTAssertEqual(ask("how much did i spend in the last 10 days")?.contains("£55.00"), true)
        // first 2 days (1–2 June) = 10+20+5 = £35.
        XCTAssertEqual(ask("how much in the first 2 days")?.contains("£35.00"), true)
    }

    func testLastDaySpend() {
        // 20 June (the last day) = £15; must not be read as "last transaction".
        let a = ask("how much did i spend on the last day")
        XCTAssertEqual(a?.contains("£15.00"), true, "last-day spend: \(a ?? "nil")")
    }

    func testMerchantComparison() {
        // BRAVO £20 beats ALPHA £10 — and the answer names both sides.
        let a = ask("did i spend more at alpha or bravo")
        XCTAssertEqual(a?.contains("more at Bravo"), true, "compare: \(a ?? "nil")")
        XCTAssertEqual(a?.contains("£10.00"), true)
        XCTAssertEqual(a?.contains("£20.00"), true)
    }

    func testWeekendVsWeekdayComparison() {
        // Only 20 June (Sat) is weekend (£15); weekdays £175.
        let a = ask("do i spend more on weekends or weekdays")
        XCTAssertEqual(a?.contains("more on weekdays"), true, "wk-vs-wd: \(a ?? "nil")")
    }

    func testDaysWithSpendingCount() {
        // Distinct spending days: 1, 2, 8, 15, 20 June = 5.
        XCTAssertEqual(ask("how many days did i spend money")?.contains("5 days"), true)
    }

    func testBusiestDayTransactionCount() {
        // 15 June has 3 transactions — asked as a "how many" question.
        let a = ask("how many transactions on my busiest day")
        XCTAssertEqual(a?.contains("15 Jun 2026"), true, "busiest count: \(a ?? "nil")")
        XCTAssertEqual(a?.contains("3 transactions"), true)
    }

    func testExistenceYesAndHonestNo() {
        // Yes: ALPHA exists in June.
        XCTAssertEqual(ask("did i use alpha in june")?.hasPrefix("**Yes"), true)
        // Honest no: ALPHA has no rows in May (named month never scoped).
        let no = ask("did i use alpha in may")
        XCTAssertEqual(no?.hasPrefix("**No"), true, "expected honest no: \(no ?? "nil")")
        XCTAssertEqual(no?.contains("£0.00"), true)
    }

    func testScopedMaxInOneGo() {
        // "the most I've paid <merchant> in one go" → largest single ALPHA charge.
        XCTAssertEqual(ask("what's the most i've paid alpha in one go")?.contains("£10.00"), true)
    }

    // MARK: - Round 3: amount lookup, category compare, date lookup, misc

    func testAmountReverseLookup() {
        let a = ask("what was the £100 charge")
        XCTAssertEqual(a?.contains("DELTA"), true, "amount lookup: \(a ?? "nil")")
        XCTAssertEqual(a?.contains("8 Jun 2026"), true)
        // absent amount → honest no, never a guess
        XCTAssertEqual(ask("what was the £77.77 charge")?.contains("No transaction for £77.77"), true)
    }

    func testWordNumberTopN() {
        let a = ask("what are my top three expenses")
        XCTAssertEqual(a?.contains("top 3"), true, "word-number top-N: \(a ?? "nil")")
    }

    func testLeastSpentDay() {
        // Day totals: 1 Jun £10, 2 Jun £25, 8 Jun £100, 15 Jun £40, 20 Jun £15.
        let a = ask("which day did i spend the least")
        XCTAssertEqual(a?.contains("1 Jun 2026"), true, "least day: \(a ?? "nil")")
        XCTAssertEqual(a?.contains("£10.00"), true)
    }

    func testNoSpendDays() {
        // Span 1–20 June = 20 days, spending on 5 → 15 no-spend days.
        let a = ask("how many days did i not spend anything")
        XCTAssertEqual(a?.contains("15 no-spend days"), true, "no-spend: \(a ?? "nil")")
    }

    func testHowManyPoundsIsASum() {
        // "how many pounds" must SUM (£190), not count transactions (8).
        let a = ask("how many pounds did i spend")
        XCTAssertEqual(a?.contains("£190.00"), true, "money-count: \(a ?? "nil")")
    }

    func testTypoToleratedSuperlative() {
        XCTAssertEqual(ask("biggest expence?")?.contains("£100.00"), true)
    }

    func testTransactionCountShare() {
        // ALPHA is 1 of 8 debits = 12.5% of transactions.
        let a = ask("what percentage of my transactions were at alpha")
        XCTAssertEqual(a?.contains("12.5%"), true, "count share: \(a ?? "nil")")
    }

    func testWhenDidIDateLookup() {
        let a = ask("when did i pay delta")
        XCTAssertEqual(a?.contains("8 Jun 2026"), true, "date lookup: \(a ?? "nil")")
    }

    func testCategoryComparison() {
        // Local fixture with real categories: Groceries £50 vs Transport £20.
        let rows = [
            Self.row("2026-06-03", "SUPERMART", debit: 50, seq: 1),
            Self.row("2026-06-04", "METRO", debit: 20, seq: 2),
        ].enumerated().map { i, r -> TxnRow in
            var c = r; c.category = i == 0 ? "Groceries" : "Transport"; return c
        }
        let a = FinanceRouter.answer("did i spend more on groceries or transport",
                                     rows: rows, currency: "GBP", money: Self.gbp)
        XCTAssertEqual(a?.contains("more on Groceries"), true, "category compare: \(a ?? "nil")")
        XCTAssertEqual(a?.contains("£50.00"), true)
        XCTAssertEqual(a?.contains("£20.00"), true)
    }

    func testMonthDifferenceCompare() {
        // Two-month fixture: June £30 vs July £10 → difference £20.
        let rows = [
            Self.row("2026-06-05", "ALPHA", debit: 30, seq: 1),
            Self.row("2026-07-05", "BRAVO", debit: 10, seq: 2),
        ]
        let a = FinanceRouter.answer("how much more did i spend in june than july",
                                     rows: rows, currency: "GBP", money: Self.gbp)
        XCTAssertEqual(a?.contains("more in Jun"), true, "month diff: \(a ?? "nil")")
        XCTAssertEqual(a?.contains("Difference: £20.00"), true)
    }
}
