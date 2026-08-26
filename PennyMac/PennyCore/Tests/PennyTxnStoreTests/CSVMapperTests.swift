// CSVMapperTests — the "help me map this" fallback core (Fix 2).
import XCTest
@testable import PennyTxnStore

final class CSVMapperTests: XCTestCase {

    private var cats: Categories!
    override func setUpWithError() throws {
        cats = try Categories(categoriesJSONPath: TestPaths.categoriesJSON.path)
    }

    // A well-formed export the auto-detector already handles.
    private let standard: [[String]] = [
        ["Date", "Description", "Amount", "Balance"],
        ["2026-06-01", "TESCO", "-45.50", "954.50"],
        ["2026-06-05", "SALARY", "2500.00", "3454.50"],
    ]

    // Opaque headers the role synonyms won't recognize → needs the user.
    private let opaque: [[String]] = [
        ["Txn", "Narrative", "Value"],
        ["01/06/2026", "TESCO STORES", "-45.50"],
        ["05/06/2026", "MONTHLY SALARY", "2500.00"],
    ]

    func testStandardCSVNeedsNoHelp() {
        let a = CSVMapper.analyze(records: standard)
        XCTAssertNotNil(a)
        XCTAssertFalse(a!.needsHelp)
        XCTAssertEqual(a!.headerIdx, 0)
        XCTAssertNotNil(a!.suggested["date"])
        XCTAssertNotNil(a!.suggested["amount"])
    }

    func testOpaqueHeadersFlagMissingRoles() {
        let a = CSVMapper.analyze(records: opaque)!
        XCTAssertTrue(a.needsHelp)
        XCTAssertTrue(a.missingRequired.contains("date"))
        XCTAssertTrue(a.missingRequired.contains("amount"))
        XCTAssertEqual(a.headers, ["Txn", "Narrative", "Value"])
        XCTAssertEqual(a.sampleRows.count, 2)   // two data rows previewed
    }

    func testBuildRowsFromUserMapping() {
        // User maps: col0=date, col1=desc, col2=amount(signed).
        let out = CSVMapper.buildRows(records: opaque, headerIdx: 0,
                                      mapping: ["date": 0, "desc": 1, "amount": 2],
                                      categories: cats)
        XCTAssertEqual(out.rows.count, 2)
        XCTAssertEqual(out.confidence, "high")
        let tesco = out.rows.first { $0.descr.contains("TESCO") }
        XCTAssertEqual(tesco?.debit ?? 0, 45.50, accuracy: 0.001)   // negative → money out
        let salary = out.rows.first { $0.descr.contains("SALARY") }
        XCTAssertEqual(salary?.credit ?? 0, 2500.00, accuracy: 0.001) // positive → money in
    }

    func testSeparateDebitCreditMapping() {
        let records: [[String]] = [
            ["When", "What", "Out", "In"],
            ["2026-06-01", "TESCO", "45.50", ""],
            ["2026-06-05", "SALARY", "", "2500.00"],
        ]
        let out = CSVMapper.buildRows(records: records, headerIdx: 0,
                                      mapping: ["date": 0, "desc": 1, "debit": 2, "credit": 3],
                                      categories: cats)
        XCTAssertEqual(out.rows.count, 2)
        XCTAssertEqual(out.rows.first { $0.descr.contains("TESCO") }?.debit ?? 0, 45.50, accuracy: 0.001)
        XCTAssertEqual(out.rows.first { $0.descr.contains("SALARY") }?.credit ?? 0, 2500, accuracy: 0.001)
    }

    func testIsComplete() {
        XCTAssertTrue(CSVMapper.isComplete(["date": 0, "amount": 1]))
        XCTAssertTrue(CSVMapper.isComplete(["date": 0, "debit": 1]))
        XCTAssertFalse(CSVMapper.isComplete(["date": 0]))          // no money column
        XCTAssertFalse(CSVMapper.isComplete(["amount": 1]))        // no date
    }
}
