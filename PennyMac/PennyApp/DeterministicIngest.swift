import Foundation
import PennyCore
import PennyModel
import PennyTxnStore

/// Deterministic statement ingestion for the app — the P0 replacement for the
/// LLM extraction path. Runs the same `PennyTxnStore` pipeline that passes the
/// 15/15 contract (MuPDF-parity PDF extraction → bank parsers → categorization),
/// so every row and figure is exact and model-free.
///
/// The `categories.json` + `bank_profiles/` the pipeline needs are bundled into
/// the app (see `project.yml` / `Resources/`), and read from `Bundle.main`, which
/// is always allowed under the App Sandbox.
enum DeterministicIngest {

    /// This file translated into the canonical model — the single source of truth.
    /// (Phase 0.8 cleanup: the legacy transactions/rows/currency/bank/closingBalance/
    /// isCard fields were removed once the runtime switched to the graph in Task 0.7.)
    struct Result: Sendable {
        var graph: FinancialGraph = .empty
    }

    enum IngestError: Error, LocalizedError {
        case missingResources
        var errorDescription: String? {
            "Penny's parser resources are missing from the app bundle."
        }
    }

    /// Parse a statement PDF at `url` into canonical transactions. Caller is
    /// responsible for holding the file's security scope (see `AppModel.extract`).
    /// `statementText` is the already-extracted PDFKit text (Task 0.5, Option B):
    /// the header metadata parser reads it, so extraction behaves exactly as the
    /// former in-`AppModel` code. Defaults to "" (no metadata) for callers without it.
    static func ingest(pdfAt url: URL, statementText: String = "") throws -> Result {
        let ingester = try makeIngester()
        return toResult(try ingester.ingestPDF(path: url.path),
                        sourceName: url.lastPathComponent, statementText: statementText)
    }

    /// Parse a statement CSV at `url` — the same canonical pipeline
    /// (categorization, currency detection) through the ingester's CSV entry
    /// point, so CSV exports land as first-class statements.
    static func ingest(csvAt url: URL, statementText: String = "") throws -> Result {
        let ingester = try makeIngester()
        return toResult(try ingester.ingestCSV(path: url.path),
                        sourceName: url.lastPathComponent, statementText: statementText)
    }

    private static func toResult(_ out: IngestOutput, sourceName: String, statementText: String) -> Result {
        // Translate the parser output into the canonical model, filling header
        // metadata parsed from the statement text.
        let metadata = StatementMetadataParser.parse(text: statementText)
        return Result(graph: ModelAssembler.assemble(out, sourceName: sourceName, metadata: metadata).graph)
    }

    // MARK: - Bundled resources

    private static func makeIngester() throws -> TxnIngester {
        guard let categoriesPath = Bundle.main.url(
            forResource: "categories", withExtension: "json")?.path else {
            throw IngestError.missingResources
        }
        // bank_profiles is a folder reference; a missing/unfound dir is non-fatal
        // (BankParsers still detect banks heuristically), so pass "" as a fallback.
        let profilesDir = Bundle.main.url(forResource: "bank_profiles", withExtension: nil)?.path
            ?? Bundle.main.resourceURL?.appendingPathComponent("bank_profiles").path
            ?? ""
        return try TxnIngester(categoriesJSONPath: categoriesPath, bankProfilesDir: profilesDir)
    }

    // MARK: - Row mapping

    /// Map a `PennyTxnStore.TxnRow` (0.0 = "no amount") onto the app's
    /// `PennyCore.Transaction` (nil = "no amount"), carrying the real category.
    /// Internal (not private): `StatementStore` rebuilds transactions from its
    /// persisted rows through this same mapping, so restored docs are
    /// figure-identical to freshly imported ones.
    static func toTransaction(_ r: TxnRow) -> PennyCore.Transaction {
        PennyCore.Transaction(
            date: r.txnDate,
            description: r.descr,
            debit: r.debit == 0 ? nil : r.debit,
            credit: r.credit == 0 ? nil : r.credit,
            balance: r.balance,
            category: r.category.isEmpty ? nil : r.category
        )
    }
}
