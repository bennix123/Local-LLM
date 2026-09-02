//
//  AppModelLogicTests.swift
//  PennyTests
//
//  Guards AppModel's deterministic app-layer logic (AppModel.swift): the Today-
//  panel sums in recomputeSummary (debits = spent, "Payments" credits excluded
//  from income, multi-account balances with credit-card balances subtracted,
//  currency preference order, the per-currency Summary.perCurrency breakdown
//  with AppModel.effectiveCurrency grouping), LoadedDoc's latestBalance and sidebar displayName
//  chain (LLM issuer > earliest-brand text heuristic > bank-like parser name >
//  filename), the keyword category fallback, the capped/escaped transactions
//  markdown table, chat-history archiving (newChat / openSession / deleteSession
//  with the PENNY_UITEST temp-file redirect), and send()'s deterministic routing
//  (LEDGER table answers and ANALYTICS FinanceRouter answers). The open-ended
//  MLX path is intentionally NOT exercised: without --uitest-model-ready the
//  stub is off and send() would touch the real model.
//

import XCTest
import SwiftUI
import PennyCore
import PennyTxnStore
@testable import Penny

@MainActor
final class AppModelLogicTests: XCTestCase {

    // MARK: - fixtures

    private func txn(date: String = "2024-01-05", desc: String = "TESCO STORES",
                     debit: Double? = nil, credit: Double? = nil,
                     balance: Double? = nil, category: String? = nil) -> PennyCore.Transaction {
        PennyCore.Transaction(date: date, description: desc, debit: debit, credit: credit,
                              balance: balance, category: category)
    }

    private func row(_ seq: Int, date: String = "2024-01-05", desc: String = "TESCO STORES",
                     category: String = "Groceries", debit: Double = 0, credit: Double = 0,
                     balance: Double? = nil, currency: String = "GBP") -> TxnRow {
        TxnRow(txnDate: date, month: String(date.prefix(7)),
               year: Int(date.prefix(4)) ?? 2024,
               monthNo: Int(date.dropFirst(5).prefix(2)) ?? 1,
               day: Int(date.suffix(2)) ?? 1,
               descr: desc, merchant: desc, category: category,
               debit: debit, credit: credit, balance: balance,
               currency: currency, seq: seq)
    }

    private func makeDoc(name: String, text: String = "statement text",
                         txns: [PennyCore.Transaction] = [], rows: [TxnRow] = [],
                         currency: String = "INR", bank: String? = nil,
                         detectedIssuer: String? = nil, closingBalance: Double? = nil,
                         isCard: Bool = false) -> LoadedDoc {
        LoadedDoc(name: name, text: text, transactions: txns, rows: rows,
                  currency: currency, bank: bank, detectedIssuer: detectedIssuer,
                  closingBalance: closingBalance, isCard: isCard, analyzed: true)
    }

