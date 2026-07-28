// StatementBatchingTests — pins the progressive-analysis engine: 6-month plans
// batch by two, the staged progress climbs monotonically to 100% only at the end,
// and a retry touches only the failed batch.
import XCTest
@testable import PennyTxnStore

final class StatementBatchingTests: XCTestCase {

    func testSixMonthsBatchByTwo() {
        let b = StatementBatchPlanner.plan(fileCount: 6)
        XCTAssertEqual(b.count, 3, "6 monthly statements → 3 batches of 2")
        XCTAssertEqual(b.map(\.fileIndices), [[0, 1], [2, 3], [4, 5]])
        XCTAssertEqual(b.map(\.monthRange), ["1–2", "3–4", "5–6"])
    }

    func testUnevenAndSingle() {
        XCTAssertEqual(StatementBatchPlanner.plan(fileCount: 5).map(\.monthRange), ["1–2", "3–4", "5"])
        XCTAssertEqual(StatementBatchPlanner.plan(fileCount: 1).map(\.fileIndices), [[0]])
        XCTAssertEqual(StatementBatchPlanner.plan(fileCount: 1).map(\.monthRange), ["1"])
        XCTAssertTrue(StatementBatchPlanner.plan(fileCount: 0).isEmpty)
    }

    func testCustomBatchSize() {
        let b = StatementBatchPlanner.plan(fileCount: 6, monthsPerBatch: 3)
        XCTAssertEqual(b.map(\.fileIndices), [[0, 1, 2], [3, 4, 5]])
        XCTAssertEqual(b.map(\.monthRange), ["1–3", "4–6"])
    }

    func testStageSequenceMatchesSpec() {
        let b = StatementBatchPlanner.plan(fileCount: 6)
        let titles = StatementBatchPlanner.stageSequence(for: b).map(\.title)
        XCTAssertEqual(titles, [
            "Reading PDF", "Extracting transactions",
            "Analyzing month 1–2", "Analyzing month 3–4", "Analyzing month 5–6",
            "Generating insights", "Completed",
        ])
    }

    func testProgressIsMonotonicAndHits100OnlyAtEnd() {
        let b = StatementBatchPlanner.plan(fileCount: 6)
        let seq = StatementBatchPlanner.stageSequence(for: b)
        var last = -1.0
        for (i, stage) in seq.enumerated() {
            let done = stage == .generatingInsights || stage == .completed ? b.count
                     : (i >= 2 ? i - 2 : 0)
            let p = StatementBatchPlanner.progress(stage: stage, batches: b, batchesDone: done)
            XCTAssertGreaterThanOrEqual(p.fraction, last, "fraction must not go backwards at \(stage)")
            XCTAssertGreaterThanOrEqual(p.fraction, 0); XCTAssertLessThanOrEqual(p.fraction, 1)
            last = p.fraction
            if stage == .completed { XCTAssertEqual(p.fraction, 1.0) }
            else { XCTAssertLessThan(p.fraction, 1.0, "only .completed is 100%") }
        }
        // First batch's data is published well before the end.
        let firstBatch = StatementBatchPlanner.progress(stage: .analyzing(monthRange: "1–2"),
                                                        batches: b, batchesDone: 1)
        XCTAssertGreaterThan(firstBatch.fraction, 0)
        XCTAssertLessThan(firstBatch.fraction, 0.6, "seeing month 1–2 shouldn't imply we're nearly done")
        XCTAssertEqual(firstBatch.stepCount, 6)   // Reading … Insights
    }

    func testRetryIsolatesToTheFailedBatch() {
        let batches = StatementBatchPlanner.plan(fileCount: 6)
        let target = batches[1]
        let r1 = StatementBatchPlanner.nextAttempt(target)
        XCTAssertEqual(r1?.attempt, 1)
        XCTAssertEqual(r1?.fileIndices, target.fileIndices, "retry keeps the same batch's files")
        // Other batches are unaffected — they're separate values.
        XCTAssertEqual(batches[0].attempt, 0)
        XCTAssertEqual(batches[2].attempt, 0)
        // Retries are capped; past the cap the caller gets nil and marks it failed.
        let r2 = StatementBatchPlanner.nextAttempt(r1!)
        XCTAssertEqual(r2?.attempt, 2)
        XCTAssertNil(StatementBatchPlanner.nextAttempt(r2!), "exhausted retries → nil")
    }

    func testPercentRounding() {
        let b = StatementBatchPlanner.plan(fileCount: 6)
        XCTAssertEqual(StatementBatchPlanner.progress(stage: .completed, batches: b, batchesDone: 3).percent, 100)
        XCTAssertEqual(StatementBatchPlanner.progress(stage: .readingPDF, batches: b, batchesDone: 0).percent, 0)
    }
}
