// CSVMapper — the "help me map this" fallback (Fix 2).
//
// When a CSV/XLSX won't auto-parse (no recognizable header, or the date/amount
// columns can't be found), the honest move is NOT to guess and emit wrong rows,
// but to show the user the columns and let them say which is which. This is the
// deterministic core of that flow: it analyzes the raw grid, suggests what it
// can, reports what's missing, and — given the user's choices — reuses the SAME
// tested row-builder (`CSVIngest.ingest` with a mapping override) so a manually
// mapped file is parsed exactly like an auto-detected one.
import Foundation

public enum CSVMapper {

    /// Roles the user can assign a column to. `date` plus one money role
    /// (`amount`, or `debit`/`credit`) are required to build rows.
    public static let assignableRoles = ["date", "desc", "amount", "debit", "credit",
                                         "balance", "category", "currency"]

    public static func displayName(_ role: String) -> String {
        switch role {
        case "date": return "Date"
        case "desc": return "Description"
        case "amount": return "Amount (signed)"
        case "debit": return "Money out"
        case "credit": return "Money in"
        case "balance": return "Balance"
        case "category": return "Category"
        case "currency": return "Currency"
        default: return role.capitalized
        }
    }

    public struct Analysis: Equatable {
        public let headerIdx: Int          // which row holds the column names
        public let headers: [String]       // the column names
        public let sampleRows: [[String]]  // a few data rows, for preview
        public let suggested: [String: Int]  // auto-guessed role → column
        public let missingRequired: [String] // required roles we couldn't map

        /// True when auto-detection is insufficient and the user should map.
        public var needsHelp: Bool { !missingRequired.isEmpty }
    }

    /// Split raw CSV text into a grid (RFC-4180), for feeding `analyze`.
    public static func parseRecords(_ text: String) -> [[String]] {
        CSVIngest.parseRecords(text)
    }

    /// Inspect a raw grid: choose the most likely header row, auto-suggest the
    /// mapping, and report which required roles are still missing.
    public static func analyze(records: [[String]], sampleCount: Int = 5) -> Analysis? {
        guard !records.isEmpty else { return nil }

        // Best header row = the one (within the scan window) that maps the most
        // roles; ties break earliest. Falls back to the first non-empty row.
        var bestIdx = 0, bestScore = -1
        for (i, rec) in records.prefix(CSVIngest.maxHeaderScan).enumerated() {
            let score = CSVIngest.mapHeaders(rec).count
            if score > bestScore { bestScore = score; bestIdx = i }
        }
        let headers = records[bestIdx]
        let suggested = CSVIngest.mapHeaders(headers)
        let sample = Array(records[(bestIdx + 1)...].prefix(sampleCount))

        var missing: [String] = []
        if suggested["date"] == nil { missing.append("date") }
        if suggested["amount"] == nil, suggested["debit"] == nil, suggested["credit"] == nil {
            missing.append("amount")
        }
        return Analysis(headerIdx: bestIdx, headers: headers, sampleRows: sample,
                        suggested: suggested, missingRequired: missing)
    }

    /// Is a proposed mapping sufficient to build rows? (date + a money column.)
    public static func isComplete(_ mapping: [String: Int]) -> Bool {
        mapping["date"] != nil &&
            (mapping["amount"] != nil || mapping["debit"] != nil || mapping["credit"] != nil)
    }

    /// Build rows from the user's explicit column mapping, reusing the canonical
    /// ingester so manual and automatic parses are identical downstream.
    public static func buildRows(records: [[String]], headerIdx: Int,
                                 mapping: [String: Int], categories: Categories,
                                 rawText: String? = nil) -> IngestOutput {
        CSVIngest.ingest(records: records, categories: categories, rawText: rawText,
                         mappingOverride: (headerIdx: headerIdx, mapping: mapping))
    }
}