    /// AppModel writes chat history here when TestMode is active (PENNY_UITEST=1
    /// in the scheme's test environment) — per-process, under NSTemporaryDirectory().
    private var historyFileURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("penny-uitest-history-\(ProcessInfo.processInfo.processIdentifier).json")
    }

    /// A model with no leftover history from earlier tests in this process.
    /// The launch-restore task is cancelled so statements persisted by OTHER
    /// tests (PersistenceTests/StressTests share the per-process temp dir)
    /// can never appear in these hand-built doc sets mid-test.
    private func freshModel() -> AppModel {
        try? FileManager.default.removeItem(at: historyFileURL)
        let m = AppModel()
        m.restoreTask?.cancel()
        m.history = []
        return m
    }

    private func mdTable(_ block: MD.Block?,
                         file: StaticString = #filePath, line: UInt = #line)
        -> (headers: [String], rows: [[String]], aligns: [TextAlignment])? {
        if case .table(let h, let r, let a)? = block { return (h, r, a) }
        XCTFail("expected a markdown table block, got \(String(describing: block))",
                file: file, line: line)
        return nil
    }

    // MARK: - recomputeSummary

    func testSummarySpentIncomeNetAndPaymentsExclusion() {
        let m = freshModel()
        m.loadForTesting([makeDoc(name: "bank.pdf", txns: [
            txn(desc: "TESCO GROCERY", debit: 100, category: "Groceries"),
            txn(desc: "AMAZON MARKETPLACE", debit: 49.5),                 // nil category → keyword fallback
            txn(desc: "ACME PAYROLL", credit: 500, category: "Income"),
            txn(desc: "CARD PAYMENT RECEIVED", credit: 200, category: "Payments"),
        ], currency: "GBP")])
        m.recomputeSummary()

        XCTAssertEqual(m.summary.spent, 149.5, accuracy: 0.001, "spent = sum of debits")
        XCTAssertEqual(m.summary.income, 500, accuracy: 0.001,
                       "'Payments' credits are card repayments, never income")
        XCTAssertEqual(m.summary.net, 350.5, accuracy: 0.001, "net = income − spent")
        XCTAssertEqual(m.summary.count, 4)
        XCTAssertEqual(m.summary.currency, "GBP")
        XCTAssertNil(m.summary.balance, "no row balance and no closing balance → nil, not 0")
        XCTAssertEqual(m.summary.categories.map(\.name), ["Groceries", "Shopping"],
                       "debits grouped by category, sorted desc; nil category uses the keyword heuristic")
        XCTAssertEqual(m.summary.categories.first?.amount ?? -1, 100, accuracy: 0.001)
    }

    func testSummaryMultiDocBalanceSubtractsCreditCards() {
        let m = freshModel()
        let bank = makeDoc(name: "bank.pdf",
                           txns: [txn(debit: 20, balance: 800), txn(credit: 220, balance: 1000)],
                           currency: "GBP")
        let card = makeDoc(name: "card.pdf",
                           txns: [txn(desc: "COFFEE SHOP", debit: 250)],
                           currency: "GBP", closingBalance: 250, isCard: true)
        m.loadForTesting([bank, card])
        m.recomputeSummary()
        XCTAssertEqual(m.summary.balance ?? .nan, 750, accuracy: 0.001,
                       "bank 1000 minus card 250 owed = 750")
        XCTAssertEqual(m.summary.count, 3)
    }

    func testSummaryBalanceNilWhenNoDocHasOne() {
        let m = freshModel()
        m.loadForTesting([makeDoc(name: "a.pdf", txns: [txn(debit: 5)]),
                  makeDoc(name: "b.pdf", txns: [txn(credit: 9)])])
        m.recomputeSummary()
        XCTAssertNil(m.summary.balance,
                     "docs without any latestBalance must yield nil (dash in UI), not 0")
    }

    func testSummaryScopedToSelectedDocs() {
        let m = freshModel()
        m.loadForTesting([makeDoc(name: "a.pdf", txns: [txn(debit: 10)], currency: "GBP"),
                  makeDoc(name: "b.pdf", txns: [txn(debit: 90)], currency: "GBP")])
        m.selectedDocNames = ["a.pdf"]
        m.recomputeSummary()
        XCTAssertEqual(m.summary.spent, 10, accuracy: 0.001, "only the selected doc counts")
        XCTAssertEqual(m.summary.count, 1)

        m.selectedDocNames = []
        m.recomputeSummary()
        XCTAssertEqual(m.summary.spent, 100, accuracy: 0.001,
                       "empty selection means ALL docs")
        XCTAssertEqual(m.summary.count, 2)
    }

    // MARK: - per-currency breakdown (Summary.perCurrency)

    func testPerCurrencySingleCurrencyMatchesTopLevelFigures() {
        let m = freshModel()
        m.loadForTesting([makeDoc(name: "bank.pdf", txns: [
            txn(desc: "TESCO", debit: 100, balance: 900, category: "Groceries"),
            txn(desc: "PAYROLL", credit: 500, category: "Income"),
        ], currency: "GBP")])
        m.recomputeSummary()

        XCTAssertFalse(m.summary.isMultiCurrency)
        XCTAssertEqual(m.summary.currencyList, ["GBP"])
        let t = m.summary.perCurrency["GBP"]
        XCTAssertEqual(t?.spent ?? -1, m.summary.spent, accuracy: 0.001)
        XCTAssertEqual(t?.income ?? -1, m.summary.income, accuracy: 0.001)
        XCTAssertEqual(t?.net ?? -1, m.summary.net, accuracy: 0.001)
        XCTAssertEqual(t?.balance ?? .nan, m.summary.balance ?? .nan, accuracy: 0.001)
        XCTAssertEqual(t?.count, m.summary.count)
    }

    func testPerCurrencyMultiCurrencySplitsFigures() {
        let m = freshModel()
        let gbp = makeDoc(name: "uk.pdf",
                          txns: [txn(debit: 100, balance: 900), txn(credit: 50)],
                          currency: "GBP")
        let eur = makeDoc(name: "de.pdf",
                          txns: [txn(debit: 40, balance: 460)],
                          currency: "EUR")
        m.loadForTesting([gbp, eur])
        m.recomputeSummary()

        XCTAssertTrue(m.summary.isMultiCurrency)
        XCTAssertEqual(m.summary.currencyList, ["EUR", "GBP"], "sorted, deterministic order")
        XCTAssertEqual(m.summary.perCurrency["GBP"]?.spent ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(m.summary.perCurrency["GBP"]?.income ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(m.summary.perCurrency["GBP"]?.net ?? -1, -50, accuracy: 0.001)
        XCTAssertEqual(m.summary.perCurrency["GBP"]?.balance ?? .nan, 900, accuracy: 0.001)
        XCTAssertEqual(m.summary.perCurrency["EUR"]?.spent ?? -1, 40, accuracy: 0.001)
        XCTAssertEqual(m.summary.perCurrency["EUR"]?.balance ?? .nan, 460, accuracy: 0.001)
        // the top-level (legacy) figures still sum everything — single-currency
        // callers see no change, multi-currency UI reads perCurrency instead
        XCTAssertEqual(m.summary.spent, 140, accuracy: 0.001)
    }

    func testPerCurrencyCardBalancesSubtractWithinTheirCurrency() {
        let m = freshModel()
        m.loadForTesting([
            makeDoc(name: "bank.pdf", txns: [txn(credit: 10, balance: 1000)], currency: "GBP"),
            makeDoc(name: "card.pdf", txns: [txn(debit: 250)], currency: "GBP",
                    closingBalance: 250, isCard: true),
            makeDoc(name: "de.pdf", txns: [txn(debit: 5, balance: 500)], currency: "EUR"),
        ])
        m.recomputeSummary()
        XCTAssertEqual(m.summary.perCurrency["GBP"]?.balance ?? .nan, 750, accuracy: 0.001,
                       "GBP bank 1000 − GBP card 250 owed, EUR untouched")
        XCTAssertEqual(m.summary.perCurrency["EUR"]?.balance ?? .nan, 500, accuracy: 0.001)
    }

    func testEffectiveCurrencySniffsDocTextWhenParserFellBack() {
        // Parser fell back to INR but the text is clearly GBP — the per-doc
        // grouping must follow the same sniff order detectCurrency() uses.
        let sniffed = makeDoc(name: "a.pdf", text: "Opening balance £1,022.10", currency: "INR")
        XCTAssertEqual(AppModel.effectiveCurrency(of: sniffed), "GBP")
        let parserWins = makeDoc(name: "b.pdf", text: "£100 spent", currency: "USD")
        XCTAssertEqual(AppModel.effectiveCurrency(of: parserWins), "USD",
                       "a parser-detected non-INR currency is authoritative")
        let inr = makeDoc(name: "c.pdf", text: "no symbols here", currency: "INR")
        XCTAssertEqual(AppModel.effectiveCurrency(of: inr), "INR")

        let m = freshModel()
        m.loadForTesting([sniffed, makeDoc(name: "d.pdf", txns: [txn(debit: 1)], currency: "EUR")])
        m.recomputeSummary()
        XCTAssertEqual(m.summary.currencyList, ["EUR", "GBP"])
    }

    // MARK: - currency preference order

    func testCurrencyParserDetectedNonINRWins() {
        let m = freshModel()
        // Parser said USD for doc 2 — that beats any symbol sniffing, even though
        // the text is full of £. Empty-string currencies are skipped.
        m.loadForTesting([makeDoc(name: "a.pdf", text: "£ £ £", currency: ""),
                  makeDoc(name: "b.pdf", text: "£100 spent", currency: "USD")])
        m.recomputeSummary()
        XCTAssertEqual(m.summary.currency, "USD",
                       "first parser-detected non-INR, non-empty currency is authoritative")
    }

    func testCurrencySniffedFromTextWhenParserSaysINR() {
        let m = freshModel()
        m.loadForTesting([makeDoc(name: "a.pdf", text: "Opening balance £1,022.10", currency: "INR")])
        m.recomputeSummary()
        XCTAssertEqual(m.summary.currency, "GBP", "£ in the text → GBP when parser fell back to INR")

        m.loadForTesting([makeDoc(name: "b.pdf", text: "Charge of €10 then a fee of $5", currency: "INR")])
        m.recomputeSummary()
        XCTAssertEqual(m.summary.currency, "EUR", "sniff order prefers € over $")

        m.loadForTesting([makeDoc(name: "c.pdf", text: "INR 500 credited, card charge $12", currency: "INR")])
        m.recomputeSummary()
        XCTAssertEqual(m.summary.currency, "INR", "explicit INR text outranks $")
    }

    func testCurrencyFallsBackToParserValue() {
        let m = freshModel()
        m.loadForTesting([makeDoc(name: "a.pdf", text: "no symbols here at all", currency: "INR")])
        m.recomputeSummary()
        XCTAssertEqual(m.summary.currency, "INR")
    }

    // MARK: - LoadedDoc.latestBalance

    func testLatestBalancePrefersLastRowWithBalance() {
        let d = makeDoc(name: "x.pdf",
                        txns: [txn(balance: 100), txn(), txn(balance: 300), txn()],
                        closingBalance: 999)
        XCTAssertEqual(d.latestBalance ?? .nan, 300, accuracy: 0.001,
                       "last row WITH a balance wins; closingBalance is only a fallback")
    }

    func testLatestBalanceFallsBackToClosingBalance() {
        let d = makeDoc(name: "x.pdf", txns: [txn(), txn()], closingBalance: 500)
        XCTAssertEqual(d.latestBalance ?? .nan, 500, accuracy: 0.001)
    }

    func testLatestBalanceNilWhenNeitherExists() {
        XCTAssertNil(makeDoc(name: "x.pdf", txns: [txn()]).latestBalance)
    }

    // MARK: - LoadedDoc.displayName priority chain

    func testDisplayNamePriorityChain() {
        // 1. LLM-detected issuer beats everything
        XCTAssertEqual(makeDoc(name: "f.pdf", text: "Nationwide Building Society",
                               bank: "HDFC Bank", detectedIssuer: "Chase").displayName,
                       "Chase")
        // 2. text-heuristic issuer beats parser bank name
        XCTAssertEqual(makeDoc(name: "f.pdf", text: "Nationwide Building Society\nStatement",
                               bank: "Sample").displayName,
                       "Nationwide")
        // 3. parser bank name used only when it reads like a bank
        XCTAssertEqual(makeDoc(name: "f.pdf", text: "no brands here",
                               bank: "HDFC Bank").displayName,
                       "HDFC Bank")
        // 4. non-bank-like parser name (filename-derived junk) → cleaned
        // filename, never the raw technical name (2026-08-29 request)
        XCTAssertEqual(makeDoc(name: "Sample_Statement_acct.pdf", text: "no brands here",
                               bank: "Sample").displayName,
                       "Sample")
        // 5. no bank at all → cleaned filename, no extension
        XCTAssertEqual(makeDoc(name: "plain.pdf", text: "no brands here").displayName,
                       "Plain")
    }

    func testDetectIssuerEarliestBrandWins() {
        // The Nationwide letterhead sits at the top; a MONZO transfer line lower
        // down (still inside the 1500-char head) must NOT steal the label.
        let text = "Nationwide Building Society\nAccount statement\n"
            + String(repeating: "filler ", count: 80)
            + "\n03 Apr Transfer from MONZO A/C 12.00"
        XCTAssertEqual(LoadedDoc.detectIssuer(in: text), "Nationwide")

        // Earliest by position in the TEXT, not by position in the brand table
        // (HSBC precedes Halifax in the table).
        let halifaxFirst = "Halifax plc statement of account\nqueries: contact HSBC helpline"
        XCTAssertEqual(LoadedDoc.detectIssuer(in: halifaxFirst), "Halifax")
    }

    func testDetectIssuerOnlyScansFirst1500Chars() {
        let near = String(repeating: "x", count: 1000) + " Monzo Bank"
        XCTAssertEqual(LoadedDoc.detectIssuer(in: near), "Monzo", "brand inside the head window is found")
        let far = String(repeating: "x", count: 1600) + " Monzo Bank"
        XCTAssertNil(LoadedDoc.detectIssuer(in: far), "brand past 1500 chars must be ignored")
    }

    func testDetectIssuerWordBoundariesAndAliases() {
        XCTAssertNil(LoadedDoc.detectIssuer(in: "Purchases this month were high"),
                     "'chase' inside 'Purchases' must not match")
        XCTAssertEqual(LoadedDoc.detectIssuer(in: "AMEX Platinum Card"), "American Express")
        XCTAssertEqual(LoadedDoc.detectIssuer(in: "National Westminster Bank Plc"), "NatWest")
        XCTAssertNil(LoadedDoc.detectIssuer(in: "Interbank transfers summary"))
    }

    func testDetectIssuerIndianBanksAndPaytmLetterhead() {
        // A real Paytm Payments Bank statement: PPBL letterhead up top, and an
        // Axis IFSC ("UTIB…") + "@sliceaxis" handle down in the transactions. It
        // must read as Paytm — never "Axis Bank" from the transaction noise.
        let paytm = """
            PPBL Noida branch, Skymark One, Sector-98, Noida
            Account statement for: 06 Jan 2023 to 01 Mar 2023
            UPI/quadrillion@sliceaxis/UTIB0000100/transfer 12.00
            """
        XCTAssertEqual(LoadedDoc.detectIssuer(in: paytm), "Paytm Payments Bank")

        XCTAssertEqual(LoadedDoc.detectIssuer(in: "Axis Bank Ltd\nStatement of account"), "Axis Bank")
        XCTAssertEqual(LoadedDoc.detectIssuer(in: "HDFC Bank statement"), "HDFC Bank")
        // A bare Axis IFSC / VPA with no "Axis Bank" letterhead must NOT match.
        XCTAssertNil(LoadedDoc.detectIssuer(in: "UPI to name@sliceaxis via UTIB0000100"))
    }

    func testLooksLikeBankName() {
        for good in ["HDFC Bank", "Nationwide Building Society", "First Credit Union",
                     "Coastal Banking Group", "Acme Financial"] {
            XCTAssertTrue(LoadedDoc.looksLikeBankName(good), "'\(good)' should look like a bank")
        }
        for bad in ["Sample", "American Express", "Monzo", "Bankrupt Holdings", "Statement"] {
            XCTAssertFalse(LoadedDoc.looksLikeBankName(bad), "'\(bad)' should NOT look like a bank")
        }
    }

    // MARK: - categoryName keyword fallback

    func testCategoryNameKeywords() {
        let cases: [(String, String)] = [
            ("WM MORRISONS GROCERY", "Groceries"),
            ("Starbucks Coffee #123", "Food & Dining"),
            ("UBER *TRIP", "Transport"),
            ("ELECTRICITY BOARD", "Bills & Utilities"),
            ("AMAZON RETAIL", "Shopping"),
            ("ATM WDL 1234", "Cash & ATM"),
            ("NEFT-AXIS-000123", "Transfers"),
            ("random merchant xyz", "Other"),
        ]
        for (desc, expected) in cases {
            XCTAssertEqual(AppModel.categoryName(desc), expected, "for '\(desc)'")
        }
    }

    func testCategoryNamePrecedence() {
        XCTAssertEqual(AppModel.categoryName("food store"), "Food & Dining",
                       "'food' outranks 'store'")
        XCTAssertEqual(AppModel.categoryName("cash transfer"), "Cash & ATM",
                       "'cash' outranks 'transfer'")
        XCTAssertEqual(AppModel.categoryName("Gas station fuel"), "Transport",
                       "'fuel' outranks 'gas'")
    }

    // MARK: - transactionsMarkdown

    func testTransactionsMarkdownCapsAt200WithFooter() {
        let many = (1...205).map { txn(date: "2024-01-01", desc: "Txn \($0)", debit: Double($0)) }
        let md = AppModel.transactionsMarkdown(many, currency: "GBP")
        XCTAssertTrue(md.contains("_Showing first 200 of 205."),
                      "cap footer missing or wrong; got tail: …\(md.suffix(60))")
        XCTAssertTrue(md.hasSuffix("_"), "footer must be an italic paragraph")

        let blocks = MD.parse(md)
        XCTAssertEqual(blocks.count, 2, "expected table + footer paragraph")
        guard let t = mdTable(blocks.first) else { return }
        XCTAssertEqual(t.headers, ["#", "Date", "Description", "Category", "Debit", "Credit", "Balance"])
        XCTAssertEqual(t.rows.count, 200, "body must stop at 200 rows")
        XCTAssertEqual(t.rows.last?.first, "200", "rows are 1-indexed and cut at #200")
        XCTAssertEqual(t.rows.last?[2], "Txn 200")

        let exact = AppModel.transactionsMarkdown(Array(many.prefix(200)), currency: "GBP")
        XCTAssertFalse(exact.contains("Showing first"), "exactly 200 rows needs no footer")
    }

    func testTransactionsMarkdownEscapesPipesTruncatesAndFormatsMoney() {
        let txns = [
            txn(date: "2024-01-05", desc: "TESCO", debit: 1234.5, balance: 2000),
            txn(date: "2024-01-06", desc: "COFFEE|SHOP|LTD", credit: 12),
            txn(date: "2024-01-07", desc: String(repeating: "D", count: 41), debit: 1),
            txn(date: "2024-01-08", desc: String(repeating: "E", count: 40), debit: 2),
        ]
        let md = AppModel.transactionsMarkdown(txns, currency: "GBP")

        // Exact full row: index, date, desc, category (empty here), debit, empty credit, balance.
        let lines = md.components(separatedBy: "\n")
        XCTAssertEqual(lines[2], "| 1 | 2024-01-05 | TESCO |  | £1,234.50 |  | £2,000.00 |")

        guard let t = mdTable(MD.parse(md).first) else { return }
        XCTAssertEqual(t.rows[1][2], "COFFEE/SHOP/LTD",
                       "pipes in descriptions must become slashes or they break the table")
        XCTAssertEqual(t.rows[2][2], String(repeating: "D", count: 39) + "…",
                       ">40-char description truncated to 39 chars + ellipsis")
        XCTAssertEqual(t.rows[3][2], String(repeating: "E", count: 40),
                       "exactly 40 chars is NOT truncated")
        XCTAssertEqual(t.aligns, [.trailing, .leading, .leading, .leading, .trailing, .trailing, .trailing],
                       "money/index columns right-align, date/description/category lead")
    }

    func testTransactionsMarkdownUsesIndianGroupingForINR() {
        let md = AppModel.transactionsMarkdown([txn(desc: "BIG SPEND", debit: 123456.78)],
                                               currency: "INR")
        guard let t = mdTable(MD.parse(md).first) else { return }
        XCTAssertEqual(t.rows[0][4], "₹1,23,456.78", "INR uses lakh/crore grouping (Debit is col 4 after Category)")
    }

    // MARK: - send() deterministic routing (LEDGER / ANALYTICS only — the
    // open-ended path would hit MLX because --uitest-model-ready is not set
    // for hosted tests, so it is deliberately not exercised here).

    private func modelWithThreeTxns() -> AppModel {
        let m = freshModel()
        m.loadForTesting([makeDoc(name: "bank.pdf",
                          txns: [txn(desc: "ALPHA", debit: 10),
                                 txn(desc: "BRAVO", debit: 20),
                                 txn(desc: "CHARLIE", credit: 5)],
                          rows: [row(1, desc: "ALPHA", debit: 10),
                                 row(2, desc: "BRAVO", debit: 20),
                                 row(3, desc: "CHARLIE", category: "Income", credit: 5)],
                          currency: "GBP")])
        m.recomputeSummary()
        return m
    }

    func testSendTableQuestionAppendsLedgerMessage() {
        let m = modelWithThreeTxns()
        m.send("  show me all transactions in a table \n")
        XCTAssertEqual(m.messages.count, 2, "user + LEDGER reply, nothing else")
        XCTAssertEqual(m.messages[0].role, .user)
        XCTAssertEqual(m.messages[0].content, "show me all transactions in a table",
                       "question is whitespace-trimmed before appending")
        let reply = m.messages[1]
        XCTAssertEqual(reply.engine, "LEDGER")
        XCTAssertTrue(reply.content.hasPrefix("Here are all 3 transactions on record:"),
                      "plural header wrong; got: \(reply.content.prefix(60))")
        let blocks = MD.parse(reply.content)
        XCTAssertEqual(blocks.count, 2, "header paragraph + table")
        XCTAssertEqual(mdTable(blocks.last)?.rows.count, 3, "table lists every extracted txn")
        XCTAssertFalse(m.isThinking, "deterministic route never enters the thinking state")

        // "ledger"/"full" phrasing routes the same way.
        m.send("show me the full ledger")
        XCTAssertEqual(m.messages.count, 4)
        XCTAssertEqual(m.messages[3].engine, "LEDGER")
    }

    func testSendSingularLedgerHeader() {
        let m = freshModel()
        m.loadForTesting([makeDoc(name: "one.pdf", txns: [txn(debit: 5)], rows: [row(1, debit: 5)],
                          currency: "GBP")])
        m.recomputeSummary()
        m.send("list all transactions")
        XCTAssertEqual(m.messages.last?.engine, "LEDGER")
        XCTAssertTrue(m.messages.last?.content.hasPrefix("Here is all 1 transaction on record:") == true,
                      "singular verb/noun expected; got: \(m.messages.last?.content.prefix(60) ?? "")")
    }

    func testSendCreditTableFiltersToCreditsOnly() {
        let m = modelWithThreeTxns()
        m.send("list my credit transactions")
        let reply = m.messages.last
        XCTAssertEqual(reply?.engine, "LEDGER")
        XCTAssertTrue(reply?.content.hasPrefix("Here is all 1 credit transaction on record:") == true,
                      "direction word + credit-only count expected; got: \(reply?.content.prefix(60) ?? "")")
        XCTAssertTrue(reply?.content.contains("CHARLIE") == true)
        XCTAssertFalse(reply?.content.contains("ALPHA") == true, "debit rows must be filtered out")
    }

    func testSendDebitTableFiltersToDebitsOnly() {
        let m = modelWithThreeTxns()
        m.send("show all debit transactions")
        let reply = m.messages.last
        XCTAssertEqual(reply?.engine, "LEDGER")
        XCTAssertTrue(reply?.content.hasPrefix("Here are all 2 debit transactions on record:") == true,
                      "got: \(reply?.content.prefix(60) ?? "")")
        XCTAssertTrue(reply?.content.contains("ALPHA") == true && reply?.content.contains("BRAVO") == true)
        XCTAssertFalse(reply?.content.contains("CHARLIE") == true, "credit row must be filtered out")
    }

    func testDirectWhichAccountForMerchantNamesTheStatement() {
        // Live (2026-08-28): "from which bank accounts did i make zara
        // transactions?" answered a keyword-search summary with the WRONG
        // currency symbol. The direct account-dimension form now groups the
        // scoped rows by statement.
        let m = modelWithTwoDocs()
        m.send("from which bank accounts did i make alpha transactions?")
        let reply = m.messages.last
        XCTAssertEqual(reply?.engine, "ANALYTICS")
        XCTAssertTrue(reply?.content.localizedCaseInsensitiveContains("chase") == true,
                      "\(reply?.content.prefix(100) ?? "")")
    }

    func testBareFromWhichAccountsFollowUp() {
        // Live: "from which accounts?" after a merchant answer went to the model
        // and hallucinated "the USD account". Resolves against receipts now.
        let m = modelWithThreeTxns()
        m.send("how much did i spend at alpha?")
        m.send("from which accounts?")
        let reply = m.messages.last
        XCTAssertEqual(reply?.engine, "ANALYTICS", "must not fall to a model")
        XCTAssertTrue(reply?.content.localizedCaseInsensitiveContains("bank") == true,
                      "\(reply?.content.prefix(100) ?? "")")
    }

    func testKeywordFallbackNeverBlendsCurrencies() {
        // Live: the fallback summed rupee rows and printed them with a £ symbol.
        let m = freshModel()
        m.loadForTesting([
            makeDoc(name: "us.csv", txns: [txn(desc: "ZED STORE", debit: 10)],
                    rows: [row(1, desc: "ZED STORE", debit: 10, currency: "USD")], currency: "USD"),
            makeDoc(name: "uk.csv", txns: [txn(desc: "ZED STORE", debit: 20)],
                    rows: [row(1, desc: "ZED STORE", debit: 20, currency: "GBP")], currency: "GBP"),
        ])
        m.recomputeSummary()
        m.send("anything about zed store?")
        let reply = m.messages.last?.content ?? ""
        XCTAssertTrue(reply.contains("$10.00") && reply.contains("£20.00"),
                      "per-currency sums with their own symbols: \(reply.prefix(140))")
        XCTAssertFalse(reply.contains("$30.00") || reply.contains("£30.00"),
                       "must never blend currencies into one figure: \(reply.prefix(140))")
    }

    func testThisTransactionFollowUpNamesTheAccount() {
        // Live session (2026-08-28): "from which account did i make this
        // transaction?" answered "hdfc has the most transactions: 273" — a count,
        // for a question about ONE specific transaction. Now resolved against the
        // previous answer's receipt rows.
        let m = modelWithThreeTxns()
        m.send("when was the last transaction of alpha?")
        XCTAssertEqual(m.messages.last?.engine, "ANALYTICS")
        m.send("from which account did i make this transaction?")
        let reply = m.messages.last
        XCTAssertEqual(reply?.engine, "ANALYTICS")
        XCTAssertTrue(reply?.content.localizedCaseInsensitiveContains("bank") == true,
                      "should name the statement: \(reply?.content.prefix(100) ?? "")")
        XCTAssertFalse(reply?.content.contains("most transactions") == true,
                       "\(reply?.content.prefix(100) ?? "")")
    }

    func testLargestTransactionIsNotACount() {
        // Parallel-session fix (2af0daa): "which was my largest transaction?"
        // was intercepted by the cross-statement COUNT handler.
        let m = modelWithThreeTxns()
        m.send("which was my largest transaction?")
        let reply = m.messages.last?.content ?? ""
        XCTAssertTrue(reply.contains("Largest") || reply.contains("largest"), "\(reply.prefix(100))")
        XCTAssertTrue(reply.contains("BRAVO"), "BRAVO (20) is the largest debit: \(reply.prefix(100))")
        XCTAssertFalse(reply.contains("most transactions"), "\(reply.prefix(100))")
    }

    func testKeywordFallbackAnswersNamedItemDeterministically() {
        // Parallel-session P11: a router-declined question naming a merchant gets
        // a deterministic keyword-search answer, never a model fallback.
        let m = modelWithThreeTxns()
        m.send("anything about ALPHA?")
        let reply = m.messages.last
        XCTAssertEqual(reply?.engine, "ANALYTICS", "named-item question must not fall to MLX")
        XCTAssertTrue(reply?.content.contains("ALPHA") == true, "\(reply?.content.prefix(100) ?? "")")
    }

    func testLedgerMatchesShortMerchantNames() {
        // Live (2026-08-28): "show me the transactions of uber" answered "No
        // transactions matching 'Uber'" while Uber rows were on screen — the
        // table's private matcher required 5+ characters. It now uses the
        // router's scoping brain, where "Uber" (4 chars) word-matches fine.
        let m = freshModel()
        m.loadForTesting([makeDoc(name: "bank.pdf",
                          txns: [txn(desc: "UPI/Uber/703766", debit: 10),
                                 txn(desc: "UPI/Ola Cabs/1", debit: 20)],
                          rows: [row(1, desc: "UPI/Uber/703766", debit: 10),
                                 row(2, desc: "UPI/Ola Cabs/1", debit: 20)],
                          currency: "INR")])
        m.recomputeSummary()
        m.send("show me the transactions of uber")
        let reply = m.messages.last
        XCTAssertEqual(reply?.engine, "LEDGER")
        XCTAssertTrue(reply?.content.contains("Uber") == true, "\(reply?.content.prefix(120) ?? "")")
        XCTAssertFalse(reply?.content.contains("No transactions matching") == true,
                       "Uber exists — no false zero: \(reply?.content.prefix(120) ?? "")")
        XCTAssertFalse(reply?.content.contains("Ola") == true,
                       "only Uber rows: \(reply?.content.prefix(160) ?? "")")

        // "related" is filler, not a merchant.
        m.send("show me the transactions related to uber")
        let reply2 = m.messages.last
        XCTAssertTrue(reply2?.content.contains("Uber") == true, "\(reply2?.content.prefix(120) ?? "")")
        XCTAssertFalse(reply2?.content.contains("Related") == true, "\(reply2?.content.prefix(120) ?? "")")
    }

    func testLedgerFiltersToNamedMerchant() {
        let m = modelWithThreeTxns()
        m.send("list my alpha transactions")
        let reply = m.messages.last
        XCTAssertEqual(reply?.engine, "LEDGER")
        XCTAssertTrue(reply?.content.contains("ALPHA") == true, "\(reply?.content.prefix(80) ?? "")")
        XCTAssertFalse(reply?.content.contains("BRAVO") == true,
                       "only the named merchant's rows: \(reply?.content.prefix(120) ?? "")")
    }

    func testLedgerHonestZeroForAbsentMerchant() {
        // Meeting finding: "list my netflix transactions" with no Netflix rows
        // dumped the ENTIRE ledger. A named-but-absent merchant is an honest
        // zero, never the full table.
        let m = modelWithThreeTxns()
        m.send("list my netflix transactions")
        let reply = m.messages.last
        XCTAssertEqual(reply?.engine, "LEDGER")
        XCTAssertTrue(reply?.content.contains("No transactions matching") == true,
                      "\(reply?.content.prefix(120) ?? "")")
        XCTAssertFalse(reply?.content.contains("ALPHA") == true,
                       "must not dump the whole ledger: \(reply?.content.prefix(120) ?? "")")
    }

    func testSendCreditTableWithNoCreditsSaysSo() {
        let m = freshModel()
        m.loadForTesting([makeDoc(name: "one.pdf", txns: [txn(debit: 5)], rows: [row(1, debit: 5)],
                          currency: "GBP")])
        m.recomputeSummary()
        m.send("show all credit transactions")
        XCTAssertEqual(m.messages.last?.engine, "LEDGER")
        XCTAssertEqual(m.messages.last?.content, "No credit transactions on record.")
    }

    // Two statements in different currencies — counts must never split by
    // currency ("USD: 2 · GBP: 1" read as a non-answer in live testing).
    private func modelWithTwoDocs() -> AppModel {
        let m = freshModel()
        m.loadForTesting([
            makeDoc(name: "chase.csv",
                    txns: [txn(desc: "ALPHA", debit: 10), txn(desc: "BRAVO", credit: 20)],
                    rows: [row(1, desc: "ALPHA", debit: 10),
                           row(2, desc: "BRAVO", category: "Income", credit: 20)],
                    currency: "USD"),
            makeDoc(name: "barclays.csv",
                    txns: [txn(desc: "CHARLIE", debit: 5)],
                    rows: [row(1, desc: "CHARLIE", debit: 5)],
                    currency: "GBP"),
        ])
        m.recomputeSummary()
        return m
    }

    func testTotalTransactionCountIsGrandTotalNotPerCurrency() {
        let m = modelWithTwoDocs()
        m.send("whats the total count of transactions?")
        let reply = m.messages.last?.content ?? ""
        XCTAssertTrue(reply.contains("**3 transactions**"), "grand total expected: \(reply)")
        XCTAssertFalse(reply.contains("**USD**"), "must not split a count by currency: \(reply)")
    }

    func testPerAccountTransactionCountListsEachStatement() {
        let m = modelWithTwoDocs()
        m.send("whats the total count of transactions in individual accounts?")
        let reply = m.messages.last?.content ?? ""
        XCTAssertTrue(reply.contains("Chase") && reply.contains("2")
                      && reply.contains("Barclays") && reply.contains("1"), "\(reply)")
        XCTAssertFalse(reply.contains(".csv"), "no technical filenames in answers: \(reply)")
        XCTAssertFalse(reply.contains("**USD**"), "per-ACCOUNT, not per-currency: \(reply)")
    }

    // A stale personal key in the Keychain must never shadow the healthy proxy
    // (2026-08-29: "key was rejected" toasts while the local proxy sat working).
    func testProxyOutranksStalePersonalKey() throws {
        let m = AppModel()
        m.claudeAPIKey = "sk-dead-key-from-months-ago"
        let cfg = try XCTUnwrap(m.categorizerConfig)
        XCTAssertNotEqual(cfg.endpoint, .anthropic,
                          "personal key must not send traffic to Anthropic when a proxy is configured")
        XCTAssertEqual(cfg.key, PennyBackend.appToken)
    }

    // Aggregator statements (Paytm-style) must surface the UNDERLYING banks —
    // the user's "bank name is union bank" is about where the money moved
    // (2026-08-29).
    func testBankNameNamesUnderlyingAccountsForAggregators() {
        let m = freshModel()
        let text = """
        Paytm Statement for
        Payment received
        Union Bank Of India - 49 Rs.44,119.16
        Canara Bank - 41 Rs.345
        """
        m.loadForTesting([makeDoc(name: "paytm.pdf", text: text, rows: [row(1)], detectedIssuer: "Paytm")])
        m.send("whats the bank name?")
        let reply = m.messages.last?.content ?? ""
        XCTAssertTrue(reply.contains("Paytm"), reply)
        XCTAssertTrue(reply.contains("Union Bank Of India -49") || reply.contains("Union Bank Of India - 49"), reply)
        XCTAssertTrue(reply.contains("Canara Bank -41") || reply.contains("Canara Bank - 41"), reply)
    }

    // "whats the bank name?" was hijacked by keyword search matching the word
    // "bank" inside descriptions ("Union Bank Of India") → "Found 10
    // transactions at Bank" (2026-08-29). Roster answers; search never fires.
    func testWhatsTheBankNameIsARosterNotASearch() {
        let m = modelWithTwoDocs()
        m.send("whats the bank name?")
        let reply = m.messages.last?.content ?? ""
        XCTAssertTrue(reply.contains("statements:") || reply.contains("statement is from"), reply)
        XCTAssertFalse(reply.contains("Found"), "must not be a keyword search: \(reply)")
        XCTAssertFalse(reply.contains("at Bank"), reply)
    }

    func testWhichMonthDidISpendTheMostIsAMonthAnswerNotAStatementComparison() {
        // 2026-08-31 manual bug: the cross-statement money-out comparer stole
        // this and replied "Paytm has the most money out: ₹44,885.16".
        let m = modelWithDatedTxns()
        m.send("which month did i spend the most?")
        let reply = m.messages.last?.content ?? ""
        XCTAssertTrue(reply.contains("highest-spending month"), reply)
        XCTAssertFalse(reply.contains("has the most money out"), reply)
    }

    // 2026-09-02 manual bugs: the same comparer, new subjects — its exclusion
    // blacklist lost to a typo ("catagory") and to "on what … in fastfood".
    // It now requires the question to be ABOUT accounts/statements/banks.
    func testCategorySuperlativeTypoIsNotAStatementComparison() {
        let m = modelWithTwoDocs()
        m.send("which catagory did i spend most amount?")
        let reply = m.messages.last?.content ?? ""
        XCTAssertFalse(reply.contains("has the most money out"), reply)
    }

    func testOnWhatInFastfoodIsNotAStatementComparison() {
        let m = modelWithTwoDocs()
        m.send("on what did i spend most in fastfood?")
        let reply = m.messages.last?.content ?? ""
        XCTAssertFalse(reply.contains("has the most money out"), reply)
    }

    // 2026-09-02 manual bug: "to which account did i recieve most?" (typo and
    // all) got the same per-currency account-decline three times. The statement
    // dimension now answers — the statement IS the account.
    func testToWhichAccountDidIRecieveMostAnswersFromStatements() {
        let m = modelWithTwoDocs()
        m.send("to which account did i recieve most?")
        let reply = m.messages.last?.content ?? ""
        XCTAssertFalse(reply.contains("doesn't say which of your accounts"), reply)
        XCTAssertTrue(reply.contains("came into"), reply)
    }

    // 2026-09-02 manual bug: "what transaction did i make from paytm related to
    // that?" → "$0.00 on Paytm" — a statement name is session metadata, never a
    // phantom merchant.
    func testStatementNameNeverBecomesAPhantomMerchant() {
        let m = freshModel()
        m.loadForTesting([
            makeDoc(name: "paytm.pdf",
                    txns: [txn(desc: "TESCO", debit: 10)],
                    rows: [row(1, desc: "TESCO", debit: 10, currency: "INR")],
                    currency: "INR"),
            makeDoc(name: "hdfc.csv",
                    txns: [txn(desc: "SWIGGY", debit: 20)],
                    rows: [row(1, desc: "SWIGGY", category: "Food & Dining", debit: 20, currency: "INR")],
                    currency: "INR"),
        ])
        m.recomputeSummary()
        m.send("what transaction did i make from paytm related to that?")
        let reply = m.messages.last?.content ?? ""
        XCTAssertFalse(reply.contains("0.00 on Paytm"), reply)
    }

    // 2026-09-02 manual bug: "list those transactions" after a scoped answer
    // dumped the entire 981-row ledger. A demonstrative refers to the previous
    // answer's receipts — and each row renders in its own currency.
    func testListThoseTransactionsScopesToPreviousReceipts() {
        let m = modelWithTwoDocs()
        m.send("how much did i spend at alpha?")
        m.send("list those transactions")
        let reply = m.messages.last?.content ?? ""
        XCTAssertTrue(reply.contains("behind that answer"), reply)
        XCTAssertTrue(reply.contains("ALPHA"), reply)
        XCTAssertTrue(reply.contains("$10.00"), "ALPHA is a USD row: \(reply)")
        XCTAssertFalse(reply.contains("CHARLIE"), "GBP doc's row must not appear: \(reply)")
    }

    // 2026-09-02 manual bug: bare "list them" (no noun) fell past every
    // deterministic handler to the MLX model, which prose-listed and garbled
    // the rows. The pronoun alone must reach the receipts table.
    func testBareListThemAlsoScopesToPreviousReceipts() {
        let m = modelWithTwoDocs()
        m.send("how much did i spend at alpha?")
        m.send("list them")
        let reply = m.messages.last?.content ?? ""
        XCTAssertEqual(m.messages.last?.engine, "LEDGER", reply)
        XCTAssertTrue(reply.contains("behind that answer"), reply)
        XCTAssertFalse(reply.contains("CHARLIE"), reply)
    }

    // 2026-09-02 manual bug: "do i have prime?" answered "Found 30 transactions
    // at Prime" — a listing header, not an answer. Yes/no questions lead with
    // yes.
    func testExistenceQuestionLeadsWithYesNotFound() {
        let m = freshModel()
        m.loadForTesting([makeDoc(name: "bank.csv",
            txns: [txn(desc: "AMAZON PRIME", debit: 149), txn(desc: "STARBUCKS", debit: 300)],
            rows: [row(1, desc: "AMAZON PRIME", category: "Subscriptions", debit: 149),
                   row(2, desc: "STARBUCKS", category: "Food & Dining", debit: 300)],
            currency: "INR")])
        m.recomputeSummary()
        m.send("do i have prime?")
        var reply = m.messages.last?.content ?? ""
        XCTAssertTrue(reply.hasPrefix("**Yes —"), reply)
        XCTAssertFalse(reply.contains("Found"), reply)
        m.send("do i got to starbucks?")
        reply = m.messages.last?.content ?? ""
        XCTAssertTrue(reply.hasPrefix("**Yes —"), reply)
    }

    private func modelWithDatedTxns() -> AppModel {
        let m = freshModel()
        m.loadForTesting([makeDoc(name: "bank.pdf",
                          txns: [txn(date: "2026-02-24", desc: "FEB",   debit: 10),
                                 txn(date: "2026-03-10", desc: "MAR-A", debit: 20),
                                 txn(date: "2026-03-20", desc: "MAR-B", debit: 30),
                                 txn(date: "2026-04-05", desc: "APR",   debit: 40),
                                 txn(date: "2026-05-01", desc: "MAY",   debit: 50)],
                          rows: [row(1, date: "2026-02-24", desc: "FEB",   debit: 10),
                                 row(2, date: "2026-03-10", desc: "MAR-A", debit: 20),
                                 row(3, date: "2026-03-20", desc: "MAR-B", debit: 30),
                                 row(4, date: "2026-04-05", desc: "APR",   debit: 40),
                                 row(5, date: "2026-05-01", desc: "MAY",   debit: 50)],
                          currency: "GBP")])
        m.recomputeSummary()
        return m
    }

    func testSendTableWithDateRangeFiltersRows() {
        let m = modelWithDatedTxns()
        m.send("generate table from 2026-03-05 to 2026-04-05")
        let reply = m.messages.last
        XCTAssertEqual(reply?.engine, "LEDGER")
        // MAR-A, MAR-B, and APR (end date is inclusive); FEB and MAY excluded.
        XCTAssertTrue(reply?.content.hasPrefix(
            "Here are all 3 transactions from 2026-03-05 to 2026-04-05:") == true,
            "range header/count wrong; got: \(reply?.content.prefix(80) ?? "")")
        let blocks = MD.parse(reply?.content ?? "")
        XCTAssertEqual(mdTable(blocks.last)?.rows.count, 3, "only in-range rows appear")
    }

    func testSendTableWithReversedRangeStillWorks() {
        let m = modelWithDatedTxns()
        m.send("show all transactions between 2026-04-05 and 2026-03-05")
        XCTAssertTrue(m.messages.last?.content.hasPrefix(
            "Here are all 3 transactions from 2026-03-05 to 2026-04-05:") == true,
            "reversed range should sort ascending; got: \(m.messages.last?.content.prefix(80) ?? "")")
    }

    func testSendTableWithTypoedLeadingZeroDay() {
        // Real user input: "…to 2026-03-010" (fat-fingered extra zero → the 10th).
        // Must parse as 2026-03-05…2026-03-10, NOT fall through to a whole-year dump.
        let m = modelWithDatedTxns()
        m.send("generate table from 2026-03-05 to 2026-03-010")
        let reply = m.messages.last
        XCTAssertEqual(reply?.engine, "LEDGER")
        // Window 03-05…03-10 catches only MAR-A (03-10); MAR-B is 03-20, outside it.
        XCTAssertTrue(reply?.content.hasPrefix(
            "Here is all 1 transaction from 2026-03-05 to 2026-03-10:") == true,
            "leading-zero typo should still parse the range; got: \(reply?.content.prefix(90) ?? "")")
        XCTAssertEqual(mdTable(MD.parse(reply?.content ?? "").last)?.rows.count, 1)
    }

    func testSendTableWithEmptyDateRangeSaysSo() {
        let m = modelWithDatedTxns()
        m.send("generate table from 2026-06-01 to 2026-06-30")
        let reply = m.messages.last
        XCTAssertEqual(reply?.engine, "LEDGER")
        XCTAssertEqual(reply?.content, "No transactions from 2026-06-01 to 2026-06-30.")
    }

    func testSendTableWithNamedMonth() {
        let m = modelWithDatedTxns()
        m.send("generate table for March")
        // MAR-A and MAR-B; year inferred from the data (2026).
        XCTAssertTrue(m.messages.last?.content.hasPrefix(
            "Here are all 2 transactions in March 2026:") == true,
            "named-month scope wrong; got: \(m.messages.last?.content.prefix(80) ?? "")")
        XCTAssertEqual(mdTable(MD.parse(m.messages.last?.content ?? "").last)?.rows.count, 2)
    }

    func testSendTableWithNamedMonthAndExplicitYear() {
        let m = modelWithDatedTxns()
        m.send("show all transactions in February 2026")
        XCTAssertTrue(m.messages.last?.content.hasPrefix(
            "Here is all 1 transaction in February 2026:") == true,
            "explicit-year month scope wrong; got: \(m.messages.last?.content.prefix(80) ?? "")")
    }

    func testSendTableLastMonthAnchorsToData() {
        let m = modelWithDatedTxns()   // months present: Feb, Mar, Apr, May 2026
        m.send("show all transactions last month")   // latest is May → "last" = April
        XCTAssertTrue(m.messages.last?.content.hasPrefix(
            "Here is all 1 transaction last month (April 2026):") == true,
            "last-month should anchor to the data's second-latest month; got: \(m.messages.last?.content.prefix(90) ?? "")")
    }

    func testSendTableLastNDays() {
        let m = modelWithDatedTxns()   // max date is 2026-05-01
        m.send("show all transactions in the last 30 days")
        // Window is 2026-04-02…2026-05-01 → APR (04-05) and MAY (05-01).
        XCTAssertTrue(m.messages.last?.content.hasPrefix(
            "Here are all 2 transactions in the last 30 days:") == true,
            "rolling-day window wrong; got: \(m.messages.last?.content.prefix(80) ?? "")")
    }

    func testSendTableThisYear() {
        let m = modelWithDatedTxns()
        m.send("show all transactions this year")   // maxYear = 2026 → all five rows
        XCTAssertTrue(m.messages.last?.content.hasPrefix(
            "Here are all 5 transactions in 2026:") == true,
            "year window wrong; got: \(m.messages.last?.content.prefix(80) ?? "")")
    }

    func testSendTableEmptyNamedMonthSaysSo() {
        let m = modelWithDatedTxns()
        m.send("generate table for January")   // no January rows in the data
        XCTAssertEqual(m.messages.last?.content, "No transactions in January 2026.")
    }

    func testSendTableWithoutRangeUnaffected() {
        let m = modelWithDatedTxns()
        m.send("show me all transactions in a table")
        XCTAssertTrue(m.messages.last?.content.hasPrefix(
            "Here are all 5 transactions on record:") == true,
            "no-range path must keep 'on record' wording; got: \(m.messages.last?.content.prefix(80) ?? "")")
    }

    func testSendCountQuestionRoutesToAnalyticsNotLedger() {
        let m = modelWithThreeTxns()
        m.send("how many transactions do I have?")
        XCTAssertEqual(m.messages.count, 2)
        XCTAssertEqual(m.messages[1].engine, "ANALYTICS",
                       "count questions must go to the FinanceRouter, not the LEDGER table")
        XCTAssertTrue(m.messages[1].content.contains("**3 transactions.**"),
                      "got: \(m.messages[1].content)")

        // 'count' is a hard veto on the table route even alongside table words.
        m.send("count my transactions")
        XCTAssertEqual(m.messages.count, 4)
        XCTAssertEqual(m.messages[3].engine, "ANALYTICS")
        XCTAssertTrue(m.messages[3].content.contains("**3 transactions.**"))
    }

    // Phase 1.1 — the Query Engine routes count/spend/income through the parity
    // guard (engine answer == router answer), and reports it via engineRoutingStats.
    // An advisory question the bridge doesn't map falls back automatically.
    func testPhase11EngineRoutesCountSpendIncomeAndFallsBack() {
        let m = modelWithThreeTxns()  // debits 10 + 20, credit 5

        m.send("how many transactions do I have?")
        XCTAssertEqual(m.messages.last?.engine, "ANALYTICS")
        XCTAssertTrue(m.messages.last?.content.contains("**3 transactions.**") == true,
                      "got: \(m.messages.last?.content ?? "nil")")
        XCTAssertEqual(m.engineRoutingStats.routed, 1, "count must be engine-routed, not a fallback")

        m.send("total spending")
        XCTAssertTrue(m.messages.last?.content.contains("**You spent £30.00** across 2 transactions.") == true,
                      "got: \(m.messages.last?.content ?? "nil")")
        XCTAssertEqual(m.engineRoutingStats.routed, 2)

        // "total income" — the router scopes to the fixture's category literally named
        // "Income"; the engine's unscoped total diverges, so the guard falls back and
        // the router's (correct, scoped) answer is preserved. Behaviour unchanged.
        m.send("total income")
        XCTAssertTrue(m.messages.last?.content.contains("**You received £5.00 on Income** across 1 credit.") == true,
                      "guard must fall back to the router's scoped answer; got: \(m.messages.last?.content ?? "nil")")
        XCTAssertEqual(m.engineRoutingStats.routed, 2, "income diverged (router scope) → not routed")
        XCTAssertEqual(m.engineRoutingStats.fellBack, 1)

        // Advisory → bridge returns nil → router returns nil → MLX fallback (unsupported).
        m.send("should I be worried about my spending?")
        XCTAssertEqual(m.messages.last?.engine, "MLX")
        XCTAssertEqual(m.engineRoutingStats.routed, 2, "advisory must not be engine-routed")
        XCTAssertEqual(m.engineRoutingStats.unsupported, 1)
    }

    func testSendBalanceQuestionAnswersMultiAccountAnalytics() {
        let m = freshModel()
        let bank = makeDoc(name: "bank.pdf",
                           txns: [txn(debit: 10, balance: 1000)],
                           rows: [row(1, debit: 10, balance: 1000)],
                           currency: "GBP")
        let card = makeDoc(name: "card.pdf",
                           txns: [txn(debit: 250)],
                           currency: "GBP", closingBalance: 250, isCard: true)
        m.loadForTesting([bank, card])
        m.recomputeSummary()
        m.send("what is my balance?")
        let reply = m.messages.last
        XCTAssertEqual(reply?.engine, "ANALYTICS")
        XCTAssertTrue(reply?.content.contains("£750.00") == true,
                      "bank 1000 − card 250 owed; got: \(reply?.content ?? "nil")")
        XCTAssertTrue(reply?.content.contains("owed (card)") == true,
                      "card line must be marked as owed; got: \(reply?.content ?? "nil")")
    }

    // MARK: - namedDocHeader (per-statement header grounding)

    func testNamedDocHeaderPicksTheNamedStatement() {
        let m = freshModel()
        m.loadForTesting([
            makeDoc(name: "Sample_Statement_barclays.pdf",
                    text: "Barclays Bank PLC\nStatement period: 16 May 2026 to 15 June 2026\n…rows…",
                    bank: "Barclays Bank"),
            makeDoc(name: "monzo.pdf", text: "Monzo Bank\nYour statement\n…", bank: "Monzo"),
        ])
        let header = m.namedDocHeader(for: "What is the statement period for Barclays?")
        XCTAssertNotNil(header, "a question naming Barclays must surface that statement's header")
        XCTAssertTrue(header!.contains("16 May 2026 to 15 June 2026"),
                      "the Barclays header text must be included; got: \(header ?? "nil")")
        XCTAssertFalse(header!.contains("Monzo"),
                       "only the named statement's header, not the other doc's")
    }

    func testNamedDocHeaderNilForGenericQuestion() {
        let m = freshModel()
        m.loadForTesting([makeDoc(name: "barclays.pdf", text: "Barclays Bank", bank: "Barclays Bank")])
        // "bank"/"statement"/"account" are stop words — a generic question names no doc.
        XCTAssertNil(m.namedDocHeader(for: "how much did I spend at the bank this month?"),
                     "generic words must not select a specific statement")
    }

    func testNamedDocHeaderMatchesFilenameAndIssuer() {
        let m = freshModel()
        m.loadForTesting([makeDoc(name: "revolut_dummy.pdf", text: "Revolut Ltd header",
                          detectedIssuer: "Revolut")])
        XCTAssertNotNil(m.namedDocHeader(for: "what's the account number on Revolut?"),
                        "issuer name should match")
        XCTAssertNotNil(m.namedDocHeader(for: "show the header of revolut_dummy"),
                        "filename token should match too")
    }

    // MARK: - openingBalance extraction + documentMetadataAnswer

    func testOpeningBalanceExtractsCommonLabels() {
        XCTAssertEqual(AppModel.openingBalance(in: "Opening Balance £42.20\n…"), 42.20)
        XCTAssertEqual(AppModel.openingBalance(in: "Balance brought forward 1,234.56"), 1234.56)
        XCTAssertEqual(AppModel.openingBalance(in: "Start balance: -15.00 overdrawn"), -15.00)
        XCTAssertEqual(AppModel.openingBalance(in: "Previous balance    £0.00"), 0.00)
        XCTAssertNil(AppModel.openingBalance(in: "Closing balance £900.00"),
                     "must not read the CLOSING balance as the opening one")
        XCTAssertNil(AppModel.openingBalance(in: "no balance stated here"))
    }

    func testDocumentMetadataAnswersBarclaysOpeningBalance() {
        let m = freshModel()
        m.loadForTesting([
            makeDoc(name: "Sample_Statement_barclays.pdf",
                    text: "Barclays Bank PLC\nOpening balance £42.20\n… rows …",
                    currency: "GBP", bank: "Barclays Bank"),
            makeDoc(name: "monzo.pdf", text: "Monzo\nOpening balance £500.00", bank: "Monzo"),
        ])
        let a = m.documentMetadataAnswer("What was the Barclays starting balance?")
        XCTAssertEqual(a, "**Barclays Bank opening balance: £42.20.**",
                       "must scope to the named Barclays statement, not Monzo")
    }

    func testDocumentMetadataAnswersAmexAvailableCreditAndLimit() {
        let m = freshModel()
        // The real Amex "Credit Summary" layout: two aligned columns — labels on one
        // line, the two amounts (limit, then available) on the next.
        m.loadForTesting([makeDoc(name: "Sample_Statement_amex.pdf",
                          text: "American Express Platinum\nCredit Summary\n"
                              + "Credit Limit £ Available Credit Limit £\n16,100.00 15,470.46\n"
                              + "Rates of Interest",
                          currency: "GBP", detectedIssuer: "American Express")])
        XCTAssertEqual(m.documentMetadataAnswer("What is the available credit limit on the Amex account?"),
                       "**American Express available credit: £15,470.46.**",
                       "‘available credit limit’ = the SECOND column, not the £16,100 total limit")
        XCTAssertEqual(m.documentMetadataAnswer("what's the credit limit on Amex?"),
                       "**American Express credit limit: £16,100.00.**")
    }

    func testDocumentMetadataAnswersAmexStatementDateAndCardholder() {
        let m = freshModel()
        // Real Amex "Platinum Card" header — no "Statement date:" label; the name and
        // date live on the "Prepared for … Date" value row + the "received by" line.
        m.loadForTesting([makeDoc(name: "Sample_Statement_amex.pdf",
                          text: "The Platinum Card\nStatement of Account\n"
                              + "Prepared for Membership Number Date\n"
                              + "PIYUSH MISHRA xxxx-xxxxxx-01001 15/03/26\n"
                              + "Statement includes payments and charges received by 15 March 2026\n",
                          currency: "GBP", detectedIssuer: "American Express")])
        XCTAssertEqual(m.documentMetadataAnswer("What is the statement date?"),
                       "**American Express statement date: 15 March 2026.**",
                       "must read 15 March (not the LLM's off-by-one 14th)")
        XCTAssertEqual(m.documentMetadataAnswer("Who is the statement prepared for?"),
                       "**The American Express statement is prepared for Piyush Mishra.**",
                       "must extract the cardholder name, not answer 'you'")
        // The statement-period query must NOT be captured by the statement-date case.
        XCTAssertNil(m.documentMetadataAnswer("what is the statement period?"),
                     "period query has no declared period here → defers, not a date answer")
    }

    func testHeaderFactAnswerFormatsAndRejects() {
        let doc = makeDoc(name: "amex.pdf", text: "x", currency: "GBP",
                          detectedIssuer: "American Express")
        // Statement date: a well-formed value is parsed + formatted; anything the
        // date parser rejects becomes nil (an honest miss, never a wrong answer).
        XCTAssertEqual(
            AppModel.headerFactAnswer(.statementDate,
                facts: .init(cardholder: nil, statementDate: "15/03/26"), doc: doc),
            "**American Express statement date: 15 March 2026.**")
        XCTAssertNil(AppModel.headerFactAnswer(.statementDate,
                facts: .init(statementDate: "sometime in spring"), doc: doc),
            "an unparseable date must not become a wrong answer")
        XCTAssertNil(AppModel.headerFactAnswer(.statementDate, facts: .init(), doc: doc))
        // Cardholder: an ALL-CAPS name is title-cased; a junk blob is rejected.
        XCTAssertEqual(
            AppModel.headerFactAnswer(.cardholder, facts: .init(cardholder: "PIYUSH MISHRA"), doc: doc),
            "**The American Express statement is prepared for Piyush Mishra.**")
        XCTAssertNil(
            AppModel.headerFactAnswer(.cardholder,
                facts: .init(cardholder: "xxxx-xxxxxx-01001 15/03/26"), doc: doc),
            "a membership-number blob is not a name")
        XCTAssertNil(AppModel.headerFactAnswer(.cardholder, facts: .init(cardholder: ""), doc: doc))
    }

    func testDynamicHeaderFactRequestRouting() {
        let m = freshModel()
        // Header with NO recognisable labels → the deterministic parser can't answer,
        // so these questions are the ones that route to the dynamic model fallback.
        m.loadForTesting([makeDoc(name: "bank.pdf", text: "Some Bank\nno labelled fields here",
                          currency: "GBP")])
        XCTAssertEqual(m.dynamicHeaderFactRequest("what is the statement date?")?.field, .statementDate)
        XCTAssertEqual(m.dynamicHeaderFactRequest("who is the statement prepared for?")?.field, .cardholder)
        XCTAssertNil(m.dynamicHeaderFactRequest("how much did I spend on food?"),
                     "non-metadata questions don't route to the dynamic fallback")
        XCTAssertNil(m.dynamicHeaderFactRequest("what is the statement period?"),
                     "‘period’ is not a statement-date request")
    }

    func testCreditSummaryColumnarParse() {
        let text = "Credit Limit £ Available Credit Limit £\n16,100.00 15,470.46\nRates"
        let s = AppModel.creditSummary(in: text)
        XCTAssertEqual(s.limit, 16100.00)
        XCTAssertEqual(s.available, 15470.46)
        // No such block → nils (caller falls back to the generic label reader).
        let none = AppModel.creditSummary(in: "no credit summary here")
        XCTAssertNil(none.limit); XCTAssertNil(none.available)
    }

    func testHasSalaryRecognisesPayrollCreditVariants() {
        // Real descriptions from the sample statements.
        XCTAssertTrue(AppModel.hasSalary([row(1, desc: "Salary", credit: 2607.91)]))
        XCTAssertTrue(AppModel.hasSalary([row(1, desc: "BGC PENNY TECH LTD", credit: 3001.16)]))
        XCTAssertTrue(AppModel.hasSalary([row(1, desc: "Giro Received From Penny Tech Ltd", credit: 2422.28)]))
        XCTAssertTrue(AppModel.hasSalary([row(1, desc: "PENNY TECH LTD (Faster Payments)", credit: 2690.87)]))
        XCTAssertTrue(AppModel.hasSalary([row(1, desc: "NAZARA TECHNOLOGIES UK LIMITED", credit: 7881.82)]))
        // Amex has no payroll credit — only a card repayment + a dining benefit.
        XCTAssertFalse(AppModel.hasSalary([
            row(1, desc: "PAYMENT RECEIVED - THANK YOU", credit: 1182.79),
            row(2, desc: "AMBASSADORS CLUB HOUSE Dining Benefit", credit: 100.00),
        ]))
        // A small credit from a Ltd (e.g. a refund) is not a salary.
        XCTAssertFalse(AppModel.hasSalary([row(1, desc: "ASOS LTD REFUND", credit: 25.86)]))
    }

    func testDocumentContentListsStatementsWithSalary() {
        let m = freshModel()
        m.loadForTesting([
            makeDoc(name: "amex.pdf", rows: [row(1, desc: "PAYMENT RECEIVED", credit: 1182.79)],
                    detectedIssuer: "American Express", isCard: true),
            makeDoc(name: "barclays.pdf", rows: [row(1, desc: "Giro Received From Penny Tech Ltd", credit: 2422.28)],
                    bank: "Barclays Bank"),
            makeDoc(name: "nationwide.pdf", rows: [row(1, desc: "Salary", credit: 2607.91)],
                    detectedIssuer: "Nationwide"),
        ])
        let a = m.documentContentAnswer("Which statements contain salary transactions?")
        XCTAssertEqual(a, """
        **These statements contain salary transactions:**
        - Barclays Bank
        - Nationwide
        """, "must list the payroll statements and exclude the Amex card; got: \(a ?? "nil")")
    }

    func testDocumentContentNilForNonContentQuestion() {
        let m = freshModel()
        m.loadForTesting([makeDoc(name: "nationwide.pdf", rows: [row(1, desc: "Salary", credit: 2607.91)])])
        XCTAssertNil(m.documentContentAnswer("how much salary did I get?"),
                     "a totals question is not a 'which statements contain' lookup")
    }

    func testDocumentMetadataDefersWhenNotAnOpeningBalanceQuestion() {
        let m = freshModel()
        m.loadForTesting([makeDoc(name: "barclays.pdf", text: "Opening balance £42.20", bank: "Barclays Bank")])
        XCTAssertNil(m.documentMetadataAnswer("what is my balance?"),
                     "only opening/starting-balance questions are handled here")
    }

    func testSendRoutesStartingBalanceToDocumentMetadata() {
        let m = freshModel()
        m.loadForTesting([makeDoc(name: "Sample_Statement_barclays.pdf",
                          text: "Barclays Bank PLC\nOpening balance £42.20\nrows",
                          txns: [txn(debit: 10, balance: 1000)],
                          rows: [row(1, debit: 10, balance: 1000)],
                          currency: "GBP", bank: "Barclays Bank")])
        m.recomputeSummary()
        m.send("What was the Barclays starting balance?")
        let reply = m.messages.last
        XCTAssertEqual(reply?.engine, "ANALYTICS")
        XCTAssertEqual(reply?.content, "**Barclays Bank opening balance: £42.20.**",
                       "starting-balance question must not fall to the latest-balance handler")
    }

    func testSendIgnoresBlankInputAndWhileThinking() {
        let m = modelWithThreeTxns()
        m.send("   \n ")
        XCTAssertTrue(m.messages.isEmpty, "whitespace-only input must be dropped")
        m.isThinking = true
        m.send("how many transactions do I have?")
        XCTAssertTrue(m.messages.isEmpty, "send() is a no-op while a reply is in flight")
    }

    // MARK: - chat history (requires the PENNY_UITEST=1 temp-file redirect so
    // these can never touch the user's real chat-history.json)

    func testNewChatArchivesOnlyWhenAUserMessageExists() throws {
        try XCTSkipUnless(TestMode.active,
                          "PENNY_UITEST=1 must be set (Penny scheme test env) to redirect history to temp")
        let m = freshModel()

        m.messages = [ChatMessage(role: .assistant, content: "Hi! I'm Penny.")]
        m.newChat()
        XCTAssertTrue(m.history.isEmpty, "assistant-only transcript must not be archived")
        XCTAssertTrue(m.messages.isEmpty, "new chat always clears the transcript")

        m.messages = [ChatMessage(role: .user, content: ""),
                      ChatMessage(role: .assistant, content: "x")]
        m.newChat()
        XCTAssertTrue(m.history.isEmpty, "an empty-content user message doesn't count as spoken")

        m.messages = [ChatMessage(role: .user, content: "What did I spend at Tesco?"),
                      ChatMessage(role: .assistant, content: "£42")]
        m.centerView = .history
        m.newChat()
        XCTAssertEqual(m.history.count, 1)
        XCTAssertEqual(m.history.first?.title, "What did I spend at Tesco?",
                       "title is the first user message")
        XCTAssertEqual(m.history.first?.messages.count, 2)
        XCTAssertTrue(m.messages.isEmpty)
        XCTAssertEqual(m.centerView, .chat, "new chat returns to the chat pane")
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyFileURL.path),
                      "archive must persist to the per-process temp file in test mode")
    }

    func testArchiveTitleTruncatedTo80Chars() throws {
        try XCTSkipUnless(TestMode.active,
                          "PENNY_UITEST=1 must be set (Penny scheme test env) to redirect history to temp")
        let m = freshModel()
        m.messages = [ChatMessage(role: .user, content: String(repeating: "q", count: 100))]
        m.newChat()
        XCTAssertEqual(m.history.first?.title, String(repeating: "q", count: 80),
                       "title is capped at prefix(80)")
    }

    func testOpenSessionRestoresMessagesAndArchivesCurrent() throws {
        try XCTSkipUnless(TestMode.active,
                          "PENNY_UITEST=1 must be set (Penny scheme test env) to redirect history to temp")
        let m = freshModel()
        let past = ChatSession(id: UUID(), title: "old chat",
                               date: Date(timeIntervalSince1970: 1_700_000_000),
                               messages: [ChatMessage(role: .user, content: "old chat"),
                                          ChatMessage(role: .assistant, content: "old answer")])
        m.history = [past]
        m.messages = [ChatMessage(role: .user, content: "current question"),
                      ChatMessage(role: .assistant, content: "current answer")]
        m.centerView = .history

        m.openSession(past)

        XCTAssertEqual(m.messages, past.messages, "the past transcript becomes live again")
        XCTAssertEqual(m.centerView, .chat)
        XCTAssertFalse(m.history.contains { $0.id == past.id },
                       "an opened session leaves History (it re-archives on next new chat)")
        XCTAssertEqual(m.history.count, 1, "the interrupted live chat was archived")
        XCTAssertEqual(m.history.first?.title, "current question")
    }

    func testDeleteSessionRemovesOnlyThatSession() throws {
        try XCTSkipUnless(TestMode.active,
                          "PENNY_UITEST=1 must be set (Penny scheme test env) to redirect history to temp")
        let m = freshModel()
        let s1 = ChatSession(id: UUID(), title: "one", date: Date(),
                             messages: [ChatMessage(role: .user, content: "one")])
        let s2 = ChatSession(id: UUID(), title: "two", date: Date(),
                             messages: [ChatMessage(role: .user, content: "two")])
        m.history = [s1, s2]
        m.deleteSession(s1)
        XCTAssertEqual(m.history.map(\.id), [s2.id])
        m.deleteSession(s1)   // deleting again is a harmless no-op
        XCTAssertEqual(m.history.map(\.id), [s2.id])
    }

    // MARK: - Task 0.7 · graph is the source of truth, docs derived, selection canonical

    func testGraphIsSourceOfTruthDocsDerivedSelectionCanonical() {
        let m = freshModel()
        m.loadForTesting([
            makeDoc(name: "a.pdf", txns: [txn(debit: 10)], currency: "GBP"),
            makeDoc(name: "b.pdf", txns: [txn(debit: 20)], currency: "GBP"),
        ])
        XCTAssertEqual(m.graph.statements.count, 2, "graph holds both statements")
        XCTAssertEqual(m.docs.count, 2, "docs derived from the graph")
        XCTAssertTrue(m.docs.allSatisfy { $0.statementID != nil }, "derived docs carry their statement id")
        for doc in m.docs {
            XCTAssertTrue(m.graph.statements.contains { $0.id == doc.statementID },
                          "each derived doc maps to a canonical statement")
        }
        // Selection is canonical (by StatementID); the compat view + summary follow it.
        m.toggleDoc("b.pdf")
        XCTAssertEqual(m.selectedDocNames, ["a.pdf"], "compat name view reflects canonical selection")
        XCTAssertEqual(m.summary.spent, 10, accuracy: 0.001, "summary scopes to the selected statement")
        // Removal mutates the graph; docs re-derive from it.
        m.removeDoc(named: "a.pdf")
        XCTAssertEqual(m.graph.statements.count, 1)
        XCTAssertEqual(m.docs.count, 1)
        XCTAssertEqual(m.docs.first?.name, "b.pdf", "docs re-derived from the mutated graph")
    }
}

