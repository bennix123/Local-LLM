import XCTest
import CoreGraphics
import CoreText
@testable import PennyTxnStore

/// End-to-end scanned-statement proof: draw a synthetic statement into a
/// PURE-IMAGE PDF (no text layer at all), then run the full ingest chain.
/// The universal fallback must OCR it and pass the balance-chain gate.
final class ScannedPDFOCRTests: XCTestCase {

    private func makeImageOnlyPDF(lines: [String]) throws -> String {
        let w = 1240, h = 1754   // ~A4 @150dpi
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        var y = CGFloat(h) - 80
        for line in lines {
            let attr = NSAttributedString(string: line, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            ])
            let ct = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 80, y: y)
            CTLineDraw(ct, ctx)
            y -= 44
        }
        let img = try XCTUnwrap(ctx.makeImage())

        let path = NSTemporaryDirectory() + "penny_scan_test_\(UUID().uuidString.prefix(8)).pdf"
        var mediaBox = CGRect(x: 0, y: 0, width: 620, height: 877)
        let pdf = try XCTUnwrap(CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &mediaBox, nil))
        pdf.beginPDFPage(nil)
        pdf.draw(img, in: mediaBox)
        pdf.endPDFPage()
        pdf.closePDF()
        return path
    }

    func testImageOnlyPDFIsOCRedAndBalanceVerified() throws {
        let path = try makeImageOnlyPDF(lines: [
            "Anybank Passbook",
            "01/03/2026",
            "SALARY CREDIT ACME LTD",
            "+ 1,000.00   5,000.00",
            "05/03/2026",
            "POS PURCHASE GROCERY MART",
            "- 250.00   4,750.00",
            "09/03/2026",
            "ATM WITHDRAWAL MAIN ST",
            "- 500.00   4,250.00",
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Sanity: this PDF really has no text layer.
        let doc = try PDFTextExtractor(path: path)
        let rawText = (0..<doc.pageCount).compactMap { doc.page($0)?.text }.joined()
        XCTAssertLessThan(rawText.count, 10, "fixture must be image-only, got text: \(rawText)")

        let out = try TestPaths.makeIngester().ingestPDF(path: path)
        XCTAssertEqual(out.rows.count, 3, "OCR chain should read all three records")
        XCTAssertTrue(out.confidence.hasPrefix("universal-"), out.confidence)
        XCTAssertEqual(out.rows.map(\.txnDate), ["2026-03-01", "2026-03-05", "2026-03-09"])
        XCTAssertEqual(out.rows[0].credit, 1000, accuracy: 0.01)
        XCTAssertEqual(out.rows[2].debit, 500, accuracy: 0.01)
        XCTAssertEqual(out.rows[2].balance ?? 0, 4250, accuracy: 0.01)
    }
}
