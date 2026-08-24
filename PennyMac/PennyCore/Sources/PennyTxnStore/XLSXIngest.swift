// XLSXIngest — minimal, dependency-free .xlsx reader for statement ingestion.
//
// An .xlsx file is a ZIP of XML parts. Bank exports are small and vanilla, so a
// full OOXML library is overkill (and PennyCore deliberately carries no
// third-party deps — same reasoning as the hand-rolled PDF extractor and HTTP
// server). This reads just enough of the format:
//
//   - ZIP central directory + raw-DEFLATE entries (Compression framework)
//   - xl/sharedStrings.xml     (cell type "s" indirection)
//   - xl/styles.xml            (which numeric styles mean "this is a date")
//   - xl/worksheets/sheetN.xml (rows → [[String]], same matrix CSVIngest eats)
//
// Out of scope, by design: formulas (their cached <v> is used), .xls (the 1997
// binary format), encrypted workbooks, ZIP64 (statements never get that big).
import Foundation
import Compression

enum XLSXIngest {

    enum XLSXError: Error, LocalizedError {
        case notAZip, missingSheet, badEntry(String)
        var errorDescription: String? {
            switch self {
            case .notAZip: return "not a valid .xlsx (zip) file"
            case .missingSheet: return "no worksheet found in the workbook"
            case .badEntry(let n): return "corrupt workbook entry: \(n)"
            }
        }
    }

    /// Read the workbook and ingest the first sheet that yields transactions,
    /// through the exact same header-discovery pipeline as CSV.
    static func ingest(path: String, categories: Categories) throws -> IngestOutput {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let zip = try ZipArchive(data: data)

        let shared = (try? zip.extract("xl/sharedStrings.xml")).map(parseSharedStrings) ?? []
        let dateStyles = (try? zip.extract("xl/styles.xml")).map(parseDateStyles) ?? []

        // Sheets in part order (sheet1, sheet2, …) — first with a parseable
        // statement wins; multi-sheet exports put the ledger on the first sheet.
        let sheetNames = zip.entryNames
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !sheetNames.isEmpty else { throw XLSXError.missingSheet }

        var lastOutput: IngestOutput? = nil
        for name in sheetNames {
            guard let xml = try? zip.extract(name) else { continue }
            let records = parseSheet(xml, shared: shared, dateStyles: dateStyles)
            guard !records.isEmpty else { continue }
            let out = CSVIngest.ingest(records: records, categories: categories)
            if !out.rows.isEmpty { return out }
            if lastOutput == nil { lastOutput = out }
        }
        return lastOutput ?? IngestOutput(rows: [], bankName: nil, confidence: "low",
                                          detectedCurrency: "INR", closingBalance: nil, isCard: false)
    }

    // MARK: - sharedStrings.xml