// MARK: - Ground-truth fixture + end-to-end spec (merged; project uses explicit file refs)

// AUTO-GENERATED from the real parsed sample statements — ground-truth end-to-end
// fixture for cross-document analytics. Regenerate via the /tmp dumper if parsing changes.

enum SampleGroundTruth {
    static func row(_ dt:String,_ de:String,_ me:String,_ ca:String,_ db:Double,_ cr:Double,_ ba:Double?) -> TxnRow {
        let p = dt.split(separator:"-").compactMap{Int($0)}
        return TxnRow(txnDate:dt,month:String(dt.prefix(7)),year:p[0],monthNo:p[1],day:p[2],descr:de,merchant:me,category:ca,debit:db,credit:cr,balance:ba,currency:"GBP",seq:0)
    }
    static var docs: [LoadedDoc] {
        var out:[LoadedDoc]=[]
        do { var rows:[TxnRow]=[]
          rows.append(row("2026-05-17","LE PETIT BISTRO PARIS FR","LE PETIT BISTRO PARIS FR","Food & Dining",35.34,0,nil))
          rows.append(row("2026-05-18","PAYMENT RECEIVED - THANK YOU","Payment Received","Payments",0,1182.79,nil))
          rows.append(row("2026-05-19","BOLT SERVICES UK LTD LONDON","BOLT SERVICES UK LTD LONDON","Transport",24.5,0,nil))
          rows.append(row("2026-05-19","WAITROSE SAMPLETON HILL SAMPLETON","WAITROSE SAMPLETON HILL SAMPLETON","Groceries",46.95,0,nil))
          rows.append(row("2026-05-20","JOHN LEWIS LONDON","JOHN LEWIS LONDON","Shopping",103.67,0,nil))
          rows.append(row("2026-05-25","AVIVA","AVIVA INSURANCE","Investment & Insurance",32.35,0,nil))
          rows.append(row("2026-05-26","PRET A MANGER LONDON","PRET A MANGER LONDON","Food & Dining",10.97,0,nil))
          rows.append(row("2026-05-28","TESCO STORES 2481 LONDON","TESCO STORES 2481 LONDON","Groceries",19.56,0,nil))
          rows.append(row("2026-05-28","THE ENTERTAINER - 47 WHITE CITY","THE ENTERTAINER - 47 WHITE CITY","Other",39.03,0,nil))
          rows.append(row("2026-05-28","AMAZON PRIME*N385H35X4 AMZN.CO.UK/PM","AMAZON PRIME*N385H35X4 AMZN.CO.UK/PM","Subscriptions",8.99,0,nil))
          rows.append(row("2026-05-29","SPOTIFY AB STOCKHOLM","SPOTIFY AB STOCKHOLM","Subscriptions",6.17,0,nil))
          rows.append(row("2026-05-29","APPLE.COM/BILL HOLLYHILL","APPLE.COM/BILL HOLLYHILL","Shopping",3.96,0,nil))
          rows.append(row("2026-05-30","WILLIAM MORRIS LONDON WILLIAM MORRIS 166","WILLIAM MORRIS LONDON WILLIAM MORRIS 166","Other",4.59,0,nil))
          rows.append(row("2026-06-03","DELIVEROO LONDON","DELIVEROO LONDON","Food & Dining",24,0,nil))
          rows.append(row("2026-06-03","THE ROCKET LONDON ROCKET 6283","THE ROCKET LONDON ROCKET 6283","Other",6.48,0,nil))
          rows.append(row("2026-06-04","AMAZON.CO.UK","AMAZON.CO.UK","Shopping",69.83,0,nil))
          rows.append(row("2026-06-04","SAINSBURYS S/MKT LONDON","SAINSBURYS S/MKT LONDON","Groceries",41.74,0,nil))
          rows.append(row("2026-06-04","SHELL FUEL SAMPLETON","SHELL FUEL SAMPLETON","Transport",65.4,0,nil))
          rows.append(row("2026-06-06","BOOKING.COM B.V. AMSTERDAM","BOOKING.COM B.V. AMSTERDAM","Transport",141,0,nil))
          rows.append(row("2026-06-08","BRITISH AIRWAYS LONDON","BRITISH AIRWAYS LONDON","Transport",328.28,0,nil))
          rows.append(row("2026-06-10","ASOS.COM","ASOS.COM","Shopping",24.58,0,nil))
          rows.append(row("2026-06-11","COSTA COFFEE LONDON","COSTA COFFEE LONDON","Food & Dining",5.29,0,nil))
          rows.append(row("2026-06-15","7245 - RUTLAND ARMS HAMMERSMITH","7245 - RUTLAND ARMS HAMMERSMITH","Other",24.76,0,nil))
          rows.append(row("2026-06-15","LIME*RIDE DXIZ LONDON","LIME*RIDE DXIZ LONDON","Other",2.31,0,nil))
          rows.append(row("2026-05-19","AMBASSADORS CLUB HOUSE Dining Benefit","AMBASSADORS CLUB HOUSE Dining Benefit","Income",0,100,nil))
          out.append(LoadedDoc(name:"amex.pdf",text:"",transactions:[],rows:rows,currency:"GBP",bank:nil,detectedIssuer:"American Express",closingBalance:629.54,isCard:true,analyzed:true)) }
        do { var rows:[TxnRow]=[]
          rows.append(row("2026-05-18","Card Card Payment to Tfl Travel Charge","Tfl Travel Charge","Transport",8.66,0,33.54))
          rows.append(row("2026-05-19","Giro Received From Penny Tech Ltd Ref:","Penny Tech Ltd","Income",0,2422.28,2455.82))
          rows.append(row("2026-05-20","Card Card Payment to Shein.Com","Shein.Com","Other",36.69,0,2419.13))
          rows.append(row("2026-05-20","DD Direct Debit to Pure Gym Ref: 935687810","Pure Gym","Subscriptions",22.32,0,2396.81))
          rows.append(row("2026-05-23","Giro Received From R Tester & Alex Ref: Sent From Monzo","R Tester & Alex","Transfers",0,111.6,2508.41))
          rows.append(row("2026-05-28","DD Direct Debit to O2 D34842817","O2 D34842817","Utilities",32.63,0,2475.78))
          rows.append(row("2026-05-28","DD Direct Debit to Sampleton Animal Charity Ref: 549698145","Sampleton Animal Charity","Other",19.68,0,2456.1))
          rows.append(row("2026-05-28","Card Card Payment to Asos.Com","Asos.Com","Shopping",24.87,0,2431.23))
          rows.append(row("2026-05-29","Card Card Payment to Tesco Stores 2481","Tesco Stores 2481","Groceries",27.41,0,2403.82))
          rows.append(row("2026-05-30","Card Card Payment to Sainsburys S/Mkt Sort code 20-72-61  Account number 905957","Sainsburys S/Mkt Sort code 20-72-61  Account number 905957","Groceries",23.4,0,2380.42))
          rows.append(row("2026-05-31","DD Direct Debit to Virgin Media Pymts Ref: 199749410","Virgin Media Pymts","Utilities",42.67,0,2337.75))
          rows.append(row("2026-06-02","DD Direct Debit to Aqua Water Services Ref: 100939383","Aqua Water Services","Other",31.18,0,2306.57))
          rows.append(row("2026-06-02","DD Direct Debit to Aviva Insurance Ref: 008515901","Aviva Insurance","Investment & Insurance",35.7,0,2270.87))
          rows.append(row("2026-06-02","Card Card Payment to Amazon.Co.Uk","Amazon.Co.Uk","Shopping",33.86,0,2237.01))
          rows.append(row("2026-06-02","Card Card Payment to Deliveroo","Deliveroo","Food & Dining",27.15,0,2209.86))
          rows.append(row("2026-06-02","Card Card Payment to Google Youtubeprem","Google Youtubeprem","Entertainment",17.05,0,2192.81))
          rows.append(row("2026-06-03","Giro Received From Alex Sample Ref: Alex Barclays NOT","Alex Sample","Transfers",0,145.65,2338.46))
          rows.append(row("2026-06-03","DD Direct Debit to Sampleton Council Ref: 234911868","Sampleton Council","Utilities",144.46,0,2194))
          rows.append(row("2026-06-05","DD Direct Debit to Acme Lettings Ref: 848619301","Acme Lettings","Rent",976.33,0,1217.67))
          rows.append(row("2026-06-06","Card Card Payment to Apple.Com/Bill -","Apple.Com/Bill","Shopping",3.5,0,1214.17))
          rows.append(row("2026-06-07","Card Card Payment to Putney Cricket Clu","Putney Cricket Clu","Entertainment",13.44,0,1200.73))
          rows.append(row("2026-06-09","Card Card Payment to Boots","Boots","Healthcare",14.61,0,1186.12))
          rows.append(row("2026-06-10","Card Card Payment to Shell Fuel SAMPLE","Shell Fuel SAMPLE","Transport",42.2,0,1143.92))
          rows.append(row("2026-06-12","Card Card Payment to Netflix.Com","Netflix.Com","Subscriptions",10.52,0,1133.4))
          out.append(LoadedDoc(name:"barclays.pdf",text:"",transactions:[],rows:rows,currency:"GBP",bank:nil,detectedIssuer:"Barclays",closingBalance:nil,isCard:false,analyzed:true)) }
        do { var rows:[TxnRow]=[]
          rows.append(row("2026-05-16","TESCO STORES 2481 London GBR","TESCO STORES 2481 London GBR","Groceries",51.46,0,4212.83))
          rows.append(row("2026-05-17","SAINSBURYS S/MKT London GBR","SAINSBURYS S/MKT London GBR","Groceries",35.1,0,4177.73))
          rows.append(row("2026-05-17","AMAZON.CO.UK London GBR","AMAZON.CO.UK London GBR","Shopping",21.88,0,4155.85))
          rows.append(row("2026-05-18","NANDO'S London GBR","NANDO'S London GBR","Food & Dining",27.45,0,4128.4))
          rows.append(row("2026-05-18","Le Petit Bistro Paris FRA","Le Petit Bistro Paris FRA","Food & Dining",36.56,0,4091.84))
          rows.append(row("2026-05-18","VODAFONE UK (","VODAFONE UK (Direct Debit)","Utilities",43.92,0,4047.92))
          rows.append(row("2026-05-18","TFL TRAVEL CHARGE London GBR","TFL TRAVEL CHARGE London GBR","Transport",4.79,0,4043.13))
          rows.append(row("2026-05-19","Monzo Overdraft (","Monzo Overdraft (Direct Debit)","Other",10.86,0,4032.27))
          rows.append(row("2026-05-19","Netflix.com Los Gatos GBR","Netflix.com Los Gatos GBR","Subscriptions",7.46,0,4024.81))
          rows.append(row("2026-05-21","R Tester (Faster Payments)","R Tester (Faster Payments)","Transfers",0,93.98,4118.79))
          rows.append(row("2026-05-22","ACME LETTINGS (","ACME LETTINGS (Direct Debit)","Rent",1102.66,0,3016.13))
          rows.append(row("2026-05-22","Alex Sample & R Tester (P2P Payment)","Alex Sample & R Tester (P2P Payment)","Transfers",35.71,0,2980.42))
          rows.append(row("2026-05-23","Transfer to Pot","Pot","Transfers",58.55,0,2921.87))
          rows.append(row("2026-05-24","Deliveroo London GBR","Deliveroo London GBR","Food & Dining",20.58,0,2901.29))
          rows.append(row("2026-05-25","SAMPLETON ANIMAL CHARITY (","SAMPLETON ANIMAL CHARITY (Direct Debit)","Other",7.78,0,2893.51))
          rows.append(row("2026-05-27","SHELL FUEL London GBR","SHELL FUEL London GBR","Transport",43.45,0,2850.06))
          rows.append(row("2026-05-28","Apple.com/bill London GBR","Apple.com/bill London GBR","Shopping",2.74,0,2847.32))
          rows.append(row("2026-05-28","ALDI STORES London GBR","ALDI STORES London GBR","Groceries",37.34,0,2809.98))
          rows.append(row("2026-05-28","PURE GYM (","PURE GYM (Direct Debit)","Subscriptions",31.9,0,2778.08))
          rows.append(row("2026-06-01","JOHN LEWIS London GBR","JOHN LEWIS London GBR","Shopping",81.01,0,2697.07))
          rows.append(row("2026-06-01","PRET A MANGER London GBR","PRET A MANGER London GBR","Food & Dining",7.58,0,2689.49))
          rows.append(row("2026-06-02","ASOS.COM A45834895\\RETURNS\\LONDON\\SA1 0GB GBR","ASOS.COM A45834895\\RETURNS\\LONDON\\SA1 0GB GBR","Shopping",0,25.86,2715.35))
          rows.append(row("2026-06-03","NAZARA TECHNOLOGIES UK LIMITED (International","NAZARA TECHNOLOGIES UK LIMITED (International Transfer)","Income",0,7881.82,10597.17))
          rows.append(row("2026-06-06","LIDL GB London GBR","LIDL GB London GBR","Groceries",20.63,0,10576.54))
          rows.append(row("2026-06-07","Cash Withdrawal ATM London GBR","Cash Withdrawal ATM London GBR","Cash",91.08,0,10485.46))
          rows.append(row("2026-06-09","AQUA WATER SERVICES (","AQUA WATER SERVICES (Direct Debit)","Other",31.96,0,10453.5))
          rows.append(row("2026-06-10","COSTA COFFEE London GBR","COSTA COFFEE London GBR","Food & Dining",4.98,0,10448.52))
          rows.append(row("2026-06-10","ASOS.COM London GBR","ASOS.COM London GBR","Shopping",20.52,0,10428))
          rows.append(row("2026-06-11","BOOTS CHEMIST London GBR","BOOTS CHEMIST London GBR","Healthcare",8.49,0,10419.51))
          rows.append(row("2026-06-12","AVIVA INSURANCE (","AVIVA INSURANCE (Direct Debit)","Investment & Insurance",20.54,0,10398.97))
          rows.append(row("2026-06-14","SAMPLETON COUNCIL (","SAMPLETON COUNCIL (Direct Debit)","Utilities",133.94,0,10265.03))
          rows.append(row("2026-06-15","PENNY TECH LTD (Faster Payments)","PENNY TECH LTD (Faster Payments)","Transfers",0,2690.87,12955.9))
          out.append(LoadedDoc(name:"monzo.pdf",text:"",transactions:[],rows:rows,currency:"GBP",bank:nil,detectedIssuer:"Monzo",closingBalance:12955.9,isCard:false,analyzed:true)) }
        do { var rows:[TxnRow]=[]
          rows.append(row("2026-05-17","Coffee shop London","Coffee shop London","Food & Dining",7.59,0,1588.85))
          rows.append(row("2026-05-18","Refund Clothes store WILTSHIRE","Refund Clothes store WILTSHIRE","Income",0,19.14,1607.99))
          rows.append(row("2026-05-18","Card payment Paris FR","Card payment Paris FR","Other",38.23,0,1569.76))
          rows.append(row("2026-05-18","Interest","Interest","Income",0,2.69,1572.45))
          rows.append(row("2026-05-18","Supermarket MARLBOROUGH","Supermarket MARLBOROUGH","Groceries",32.93,0,1539.52))
          rows.append(row("2026-05-21","Direct Debit TV","Direct Debit TV","Other",31.9,0,1507.62))
          rows.append(row("2026-05-21","Standing Order to Savings account","Savings account","Transfers",92.11,0,1415.51))
          rows.append(row("2026-05-22","Salary","Salary","Income",0,2607.91,4023.42))
          rows.append(row("2026-05-24","Direct Debit returned - insufficient funds","Direct Debit returned - insufficient funds","Income",0,31.81,4055.23))
          rows.append(row("2026-05-25","Online donation","Online donation","Other",29.08,0,4026.15))
          rows.append(row("2026-05-25","Cash Machine wdl Nationwide","Cash Machine wdl Nationwide","Cash",90.66,0,3935.49))
          rows.append(row("2026-05-26","Online retailer","Online retailer","Shopping",36.52,0,3898.97))
          rows.append(row("2026-05-26","Direct Debit Council Tax","Direct Debit Council Tax","Utilities",170.42,0,3728.55))
          rows.append(row("2026-05-27","Restaurant London","Restaurant London","Food & Dining",40.37,0,3688.18))
          rows.append(row("2026-05-27","Toy store SWINDON 3635","Toy store SWINDON 3635","Other",34.37,0,3653.81))
          rows.append(row("2026-05-29","Supermarket SWINDON","Supermarket SWINDON","Groceries",10.54,0,3643.27))
          rows.append(row("2026-05-30","Films 1234567890","Films 1234567890","Other",13.05,0,3630.22))
          rows.append(row("2026-05-30","Petrol SWINDON 3635","Petrol SWINDON 3635","Transport",44.53,0,3585.69))
          rows.append(row("2026-06-01","Supermarket STRATTON","Supermarket STRATTON","Groceries",45.43,0,3540.26))
          rows.append(row("2026-06-02","Unarranged overdraft","Unarranged overdraft fee","Fees & Charges",6.33,0,3533.93))
          rows.append(row("2026-06-05","Direct Debit Broadband","Direct Debit Broadband","Utilities",42.13,0,3491.8))
          rows.append(row("2026-06-06","Music store","Music store","Other",7.94,0,3483.86))
          rows.append(row("2026-06-10","Direct Debit Nationwide C/Card","Direct Debit Nationwide C/Card","Other",184.05,0,3299.81))
          rows.append(row("2026-06-10","Lottery WATFORD","Lottery WATFORD","Other",6.01,0,3293.8))
          rows.append(row("2026-06-11","Standing Order to Joint account","Joint account","Transfers",547.16,0,2746.64))
          rows.append(row("2026-06-12","Direct Debit Gym","Direct Debit Gym","Subscriptions",24.49,0,2722.15))
          rows.append(row("2026-06-12","Cheque 000123","Cheque 000123","Other",38.53,0,2683.62))
          rows.append(row("2026-06-14","Transfer to Department store card","Department store card","Transfers",329.79,0,2353.83))
          rows.append(row("2026-06-15","Clothes store WILTSHIRE","Clothes store WILTSHIRE","Other",61.03,0,2292.8))
          out.append(LoadedDoc(name:"nationwide.pdf",text:"",transactions:[],rows:rows,currency:"GBP",bank:nil,detectedIssuer:"Nationwide",closingBalance:2292.8,isCard:false,analyzed:true)) }
        do { var rows:[TxnRow]=[]
          rows.append(row("2026-05-16","POS PRET A MANGER","POS PRET A MANGER","Food & Dining",5.91,0,4477.78))
          rows.append(row("2026-05-17","INT CREDIT","INT CREDIT INTEREST","Income",0,3.08,4480.86))
          rows.append(row("2026-05-18","D/D SPOTIFY AB","D/D SPOTIFY AB","Subscriptions",9.58,0,4471.28))
          rows.append(row("2026-05-19","POS TFL TRAVEL CHARGE","POS TFL TRAVEL CHARGE","Transport",2.45,0,4468.83))
          rows.append(row("2026-05-19","POS COSTA COFFEE","POS COSTA COFFEE","Food & Dining",4.59,0,4464.24))
          rows.append(row("2026-05-20","TFR TO SAMPLE HOLIDAY FUND","SAMPLE HOLIDAY FUND","Other",38.65,0,4425.59))
          rows.append(row("2026-05-21","D/D AVIVA","D/D AVIVA INSURANCE","Investment & Insurance",22.44,0,4403.15))
          rows.append(row("2026-05-21","D/D SAMPLETON COUNCIL C TAX","D/D SAMPLETON COUNCIL C TAX","Utilities",113.07,0,4290.08))
          rows.append(row("2026-05-21","POS TESCO STORES 2481","POS TESCO STORES 2481","Groceries",46.53,0,4243.55))
          rows.append(row("2026-05-22","D/D BRIGHT ENERGY LTD","D/D BRIGHT ENERGY LTD","Other",131.67,0,4111.88))
          rows.append(row("2026-05-23","POS ASOS.COM","POS ASOS.COM","Shopping",34.33,0,4077.55))
          rows.append(row("2026-05-25","S/O TO J SAMPLE SAVINGS","J SAMPLE SAVINGS","Other",272.21,0,3805.34))
          rows.append(row("2026-05-25","POS SHELL FUEL SAMPLETON","POS SHELL FUEL SAMPLETON","Transport",48.92,0,3756.42))
          rows.append(row("2026-05-25","D/D GLL-BETTER REPRESENTED","D/D GLL-BETTER REPRESENTED","Income",0,26.23,3782.65))
          rows.append(row("2026-05-26","POS SAINSBURYS S/MKT","POS SAINSBURYS S/MKT","Groceries",40.23,0,3742.42))
          rows.append(row("2026-05-26","D/D ACME LETTINGS","D/D ACME LETTINGS RENT","Rent",1022.09,0,2720.33))
          rows.append(row("2026-05-28","POS JOHN LEWIS","POS JOHN LEWIS","Shopping",113.25,0,2607.08))
          rows.append(row("2026-05-29","D/D NETFLIX.COM","D/D NETFLIX.COM","Subscriptions",14.11,0,2592.97))
          rows.append(row("2026-06-01","CHQ CHEQUE 000123","CHQ CHEQUE 000123","Other",132.72,0,2460.25))
          rows.append(row("2026-06-01","POS APPLE.COM/BILL","POS APPLE.COM/BILL","Shopping",2.58,0,2457.67))
          rows.append(row("2026-06-03","D/D VODAFONE UK","D/D VODAFONE UK","Utilities",39.06,0,2418.61))
          rows.append(row("2026-06-04","D/D FIBRENOW BROADBAND","D/D FIBRENOW BROADBAND","Utilities",40.43,0,2378.18))
          rows.append(row("2026-06-04","POS AMAZON.CO.UK","POS AMAZON.CO.UK","Shopping",51.44,0,2326.74))
          rows.append(row("2026-06-04","D/D AQUA WATER SERVICES","D/D AQUA WATER SERVICES","Other",43.05,0,2283.69))
          rows.append(row("2026-06-05","POS DELIVEROO","POS DELIVEROO","Food & Dining",21.88,0,2261.81))
          rows.append(row("2026-06-06","N-S TRN FEENON-STERLING TRANSACTION","N-S TRN FEENON-STERLING TRANSACTION FEE","Other",1.98,0,2259.83))
          rows.append(row("2026-06-07","POS ALDI STORES","POS ALDI STORES","Groceries",37.04,0,2222.79))
          rows.append(row("2026-06-09","D/D PURE GYM SAMPLETON","D/D PURE GYM SAMPLETON","Subscriptions",28.25,0,2194.54))
          rows.append(row("2026-06-12","ATM CASH SAMPLETON HIGH ST","ATM CASH SAMPLETON HIGH ST","Cash",72.2,0,2122.34))
          rows.append(row("2026-06-12","BGC PENNY TECH LTD","BGC PENNY TECH LTD SALARY","Income",0,3001.16,5123.5))
          rows.append(row("2026-06-13","D/D SAMPLETON ANIMAL CHARITY","D/D SAMPLETON ANIMAL CHARITY","Other",7.26,0,5116.24))
          rows.append(row("2026-06-13","CHG UNARRANGED OVERDRAFT","CHG UNARRANGED OVERDRAFT FEE","Fees & Charges",6.46,0,5109.78))
          rows.append(row("2026-06-15","TFR FROM R TESTER","R TESTER","Income",0,38.58,5148.36))
          out.append(LoadedDoc(name:"natwest.pdf",text:"",transactions:[],rows:rows,currency:"GBP",bank:nil,detectedIssuer:"NatWest",closingBalance:5148.36,isCard:false,analyzed:true)) }
        do { var rows:[TxnRow]=[]
          rows.append(row("2026-05-16","To Savings Vault (Savings)","Savings Vault (Savings)","Other",67.6,0,2814.52))
          rows.append(row("2026-05-20","Deliveroo (","Deliveroo (Card payment)","Food & Dining",17.51,0,2797.01))
          rows.append(row("2026-05-23","Costa Coffee (","Costa Coffee (Card payment)","Food & Dining",4.15,0,2792.86))
          rows.append(row("2026-05-24","Cashback","Cashback","Income",0,3.58,2796.44))
          rows.append(row("2026-05-26","ASOS Refund","ASOS Refund (Refund)","Income",0,18.42,2814.86))
          rows.append(row("2026-05-26","Spotify AB (","Spotify AB (Card payment)","Subscriptions",6.5,0,2808.36))
          rows.append(row("2026-06-01","Amazon (","Amazon (Card payment)","Shopping",9.28,0,2799.08))
          rows.append(row("2026-06-02","Top-up from ****1234 (Debit card top-up)","****1234 (Debit card top-up)","Income",0,1569.97,4369.05))
          rows.append(row("2026-06-02","Revolut Premium","Revolut Premium (Subscription)","Subscriptions",13.03,0,4356.02))
          rows.append(row("2026-06-02","SAMPLETON COUNCIL (","SAMPLETON COUNCIL (Direct Debit)","Utilities",157.3,0,4198.72))
          rows.append(row("2026-06-03","ACME LETTINGS (","ACME LETTINGS (Direct Debit)","Rent",1028.42,0,3170.3))
          rows.append(row("2026-06-04","Cash Withdrawal London GBR (ATM)","Cash Withdrawal London GBR (ATM)","Cash",74.09,0,3096.21))
          rows.append(row("2026-06-04","Aldi (","Aldi (Card payment)","Groceries",28.37,0,3067.84))
          rows.append(row("2026-06-05","Le Petit Bistro Paris (","Le Petit Bistro Paris (Card payment)","Food & Dining",39.78,0,3028.06))
          rows.append(row("2026-06-05","Tesco Stores (","Tesco Stores (Card payment)","Groceries",53.52,0,2974.54))
          rows.append(row("2026-06-05","Direct Debit returned - insufficient funds","Direct Debit returned - insufficient funds (Refund)","Income",0,31.49,3006.03))
          rows.append(row("2026-06-08","TFL Travel Charge (","TFL Travel Charge (Card payment)","Transport",7.88,0,2998.15))
          rows.append(row("2026-06-08","Apple.com/bill (","Apple.com/bill (Card payment)","Shopping",9.09,0,2989.06))
          rows.append(row("2026-06-08","Netflix.com (","Netflix.com (Card payment)","Subscriptions",15.16,0,2973.9))
          rows.append(row("2026-06-09","PENNY TECH LTD","PENNY TECH LTD (Transfer)","Income",0,2500.13,5474.03))
          rows.append(row("2026-06-09","ASOS (","ASOS (Card payment)","Shopping",22.25,0,5451.78))
          rows.append(row("2026-06-10","From R Tester","R Tester (Transfer)","Income",0,55.29,5507.07))
          rows.append(row("2026-06-10","John Lewis (","John Lewis (Card payment)","Shopping",32.37,0,5474.7))
          rows.append(row("2026-06-11","Shell Fuel (","Shell Fuel (Card payment)","Transport",46.7,0,5428))
          rows.append(row("2026-06-12","From Savings Vault (Savings)","Savings Vault (Savings)","Income",0,120.52,5548.52))
          rows.append(row("2026-06-12","Sainsbury's (","Sainsbury's (Card payment)","Groceries",52.58,0,5495.94))
          rows.append(row("2026-06-12","Nando's (","Nando's (Card payment)","Food & Dining",15.45,0,5480.49))
          rows.append(row("2026-06-13","To R Tester","R Tester (Transfer)","Other",138.43,0,5342.06))
          rows.append(row("2026-06-14","To J Sample (","J Sample (Standing Order)","Transfers",56.79,0,5285.27))
          rows.append(row("2026-06-15","Boots Chemist (","Boots Chemist (Card payment)","Healthcare",15.35,0,5269.92))
          out.append(LoadedDoc(name:"revolut.pdf",text:"",transactions:[],rows:rows,currency:"GBP",bank:nil,detectedIssuer:"Revolut",closingBalance:5269.92,isCard:false,analyzed:true)) }
        return out
    }
}

