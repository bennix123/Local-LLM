// ConformanceContractTests — XCTest port of the `penny-conformance run` contract.
// Guards the deterministic ingest pipeline end-to-end: every bank-statement fixture
// PDF in finquery/contract/fixtures must flow through TxnIngester.ingestPDF →
// TxnDB.insert → TxnDB.conformanceRows and EXACT-match its *_expected.json — same
// row count and order (ORDER BY seq), and per row the same date, description,
// debit, credit, balance (including SQL-NULL balances), category and bank label,
// using the identical comparison semantics as the runner (NSNumber.doubleValue
// coercion, missing debit/credit → 0, NSNull bank → nil, exact Double equality,
// no rounding). An inventory test pins the 22-fixture contract so deleting a
// fixture — or dropping a new one in untested — fails loudly instead of silently.

import XCTest
@testable import PennyTxnStore

final class ConformanceContractTests: XCTestCase {

    // MARK: - Fixture inventory

    /// The 22 contract fixture stems: each must have "<stem>.pdf" and
    /// "<stem>_expected.json" in TestPaths.fixturesDir.
    /// NOTE: the Barclays stem intentionally contains a DOUBLE space between
    /// "73519392" and "06053808" — that is the real on-disk filename.
    private static let fixtureStems: [String] = [
        "Coop_Demo_Statement",
        "DeutscheBank_Demo_Statement",
        "GoldmanSachs_Demo_Statement",
        "Handelsbanken_Demo_Statement",
        "NatWest_Demo_Statement",
        "Nationwide_Demo_Statement",
        "Starling_Demo_Statement",
        "Statement 05-MAR-26 AC 73519392  06053808 barckley",
        "boi_dummy_statement",
        "chase_dummy_statement",
        "lloyds_dummy_statement",
        "metrobank_dummy_statement",
        "revolut_dummy_statement",
        "santander_dummy_statement",
        "specimen_bnp_paribas_statement",
        "specimen_coutts_statement",
        "specimen_credit_suisse_statement",
        "specimen_hsbc_uk_statement",
        "specimen_monzo_statement",
        "specimen_standard_chartered_statement",
        "specimen_virgin_money_statement",
        "tsb_dummy_statement",
    ]

    private static let barclaysStem = "Statement 05-MAR-26 AC 73519392  06053808 barckley"

    /// All 22 fixture pairs must exist — guards against fixtures being deleted
    /// or renamed silently (which would shrink the contract without any failure).
    func testAll22ExpectedFixturesPresent() {
        XCTAssertEqual(Self.fixtureStems.count, 22,
                       "the contract is defined as exactly 22 fixtures; the hardcoded list drifted")
        let fm = FileManager.default
        for stem in Self.fixtureStems {
            let pdf = TestPaths.fixturesDir.appendingPathComponent(stem + ".pdf").path
            let exp = TestPaths.fixturesDir.appendingPathComponent(stem + "_expected.json").path
            XCTAssertTrue(fm.fileExists(atPath: pdf),
                          "contract fixture PDF missing: \(stem).pdf (deleted or renamed?)")
            XCTAssertTrue(fm.fileExists(atPath: exp),
                          "expected JSON missing: \(stem)_expected.json (deleted or renamed?)")
        }
    }

