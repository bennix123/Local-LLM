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
        // Prefer the central categories copy fetched from penny1.thescript.design
        // (so every device shares the same, always-current vocabulary); fall back
        // to the bundled file when the fetch has never succeeded (offline / first
        // launch), which keeps the app fully functional with no network.
        let categoriesPath: String
        if let cached = CategoryCatalog.cachedCategoriesPath {
            categoriesPath = cached
        } else if let bundled = Bundle.main.url(
            forResource: "categories", withExtension: "json")?.path {
            categoriesPath = bundled
        } else {
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

/// Client for the **central categories API** (`penny-categories-server`, hosted
/// at `penny1.thescript.design`). It downloads Penny's categorization vocabulary
/// — the `merchant_map` + keyword `category_rules` — and caches it to
/// Application Support, so every device shares the same, always-current
/// categories without shipping a new build. `DeterministicIngest.makeIngester()`
/// prefers this cached copy over the bundled `categories.json`; if the fetch has
/// never succeeded, it falls back to the bundle, so the app is fully offline-safe.
enum CategoryCatalog {

    /// Application Support/Penny/categories.json — the cached server copy.
    private static var cacheURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        let pennyDir = dir.appendingPathComponent("Penny", isDirectory: true)
        try? FileManager.default.createDirectory(at: pennyDir, withIntermediateDirectories: true)
        return pennyDir.appendingPathComponent("categories.json")
    }

    /// Where the last-seen ETag is stored, for conditional (`If-None-Match`) GETs.
    private static var etagURL: URL? {
        cacheURL?.deletingLastPathComponent().appendingPathComponent("categories.etag")
    }

    /// Path to the cached server categories, or nil if we've never fetched one.
    static var cachedCategoriesPath: String? {
        guard let url = cacheURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url.path
    }

    /// Fetch the latest categories from the backend and cache them. Cheap and
    /// safe to call on every launch: an unchanged catalog returns `304` and does
    /// nothing; any failure (offline, server down) is swallowed and the previous
    /// cache (or the bundle) keeps working. Returns true if the cache was updated.
    @discardableResult
    static func refresh() async -> Bool {
        guard let endpoint = PennyBackend.categoriesURL, let cache = cacheURL else { return false }

        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 15
        if !PennyBackend.appToken.isEmpty {
            req.setValue("Bearer \(PennyBackend.appToken)", forHTTPHeaderField: "Authorization")
        }
        if let etURL = etagURL, let et = try? String(contentsOf: etURL, encoding: .utf8), !et.isEmpty {
            req.setValue(et, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            if http.statusCode == 304 { return false }          // unchanged — keep cache
            guard http.statusCode == 200 else { return false }

            // Extract just the two canonical keys the parser needs, and persist
            // them in the same shape the app bundles (so the textual merchant-map
            // order scan in `Categories` behaves identically).
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let merchantMap = obj["merchant_map"],
                  let categoryRules = obj["category_rules"] else { return false }
            let canonical = try JSONSerialization.data(
                withJSONObject: ["merchant_map": merchantMap, "category_rules": categoryRules],
                options: [.prettyPrinted])
            try canonical.write(to: cache, options: .atomic)

            if let etURL = etagURL, let tag = http.value(forHTTPHeaderField: "Etag") {
                try? tag.write(to: etURL, atomically: true, encoding: .utf8)
            }
            return true
        } catch {
            return false                                        // offline / server down — keep prior cache
        }
    }
}
