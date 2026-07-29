// FinanceRouterTests — guards the deterministic finance-query router (FinanceQuery.swift),
// the heart of "no hallucinated figures": every numeric answer must be summed straight from
// the parsed TxnRow set, formatted exclusively through the caller's `money` closure, and the
// router must return nil (defer to the LLM) for advisory / open-ended questions. The suite
// pins exact answer strings for balance (single account, multi-account with card "owed"
// semantics, as-of-a-date), counts, total spend / income / net, category & merchant & period
// scoping (month names, this/last month, exact days in three phrasings), largest / top-N,
// averages, what-if percentage cuts, the financial-reasoning block (savings rate, runway,
// risky months), and the ≥3-distinct-months recurring-charge ("ghosts") detector — all over
// small synthetic fixtures whose sums were hand-verified and cross-checked against the
// penny-conformance binary's answer formats.
import XCTest
@testable import PennyTxnStore

// MARK: - Fixtures

private enum RouterFix {
    static let gbp: (Double) -> String = { String(format: "£%.2f", $0) }

    static func row(_ date: String, _ descr: String, merchant: String = "",
                    category: String = "", debit: Double = 0, credit: Double = 0,
                    balance: Double? = nil, seq: Int = 0) -> TxnRow {
        let p = date.split(separator: "-").compactMap { Int($0) }
        precondition(p.count == 3, "fixture date must be YYYY-MM-DD, got \(date)")
        return TxnRow(txnDate: date, month: String(date.prefix(7)), year: p[0],
                      monthNo: p[1], day: p[2], descr: descr, merchant: merchant,
                      category: category, debit: debit, credit: credit,
                      balance: balance, currency: "GBP", seq: seq)
    }

    /// One month (June 2026), running balance on every row.
    /// Debits total £304.49 across 6 rows; income £2500.00 (the £200 card
    /// repayment is category "Payments" and must never count as income).
    static let june: [TxnRow] = [
        row("2026-06-01", "SALARY ACME LTD", merchant: "Acme Ltd", category: "Income",
            credit: 2500.00, balance: 3000.00, seq: 1),
        row("2026-06-04", "TESCO STORES 1234", merchant: "Tesco", category: "Groceries",
            debit: 45.50, balance: 2954.50, seq: 2),
        row("2026-06-05", "NETFLIX.COM", merchant: "Netflix", category: "Entertainment",
            debit: 9.99, balance: 2944.51, seq: 3),
        row("2026-06-10", "TESCO STORES 1234", merchant: "Tesco", category: "Groceries",
            debit: 30.25, balance: 2914.26, seq: 4),
        row("2026-06-12", "AMAZON MARKETPLACE", merchant: "Amazon", category: "Shopping",
            debit: 120.00, balance: 2794.26, seq: 5),
        row("2026-06-15", "UBER TRIP HELP.UBER.COM", merchant: "Uber", category: "Transport",
            debit: 18.75, balance: 2775.51, seq: 6),
        row("2026-06-20", "PAYMENT RECEIVED - THANK YOU", merchant: "", category: "Payments",
            credit: 200.00, balance: 2975.51, seq: 7),
        row("2026-06-25", "BRITISH GAS DD", merchant: "British Gas", category: "Bills & Utilities",
            debit: 80.00, balance: 2895.51, seq: 8),
    ]

    /// Three months (Apr–Jun 2026). Netflix £9.99 in all 3 months (recurring);
    /// Spotify 3× but in only 2 distinct months (must NOT be recurring);
    /// Corner Cafe in 3 months but £5/£30/£90 (CV ≈ 0.86, must NOT be recurring).
    /// Salary £2000/month. Debits: Apr £38.97, May £51.98, Jun £99.99 = £190.94.
    static let quarter: [TxnRow] = [
        row("2026-04-01", "SALARY", merchant: "Acme Payroll", category: "Income",
            credit: 2000.00, balance: 2100.00, seq: 1),
        row("2026-04-03", "SPOTIFY LTD", merchant: "Spotify", category: "Entertainment",
            debit: 11.99, balance: 2088.01, seq: 2),
        row("2026-04-05", "NETFLIX.COM", merchant: "Netflix", category: "Entertainment",
            debit: 9.99, balance: 2078.02, seq: 3),
        row("2026-04-20", "SPOTIFY LTD", merchant: "Spotify", category: "Entertainment",
            debit: 11.99, balance: 2066.03, seq: 4),
        row("2026-04-22", "CORNER CAFE", merchant: "Corner Cafe", category: "Food & Dining",
            debit: 5.00, balance: 2061.03, seq: 5),
        row("2026-05-01", "SALARY", merchant: "Acme Payroll", category: "Income",
            credit: 2000.00, balance: 4061.03, seq: 6),
        row("2026-05-03", "SPOTIFY LTD", merchant: "Spotify", category: "Entertainment",
            debit: 11.99, balance: 4049.04, seq: 7),
        row("2026-05-05", "NETFLIX.COM", merchant: "Netflix", category: "Entertainment",
            debit: 9.99, balance: 4039.05, seq: 8),
        row("2026-05-18", "CORNER CAFE", merchant: "Corner Cafe", category: "Food & Dining",
            debit: 30.00, balance: 4009.05, seq: 9),
        row("2026-06-01", "SALARY", merchant: "Acme Payroll", category: "Income",
            credit: 2000.00, balance: 6009.05, seq: 10),
        row("2026-06-05", "NETFLIX.COM", merchant: "Netflix", category: "Entertainment",
            debit: 9.99, balance: 5999.06, seq: 11),
        row("2026-06-21", "CORNER CAFE", merchant: "Corner Cafe", category: "Food & Dining",
            debit: 90.00, balance: 5909.06, seq: 12),
    ]

    /// One month where spending (£140) beats income (£100).
    static let overspend: [TxnRow] = [
        row("2026-06-01", "PART TIME WAGES", merchant: "Wages Co", category: "Income",
            credit: 100.00, balance: 100.00, seq: 1),
        row("2026-06-10", "BIG PURCHASE", merchant: "MegaStore", category: "Shopping",
            debit: 140.00, balance: -40.00, seq: 2),
    ]

