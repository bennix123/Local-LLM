// RetrieverTests — guards the hybrid RAG retriever (Retriever.swift): BM25 sparse leg,
// optional Apple NLEmbedding dense leg, and reciprocal-rank fusion (k0 = 60) that together
// pick the transaction rows the LLM gets grounded on. Because NLEmbedding availability
// varies per machine, every topK-level assertion here is written to hold in BOTH modes:
// with a corpus of n ≤ 61 rows, a row whose text matches a query keyword earns a BM25 rank
// (fused ≥ 1/(60+|T|) + 1/(60+n) ≥ 2/(60+n) with dense, ≥ 1/(60+n) without) while a
// non-matching row scores at most 1/61 (dense rank 1) — or exactly 0 in BM25-only mode —
// so keyword-matching rows provably occupy the head of the result in either mode. The suite
// covers topic separation (food delivery / salary / ATM), docText direction-word retrieval,
// k clamping, empty/garbage/case-variant queries, empty corpora, tie-breaking on duplicate
// rows, in-process determinism, the BM25/rankMap/cosine/tokenize internals, and one
// end-to-end run over a real contract fixture ground-truthed via penny-conformance.
import XCTest
import NaturalLanguage
@testable import PennyTxnStore

// MARK: - Synthetic corpus helpers

/// A minimal, valid TxnRow; only the retrieval-relevant fields vary per test.
private func row(seq: Int, descr: String, merchant: String, category: String,
                 debit: Double = 0, credit: Double = 0, day: Int = 5) -> TxnRow {
    TxnRow(txnDate: String(format: "2025-03-%02d", day), month: "2025-03",
           year: 2025, monthNo: 3, day: day, descr: descr, merchant: merchant,
           category: category, debit: debit, credit: credit, balance: nil,
           currency: "GBP", seq: seq)
}

/// Ten rows in three clearly separable topics plus unrelated fillers.
/// Token exclusivity (after tokenize): "food"/"dining" only in seqs 0–2,
/// "salary"/"acme" only in 3–4, "atm"/"withdrawal"/"cash" only in 5–6, and the
/// credit direction words ("received credit income deposit incoming") only in 3–4
/// because they are the sole credit rows.
private func makeCorpus() -> [TxnRow] {
    [
        row(seq: 0, descr: "SWIGGY ORDER 8841", merchant: "Swiggy", category: "Food & Dining", debit: 450),
        row(seq: 1, descr: "ZOMATO ORDER 1213", merchant: "Zomato", category: "Food & Dining", debit: 320),
        row(seq: 2, descr: "DELIVEROO LUNCH", merchant: "Deliveroo", category: "Food & Dining", debit: 18.5),
        row(seq: 3, descr: "ACME CORP SALARY MAR", merchant: "Acme Corp", category: "Income", credit: 3200),
        row(seq: 4, descr: "ACME CORP SALARY BONUS", merchant: "Acme Corp", category: "Income", credit: 500),
        row(seq: 5, descr: "ATM WITHDRAWAL KINGSLAND", merchant: "", category: "Cash", debit: 100),
        row(seq: 6, descr: "ATM WITHDRAWAL HIGHBURY", merchant: "", category: "Cash", debit: 60),
        row(seq: 7, descr: "COUNCIL TAX HACKNEY", merchant: "Hackney Council", category: "Bills", debit: 148.3),
        row(seq: 8, descr: "NETFLIX SUBSCRIPTION", merchant: "Netflix", category: "Entertainment", debit: 9.99),
        row(seq: 9, descr: "TFL TRAVEL CHARGE", merchant: "TfL", category: "Transport", debit: 5.6),
    ]
}

final class RetrieverTests: XCTestCase {

    /// Mirrors topK's own gate for the dense leg (hasDense && query vector non-nil)
    /// so assertions can tighten to "BM25-only" semantics when dense is inactive.
    private func denseLegActive(query: String, corpus: [TxnRow]) -> Bool {
        guard let emb = NLEmbedding.sentenceEmbedding(for: .english),
              emb.vector(for: query.lowercased()) != nil else { return false }
        return corpus.contains { emb.vector(for: TxnRetriever.docText($0)) != nil }
    }

