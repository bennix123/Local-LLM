import XCTest
@testable import PennyTxnStore

/// Regression pins for the 2026-08-31 manual test session (exact phrasings).
/// Root causes fixed: universal-parser year inference on wrap-around periods,
/// page-furniture filter eating per-record structure (tags / bank footers),
/// router misroutes (net comparison, month superlatives, multi-month scope,
/// where-did-money-go), and the new AccountQuery gate (account dimension,
/// senders, self-transfers, timing template).
final class ManualBugs20260831Tests: XCTestCase {

    // MARK: - universal parser: Paytm-shaped mini fixture

    /// Descending (newest-first) record blocks over a period that opens AND
    /// closes in August one year apart — the exact wrap that used to stamp the
    /// closing-August rows with the OPENING year. Includes two-line tags, a
    /// wrapped bank footer, and a statement-marked self-transfer. 4 pages so
    /// the furniture filter is live.
    private func paytmishPages() -> [String] {
        let header = "Paytm UPI Statement\n27 Aug'25 - 26 Aug'26\n"
        let footerLine = "Page  of \n"
        // 12 records, one per month, newest first: Aug'26 back to Sep'25.
        // Amounts 12,11,...,1 (Aug'26 = 12 ... Sep'25 = 1).
        let months = ["Aug", "Jul", "Jun", "May", "Apr", "Mar",
                      "Feb", "Jan", "Dec", "Nov", "Oct", "Sep"]
        var blocks: [String] = []
        for (i, m) in months.enumerated() {
            let amt = 12 - i
            if m == "Feb" {
                // statement-marked self transfer with a destination account in
                // the description and the paying account in the footer
                blocks.append("""
                10 \(m)
                6:0\(i % 10) PM
                Transferred to Self, Canara Bank - 1441
                UPI ID: ******0865@ptyes
                on
                UPI Ref No: 29951070208\(i)
                Rs.\(amt).00
                Note: This payment is not included in the total money paid and money received calculations.
                Union Bank
                Of India - 49
                """)
            } else {
                blocks.append("""
                10 \(m)
                6:0\(i % 10) PM
                Paid to Merchant \(m)
                UPI ID: q9229940\(i)0@ybl
                on
                UPI Ref No: 62322215444\(i)
                 Tag:
                # \(i % 2 == 0 ? "Food" : "Groceries")
                \(i % 3 == 0 ? "Canara Bank \n- 41" : "Union Bank \nOf India - 49")
                - Rs.\(amt).00
                """)
            }
        }
        // total paid = 12+11+...+1 minus the Feb self-transfer (5) = 73
        let totals = "Total Money Paid: Rs.73.00\n"
        var pages: [String] = []
        for chunk in stride(from: 0, to: blocks.count, by: 3) {
            let body = blocks[chunk..<min(chunk + 3, blocks.count)].joined(separator: "\n")
            pages.append(header + (chunk == 0 ? totals : "") + body + "\n" + footerLine)
        }
        return pages
    }

    private func parseFixture() throws -> UniversalRecordIngest.Output {
        let out = UniversalRecordIngest.parse(pages: paytmishPages(),
                                              categories: try Categories(categoriesJSONPath: TestPaths.categoriesJSON.path))
        return try XCTUnwrap(out, "fixture must verify via printed totals")
    }

    func testWrapAroundYearsFollowDocumentOrder() throws {
        let out = try parseFixture()
        let byMonth = Dictionary(grouping: out.rows, by: \.month)
        // Closing August belongs to the LATER year, opening months to the earlier.
        XCTAssertNotNil(byMonth["2026-08"], "Aug rows at the top are August 2026")
        XCTAssertNotNil(byMonth["2025-09"], "Sep rows at the bottom are September 2025")
        XCTAssertNil(byMonth["2025-08"], "no rows may fall into the OPENING August")
        XCTAssertEqual(out.rows.map(\.txnDate).max()?.prefix(4), "2026")
    }

    func testTwoLineTagsBecomeCategoryHints() throws {
        let out = try parseFixture()
        let tagged = out.rows.filter { $0.rawCategory != nil }
        XCTAssertGreaterThanOrEqual(tagged.count, 8, "two-line ' Tag:' + '# Value' must be captured")
        XCTAssertTrue(tagged.allSatisfy { ["Food", "Groceries"].contains($0.rawCategory!) },
                      "tag values are clean words, got \(Set(tagged.compactMap(\.rawCategory)))")
    }

