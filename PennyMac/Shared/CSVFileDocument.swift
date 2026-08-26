import SwiftUI
import UniformTypeIdentifiers

/// A read-only CSV document for SwiftUI's `.fileExporter` — works identically on
/// macOS and iOS (Fix 7). The bytes come from `TxnCSVExport`, which is pure and
/// unit-tested; this type only adapts them to the platform save/share sheet.
struct CSVFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    static var writableContentTypes: [UTType] { [.commaSeparatedText] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