    /// Asserts the keyword-matching rows (`expectedSeqs`) occupy the head of topK in
    /// either mode, and are the ONLY results in BM25-only mode. Requires
    /// k >= expectedSeqs.count and corpus.count <= 61 (see file header for the proof).
    private func assertHead(_ expectedSeqs: Set<Int>, corpus: [TxnRow], query: String, k: Int,
                            file: StaticString = #filePath, line: UInt = #line) {
        precondition(corpus.count <= 61 && k >= expectedSeqs.count, "test misuse: head guarantee needs n<=61, k>=|T|")
        let hits = TxnRetriever(rows: corpus).topK(query, k: k)
        XCTAssertGreaterThanOrEqual(
            hits.count, expectedSeqs.count,
            "query \"\(query)\": every keyword-matching row earns a BM25 rank so at least " +
            "\(expectedSeqs.count) hits must come back, got \(hits.count)",
            file: file, line: line)
        let head = Set(hits.prefix(expectedSeqs.count).map(\.seq))
        XCTAssertEqual(
            head, expectedSeqs,
            "query \"\(query)\": keyword-matching rows must outrank all unrelated rows; " +
            "head seqs \(head.sorted()) != expected \(expectedSeqs.sorted()) " +
            "(full order: \(hits.map(\.seq)))",
            file: file, line: line)
        if !denseLegActive(query: query, corpus: corpus) {
            XCTAssertEqual(
                Set(hits.map(\.seq)), expectedSeqs,
                "BM25-only mode: rows with zero BM25 score must be filtered out entirely " +
                "for \"\(query)\", got seqs \(hits.map(\.seq))",
                file: file, line: line)
        }
    }

    // MARK: - Topic separation

    func testFoodDeliveryQueryRanksFoodRowsFirst() {
        // "food" hits only the Food & Dining category tokens of seqs 0–2
        // ("delivery" matches nothing, so it must not perturb the head).
        assertHead([0, 1, 2], corpus: makeCorpus(), query: "food delivery", k: 6)
    }

    func testSalaryQueryRanksSalaryRowsFirst() {
        assertHead([3, 4], corpus: makeCorpus(), query: "salary", k: 6)
    }

    func testAtmQueryRanksAtmRowsFirst() {
        assertHead([5, 6], corpus: makeCorpus(), query: "atm withdrawal", k: 6)
    }

    func testMerchantNameQueryFindsExactRow() {
        assertHead([1], corpus: makeCorpus(), query: "zomato", k: 4)
    }

    func testDirectionWordsRetrieveCreditRows() {
        // docText appends "received credit income deposit incoming" to credit rows,
        // so an income-flavoured query must surface the two credits (seqs 3–4) first.
        assertHead([3, 4], corpus: makeCorpus(), query: "income received deposit", k: 6)
    }

    func testQueryIsCaseInsensitive() {
        let r = TxnRetriever(rows: makeCorpus())
        XCTAssertEqual(r.topK("SALARY", k: 5), r.topK("salary", k: 5),
                       "tokenize lowercases and topK lowercases the dense query, so case must not matter")
        assertHead([3, 4], corpus: makeCorpus(), query: "SALARY", k: 6)
    }

    // MARK: - k handling

    func testKNeverExceeded() {
        let corpus = makeCorpus()
        let r = TxnRetriever(rows: corpus)
        for k in [0, 1, 2, 3, 5, 10, 50] {
            let hits = r.topK("food delivery", k: k)
            XCTAssertLessThanOrEqual(hits.count, k, "topK(k: \(k)) returned \(hits.count) rows")
            XCTAssertLessThanOrEqual(hits.count, corpus.count, "cannot return more rows than exist")
        }
    }

