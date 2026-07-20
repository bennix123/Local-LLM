import Foundation
import SwiftUI
import PennyCore
import PennyTxnStore

// MARK: - App-level types

enum AppStage { case onboarding, modelPicker, dashboard }

enum ModelPhase: Equatable {
    case idle
    case loading(Int)   // percent 0-100
    case ready
}

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    let role: Role
    var content: String
    var engine: String?   // e.g. "MLX" — the badge shown on assistant bubbles
}

/// An archived conversation — created when the user starts a new chat, listed
/// in the History view, and persisted to disk so it survives relaunches.
struct ChatSession: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String       // first user message (trimmed)
    var date: Date          // when it was archived
    var messages: [ChatMessage]
}

/// Which view fills the centre column of the dashboard.
enum CenterView { case chat, history }

/// A statement the user imported: its PDFKit-extracted text (grounding for chat)
/// plus the transactions the deterministic `PennyTxnStore` parser pulled out of it
/// (source of every Today-panel figure).
struct LoadedDoc: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let text: String
    var transactions: [PennyCore.Transaction] = []   // PennyCore-qualified: SwiftUI also has a `Transaction`
    var rows: [TxnRow] = []                           // richer canonical rows, for the deterministic query router
    var currency: String = "INR"                     // currency the parser detected for this statement
    var analyzed = false
    var charCount: Int { text.count }
}

/// Deterministically-computed figures for the Today panel (all summed in Swift
/// from the extracted transactions — never guessed by the model).
struct Summary: Equatable {
    var currency = "INR"
    var balance: Double?
    var spent: Double = 0     // sum of debits
    var income: Double = 0    // sum of credits
    var net: Double = 0       // income − spent
    var count: Int = 0
    var categories: [CategorySpend] = []
}

struct CategorySpend: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let amount: Double
}

/// The single source of truth for the whole app UI — the SwiftUI analogue of the
/// React `Dashboard`/`ModelPicker` component state + `AuthContext`. It owns the
/// navigation stage, the chosen model, imported docs and the chat transcript, and
/// routes every question through `PennyCore.PennyLLM` (on-device MLX).
@MainActor
final class AppModel: ObservableObject {
    @Published var stage: AppStage = .onboarding

    // MARK: onboarding flow (the template's 7-step wizard)

    /// Which of the 7 onboarding screens is showing (1 = welcome … 7 = insights).
    @Published var onboardStep: Int = 1

    /// First name from step 2 — persisted so Penny greets returning users.
    @Published var userName: String = UserDefaults.standard.string(forKey: "penny.userName") ?? "" {
        didSet { UserDefaults.standard.set(userName, forKey: "penny.userName") }
    }

    /// Account kinds picked in step 4 (template pre-selects these three).
    @Published var selectedAccountKinds: [String] = ["current", "credit", "stocks"]

    /// Which account tab is active on the upload screen (index into selectedAccountKinds).
    @Published var uploadKindIndex: Int = 0

    /// Statement files imported per account kind (doc names, in import order).
    @Published var uploadsByKind: [String: [String]] = [:]

    func goToStep(_ n: Int) { onboardStep = max(1, min(7, n)) }

    /// "Take me to Penny →" — model still has to be picked/loaded before chat.
    func finishOnboarding() {
        stage = modelPhase == .ready ? .dashboard : .modelPicker
    }

    /// The account kind currently receiving uploads on step 5.
    var currentUploadKind: String? {
        selectedAccountKinds.indices.contains(uploadKindIndex) ? selectedAccountKinds[uploadKindIndex] : nil
    }

    /// Docs imported for a given account kind (dropped docs are filtered out).
    func uploads(for kind: String) -> [LoadedDoc] {
        (uploadsByKind[kind] ?? []).compactMap { name in docs.first { $0.name == name } }
    }

    /// Remove an onboarding upload everywhere it's tracked.
    func removeDoc(named name: String) {
        docs.removeAll { $0.name == name }
        selectedDocNames.remove(name)
        for (kind, names) in uploadsByKind {
            uploadsByKind[kind] = names.filter { $0 != name }
        }
        recomputeSummary()
    }