    /// Every *.pdf in the fixtures dir must be part of the known contract. A new
    /// fixture must be added to `fixtureStems` and given its own test method —
    /// otherwise it would sit in the directory untested by this suite.
    func testFixtureDirectoryMatchesKnownContract() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: TestPaths.fixturesDir.path)
        let pdfStems = Set(names.filter { $0.hasSuffix(".pdf") }.map { String($0.dropLast(4)) })
        let known = Set(Self.fixtureStems)
        let extra = pdfStems.subtracting(known).sorted()
        XCTAssertTrue(extra.isEmpty,
                      "fixture PDFs not covered by this suite (add to fixtureStems + a test method): \(extra)")
        let missing = known.subtracting(pdfStems).sorted()
        XCTAssertTrue(missing.isEmpty, "contract fixture PDFs missing from directory: \(missing)")
    }

    // MARK: - Per-fixture conformance (one test per PDF for triage granularity)

    func testCoopDemoStatementConforms()            { runConformance(stem: "Coop_Demo_Statement") }
    func testDeutscheBankDemoStatementConforms()    { runConformance(stem: "DeutscheBank_Demo_Statement") }
    func testGoldmanSachsDemoStatementConforms()    { runConformance(stem: "GoldmanSachs_Demo_Statement") }
    func testHandelsbankenDemoStatementConforms()   { runConformance(stem: "Handelsbanken_Demo_Statement") }
    func testNatWestDemoStatementConforms()         { runConformance(stem: "NatWest_Demo_Statement") }
    func testNationwideDemoStatementConforms()      { runConformance(stem: "Nationwide_Demo_Statement") }
    func testStarlingDemoStatementConforms()        { runConformance(stem: "Starling_Demo_Statement") }
    func testBarclaysStatementConforms()            { runConformance(stem: Self.barclaysStem) }
    func testBOIDummyStatementConforms()            { runConformance(stem: "boi_dummy_statement") }
    func testChaseDummyStatementConforms()          { runConformance(stem: "chase_dummy_statement") }
    func testLloydsDummyStatementConforms()         { runConformance(stem: "lloyds_dummy_statement") }
    func testMetroBankDummyStatementConforms()      { runConformance(stem: "metrobank_dummy_statement") }
    func testRevolutDummyStatementConforms()        { runConformance(stem: "revolut_dummy_statement") }
    func testSantanderDummyStatementConforms()      { runConformance(stem: "santander_dummy_statement") }
    func testBNPParibasSpecimenConforms()           { runConformance(stem: "specimen_bnp_paribas_statement") }
    func testCouttsSpecimenConforms()               { runConformance(stem: "specimen_coutts_statement") }
    func testCreditSuisseSpecimenConforms()         { runConformance(stem: "specimen_credit_suisse_statement") }
    func testHSBCUKSpecimenConforms()               { runConformance(stem: "specimen_hsbc_uk_statement") }
    func testMonzoSpecimenConforms()                { runConformance(stem: "specimen_monzo_statement") }
    func testStandardCharteredSpecimenConforms()    { runConformance(stem: "specimen_standard_chartered_statement") }
    func testVirginMoneySpecimenConforms()          { runConformance(stem: "specimen_virgin_money_statement") }
    func testTSBDummyStatementConforms()            { runConformance(stem: "tsb_dummy_statement") }

    // MARK: - Edge cases the contract depends on

    /// Barclays fixture: rows without a printed balance must round-trip through
    /// SQLite as NULL (nil in StoredRow), never coerced to 0.0. Ground truth from
    /// the expected JSON: exactly rows 1 (O2 direct debit) and 2 (cricket-club
    /// card payment) have "balance": null; rows 0 and 3 carry real balances.
    func testBarclaysNullBalancesRoundTripAsSQLNull() throws {
        let pdfName = Self.barclaysStem + ".pdf"
        let ingester = try TestPaths.makeIngester()
        let output = try ingester.ingestPDF(
            path: TestPaths.fixturesDir.appendingPathComponent(pdfName).path)
        let db = try makeTempDB(label: "barclays_null")
        db.insert(rows: output.rows, userID: "u", docName: pdfName, bankName: output.bankName)
        let rows = db.conformanceRows(userID: "u")

        guard rows.count == 6 else {
            XCTFail("Barclays fixture must yield 6 rows, got \(rows.count)")
            return
        }
        let nullIdx = rows.enumerated().filter { $0.element.balance == nil }.map { $0.offset }
        XCTAssertEqual(nullIdx, [1, 2],
                       "exactly rows 1 and 2 must have NULL balances, got NULLs at \(nullIdx)")
        XCTAssertEqual(rows[0].balance, 20.36, "row 0 balance must survive the SQLite round trip")
        XCTAssertEqual(rows[3].balance, 97.16, "row 3 balance must survive the SQLite round trip")
        XCTAssertEqual(rows.compactMap(\.bank), Array(repeating: "Barclays Bank", count: 6),
                       "every Barclays row must carry the bank label 'Barclays Bank'")
    }

    /// The runner stores every fixture in ONE shared DB keyed by userID and reads
    /// back with `conformanceRows(userID:)` — two fixtures sharing a DB must not
    /// bleed into each other's result sets, and deleteUser must fully clear one
    /// user without touching the other.
    func testSharedDBIsolationAndDeleteUser() throws {
        let ingester = try TestPaths.makeIngester()
        let barclays = try ingester.ingestPDF(
            path: TestPaths.fixturesDir.appendingPathComponent(Self.barclaysStem + ".pdf").path)
        let coop = try ingester.ingestPDF(
            path: TestPaths.fixturesDir.appendingPathComponent("Coop_Demo_Statement.pdf").path)

        let db = try makeTempDB(label: "isolation")
        db.insert(rows: barclays.rows, userID: "user_barclays",
                  docName: "barclays.pdf", bankName: barclays.bankName)
        db.insert(rows: coop.rows, userID: "user_coop",
                  docName: "coop.pdf", bankName: coop.bankName)

        XCTAssertEqual(db.conformanceRows(userID: "user_barclays").count, 6,
                       "user_barclays must see exactly its own 6 rows")
        XCTAssertEqual(db.conformanceRows(userID: "user_coop").count, 37,
                       "user_coop must see exactly its own 37 rows")
        XCTAssertTrue(db.conformanceRows(userID: "user_nobody").isEmpty,
                      "unknown user must see zero rows")

        db.deleteUser(userID: "user_barclays")
        XCTAssertTrue(db.conformanceRows(userID: "user_barclays").isEmpty,
                      "deleteUser must remove all of user_barclays' rows")
        XCTAssertEqual(db.conformanceRows(userID: "user_coop").count, 37,
                       "deleteUser(user_barclays) must not touch user_coop's rows")
    }

    // MARK: - Core comparison (replicates `penny-conformance run` semantics)

    /// Ingest one fixture PDF and exact-match the stored rows against its
    /// expected JSON. Comparison is field-for-field identical to the runner:
    ///   - date / description / category vs (expected as? String ?? "")
    ///   - debit / credit vs NSNumber.doubleValue with missing → 0, exact ==
    ///   - balance vs optional Double (NSNull/missing → nil), exact ==
    ///   - bank vs optional String (NSNull → nil)
    /// Row-count mismatch short-circuits field comparison, like the runner.
    private func runConformance(stem: String,
                                file: StaticString = #filePath,
                                line: UInt = #line) {
        let pdfName = stem + ".pdf"
        let fm = FileManager.default
        let pdfPath = TestPaths.fixturesDir.appendingPathComponent(pdfName).path
        let expectedPath = TestPaths.fixturesDir
            .appendingPathComponent(stem + "_expected.json").path

        guard fm.fileExists(atPath: pdfPath) else {
            XCTFail("\(pdfName): fixture PDF missing at \(pdfPath)", file: file, line: line)
            return
        }
        guard let expData = fm.contents(atPath: expectedPath),
              let expected = (try? JSONSerialization.jsonObject(with: expData)) as? [[String: Any]]
        else {
            XCTFail("\(pdfName): missing/unreadable expected JSON at \(expectedPath)",
                    file: file, line: line)
            return
        }

        let got: [TxnDB.StoredRow]
        do {
            let ingester = try TestPaths.makeIngester()
            let output = try ingester.ingestPDF(path: pdfPath)
            let db = try makeTempDB(label: "conformance")
            let userID = "conformance_test_\(pdfName)"
            db.insert(rows: output.rows, userID: userID, docName: pdfName,
                      bankName: output.bankName)
            got = db.conformanceRows(userID: userID)
        } catch {
            XCTFail("\(pdfName): ingest failed: \(error)", file: file, line: line)
            return
        }

        guard got.count == expected.count else {
            XCTFail("\(pdfName): row count mismatch — got \(got.count), want \(expected.count)",
                    file: file, line: line)
            return
        }

        // Same coercion as the runner's local num(): nil/NSNull → nil, else doubleValue.
        func num(_ v: Any?) -> Double? {
            if v == nil || v is NSNull { return nil }
            return (v as? NSNumber)?.doubleValue
        }
        func fmt(_ v: Double?) -> String { v.map { String($0) } ?? "NULL" }
        func fmt(_ v: String?) -> String { v.map { "\"\($0)\"" } ?? "NULL" }

        let maxDetailedFailures = 8
        var mismatchedRows = 0
        for (i, (g, e)) in zip(got, expected).enumerated() {
            var diffs: [String] = []
            let wantDate = e["date"] as? String ?? ""
            if g.date != wantDate {
                diffs.append("date got \"\(g.date)\" want \"\(wantDate)\"")
            }
            let wantDescr = e["description"] as? String ?? ""
            if g.description != wantDescr {
                diffs.append("description got \"\(g.description)\" want \"\(wantDescr)\"")
            }
            let wantDebit = num(e["debit"]) ?? 0
            if g.debit != wantDebit {
                diffs.append("debit got \(g.debit) want \(wantDebit)")
            }
            let wantCredit = num(e["credit"]) ?? 0
            if g.credit != wantCredit {
                diffs.append("credit got \(g.credit) want \(wantCredit)")
            }
            let wantBalance = num(e["balance"])
            if g.balance != wantBalance {
                diffs.append("balance got \(fmt(g.balance)) want \(fmt(wantBalance))")
            }
            let wantCategory = e["category"] as? String ?? ""
            if g.category != wantCategory {
                diffs.append("category got \"\(g.category)\" want \"\(wantCategory)\"")
            }
            let wantBank: String? = e["bank"] is NSNull ? nil : e["bank"] as? String
            if g.bank != wantBank {
                diffs.append("bank got \(fmt(g.bank)) want \(fmt(wantBank))")
            }
            if !diffs.isEmpty {
                mismatchedRows += 1
                if mismatchedRows <= maxDetailedFailures {
                    XCTFail("\(pdfName) row \(i): " + diffs.joined(separator: "; "),
                            file: file, line: line)
                }
            }
        }
        if mismatchedRows > maxDetailedFailures {
            XCTFail("\(pdfName): \(mismatchedRows) of \(got.count) rows mismatched "
                    + "(first \(maxDetailedFailures) detailed above)",
                    file: file, line: line)
        }
    }

    /// Fresh throwaway TxnDB whose files (.db/-wal/-shm) are removed at teardown.
    private func makeTempDB(label: String) throws -> TxnDB {
        let dbPath = TestPaths.tempDBPath(label)
        addTeardownBlock {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: dbPath + suffix)
            }
        }
        return try TxnDB(path: dbPath)
    }
}
