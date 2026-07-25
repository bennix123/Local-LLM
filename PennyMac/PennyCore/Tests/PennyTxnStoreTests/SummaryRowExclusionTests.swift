// SummaryRowExclusionTests — summary balance-display rows must never ingest as
// transactions. The boi/chase/lloyds/metrobank/santander/tsb/revolut fixtures
// carry "BALANCE BROUGHT FORWARD" / "BALANCE CARRIED FORWARD" (UK layouts) or
// "BEGINNING BALANCE" / "ENDING BALANCE" (chase) rows that used to leak out of
// the generic layers and inflate spent/income:
//   - the date-inherited layer's summary regex missed "carried forward" and
//     "beginning/ending balance", so those rows became transactions (with the
//     page footer stitched into the CARRIED FORWARD row's description);
//   - the columnar layer's single-money "balance-display" skip only fired when
//     the value equalled a non-nil running balance, so chase's BEGINNING
//     BALANCE row (running balance still nil) leaked as a 1250 credit.
// The fix skips summary rows on phrase match ANYWHERE in the row text and
// SEEDS the running balance from a skipped statement-opening row, so the first
// real row classifies by balance delta — flipping the previously misclassified
// first rows (e.g. chase's ZELLE TRANSFER RECEIVED) from debit to credit.
//
// Every expected value below was derived from the pre-fix ground truth dumps
// (`penny-conformance rows-json`) minus the excluded summary rows plus the
// first-row polarity fix, and cross-checked against the Python reference
// (finquery/backend/src/services/txn_store/parsers.py) running the same
// change: 32 rows -> 31 per fixture, totals shift by exactly the removed
// summary amount and the flipped first-row amount, and the running-balance
// chain now reconciles end-to-end (seeded opening 1250.00 -> closing balance).
import XCTest
@testable import PennyTxnStore

/// The pinned post-fix expectation for one fixture.
private struct ExclusionPin {
    let file: String
    let rows: Int
    let totalDebit: Double
    let totalCredit: Double
    let firstDate: String
    let firstDescr: String
    let firstDebit: Double
    let firstCredit: Double
    let firstBalance: Double
    let lastDate: String
    let lastDescr: String
    let lastDebit: Double
    let lastCredit: Double
    let lastBalance: Double
}

private let exclusionPins: [ExclusionPin] = [
    // UK layouts (date-inherited layer): the BROUGHT FORWARD row seeds the
    // walk at 1,250.00 so the first row (bal 1,899.99) is now a credit, and
    // the CARRIED FORWARD row (previously a 5,804.92 "debit" with the page
    // footer stitched in) is gone — the last row is the final real purchase.
    ExclusionPin(file: "boi_dummy_statement.pdf", rows: 31,
                 totalDebit: 3119.63, totalCredit: 7674.55,
                 firstDate: "2026-06-07", firstDescr: "26 TRANSFER FROM SAVINGS",
                 firstDebit: 0, firstCredit: 649.99, firstBalance: 1899.99,
                 lastDate: "2026-07-06", lastDescr: "26 IKEA",
                 lastDebit: 176.21, lastCredit: 0, lastBalance: 5804.92),
    ExclusionPin(file: "metrobank_dummy_statement.pdf", rows: 31,
                 totalDebit: 3119.63, totalCredit: 7674.55,
                 firstDate: "2026-06-07", firstDescr: "26 TRANSFER FROM SAVINGS",
                 firstDebit: 0, firstCredit: 649.99, firstBalance: 1899.99,
                 lastDate: "2026-07-06", lastDescr: "26 IKEA",
                 lastDebit: 176.21, lastCredit: 0, lastBalance: 5804.92),
    ExclusionPin(file: "santander_dummy_statement.pdf", rows: 31,
                 totalDebit: 3119.63, totalCredit: 7674.55,
                 firstDate: "2026-06-07", firstDescr: "26 TRANSFER FROM SAVINGS",
                 firstDebit: 0, firstCredit: 649.99, firstBalance: 1899.99,
                 lastDate: "2026-07-06", lastDescr: "26 IKEA",
                 lastDebit: 176.21, lastCredit: 0, lastBalance: 5804.92),
    ExclusionPin(file: "tsb_dummy_statement.pdf", rows: 31,
                 totalDebit: 3119.63, totalCredit: 7674.55,
                 firstDate: "2026-06-07", firstDescr: "26 TRANSFER FROM SAVINGS",
                 firstDebit: 0, firstCredit: 649.99, firstBalance: 1899.99,
                 lastDate: "2026-07-06", lastDescr: "26 IKEA",
                 lastDebit: 176.21, lastCredit: 0, lastBalance: 5804.92),
    ExclusionPin(file: "lloyds_dummy_statement.pdf", rows: 31,
                 totalDebit: 3743.35, totalCredit: 5114.54,
                 firstDate: "2026-06-07", firstDescr: "26 REFUND - JOHN LEWIS",
                 firstDebit: 0, firstCredit: 723.82, firstBalance: 1973.82,
                 lastDate: "2026-07-06", lastDescr: "26 UBER TRIP",
                 lastDebit: 35.24, lastCredit: 0, lastBalance: 2621.19),
    ExclusionPin(file: "revolut_dummy_statement.pdf", rows: 31,
                 totalDebit: 4599.96, totalCredit: 5817.08,
                 firstDate: "2026-06-07", firstDescr: "26 TOP-UP FROM BANK ACCOUNT",
                 firstDebit: 0, firstCredit: 649.99, firstBalance: 1899.99,
                 lastDate: "2026-07-06", lastDescr: "26 SHELL GARAGE",
                 lastDebit: 224.01, lastCredit: 0, lastBalance: 2467.12),
    // chase (columnar layer): pre-fix ground truth was 32 rows with the
    // BEGINNING BALANCE row leaking as a 1,250.00 credit (balance 0) and the
    // ZELLE row misread as a debit; ENDING BALANCE was already skipped via
    // the running-balance equality check. Post-fix: 31 rows, total credit
    // drops by the 1,250.00 leak and gains the flipped 649.99 ZELLE credit
    // (8274.56 - 1250 + 649.99 = 7674.55), total debit loses the ZELLE
    // amount (3723.08 - 649.99 = 3073.09).
    ExclusionPin(file: "chase_dummy_statement.pdf", rows: 31,
                 totalDebit: 3073.09, totalCredit: 7674.55,
                 firstDate: "2026-06-07", firstDescr: "ZELLE TRANSFER RECEIVED",
                 firstDebit: 0, firstCredit: 649.99, firstBalance: 1899.99,
                 lastDate: "2026-07-06", lastDescr: "AT&T WIRELESS",
                 lastDebit: 129.67, lastCredit: 0, lastBalance: 5851.46),
]