    // model
    @Published var selectedModelID: String = PennyLLM.sliceModelID
    @Published var modelPhase: ModelPhase = .idle
    @Published var loadStatus: String = ""
    // live download telemetry (drives the model-picker progress bar)
    @Published var downloadFraction: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var loadElapsed: Int = 0

    // documents / scope
    @Published var docs: [LoadedDoc] = []
    @Published var selectedDocNames: Set<String> = []
    @Published var isImporting = false
    @Published var importingName: String?
    @Published var isAnalyzing = false
    @Published var summary = Summary()

    // chat
    @Published var messages: [ChatMessage] = []
    @Published var isThinking = false
    @Published var errorMessage: String?

    // chat history
    @Published var centerView: CenterView = .chat
    @Published var history: [ChatSession] = AppModel.loadHistory()

    // ui prefs
    @Published var offlineOnly = true

    private var llm = PennyLLM(modelID: PennyLLM.sliceModelID)
    private var tickCount = 0   // 0.5 s ticks, for the elapsed clock

    // Hybrid-RAG retriever, cached per selected-document set (rebuilding embeds
    // every row, so we only redo it when the selection actually changes).
    private var retriever: TxnRetriever?
    private var retrieverKey = ""

    var catalog: [PennyLLM.CatalogEntry] { PennyLLM.catalog }

    var modelDisplayName: String {
        catalog.first { $0.id == selectedModelID }?.name ?? "local model"
    }

    // MARK: model ⇄ device fit