    func testKSmallerThanMatchesTruncatesToBestMatches() {
        // Three food rows match; k = 2 must return exactly 2, both from the food topic.
        let hits = TxnRetriever(rows: makeCorpus()).topK("food delivery", k: 2)
        XCTAssertEqual(hits.count, 2, "3 rows have positive BM25 score, so k=2 must fill completely")
        XCTAssertTrue(Set(hits.map(\.seq)).isSubset(of: [0, 1, 2]),
                      "truncated results must still all be food rows, got seqs \(hits.map(\.seq))")
    }

    func testKZeroReturnsEmpty() {
        XCTAssertEqual(TxnRetriever(rows: makeCorpus()).topK("salary", k: 0), [],
                       "k=0 must return no rows")
    }

    func testKLargerThanCorpusKeepsMatchesInHead() {
        assertHead([0, 1, 2], corpus: makeCorpus(), query: "food delivery", k: 50)
    }

    // MARK: - Degenerate inputs

    func testEmptyRowsAlwaysEmpty() {
        let r = TxnRetriever(rows: [])
        XCTAssertEqual(r.topK("salary", k: 5), [], "no rows → no results")
        XCTAssertEqual(r.topK("", k: 0), [], "no rows + empty query must not crash")
        XCTAssertEqual(r.topK("anything at all", k: 100), [])
    }

    func testEmptyQueryIsSane() {
        let corpus = makeCorpus()
        let r = TxnRetriever(rows: corpus)
        let hits = r.topK("", k: 5)
        XCTAssertLessThanOrEqual(hits.count, 5, "empty query must still respect k")
        if !denseLegActive(query: "", corpus: corpus) {
            XCTAssertTrue(hits.isEmpty,
                          "no BM25 tokens and no dense vector → nothing can score, expected []")
        }
        XCTAssertEqual(hits, r.topK("", k: 5), "empty-query results must be deterministic")
    }

    func testWhitespaceAndPunctuationQueriesDoNotCrash() {
        let corpus = makeCorpus()
        let r = TxnRetriever(rows: corpus)
        for q in ["   ", "\t\n", "!!! ???", "£$%^&*", "a b c 1"] { // last: all tokens < 2 chars
            let hits = r.topK(q, k: 4)
            XCTAssertLessThanOrEqual(hits.count, 4, "query \"\(q)\" exceeded k")
            if !denseLegActive(query: q, corpus: corpus) {
                XCTAssertTrue(hits.isEmpty,
                              "query \"\(q)\" yields no BM25 tokens; BM25-only mode must return []")
            }
        }
    }

    func testUnmatchedKeywordsAreSane() {
        // Tokens that appear in no docText: BM25 scores all zero.
        let corpus = makeCorpus()
        let r = TxnRetriever(rows: corpus)
        let q = "zzyzx qwertyuiop"
        let hits = r.topK(q, k: 4)
        XCTAssertLessThanOrEqual(hits.count, 4)
        if !denseLegActive(query: q, corpus: corpus) {
            XCTAssertTrue(hits.isEmpty, "no BM25 match + no dense leg must yield [] (caller falls back)")
        }
        XCTAssertEqual(hits, r.topK(q, k: 4), "unmatched-query results must be deterministic")
    }

    func testSingleRowCorpus() {
        let solo = [row(seq: 0, descr: "STARBUCKS COFFEE", merchant: "Starbucks",
                        category: "Food & Dining", debit: 4.5)]
        XCTAssertEqual(TxnRetriever(rows: solo).topK("starbucks", k: 3).map(\.seq), [0],
                       "the sole keyword-matching row must be returned exactly once")
    }

    // MARK: - Determinism & tie-breaking

    func testDeterministicAcrossCallsAndInstances() {
        let corpus = makeCorpus()
        let r1 = TxnRetriever(rows: corpus)
        for q in ["food delivery", "salary", "atm withdrawal", "how much did i spend", ""] {
            let a = r1.topK(q, k: 6)
            XCTAssertEqual(a, r1.topK(q, k: 6), "same-instance repeat call diverged for \"\(q)\"")
            XCTAssertEqual(a, TxnRetriever(rows: corpus).topK(q, k: 6),
                           "fresh-instance call diverged for \"\(q)\"")
        }
    }

