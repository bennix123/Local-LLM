// IOSModel — the iOS app's single observable state: statement ingestion through
// the shared deterministic pipeline (TxnIngester), chat through FinanceRouter
// first and the on-device model second (Apple Intelligence on iOS 26, MLX once
// loaded), and lightweight JSON persistence so statements survive relaunch.
//
// Mirrors the roles AppModel plays on macOS, at vertical-slice scope. The two
// apps share every engine type; only the UI layer differs.
import SwiftUI
import PennyCore
import PennyTxnStore

struct IOSStatement: Identifiable {
    let id = UUID()
    let name: String
    let bankName: String?
    let currency: String
    let isCard: Bool
    let closingBalance: Double?
    let rows: [TxnRow]
}

struct IOSChatMsg: Identifiable, Equatable {
    let id = UUID()
    let role: Role          // .user | .penny
    var text: String
    var engine: String?     // "swift engine" | "apple" | "mlx" | nil while streaming
    enum Role { case user, penny }
}

@MainActor
final class IOSModel: ObservableObject {

    // MARK: statements
    @Published var statements: [IOSStatement] = []
    @Published var isImporting = false
    @Published var importedRowCount = 0      // live counter for the sync screen
    @Published var importStatus = ""
    @Published var importErrors: [String] = []

    // MARK: chat
    @Published var messages: [IOSChatMsg] = []
    @Published var isThinking = false
    @Published var modelLoading = false
    @Published var modelLoadFraction: Double = 0
    @Published var mlxReady = false

    // MARK: onboarding
    @AppStorage("penny.ios.onboarded") var onboarded = false

    private let llm = PennyLLM()
    private var ingester: TxnIngester?

    static let maxImportBatch = 10

    init() {
        restore()
    }

    // MARK: - derived

    var mergedRows: [TxnRow] { statements.flatMap(\.rows) }
    var hasData: Bool { !mergedRows.isEmpty }

    var primaryCurrency: String {
        let counts = Dictionary(grouping: statements.map(\.currency).filter { !$0.isEmpty }, by: { $0 })
            .mapValues(\.count)
        return counts.max(by: { $0.value < $1.value })?.key ?? "GBP"
    }

    /// One entry per currency — never blended across currencies.
    struct CurrencySummary: Identifiable {
        var id: String { currency }
        let currency: String
        let symbol: String
        let spent: Double
        let income: Double
        let balance: Double?    // sum of latest account balances, cards negative
    }

    var perCurrency: [CurrencySummary] {
        var spent: [String: Double] = [:], income: [String: Double] = [:]
        var balance: [String: Double] = [:], hasBalance: Set<String> = []
        for s in statements {
            let cur = s.currency.isEmpty ? primaryCurrency : s.currency
            for r in s.rows {
                if r.debit > 0 { spent[cur, default: 0] += r.debit }
                if r.credit > 0 && r.category != "Payments" { income[cur, default: 0] += r.credit }
            }
            if let b = s.closingBalance ?? s.rows.last(where: { $0.balance != nil })?.balance {
                balance[cur, default: 0] += s.isCard ? -b : b
                hasBalance.insert(cur)
            }
        }
        return Set(spent.keys).union(income.keys).sorted().map { c in
            CurrencySummary(currency: c, symbol: Self.symbol(c),
                            spent: spent[c] ?? 0, income: income[c] ?? 0,
                            balance: hasBalance.contains(c) ? balance[c] : nil)
        }
    }

    var spendByCategory: [(category: String, amount: Double)] {
        var byCat: [String: Double] = [:]
        for r in mergedRows where r.debit > 0 { byCat[r.category, default: 0] += r.debit }
        return byCat.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    var recentRows: [TxnRow] {
        mergedRows.sorted { ($0.txnDate, $0.seq) > ($1.txnDate, $1.seq) }
    }

    var recurring: [FinanceRouter.RecurringCharge] {
        FinanceRouter.recurringCharges(mergedRows)
    }

    static func symbol(_ code: String) -> String {
        switch code.uppercased() {
        case "GBP": return "£"; case "INR": return "₹"
        case "EUR": return "€"; case "USD": return "$"
        default: return code.isEmpty ? "£" : code + " "
        }
    }

    func money(_ amount: Double, _ currency: String? = nil) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2; f.maximumFractionDigits = 2
        return Self.symbol(currency ?? primaryCurrency) + (f.string(from: NSNumber(value: amount)) ?? "0")
    }

    // MARK: - ingestion