    /// This Mac's physical RAM in GB — used to warn before a model that won't fit
    /// gets picked (running an 8B model on 8 GB thrashes/OOMs, the exact crash the
    /// native rewrite exists to avoid).
    static let deviceRAMGB: Int = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())

    /// True when a catalog model fits comfortably in this Mac's RAM.
    func modelFits(_ entry: PennyLLM.CatalogEntry) -> Bool { Self.deviceRAMGB >= entry.minRAMGB }

    /// Which catalog models are already fully downloaded (weights on disk) — drives
    /// the "downloaded ✓ / downloads on first use" hint. Refreshed on picker appear.
    @Published var downloadedModelIDs: Set<String> = []

    func refreshDownloadedModels() {
        let ids = catalog.map(\.id)
        Task.detached {
            var done = Set<String>()
            for id in ids {
                let total = AppModel.catalogBytes(id)
                if total > 0, DownloadMeter.bytesOnDisk(repo: id) >= Int64(Double(total) * 0.95) {
                    done.insert(id)
                }
            }
            await MainActor.run { [weak self] in self?.downloadedModelIDs = done }
        }
    }

    /// The Today panel is ready once we've extracted at least one transaction.
    var contextReady: Bool { summary.count > 0 }
    var transactionCount: Int { summary.count }

    /// Real count of auto-detected recurring charges / subscriptions ("ghosts")
    /// across all imported statements — drives the sidebar's Ghosts badge, so it
    /// reflects the actual data instead of a hardcoded placeholder. Needs ≥3
    /// months of history to detect anything, so it's 0 for a single statement.
    var ghostCount: Int { FinanceRouter.recurringCharges(docs.flatMap(\.rows)).count }

    // MARK: model picker

    func chooseModel(_ id: String) {
        guard id != selectedModelID else { return }
        selectedModelID = id
        modelPhase = .idle
        resetLoadTelemetry()
        llm = PennyLLM(modelID: id)
    }

    private func resetLoadTelemetry() {
        loadStatus = ""
        downloadFraction = 0
        downloadedBytes = 0
        totalBytes = 0
        loadElapsed = 0
        tickCount = 0
    }

    /// Load the chosen model (downloading weights on first use) and, once ready,
    /// advance into the dashboard. Mirrors ModelPicker's "Use this model → continue".
    ///
    /// Progress is measured from BYTES ON DISK, not the Hub's `fractionCompleted`:
    /// the Hub only credits whole completed files, so a single 4.5 GB weights file
    /// would sit at ~0 % then snap to 100 %. We instead poll the on-disk size of the
    /// cache + the in-flight download temp against the true total (which the Hub
    /// *does* report accurately) for a smooth, honest bar.
    func loadAndContinue() {
        if modelPhase == .ready { stage = .dashboard; return }
        guard modelPhase == .idle else { return }
        resetLoadTelemetry()
        totalBytes = Self.catalogBytes(selectedModelID)   // provisional denominator
        DownloadMeter.clearStaleTemps()
        modelPhase = .loading(0)
        loadStatus = "connecting…"
        startProgressTimer()
        Task {
            do {
                try await llm.load { [weak self] p in
                    // Use the Hub only for the accurate TOTAL byte count.
                    guard p.totalBytes > 0 else { return }
                    Task { @MainActor in self?.totalBytes = p.totalBytes }
                }
                downloadedBytes = totalBytes
                downloadFraction = 1
                modelPhase = .ready
                loadStatus = "ready ✓"
                stage = .dashboard
            } catch {
                modelPhase = .idle
                errorMessage = "Model load failed: \(error.localizedDescription)"
                loadStatus = ""
            }
        }
    }

    /// Polls disk every 0.5 s while loading: real downloaded bytes → smooth bar +
    /// a ticking elapsed clock.
    private func startProgressTimer() {
        let repo = selectedModelID
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, case .loading = self.modelPhase else { break }
                self.tickCount += 1
                self.loadElapsed = self.tickCount / 2
                self.refreshDiskProgress(repo: repo)
            }
        }
    }

    private func refreshDiskProgress(repo: String) {
        let bytes = DownloadMeter.bytesOnDisk(repo: repo)
        // Never let the bar go backwards (temp→blob moves can dip the instantaneous sum).
        downloadedBytes = max(downloadedBytes, bytes)
        if totalBytes > 0 {
            downloadFraction = min(0.999, Double(downloadedBytes) / Double(totalBytes))
        }
        if downloadFraction >= 0.98 {
            loadStatus = "loading onto GPU…"
        } else if downloadedBytes > 1_000_000 {
            loadStatus = "downloading weights…"
        } else {
            loadStatus = "connecting…"
        }
    }

    /// Fallback denominator parsed from the catalog size string ("4.5 GB").
    /// `nonisolated` so the off-main download-state refresh can call it.
    nonisolated static func catalogBytes(_ id: String) -> Int64 {
        guard let size = PennyLLM.catalog.first(where: { $0.id == id })?.size else { return 0 }
        guard let num = Double(size.split(separator: " ").first ?? "") else { return 0 }
        let mult: Double = size.uppercased().contains("GB") ? 1_000_000_000 : 1_000_000
        return Int64(num * mult)
    }

    // MARK: display helpers for the picker

    /// Fine-grained early on (so a 0.4 % sliver of a 4.5 GB file doesn't read as a
    /// dead "0 %"), integer once it's past 10 %.
    var downloadPercentText: String {
        let pct = downloadFraction * 100
        return pct >= 10 ? "\(Int(pct))%" : String(format: "%.1f%%", pct)
    }

    var downloadBytesText: String? {
        guard totalBytes > 0 else { return nil }
        return "\(Self.humanBytes(downloadedBytes)) / \(Self.humanBytes(totalBytes))"
    }

    var elapsedText: String {
        String(format: "%d:%02d", loadElapsed / 60, loadElapsed % 60)
    }

    static func humanBytes(_ b: Int64) -> String {
        let gb = Double(b) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(b) / 1_048_576)
    }

    // MARK: documents

    private struct ExtractResult: Sendable {
        let name: String
        let text: String
        let txns: [PennyCore.Transaction]
        let rows: [TxnRow]
        let currency: String
    }
    private struct ImportFailure: Error, Sendable { let message: String }

    /// Import a PDF WITHOUT freezing the UI: PDFKit text extraction and the
    /// deterministic `PennyTxnStore` parse both run off the main thread while the
    /// picker shows an "importing" state. Results are applied on the main actor.
    /// `kind` tags the import to an onboarding account tab (step 5), so the
    /// upload screen can show per-account progress.
    func importPDF(from url: URL, kind: String? = nil) {
        guard !isImporting else { return }
        isImporting = true
        isAnalyzing = true
        importingName = url.lastPathComponent
        errorMessage = nil
        Task {
            // Extract and a minimum-visible delay run concurrently, so tiny PDFs
            // (which parse in a few ms) still show the loader long enough to notice.
            async let extraction = Self.extract(url: url)
            await Self.minimumLoaderDelay()
            let result = await extraction
            isImporting = false
            importingName = nil
            switch result {
            case .success(let r):
                if r.text.isEmpty {
                    isAnalyzing = false
                    errorMessage = "No selectable text in \(r.name) (is it a scanned image?)"
                    return
                }
                if let i = docs.firstIndex(where: { $0.name == r.name }) {
                    // Re-import of a same-named file: refresh its parsed contents.
                    docs[i].transactions = r.txns
                    docs[i].rows = r.rows
                    docs[i].currency = r.currency
                    docs[i].analyzed = true
                } else {
                    docs.append(LoadedDoc(name: r.name, text: r.text,
                                          transactions: r.txns, rows: r.rows,
                                          currency: r.currency, analyzed: true))
                }
                selectedDocNames.insert(r.name)
                if let kind, uploadsByKind[kind]?.contains(r.name) != true {
                    uploadsByKind[kind, default: []].append(r.name)
                }
                isAnalyzing = false
                recomputeSummary()   // deterministic figures → fills the Today panel
            case .failure(let failure):
                isAnalyzing = false
                errorMessage = failure.message
            }
        }
    }

    nonisolated private static func minimumLoaderDelay() async {
        try? await Task.sleep(nanoseconds: 650_000_000)   // ~0.65 s floor
    }

    nonisolated private static func extract(url: URL) async -> Result<ExtractResult, ImportFailure> {
        await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                // PDFKit text is the chat grounding; the deterministic parser
                // produces the transactions/figures. Both read the same scoped file.
                let text = try StatementText.extract(from: url)
                let parsed = (try? DeterministicIngest.ingest(pdfAt: url))
                    ?? DeterministicIngest.Result(transactions: [], rows: [], currency: "INR", bank: nil)
                return .success(ExtractResult(name: url.lastPathComponent, text: text,
                                              txns: parsed.transactions, rows: parsed.rows,
                                              currency: parsed.currency))
            } catch {
                return .failure(ImportFailure(message: error.localizedDescription))
            }
        }.value
    }

    func toggleDoc(_ name: String) {
        if selectedDocNames.contains(name) { selectedDocNames.remove(name) }
        else { selectedDocNames.insert(name) }
        recomputeSummary()
    }

    // MARK: analysis (deterministic summary from parsed transactions)

    /// Sum the selected documents' transactions in Swift — deterministic, no model.
    func recomputeSummary() {
        let txns = docs
            .filter { selectedDocNames.isEmpty || selectedDocNames.contains($0.name) }
            .flatMap(\.transactions)
        var s = Summary()
        s.currency = detectCurrency()
        s.count = txns.count
        s.spent = txns.compactMap(\.debit).reduce(0, +)
        s.income = txns.compactMap(\.credit).reduce(0, +)
        s.net = s.income - s.spent
        s.balance = txns.last(where: { $0.balance != nil })?.balance
        s.categories = categorize(txns)
        summary = s
    }

    private func detectCurrency() -> String {
        let chosen = docs.filter { selectedDocNames.isEmpty || selectedDocNames.contains($0.name) }
        // Prefer the parser's detected currency when it's something other than the
        // default INR fallback — it's authoritative (read from the statement itself).
        if let cur = chosen.map(\.currency).first(where: { $0 != "INR" && !$0.isEmpty }) {
            return cur
        }
        // Otherwise sniff the raw text for a symbol/code.
        let text = chosen.map(\.text).joined()
        if text.contains("₹") || text.range(of: "INR", options: .caseInsensitive) != nil { return "INR" }
        if text.contains("£") || text.range(of: "GBP", options: .caseInsensitive) != nil { return "GBP" }
        if text.contains("€") || text.range(of: "EUR", options: .caseInsensitive) != nil { return "EUR" }
        if text.contains("$") || text.range(of: "USD", options: .caseInsensitive) != nil { return "USD" }
        return chosen.map(\.currency).first ?? "INR"
    }

    private func categorize(_ txns: [PennyCore.Transaction]) -> [CategorySpend] {
        var totals: [String: Double] = [:]
        for t in txns {
            guard let debit = t.debit, debit > 0 else { continue }
            // Prefer the parser's deterministic category (from categories.json);
            // fall back to the keyword heuristic only for model-extracted rows.
            let name = (t.category?.isEmpty == false) ? t.category! : Self.categoryName(t.description)
            totals[name, default: 0] += debit
        }
        return totals
            .map { CategorySpend(name: $0.key, amount: $0.value) }
            .sorted { $0.amount > $1.amount }
    }

    static func categoryName(_ description: String) -> String {
        let d = description.lowercased()
        if d.contains("grocer") { return "Groceries" }
        if d.contains("restaurant") || d.contains("food") || d.contains("dining") || d.contains("cafe") || d.contains("coffee") { return "Food & Dining" }
        if d.contains("fuel") || d.contains("petrol") || d.contains("uber") || d.contains("transport") || d.contains("travel") { return "Transport" }
        if d.contains("electric") || d.contains("utilit") || d.contains("water") || d.contains("gas") || d.contains("bill") { return "Bills & Utilities" }
        if d.contains("shop") || d.contains("amazon") || d.contains("flipkart") || d.contains("store") || d.contains("mart") { return "Shopping" }
        if d.contains("atm") || d.contains("cash") || d.contains("withdrawal") { return "Cash & ATM" }
        if d.contains("transfer") || d.contains("upi") || d.contains("neft") || d.contains("imps") { return "Transfers" }
        return "Other"
    }

    // MARK: deterministic chat answers (from extracted data, not the model)

    private func selectedTransactions() -> [PennyCore.Transaction] {
        docs.filter { selectedDocNames.isEmpty || selectedDocNames.contains($0.name) }
            .flatMap(\.transactions)
    }

    /// The parsed canonical rows for the selected documents — the input to the
    /// deterministic finance query router.
    private func selectedRows() -> [TxnRow] {
        docs.filter { selectedDocNames.isEmpty || selectedDocNames.contains($0.name) }
            .flatMap(\.rows)
    }

    /// Does the question ask for the transaction list/table (vs. a count or a nuanced Q)?
    private func wantsTransactionTable(_ q: String) -> Bool {
        let l = q.lowercased()
        if l.contains("how many") || l.contains("count") || l.contains("number of") { return false }
        let dataWord = l.contains("transaction") || l.contains("table") || l.contains("all data")
            || l.contains("ledger") || l.contains("entries") || l.contains("statement data")
        let listWord = l.contains("all") || l.contains("list") || l.contains("table")
            || l.contains("show") || l.contains("every") || l.contains("full") || l.contains("create")
        return dataWord && listWord
    }

    /// Build a complete Markdown table from the extracted transactions.
    static func transactionsMarkdown(_ txns: [PennyCore.Transaction], currency: String) -> String {
        let cap = 200
        let shown = Array(txns.prefix(cap))
        var lines = [
            "| # | Date | Description | Debit | Credit | Balance |",
            "|---|------|-------------|-------|--------|---------|",
        ]
        for (i, t) in shown.enumerated() {
            let debit = t.debit.map { Money.format($0, currency: currency) } ?? ""
            let credit = t.credit.map { Money.format($0, currency: currency) } ?? ""
            let balance = t.balance.map { Money.format($0, currency: currency) } ?? ""
            var desc = t.description.replacingOccurrences(of: "|", with: "/")
            if desc.count > 40 { desc = String(desc.prefix(39)) + "…" }
            lines.append("| \(i + 1) | \(t.date) | \(desc) | \(debit) | \(credit) | \(balance) |")
        }
        var out = lines.joined(separator: "\n")
        if txns.count > cap { out += "\n\n_Showing first \(cap) of \(txns.count)._" }
        return out
    }

    /// Text handed to the model as grounding: the selected statements (or all of
    /// them if nothing is explicitly selected).
    private func scopedText() -> String {
        let chosen = docs.filter {
            selectedDocNames.isEmpty || selectedDocNames.contains($0.name)
        }
        return chosen.map { "### \($0.name)\n\($0.text)" }.joined(separator: "\n\n")
    }

    // MARK: chat history

    /// "✨ New chat" — archive whatever was said, then start fresh.
    func newChat() {
        archiveCurrentChat()
        messages.removeAll()
        centerView = .chat
    }

    /// Move the live transcript into History (skipped when nothing was said).
    private func archiveCurrentChat() {
        let kept = messages.filter { !$0.content.isEmpty }
        guard kept.contains(where: { $0.role == .user }) else { return }
        let title = kept.first(where: { $0.role == .user })?.content ?? "Chat"
        history.insert(ChatSession(id: UUID(),
                                   title: String(title.prefix(80)),
                                   date: Date(),
                                   messages: kept), at: 0)
        saveHistory()
    }

    /// Reopen a past conversation: it becomes the live chat again (and will be
    /// re-archived, updated, the next time the user starts a new chat).
    func openSession(_ session: ChatSession) {
        archiveCurrentChat()
        history.removeAll { $0.id == session.id }
        messages = session.messages
        centerView = .chat
        saveHistory()
    }

    func deleteSession(_ session: ChatSession) {
        history.removeAll { $0.id == session.id }
        saveHistory()
    }

    // History lives as JSON in the app's sandboxed Application Support — on
    // this Mac only, like everything else.
    private static var historyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Penny", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chat-history.json")
    }

    private static func loadHistory() -> [ChatSession] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        return (try? JSONDecoder().decode([ChatSession].self, from: data)) ?? []
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: Self.historyURL, options: .atomic)
        }
    }

    // MARK: chat

    func send(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isThinking else { return }
        errorMessage = nil
        messages.append(ChatMessage(role: .user, content: q))

        // Deterministic route: if they want the transaction list/table and we've
        // already extracted it, answer straight from the data — complete and correctly
        // aligned — instead of asking the model to re-type it from a clipped context
        // (which truncates rows and garbles columns).
        let txns = selectedTransactions()
        if wantsTransactionTable(q), !txns.isEmpty {
            let verb = txns.count == 1 ? "is" : "are"
            let noun = txns.count == 1 ? "transaction" : "transactions"
            let header = "Here \(verb) all \(txns.count) \(noun) on record:\n\n"
            let table = Self.transactionsMarkdown(txns, currency: summary.currency)
            messages.append(ChatMessage(role: .assistant, content: header + table, engine: "LEDGER"))
            return
        }

        // Deterministic finance router: answer factual numeric questions (totals,
        // counts, balance, category/merchant/period spend, largest/top, income,
        // net, average) straight from the parsed rows — no model, no hallucinated
        // figures. Returns nil for advisory/open-ended questions, which fall to MLX.
        let cur = summary.currency
        if let answer = FinanceRouter.answer(q, rows: selectedRows(), currency: cur,
                                             money: { Money.format($0, currency: cur) }) {
            messages.append(ChatMessage(role: .assistant, content: answer, engine: "ANALYTICS"))
            return
        }

        messages.append(ChatMessage(role: .assistant, content: "", engine: "MLX"))
        let idx = messages.count - 1
        isThinking = true

        let rows = selectedRows()
        let fullText = scopedText()
        let key = retrieverSignature()
        Task {
            // On-device hybrid RAG: ground the model on the handful of transactions
            // most relevant to the question instead of the whole statement (which
            // blows the context window and dilutes relevance on big statements).
            var grounding = fullText
            if !rows.isEmpty {
                let retr: TxnRetriever
                if let cached = retriever, retrieverKey == key {
                    retr = cached
                } else {
                    retr = await Task.detached { TxnRetriever(rows: rows) }.value
                    retriever = retr
                    retrieverKey = key
                }
                let hits = retr.topK(q, k: 14)
                if !hits.isEmpty {
                    grounding = Self.retrievalContext(hits, currency: summary.currency)
                }
            }
            do {
                // Generous cap so long outputs (e.g. a full transaction table) aren't
                // truncated mid-row; short answers still stop early at end-of-text.
                _ = try await llm.ask(question: q, statementText: grounding, maxTokens: 4096) { [weak self] piece in
                    Task { @MainActor in
                        guard let self, self.messages.indices.contains(idx) else { return }
                        self.messages[idx].content += piece
                    }
                }
            } catch {
                if messages.indices.contains(idx) {
                    messages[idx].content = "Sorry — I couldn't answer that. \(error.localizedDescription)"
                }
            }
            isThinking = false
        }
    }

    /// A cheap signature of the selected-document set — the RAG index is rebuilt
    /// only when this changes (docs added/removed or selection toggled).
    private func retrieverSignature() -> String {
        docs.filter { selectedDocNames.isEmpty || selectedDocNames.contains($0.name) }
            .map { "\($0.name):\($0.rows.count)" }
            .sorted()
            .joined(separator: "|")
    }

    /// Format the retrieved rows as compact grounding for the model — the RAG
    /// context that replaces whole-document stuffing.
    static func retrievalContext(_ rows: [PennyTxnStore.TxnRow], currency: String) -> String {
        var lines = [
            "Here are the transactions from the user's statement most relevant to their question.",
            "Base your answer only on these rows:",
            "",
        ]
        for r in rows {
            let amt = r.debit > 0 ? "spent \(Money.format(r.debit, currency: currency))"
                                  : "received \(Money.format(r.credit, currency: currency))"
            let bal = r.balance.map { " · balance \(Money.format($0, currency: currency))" } ?? ""
            lines.append("• \(r.txnDate) — \(r.descr) [\(r.category)] — \(amt)\(bal)")
        }
        return lines.joined(separator: "\n")
    }

    /// Quick-action flows — the SwiftUI twin of Dashboard.runFlow(). Each maps to a
    /// natural-language prompt. (In FinQuery these route through the SQL/ML engine;
    /// here they go to the on-device model until the analytics layer is ported.)
    func runFlow(_ action: String) {
        let map: [String: String] = [
            "roast":    "roast my spending",
            "ghosts":   "find recurring subscriptions i forgot i had",
            "patterns": "what spending patterns do you notice?",
            "forecast": "give me a spending forecast",
            "compound": "calculate compound savings if i cut back",
            "reports":  "show my category report",
            "splurge":  "can i splurge this month?",
        ]
        send(map[action] ?? action)
    }
}

