import XCTest

/// Guards the dashboard shell end-to-end over a real deterministic import of
/// finquery/contract/fixtures/Coop_Demo_Statement.pdf: the sidebar account row
/// (issuer name + latest balance), the PENNY'S BRAIN statement/transaction
/// stats, the Today panel's deterministically-summed figures, all three chat
/// engines (LEDGER full-table answers, ANALYTICS router answers, the stubbed
/// MLX fallback), account-selection toggling, the quick-start cards, the
/// offline/online privacy toggle, and the "switch" → model-picker → continue
/// round-trip. Every money/count assertion is pinned to ground truth produced
/// by `penny-conformance rows-json` / `query` on the same PDF — 37 rows, GBP,
/// Σdebits 1948.55 over 29 debit rows, Σcredits 3498.74, net 1550.19, last
/// running balance 4000.19 — never invented.
final class DashboardUITests: PennyUITestCase {

    // MARK: - Ground truth (penny-conformance on Coop_Demo_Statement.pdf)

    private static let fixture    = "Coop_Demo_Statement.pdf"
    private static let statusLine = "37 transactions · on-device"   // Today header after import
    private static let issuer     = "Co-operative Bank"             // letterhead-derived display name
    private static let balanceStr = "£4,000.19"                     // last running balance, Money.format GBP
    private static let spentStr   = "£1,948.55"                     // Σ debits
    private static let netStr     = "£1,550.19"                     // 3,498.74 credits − 1,948.55 debits
    private static let debitRows  = 29                              // rows with debit > 0

    // MARK: - helpers

    /// First element of `query` whose OWN label — or AX value, where SwiftUI
    /// surfaces some Texts' strings — contains `s` (no ancestor bleed-through,
    /// unlike `containing(_:)`).
    private func labeled(_ query: XCUIElementQuery, containing s: String) -> XCUIElement {
        query.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", s, s)).firstMatch
    }

    /// Element (any type) carrying an accessibility identifier — used for the
    /// `.accessibilityElement(children: .combine)` bubbles and Today cards.
    private func byID(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", id)).firstMatch
    }

    /// Launch on the dashboard with the Coop fixture and wait until the async
    /// import has landed (proven by the exact ground-truth status line).
    private func launchWithCoop() throws -> XCUIApplication {
        let app = try launchPenny(modelReady: true, dashboard: true, importFixture: Self.fixture)
        waitFor(app.staticTexts[Self.statusLine], timeout: 15,
                "Import never completed — expected Today status line \"\(Self.statusLine)\"")
        return app
    }

