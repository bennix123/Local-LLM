//
//  PersistenceTests.swift
//  PennyTests
//
//  StatementStore round-trip: an imported statement must survive a "relaunch"
//  (a fresh AppModel restoring from disk) with identical docs and Today-panel
//  figures, and "wipe all data" must clear both disk and memory. Runs under
//  PENNY_UITEST=1 (the Penny scheme's test environment), so StatementStore and
//  chat history write to per-process temp locations — never the real container.
//

import XCTest
import PennyCore
import PennyTxnStore
@testable import Penny

@MainActor
final class PersistenceTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(TestMode.active,
                          "PENNY_UITEST=1 must be set (Penny scheme test env) so persistence stays in temp")
        StatementStore.wipeAll()   // no leftovers from earlier tests in this process
    }

    override func tearDown() {
        StatementStore.wipeAll()   // never leak docs into later test classes
    }

    // MARK: - helpers

    private var historyFileURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("penny-uitest-history-\(ProcessInfo.processInfo.processIdentifier).json")
    }

    private func fixtureURL(_ name: String, file: StaticString = #filePath,
                            line: UInt = #line) throws -> URL {
        guard let url = Bundle(for: PersistenceTests.self).url(forResource: name, withExtension: "pdf") else {
            XCTFail("fixture \(name).pdf missing from test bundle", file: file, line: line)
            throw XCTSkip("missing fixture")
        }
        return url
    }

    /// Pump the main run loop until `condition` holds (same as StressTests).
    private func spinUntil(timeout: TimeInterval, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    private func importFixture(_ name: String, into model: AppModel,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try fixtureURL(name, file: file, line: line)
        let before = model.docs.count
        model.importPDF(from: url)
        spinUntil(timeout: 60, "import of \(name) never completed", file: file, line: line) {
            model.docs.count == before + 1 && !model.isImporting && !model.isAnalyzing
        }
    }

    /// Summary equality field-by-field (CategorySpend carries a fresh UUID per
    /// compute, so `==` on whole Summaries can never hold).
    private func assertSummariesEqual(_ a: Summary, _ b: Summary,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.currency, b.currency, file: file, line: line)
        XCTAssertEqual(a.balance, b.balance, file: file, line: line)
        XCTAssertEqual(a.spent, b.spent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.income, b.income, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.net, b.net, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        XCTAssertEqual(a.perCurrency, b.perCurrency, file: file, line: line)
        XCTAssertEqual(a.categories.map(\.name), b.categories.map(\.name), file: file, line: line)
        XCTAssertEqual(a.categories.map(\.amount), b.categories.map(\.amount), file: file, line: line)
    }

    // MARK: - round trip

    func testRoundTripRestoresDocsAndSummaryOnFreshModel() throws {
        let m1 = AppModel()
        m1.restoreTask?.cancel()
        try importFixture("Coop_Demo_Statement", into: m1)
        guard let original = m1.docs.first else { return XCTFail("import produced no doc") }
        XCTAssertGreaterThan(m1.summary.count, 0, "fixture should parse transactions")
        XCTAssertFalse(StatementStore.loadAll().isEmpty, "a successful import must persist to disk")

        // A fresh AppModel is a relaunch: its restore task must rebuild the
        // same docs and recompute the same Today-panel figures.
        let m2 = AppModel()
        spinUntil(timeout: 30, "restore never applied the persisted statement") {
            m2.docs.count == 1
        }

        guard let restored = m2.docs.first else { return XCTFail("restore produced no doc") }
        XCTAssertEqual(restored.name, original.name)
        XCTAssertEqual(restored.text, original.text, "chat grounding text must round-trip")
        XCTAssertEqual(restored.rows, original.rows, "TxnRows must round-trip exactly")
        XCTAssertEqual(restored.transactions, original.transactions,
                       "transactions rebuilt from rows must match the live import's")
        XCTAssertEqual(restored.currency, original.currency)
        XCTAssertEqual(restored.bank, original.bank)
        XCTAssertEqual(restored.detectedIssuer, original.detectedIssuer)
        XCTAssertEqual(restored.closingBalance, original.closingBalance)
        XCTAssertEqual(restored.isCard, original.isCard)
        XCTAssertTrue(restored.analyzed, "restored docs are already analyzed")
        XCTAssertEqual(m2.selectedDocNames, [original.name],
                       "restored docs come back selected, like a fresh import")
        assertSummariesEqual(m2.summary, m1.summary)
    }

    func testRemoveDocDeletesItsPersistedFile() throws {
        let m = AppModel()
        m.restoreTask?.cancel()
        try importFixture("Coop_Demo_Statement", into: m)
        guard let name = m.docs.first?.name else { return XCTFail("import produced no doc") }
        XCTAssertEqual(StatementStore.loadAll().count, 1)

        m.removeDoc(named: name)
        XCTAssertTrue(m.docs.isEmpty)
        XCTAssertTrue(StatementStore.loadAll().isEmpty,
                      "removing a doc must delete its persisted JSON too")

        // A relaunch has an empty store, so nothing can resurrect (a short
        // pump gives the restore task every chance to misbehave).
        let m2 = AppModel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(m2.docs.isEmpty, "a removed doc must not resurrect on relaunch")
    }

    // MARK: - wipe

    func testWipeAllDataClearsDiskAndMemory() throws {
        try? FileManager.default.removeItem(at: historyFileURL)
        let m = AppModel()
        m.restoreTask?.cancel()
        m.history = []
        try importFixture("Coop_Demo_Statement", into: m)
        m.messages = [ChatMessage(role: .user, content: "what did I spend?"),
                      ChatMessage(role: .assistant, content: "a lot")]
        m.newChat()   // archives → writes the history file

        XCTAssertFalse(StatementStore.loadAll().isEmpty, "statement should be on disk before wipe")
        XCTAssertFalse(m.history.isEmpty, "history should hold the archived chat before wipe")
        XCTAssertTrue(FileManager.default.fileExists(atPath: historyFileURL.path))

        m.wipeAllData()

        // memory
        XCTAssertTrue(m.docs.isEmpty)
        XCTAssertTrue(m.selectedDocNames.isEmpty)
        XCTAssertTrue(m.messages.isEmpty)
        XCTAssertTrue(m.history.isEmpty)
        XCTAssertEqual(m.summary.count, 0)
        XCTAssertNil(m.summary.balance)
        XCTAssertTrue(m.summary.perCurrency.isEmpty)
        // disk
        XCTAssertTrue(StatementStore.loadAll().isEmpty, "wipe must delete every persisted statement")
        XCTAssertFalse(FileManager.default.fileExists(atPath: historyFileURL.path),
                       "wipe must delete the chat-history file")

        // and a relaunch starts truly empty
        let m2 = AppModel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(m2.docs.isEmpty)
        XCTAssertEqual(m2.summary.count, 0)
    }
}