// End-to-end validation of the cross-document analytics against the REAL parsed
// sample statements (SampleGroundTruth, auto-generated from the six PDFs). These
// assert the values that reconcile with the actual PDF data — which is authoritative.
// Where the user's ChatGPT-derived spec disagrees (e.g. salary total £18,603.17),
// the reconciled figure (£18,413.30) is used, because ChatGPT's number can't be
// reproduced from any combination of the parsed transactions.

@MainActor
final class EndToEndSpecTests: XCTestCase {

    private func model() -> AppModel {
        let m = AppModel()
        m.restoreTask?.cancel()
        m.loadForTesting(SampleGroundTruth.docs)
        m.recomputeSummary()
        return m
    }

    func testStatementCount() {
        XCTAssertEqual(model().crossDocumentAnswer("How many statements were uploaded?"),
                       "**You uploaded 6 statements.**")
    }

    func testPerStatementCounts() {
        let m = model()
        let expect = [("American Express", 25), ("Barclays", 24), ("Monzo", 32),
                      ("Nationwide", 29), ("NatWest", 33), ("Revolut", 30)]
        for (name, n) in expect {
            XCTAssertEqual(m.crossDocumentAnswer("How many \(name) transactions?"),
                           "**\(name) has \(n) transactions.**", "count for \(name)")
        }
    }