    /// June rows with every running balance stripped.
    static let noBalance: [TxnRow] = june.map { r in
        var c = r; c.balance = nil; return c
    }

    /// Merchant-prefix disambiguation: "Tesco" (£50 + £30) vs "Tesco Express" (£20).
    static let tescoPair: [TxnRow] = [
        row("2026-06-02", "TESCO STORES 1234", merchant: "Tesco", category: "Groceries",
            debit: 50.00, seq: 1),
        row("2026-06-08", "TESCO EXPRESS LONDON", merchant: "Tesco Express", category: "Groceries",
            debit: 20.00, seq: 2),
        row("2026-06-15", "TESCO STORES 1234", merchant: "Tesco", category: "Groceries",
            debit: 30.00, seq: 3),
    ]
}

private func ask(_ q: String, _ rows: [TxnRow],
                 accounts: [FinanceRouter.AccountBalance] = [],
                 money: (Double) -> String = RouterFix.gbp) -> String? {
    FinanceRouter.answer(q, rows: rows, currency: "GBP", accounts: accounts, money: money)
}

private func answerOrFail(_ q: String, _ rows: [TxnRow],
                          accounts: [FinanceRouter.AccountBalance] = [],
                          file: StaticString = #filePath, line: UInt = #line) -> String {
    guard let a = ask(q, rows, accounts: accounts) else {
        XCTFail("router declined \"\(q)\" — expected a deterministic answer",
                file: file, line: line)
        return "<router declined>"
    }
    return a
}

// MARK: - Balance

final class FinanceRouterBalanceTests: XCTestCase {

    func testLatestBalanceFromRows() {
        XCTAssertEqual(answerOrFail("what is my balance", RouterFix.june),
                       "**Your latest balance is £2895.51.**",
                       "latest balance must come from the LAST row carrying a balance")
    }

    func testBalancePhrasingInMyAccount() {
        XCTAssertEqual(answerOrFail("how much money do i have in my account", RouterFix.june),
                       "**Your latest balance is £2895.51.**")
    }

    func testBalanceAsOfDayWithTransaction() {
        XCTAssertEqual(answerOrFail("what was my balance on 10 june", RouterFix.june),
                       "**Your balance at the end of 10 Jun 2026 was £2914.26.**",
                       "as-of balance must be the running balance of the last row on/before that day")
    }

    func testBalanceAsOfDayBetweenTransactions() {
        // No txn on 7 June — must fall back to the last balance on or before it (5 June).
        XCTAssertEqual(answerOrFail("what was my balance on 7 june", RouterFix.june),
                       "**Your balance at the end of 7 Jun 2026 was £2944.51.**")
    }

    func testBalanceAsOfDayBeforeStatementOpens() {
        XCTAssertEqual(answerOrFail("what was my balance on 1 may 2026", RouterFix.june),
                       "This statement doesn't show a running balance on or before 1 May 2026.",
                       "a date before the first row must NOT invent a balance")
    }

    func testMultiAccountBalanceCardSubtracts() {
        let accounts = [
            FinanceRouter.AccountBalance(name: "HSBC Current", balance: 1000.00, isCard: false),
            FinanceRouter.AccountBalance(name: "Monzo", balance: 500.00, isCard: false),
            FinanceRouter.AccountBalance(name: "Amex", balance: 200.00, isCard: true),
        ]
        let expected = """
        **Your total balance is £1300.00** across 3 accounts:
        - HSBC Current: £1000.00
        - Monzo: £500.00
        - Amex: £200.00 owed (card)
        _Total = bank balances − card balances._
        """
        XCTAssertEqual(answerOrFail("what is my balance", RouterFix.june, accounts: accounts),
                       expected,
                       "card balances are money OWED and must subtract from the total")
    }

    func testMultiAccountIgnoresNilBalances() {
        let accounts = [
            FinanceRouter.AccountBalance(name: "Ghost Acct", balance: nil, isCard: false),
            FinanceRouter.AccountBalance(name: "HSBC Current", balance: 1000.00, isCard: false),
        ]
        // Only one account HAS a balance → not a multi-account answer; the
        // statement's own running balance wins.
        XCTAssertEqual(answerOrFail("what is my balance", RouterFix.june, accounts: accounts),
                       "**Your latest balance is £2895.51.**")
    }

    func testSingleCreditCardBalanceIsOwed() {
        let accounts = [FinanceRouter.AccountBalance(name: "Amex", balance: 350.75, isCard: true)]
        XCTAssertEqual(answerOrFail("what is my balance", RouterFix.june, accounts: accounts),
                       "**You currently owe £350.75 on Amex** (statement closing balance).",
                       "a lone card account must answer with owed semantics, not 'your balance is'")
    }

    func testSingleBankAccountFallbackWhenRowsHaveNoBalance() {
        let accounts = [FinanceRouter.AccountBalance(name: "HSBC Current", balance: 1000.00, isCard: false)]
        XCTAssertEqual(answerOrFail("what is my balance", RouterFix.noBalance, accounts: accounts),
                       "**Your latest balance is £1000.00** (HSBC Current, statement closing balance).")
    }

    // MARK: - Card identity ("which statement is a credit card?")

    private static let mixedAccounts = [
        FinanceRouter.AccountBalance(name: "HSBC Current", balance: 1000.00, isCard: false),
        FinanceRouter.AccountBalance(name: "American Express", balance: 200.00, isCard: true),
    ]

    func testWhichStatementIsCreditCardNamesTheCard() {
        // The exact question that used to fall through to the income handler and
        // wrongly answer "You received £… across N credits."
        XCTAssertEqual(answerOrFail("Which statement belongs to a credit card?",
                                    RouterFix.june, accounts: Self.mixedAccounts),
                       "**American Express is your credit-card statement.**")
    }

    func testIsThisACreditCardNamesTheCard() {
        XCTAssertEqual(answerOrFail("is any of these a credit card?",
                                    RouterFix.june, accounts: Self.mixedAccounts),
                       "**American Express is your credit-card statement.**")
    }

