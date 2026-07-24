// PDFExtractorTests — guards the MuPDF-parity CGPDF text extractor that the
// whole deterministic parser stack sits on. It pins page counts, exact per-page
// text lengths (unicode scalars, matching pymupdf's code-point lengths), known
// substrings, word counts and word bounding boxes for three representative
// documents ground-truthed via `penny-conformance dump-text` / `dump-words`:
// a simple Latin-1 ReportLab statement (Coop), the WeasyPrint Type0/CID
// Identity-H statement (Wrenfield — where a CID-decode regression would garble
// every glyph), and the multi-page rotated-watermark HSBC specimen. It also
// checks word-geometry invariants (ordered, finite, whitespace-free boxes),
// re-extraction determinism, Info-dictionary metadata, out-of-range page
// handling, and that unopenable/non-PDF inputs throw rather than crash.
import XCTest
@testable import PennyTxnStore

final class PDFExtractorTests: XCTestCase {

    private static let coopPath =
        TestPaths.testDataDir.appendingPathComponent("Coop_Demo_Statement.pdf").path
    private static let wrenfieldPath =
        TestPaths.testDataDir.appendingPathComponent("Wrenfield_Bank_Statement_Tinku_Kesariya-1.pdf").path
    private static let hsbcPath =
        TestPaths.testDataDir.appendingPathComponent("specimen_hsbc_uk_statement.pdf").path

    /// pymupdf-parity text length: dump-text lengths were measured in unicode
    /// code points, which map 1:1 to Swift unicode scalars.
    private func scalarCount(_ s: String) -> Int { s.unicodeScalars.count }

    private func assertWordGeometry(_ page: ExtractedPage, label: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        var violations: [String] = []
        for (i, w) in page.words.enumerated() where violations.count < 6 {
            if w.text.isEmpty { violations.append("word \(i) empty") }
            if w.text.contains(where: { $0.isWhitespace }) {
                violations.append("word \(i) '\(w.text)' contains whitespace")
            }
            if ![w.x0, w.y0, w.x1, w.y1].allSatisfy({ $0.isFinite }) {
                violations.append("word \(i) '\(w.text)' non-finite bbox")
            }
            if w.x0 > w.x1 || w.y0 > w.y1 {
                violations.append("word \(i) '\(w.text)' inverted bbox (\(w.x0),\(w.y0))-(\(w.x1),\(w.y1))")
            }
            if w.x0 < -1 || w.y0 < -1 {
                violations.append("word \(i) '\(w.text)' negative origin (\(w.x0),\(w.y0))")
            }
        }
        XCTAssertTrue(violations.isEmpty,
                      "\(label): word geometry violated — " + violations.joined(separator: " | "),
                      file: file, line: line)
    }

    // MARK: simple Latin fixture (ReportLab, base-14 fonts)

    func testCoopSimpleStatementExtraction() throws {
        let ex = try PDFTextExtractor(path: Self.coopPath)
        XCTAssertEqual(ex.pageCount, 2, "Coop demo statement is a 2-page PDF")

        let p0 = try XCTUnwrap(ex.page(0), "page 0 must extract")
        XCTAssertGreaterThan(p0.width, 0)
        XCTAssertGreaterThan(p0.height, 0)
        XCTAssertEqual(scalarCount(p0.text), 2061,
                       "page 0 text length drifted from dump-text ground truth")
        XCTAssertTrue(p0.text.contains("The Co-operative Bank — SAMPLE / DEMO STATEMENT (SYNTHETIC DATA,"),
                      "page 0 header line missing/garbled")
        XCTAssertTrue(p0.text.contains("Account Number: 1122 3344 5566 78 (fictional)"),
                      "account-number line missing — digit or spacing extraction broke")
        XCTAssertTrue(p0.text.contains("Sort Code: 08-92-99 (fictional)"))
        XCTAssertTrue(p0.text.contains("TESCO STORES 2431 PATNA"),
                      "first transaction description missing from page text")
        XCTAssertEqual(p0.words.count, 281, "page 0 word count drifted")
        let first = try XCTUnwrap(p0.words.first)
        XCTAssertEqual(first.text, "The")
        XCTAssertEqual(first.x0, 60.7258, accuracy: 0.05, "first word x0 drifted")
        XCTAssertEqual(first.y0, 69.7829, accuracy: 0.05, "first word y0 drifted")
        XCTAssertEqual(first.x1, 83.8398, accuracy: 0.05, "first word x1 drifted")
        XCTAssertEqual(first.y1, 87.6839, accuracy: 0.05, "first word y1 drifted")
        XCTAssertEqual(p0.words.last?.text, "3,738.33",
                       "last word of page 0 should be the final balance figure")
        assertWordGeometry(p0, label: "Coop page 0")

        let p1 = try XCTUnwrap(ex.page(1), "page 1 must extract")
        XCTAssertEqual(scalarCount(p1.text), 571, "page 1 text length drifted")
        XCTAssertEqual(p1.words.count, 73, "page 1 word count drifted")
        XCTAssertTrue(p1.text.contains("DIRECT DEBIT - THAMES WATER"))
        XCTAssertTrue(p1.text.contains("TRANSFER FROM R PATEL"))
        assertWordGeometry(p1, label: "Coop page 1")
    }