    func testMostTransactions() {
        XCTAssertEqual(model().crossDocumentAnswer("Which statement contains the most transactions?"),
                       "**NatWest has the most transactions: 33.**")
    }

    func testHighestLowestClosingBalance() {
        let m = model()
        XCTAssertEqual(m.crossDocumentAnswer("Which statement has the highest closing balance?"),
                       "**Monzo has the highest closing balance: £12,955.90.**")
        XCTAssertEqual(m.crossDocumentAnswer("Which statement has the lowest closing balance?"),
                       "**American Express has the lowest closing balance: £629.54.**")
    }

    func testHighestMoneyInOut() {
        let m = model()
        XCTAssertEqual(m.crossDocumentAnswer("Which account has the highest total money in?"),
                       "**Monzo has the most money in: £10,692.53.**")
        XCTAssertEqual(m.crossDocumentAnswer("Which account has the highest total money out?"),
                       "**NatWest has the most money out: £2,404.38.**")
    }

    func testLargestCreditAndDebit() {
        let m = model()
        let c = m.crossDocumentAnswer("Largest credit?")
        XCTAssertNotNil(c); XCTAssertTrue(c!.contains("£7,881.82") && c!.contains("Monzo"), "got: \(c ?? "nil")")
        let db = m.crossDocumentAnswer("Largest debit?")
        XCTAssertNotNil(db); XCTAssertTrue(db!.contains("£1,102.66") && db!.contains("Monzo")
                                           && db!.uppercased().contains("ACME"), "got: \(db ?? "nil")")
    }