    func testWhichCreditCardListsMultipleCards() {
        let accounts = [
            FinanceRouter.AccountBalance(name: "HSBC Current", balance: 1000.00, isCard: false),
            FinanceRouter.AccountBalance(name: "American Express", balance: 200.00, isCard: true),
            FinanceRouter.AccountBalance(name: "Barclaycard", balance: 90.00, isCard: true),
        ]
        XCTAssertEqual(answerOrFail("which of my statements are credit cards?",
                                    RouterFix.june, accounts: accounts),
                       """
                       **These are your credit-card statements:**
                       - American Express
                       - Barclaycard
                       """)
    }

    func testWhichCreditCardHonestWhenNoneAreCards() {
        let accounts = [
            FinanceRouter.AccountBalance(name: "HSBC Current", balance: 1000.00, isCard: false),
            FinanceRouter.AccountBalance(name: "Monzo", balance: 500.00, isCard: false),
        ]
        XCTAssertEqual(answerOrFail("which statement is a credit card?",
                                    RouterFix.june, accounts: accounts),
                       "**None of your imported statements is a credit card** — they all read as bank / current accounts.")
    }

    func testCreditCardSpendQuestionStillDefersOrSums() {
        // "spent on my credit card" is NOT an identity question — it must not be
        // hijacked by the card-identity handler (no which/belongs/identify cue).
        let ans = answerOrFail("how much did I spend on my credit card?",
                               RouterFix.june, accounts: Self.mixedAccounts)
        XCTAssertFalse(ans.contains("credit-card statement"),
                       "a spend question must not be answered as a card-identity lookup")
    }

    func testCardIdentityDefersWithoutAccountContext() {
        // No account list (e.g. a row-only call) → defer to the model, don't guess.
        XCTAssertNil(ask("which statement is a credit card?", RouterFix.june),
                     "card identity needs the per-account isCard flags; with none, defer")
    }

    func testWhichStatementsAreCurrentAccountsListsNonCards() {
        let accounts = [
            FinanceRouter.AccountBalance(name: "Monzo", balance: 500.00, isCard: false),
            FinanceRouter.AccountBalance(name: "Barclays", balance: 1000.00, isCard: false),
            FinanceRouter.AccountBalance(name: "American Express", balance: 200.00, isCard: true),
        ]
        XCTAssertEqual(answerOrFail("Which statements are current accounts?",
                                    RouterFix.june, accounts: accounts),
                       """
                       **These are your current (bank) accounts:**
                       - Barclays
                       - Monzo
                       """)
    }

    func testWhichIsCurrentAccountSingleNonCard() {
        XCTAssertEqual(answerOrFail("which of these is a current account?",
                                    RouterFix.june, accounts: Self.mixedAccounts),
                       "**HSBC Current is your current account.**")
    }

    func testCreditLimitPhrasesDoNotReadAsIncome() {
        // "credit limit" / "available credit" contain "credit" but are card headroom,
        // not money-in — the income handler must not hijack them (they're answered
        // upstream from the statement header).
        for q in ["what is the available credit limit on the Amex account?",
                  "what's my credit limit?",
                  "how much available credit do I have?"] {
            let a = ask(q, RouterFix.june)
            XCTAssertNil(a.map { $0.contains("You received") ? $0 : nil } ?? nil,
                         "‘\(q)’ must not be answered as income; got: \(a ?? "nil")")
        }
        // A genuine income question still works.
        XCTAssertTrue(answerOrFail("how much did I receive in credits?", RouterFix.june)
                        .contains("You received"))
    }

    func testOpeningBalanceQuestionDefersToUpstream() {
        // "starting/opening balance" is a statement-header figure — the router must
        // NOT answer it with the latest all-account total; it defers to the model /
        // the app's document-metadata handler.
        let accounts = [FinanceRouter.AccountBalance(name: "Barclays", balance: 1133.40, isCard: false)]
        XCTAssertNil(ask("what was the Barclays starting balance?", RouterFix.june, accounts: accounts),
                     "opening/starting balance must not be answered as the latest balance")
        XCTAssertNil(ask("opening balance?", RouterFix.june, accounts: accounts))
        // A plain "what is my balance" still answers as before.
        XCTAssertNotNil(ask("what is my balance?", RouterFix.june, accounts: accounts))
    }

    func testCurrentAccountHonestWhenAllCards() {
        let accounts = [
            FinanceRouter.AccountBalance(name: "American Express", balance: 200.00, isCard: true),
            FinanceRouter.AccountBalance(name: "Barclaycard", balance: 90.00, isCard: true),
        ]
        XCTAssertEqual(answerOrFail("which statement is a bank account?",
                                    RouterFix.june, accounts: accounts),
                       "**None of your imported statements is a current account** — they all read as credit cards.")
    }

    func testNoRunningBalanceIsAdmittedNotInvented() {
        XCTAssertEqual(answerOrFail("what is my balance", RouterFix.noBalance),
                       "This statement doesn't show a running balance, so I can't give you a current figure.")
    }
}

// MARK: - Counts

final class FinanceRouterCountTests: XCTestCase {

    func testCountAllTransactions() {
        XCTAssertEqual(answerOrFail("how many transactions did i make", RouterFix.june),
                       "**8 transactions.**")
    }

    func testCountNoOfPhrasing() {
        XCTAssertEqual(answerOrFail("no. of transactions", RouterFix.june),
                       "**8 transactions.**")
    }

    func testCountScopedToMerchant() {
        XCTAssertEqual(answerOrFail("number of transactions at tesco", RouterFix.june),
                       "**2 transactions at Tesco.**")
    }

    func testHowOftenScopedToCategory() {
        XCTAssertEqual(answerOrFail("how often did i buy groceries", RouterFix.june),
                       "**2 transactions on Groceries.**")
    }

