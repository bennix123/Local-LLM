import Foundation
import PennyCore
import PennyTxnStore

/// On-disk persistence for imported statements, so the dashboard survives a
/// relaunch without re-importing. One JSON file per document under the app's
/// sandboxed `Application Support/Penny/statements/` (atomic writes), holding
/// everything a `LoadedDoc` needs: the extracted text (chat grounding), the
/// parsed canonical rows (every Today-panel figure), and the per-statement
/// metadata (currency, bank, issuer label, closing balance, card semantics).
///
/// `TxnRow` is not Codable, so rows are stored through a field-for-field DTO;
/// transactions are rebuilt from the restored rows via the SAME mapping the
/// live import uses (`DeterministicIngest.toTransaction`), so a restored doc
/// is figure-identical to the freshly imported one.
///
/// Test runs (`TestMode.active`) write to a per-process temp directory instead
/// — exactly the `AppModel.historyURL` pattern — because the Debug build shares
/// its sandbox container with the installed app and tests must never persist
/// into it.
enum StatementStore {

    // MARK: - Codable DTOs

    /// Field-for-field mirror of `PennyTxnStore.TxnRow` (which is not Codable).
    struct StoredRow: Codable {
        var txnDate: String
        var month: String
        var year: Int
        var monthNo: Int
        var day: Int
        var descr: String
        var merchant: String
        var category: String
        var debit: Double
        var credit: Double
        var balance: Double?
        var currency: String
        var seq: Int
        var rawCategory: String?

        init(_ r: TxnRow) {
            txnDate = r.txnDate; month = r.month; year = r.year
            monthNo = r.monthNo; day = r.day
            descr = r.descr; merchant = r.merchant; category = r.category
            debit = r.debit; credit = r.credit; balance = r.balance
            currency = r.currency; seq = r.seq; rawCategory = r.rawCategory
        }

        var row: TxnRow {
            var r = TxnRow(txnDate: txnDate, month: month, year: year,
                           monthNo: monthNo, day: day,
                           descr: descr, merchant: merchant, category: category,
                           debit: debit, credit: credit, balance: balance,
                           currency: currency, seq: seq)
            r.rawCategory = rawCategory
            return r
        }
    }

    /// One persisted statement — everything `LoadedDoc` carries except the
    /// transactions (rebuilt from `rows`) and the transient `analyzed` flag.
    struct StoredDoc: Codable {
        var name: String
        var text: String
        var rows: [StoredRow]
        var currency: String
        var bank: String?
        var detectedIssuer: String?
        var closingBalance: Double?
        var isCard: Bool
        /// First-import time — preserved across re-saves so a restore lists
        /// statements in the order the user imported them.
        var importedAt: Date
    }

    // MARK: - Location

    /// Where statement JSONs live. Test runs get a per-process temp directory
    /// (like `AppModel.historyURL`), so they start empty and never touch the
    /// real container.
    static var directory: URL {
        if TestMode.active {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("penny-uitest-statements-\(getpid())", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Penny/statements", isDirectory: true)
    }

    /// Deterministic, collision-free file name for a doc (doc names are user
    /// filenames — percent-encode anything that isn't alphanumeric).
    private static func fileURL(for name: String) -> URL {
        let safe = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        return directory.appendingPathComponent(safe + ".json")
    }

    // MARK: - Save / load / remove / wipe

    static func save(_ doc: LoadedDoc) {
        let url = fileURL(for: doc.name)
        // Re-saves (issuer refinements, same-name re-imports) keep the original
        // import time so the restore order stays the user's import order.
        let importedAt = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(StoredDoc.self, from: $0).importedAt }
            ?? Date()
        let stored = StoredDoc(name: doc.name, text: doc.text,
                               rows: doc.rows.map(StoredRow.init),
                               currency: doc.currency, bank: doc.bank,
                               detectedIssuer: doc.detectedIssuer,
                               closingBalance: doc.closingBalance,
                               isCard: doc.isCard,
                               importedAt: importedAt)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Every persisted statement, in import order, rebuilt as `LoadedDoc`s.
    static func loadAll() -> [LoadedDoc] {
        guard let files = try? FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> StoredDoc? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(StoredDoc.self, from: data)
            }
            .sorted { $0.importedAt == $1.importedAt ? $0.name < $1.name
                                                     : $0.importedAt < $1.importedAt }
            .map { s in
                let rows = s.rows.map(\.row)
                return LoadedDoc(name: s.name, text: s.text,
                                 transactions: rows.map(DeterministicIngest.toTransaction),
                                 rows: rows,
                                 currency: s.currency, bank: s.bank,
                                 detectedIssuer: s.detectedIssuer,
                                 closingBalance: s.closingBalance, isCard: s.isCard,
                                 analyzed: true)
            }
    }

    static func remove(named name: String) {
        try? FileManager.default.removeItem(at: fileURL(for: name))
    }

    /// Delete every persisted statement (the "wipe all data" control).
    static func wipeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