    func testTopCategory() {
        let a = model().crossDocumentAnswer("Which category has the highest spending?")
        XCTAssertNotNil(a); XCTAssertTrue(a!.contains("Rent"), "got: \(a ?? "nil")")
    }

    func testHighestSalaryBank() {
        XCTAssertEqual(model().crossDocumentAnswer("Which bank received the highest salary?"),
                       "**Monzo received the highest salary: £7,881.82.**")
    }

    func testSalaryCountAndTotal() {
        let m = model()
        let cnt = m.crossDocumentAnswer("How many salary transactions?")
        XCTAssertNotNil(cnt); XCTAssertTrue(cnt!.contains("5 salary"), "spec count is 5; got: \(cnt ?? "nil")")
        let tot = m.crossDocumentAnswer("Total salary received?")
        // Reconciled from the actual PDFs (one primary salary per current account).
        XCTAssertNotNil(tot); XCTAssertTrue(tot!.contains("£18,413.30"),
                        "reconciled total is £18,413.30 (spec's £18,603.17 is a ChatGPT error); got: \(tot ?? "nil")")
    }

    func testHighValueOver500() {
        let a = model().crossDocumentAnswer("Show every transaction above £500.")
        XCTAssertNotNil(a); XCTAssertTrue(a!.contains("13 transactions above £500"), "got first line: \(a?.prefix(60) ?? "")")
    }

