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