    func testDuplicateRowsTieBreakByCorpusOrder() {
        // An exact textual duplicate produces identical BM25 scores and identical dense
        // vectors; rankMap and the fused sort both break ties by lower index, so the
        // earlier row must come first — in both modes.
        var corpus = makeCorpus()
        corpus.append(row(seq: 10, descr: "SWIGGY ORDER 8841", merchant: "Swiggy",
                          category: "Food & Dining", debit: 450))
        let hits = TxnRetriever(rows: corpus).topK("swiggy", k: 4)
        XCTAssertGreaterThanOrEqual(hits.count, 2, "both swiggy duplicates must match")
        XCTAssertEqual(hits.prefix(2).map(\.seq), [0, 10],
                       "identical docs must keep corpus order (index tie-break), got \(hits.map(\.seq))")
    }

    // MARK: - docText / tokenize internals

    func testDocTextEncodesDirectionAndSemanticFields() {
        let debitText = TxnRetriever.docText(
            row(seq: 0, descr: "SWIGGY ORDER", merchant: "Swiggy", category: "Food & Dining", debit: 450))
        XCTAssertTrue(debitText.contains("SWIGGY ORDER"), "descr missing from docText: \(debitText)")
        XCTAssertTrue(debitText.contains("Swiggy"), "merchant missing from docText")
        XCTAssertTrue(debitText.contains("Food & Dining"), "category missing from docText")
        XCTAssertTrue(debitText.contains("spent debit payment outgoing"), "debit direction words missing")
        XCTAssertFalse(debitText.contains("received"), "debit row must not carry credit direction words")

        let creditText = TxnRetriever.docText(
            row(seq: 1, descr: "ACME SALARY", merchant: "Acme", category: "Income", credit: 3200))
        XCTAssertTrue(creditText.contains("received credit income deposit incoming"),
                      "credit direction words missing: \(creditText)")
        XCTAssertFalse(creditText.contains("outgoing"), "credit row must not carry debit direction words")
    }

    func testTokenizeLowercasesSplitsAndDropsShortTokens() {
        XCTAssertEqual(TxnRetriever.tokenize("Swiggy*Order #8841"), ["swiggy", "order", "8841"])
        XCTAssertEqual(TxnRetriever.tokenize("TFL. Travel/Charge 2X"), ["tfl", "travel", "charge", "2x"])
        XCTAssertEqual(TxnRetriever.tokenize("a I x 9"), [], "single-character tokens must be dropped")
        XCTAssertEqual(TxnRetriever.tokenize(""), [])
        XCTAssertEqual(TxnRetriever.tokenize("  \t\n "), [])
    }

    // MARK: - rankMap / cosine internals

    func testRankMapDescendingWithIndexTieBreakAndPositiveCutoff() {
        let m = TxnRetriever.rankMap([0.5, 2.0, 0.5, 0.0], limit: 10, positiveOnly: true)
        XCTAssertEqual(m, [1: 1, 0: 2, 2: 3],
                       "expected desc-score order, lower-index tie-break, stop at first non-positive; got \(m)")
    }

    func testRankMapRespectsLimit() {
        XCTAssertEqual(TxnRetriever.rankMap([3, 2, 1], limit: 2, positiveOnly: true), [0: 1, 1: 2])
    }

    func testRankMapPositiveOnlyFalseRanksNegatives() {
        XCTAssertEqual(TxnRetriever.rankMap([-2.0, 5.0], limit: 10, positiveOnly: false), [1: 1, 0: 2],
                       "dense leg ranks all scores including negatives")
    }

    func testRankMapAllNonPositiveOrEmpty() {
        XCTAssertEqual(TxnRetriever.rankMap([0.0, -1.0], limit: 5, positiveOnly: true), [:],
                       "0 means 'no term matched' and must earn no rank")
        XCTAssertEqual(TxnRetriever.rankMap([], limit: 5, positiveOnly: true), [:])
    }