    func testCountUsesThousandsGrouping() {
        let many: [TxnRow] = (0..<1234).map { i in
            RouterFix.row("2026-06-\(String(format: "%02d", i % 28 + 1))",
                          "COFFEE \(i)", debit: 2.50, seq: i)
        }
        XCTAssertEqual(answerOrFail("how many transactions", many),
                       "**1,234 transactions.**",
                       "counts must be comma-grouped like Python's grp()")
    }
}

// MARK: - Total spend + category / merchant / period scoping

final class FinanceRouterSpendScopeTests: XCTestCase {

    func testTotalSpendUnscoped() {
        XCTAssertEqual(answerOrFail("how much did i spend", RouterFix.june),
                       "**You spent £304.49** across 6 transactions.")
    }

    func testGrocerySpendPhrasingVariants() {
        // All variants the router claims to route: synonym "grocer*", direct
        // category word, catch-all "total spent", and case-insensitivity.
        let expected = "**You spent £75.75 on Groceries** across 2 transactions."
        for q in ["how much did i spend on groceries",
                  "grocery spending",
                  "total spent on groceries",
                  "HOW MUCH DID I SPEND ON GROCERIES?"] {
            XCTAssertEqual(ask(q, RouterFix.june), expected, "phrasing failed: \"\(q)\"")
        }
    }

    func testFoodSynonymMapsToFoodAndDining() {
        XCTAssertEqual(answerOrFail("how much do i spend on food", RouterFix.quarter),
                       "**You spent £125.00 on Food & Dining** across 3 transactions.")
    }

    func testMerchantSpendPhrasingVariants() {
        let expected = "**You spent £75.75 at Tesco** across 2 transactions."
        for q in ["what did i spend at tesco", "how much have i paid tesco"] {
            XCTAssertEqual(ask(q, RouterFix.june), expected, "phrasing failed: \"\(q)\"")
        }
    }

    func testLongestMerchantNameWins() {
        XCTAssertEqual(answerOrFail("how much did i spend at tesco express", RouterFix.tescoPair),
                       "**You spent £20.00 at Tesco Express** across 1 transaction.",
                       "'tesco express' must scope to the longer merchant, not plain Tesco")
        // Bare "tesco" scopes to exactly the Tesco-tagged rows, NOT the distinct
        // merchant "Tesco Express". (Exact merchant-field match — the fix that also
        // stops "TfL" matching "neTFLix" and "Amazon" pulling in "Amazon Prime".)
        XCTAssertEqual(answerOrFail("how much did i spend at tesco", RouterFix.tescoPair),
                       "**You spent £80.00 at Tesco** across 2 transactions.")
    }

    func testMerchantScopeReportsCreditsSeparately() {
        // Acme Ltd only ever paid us — spend is £0.00 and the credit is
        // called out, never silently mixed into "spent".
        XCTAssertEqual(answerOrFail("how much did i spend at acme ltd", RouterFix.june),
                       "**You spent £0.00 at Acme Ltd** across 0 transactions. (You also received £2500.00 here.)")
    }

    func testSpendInNamedMonth() {
        XCTAssertEqual(answerOrFail("how much did i spend in april", RouterFix.quarter),
                       "**You spent £38.97 in April** across 4 transactions.")
    }

    func testSpendThisMonthAnchorsToLatestMonth() {
        XCTAssertEqual(answerOrFail("how much did i spend this month", RouterFix.quarter),
                       "**You spent £99.99 this month** across 2 transactions.")
    }

    func testSpendLastMonthIsSecondNewestMonth() {
        XCTAssertEqual(answerOrFail("how much did i spend last month", RouterFix.quarter),
                       "**You spent £51.98 last month** across 3 transactions.")
    }

    func testSpendLastMonthSingleMonthStatementFallsBackToOnlyMonth() {
        XCTAssertEqual(answerOrFail("how much did i spend last month", RouterFix.june),
                       "**You spent £304.49 last month** across 6 transactions.")
    }

    func testCategoryAndMonthScopesCombine() {
        XCTAssertEqual(answerOrFail("how much did i spend on groceries in june", RouterFix.june),
                       "**You spent £75.75 on Groceries in June** across 2 transactions.")
    }

    func testSpendOnExactDayPhrasingVariants() {
        // day-first, month-first, ordinal-of, and numeric UK day/month order —
        // year resolved from the data when the question omits it.
        let expected = "**You spent £45.50 on 4 Jun 2026** across 1 transaction."
        for q in ["how much did i spend on 4 june",
                  "how much did i spend on june 4th",
                  "how much did i spend on the 4th of june 2026",
                  "how much did i spend on 4/6"] {
            XCTAssertEqual(ask(q, RouterFix.june), expected, "phrasing failed: \"\(q)\"")
        }
    }

    func testSpendOnDayWithNoTransactionsIsExactZero() {
        XCTAssertEqual(answerOrFail("how much did i spend on 7 june", RouterFix.june),
                       "**You spent £0.00 on 7 Jun 2026** across 0 transactions.",
                       "an empty day is a valid exact answer (zero), not a decline")
    }
}

// MARK: - Income / net / average / breakdown / largest / top-N / what-if

final class FinanceRouterAggregateTests: XCTestCase {

    func testIncomeExcludesCardRepayments() {
        XCTAssertEqual(answerOrFail("how much did i receive", RouterFix.june),
                       "**You received £2500.00** across 1 credit. (Card repayments of £200.00 aren't counted — that's your own money.)",
                       "category-Payments credits are the user's own money, never income")
    }

    func testIncomePhrasingMoneyReceived() {
        let a = answerOrFail("total money received", RouterFix.june)
        XCTAssertTrue(a.contains("£2500.00"), "unexpected income answer: \(a)")
        XCTAssertTrue(a.contains("£200.00 aren't counted"),
                      "repayment exclusion note missing: \(a)")
    }

    func testNetKept() {
        XCTAssertEqual(answerOrFail("what is my net", RouterFix.june),
                       "**Net: £2195.51** — £2500.00 in minus £304.49 out. You kept £2195.51.")
    }

    func testHowMuchDidISaveRoutesToNet() {
        XCTAssertEqual(answerOrFail("how much did i save", RouterFix.june),
                       "**Net: £2195.51** — £2500.00 in minus £304.49 out. You kept £2195.51.")
    }