// MARK: - Disk-based download meter

/// Measures how many bytes of a model are actually on disk, by summing the
/// HuggingFace cache blobs plus the in-flight `CFNetworkDownload_*.tmp` files —
/// all inside the app's OWN sandbox container, so it's entitlement-safe.
///
/// This exists because the Hub's `Progress.completedUnitCount` only advances when
/// a whole file finishes; for a single multi-GB weights file that means no motion
/// until the very end. Real on-disk bytes give a smooth, truthful percentage.
enum DownloadMeter {
    /// `repo` is a HuggingFace id like "mlx-community/Llama-3.1-8B-Instruct-4bit".
    static func bytesOnDisk(repo: String) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0

        // 1) Completed blobs in the HF cache: <Caches>/huggingface/hub/models--<repo>
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let escaped = "models--" + repo.replacingOccurrences(of: "/", with: "--")
            let modelDir = caches.appendingPathComponent("huggingface/hub/\(escaped)")
            total += dirSize(modelDir, fm: fm)
        }

        // 2) In-flight downloads: URLSession streams to CFNetworkDownload_*.tmp in tmp.
        total += tempDownloadBytes(fm: fm)
        return total
    }

    /// Remove abandoned download temps from a previous, interrupted run so they
    /// don't inflate the numerator. Safe: called before a fresh download starts.
    static func clearStaleTemps() {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        for u in items where u.lastPathComponent.hasPrefix("CFNetworkDownload") {
            try? fm.removeItem(at: u)
        }
    }

    private static func tempDownloadBytes(fm: FileManager) -> Int64 {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let items = try? fm.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for u in items where u.lastPathComponent.hasPrefix("CFNetworkDownload") {
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private static func dirSize(_ url: URL, fm: FileManager) -> Int64 {
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in en {
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