final class SummaryRowExclusionTests: XCTestCase {

    // MARK: shared ingest cache (each PDF parses once for the whole class)

    private static var ingester: TxnIngester?
    private static var cache: [String: Result<IngestOutput, Error>] = [:]

    private static func ingest(_ file: String) throws -> IngestOutput {
        let path = TestPaths.fixturesDir.appendingPathComponent(file).path
        if let cached = cache[path] { return try cached.get() }
        if ingester == nil { ingester = try TestPaths.makeIngester() }
        let result = Result { try ingester!.ingestPDF(path: path) }
        cache[path] = result
        return try result.get()
    }

    /// The summary phrases that must never appear in an ingested description.
    private let summaryPhrases = ["balance carried forward", "balance brought forward",
                                  "beginning balance", "ending balance"]

    private func check(_ file: String, testFile: StaticString = #filePath, line: UInt = #line) throws {
        guard let pin = exclusionPins.first(where: { $0.file == file }) else {
            XCTFail("no exclusion pin registered for \(file)", file: testFile, line: line)
            return
        }
        let path = TestPaths.fixturesDir.appendingPathComponent(file).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "\(file): fixture missing at \(path)", file: testFile, line: line)
        let out = try Self.ingest(file)

        // 1. No summary balance-display row survives as a transaction.
        for (i, r) in out.rows.enumerated() {
            let low = r.descr.lowercased()
            for phrase in summaryPhrases where low.contains(phrase) {
                XCTFail("\(file) row \(i) ('\(r.descr)') contains summary phrase '\(phrase)' — "
                        + "balance-display rows must not ingest as transactions",
                        file: testFile, line: line)
            }
        }

        // 2. Row count: exactly the pre-fix count minus the leaked summary rows.
        XCTAssertEqual(out.rows.count, pin.rows,
                       "\(file): row count drifted", file: testFile, line: line)

        // 3. Totals: the summary leak is out and the first-row polarity fix is in.
        let totalDebit = out.rows.reduce(0.0) { $0 + $1.debit }
        let totalCredit = out.rows.reduce(0.0) { $0 + $1.credit }
        XCTAssertEqual(totalDebit, pin.totalDebit, accuracy: 0.01,
                       "\(file): total debit drifted", file: testFile, line: line)
        XCTAssertEqual(totalCredit, pin.totalCredit, accuracy: 0.01,
                       "\(file): total credit drifted", file: testFile, line: line)

