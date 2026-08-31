import Foundation
import PennyCore
import PennyModel
import PennyTxnStore

/// On-disk persistence for imported statements (Task 0.6 — v2).
///
/// The **canonical model is the only persisted source of truth**: each statement is
/// stored as one `StatementRecord` (its `Account` + `Statement` + `[PennyModel.Transaction]` +
/// the legacy merchant/category projection + the grounding text), wrapped in a
/// versioned `PersistenceEnvelope`. One file per statement, named by the
/// content-derived `StatementID`, written atomically.
///
/// The store performs **no parsing, analytics, or enrichment** — it serializes
/// finished model values. `LoadedDoc` (still used by today's UI) is *reconstructed*
/// from the record on load via a temporary adapter; no legacy shape is persisted.
///
/// v1 files (the former `StoredDoc`, one per doc, keyed by filename) are migrated
/// to v2 on first launch, without data loss.
enum StatementStore {

    // MARK: - v2 persisted types

    /// One statement as canonical model + provenance. The single persisted record.
    struct StatementRecord: Codable, Sendable {
        var account: Account
        var statement: Statement
        var transactions: [PennyModel.Transaction]
        var merchants: [Merchant]         // legacy parser projection (Phase 2 replaces)
        var categories: [PennyModel.Category]        // legacy parser projection (Phase 2 replaces)
        var text: String                  // chat grounding + re-derivation
        var importedAt: Date

        init(account: Account, statement: Statement, transactions: [PennyModel.Transaction],
             merchants: [Merchant], categories: [PennyModel.Category], text: String, importedAt: Date) {
            self.account = account; self.statement = statement; self.transactions = transactions
            self.merchants = merchants; self.categories = categories
            self.text = text; self.importedAt = importedAt
        }

        /// Build a record from a single-file graph slice (as `ModelAssembler` emits).
        init(from graph: FinancialGraph, text: String, importedAt: Date = Date()) {
            let account = graph.accounts.first
                ?? Account(id: AccountID("acct-empty"), institution: "Unknown", kind: .unknown, currency: Currency("INR"))
            self.init(account: account,
                      statement: graph.statements.first
                        ?? Statement(id: StatementID("stmt-empty"), accountID: account.id, sourceName: ""),
                      transactions: graph.transactions,
                      merchants: graph.merchants, categories: graph.categories,
                      text: text, importedAt: importedAt)
        }
    }

    /// Version envelope — routes future parser/enrichment migrations.
    struct PersistenceEnvelope: Codable {
        var schema: Int
        var appVersion: String
        var parserVersion: Int
        var enrichmentVersion: Int
        var record: StatementRecord
    }