    /// Concatenates every <t> run inside each <si> (rich-text cells split one
    /// logical string across runs).
    static func parseSharedStrings(_ data: Data) -> [String] {
        final class D: NSObject, XMLParserDelegate {
            var strings: [String] = []
            var current = ""
            var inT = false
            func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String]) {
                if e == "si" { current = "" }
                if e == "t" { inT = true }
            }
            func parser(_ p: XMLParser, foundCharacters s: String) { if inT { current += s } }
            func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
                if e == "t" { inT = false }
                if e == "si" { strings.append(current) }
            }
        }
        let d = D()
        let parser = XMLParser(data: data)
        parser.delegate = d
        parser.parse()
        return d.strings
    }

    // MARK: - styles.xml → which cell styles are dates

    /// Style indices (positions in <cellXfs>) whose number format renders a
    /// date, so numeric cells in those styles get serial→date conversion.
    /// Built-in date formats are ids 14–22 and 45–47; custom formats count when
    /// their code contains day/month/year tokens (color/escape blocks stripped).
    static func parseDateStyles(_ data: Data) -> [Bool] {
        final class D: NSObject, XMLParserDelegate {
            var customDateFmts = Set<Int>()
            var xfFmtIds: [Int] = []
            var inCellXfs = false
            func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?,
                        qualifiedName: String?, attributes a: [String: String]) {
                switch e {
                case "numFmt":
                    if let id = a["numFmtId"].flatMap(Int.init), let code = a["formatCode"] {
                        let bare = code
                            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
                            .replacingOccurrences(of: #""[^"]*""#, with: "", options: .regularExpression)
                            .lowercased()
                        if bare.contains("d") || bare.contains("y")
                            || (bare.contains("m") && !bare.contains("#")) {
                            customDateFmts.insert(id)
                        }
                    }
                case "cellXfs": inCellXfs = true
                case "xf" where inCellXfs:
                    xfFmtIds.append(a["numFmtId"].flatMap(Int.init) ?? 0)
                default: break
                }
            }
            func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
                if e == "cellXfs" { inCellXfs = false }
            }
        }
        let d = D()
        let parser = XMLParser(data: data)
        parser.delegate = d
        parser.parse()
        return d.xfFmtIds.map { id in
            (14...22).contains(id) || (45...47).contains(id) || d.customDateFmts.contains(id)
        }
    }

    // MARK: - sheetN.xml → [[String]]

    static func parseSheet(_ data: Data, shared: [String], dateStyles: [Bool]) -> [[String]] {
        final class D: NSObject, XMLParserDelegate {
            let shared: [String]
            let dateStyles: [Bool]
            init(shared: [String], dateStyles: [Bool]) {
                self.shared = shared; self.dateStyles = dateStyles
            }
            var rows: [[String]] = []
            var row: [String] = []
            var col = 0            // 0-based column of the current cell
            var type = ""          // c/@t: s, n, str, inlineStr, b, e ("" = n)
            var styleIdx = -1
            var value = ""
            var capture = false    // inside <v> or an inlineStr <t>
            var inCell = false

            func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?,
                        qualifiedName: String?, attributes a: [String: String]) {
                switch e {
                case "row": row = []
                case "c":
                    inCell = true
                    value = ""
                    type = a["t"] ?? ""
                    styleIdx = a["s"].flatMap(Int.init) ?? -1
                    col = a["r"].map(Self.columnIndex) ?? row.count
                case "v", "t" where inCell && type == "inlineStr":
                    capture = true
                default: break
                }
            }
            func parser(_ p: XMLParser, foundCharacters s: String) { if capture { value += s } }
            func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
                switch e {
                case "v", "t": capture = false
                case "c":
                    inCell = false
                    while row.count < col { row.append("") }   // pad skipped blank cells
                    row.append(resolved())
                case "row":
                    // Trim trailing blanks; keep the row if anything remains.
                    while row.last?.isEmpty == true { row.removeLast() }
                    if !row.isEmpty { rows.append(row) }
                default: break
                }
            }

            private func resolved() -> String {
                switch type {
                case "s":
                    return Int(value).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? ""
                case "b":
                    return value == "1" ? "TRUE" : "FALSE"
                case "str", "inlineStr", "e":
                    return value.trimmingCharacters(in: .whitespacesAndNewlines)
                default:   // numeric
                    let isDate = styleIdx >= 0 && styleIdx < dateStyles.count && dateStyles[styleIdx]
                    if isDate, let serial = Double(value), serial > 0 {
                        return Self.serialToISO(serial) ?? value
                    }
                    // Strip Excel's float noise on integer amounts ("2450.0" → "2450").
                    if let d = Double(value), d == d.rounded(), abs(d) < 1e12,
                       value.contains(".") {
                        return String(Int64(d))
                    }
                    return value
                }
            }

            /// "BC42" → 54 (0-based). Letters only; digits are the row number.
            static func columnIndex(_ ref: String) -> Int {
                var n = 0
                for ch in ref {
                    guard let a = ch.asciiValue, a >= 65, a <= 90 else { break }
                    n = n * 26 + Int(a - 64)
                }
                return max(0, n - 1)
            }

            /// Excel serial date (1900 system, day 0 = 1899-12-30) → "yyyy-MM-dd".
            static func serialToISO(_ serial: Double) -> String? {
                guard serial > 59, serial < 200_000 else { return nil }   // sane statement range
                let epoch = DateComponents(calendar: .init(identifier: .gregorian),
                                           timeZone: TimeZone(identifier: "UTC"),
                                           year: 1899, month: 12, day: 30).date!
                let date = epoch.addingTimeInterval(serial.rounded(.down) * 86_400)
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                f.timeZone = TimeZone(identifier: "UTC")
                return f.string(from: date)
            }
        }
        let d = D(shared: shared, dateStyles: dateStyles)
        let parser = XMLParser(data: data)
        parser.delegate = d
        parser.parse()
        return d.rows
    }

    // MARK: - Minimal ZIP reader (central directory + stored/deflate entries)

    struct ZipArchive {
        private let data: Data
        private var entries: [String: (offset: Int, method: UInt16, compSize: Int, rawSize: Int)] = [:]
        var entryNames: [String] { Array(entries.keys) }

        init(data: Data) throws {
            self.data = data
            // End-of-central-directory: signature 0x06054b50, scanned backwards
            // past an optional trailing comment (max 64 KB).
            let sig: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
            var eocd = -1
            let start = max(0, data.count - 65_557)
            var i = data.count - 22
            while i >= start {
                if data[i] == sig[0], data[i+1] == sig[1], data[i+2] == sig[2], data[i+3] == sig[3] {
                    eocd = i; break
                }
                i -= 1
            }
            guard eocd >= 0 else { throw XLSXError.notAZip }
            let count = Int(u16(eocd + 10))
            var p = Int(u32(eocd + 16))     // central directory offset
            for _ in 0..<count {
                guard p + 46 <= data.count, u32(p) == 0x0201_4b50 else { throw XLSXError.notAZip }
                let method = u16(p + 10)
                let compSize = Int(u32(p + 20))
                let rawSize = Int(u32(p + 24))
                let nameLen = Int(u16(p + 28))
                let extraLen = Int(u16(p + 30))
                let commentLen = Int(u16(p + 32))
                let localOffset = Int(u32(p + 42))
                let name = String(data: data.subdata(in: (p + 46)..<(p + 46 + nameLen)), encoding: .utf8) ?? ""
                entries[name] = (localOffset, method, compSize, rawSize)
                p += 46 + nameLen + extraLen + commentLen
            }
        }

        func extract(_ name: String) throws -> Data {
            guard let e = entries[name] else { throw XLSXError.badEntry(name) }
            // Local header: sizes can be zero there (data-descriptor files), so
            // trust the central directory; only the name/extra lengths matter.
            let p = e.offset
            guard p + 30 <= data.count, u32(p) == 0x0403_4b50 else { throw XLSXError.badEntry(name) }
            let nameLen = Int(u16(p + 26)), extraLen = Int(u16(p + 28))
            let payload = p + 30 + nameLen + extraLen
            guard payload + e.compSize <= data.count else { throw XLSXError.badEntry(name) }
            let comp = data.subdata(in: payload..<(payload + e.compSize))
            switch e.method {
            case 0: return comp                            // stored
            case 8: return try inflate(comp, rawSize: e.rawSize)
            default: throw XLSXError.badEntry(name)
            }
        }

        /// Raw DEFLATE (RFC 1951) — exactly what Compression's ZLIB codec speaks.
        private func inflate(_ comp: Data, rawSize: Int) throws -> Data {
            let capacity = max(rawSize, 64)
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { dst in
                comp.withUnsafeBytes { src in
                    compression_decode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        src.bindMemory(to: UInt8.self).baseAddress!, comp.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            guard written > 0 else { throw XLSXError.badEntry("deflate") }
            out.removeSubrange(written..<capacity)
            return out
        }

        private func u16(_ i: Int) -> UInt16 { UInt16(data[i]) | UInt16(data[i+1]) << 8 }
        private func u32(_ i: Int) -> UInt32 {
            UInt32(data[i]) | UInt32(data[i+1]) << 8 | UInt32(data[i+2]) << 16 | UInt32(data[i+3]) << 24
        }
    }
}
