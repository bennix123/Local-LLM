// StressTests — multi-statement scale + context-window guarantees.
//
// Imports FIVE bundled statements (~2,100 rows across GBP/USD/EUR: Wrenfield
// 1,000 rows, indian_bank 1,000 rows, Coop, chase, DeutscheBank) into one
// AppModel, then drives 1,050 generated questions through the REAL send()
// pipeline (LEDGER table answers, ANALYTICS router answers, stubbed-MLX
// fallback — PENNY_UITEST_MODEL_READY=1 in the scheme test env). Asserts the
// properties that keep the app healthy at scale:
//   • every question gets a non-empty answer, transcript stays consistent
//   • the LEDGER table answer respects its 200-row cap on a 2,100-row corpus
//   • the grounding a real model would receive stays BOUNDED no matter how
//     many statements are loaded (top-14 retrieval + facts — the app's
//     context-window guarantee)
//   • history archive/reopen round-trips a 2,000+ message transcript
//   • memory growth over the run stays sane
import XCTest
@testable import Penny
import PennyTxnStore

@MainActor
final class StressTests: XCTestCase {

    // MARK: - corpus

    private static let fixtureNames = [
        "Coop_Demo_Statement",
        "chase_dummy_statement",
        "DeutscheBank_Demo_Statement",
        "Wrenfield_Bank_Statement_Tinku_Kesariya-1",
        "indian_bank_statement",
    ]

    /// One shared, fully-imported model for the whole class (imports cost
    /// seconds; every test reuses the same corpus).
    private static var corpus: AppModel?

    private func loadedCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> AppModel {
        if let m = Self.corpus { return m }
        let model = AppModel()
        // Statements persisted by other tests in this process (same per-process
        // StatementStore temp dir) must not restore into the corpus mid-import.
        model.restoreTask?.cancel()
        let bundle = Bundle(for: StressTests.self)
        for name in Self.fixtureNames {
            guard let url = bundle.url(forResource: name, withExtension: "pdf") else {
                XCTFail("fixture \(name).pdf missing from test bundle", file: file, line: line)
                throw XCTSkip("missing fixture")
            }
            let before = model.docs.count
            model.importPDF(from: url)
            spinUntil(timeout: 60, "import of \(name) never completed") {
                model.docs.count == before + 1 && !model.isImporting && !model.isAnalyzing
            }
        }
        XCTAssertEqual(model.docs.count, Self.fixtureNames.count, "all five statements should import")
        Self.corpus = model
        return model
    }

    /// Pump the main run loop until `condition` holds.
    private func spinUntil(timeout: TimeInterval, _ message: String,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    private func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576
    }

    // MARK: - 1. five statements import and sum coherently

    func testMultiStatementImportSumsAcrossCurrencies() throws {
        let model = try loadedCorpus()

        let totalRows = model.docs.map(\.rows.count).reduce(0, +)
        XCTAssertGreaterThanOrEqual(totalRows, 2_000,
            "corpus should carry 2,000+ rows (Wrenfield 1,000 + indian 1,000 + demos); got \(totalRows)")
        XCTAssertEqual(model.summary.count,
                       model.docs.map(\.transactions.count).reduce(0, +),
                       "Today-panel count must equal the sum of every imported statement's transactions")
        XCTAssertGreaterThan(model.summary.spent, 0, "corpus has debits — spent must be positive")
        for doc in model.docs {
            XCTAssertFalse(doc.rows.isEmpty, "\(doc.name) parsed 0 rows")
            XCTAssertTrue(doc.analyzed, "\(doc.name) not marked analyzed")
        }
    }

    // MARK: - 2. the 1,050-question gauntlet