    func testCosine() {
        XCTAssertEqual(TxnRetriever.cosine([1, 2, 3], [2, 4, 6]), 1.0, accuracy: 1e-12,
                       "parallel vectors → 1")
        XCTAssertEqual(TxnRetriever.cosine([1, 0], [0, 1]), 0.0, accuracy: 1e-12,
                       "orthogonal vectors → 0")
        XCTAssertEqual(TxnRetriever.cosine([1, 0], [-1, 0]), -1.0, accuracy: 1e-12,
                       "opposite vectors → -1")
        XCTAssertEqual(TxnRetriever.cosine([1, 2], [1, 2, 3]), 0, "length mismatch → 0")
        XCTAssertEqual(TxnRetriever.cosine([], []), 0, "empty vectors → 0")
        XCTAssertEqual(TxnRetriever.cosine([0, 0], [1, 1]), 0, "zero vector → 0, never NaN")
    }

    // MARK: - BM25 internals

    func testBM25PositiveOnPresenceZeroOnAbsence() {
        let bm = BM25(docs: [["swiggy", "order"], ["salary", "credit"], ["atm", "cash"]])
        let s = bm.scores(["swiggy"])
        XCTAssertEqual(s.count, 3)
        XCTAssertGreaterThan(s[0], 0, "doc containing the term must score > 0")
        XCTAssertEqual(s[1], 0, "doc without the term must score exactly 0")
        XCTAssertEqual(s[2], 0)
    }

    func testBM25EmptyQueryAndEmptyCorpus() {
        let bm = BM25(docs: [["a", "b"]])
        XCTAssertEqual(bm.scores([]), [0], "empty query → all-zero scores")
        XCTAssertEqual(BM25(docs: []).scores(["x"]), [], "empty corpus → empty score vector, no crash")
    }

    func testBM25RareTermOutscoresCommonTerm() {
        // Same tf (1) and doc length (2) everywhere; only document frequency differs.
        let bm = BM25(docs: [["common", "rare"], ["common", "fillera"], ["common", "fillerb"]])
        XCTAssertGreaterThan(bm.scores(["rare"])[0], bm.scores(["common"])[0],
                             "IDF must reward the rarer term at equal tf and doc length")
    }

    func testBM25HigherTermFrequencyScoresHigher() {
        // Equal doc lengths isolate the tf component.
        let s = BM25(docs: [["cafe", "cafe"], ["cafe", "misc"]]).scores(["cafe"])
        XCTAssertGreaterThan(s[0], s[1], "tf=2 must outscore tf=1 at equal doc length")
    }

    func testBM25DeduplicatesQueryTokens() {
        let bm = BM25(docs: [["cafe", "misc"], ["tea", "misc"]])
        XCTAssertEqual(bm.scores(["cafe", "cafe"]), bm.scores(["cafe"]),
                       "repeated query tokens must not double-count")
    }

    // MARK: - End-to-end over a real fixture (ground-truthed via penny-conformance retrieve)

    func testNatWestFixtureSalaryRetrieval() throws {
        let pdf = TestPaths.fixturesDir.appendingPathComponent("NatWest_Demo_Statement.pdf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: pdf.path),
                          "contract fixture missing at \(pdf.path)")
        let ingester = try TestPaths.makeIngester()
        let out = try ingester.ingestPDF(path: pdf.path)
        XCTAssertFalse(out.rows.isEmpty, "NatWest fixture must ingest rows")
        XCTAssertLessThan(out.rows.count, 62,
                          "head-of-results guarantee assumes n<62; revisit this test if the fixture grows")
        // Ground truth (penny-conformance retrieve … "salary"): exactly two rows contain
        // the token — "SALARY - ACME CORP LTD" and "SALARY - ACME CORP LTD (BONUS)".
        let hits = TxnRetriever(rows: out.rows).topK("salary", k: 5)
        XCTAssertGreaterThanOrEqual(hits.count, 2, "both SALARY rows must be retrieved")
        for (i, hit) in hits.prefix(2).enumerated() {
            XCTAssertTrue(hit.descr.contains("SALARY"),
                          "hit \(i + 1) for 'salary' must be a SALARY row, got \"\(hit.descr)\"")
        }
    }
}