    func testBankFootersBecomePerRowAccounts() throws {
        let out = try parseFixture()
        let accounts = Set(out.rows.compactMap(\.account))
        XCTAssertTrue(accounts.contains("Union Bank Of India -49"), "wrapped footer must join: \(accounts)")
        XCTAssertTrue(accounts.contains("Canara Bank -41"), "\(accounts)")
        // The self-transfer row's account is the PAYING side (footer), never the
        // destination named in its description.
        let selfRow = try XCTUnwrap(out.rows.first(where: \.isSelfTransfer))
        XCTAssertEqual(selfRow.account, "Union Bank Of India -49")
    }

    func testStatementMarkedSelfTransferIsFlagged() throws {
        let out = try parseFixture()
        let selfRows = out.rows.filter(\.isSelfTransfer)
        XCTAssertEqual(selfRows.count, 1)
        XCTAssertTrue(selfRows[0].descr.contains("Transferred to Self"))
    }

    // MARK: - router pins (exact manual phrasings)

    private func row(_ seq: Int, date: String, descr: String, category: String = "Shopping",
                     debit: Double = 0, credit: Double = 0) -> TxnRow {
        let p = date.split(separator: "-")
        return TxnRow(txnDate: date, month: "\(p[0])-\(p[1])", year: Int(p[0])!, monthNo: Int(p[1])!,
                      day: Int(p[2])!, descr: descr, merchant: descr, category: category,
                      debit: debit, credit: credit, balance: nil, currency: "INR", seq: seq)
    }

    private var routerRows: [TxnRow] {
        [row(1, date: "2026-04-05", descr: "SALARY", category: "Income", credit: 3000),
         row(2, date: "2026-04-10", descr: "TESCO", category: "Groceries", debit: 100),
         row(3, date: "2026-05-10", descr: "ZARA", debit: 400),
         row(4, date: "2026-06-10", descr: "TESCO", category: "Groceries", debit: 250),
         row(5, date: "2026-08-09", descr: "UBER", category: "Transport", debit: 50)]
    }

    private func ask(_ q: String) -> String? {
        FinanceRouter.answer(q, rows: routerRows, currency: "INR",
                             money: { "₹" + String(format: "%.2f", $0) })
    }

    func testSpendMoreThanReceivedIsANetComparison() throws {
        let a = try XCTUnwrap(ask("Did I spend more than I received?"))
        XCTAssertTrue(a.contains("No — you spent ₹800.00 and received ₹3000.00"), a)
        XCTAssertTrue(a.contains("ahead"), a)
    }

    func testWhichMonthDidISpendTheMost() throws {
        let a = try XCTUnwrap(ask("Which month did I spend the most?"))
        XCTAssertTrue(a.contains("May 2026") && a.contains("highest-spending month"), a)
        XCTAssertTrue(a.contains("₹400.00"), a)
    }

    func testHighestAndLowestSpendingMonth() throws {
        let hi = try XCTUnwrap(ask("What was my highest-spending month?"))
        XCTAssertTrue(hi.contains("May 2026") && hi.contains("₹400.00"), hi)
        XCTAssertFalse(hi.contains("largest expense"), "must not answer a single transaction: \(hi)")
        let lo = try XCTUnwrap(ask("What was my lowest-spending month?"))
        XCTAssertTrue(lo.contains("August 2026") && lo.contains("₹50.00"), lo)
        XCTAssertFalse(lo.contains("smallest expense"), lo)
    }

    func testMayAndAugustCombinedScopesBothMonths() throws {
        let a = try XCTUnwrap(ask("How much did I spend in May and August combined?"))
        XCTAssertTrue(a.contains("₹450.00"), "400 + 50 across both months: \(a)")
        XCTAssertTrue(a.contains("May") && a.contains("August"), a)
    }

    func testWhereDidMostOfMyMoneyGoIsACategoryAnswer() throws {
        let a = try XCTUnwrap(ask("Where did most of my money go?"))
        XCTAssertTrue(a.contains("categor") || a.contains("Categor"), a)
        XCTAssertFalse(a.contains("top merchant"), a)
    }

