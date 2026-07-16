import Foundation
import PDFKit

/// PDF → plain text with page markers. PDFKit is native and sandbox-safe.
/// (Table-aware extraction — FinQuery's camelot layer — comes later; the slice
/// just needs selectable text.)
public enum StatementText {
    public static func extract(from url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else {
            throw NSError(
                domain: "Penny", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not open PDF: \(url.lastPathComponent)"]
            )
        }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            if let text = doc.page(at: i)?.string, !text.isEmpty {
                pages.append("--- page \(i + 1) ---\n\(text)")
            }
        }
        return pages.joined(separator: "\n\n")
    }
}
