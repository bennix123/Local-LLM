import XCTest

/// Guards the chat-history lifecycle over a real imported statement
/// (Coop_Demo_Statement.pdf, 37 rows — penny-conformance ground truth):
/// "✨ New chat" archives the live transcript into a History session titled by
/// the first user message; the History view lists the session card (date/count
/// meta, "open →", ×) plus "ASK ME AGAIN" follow-up suggestions derived from
/// the title; clicking a card restores both bubbles into the live chat and
/// empties History; × forgets a session (empty state "no past chats yet");
/// and the header's "today's chat →" pill navigates back to the chat column.
/// Test mode persists history to a per-process temp file, so every launch
/// starts with zero past chats.
final class HistoryUITests: PennyUITestCase {

    // MARK: - Ground truth / fixtures

    private static let fixture    = "Coop_Demo_Statement.pdf"
    private static let statusLine = "37 transactions · on-device"
    /// The one question each flow archives — routed by the deterministic
    /// ANALYTICS engine (verified via `penny-conformance query`:
    /// Σdebits 1948.55 across 29 debit rows).
    private static let question   = "how much did i spend in total?"

    // MARK: - helpers

    private func labeled(_ query: XCUIElementQuery, containing s: String) -> XCUIElement {
        query.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", s, s)).firstMatch
    }

    private func byID(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", id)).firstMatch
    }

    private func launchWithCoop() throws -> XCUIApplication {
        let app = try launchPenny(modelReady: true, dashboard: true, importFixture: Self.fixture)
        waitFor(app.staticTexts[Self.statusLine], timeout: 15,
                "Import never completed — expected Today status line \"\(Self.statusLine)\"")
        return app
    }

    private func ask(_ app: XCUIApplication, _ q: String) {
        let input = waitFor(app.textFields["chat.input"], timeout: 10, "chat.input text field missing")
        typeInto(input, q)
        app.buttons["chat.send"].click()
    }

    /// Ask the ANALYTICS question, then archive the conversation via the
    /// sidebar's "✨ New chat" (leaving exactly one History session).
    private func archiveOneChat(_ app: XCUIApplication) {
        ask(app, Self.question)
        waitFor(labeled(app.staticTexts, containing: "ANALYTICS ENGINE"), timeout: 10,
                "the archived question should get a deterministic ANALYTICS answer")
        labeled(app.buttons, containing: "New chat").click()
        // Archiving clears the live transcript → the empty-state greeting returns.
        waitFor(labeled(app.staticTexts, containing: "hey, i'm all yours"), timeout: 5,
                "New chat should clear the transcript back to the empty state")
    }

    private func openHistory(_ app: XCUIApplication) {
        labeled(app.buttons, containing: "History").click()
    }

    // MARK: - 1. archive → session card + suggestions

    func testNewChatArchivesSessionWithBadgeCardAndSuggestions() throws {
        let app = try launchWithCoop()
        archiveOneChat(app)

        // Sidebar History row now carries the count badge (1).
        let historyRow = labeled(app.buttons, containing: "History")
        waitUntil(NSPredicate(format: "label CONTAINS %@", "1"), on: historyRow, timeout: 5)

        openHistory(app)
        waitFor(app.staticTexts["1 past chat · stored on this Mac"], timeout: 10,
                "History header should count exactly 1 archived chat")

        // Session card: titled with the first user message, with meta + affordances.
        waitFor(app.staticTexts[Self.question], timeout: 5,
                "session card should be titled with the archived question")
        XCTAssertTrue(labeled(app.staticTexts, containing: "2 messages").exists,
                      "session meta should count the 2 archived messages (user + assistant)")
        XCTAssertTrue(app.staticTexts["open →"].exists, "session card 'open →' affordance missing")
        XCTAssertTrue(app.buttons["×"].exists, "session card × (forget) button missing")

        // "ASK ME AGAIN": first suggestion is derived from the session title.
        XCTAssertTrue(app.staticTexts["ASK ME AGAIN"].exists, "suggestion section header missing")
        let suggestion = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@",
                        "Recap what we covered about", Self.question)).firstMatch
        XCTAssertTrue(suggestion.exists,
                      "first follow-up should be 'Recap what we covered about “\(Self.question)”'")
    }

    // MARK: - 2. reopen restores the transcript and empties History

    func testReopeningSessionRestoresTranscriptAndEmptiesHistory() throws {
        let app = try launchWithCoop()
        archiveOneChat(app)
        openHistory(app)

        let title = waitFor(app.staticTexts[Self.question], timeout: 10, "session card missing")
        title.click()   // card tap → openSession

        // Chat reopens with BOTH bubbles restored.
        waitFor(app.textFields["chat.input"], timeout: 10,
                "opening a session should return to the chat view")
        let user = waitFor(byID(app, "chat.msg.user"), timeout: 5, "restored user bubble missing")
        XCTAssertTrue(user.label.contains(Self.question),
                      "restored user bubble should hold the original question; got \"\(user.label)\"")
        let assistant = waitFor(byID(app, "chat.msg.assistant"), timeout: 5,
                                "restored assistant bubble missing")
        XCTAssertTrue(assistant.label.contains("1,948.55"),
                      "restored answer should still quote Σdebits 1,948.55; got \"\(assistant.label)\"")

        // The reopened session left History → empty again.
        openHistory(app)
        waitFor(app.staticTexts["0 past chats · stored on this Mac"], timeout: 10,
                "History should be empty after the only session was reopened")
        XCTAssertTrue(app.staticTexts["no past chats yet"].exists,
                      "empty state should show once the session moved back to the live chat")
    }

    // MARK: - 3. × forgets the session

    func testDeletingSessionShowsEmptyState() throws {
        let app = try launchWithCoop()
        archiveOneChat(app)
        openHistory(app)

        waitFor(app.staticTexts[Self.question], timeout: 10, "session card missing")
        app.buttons["×"].click()

        waitFor(app.staticTexts["no past chats yet"], timeout: 5,
                "deleting the only session should show the empty state")
        XCTAssertTrue(app.staticTexts["0 past chats · stored on this Mac"].exists,
                      "History header should count 0 after deletion")
        XCTAssertFalse(app.staticTexts[Self.question].exists,
                       "deleted session card should disappear")
    }

    // MARK: - 4. "today's chat →" pill navigates back

    func testTodaysChatPillReturnsToChat() throws {
        let app = try launchPenny(modelReady: true, dashboard: true, importFixture: Self.fixture)

        let historyRow = waitFor(labeled(app.buttons, containing: "History"), timeout: 10,
                                 "sidebar History row missing")
        historyRow.click()
        waitFor(app.staticTexts["no past chats yet"], timeout: 10, "History view did not open")
        XCTAssertFalse(app.textFields["chat.input"].exists,
                       "chat input should not be visible while History fills the centre column")

        labeled(app.buttons, containing: "today's chat").click()
        waitFor(app.textFields["chat.input"], timeout: 10,
                "the today's chat pill should navigate back to the chat view")
    }
}