    // MARK: Type0/CID (Identity-H) fixture — the hard case

    func testWrenfieldType0CIDExtraction() throws {
        let ex = try PDFTextExtractor(path: Self.wrenfieldPath)
        XCTAssertEqual(ex.pageCount, 51, "Wrenfield statement is a 51-page PDF")

        let p0 = try XCTUnwrap(ex.page(0), "page 0 must extract")
        XCTAssertEqual(scalarCount(p0.text), 879,
                       "page 0 text length drifted — CID/ToUnicode decode changed")
        // Readable brand + person names prove 2-byte CID codes map through
        // ToUnicode correctly; garbled output here means the decode broke.
        XCTAssertTrue(p0.text.contains("wrenfield"), "brand word missing — CID decode broken")
        XCTAssertTrue(p0.text.contains("Tinku Kesariya"), "account holder name missing")
        XCTAssertTrue(p0.text.contains("Total balance"))
        XCTAssertTrue(p0.text.contains("£2,171.15"),
                      "GBP total-balance figure missing — currency glyph or digits garbled")
        XCTAssertTrue(p0.text.contains("-£25,863.36"), "total-outgoings figure missing")
        XCTAssertTrue(p0.text.contains("COSTA COFFEE LUTON GBR (pending)"),
                      "newest transaction line missing")
        XCTAssertEqual(p0.words.count, 122, "page 0 word count drifted")
        XCTAssertEqual(p0.words.first?.text, "wrenfield", "first word drifted")
        assertWordGeometry(p0, label: "Wrenfield page 0")

        let last = try XCTUnwrap(ex.page(50), "last page must extract")
        XCTAssertEqual(scalarCount(last.text), 621, "last page text length drifted")
        XCTAssertTrue(last.text.contains("SAINSBURYS LUTON GBR"))

        // No page of the statement may extract empty: a mid-document collapse
        // silently halves the parsed transaction count.
        for i in 0..<ex.pageCount {
            let pg = ex.page(i)
            XCTAssertNotNil(pg, "page \(i) failed to extract")
            XCTAssertFalse(pg?.text.isEmpty ?? true, "page \(i) extracted empty text")
        }
    }

    // MARK: multi-page + rotated watermark fixture

    func testHSBCSpecimenPerPageLengthsStable() throws {
        let ex = try PDFTextExtractor(path: Self.hsbcPath)
        XCTAssertEqual(ex.pageCount, 4, "HSBC specimen is a 4-page PDF")
        let expectedTextLens = [1976, 2164, 2190, 1286]
        let expectedWordCounts = [325, 367, 366, 211]
        for i in 0..<4 {
            let pg = try XCTUnwrap(ex.page(i), "page \(i) must extract")
            XCTAssertEqual(scalarCount(pg.text), expectedTextLens[i],
                           "page \(i) text length drifted from dump-text ground truth")
            XCTAssertEqual(pg.words.count, expectedWordCounts[i],
                           "page \(i) word count drifted from dump-words ground truth")
        }
        let p0 = try XCTUnwrap(ex.page(0))
        // The rotated SPECIMEN watermark must not swallow the body text.
        XCTAssertTrue(p0.text.contains("HSBC UK  (SPECIMEN / FICTIONAL SAMPLE)"))
        XCTAssertTrue(p0.text.contains("Current Account Statement"))
        XCTAssertEqual(p0.words.last?.text, "3,921.10",
                       "last word of page 0 should be the final balance on the page")
        let p3 = try XCTUnwrap(ex.page(3))
        XCTAssertTrue(p3.text.contains("INTEREST PAID"))
        assertWordGeometry(p0, label: "HSBC page 0")
    }