    func testWhichStatementsContainSalary() {
        let a = model().documentContentAnswer("Which statements contain salary transactions?")
        XCTAssertNotNil(a)
        for name in ["Barclays", "Monzo", "Nationwide", "NatWest", "Revolut"] {
            XCTAssertTrue(a!.contains(name), "\(name) should be listed; got: \(a ?? "nil")")
        }
        XCTAssertFalse(a!.contains("American Express"), "the Amex card has no salary")
    }
}

/// Guards the pure parsing/normalization half of the on-device dynamic
/// categorizer (`PennyLLM.categorizeMerchants`): reconciling a small local
/// model's imperfect JSON back onto the input descriptors, and taming
/// model-coined category names so the taxonomy can grow without fragmenting.
/// No MLX inference runs here — these are the deterministic statics only.
final class LocalCategorizerParsingTests: XCTestCase {

    private let seeds = ["Groceries", "Food & Dining", "Transport", "Other"]

    func testParsesCleanVerdicts() {
        let raw = """
        [{"merchant": "LATYMERS - HAMMERSMITH LONDON", "category": "Food & Dining", "confidence": 0.9},
         {"merchant": "NAYAXAU*DATATEK PAYMENT LONDON", "category": "Vending", "confidence": 0.8}]
        """
        let out = PennyLLM.parseMerchantCategories(
            from: raw,
            descriptors: ["LATYMERS - HAMMERSMITH LONDON", "NAYAXAU*DATATEK PAYMENT LONDON"],
            seeds: seeds)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], MerchantCategory(merchant: "LATYMERS - HAMMERSMITH LONDON",
                                                category: "Food & Dining", confidence: 0.9))
        XCTAssertEqual(out[1].category, "Vending")   // a model-coined category survives
    }

    func testIgnoresProseAndCodeFences() {
        let raw = """
        Here are the results:
        ```json
        [{"merchant": "PET SUPPLIES PLUS", "category": "pet care", "confidence": 1}]
        ```
        """
        let out = PennyLLM.parseMerchantCategories(from: raw, descriptors: ["PET SUPPLIES PLUS"], seeds: seeds)
        XCTAssertEqual(out, [MerchantCategory(merchant: "PET SUPPLIES PLUS", category: "Pet Care", confidence: 1)])
    }

    func testMangledEchoMatchesCaseAndPunctuationInsensitively() {
        let raw = #"[{"merchant": "dojo the craft beer co london", "category": "Food & Dining", "confidence": 0.95}]"#
        let out = PennyLLM.parseMerchantCategories(
            from: raw, descriptors: ["DOJO*THE CRAFT BEER CO LONDON", "SOMETHING ELSE"], seeds: seeds)
        XCTAssertEqual(out.map(\.merchant), ["DOJO*THE CRAFT BEER CO LONDON"])
    }

    func testPositionalFallbackWhenEchoUnrecognizable() {
        // The model rewrote both echoes beyond recognition, but returned exactly
        // one verdict per input — position pairs them back up.
        let raw = """
        [{"merchant": "a coffee shop", "category": "Food & Dining", "confidence": 0.9},
         {"merchant": "a taxi firm", "category": "Transport", "confidence": 0.9}]
        """
        let out = PennyLLM.parseMerchantCategories(from: raw, descriptors: ["XK-291", "ZZTOP LTD"], seeds: seeds)
        XCTAssertEqual(out.map(\.merchant), ["XK-291", "ZZTOP LTD"])
        XCTAssertEqual(out.map(\.category), ["Food & Dining", "Transport"])
    }

    func testConfidenceMissingStringAndOutOfRange() {
        let raw = """
        [{"merchant": "A", "category": "Transport"},
         {"merchant": "B", "category": "Transport", "confidence": "0.8"},
         {"merchant": "C", "category": "Transport", "confidence": 7}]
        """
        let out = PennyLLM.parseMerchantCategories(from: raw, descriptors: ["A", "B", "C"], seeds: seeds)
        XCTAssertEqual(out.map(\.confidence), [0.75, 0.8, 1.0])
    }

    func testGarbageYieldsEmpty() {
        XCTAssertEqual(PennyLLM.parseMerchantCategories(from: "I cannot help with that.",
                                                        descriptors: ["A"], seeds: seeds), [])
        XCTAssertEqual(PennyLLM.parseMerchantCategories(from: "[not json at all",
                                                        descriptors: ["A"], seeds: seeds), [])
    }

    func testNormalizeSnapsToSeedSpelling() {
        XCTAssertEqual(PennyLLM.normalizeCategory("food & dining", seeds: seeds), "Food & Dining")
        XCTAssertEqual(PennyLLM.normalizeCategory("  \"TRANSPORT\". ", seeds: seeds), "Transport")
    }

    func testNormalizeTitleCasesNewNamesAndKeepsConnectorsLowercase() {
        XCTAssertEqual(PennyLLM.normalizeCategory("home improvement", seeds: seeds), "Home Improvement")
        XCTAssertEqual(PennyLLM.normalizeCategory("arts and crafts", seeds: seeds), "Arts and Crafts")
    }

    func testNormalizeRejectsEmptyAndRambling() {
        XCTAssertEqual(PennyLLM.normalizeCategory("", seeds: seeds), "Other")
        XCTAssertEqual(PennyLLM.normalizeCategory("This merchant appears to be a restaurant",
                                                  seeds: seeds), "Other")
        XCTAssertEqual(PennyLLM.normalizeCategory("Extremely Long Category Name Indeed",
                                                  seeds: seeds), "Other")
    }
}