    func testNetOverspentWording() {
        XCTAssertEqual(answerOrFail("profit and loss", RouterFix.overspend),
                       "**Net: £-40.00** — £100.00 in minus £140.00 out. You overspent by £40.00.")
    }

    func testNetScopedToMonth() {
        XCTAssertEqual(answerOrFail("what is my net in april", RouterFix.quarter),
                       "**Net in April: £1961.03** — £2000.00 in minus £38.97 out. You kept £1961.03.")
    }

    func testAveragePerTransaction() {
        XCTAssertEqual(answerOrFail("what is my average transaction size", RouterFix.june),
                       "**Your average transaction is £50.75** across 6 debits.")
    }

    func testAveragePerMonth() {
        XCTAssertEqual(answerOrFail("how much do i spend monthly on average", RouterFix.quarter),
                       "**You spend about £63.65/month** on average (over 3 months).")
    }

    func testCategoryBreakdownRankedWithPercentages() {
        let expected = """
        **Spending by category:**
        - **Shopping**: £120.00 (39.4%)
        - **Bills & Utilities**: £80.00 (26.3%)
        - **Groceries**: £75.75 (24.9%)
        - **Transport**: £18.75 (6.2%)
        - **Entertainment**: £9.99 (3.3%)
        """
        XCTAssertEqual(answerOrFail("breakdown by category", RouterFix.june), expected)
    }

    func testWhereDidMyMoneyGoIsABreakdown() {
        let a = answerOrFail("where did my money go", RouterFix.june)
        XCTAssertTrue(a.hasPrefix("**Spending by category:**"), "unexpected answer: \(a)")
        XCTAssertTrue(a.contains("- **Shopping**: £120.00 (39.4%)"), "unexpected answer: \(a)")
    }

    func testWhatDidISpendOnWithoutADayIsABreakdown() {
        let a = answerOrFail("what did i spend on", RouterFix.june)
        XCTAssertTrue(a.hasPrefix("**Spending by category:**"),
                      "'what did i spend on' (no date) must break down by category, got: \(a)")
    }

    func testLargestSingleExpense() {
        let expected = "**Your largest expense was £120.00** — AMAZON MARKETPLACE on 2026-06-12."
        XCTAssertEqual(answerOrFail("what was my biggest expense", RouterFix.june), expected)
        XCTAssertEqual(answerOrFail("most expensive purchase", RouterFix.june), expected)
    }

    func testLargestExpenseScopedToMonth() {
        XCTAssertEqual(answerOrFail("biggest expense in april", RouterFix.quarter),
                       "**Your largest expense in April was £11.99** — SPOTIFY LTD on 2026-04-03.")
    }

    func testTopThreeExpensesOrdered() {
        let expected = """
        **Your top 3 expenses:**
        1. £120.00 — AMAZON MARKETPLACE (2026-06-12)
        2. £80.00 — BRITISH GAS DD (2026-06-25)
        3. £45.50 — TESCO STORES 1234 (2026-06-04)
        """
        XCTAssertEqual(answerOrFail("what were my top 3 expenses", RouterFix.june), expected)
    }

    func testTopExpensesDefaultsToFive() {
        let a = answerOrFail("what were my biggest expenses", RouterFix.june)
        let lines = a.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "**Your top 5 expenses:**", "unexpected header: \(a)")
        XCTAssertEqual(lines.count, 6, "expected header + 5 entries, got: \(a)")
        XCTAssertFalse(a.contains("£9.99"), "6th-largest debit must be cut at N=5: \(a)")
    }

    func testTopNClampsToAvailableDebits() {
        let a = answerOrFail("what were my top 99 expenses", RouterFix.june)
        let lines = a.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "**Your top 6 expenses:**",
                       "header must reflect the 6 debits actually available: \(a)")
        XCTAssertEqual(lines.count, 7, "expected header + all 6 debits, got: \(a)")
    }

    func testTopNScopedToMerchant() {
        let expected = """
        **Your top 2 expenses at Tesco:**
        1. £45.50 — TESCO STORES 1234 (2026-06-04)
        2. £30.25 — TESCO STORES 1234 (2026-06-10)
        """
        XCTAssertEqual(answerOrFail("top 3 expenses at tesco", RouterFix.june), expected)
    }

    func testWhatIfCutCategoryByPercent() {
        XCTAssertEqual(
            answerOrFail("if i cut shopping by 20% how much would i save", RouterFix.june),
            "**Cutting Shopping by 20% would save £24.00** — about £24.00/month, £288.00/year. (Shopping is currently £120.00 over 1 month.)")
    }

    func testWhatIfCutMerchantByPercent() {
        XCTAssertEqual(
            answerOrFail("if i cut amazon by 50% how much would i save", RouterFix.june),
            "**Cutting Amazon by 50% would save £60.00** — about £60.00/month, £720.00/year. (Amazon is currently £120.00 over 1 month.)")
    }

    func testEveryFigureFlowsThroughMoneyClosure() {
        let marker: (Double) -> String = { "USD[\(String(format: "%.2f", $0))]" }
        XCTAssertEqual(ask("how much did i spend", RouterFix.june, money: marker),
                       "**You spent USD[304.49]** across 6 transactions.",
                       "amounts must be rendered by the injected money closure, not hardcoded £")
        XCTAssertEqual(ask("what is my balance", RouterFix.june, money: marker),
                       "**Your latest balance is USD[2895.51].**")
    }
}

// MARK: - Recurring charges / ghosts (≥ 3 distinct months rule)

final class FinanceRouterRecurringTests: XCTestCase {

    func testDetectsThreeMonthStableCharge() {
        let found = FinanceRouter.recurringCharges(RouterFix.quarter)
        XCTAssertEqual(found.count, 1,
                       "only Netflix qualifies; got \(found.map(\.name))")
        guard let n = found.first else { return }
        XCTAssertEqual(n.name, "Netflix")
        XCTAssertEqual(n.months, 3)
        XCTAssertEqual(n.count, 3)
        XCTAssertEqual(n.amount, 9.99, accuracy: 0.001)
        XCTAssertEqual(n.confidence, 1.0, accuracy: 0.0001,
                       "identical amounts ⇒ zero variation ⇒ full confidence")
    }

