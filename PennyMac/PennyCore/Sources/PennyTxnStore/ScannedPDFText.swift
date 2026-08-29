// ScannedPDFText — on-device OCR for PDFs with no text layer (scans/photos).
//
// Renders each page via CoreGraphics and reads it with Vision. Observations
// are grouped into visual lines (top-to-bottom, left-to-right) so the output
// has the same "one field per line" shape UniversalRecordIngest expects.
// Fully offline on both platforms.
import Foundation
import CoreGraphics
import Vision

public enum ScannedPDFText {

    /// Whether the extracted text is too thin to be a real text layer —
    /// the signal to fall back to OCR.
    public static func looksScanned(_ pages: [String], pageCount: Int) -> Bool {
        pageCount > 0 && pages.joined().count < 80 * pageCount / 4
    }

    /// OCR every page of the PDF at `path` into linearized text lines.
    public static func ocrPages(path: String, dpi: CGFloat = 220) -> [String] {
        guard let doc = CGPDFDocument(URL(fileURLWithPath: path) as CFURL) else { return [] }
        var out: [String] = []
        for i in 1...max(1, doc.numberOfPages) {
            guard let page = doc.page(at: i) else { out.append(""); continue }
            guard let img = render(page: page, dpi: dpi) else { out.append(""); continue }
            out.append(recognizeLines(in: img))
        }
        return out
    }

    private static func render(page: CGPDFPage, dpi: CGFloat) -> CGImage? {
        let box = page.getBoxRect(.mediaBox)
        let scale = dpi / 72.0
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard w > 0, h > 0, w * h < 60_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    private static func recognizeLines(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false   // account numbers/amounts must not be "corrected"
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results else { return "" }

        // Group observations into visual lines by y-centre proximity.
        struct Frag { let x: CGFloat; let y: CGFloat; let text: String }
        var frags: [Frag] = []
        for o in obs {
            guard let cand = o.topCandidates(1).first else { continue }
            let b = o.boundingBox   // normalized, origin bottom-left
            frags.append(Frag(x: b.midX, y: 1 - b.midY, text: cand.string))
        }
        frags.sort { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
        var lines: [[Frag]] = []
        for f in frags {
            if let last = lines.last, let ref = last.first, abs(f.y - ref.y) < 0.012 {
                lines[lines.count - 1].append(f)
            } else {
                lines.append([f])
            }
        }
        return lines.map { line in
            line.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ")
        }.joined(separator: "\n")
    }
}