    // MARK: determinism + caching

    func testReExtractionIsDeterministic() throws {
        let a = try XCTUnwrap(try PDFTextExtractor(path: Self.wrenfieldPath).page(0))
        let b = try XCTUnwrap(try PDFTextExtractor(path: Self.wrenfieldPath).page(0))
        XCTAssertEqual(a.text, b.text, "re-extraction produced different text")
        XCTAssertEqual(a.words.count, b.words.count, "re-extraction produced different word count")
        for (i, (wa, wb)) in zip(a.words, b.words).enumerated() {
            if wa.text != wb.text || wa.x0 != wb.x0 || wa.y0 != wb.y0
                || wa.x1 != wb.x1 || wa.y1 != wb.y1 {
                XCTFail("word \(i) not reproducible: '\(wa.text)'@(\(wa.x0),\(wa.y0)) vs '\(wb.text)'@(\(wb.x0),\(wb.y0))")
                break
            }
        }
        // Cached second read of the same instance must return identical content.
        let ex = try PDFTextExtractor(path: Self.coopPath)
        let first = try XCTUnwrap(ex.page(0)).text
        let second = try XCTUnwrap(ex.page(0)).text
        XCTAssertEqual(first, second, "page cache returned different text on the second read")
    }

    // MARK: metadata

    func testMetadataMatchesInfoDictionary() throws {
        let coop = try PDFTextExtractor(path: Self.coopPath)
        XCTAssertEqual(coop.metadata["producer"], "ReportLab PDF Library - (opensource)")
        XCTAssertEqual(coop.metadata["title"], "(anonymous)")
        XCTAssertEqual(coop.metadata["author"], "(anonymous)")
        XCTAssertEqual(coop.metadata["creator"], "(unspecified)")

        let wren = try PDFTextExtractor(path: Self.wrenfieldPath)
        XCTAssertEqual(wren.metadata, ["producer": "WeasyPrint 69.0"],
                       "Wrenfield Info dict should carry exactly one key (producer)")
    }

    // MARK: edge cases

    func testPageIndexOutOfRangeReturnsNil() throws {
        let ex = try PDFTextExtractor(path: Self.coopPath)
        XCTAssertNil(ex.page(-1), "negative page index must return nil")
        XCTAssertNil(ex.page(ex.pageCount), "page index == pageCount must return nil")
        XCTAssertNil(ex.page(Int.max), "huge page index must return nil")
    }

    func testMissingFileThrowsCannotOpen() {
        let missing = NSTemporaryDirectory() + "penny_extractor_missing_\(UUID().uuidString).pdf"
        XCTAssertThrowsError(try PDFTextExtractor(path: missing)) { error in
            guard case PDFTextExtractorError.cannotOpen(let p) = error else {
                return XCTFail("expected cannotOpen, got \(error)")
            }
            XCTAssertEqual(p, missing, "error should carry the offending path")
        }
    }

    func testNonPDFFileThrowsCannotOpen() throws {
        let junkPath = NSTemporaryDirectory() + "penny_extractor_junk_\(UUID().uuidString).pdf"
        try "this is definitely not a PDF document".write(toFile: junkPath,
                                                          atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: junkPath) }
        XCTAssertThrowsError(try PDFTextExtractor(path: junkPath)) { error in
            guard case PDFTextExtractorError.cannotOpen = error else {
                return XCTFail("expected cannotOpen for junk bytes, got \(error)")
            }
        }
    }
}
