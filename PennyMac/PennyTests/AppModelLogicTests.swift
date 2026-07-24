//
//  AppModelLogicTests.swift
//  PennyTests
//
//  Guards AppModel's deterministic app-layer logic (AppModel.swift): the Today-
//  panel sums in recomputeSummary (debits = spent, "Payments" credits excluded
//  from income, multi-account balances with credit-card balances subtracted,
//  currency preference order), LoadedDoc's latestBalance and sidebar displayName
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
                     balance: Double? = nil) -> TxnRow {
        TxnRow(txnDate: date, month: String(date.prefix(7)),
               year: Int(date.prefix(4)) ?? 2024,
               monthNo: Int(date.dropFirst(5).prefix(2)) ?? 1,
               day: Int(date.suffix(2)) ?? 1,
               descr: desc, merchant: desc, category: category,
               debit: debit, credit: credit, balance: balance,
               currency: "GBP", seq: seq)
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
    private func freshModel() -> AppModel {
        try? FileManager.default.removeItem(at: historyFileURL)
        let m = AppModel()
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
        m.docs = [makeDoc(name: "bank.pdf", txns: [
            txn(desc: "TESCO GROCERY", debit: 100, category: "Groceries"),
            txn(desc: "AMAZON MARKETPLACE", debit: 49.5),                 // nil category → keyword fallback
            txn(desc: "ACME PAYROLL", credit: 500, category: "Income"),
            txn(desc: "CARD PAYMENT RECEIVED", credit: 200, category: "Payments"),
        ], currency: "GBP")]
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
        m.docs = [bank, card]
        m.recomputeSummary()
        XCTAssertEqual(m.summary.balance ?? .nan, 750, accuracy: 0.001,
                       "bank 1000 minus card 250 owed = 750")
        XCTAssertEqual(m.summary.count, 3)
    }

    func testSummaryBalanceNilWhenNoDocHasOne() {
        let m = freshModel()
        m.docs = [makeDoc(name: "a.pdf", txns: [txn(debit: 5)]),
                  makeDoc(name: "b.pdf", txns: [txn(credit: 9)])]
        m.recomputeSummary()
        XCTAssertNil(m.summary.balance,
                     "docs without any latestBalance must yield nil (dash in UI), not 0")
    }

    func testSummaryScopedToSelectedDocs() {
        let m = freshModel()
        m.docs = [makeDoc(name: "a.pdf", txns: [txn(debit: 10)], currency: "GBP"),
                  makeDoc(name: "b.pdf", txns: [txn(debit: 90)], currency: "GBP")]
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

    // MARK: - currency preference order

    func testCurrencyParserDetectedNonINRWins() {
        let m = freshModel()
        // Parser said USD for doc 2 — that beats any symbol sniffing, even though
        // the text is full of £. Empty-string currencies are skipped.
        m.docs = [makeDoc(name: "a.pdf", text: "£ £ £", currency: ""),
                  makeDoc(name: "b.pdf", text: "£100 spent", currency: "USD")]
        m.recomputeSummary()
        XCTAssertEqual(m.summary.currency, "USD",
                       "first parser-detected non-INR, non-empty currency is authoritative")
    }

    func testCurrencySniffedFromTextWhenParserSaysINR() {
        let m = freshModel()
        m.docs = [makeDoc(name: "a.pdf", text: "Opening balance £1,022.10", currency: "INR")]
        m.recomputeSummary()
        XCTAssertEqual(m.summary.currency, "GBP", "£ in the text → GBP when parser fell back to INR")

        m.docs = [makeDoc(name: "b.pdf", text: "Charge of €10 then a fee of $5", currency: "INR")]
        m.recomputeSummary()
        XCTAssertEqual(m.summary.currency, "EUR", "sniff order prefers € over $")

        m.docs = [makeDoc(name: "c.pdf", text: "INR 500 credited, card charge $12", currency: "INR")]
        m.recomputeSummary()
        XCTAssertEqual(m.summary.currency, "INR", "explicit INR text outranks $")
    }

    func testCurrencyFallsBackToParserValue() {
        let m = freshModel()
        m.docs = [makeDoc(name: "a.pdf", text: "no symbols here at all", currency: "INR")]
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
        // 4. non-bank-like parser name (filename-derived junk) → filename
        XCTAssertEqual(makeDoc(name: "Sample_Statement_acct.pdf", text: "no brands here",
                               bank: "Sample").displayName,
                       "Sample_Statement_acct.pdf")
        // 5. no bank at all → filename
        XCTAssertEqual(makeDoc(name: "plain.pdf", text: "no brands here").displayName,
                       "plain.pdf")
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
        XCTAssertTrue(md.hasSuffix("_Showing first 200 of 205._"),
                      "cap footer missing or wrong; got tail: …\(md.suffix(40))")

        let blocks = MD.parse(md)
        XCTAssertEqual(blocks.count, 2, "expected table + footer paragraph")
        guard let t = mdTable(blocks.first) else { return }
        XCTAssertEqual(t.headers, ["#", "Date", "Description", "Debit", "Credit", "Balance"])
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

        // Exact full row: index, date, desc, formatted debit, empty credit, balance.
        let lines = md.components(separatedBy: "\n")
        XCTAssertEqual(lines[2], "| 1 | 2024-01-05 | TESCO | £1,234.50 |  | £2,000.00 |")

        guard let t = mdTable(MD.parse(md).first) else { return }
        XCTAssertEqual(t.rows[1][2], "COFFEE/SHOP/LTD",
                       "pipes in descriptions must become slashes or they break the table")
        XCTAssertEqual(t.rows[2][2], String(repeating: "D", count: 39) + "…",
                       ">40-char description truncated to 39 chars + ellipsis")
        XCTAssertEqual(t.rows[3][2], String(repeating: "E", count: 40),
                       "exactly 40 chars is NOT truncated")
        XCTAssertEqual(t.aligns, [.trailing, .leading, .leading, .trailing, .trailing, .trailing],
                       "money/index columns right-align, date/description lead")
    }

    func testTransactionsMarkdownUsesIndianGroupingForINR() {
        let md = AppModel.transactionsMarkdown([txn(desc: "BIG SPEND", debit: 123456.78)],
                                               currency: "INR")
        guard let t = mdTable(MD.parse(md).first) else { return }
        XCTAssertEqual(t.rows[0][3], "₹1,23,456.78", "INR uses lakh/crore grouping")
    }

    // MARK: - send() deterministic routing (LEDGER / ANALYTICS only — the
    // open-ended path would hit MLX because --uitest-model-ready is not set
    // for hosted tests, so it is deliberately not exercised here).

    private func modelWithThreeTxns() -> AppModel {
        let m = freshModel()
        m.docs = [makeDoc(name: "bank.pdf",
                          txns: [txn(desc: "ALPHA", debit: 10),
                                 txn(desc: "BRAVO", debit: 20),
                                 txn(desc: "CHARLIE", credit: 5)],
                          rows: [row(1, desc: "ALPHA", debit: 10),
                                 row(2, desc: "BRAVO", debit: 20),
                                 row(3, desc: "CHARLIE", category: "Income", credit: 5)],
                          currency: "GBP")]
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
        m.docs = [makeDoc(name: "one.pdf", txns: [txn(debit: 5)], rows: [row(1, debit: 5)],
                          currency: "GBP")]
        m.recomputeSummary()
        m.send("list all transactions")
        XCTAssertEqual(m.messages.last?.engine, "LEDGER")
        XCTAssertTrue(m.messages.last?.content.hasPrefix("Here is all 1 transaction on record:") == true,
                      "singular verb/noun expected; got: \(m.messages.last?.content.prefix(60) ?? "")")
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

    func testSendBalanceQuestionAnswersMultiAccountAnalytics() {
        let m = freshModel()
        let bank = makeDoc(name: "bank.pdf",
                           txns: [txn(debit: 10, balance: 1000)],
                           rows: [row(1, debit: 10, balance: 1000)],
                           currency: "GBP")
        let card = makeDoc(name: "card.pdf",
                           txns: [txn(debit: 250)],
                           currency: "GBP", closingBalance: 250, isCard: true)
        m.docs = [bank, card]
        m.recomputeSummary()
        m.send("what is my balance?")
        let reply = m.messages.last
        XCTAssertEqual(reply?.engine, "ANALYTICS")
        XCTAssertTrue(reply?.content.contains("£750.00") == true,
                      "bank 1000 − card 250 owed; got: \(reply?.content ?? "nil")")
        XCTAssertTrue(reply?.content.contains("owed (card)") == true,
                      "card line must be marked as owed; got: \(reply?.content ?? "nil")")
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
}