    func testMonthComparisonHonoursCategoryScope() throws {
        // 2026-09-01 manual bug: "…on pharmacy?" returned the SAME totals as
        // the unscoped comparison (whole-ledger sums) while its receipts
        // correctly showed only the pharmacy rows.
        let rows = [row(1, date: "2026-08-05", descr: "MEDPLUS", category: "Pharmacy", debit: 100),
                    row(2, date: "2026-08-09", descr: "UBER", category: "Transport", debit: 500),
                    row(3, date: "2026-09-03", descr: "MEDPLUS", category: "Pharmacy", debit: 250),
                    row(4, date: "2026-09-10", descr: "ZARA", category: "Shopping", debit: 900)]
        let money: (Double) -> String = { "₹" + String(format: "%.2f", $0) }
        let scoped = try XCTUnwrap(FinanceRouter.answer(
            "between august and september which month did i spend more on pharmacy?",
            rows: rows, currency: "INR", money: money))
        XCTAssertTrue(scoped.contains("on Pharmacy") && scoped.contains("September")
                        && scoped.contains("₹250.00") && scoped.contains("₹100.00"), scoped)
        XCTAssertFalse(scoped.contains("₹600.00") || scoped.contains("₹1150.00"),
                       "whole-ledger totals must not leak in: \(scoped)")
        let unscoped = try XCTUnwrap(FinanceRouter.answer(
            "between august and september which month did i spend more?",
            rows: rows, currency: "INR", money: money))
        XCTAssertTrue(unscoped.contains("₹600.00") && unscoped.contains("₹1150.00"), unscoped)
    }

    func testWhichMonthSpentMoreOnCategoryIsAScopedSuperlative() throws {
        // 2026-09-01 manual bug: with no months named, "which month did I
        // spend MORE on pharmacy?" fell to the plain category total.
        let rows = [row(1, date: "2026-08-05", descr: "MEDPLUS", category: "Pharmacy", debit: 100),
                    row(2, date: "2026-08-09", descr: "UBER", category: "Transport", debit: 500),
                    row(3, date: "2026-09-03", descr: "MEDPLUS", category: "Pharmacy", debit: 250)]
        let a = try XCTUnwrap(FinanceRouter.answer(
            "which month did I spend more on pharmacy?",
            rows: rows, currency: "INR", money: { "₹" + String(format: "%.2f", $0) }))
        XCTAssertTrue(a.contains("September 2026") && a.contains("highest-spending month")
                        && a.contains("Pharmacy") && a.contains("₹250.00"), a)
        XCTAssertFalse(a.contains("across 3 transactions"), "must not be the category total: \(a)")
    }

    // The FAMILY the dimension-superlative resolver owns — every combination
    // of dimension × direction × superlative/comparative answers the same
    // group-by, so no new phrasing can fall into a total handler again.
    func testDimensionSuperlativeFamily() throws {
        var rows = [row(1, date: "2026-04-05", descr: "SALARY", category: "Income", credit: 3000),
                    row(2, date: "2026-04-10", descr: "TESCO", category: "Groceries", debit: 100),
                    row(3, date: "2026-05-10", descr: "ZARA", debit: 400),
                    row(4, date: "2026-05-12", descr: "REFUND", category: "Income", credit: 50),
                    row(5, date: "2025-06-10", descr: "OLDYEAR", debit: 900),
                    row(6, date: "2026-08-09", descr: "UBER", category: "Transport", debit: 50)]
        rows[1].account = "Union Bank Of India -49"
        rows[2].account = "Canara Bank -41"
        rows[4].account = "Union Bank Of India -49"
        rows[5].account = "Union Bank Of India -49"
        let money: (Double) -> String = { "₹" + String(format: "%.2f", $0) }
        func ask(_ q: String) -> String? {
            FinanceRouter.answer(q, rows: rows, currency: "INR", money: money)
        }
        // comparative == superlative, spend side
        let a = try XCTUnwrap(ask("which month did I spend more?"))
        XCTAssertTrue(a.contains("May 2026") && a.contains("highest-spending month"), a)
        // receive side
        let b = try XCTUnwrap(ask("which month did I receive the most money?"))
        XCTAssertTrue(b.contains("April 2026") && b.contains("highest-income month") && b.contains("₹3000.00"), b)
        // year dimension
        let c = try XCTUnwrap(ask("which year did I spend the most?"))
        XCTAssertTrue(c.contains("2025") && c.contains("highest-spending year") && c.contains("₹900.00"), c)
        // account dimension (per-row accounts from the parser)
        let d = try XCTUnwrap(ask("which bank did I pay the most from?"))
        XCTAssertTrue(d.contains("Union Bank Of India -49") && d.contains("₹1050.00")
                        && d.contains("3 payments"), d)
        // account dimension without account data → honest, not a misroute
        let plain = [row(1, date: "2026-04-10", descr: "TESCO", category: "Groceries", debit: 100),
                     row(2, date: "2026-05-10", descr: "ZARA", debit: 400)]
        let e = try XCTUnwrap(FinanceRouter.answer("which account did I spend the most from?",
                                                   rows: plain, currency: "INR", money: money))
        XCTAssertTrue(e.contains("doesn't say which of your accounts"), e)
        // named months still belong to the month-vs-month comparer
        let f = try XCTUnwrap(ask("did I spend more in april or may?"))
        XCTAssertTrue(f.contains("vs"), f)
    }