    func testThousandQuestionsAllAnsweredWithBoundedTranscript() throws {
        let model = try loadedCorpus()
        model.messages.removeAll()

        // Build question ingredients from the REAL parsed data, not guesses.
        let rows = model.docs.flatMap(\.rows)
        let merchants = Array(Array(Set(rows.compactMap { $0.merchant.isEmpty ? nil : $0.merchant })).prefix(40))
        let months = Array(Array(Set(rows.map(\.month))).sorted().prefix(12))
        let categories = Array(Array(Set(rows.map(\.category))).prefix(12))
        XCTAssertFalse(merchants.isEmpty, "corpus should yield merchant names")
        XCTAssertFalse(months.isEmpty, "corpus should yield months")
        XCTAssertFalse(categories.isEmpty, "corpus should yield categories")

        var questions: [String] = []
        let templates: [(Int) -> String] = [
            { _ in "what is my total balance?" },
            { _ in "how much did i spend in total?" },
            { _ in "how many transactions do i have?" },
            { _ in "what was my biggest expense?" },
            { _ in "show me my top 5 expenses" },
            { _ in "how much income did i receive?" },
            { i in "how much did i spend at \(merchants[i % max(merchants.count, 1)])?" },
            { i in "how much did i spend on \(categories[i % max(categories.count, 1)])?" },
            { i in "how many transactions in \(months[i % max(months.count, 1)])?" },
            { i in "should i buy a boat? (variant \(i))" },   // stub/MLX fallback path
        ]
        for i in 0..<1_050 { questions.append(templates[i % templates.count](i)) }

        let memBefore = residentMemoryMB()
        let started = Date()
        var unanswered: [String] = []

        for (i, q) in questions.enumerated() {
            let countBefore = model.messages.count
            model.send(q)
            // Deterministic + stub paths append synchronously on the main actor.
            guard model.messages.count == countBefore + 2,
                  let answer = model.messages.last,
                  answer.role == .assistant, !answer.content.isEmpty else {
                unanswered.append("[\(i)] \(q)")
                continue
            }
            if i % 200 == 0 { print("STRESS: \(i)/\(questions.count) answered, mem \(Int(residentMemoryMB())) MB") }
        }
        let elapsed = Date().timeIntervalSince(started)
        let memAfter = residentMemoryMB()
        print("STRESS: \(questions.count) questions in \(String(format: "%.1f", elapsed))s, mem \(Int(memBefore)) → \(Int(memAfter)) MB")

        XCTAssertTrue(unanswered.isEmpty,
                      "\(unanswered.count) questions got no answer, first: \(unanswered.prefix(3))")
        XCTAssertEqual(model.messages.count, questions.count * 2,
                       "transcript must hold exactly one user + one assistant message per question")
        XCTAssertLessThan(elapsed, 240, "1,050 questions should route in well under 4 minutes")
        XCTAssertLessThan(memAfter - memBefore, 2_048,
                          "resident memory grew \(Int(memAfter - memBefore)) MB over the run — leak-scale growth")

        // Stubbed fallback answered the open-ended variants (proves the routing
        // split; some analytic phrasings may legitimately fall through too).
        let stubCount = model.messages.filter { $0.content.hasPrefix(TestMode.stubReplyPrefix) }.count
        XCTAssertGreaterThanOrEqual(stubCount, 105,
            "at least the 105 open-ended questions must hit the (stubbed) MLX path; got \(stubCount)")
        XCTAssertLessThan(stubCount * 2, questions.count,
            "the majority of factual questions must be answered deterministically, not by the model")
    }

    // MARK: - 3. LEDGER cap on a 2,100-row corpus

    func testLedgerTableRespects200RowCapAtScale() throws {
        let model = try loadedCorpus()
        model.messages.removeAll()
        model.send("show me all my transactions in a table")

        guard let answer = model.messages.last, answer.role == .assistant else {
            return XCTFail("no answer to the table request")
        }
        XCTAssertEqual(answer.engine, "LEDGER", "table request must route to the LEDGER engine")
        XCTAssertTrue(answer.content.contains("Showing first 200 of"),
                      "a 2,000+ row corpus must trigger the 200-row cap footer")
        let tableRows = answer.content.components(separatedBy: "\n").filter { $0.hasPrefix("| ") }.count
        XCTAssertLessThanOrEqual(tableRows, 203,
                                 "rendered table must stay capped (200 rows + header/separator); got \(tableRows)")
    }

    // MARK: - 4. context-window guarantee: grounding stays bounded

    func testRetrievalGroundingBoundedRegardlessOfCorpusSize() throws {
        let model = try loadedCorpus()
        let rows = model.docs.flatMap(\.rows)
        XCTAssertGreaterThanOrEqual(rows.count, 2_000)

        // The exact structure send() hands the model on the MLX path.
        let retriever = TxnRetriever(rows: rows)
        let probes = [
            "how is my spending on food and dining trending?",
            "am i wasting money on subscriptions?",
            "what should i do about my rent costs?",
            "tell me about my salary deposits",
            "where does most of my money go?",
        ]
        for q in probes {
            let hits = retriever.topK(q, k: 14)
            XCTAssertLessThanOrEqual(hits.count, 14, "retrieval must cap at k=14")
            let grounding = AppModel.retrievalContext(hits, currency: model.summary.currency)
            XCTAssertLessThan(grounding.count, 4_000,
                "grounding for \"\(q)\" is \(grounding.count) chars — the context the model sees "
                + "must stay bounded no matter how many statements are loaded")
            XCTAssertFalse(hits.isEmpty, "retrieval returned nothing for \"\(q)\" on a 2,000-row corpus")
        }
    }

    // MARK: - 5. history round-trips a 2,000+ message transcript

    func testHistoryArchivesAndReopensHugeTranscript() throws {
        let model = try loadedCorpus()
        // Reuse the gauntlet transcript if present; otherwise synthesize one.
        if model.messages.count < 100 {
            for i in 0..<200 { model.send("how much did i spend in total? (#\(i))") }
        }
        let messageCount = model.messages.count
        let firstUserContent = model.messages.first { $0.role == .user }?.content

        model.newChat()
        XCTAssertTrue(model.messages.isEmpty, "new chat must clear the live transcript")
        XCTAssertEqual(model.history.first?.messages.count, messageCount,
                       "archived session must keep every message")
        XCTAssertEqual(model.history.first?.title, firstUserContent.map { String($0.prefix(80)) },
                       "session title must be the first user message")

        let session = model.history[0]
        model.openSession(session)
        XCTAssertEqual(model.messages.count, messageCount, "reopening must restore the full transcript")
        XCTAssertTrue(model.history.isEmpty, "reopened session leaves history empty again")
    }
}
