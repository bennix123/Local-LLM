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
        XCTAssertEqual(ask("when was my first purchase")?.contains("1st June 2026"), true)
    }

    func testBiggestSpendingDayByAmount() {
        // 8 June is the biggest by £ (£100), even though 15 June has more transactions.
        let a = ask("which day did i spend the most")
        XCTAssertEqual(a?.contains("8th June 2026"), true, "biggest £ day: \(a ?? "nil")")
        XCTAssertEqual(a?.contains("£100.00"), true)
    }

    func testBusiestDayByCount() {
        // 15 June is busiest by COUNT (3 transactions), not the biggest by £.
        let a = ask("which day had the most transactions")
        XCTAssertEqual(a?.contains("15th June 2026"), true, "busiest day: \(a ?? "nil")")
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
        XCTAssertEqual(a?.contains("15th June 2026"), true, "busiest count: \(a ?? "nil")")
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
        XCTAssertEqual(a?.contains("8th June 2026"), true)
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
        XCTAssertEqual(a?.contains("1st June 2026"), true, "least day: \(a ?? "nil")")
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
        XCTAssertEqual(a?.contains("8th June 2026"), true, "date lookup: \(a ?? "nil")")
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

    // MARK: - Round 4: refunds, repayment, reverse-lookup phrasings, listing,
    // and verb-shadowed existence (regression for the qbatch findings).

    /// A categorised fixture with a refund credit and a card repayment, mirroring
    /// the Amex layout: DENTIST £100 (Healthcare), COFFEE £8.99 (Food & Dining),
    /// AMAZON PRIME £8.99 (Subscriptions), a £12.50 REFUND credit, and a £300
    /// card repayment (category "Payments").
    private static func mixed() -> [TxnRow] {
        func r(_ date: String, _ descr: String, _ cat: String,
               debit: Double = 0, credit: Double = 0, seq: Int) -> TxnRow {
            let p = date.split(separator: "-").compactMap { Int($0) }
            return TxnRow(txnDate: date, month: String(date.prefix(7)), year: p[0], monthNo: p[1],
                          day: p[2], descr: descr, merchant: "", category: cat, debit: debit,
                          credit: credit, balance: nil, currency: "GBP", seq: seq)
        }
        return [
            r("2026-06-01", "CARE DENTAL PLATINUM", "Healthcare", debit: 100, seq: 1),
            r("2026-06-03", "PRET A MANGER", "Food & Dining", debit: 8.99, seq: 2),
            r("2026-06-05", "TFL TRAVEL CHARGE", "Transport", debit: 40.70, seq: 3),
            r("2026-06-07", "AMAZON PRIME", "Subscriptions", debit: 8.99, seq: 4),
            r("2026-06-09", "ASOS REFUND", "Shopping", credit: 12.50, seq: 5),
            r("2026-06-10", "PAYMENT RECEIVED - THANK YOU", "Payments", credit: 300, seq: 6),
        ]
    }
    private func askMixed(_ q: String) -> String? {
        FinanceRouter.answer(q, rows: Self.mixed(), currency: "GBP", money: Self.gbp)
    }

    func testRefundPresentAndCounted() {
        // One real refund (£12.50); the £300 card repayment must NOT count as a refund.
        let a = askMixed("how many refunds did i receive")
        XCTAssertEqual(a?.contains("1 refund"), true, "refund count: \(a ?? "nil")")
        XCTAssertEqual(a?.contains("£12.50"), true)
        XCTAssertEqual(a?.contains("£300") , false, "card repayment leaked into refunds: \(a ?? "nil")")
    }

    func testRefundAbsentIsHonestNo() {
        // Fixture with no credits at all → "no refunds", never a transaction count.
        let a = ask("did i get any refunds")
        XCTAssertEqual(a?.hasPrefix("**No refunds"), true, "refund absent: \(a ?? "nil")")
    }

    func testCardRepaymentPayOff() {
        // "how much did I pay off" → the repayment made (£300), not the balance.
        let a = askMixed("how much did i pay off")
        XCTAssertEqual(a?.contains("paid off £300.00"), true, "pay off: \(a ?? "nil")")
    }

    func testReverseLookupBareDecimal() {
        // "which transaction was 40.70" — bare two-decimal amount, no £ sign.
        let a = askMixed("which transaction was 40.70")
        XCTAssertEqual(a?.contains("TFL TRAVEL CHARGE"), true, "bare-decimal reverse: \(a ?? "nil")")
    }

    func testReverseLookupCurrencyWord() {
        // "what did I spend 100 pounds on" — amount named by a currency WORD.
        let a = askMixed("what did i spend 100 pounds on")
        XCTAssertEqual(a?.contains("CARE DENTAL PLATINUM"), true, "currency-word reverse: \(a ?? "nil")")
    }

    func testShopVerbWithAbsentMerchantIsNo() {
        // "did I shop at Netflix?" — "shop" is a VERB here, not the Shopping
        // category; Netflix is absent, so the honest answer is No.
        let a = askMixed("did i shop at netflix")
        XCTAssertEqual(a?.hasPrefix("**No"), true, "shop-verb shadow: \(a ?? "nil")")
        XCTAssertEqual(a?.contains("Netflix"), true)
    }

    func testUseVerbWithAbsentMerchantIsNo() {
        // "did I use Uber?" — verb "use" + absent merchant → No, not a deferral.
        let a = askMixed("did i use uber")
        XCTAssertEqual(a?.hasPrefix("**No"), true, "use-verb absent: \(a ?? "nil")")
        XCTAssertEqual(a?.contains("Uber"), true)
    }

    func testListCategoryTransactions() {
        // "list my Food & Dining transactions" → itemised, not just a total.
        let a = askMixed("list my food transactions")
        XCTAssertEqual(a?.contains("PRET A MANGER"), true, "category list: \(a ?? "nil")")
        XCTAssertEqual(a?.contains("- "), true, "expected an itemised list: \(a ?? "nil")")
    }

    func testWhatDidIBuyOnMerchant() {
        // "what did I buy on Amazon" → the Amazon row, itemised.
        let a = askMixed("what did i buy on amazon")
        XCTAssertEqual(a?.contains("AMAZON PRIME"), true, "merchant buy-list: \(a ?? "nil")")
    }

    func testReversalPluralRoutesToRefunds() {
        // "reversals" (plural) must still hit the refund handler, not defer.
        let a = askMixed("were there any reversals")
        XCTAssertNotNil(a, "reversal plural deferred")
        XCTAssertEqual(a?.contains("refund"), true, "reversal→refund: \(a ?? "nil")")
    }

    func testReverseLookupPayForPhrasing() {
        // "what did I pay 100 pounds for" — verb "pay" + currency-word amount.
        let a = askMixed("what did i pay 100 pounds for")
        XCTAssertEqual(a?.contains("CARE DENTAL PLATINUM"), true, "pay-for reverse: \(a ?? "nil")")
    }

    func testEatOutScopesToFood() {
        // "how many times did I eat out" must scope to Food & Dining (1 here),
        // not count every transaction.
        let a = askMixed("how many times did i eat out")
        XCTAssertEqual(a?.contains("1 transaction on Food & Dining"), true, "eat-out scope: \(a ?? "nil")")
    }

    /// The shop-verb guard must NOT break the genuine Shopping-category question.
    func testShoppingCategoryStillWorks() {
        let a = askMixed("how much did i spend on shopping")
        // Shopping has only the £12.50 credit here → £0 spent, but it must scope to
        // the Shopping category (mention it), not defer or answer the whole total.
        XCTAssertEqual(a?.contains("Shopping") == true || a?.contains("£0.00") == true, true,
                       "shopping category regressed: \(a ?? "nil")")
    }

    // MARK: - Round 5: median, exclusion, below/range thresholds, combined-sum,
    // count-compare, difference, typo tolerance, trip-nouns, distinct merchants.

    func testMedian() {
        // Self.rows debits sorted [5,5,5,10,15,20,30,100] → median (10+15)/2 = 12.50.
        XCTAssertEqual(ask("what was my median transaction")?.contains("£12.50"), true,
                       "median: \(ask("what was my median transaction") ?? "nil")")
    }

    func testTypoNormalisationTotal() {
        // "mcuh"/"totl" must not become phantom merchants — answer the £190 total.
        XCTAssertEqual(ask("how mcuh did i spend in total")?.contains("£190.00"), true)
        XCTAssertEqual(ask("totl spending please")?.contains("£190.00"), true)
    }

    func testHowManyPoundsIsSumScoped() {
        // "how many pounds on food" is a SUM scoped to Food (£8.99 here), not a count.
        let a = askMixed("how many pounds on food")
        XCTAssertEqual(a?.contains("£8.99"), true, "money-count scoped: \(a ?? "nil")")
        XCTAssertEqual(a?.contains("Food & Dining"), true)
    }

    func testExclusion() {
        // mixed debits = 100 + 8.99 + 40.70 + 8.99 = 158.68; excluding Food (8.99) = 149.69.
        let a = askMixed("whats my spend excluding food")
        XCTAssertEqual(a?.contains("£149.69"), true, "exclusion: \(a ?? "nil")")
        XCTAssertEqual(a?.contains("excluding Food & Dining"), true)
    }

    func testBelowThresholdAndTenner() {
        // Under a tenner: PRET 8.99 + AMAZON 8.99 = 2 transactions.
        let a = askMixed("show me transactions under a tenner")
        XCTAssertEqual(a?.contains("2 transactions under £10.00"), true, "below/tenner: \(a ?? "nil")")
    }

    func testAmountRange() {
        // Self.rows debits in [10,20]: 10, 20, 15 → 3.
        let a = ask("how many transactions were between 10 and 20 pounds")
        XCTAssertEqual(a?.contains("3 transactions between £10.00 and £20.00"), true, "range: \(a ?? "nil")")
    }

    func testCombinedSum() {
        // "TFL and Pret combined" → 40.70 + 8.99 = 49.69 (a SUM, not a comparison).
        let a = askMixed("how much on tfl and pret combined")
        XCTAssertEqual(a?.contains("£49.69"), true, "combined: \(a ?? "nil")")
        XCTAssertEqual(a?.contains("combined"), true)
    }

    func testCountComparison() {
        // Category count-compare: Food 3 txns vs Transport 2 txns → "more … in Food".
        let rows = [
            Self.row("2026-06-01", "PRET", debit: 5, seq: 1),
            Self.row("2026-06-02", "GREGGS", debit: 4, seq: 2),
            Self.row("2026-06-03", "COSTA", debit: 3, seq: 3),
            Self.row("2026-06-04", "TFL", debit: 2, seq: 4),
            Self.row("2026-06-05", "UBER", debit: 9, seq: 5),
        ].enumerated().map { i, r -> TxnRow in
            var c = r; c.category = i < 3 ? "Food & Dining" : "Transport"; return c
        }
        let a = FinanceRouter.answer("how many food transactions versus transport",
                                     rows: rows, currency: "GBP", money: Self.gbp)
        XCTAssertEqual(a?.contains("more transactions in Food & Dining"), true, "count-compare: \(a ?? "nil")")
        XCTAssertEqual(a?.contains("Food & Dining 3"), true)
    }

    func testComparisonDifference() {
        // "how much more … than" → compare + explicit difference.
        let a = askMixed("how much more did i spend on healthcare than food")
        XCTAssertEqual(a?.contains("Difference: £91.01"), true, "difference: \(a ?? "nil")")  // 100 − 8.99
    }

    func testCategoryScopedSuperlativeTripNoun() {
        // "cheapest transport trip" — "trip" must count as an expense noun.
        let a = askMixed("whats my cheapest transport trip")
        XCTAssertEqual(a?.contains("Transport"), true, "trip superlative: \(a ?? "nil")")
        XCTAssertEqual(a?.contains("£40.70"), true)
    }

    func testDistinctMerchantCountNotShoppingScoped() {
        // "how many shops did I visit" counts distinct merchants (8), not the
        // Shopping category (which the "shop" synonym would otherwise select).
        let a = ask("how many shops did i visit")
        XCTAssertEqual(a?.contains("8 different merchants"), true, "distinct merchants: \(a ?? "nil")")
    }
}