    private func makeIngester() throws -> TxnIngester {
        if let ingester { return ingester }
        guard let cats = Bundle.main.url(forResource: "categories", withExtension: "json")?.path else {
            throw NSError(domain: "penny", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "categories.json missing from app bundle"])
        }
        let profiles = Bundle.main.url(forResource: "bank_profiles", withExtension: nil)?.path ?? ""
        let ing = try TxnIngester(categoriesJSONPath: cats, bankProfilesDir: profiles)
        ingester = ing
        return ing
    }

    /// Import up to `maxImportBatch` statements. Runs the parsers off-main and
    /// streams a live row counter for the onboarding sync screen.
    func importStatements(from urls: [URL]) {
        guard !isImporting, !urls.isEmpty else { return }
        var urls = urls
        if urls.count > Self.maxImportBatch {
            importErrors.append("Importing the first \(Self.maxImportBatch) of \(urls.count) files — add the rest in a second batch.")
            urls = Array(urls.prefix(Self.maxImportBatch))
        }
        isImporting = true
        importErrors = []
        importStatus = "reading statements…"

        Task {
            for url in urls {
                importStatus = "parsing \(url.lastPathComponent)…"
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let ing = try makeIngester()
                    let ext = url.pathExtension.lowercased()
                    let path = url.path
                    let out: IngestOutput = try await Task.detached {
                        switch ext {
                        case "csv":  return try ing.ingestCSV(path: path)
                        case "xlsx": return try ing.ingestXLSX(path: path)
                        default:     return try ing.ingestPDF(path: path)
                        }
                    }.value
                    guard !out.rows.isEmpty else {
                        importErrors.append("\(url.lastPathComponent): no transactions found — is it a bank or card statement?")
                        continue
                    }
                    // Duplicate guard — same rows under any filename would double every total.
                    let fp = StatementFingerprint.compute(out.rows)
                    if let existing = statements.first(where: { StatementFingerprint.compute($0.rows) == fp }) {
                        importErrors.append("\(url.lastPathComponent): already loaded as “\(existing.name)” — skipped so totals don't double.")
                        continue
                    }
                    statements.append(IOSStatement(
                        name: url.lastPathComponent, bankName: out.bankName,
                        currency: out.detectedCurrency.isEmpty ? "GBP" : out.detectedCurrency,
                        isCard: out.isCard, closingBalance: out.closingBalance, rows: out.rows))
                    // Animate the counter up like the mockup's sync screen — but
                    // counting rows that were actually parsed, not invented ones.
                    let target = mergedRows.count
                    while importedRowCount < target {
                        importedRowCount = min(target, importedRowCount + max(1, (target - importedRowCount) / 8))
                        try? await Task.sleep(nanoseconds: 40_000_000)
                    }
                } catch {
                    importErrors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            importStatus = hasData ? "ready ✨" : "nothing imported"
            isImporting = false
            persist()
        }
    }

    func wipeAll() {
        statements = []
        messages = []
        importedRowCount = 0
        persist()
    }

    // MARK: - chat

    /// The suggestion chips under the composer — the mockup's fun actions.
    static let funActions: [(label: String, prompt: String)] = [
        ("🔥 Roast me", "Roast my spending habits"),
        ("💸 Can I splurge?", "Can I afford to splurge right now?"),
        ("😭 Why am I broke?", "Why am I broke? Where is my money leaking?"),
        ("✂️ Kill my subs", "What are my recurring charges?"),
    ]

    func send(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isThinking else { return }
        messages.append(IOSChatMsg(role: .user, text: q))

        guard hasData else {
            messages.append(IOSChatMsg(role: .penny, text: "Add a statement first — then ask me anything about it.", engine: nil))
            return
        }

        // 1) deterministic router — instant, exact, never hallucinates
        let rows = mergedRows
        let cur = primaryCurrency
        let accounts = statements.map {
            FinanceRouter.AccountBalance(name: $0.bankName ?? $0.name,
                                         balance: $0.closingBalance, isCard: $0.isCard,
                                         currency: $0.currency)
        }
        // Mixed currencies come back as one answer per currency from the router.
        if let det = FinanceRouter.answer(q, rows: rows, currency: cur,
                                          accounts: accounts, money: { self.money($0, cur) }) {
            messages.append(IOSChatMsg(role: .penny, text: det, engine: "swift engine"))
            return
        }

        // 2) on-device model
        isThinking = true
        let idx = messages.count
        messages.append(IOSChatMsg(role: .penny, text: "", engine: nil))
        Task {
            do {
                _ = try await llm.ask(question: q, statementText: digest(),
                                      maxTokens: 512,
                                      onEngine: { [weak self] engine in
                                          Task { @MainActor in
                                              guard let self, self.messages.indices.contains(idx) else { return }
                                              self.messages[idx].engine = engine
                                          }
                                      },
                                      onToken: { [weak self] piece in
                                          Task { @MainActor in
                                              guard let self, self.messages.indices.contains(idx) else { return }
                                              self.messages[idx].text += piece
                                          }
                                      })
                if messages.indices.contains(idx), messages[idx].engine == "mlx" { mlxReady = true }
            } catch {
                if messages.indices.contains(idx) {
                    messages[idx].text = PennyLLM.systemModelAvailable || mlxReady
                        ? "Sorry — I couldn't answer that. \(error.localizedDescription)"
                        : "That one needs the on-device model. Tap **Load on-device model** below — it downloads once (~1.8 GB), then everything runs offline."
                    messages[idx].engine = nil
                }
            }
            isThinking = false
        }
    }

    /// Whether the "Load on-device model" affordance should show: no Apple
    /// Intelligence on this device and MLX not yet loaded.
    var needsModelDownload: Bool { !PennyLLM.systemModelAvailable && !mlxReady && !modelLoading }

    func loadModel() {
        guard !modelLoading, !mlxReady else { return }
        modelLoading = true
        messages.append(IOSChatMsg(role: .penny, text: "Downloading the on-device model — I'll tell you when it's ready. You can keep using exact answers meanwhile.", engine: nil))
        Task {
            do {
                try await llm.load { [weak self] p in
                    Task { @MainActor in self?.modelLoadFraction = p.fraction }
                }
                mlxReady = true
                messages.append(IOSChatMsg(role: .penny, text: "Model ready ✓ — open-ended questions now run fully on this device.", engine: nil))
            } catch {
                messages.append(IOSChatMsg(role: .penny, text: "Model download failed: \(error.localizedDescription)", engine: nil))
            }
            modelLoading = false
        }
    }

    /// Compact grounding table for the model — same shape penny-server feeds it.
    private func digest() -> String {
        var lines = ["All amounts are in \(primaryCurrency) (\(Self.symbol(primaryCurrency))).",
                     "Date | Description | Debit | Credit | Balance | Category"]
        for r in mergedRows.prefix(400) {
            let d = r.debit == 0 ? "" : String(format: "%.2f", r.debit)
            let c = r.credit == 0 ? "" : String(format: "%.2f", r.credit)
            let b = r.balance.map { String(format: "%.2f", $0) } ?? ""
            lines.append("\(r.txnDate) | \(r.descr) | \(d) | \(c) | \(b) | \(r.category)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - persistence (JSON snapshot in Application Support)

    private struct RowDTO: Codable {
        var date: String, month: String, year: Int, monthNo: Int, day: Int
        var descr: String, merchant: String, category: String
        var debit: Double, credit: Double, balance: Double?
        var currency: String, seq: Int
        init(_ r: TxnRow) {
            date = r.txnDate; month = r.month; year = r.year; monthNo = r.monthNo; day = r.day
            descr = r.descr; merchant = r.merchant; category = r.category
            debit = r.debit; credit = r.credit; balance = r.balance
            currency = r.currency; seq = r.seq
        }
        var row: TxnRow {
            TxnRow(txnDate: date, month: month, year: year, monthNo: monthNo, day: day,
                   descr: descr, merchant: merchant, category: category,
                   debit: debit, credit: credit, balance: balance, currency: currency, seq: seq)
        }
    }
    private struct StatementDTO: Codable {
        var name: String, bankName: String?, currency: String
        var isCard: Bool, closingBalance: Double?
        var rows: [RowDTO]
    }

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Penny", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("statements-ios-v1.json")
    }

    private func persist() {
        let dtos = statements.map { s in
            StatementDTO(name: s.name, bankName: s.bankName, currency: s.currency,
                         isCard: s.isCard, closingBalance: s.closingBalance,
                         rows: s.rows.map(RowDTO.init))
        }
        if let data = try? JSONEncoder().encode(dtos) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let dtos = try? JSONDecoder().decode([StatementDTO].self, from: data) else { return }
        statements = dtos.map { d in
            IOSStatement(name: d.name, bankName: d.bankName, currency: d.currency,
                         isCard: d.isCard, closingBalance: d.closingBalance,
                         rows: d.rows.map(\.row))
        }
        importedRowCount = mergedRows.count
    }
}