    func testThreeOccurrencesInTwoMonthsIsNotRecurring() {
        // Spotify appears 3× but only in Apr + May — fails the ≥3 distinct months rule.
        let names = FinanceRouter.recurringCharges(RouterFix.quarter).map(\.name)
        XCTAssertFalse(names.contains("Spotify"),
                       "3 txns across only 2 months must not count as recurring: \(names)")
    }

    func testVolatileAmountsAreNotRecurring() {
        // Corner Cafe hits 3 months but £5/£30/£90 (CV ≈ 0.86 > 0.25).
        let names = FinanceRouter.recurringCharges(RouterFix.quarter).map(\.name)
        XCTAssertFalse(names.contains("Corner Cafe"),
                       "wildly varying amounts must not count as recurring: \(names)")
    }

    func testCoefficientOfVariationBoundary() {
        var rows: [TxnRow] = []
        // Gymbox 100/100/150 → CV ≈ 0.202 (≤ 0.25, in); Wildcard 100/100/200 → CV ≈ 0.354 (out).
        for (i, m) in ["2026-04", "2026-05", "2026-06"].enumerated() {
            rows.append(RouterFix.row("\(m)-02", "GYMBOX DD", merchant: "Gymbox",
                                      debit: i == 2 ? 150 : 100, seq: i))
            rows.append(RouterFix.row("\(m)-09", "WILDCARD", merchant: "Wildcard",
                                      debit: i == 2 ? 200 : 100, seq: 10 + i))
        }
        let names = FinanceRouter.recurringCharges(rows).map(\.name)
        XCTAssertEqual(names, ["Gymbox"],
                       "CV ≤ 0.25 is recurring, above is not; got \(names)")
    }

    func testSingleMonthHistoryYieldsNoGhosts() {
        // One month of data can never satisfy the ≥3-months rule — the sidebar
        // Ghosts badge must show a real zero, not an invented count.
        XCTAssertEqual(FinanceRouter.recurringCharges(RouterFix.june).count, 0)
        XCTAssertTrue(FinanceRouter.recurringCharges(RouterFix.overspend).isEmpty)
    }

    func testEmptyMerchantFallsBackToDescription() {
        let rows = ["2026-04-06", "2026-05-06", "2026-06-06"].enumerated().map { i, d in
            RouterFix.row(d, "STANDING ORDER 4412", debit: 50.00, seq: i)
        }
        let found = FinanceRouter.recurringCharges(rows)
        XCTAssertEqual(found.map(\.name), ["STANDING ORDER 4412"],
                       "rows without a merchant must group by description")
    }

    func testCreditsNeverCountAsRecurringCharges() {
        // Salary is credited every month in the quarter fixture — it must not
        // surface as a recurring CHARGE (debit-only detector).
        let names = FinanceRouter.recurringCharges(RouterFix.quarter).map(\.name)
        XCTAssertFalse(names.contains("Acme Payroll"), "credits leaked into charges: \(names)")
    }

    func testSubscriptionsAnswerListsOnlyQualifiedCharges() {
        let expected = """
        **Recurring charges & subscriptions** — payments repeating at a regular cadence and similar amount (about £9.99/month):

        - **Netflix** — ~£9.99 × 3 (3 months, 100% confidence)
        """
        XCTAssertEqual(answerOrFail("what subscriptions am i paying for", RouterFix.quarter),
                       expected)
        let a2 = answerOrFail("list my recurring payments", RouterFix.quarter)
        XCTAssertTrue(a2.contains("**Netflix**"), "unexpected answer: \(a2)")
        XCTAssertFalse(a2.contains("Spotify"), "2-month Spotify leaked in: \(a2)")
        XCTAssertFalse(a2.contains("Corner Cafe"), "volatile Cafe leaked in: \(a2)")
    }

    func testSubscriptionsAnswerAdmitsNoneOnOneMonthOfHistory() {
        XCTAssertEqual(answerOrFail("do i have any subscriptions", RouterFix.june),
                       "**No recurring charges or subscriptions detected.** Nothing repeats at a steady cadence and stable amount.")
    }
}

// MARK: - Financial-reasoning block (savings rate, runway, risky months)

final class FinanceRouterReasoningTests: XCTestCase {

    func testSavingsRate() {
        XCTAssertEqual(answerOrFail("what is my savings rate", RouterFix.quarter),
                       "**Savings rate: 96.8%** — saved £5809.06 of £6000.00 income (spent £190.94).")
    }

    func testSurvivalRunway() {
        XCTAssertEqual(
            answerOrFail("how long could i survive if my income stopped", RouterFix.quarter),
            "**Survival runway: about 92.8 months** — closing balance £5909.06 ÷ average monthly spend £63.65.")
    }

    func testNoRiskyMonthsWhenIncomeAlwaysWins() {
        XCTAssertEqual(
            answerOrFail("which months were financially risky", RouterFix.quarter),
            "**No risky months** — income exceeded spending every month. Tightest: Jun 2026 (net £1900.01), May 2026 (net £1948.02), Apr 2026 (net £1961.03).")
    }

    func testRiskyMonthsFlagsOverspending() {
        XCTAssertEqual(answerOrFail("was i in the red any months", RouterFix.overspend),
                       "**Financially risky months** (spending beat income): Jun 2026 (£-40.00)")
    }
}

// MARK: - Declines (must return nil → LLM fallback)

final class FinanceRouterDeclineTests: XCTestCase {

    func testAdvisoryQuestionsAreDeclined() {
        for q in ["roast my spending habits",
                  "can i afford a new laptop",
                  "why is my spending so high",
                  "is my spending healthy",
                  "predict my expenses for next month",
                  "recommend a budget for me"] {
            XCTAssertNil(ask(q, RouterFix.june),
                         "advisory question must fall through to the LLM: \"\(q)\"")
        }
    }

