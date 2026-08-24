import XCTest
@testable import PennyTxnStore

/// The dependency-free .xlsx reader: end-to-end against the NatWest demo
/// workbook (same synthetic statement as the PDF conformance fixture, so the
/// expected figures are cross-checked against that contract), plus unit checks
/// on the two conversions most likely to rot — A1-style column refs and Excel
/// serial dates.
final class XLSXIngestTests: XCTestCase {

    func testNatWestWorkbookMatchesPDFFixtureFigures() throws {
        let path = TestPaths.testDataDir.appendingPathComponent("NatWest_Demo_Statement.xlsx").path
        let ingester = try TestPaths.makeIngester()
        let out = try ingester.ingestXLSX(path: path)

        XCTAssertEqual(out.rows.count, 37, "row count must match the PDF fixture")
        XCTAssertEqual(out.detectedCurrency, "GBP")
        XCTAssertFalse(out.isCard)

        let debits = out.rows.reduce(0) { $0 + $1.debit }
        let credits = out.rows.reduce(0) { $0 + $1.credit }
        XCTAssertEqual(debits, 1948.55, accuracy: 0.01, "debit sum must match the PDF fixture")
        XCTAssertEqual(credits, 3498.74, accuracy: 0.01, "credit sum must match the PDF fixture")

        let first = try XCTUnwrap(out.rows.first)
        XCTAssertEqual(first.txnDate, "2026-06-01")
        XCTAssertEqual(first.descr, "TESCO STORES 2431 PATNA")
        XCTAssertEqual(first.debit, 42.15, accuracy: 0.001)
        XCTAssertEqual(first.category, "Groceries")
        XCTAssertEqual(first.balance ?? 0, 2407.85, accuracy: 0.001)
    }

    func testNonWorkbookBytesThrow() {
        let tmp = TestPaths.tempDBPath("notaworkbook") + ".xlsx"
        FileManager.default.createFile(atPath: tmp, contents: Data("junk".utf8))
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        XCTAssertThrowsError(try XLSXIngest.ingest(path: tmp,
                                                   categories: try! Categories(categoriesJSONPath: TestPaths.categoriesJSON.path)))
    }

    func testColumnIndexParsesA1References() {
        typealias Sheet = XLSXIngest
        // Delegate is private; exercise via parseSheet on a hand-built cell.
        let xml = """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" t="str"><v>first</v></c><c r="C1" t="str"><v>third</v></c></row>
        </sheetData></worksheet>
        """
        let rows = Sheet.parseSheet(Data(xml.utf8), shared: [], dateStyles: [])
        XCTAssertEqual(rows, [["first", "", "third"]],
                       "skipped column B must pad with an empty cell")
    }

    func testDateSerialCellsConvertViaDateStyles() {
        // Style 0 is a date format; serial 46082 = 2026-03-01 (1900 system).
        let xml = """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" s="0" t="n"><v>46082</v></c><c r="B1" t="n"><v>46082</v></c></row>
        </sheetData></worksheet>
        """
        let rows = XLSXIngest.parseSheet(Data(xml.utf8), shared: [], dateStyles: [true])
        XCTAssertEqual(rows, [["2026-03-01", "46082"]],
                       "date-styled serials convert; plain numerics stay raw")
    }
}
