import Foundation
#if canImport(Vision) && canImport(PDFKit)
import Vision
import PDFKit
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

/// OCR for scanned / image-only PDFs. A digital statement has a selectable text
/// layer that `StatementText.extract` returns; a scanned one doesn't, so we render
/// each page to an image and run Apple Vision text recognition. The recognised
/// per-page text then feeds `ClaudeStatementExtractor` (the deterministic
/// positional parser needs embedded word coordinates it can't get from OCR).
enum ScannedPDFOCR {

    /// A statement is "scanned" when its selectable text is essentially empty.
    static func looksScanned(text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count < 40
    }

    /// OCR every page → recognised text, in reading order (top-to-bottom,
    /// left-to-right). Empty array if the PDF can't be opened.
    static func recognizePages(at url: URL, maxPages: Int = 24) async -> [String] {
        guard let doc = PDFDocument(url: url) else { return [] }
        var out: [String] = []
        for i in 0..<min(doc.pageCount, maxPages) {
            guard let page = doc.page(at: i), let cg = render(page) else { out.append(""); continue }
            out.append(await recognize(cg))
        }
        return out
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let rect = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0   // upscale so small statement type OCRs cleanly
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)
        #if canImport(AppKit)
        let image = page.thumbnail(of: size, for: .mediaBox)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return nil
        #endif
    }

    private static func recognize(_ cg: CGImage) async -> String {
        await withCheckedContinuation { cont in
            let request = VNRecognizeTextRequest { req, _ in
                let obs = (req.results as? [VNRecognizedTextObservation]) ?? []
                // Vision's y origin is bottom-up: sort by y descending (top first),
                // then x ascending within a line, so the text reads in table order.
                let lines = obs.sorted { a, b in
                    if abs(a.boundingBox.origin.y - b.boundingBox.origin.y) > 0.012 {
                        return a.boundingBox.origin.y > b.boundingBox.origin.y
                    }
                    return a.boundingBox.origin.x < b.boundingBox.origin.x
                }.compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([request])
        }
    }
}
#endif