    /// Type `q` into the chat input and send it.
    private func ask(_ app: XCUIApplication, _ q: String) {
        let input = waitFor(app.textFields["chat.input"], timeout: 10, "chat.input text field missing")
        typeInto(input, q)
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.isEnabled, "chat.send should enable once the draft is non-empty")
        send.click()
    }

    // MARK: - 1. import lands everywhere

    func testImportPopulatesSidebarBrainAndTodayPanel() throws {
        let app = try launchWithCoop()

        // Sidebar ACCOUNTS section gained a row named from the statement letterhead,
        // showing the account's latest running balance.
        XCTAssertTrue(app.staticTexts["ACCOUNTS"].exists, "sidebar ACCOUNTS section header missing")
        let row = waitFor(labeled(app.buttons, containing: Self.issuer), timeout: 10,
                          "no sidebar account row named \"\(Self.issuer)\" after import")
        XCTAssertTrue(row.label.contains(Self.balanceStr),
                      "account row should show latest balance \(Self.balanceStr); label was \"\(row.label)\"")

        // PENNY'S BRAIN stats: Statements 1, Transactions 37 (real counts, not placeholders).
        XCTAssertTrue(app.staticTexts["PENNY'S BRAIN"].exists, "PENNY'S BRAIN panel missing")
        XCTAssertTrue(app.staticTexts["Statements"].exists, "Statements stat row missing")
        XCTAssertTrue(app.staticTexts["1"].firstMatch.exists,
                      "Statements count '1' missing from the brain panel")
        XCTAssertTrue(app.staticTexts["Transactions"].exists, "Transactions stat row missing")
        XCTAssertTrue(app.staticTexts["37"].firstMatch.exists,
                      "Transactions count '37' (ground truth) missing from the brain panel")

        // Today panel: accounts 1, and real money figures — not the '—' placeholder.
        let accounts = waitFor(byID(app, "today.accounts"), timeout: 10, "today.accounts card missing")
        XCTAssertTrue(accounts.label.contains("1"),
                      "today.accounts should show 1; label was \"\(accounts.label)\"")
        XCTAssertTrue(accounts.label.contains("statement loaded"),
                      "today.accounts sub should be singular 'statement loaded' for one doc; label was \"\(accounts.label)\"")

        let balance = byID(app, "today.balance")
        XCTAssertTrue(balance.exists, "today.balance card missing")
        XCTAssertTrue(balance.label.contains(Self.balanceStr),
                      "today.balance should show \(Self.balanceStr); label was \"\(balance.label)\"")
        XCTAssertFalse(balance.label.contains("—"),
                       "today.balance must be a real figure after import, not '—'")

        let spent = byID(app, "today.spent")
        XCTAssertTrue(spent.label.contains(Self.spentStr),
                      "today.spent should be Σdebits \(Self.spentStr); label was \"\(spent.label)\"")
        let net = byID(app, "today.net")
        XCTAssertTrue(net.label.contains(Self.netStr),
                      "today.net should be income−spend \(Self.netStr); label was \"\(net.label)\"")
    }

    // MARK: - 2. deterministic LEDGER table answer

    func testLedgerEngineRendersFullTransactionTable() throws {
        let app = try launchWithCoop()
        ask(app, "show me all the transactions in a table")

        waitFor(labeled(app.staticTexts, containing: "LEDGER ENGINE"), timeout: 10,
                "table question should be answered by the LEDGER engine (badge missing)")
        let bubble = waitFor(byID(app, "chat.msg.assistant"), timeout: 10, "no assistant bubble")
        let label = bubble.label

        XCTAssertTrue(label.contains("all 37 transactions on record"),
                      "row-count phrase should match ground truth (37); got \"\(label.prefix(120))…\"")
        XCTAssertTrue(label.contains("Description"), "table header row missing from the rendered grid")
        XCTAssertTrue(label.contains("2026-06-01"), "first transaction date missing from the table")
        XCTAssertTrue(label.contains("TESCO STORES 2431 PATNA"), "first row description missing")
        XCTAssertTrue(label.contains("£42.15"), "first row debit £42.15 missing")
        XCTAssertTrue(label.contains("£2,407.85"), "first row running balance £2,407.85 missing")
        XCTAssertTrue(label.contains("STANDING ORDER - CAR INSURANCE"),
                      "last (37th) row missing — table appears truncated")
        // 43-char description must be clipped at 39 chars + ellipsis in table cells.
        XCTAssertTrue(label.contains("CASH WITHDRAWAL - CO-OPERATIVE BANK ATM…"),
                      "long description should be truncated to 39 chars + '…'")
        XCTAssertFalse(label.contains("Showing first"),
                       "37 rows are under the 200-row cap — no 'Showing first N' footer expected")
    }

    // MARK: - 3. deterministic ANALYTICS router answer

    func testAnalyticsEngineAnswersTotalSpend() throws {
        let app = try launchWithCoop()
        ask(app, "how much did i spend in total?")

        waitFor(labeled(app.staticTexts, containing: "ANALYTICS ENGINE"), timeout: 10,
                "total-spend question should be answered by the ANALYTICS engine (badge missing)")
        let bubble = waitFor(byID(app, "chat.msg.assistant"), timeout: 10, "no assistant bubble")
        XCTAssertTrue(bubble.label.contains("1,948.55"),
                      "answer should quote ground-truth Σdebits 1,948.55; got \"\(bubble.label)\"")
        XCTAssertTrue(bubble.label.contains("\(Self.debitRows) transactions"),
                      "answer should count \(Self.debitRows) debit transactions; got \"\(bubble.label)\"")
        XCTAssertFalse(bubble.label.contains("PENNY-STUB-REPLY"),
                       "a factual total must never fall through to the MLX stub")
    }

    // MARK: - 4. open-ended question → stubbed MLX fallback

    func testOpenEndedQuestionFallsBackToStubbedMLX() throws {
        let app = try launchWithCoop()
        // NOTE: verified with `penny-conformance query` that this question is NOT
        // matched by the deterministic router (unlike e.g. "…my spending habits?",
        // which the router's total-spend catch-all intercepts).
        ask(app, "why am i broke?")

        waitFor(labeled(app.staticTexts, containing: "MLX ENGINE"), timeout: 10,
                "open-ended question should fall back to the MLX engine (badge missing)")
        let bubble = waitFor(byID(app, "chat.msg.assistant"), timeout: 10, "no assistant bubble")
        XCTAssertTrue(bubble.label.contains("PENNY-STUB-REPLY"),
                      "test-mode MLX fallback should answer with the deterministic stub; got \"\(bubble.label)\"")
        XCTAssertTrue(bubble.label.contains("grounded on 37 rows"),
                      "stub should be grounded on all 37 parsed rows; got \"\(bubble.label)\"")
        XCTAssertTrue(bubble.label.contains("why am i broke?"),
                      "stub should echo the question; got \"\(bubble.label)\"")
        XCTAssertFalse(labeled(app.staticTexts, containing: "ANALYTICS ENGINE").exists,
                       "no ANALYTICS badge expected for an advisory question")
    }

    // MARK: - 5. account-row selection toggling drives the Today panel

    func testAccountRowTogglesSelectionAndTodayFigures() throws {
        let app = try launchWithCoop()
        let row = waitFor(labeled(app.buttons, containing: Self.issuer), timeout: 10,
                          "sidebar account row missing")
        let spent = byID(app, "today.spent")
        let net = byID(app, "today.net")
        waitUntil(NSPredicate(format: "label CONTAINS %@", Self.spentStr), on: spent, timeout: 10)

        // Deselect the only account → no data in scope → spent/net show '—'.
        row.click()
        waitUntil(NSPredicate(format: "label CONTAINS %@", "—"), on: spent, timeout: 5)
        XCTAssertTrue(net.label.contains("—"),
                      "today.net should be '—' with the only account deselected; label was \"\(net.label)\"")

        // Reselect → figures return.
        row.click()
        waitUntil(NSPredicate(format: "label CONTAINS %@", Self.spentStr), on: spent, timeout: 5)
        XCTAssertTrue(net.label.contains(Self.netStr),
                      "today.net should return to \(Self.netStr) on reselect; label was \"\(net.label)\"")
    }

    // MARK: - 6. quick-start cards

    func testStarterCardsVisibleAndSendMappedPrompt() throws {
        let app = try launchWithCoop()

        for title in ["Roast me", "Banish zombie subs", "Spending patterns", "Compound my savings"] {
            XCTAssertTrue(labeled(app.buttons, containing: title).exists,
                          "starter card \"\(title)\" missing from the empty chat")
        }

        // Click the Roast card (matched by its unique subtitle, so the sidebar's
        // own "Roast me" row can't be hit instead).
        let card = labeled(app.buttons, containing: "Brutal honesty")
        XCTAssertTrue(card.exists, "Roast starter card (subtitle 'Brutal honesty…') missing")
        card.click()

        let user = waitFor(byID(app, "chat.msg.user"), timeout: 5, "no user bubble after clicking a starter card")
        XCTAssertTrue(user.label.contains("roast my spending"),
                      "'Roast me' should send its mapped prompt 'roast my spending'; got \"\(user.label)\"")
        let assistant = waitFor(byID(app, "chat.msg.assistant"), timeout: 10,
                                "no assistant reply to the quick action")
        XCTAssertFalse(assistant.label.isEmpty, "assistant reply should have content")
        XCTAssertFalse(labeled(app.buttons, containing: "Brutal honesty").exists,
                       "starter cards should disappear once the conversation starts")
    }

    // MARK: - 7. offline / online toggle

    func testOfflineToggleFlipsPrivacyLabel() throws {
        let app = try launchPenny(modelReady: true, dashboard: true)
        waitFor(app.staticTexts["OFFLINE MODE"], timeout: 10, "sidebar should start in OFFLINE MODE")

        let sw = app.switches.firstMatch
        let toggle = sw.exists ? sw : app.checkBoxes.firstMatch
        XCTAssertTrue(toggle.exists, "offline toggle control not found (neither switch nor checkbox)")

        toggle.click()
        waitFor(app.staticTexts["ONLINE WHEN NEEDED"], timeout: 5,
                "toggling should flip the label to ONLINE WHEN NEEDED")
        XCTAssertFalse(app.staticTexts["OFFLINE MODE"].exists,
                       "OFFLINE MODE label should be gone while online")

        toggle.click()
        waitFor(app.staticTexts["OFFLINE MODE"], timeout: 5,
                "toggling back should restore OFFLINE MODE")
    }

    // MARK: - 8. switch → model picker → ready-state continue

    func testSwitchOpensModelPickerAndContinueReturns() throws {
        let app = try launchPenny(modelReady: true, dashboard: true)
        waitFor(app.textFields["chat.input"], timeout: 10, "dashboard did not appear")

        let switchBtn = waitFor(labeled(app.buttons, containing: "switch"), timeout: 10,
                                "PENNY'S BRAIN 'switch' affordance missing")
        switchBtn.click()
        waitFor(app.staticTexts["Choose your AI model"], timeout: 10, "model picker did not open")

        // The test-ready selected model's card offers "In use ✓ · Continue →".
        let cont = waitFor(labeled(app.buttons, containing: "Continue"), timeout: 10,
                           "ready-state continue button missing from the selected model card")
        cont.click()
        waitFor(app.textFields["chat.input"], timeout: 10,
                "continue should return to the dashboard chat")
    }
}