    func testUnrecognisedQuestionsAreDeclined() {
        for q in ["what should i do with my money", "hello"] {
            XCTAssertNil(ask(q, RouterFix.june),
                         "non-financial question must fall through to the LLM: \"\(q)\"")
        }
    }

    func testEmptyRowsAlwaysDecline() {
        XCTAssertNil(ask("how much did i spend", []),
                     "no parsed rows ⇒ nothing deterministic to say")
        let accounts = [FinanceRouter.AccountBalance(name: "HSBC", balance: 1000, isCard: false)]
        XCTAssertNil(ask("what is my balance", [], accounts: accounts),
                     "the empty-rows guard precedes even account-based balance answers")
    }
}

// MARK: - Merchant/category disambiguation regressions (3-month eval pass)

/// Guards the fixes surfaced by the 3-month StatementBulkEvalTests set: merchant
/// names must not match as a bare substring of another merchant, short (2-letter)
/// merchant names must still resolve, a category synonym inside a merchant name
/// must not hijack a merchant question, and a category superlative must not fire
/// the recurring-charge detector.
final class FinanceRouterDisambiguationTests: XCTestCase {
    private func row(_ descr: String, merchant: String, category: String, _ debit: Double,
                     _ seq: Int) -> TxnRow {
        RouterFix.row("2026-06-\(String(format: "%02d", seq))", descr, merchant: merchant,
                      category: category, debit: debit, seq: seq)
    }

    // "TfL" must not swallow "neTFLix"; "Amazon" must not pull in "Amazon Prime";
    // "Tesco" must not include "Tesco Express".
    func testMerchantNotMatchedAsSubstringOfAnother() {
        let rows = [
            row("TFL TRAVEL CHARGE", merchant: "TfL", category: "Transport", 10.00, 1),
            row("TFL TRAVEL CHARGE", merchant: "TfL", category: "Transport", 5.00, 2),
            row("NETFLIX.COM 4K UHD", merchant: "Netflix", category: "Subscriptions", 15.99, 3),
            row("AMAZON.CO.UK*2A4B", merchant: "Amazon", category: "Shopping", 40.00, 4),
            row("AMAZON PRIME*MSHIP", merchant: "Amazon Prime", category: "Subscriptions", 8.99, 5),
            row("TESCO STORES 1", merchant: "Tesco", category: "Groceries", 30.00, 6),
            row("TESCO EXPRESS 9", merchant: "Tesco Express", category: "Groceries", 12.00, 7),
        ]
        XCTAssertEqual(ask("how much did i spend at tfl", rows), "**You spent £15.00 at TfL** across 2 transactions.")
        XCTAssertEqual(ask("how much did i spend at amazon", rows), "**You spent £40.00 at Amazon** across 1 transaction.")
        XCTAssertEqual(ask("how much did i spend at tesco", rows), "**You spent £30.00 at Tesco** across 1 transaction.")
    }

    // A two-letter merchant ("EE") resolves and doesn't match "coffEE".
    func testShortMerchantNameResolves() {
        let rows = [
            row("EE LIMITED MOBILE", merchant: "EE", category: "Utilities", 32.00, 1),
            row("EE LIMITED MOBILE", merchant: "EE", category: "Utilities", 32.00, 2),
            row("COSTA COFFEE 88", merchant: "Costa", category: "Food & Dining", 4.25, 3),
        ]
        XCTAssertEqual(ask("how much did i spend at ee", rows), "**You spent £64.00 at EE** across 2 transactions.")
    }

    // "gym" is a Subscriptions synonym, but "Pure Gym" is a merchant — a merchant
    // question must resolve to the merchant total, not the Subscriptions category.
    func testCategorySynonymInMerchantNameDoesNotHijack() {
        let rows = [
            row("PURE GYM LTD", merchant: "Pure Gym", category: "Healthcare", 28.99, 1),
            row("PURE GYM LTD", merchant: "Pure Gym", category: "Healthcare", 28.99, 2),
            row("NETFLIX.COM", merchant: "Netflix", category: "Subscriptions", 15.99, 3),
        ]
        XCTAssertEqual(ask("how much did i spend at pure gym", rows), "**You spent £57.98 at Pure Gym** across 2 transactions.")
    }

    // "biggest / smallest Subscriptions charge" is a category superlative, NOT a
    // request for the recurring-cadence list.
    func testCategorySuperlativeNotRecurringList() {
        let rows = [
            row("NETFLIX.COM", merchant: "Netflix", category: "Subscriptions", 15.99, 1),
            row("DISNEY PLUS", merchant: "Disney Plus", category: "Subscriptions", 7.99, 2),
            row("OPENAI CHATGPT", merchant: "OpenAI", category: "Subscriptions", 20.00, 3),
        ]
        let biggest = answerOrFail("what's the biggest subscriptions charge", rows)
        XCTAssertTrue(biggest.contains("£20.00"), "expected the £20.00 max, got: \(biggest)")
        XCTAssertFalse(biggest.contains("Recurring charges"), "must not run the recurring detector")
        let smallest = answerOrFail("what's the smallest subscriptions charge", rows)
        XCTAssertTrue(smallest.contains("£7.99"), "expected the £7.99 min, got: \(smallest)")
    }
}

// MARK: - 6-month eval pass regressions

final class FinanceRouterSixMonthTests: XCTestCase {
    private func row(_ iso: String, merchant: String, category: String, _ debit: Double,
                     _ seq: Int) -> TxnRow {
        RouterFix.row(iso, "\(merchant) LONDON", merchant: merchant, category: category,
                      debit: debit, seq: seq)
    }