        // 4. First row: the seeded opening balance classifies it by delta
        //    (credit), where cue words used to misread it as a debit.
        guard let first = out.rows.first, let last = out.rows.last else {
            XCTFail("\(file): no rows parsed", file: testFile, line: line)
            return
        }
        XCTAssertEqual(first.txnDate, pin.firstDate, "\(file): first date", file: testFile, line: line)
        XCTAssertEqual(first.descr, pin.firstDescr, "\(file): first descr", file: testFile, line: line)
        XCTAssertEqual(first.debit, pin.firstDebit, accuracy: 0.001,
                       "\(file): first debit", file: testFile, line: line)
        XCTAssertEqual(first.credit, pin.firstCredit, accuracy: 0.001,
                       "\(file): first credit", file: testFile, line: line)
        XCTAssertEqual(first.balance ?? .nan, pin.firstBalance, accuracy: 0.001,
                       "\(file): first balance", file: testFile, line: line)

        // 5. Last row: the trailing summary row is gone AND its footer text no
        //    longer stitches into (or past) the final real transaction.
        XCTAssertEqual(last.txnDate, pin.lastDate, "\(file): last date", file: testFile, line: line)
        XCTAssertEqual(last.descr, pin.lastDescr, "\(file): last descr", file: testFile, line: line)
        XCTAssertEqual(last.debit, pin.lastDebit, accuracy: 0.001,
                       "\(file): last debit", file: testFile, line: line)
        XCTAssertEqual(last.credit, pin.lastCredit, accuracy: 0.001,
                       "\(file): last credit", file: testFile, line: line)
        XCTAssertEqual(last.balance ?? .nan, pin.lastBalance, accuracy: 0.001,
                       "\(file): last balance", file: testFile, line: line)

        // 6. With the summary rows excluded and the opening seed in place the
        //    running-balance chain reconciles end-to-end (it used to break at
        //    the leaked summary row).
        var prev: Double? = nil
        var chainBreaks: [String] = []
        for (i, r) in out.rows.enumerated() {
            if let p = prev, let b = r.balance,
               abs((p + r.credit - r.debit) - b) > 0.01, chainBreaks.count < 4 {
                chainBreaks.append("row \(i): \(p) + \(r.credit) - \(r.debit) != \(b) ('\(r.descr)')")
            }
            prev = r.balance
        }
        XCTAssertTrue(chainBreaks.isEmpty,
                      "\(file): running-balance chain broke — " + chainBreaks.joined(separator: " | "),
                      file: testFile, line: line)
    }

    // MARK: per-fixture checks

    func testBoiExcludesSummaryRows() throws { try check("boi_dummy_statement.pdf") }
    func testChaseExcludesSummaryRows() throws { try check("chase_dummy_statement.pdf") }
    func testLloydsExcludesSummaryRows() throws { try check("lloyds_dummy_statement.pdf") }
    func testMetrobankExcludesSummaryRows() throws { try check("metrobank_dummy_statement.pdf") }
    func testSantanderExcludesSummaryRows() throws { try check("santander_dummy_statement.pdf") }
    func testTsbExcludesSummaryRows() throws { try check("tsb_dummy_statement.pdf") }
    func testRevolutExcludesSummaryRows() throws { try check("revolut_dummy_statement.pdf") }

    // MARK: targeted regressions

    /// chase: the BEGINNING BALANCE row used to leak as a 1,250.00 credit with
    /// balance 0 at row 0, and (because the running balance was still nil) the
    /// ZELLE row after it fell back to cue words and was misread as a debit.
    func testChaseBeginningBalanceSeedFlipsZelleToCredit() throws {
        let out = try Self.ingest("chase_dummy_statement.pdf")
        XCTAssertFalse(out.rows.contains { $0.descr.lowercased().contains("beginning balance") },
                       "BEGINNING BALANCE must not ingest as a transaction")
        guard let zelle = out.rows.first(where: { $0.descr == "ZELLE TRANSFER RECEIVED" }) else {
            XCTFail("chase: ZELLE TRANSFER RECEIVED row missing")
            return
        }
        XCTAssertEqual(zelle.credit, 649.99, accuracy: 0.001,
                       "ZELLE row must classify as a credit via the seeded balance delta")
        XCTAssertEqual(zelle.debit, 0, accuracy: 0.001,
                       "ZELLE row must carry no debit")
    }

    /// UK layouts: the CARRIED FORWARD row also used to swallow the statement
    /// footer ("This is a computer-generated SYNTHETIC statement…"); with the
    /// row excluded, the footer must not stitch into any surviving row either.
    func testCarriedForwardFooterDoesNotStitchIntoRealRows() throws {
        for file in ["boi_dummy_statement.pdf", "lloyds_dummy_statement.pdf",
                     "metrobank_dummy_statement.pdf", "santander_dummy_statement.pdf",
                     "tsb_dummy_statement.pdf", "revolut_dummy_statement.pdf"] {
            let out = try Self.ingest(file)
            XCTAssertFalse(out.rows.contains { $0.descr.lowercased().contains("computer-generated") },
                           "\(file): statement footer text leaked into a transaction description")
        }
    }
}