    func testWhereSpentLeastFamily() throws {
        // 2026-09-01 manual bug (exact phrasing, typo included): answered with
        // the whole-ledger spend total. Category/merchant are dimensions of
        // the same superlative family.
        let rows = [row(1, date: "2026-04-10", descr: "TESCO", category: "Groceries", debit: 100),
                    row(2, date: "2026-05-10", descr: "ZARA", category: "Shopping", debit: 400),
                    row(3, date: "2026-08-09", descr: "UBER", category: "Transport", debit: 50)]
        func ask(_ q: String) -> String? {
            FinanceRouter.answer(q, rows: rows, currency: "INR",
                                 money: { "₹" + String(format: "%.2f", $0) })
        }
        let a = try XCTUnwrap(ask("where did i spent my least amount in?"))
        XCTAssertTrue(a.contains("least") && a.contains("Transport") && a.contains("₹50.00"), a)
        XCTAssertFalse(a.contains("₹550.00"), "must not be the whole-ledger total: \(a)")
        let b = try XCTUnwrap(ask("which category did I spend the least on?"))
        XCTAssertTrue(b.contains("Transport") && b.contains("₹50.00"), b)
        let c = try XCTUnwrap(ask("where did I spend the least at?"))
        XCTAssertTrue(c.contains("UBER") && c.contains("₹50.00"), c)
        let d = try XCTUnwrap(ask("who did I pay the most?"))
        XCTAssertTrue(d.contains("ZARA") && d.contains("₹400.00"), d)
        // The dedicated handlers keep their claims:
        let e = try XCTUnwrap(ask("where did most of my money go?"))
        XCTAssertTrue(e.contains("categor") || e.contains("Categor"), e)
        let f = try XCTUnwrap(ask("what's my top merchant?"))
        XCTAssertTrue(f.contains("top merchant"), f)
    }

    func testCategoryComparisonToleratesTypos() throws {
        // 2026-09-01 manual bug (exact phrasing): "gorceries" resolved no rows
        // (transposition typo + sides only searched descriptions), so the
        // comparison collapsed into a one-sided Retail total.
        let rows = [row(1, date: "2026-05-02", descr: "BIG BAZAAR", category: "Retail", debit: 3400),
                    row(2, date: "2026-05-05", descr: "DMART", category: "Groceries", debit: 1200),
                    row(3, date: "2026-05-09", descr: "DMART", category: "Groceries", debit: 800)]
        let money: (Double) -> String = { "₹" + String(format: "%.2f", $0) }
        let a = try XCTUnwrap(FinanceRouter.answer("did i spend more on gorceries or retail?",
                                                   rows: rows, currency: "INR", money: money))
        XCTAssertTrue(a.contains("₹3400.00") && a.contains("₹2000.00"),
                      "both sides must be compared: \(a)")
        // Typo'd single-category scope resolves too (general matchCategory fix).
        let b = try XCTUnwrap(FinanceRouter.answer("how much did I spend on gorceries?",
                                                   rows: rows, currency: "INR", money: money))
        XCTAssertTrue(b.contains("₹2000.00") && b.contains("Groceries"), b)
        // A genuinely absent side stays honest.
        let c = try XCTUnwrap(FinanceRouter.answer("did i spend more on dracula or retail?",
                                                   rows: rows, currency: "INR", money: money))
        XCTAssertTrue(c.lowercased().contains("dracula")
                        && c.contains("couldn't find any transactions matching"), c)
    }