    static let schemaVersion = 2
    static let parserVersion = 1
    static let enrichmentVersion = 0   // Phase 2 bumps this to trigger re-enrichment
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0"
    }

    // MARK: - Location

    private static var root: URL {
        if TestMode.active {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("penny-uitest-statements-\(getpid())", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Penny/statements", isDirectory: true)
    }
    /// v2 records live in a subdirectory, leaving v1 files untouched until migrated.
    static var directory: URL { root.appendingPathComponent("v2", isDirectory: true) }
    private static var legacyDirectory: URL { root }
    private static var quarantineDirectory: URL { directory.appendingPathComponent("corrupt", isDirectory: true) }

    private static func fileURL(for id: StatementID) -> URL {
        directory.appendingPathComponent(id.raw + ".json")   // "stmt-<hex>.json" — already filename-safe
    }

    // MARK: - Codable config (pinned, stable)

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    // MARK: - Save

    static func save(_ record: StatementRecord) {
        var record = record
        let url = fileURL(for: record.statement.id)
        // Preserve the original import time across re-saves (same content ⇒ same file).
        if let data = try? Data(contentsOf: url),
           let existing = try? decoder.decode(PersistenceEnvelope.self, from: data) {
            record.importedAt = existing.record.importedAt
        }
        let envelope = PersistenceEnvelope(schema: schemaVersion, appVersion: appVersion,
                                           parserVersion: parserVersion,
                                           enrichmentVersion: enrichmentVersion, record: record)
        guard let data = try? encoder.encode(envelope) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Load

    /// All persisted records, in import order. Corrupt files are quarantined and skipped.
    static func loadRecords() -> [StatementRecord] {
        guard let files = try? FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> StatementRecord? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                guard let env = try? decoder.decode(PersistenceEnvelope.self, from: data) else {
                    quarantine(url); return nil
                }
                return env.record
            }
            .sorted { $0.importedAt == $1.importedAt ? $0.statement.sourceName < $1.statement.sourceName
                                                     : $0.importedAt < $1.importedAt }
    }

    /// The merged canonical graph across every persisted statement (Phase 1 / 0.7).
    static func loadGraph() -> FinancialGraph {
        var accounts: [AccountID: Account] = [:]
        var statements: [Statement] = []
        var transactions: [PennyModel.Transaction] = []
        var merchants: [MerchantID: Merchant] = [:]
        var categories: [CategoryID: PennyModel.Category] = [:]
        for r in loadRecords() {
            accounts[r.account.id] = r.account
            statements.append(r.statement)
            transactions.append(contentsOf: r.transactions)
            r.merchants.forEach { merchants[$0.id] = $0 }
            r.categories.forEach { categories[$0.id] = $0 }
        }
        return FinancialGraph(accounts: Array(accounts.values), statements: statements,
                              transactions: transactions,
                              merchants: Array(merchants.values), categories: Array(categories.values))
    }

    /// Restore path for the current UI: migrate v1 if needed, then rebuild `LoadedDoc`s.
    static func loadDocs() -> [LoadedDoc] {
        migrateV1IfNeeded()
        return loadRecords().map(reconstruct)
    }

    /// Behaviour-compatible alias for the restore call site.
    static func loadAll() -> [LoadedDoc] { loadDocs() }

    // MARK: - Reconstruction adapter (record → LoadedDoc) — transitional, removed in Phase 1

    /// Rebuild a `LoadedDoc` from the canonical record. `displayName` is *derived*
    /// (from the institution + grounding text, plus the runtime issuer-refinement
    /// layer) — the presentation value is never persisted.
    static func reconstruct(_ record: StatementRecord) -> LoadedDoc {
        let merchantName = Dictionary(record.merchants.map { ($0.id, $0.canonicalName) },
                                      uniquingKeysWith: { a, _ in a })
        let rows = record.transactions.enumerated().map { i, t -> TxnRow in
            let amt = t.amount.amount
            let iso = String(format: "%04d-%02d-%02d", t.date.year, t.date.month, t.date.day)
            var r = TxnRow(txnDate: iso, month: String(iso.prefix(7)),
                           year: t.date.year, monthNo: t.date.month, day: t.date.day,
                           descr: t.rawDescription,
                           merchant: t.enrichment.merchantID.flatMap { merchantName[$0] } ?? "",
                           category: t.enrichment.categoryID?.raw ?? "",
                           debit: amt < 0 ? double(-amt) : 0,
                           credit: amt > 0 ? double(amt) : 0,
                           balance: t.balance.map { double($0.amount) },
                           currency: t.currency.code, seq: i)
            r.account = t.subAccount
            r.isSelfTransfer = t.enrichment.tags.contains(.internalTransfer)
            return r
        }
        return LoadedDoc(name: record.statement.sourceName, text: record.text,
                         transactions: rows.map(DeterministicIngest.toTransaction), rows: rows,
                         currency: record.account.currency.code,
                         bank: record.account.institution, detectedIssuer: nil,
                         closingBalance: record.statement.closingBalance.map { double($0.amount) },
                         isCard: record.account.kind == .credit, analyzed: true)
    }

    /// Decimal → Double via the decimal string (exact for money magnitudes).
    private static func double(_ d: Decimal) -> Double {
        Double(d.description) ?? NSDecimalNumber(decimal: d).doubleValue
    }

    // MARK: - Remove / wipe

    static func remove(statementID: StatementID) {
        try? FileManager.default.removeItem(at: fileURL(for: statementID))
    }

    static func remove(sourceName: String) {
        for r in loadRecords() where r.statement.sourceName == sourceName {
            remove(statementID: r.statement.id)
        }
    }

    static func wipeAll() {
        try? FileManager.default.removeItem(at: root)   // v2, quarantine, and any v1 files
    }

    // MARK: - Corruption quarantine

    private static func quarantine(_ url: URL) {
        try? FileManager.default.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: url, to: quarantineDirectory.appendingPathComponent(url.lastPathComponent))
    }

    // MARK: - v1 → v2 migration

    /// Legacy DTOs, retained only to read pre-v2 files during migration.
    private struct StoredRow: Codable {
        var txnDate, month: String; var year, monthNo, day: Int
        var descr, merchant, category: String
        var debit, credit: Double; var balance: Double?
        var currency: String; var seq: Int; var rawCategory: String?
        var row: TxnRow {
            var r = TxnRow(txnDate: txnDate, month: month, year: year, monthNo: monthNo, day: day,
                           descr: descr, merchant: merchant, category: category,
                           debit: debit, credit: credit, balance: balance, currency: currency, seq: seq)
            r.rawCategory = rawCategory; return r
        }
    }
    private struct StoredDoc: Codable {
        var name, text: String; var rows: [StoredRow]; var currency: String
        var bank, detectedIssuer: String?; var closingBalance: Double?; var isCard: Bool; var importedAt: Date
    }

    /// Convert any v1 files (top-level `statements/*.json`) into v2 records, then
    /// delete each v1 file only after its v2 record is written. Idempotent.
    static func migrateV1IfNeeded() {
        guard let files = try? FileManager.default
            .contentsOfDirectory(at: legacyDirectory, includingPropertiesForKeys: nil) else { return }
        let v1Files = files.filter { $0.pathExtension == "json" }   // v2/ is a directory, excluded
        for url in v1Files {
            guard let data = try? Data(contentsOf: url),
                  let doc = try? JSONDecoder().decode(StoredDoc.self, from: data) else { continue }
            let out = IngestOutput(rows: doc.rows.map(\.row), bankName: doc.bank, confidence: "restored",
                                   detectedCurrency: doc.currency, closingBalance: doc.closingBalance, isCard: doc.isCard)
            let metadata = StatementMetadataParser.parse(text: doc.text)
            let graph = ModelAssembler.assemble(out, sourceName: doc.name, metadata: metadata).graph
            save(StatementRecord(from: graph, text: doc.text, importedAt: doc.importedAt))
            try? FileManager.default.removeItem(at: url)   // remove v1 only after v2 write
        }
    }
}
