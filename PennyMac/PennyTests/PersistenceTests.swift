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
import PennyModel
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
        // v2 persists only the canonical model and rebuilds LoadedDoc from it
        // (Task 0.6). We therefore verify BEHAVIOURAL equivalence — every
        // user-visible figure and label — not v1 internal shape (`rows` carry no
        // persisted `seq`/`rawCategory`; the single `institution` replaces the
        // `bank`/`detectedIssuer` split).
        XCTAssertEqual(restored.name, original.name)
        XCTAssertEqual(restored.text, original.text, "chat grounding text must round-trip")
        XCTAssertEqual(restored.transactions, original.transactions,
                       "rebuilt transactions must match the live import's figures")
        XCTAssertEqual(restored.currency, original.currency)
        XCTAssertEqual(restored.closingBalance, original.closingBalance)
        XCTAssertEqual(restored.isCard, original.isCard)
        XCTAssertEqual(restored.displayName, original.displayName,
                       "the displayed issuer label must be preserved")
        XCTAssertTrue(restored.analyzed, "restored docs are already analyzed")
        XCTAssertEqual(m2.selectedDocNames, [original.name],
                       "restored docs come back selected, like a fresh import")

        // Per-row behavioural equivalence: dates, signed amounts, balances,
        // currencies, merchants, categories — everything the app reads.
        XCTAssertEqual(restored.rows.count, original.rows.count)
        for (r, o) in zip(restored.rows, original.rows) {
            XCTAssertEqual(r.txnDate, o.txnDate, "date")
            XCTAssertEqual(r.debit, o.debit, "signed amount (debit)")
            XCTAssertEqual(r.credit, o.credit, "signed amount (credit)")
            XCTAssertEqual(r.balance, o.balance, "balance")
            XCTAssertEqual(r.currency, o.currency, "currency")
            XCTAssertEqual(r.merchant, o.merchant, "merchant")
            XCTAssertEqual(r.category, o.category, "category")
            XCTAssertEqual(r.descr, o.descr, "description")
        }

        // Reconciliation: the merged canonical graph equals the live import.
        let graph = StatementStore.loadGraph()
        XCTAssertEqual(graph.transactions.count, original.rows.count, "transaction count reconciles")
        XCTAssertEqual(graph.accounts.count, 1, "one account restored")
        XCTAssertEqual(graph.statements.first?.sourceName, original.name, "statement identity preserved")

        assertSummariesEqual(m2.summary, m1.summary)
    }

    // MARK: - v2 record / envelope / migration / corruption / performance

    /// Build a persistable record via the real translation layer (no PDF needed).
    private func makeRecord(sourceName: String, bank: String = "Monzo",
                            rows: [(date: String, descr: String, debit: Double)]) -> StatementStore.StatementRecord {
        let txnRows = rows.enumerated().map { i, r -> TxnRow in
            let p = r.date.split(separator: "-").compactMap { Int($0) }
            return TxnRow(txnDate: r.date, month: String(r.date.prefix(7)), year: p[0], monthNo: p[1], day: p[2],
                          descr: r.descr, merchant: "", category: "Groceries",
                          debit: r.debit, credit: 0, balance: nil, currency: "GBP", seq: i + 1)
        }
        let out = IngestOutput(rows: txnRows, bankName: bank, confidence: "test", detectedCurrency: "GBP")
        let graph = ModelAssembler.assemble(out, sourceName: sourceName).graph
        return StatementStore.StatementRecord(from: graph, text: "\(bank) statement text")
    }

    func testRecordAndEnvelopeRoundTrip() throws {
        let record = makeRecord(sourceName: "monzo.pdf",
                                rows: [(date: "2026-06-15", descr: "TESCO", debit: 45.50)])
        StatementStore.save(record)
        let loaded = StatementStore.loadRecords()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.statement.sourceName, "monzo.pdf")
        XCTAssertEqual(loaded.first?.transactions.count, 1)
        XCTAssertEqual(loaded.first?.transactions.first?.amount.amount, Decimal(string: "-45.50"))
        // Same content re-saved ⇒ same StatementID ⇒ one file (idempotent).
        StatementStore.save(record)
        XCTAssertEqual(StatementStore.loadRecords().count, 1, "same content must not duplicate")
    }

    func testMigrationFromV1WithoutDataLoss() throws {
        // Hand-write a v1 StoredDoc file (default-encoded importedAt as a Double)
        // into the legacy directory, then let the v2 restore migrate it.
        let root = StatementStore.directory.deletingLastPathComponent()   // …/statements
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let v1 = """
        {"name":"legacy.pdf","text":"Monzo\\nsome text",
         "rows":[{"txnDate":"2026-06-15","month":"2026-06","year":2026,"monthNo":6,"day":15,
                  "descr":"TESCO","merchant":"Tesco","category":"Groceries","debit":45.5,"credit":0,
                  "balance":100.0,"currency":"GBP","seq":1,"rawCategory":null}],
         "currency":"GBP","bank":"Monzo","detectedIssuer":null,"closingBalance":100.0,
         "isCard":false,"importedAt":700000000}
        """
        let v1URL = root.appendingPathComponent("legacy%2Epdf.json")
        try v1.data(using: .utf8)!.write(to: v1URL)

        let docs = StatementStore.loadDocs()   // triggers migrateV1IfNeeded
        XCTAssertEqual(docs.count, 1, "v1 file must migrate to a restorable doc")
        let d = docs.first
        XCTAssertEqual(d?.name, "legacy.pdf")
        XCTAssertEqual(d?.rows.first?.debit, 45.5, "figures survive migration")
        XCTAssertEqual(d?.rows.first?.category, "Groceries")
        XCTAssertFalse(FileManager.default.fileExists(atPath: v1URL.path), "v1 file removed after migration")
        XCTAssertEqual(StatementStore.loadRecords().count, 1, "a v2 record now exists")
        // Idempotent: a second restore doesn't duplicate.
        _ = StatementStore.loadDocs()
        XCTAssertEqual(StatementStore.loadRecords().count, 1)
    }

    func testCorruptFileIsQuarantinedAndOthersLoad() throws {
        StatementStore.save(makeRecord(sourceName: "good.pdf",
                                       rows: [(date: "2026-06-15", descr: "TESCO", debit: 10)]))
        // Drop a garbage file into the v2 directory.
        let bad = StatementStore.directory.appendingPathComponent("stmt-garbage.json")
        try "{ not valid json ".data(using: .utf8)!.write(to: bad)

        let records = StatementStore.loadRecords()
        XCTAssertEqual(records.count, 1, "the good record still loads; the corrupt one is skipped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path), "corrupt file is quarantined (moved)")
        let quarantined = StatementStore.directory.appendingPathComponent("corrupt/stmt-garbage.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined.path))
    }

    func testPerformanceAtScale() throws {
        let n = 150
        for i in 0..<n {
            StatementStore.save(makeRecord(sourceName: "stmt-\(i).pdf", bank: "Bank\(i)",
                                           rows: [(date: "2026-06-15", descr: "TX\(i)", debit: Double(i) + 0.5)]))
        }
        let start = Date()
        let graph = StatementStore.loadGraph()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(graph.statements.count, n, "all \(n) records load")
        XCTAssertEqual(graph.transactions.count, n)
        XCTAssertLessThan(elapsed, 5.0, "loading \(n) records should be well under 5s (was \(elapsed)s)")
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