    func testLargestExpenseStillWorks() throws {
        let a = try XCTUnwrap(ask("What was my largest expense?"))
        XCTAssertTrue(a.contains("largest expense") && a.contains("₹400.00"), a)
    }

    // MARK: - AccountQuery gate (exact manual phrasings)

    private var acctRows: [TxnRow] {
        var rows = [row(1, date: "2026-05-02", descr: "Paid to Shop A", debit: 120),
                    row(2, date: "2026-05-04", descr: "Paid to Shop B", debit: 80),
                    row(3, date: "2026-05-08", descr: "Received from Subbireddy K UPI ID: x@ybl",
                        category: "Income", credit: 100),
                    row(4, date: "2026-05-09", descr: "Money added to UPI Lite", credit: 70),
                    row(5, date: "2026-05-11", descr: "Transferred to Self, Canara Bank - 1441", credit: 200)]
        rows[0].account = "Union Bank Of India -49"
        rows[1].account = "Canara Bank -41"
        rows[2].account = "Union Bank Of India -49"
        rows[3].account = "Union Bank Of India -49"; rows[3].isSelfTransfer = true
        rows[4].account = "Union Bank Of India -49"; rows[4].isSelfTransfer = true
        return rows
    }

    private func gate(_ q: String) -> String? {
        AccountQuery.answer(q, rows: acctRows, money: { "₹" + String(format: "%.2f", $0) })
    }

    func testHowMuchDidIPayFromUnionBank() throws {
        let a = try XCTUnwrap(gate("How much did I pay from Union Bank?"))
        XCTAssertTrue(a.contains("₹120.00") && a.contains("Union Bank Of India -49"), a)
        XCTAssertFalse(a.contains("Canara"), a)
    }

    func testHowManyPaymentsFromUnionBank() throws {
        let a = try XCTUnwrap(gate("How many payments did I make from Union Bank?"))
        XCTAssertTrue(a.contains("1 payment") && a.contains("Union Bank Of India -49"), a)
    }

    func testReceiveIntoAccountsCountsCreditsNotSelfTransfers() throws {
        let a = try XCTUnwrap(gate("How much did I receive into Union Bank?"))
        XCTAssertTrue(a.contains("₹100.00"), "self-transfer credits must not count: \(a)")
        let b = try XCTUnwrap(gate("How much did I receive into Canara Bank?"))
        XCTAssertTrue(b.contains("Nothing came into Canara Bank -41"), b)
    }

    func testWhoSentMeMoney() throws {
        let a = try XCTUnwrap(gate("Who sent me money?"))
        XCTAssertTrue(a.contains("Subbireddy K") && a.contains("₹100.00"), a)
        XCTAssertFalse(a.contains("UPI Lite"), "self transfers aren't senders: \(a)")
    }

    func testSelfTransferQuestions() throws {
        let a = try XCTUnwrap(gate("Did I transfer money between my own bank accounts?"))
        XCTAssertTrue(a.contains("Yes — 2 transfers"), a)
        let b = try XCTUnwrap(gate("Did I transfer money to UPI Lite?"))
        XCTAssertTrue(b.contains("Yes — 1 transfer") && b.contains("UPI Lite"), b)
    }

    func testTimingQuestionGetsADateAnswer() {
        XCTAssertTrue(AccountQuery.isTimingQuestion("When did Subbireddy K send me money?"))
        XCTAssertFalse(AccountQuery.isTimingQuestion("How much did I receive from Subbireddy K?"))
        let matched = acctRows.filter { $0.descr.contains("Subbireddy") }
        let a = AccountQuery.timingAnswer(matched: matched, label: "at Subbireddy · money in",
                                          money: { "₹" + String(format: "%.2f", $0) })
        XCTAssertTrue(a.contains("On 8th May 2026") && a.contains("came in"), a)
    }
}
