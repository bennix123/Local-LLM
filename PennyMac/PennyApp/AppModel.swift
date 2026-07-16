import Foundation
import SwiftUI
import PennyCore

// MARK: - App-level types

enum AppStage { case onboarding, modelPicker, dashboard }

enum ModelPhase: Equatable {
    case idle
    case loading(Int)   // percent 0-100
    case ready
}

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var content: String
    var engine: String?   // e.g. "MLX" — the badge shown on assistant bubbles
}

/// A statement the user imported. Until the deterministic data-core step lands,
/// a "document" is just its PDFKit-extracted text (no parsed transactions yet).
struct LoadedDoc: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let text: String
    var transactions: [PennyCore.Transaction] = []   // PennyCore-qualified: SwiftUI also has a `Transaction`
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
    private var analyzeCount = 0

    // chat
    @Published var messages: [ChatMessage] = []
    @Published var isThinking = false
    @Published var errorMessage: String?

    // ui prefs
    @Published var offlineOnly = true

    private var llm = PennyLLM(modelID: PennyLLM.sliceModelID)
    private var tickCount = 0   // 0.5 s ticks, for the elapsed clock

    var catalog: [PennyLLM.CatalogEntry] { PennyLLM.catalog }

    var modelDisplayName: String {
        catalog.first { $0.id == selectedModelID }?.name ?? "local model"
    }

    /// The Today panel is ready once we've extracted at least one transaction.
    var contextReady: Bool { summary.count > 0 }
    var transactionCount: Int { summary.count }

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
    static func catalogBytes(_ id: String) -> Int64 {
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

    private struct ExtractResult: Sendable { let name: String; let text: String }
    private struct ImportFailure: Error, Sendable { let message: String }

    /// Import a PDF WITHOUT freezing the UI: PDFKit text extraction can take a
    /// while on a big statement, so it runs off the main thread while the picker
    /// shows an "importing" state. Results are applied back on the main actor.
    func importPDF(from url: URL) {
        guard !isImporting else { return }
        isImporting = true
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
                    errorMessage = "No selectable text in \(r.name) (is it a scanned image?)"
                    return
                }
                if !docs.contains(where: { $0.name == r.name }) {
                    docs.append(LoadedDoc(name: r.name, text: r.text))
                }
                selectedDocNames.insert(r.name)
                analyze(r.name)   // extract transactions → fills the Today panel
            case .failure(let failure):
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
                let text = try StatementText.extract(from: url)
                return .success(ExtractResult(name: url.lastPathComponent, text: text))
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

    // MARK: analysis (deterministic summary from extracted transactions)

    /// Extract transactions for a freshly-imported doc in the background, then
    /// recompute the Today figures. Upload stays fast; the panel fills in when ready.
    private func analyze(_ name: String) {
        guard let text = docs.first(where: { $0.name == name })?.text else { return }
        analyzeCount += 1
        isAnalyzing = true
        Task {
            let txns = (try? await llm.extractTransactions(from: text)) ?? []
            if let i = docs.firstIndex(where: { $0.name == name }) {
                docs[i].transactions = txns
                docs[i].analyzed = true
            }
            analyzeCount -= 1
            isAnalyzing = analyzeCount > 0
            recomputeSummary()
        }
    }

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
        let text = docs
            .filter { selectedDocNames.isEmpty || selectedDocNames.contains($0.name) }
            .map(\.text).joined()
        if text.contains("₹") || text.range(of: "INR", options: .caseInsensitive) != nil { return "INR" }
        if text.contains("£") || text.range(of: "GBP", options: .caseInsensitive) != nil { return "GBP" }
        if text.contains("€") || text.range(of: "EUR", options: .caseInsensitive) != nil { return "EUR" }
        if text.contains("$") || text.range(of: "USD", options: .caseInsensitive) != nil { return "USD" }
        return "INR"
    }

    private func categorize(_ txns: [PennyCore.Transaction]) -> [CategorySpend] {
        var totals: [String: Double] = [:]
        for t in txns {
            guard let debit = t.debit, debit > 0 else { continue }
            totals[Self.categoryName(t.description), default: 0] += debit
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

    // MARK: chat

    func newChat() { messages.removeAll() }

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

        messages.append(ChatMessage(role: .assistant, content: "", engine: "MLX"))
        let idx = messages.count - 1
        isThinking = true

        let doc = scopedText()
        Task {
            do {
                // Generous cap so long outputs (e.g. a full transaction table) aren't
                // truncated mid-row; short answers still stop early at end-of-text.
                _ = try await llm.ask(question: q, statementText: doc, maxTokens: 4096) { [weak self] piece in
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