    // "May" with month-context ("in May") must apply even when the scoped set has
    // no May rows — answering £0, not silently dropping the month. (Bare "may" as
    // a modal verb stays guarded elsewhere.)
    func testNamedMayWithContextAppliesWhenEmpty() {
        let rows = [
            row("2026-01-28", merchant: "Cash Advance", category: "Cash", 150.00, 1),
            row("2026-06-11", merchant: "Udemy", category: "Education", 18.99, 2),
            row("2026-04-05", merchant: "Tesco", category: "Groceries", 40.00, 3),
        ]
        XCTAssertEqual(ask("how much did i spend on cash in may", rows),
                       "**You spent £0.00 on Cash in May** across 0 transactions.")
        XCTAssertEqual(ask("how much did i spend on education in may", rows),
                       "**You spent £0.00 on Education in May** across 0 transactions.")
    }

    // Flowery total phrasing must resolve to the total, not invent a £0 "merchant"
    // out of filler words like "across / whole".
    func testTotalPhrasingWithFillerWords() {
        let rows = [
            row("2026-01-10", merchant: "Tesco", category: "Groceries", 40.00, 1),
            row("2026-03-10", merchant: "Uber", category: "Transport", 12.00, 2),
        ]
        XCTAssertEqual(ask("how much did i spend across the whole 6 months", rows),
                       "**You spent £52.00** across 2 transactions.")
    }
}

// MARK: - Dense single-month eval regression (category combine precedence)

final class FinanceRouterCategoryCombineTests: XCTestCase {
    // "Food & Dining and Rent together" must combine the two CATEGORIES, not be
    // mis-read as merchants because the token "food" word-matches a "CO-OP FOOD"
    // description and "rent" matches "…LETTINGS RENT". Category combine wins.
    func testCategoryCombineBeatsMerchantTokenMatch() {
        let rows = [
            RouterFix.row("2026-03-02", "CO-OP FOOD LONDON", merchant: "Co-op",
                          category: "Food & Dining", debit: 14.50, seq: 1),
            RouterFix.row("2026-03-05", "PRET A MANGER LONDON", merchant: "Pret A Manger",
                          category: "Food & Dining", debit: 7.30, seq: 2),
            RouterFix.row("2026-03-16", "HIGHBURY LETTINGS RENT", merchant: "Highbury Lettings",
                          category: "Rent", debit: 1250.00, seq: 3),
        ]
        // Food & Dining £21.80 + Rent £1250.00 = £1271.80
        let a = answerOrFail("how much did i spend on food & dining and rent together", rows)
        XCTAssertTrue(a.contains("£1271.80"), "expected the two-category sum £1271.80, got: \(a)")
        XCTAssertTrue(a.contains("Food & Dining") && a.contains("Rent"),
                      "should name both categories, got: \(a)")
    }
}

// MARK: - Bank current-account regressions (balance / savings-merchant)

final class FinanceRouterBankAccountTests: XCTestCase {
    /// A merchant/payee literally named "Savings" must not trigger the net/savings
    /// calculation for ordinary per-merchant queries.
    private static let acct: [TxnRow] = [
        RouterFix.row("2026-01-25", "SALARY ACME LTD", merchant: "Acme Ltd", category: "Income",
                      credit: 3000.00, balance: 3000.00, seq: 1),
        RouterFix.row("2026-01-26", "TFR TO SAVINGS", merchant: "Savings", category: "Transfers",
                      debit: 500.00, balance: 2500.00, seq: 2),
        RouterFix.row("2026-02-26", "TFR TO SAVINGS", merchant: "Savings", category: "Transfers",
                      debit: 500.00, balance: 1800.00, seq: 3),
        RouterFix.row("2026-02-27", "TESCO", merchant: "Tesco", category: "Groceries",
                      debit: 200.00, balance: 1600.00, seq: 4),
    ]

    func testSavingsMerchantNotHijackedByNetHandler() {
        XCTAssertEqual(ask("what's the average charge at savings", Self.acct),
                       "**Your average transaction at Savings is £500.00** across 2 debits.")
        // Not the net handler — an ordinary transfer total (£1000, both scope labels ok).
        let transfer = answerOrFail("how much did i transfer to savings", Self.acct)
        XCTAssertTrue(transfer.contains("£1000.00") && !transfer.contains("Net"),
                      "expected a £1000.00 spend/transfer total, not a net calc; got: \(transfer)")
    }

    // Running-balance queries on a current account.
    func testBalanceAsOfDateOnCurrentAccount() {
        XCTAssertEqual(ask("what was my balance on 26 January 2026", Self.acct),
                       "**Your balance at the end of 26 Jan 2026 was £2500.00.**")
        XCTAssertEqual(ask("what is my latest balance", Self.acct),
                       "**Your latest balance is £1600.00.**")
    }
}

// MARK: - Amex / foreign-spend regression

final class FinanceRouterForeignSpendTests: XCTestCase {
    private static let card: [TxnRow] = [
        RouterFix.row("2026-02-15", "TFL TRAVEL CHARGE", merchant: "TfL", category: "Transport",
                      debit: 2.10, seq: 1),
        RouterFix.row("2026-03-01", "TEYA*LITLI DUBLINER FRA REYKJAVIK", merchant: "Litli Dubliner",
                      category: "Food & Dining", debit: 3.47, seq: 2),
        RouterFix.row("2026-02-24", "PAYMENT RECEIVED - THANK YOU", merchant: "", category: "Payments",
                      credit: 500.00, seq: 3),
    ]

    // Foreign / abroad / overseas spend needs geo-FX knowledge the rows don't
    // carry — the router must DEFER (nil), never invent a "£0 on Abroad" merchant.
    func testForeignSpendDefers() {
        for q in ["how much did i spend abroad", "how much did i spend overseas",
                  "how much did i spend in foreign currency", "what did i spend internationally"] {
            XCTAssertNil(ask(q, Self.card), "expected defer (nil) for: \(q)")
        }
    }

    // Ordinary card questions still answer (card-repayment total, spend).
    func testCardRepaymentAndSpendStillAnswer() {
        XCTAssertEqual(ask("how much did i spend in total", Self.card),
                       "**You spent £5.57** across 2 transactions.")
        let repay = answerOrFail("how much did i pay off my card", Self.card)
        XCTAssertTrue(repay.contains("£500.00"), "expected card-repayment total £500.00, got: \(repay)")
    }
}
