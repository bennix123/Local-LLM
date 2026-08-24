import Foundation
import SwiftUI
import Security
import PennyCore
import PennyModel
import PennyFinance
import PennyTxnStore

/// Keychain persistence for the user's Anthropic API key — categories come
/// from the Claude API only, so the key must survive relaunches. Generic
/// password item; never written to UserDefaults or any file.
enum APIKeyStore {
    private static let service = "com.penny.anthropic-api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service]
    }

    static func load() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func clear() { SecItemDelete(query as CFDictionary) }
}

/// The hosted categorization proxy. It holds the real Anthropic key server-side
/// and forwards `/v1/messages`, so distributed builds (TestFlight) categorize
/// without every user pasting their own key — the reason categories showed as
/// all "Other" for testers, who have neither the `ANTHROPIC_API_KEY` env var nor
/// a Keychain key. A developer's own key still wins (see `AppModel`); the proxy
/// is only used when there isn't one.
///
/// SETUP: set `urlString` to your deployed proxy's `/v1/messages` URL and
/// `appToken` to the shared token the proxy checks (see `penny-proxy/`). Leaving
/// `urlString` empty disables the proxy and restores the old key-only behavior.
enum PennyBackend {
    /// Penny's single hosted backend (see `penny-categories-server/`). Serves the
    /// central categories API and, if configured server-side, the Anthropic
    /// categorization proxy — both under this one host.
    static let host = "https://penny1.thescript.design"

    /// The categorization proxy endpoint. Empty disables the proxy (a developer's
    /// own `ANTHROPIC_API_KEY`/Keychain key then takes over, as before). Set to
    /// `host + "/v1/messages"` only once the server has `ANTHROPIC_API_KEY` set.
    static let urlString = host + "/v1/messages"
    static let appToken  = "02395bd2d19b6307e8c58216e9375254c578bae8f2eed4b5e851cfb8de50dcb8"  // must equal APP_TOKEN on the server

    /// The central categories endpoint — every device fetches the same, always-
    /// current categorization vocabulary from here (see `CategoryCatalog`).
    static let categoriesURLString = host + "/v1/categories"

    static var proxyURL: URL? { urlString.isEmpty ? nil : URL(string: urlString) }
    static var categoriesURL: URL? { categoriesURLString.isEmpty ? nil : URL(string: categoriesURLString) }
    static var isConfigured: Bool { proxyURL != nil }
}

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
    /// Stable identity — the statement id when derived from the canonical model
    /// (Task 0.7), so the derived `docs` cache keeps SwiftUI list identity across
    /// re-derivations; falls back to the filename.
    var id: String { statementID?.raw ?? name }
    /// The canonical statement this doc projects (nil for hand-built test docs).
    var statementID: StatementID? = nil
    let name: String
    let text: String
    var transactions: [PennyCore.Transaction] = []   // PennyCore-qualified: SwiftUI also has a `Transaction`
    var rows: [TxnRow] = []                           // richer canonical rows, for the deterministic query router
    var currency: String = "INR"                     // currency the parser detected for this statement
    var bank: String? = nil                          // bank name the parser detected ("HDFC Bank", …)
    var detectedIssuer: String? = nil                // on-device LLM's institution name (async, best-effort)
    var closingBalance: Double? = nil                // the statement's own closing-balance figure
    var isCard = false                               // credit-card semantics: balance = owed
    var analyzed = false
    var charCount: Int { text.count }
    /// This account's latest balance: the last running balance in the rows, or
    /// the statement's stated closing balance (cards carry no per-row balance).
    var latestBalance: Double? {
        transactions.last(where: { $0.balance != nil })?.balance ?? closingBalance
    }
    /// Sidebar display name. Priority: (1) the on-device LLM's institution name,
    /// which generalizes to any bank/card issuer (async — filled in once the model
    /// has run); (2) an issuer matched straight from the text by a fast synchronous
    /// heuristic, so the row is labelled instantly and even before the model loads;
    /// (3) the parser's bank name, but only when it reads like a real bank and not
    /// its filename fallback (which surfaced files like `Sample_Statement_amex.pdf`
    /// as a bank called "Sample"); (4) the filename.
    var displayName: String {
        if let detectedIssuer { return detectedIssuer }
        if let issuer = Self.detectIssuer(in: text) { return issuer }
        if let bank, Self.looksLikeBankName(bank) { return bank }
        return name
    }

    static func looksLikeBankName(_ s: String) -> Bool {
        s.range(of: #"\b(bank|banking|financial|cooperative|credit union|building society)\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Display-only issuer detection over the statement text. Runs purely in the
    /// app layer — it never feeds PennyCore, so the 15/15 conformance contract
    /// (which pins parser bank names to filename-derived values) is untouched.
    /// Scans the header region and returns the issuer whose brand appears
    /// *earliest* — the real letterhead sits at the top, while a stray mention
    /// of another provider (e.g. a "MONZO" transfer line) appears far lower.
    static func detectIssuer(in text: String) -> String? {
        let head = String(text.prefix(1500)).lowercased()
        let table: [(String, String)] = [
            (#"american express|\bamex\b"#,               "American Express"),
            (#"\bnationwide\b"#,                          "Nationwide"),
            (#"natwest|national westminster"#,            "NatWest"),
            (#"\brevolut\b"#,                             "Revolut"),
            (#"\bmonzo\b"#,                               "Monzo"),
            (#"\bstarling\b"#,                            "Starling Bank"),
            (#"\bbarclays\b"#,                            "Barclays Bank"),
            (#"\bhsbc\b"#,                                "HSBC"),
            (#"\blloyds\b"#,                              "Lloyds Bank"),
            (#"\bsantander\b"#,                           "Santander"),
            (#"\bhalifax\b"#,                             "Halifax"),
            (#"\bmetro bank\b"#,                          "Metro Bank"),
            (#"co-?operative bank|the co-?op bank"#,      "Co-operative Bank"),
            (#"\bchase\b"#,                               "Chase"),
            // Indian banks / wallets. Paytm statements carry the "PPBL" (Paytm
            // Payments Bank Ltd) letterhead; match that, not bare "paytm" (which
            // also appears in UPI transaction lines). Note "axis" is matched only
            // as "Axis Bank" — the IFSC prefix "utib"/handles like "@sliceaxis"
            // must NOT read as an Axis statement.
            (#"\bppbl\b|paytm payments bank"#,            "Paytm Payments Bank"),
            (#"\baxis bank\b"#,                           "Axis Bank"),
            (#"\bhdfc\b"#,                                "HDFC Bank"),
            (#"\bicici\b"#,                               "ICICI Bank"),
            (#"state bank of india|\bsbi\b"#,             "State Bank of India"),
            (#"\bkotak\b"#,                               "Kotak Mahindra Bank"),
            (#"\byes bank\b"#,                            "Yes Bank"),
            (#"\bidfc\b"#,                                "IDFC First Bank"),
            (#"\bindusind\b"#,                            "IndusInd Bank"),
            (#"punjab national|\bpnb\b"#,                 "Punjab National Bank"),
            (#"bank of baroda"#,                          "Bank of Baroda"),
            (#"\bcanara\b"#,                              "Canara Bank"),
            (#"union bank of india"#,                     "Union Bank of India"),
            (#"\bidbi\b"#,                                "IDBI Bank"),
        ]
        var best: (idx: Int, name: String)? = nil
        for (pat, name) in table {
            guard let r = head.range(of: pat, options: .regularExpression) else { continue }
            let idx = head.distance(from: head.startIndex, to: r.lowerBound)
            if best == nil || idx < best!.idx { best = (idx, name) }
        }
        return best?.name
    }
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
    /// Per-currency breakdown of the same figures, keyed by currency code —
    /// so statements in different currencies are never collapsed into one
    /// meaningless mixed sum. Single-currency imports produce one entry whose
    /// figures equal the top-level ones.
    var perCurrency: [String: CurrencyTotals] = [:]
    /// Currencies present, sorted for a deterministic display order.
    var currencyList: [String] { perCurrency.keys.sorted() }
    /// True when the selected statements span more than one currency.
    var isMultiCurrency: Bool { perCurrency.count > 1 }
}

/// One currency's slice of the Today-panel figures (see `Summary.perCurrency`).
struct CurrencyTotals: Equatable {
    var balance: Double?
    var spent: Double = 0
    var income: Double = 0
    var net: Double = 0
    var count: Int = 0
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
    /// (In `--uitest` runs nothing persists: the Debug build shares its sandbox
    /// container with the installed app, so tests must never write real prefs.)
    @Published var userName: String = TestMode.active ? "" : (UserDefaults.standard.string(forKey: "penny.userName") ?? "") {
        didSet { if !TestMode.active { UserDefaults.standard.set(userName, forKey: "penny.userName") } }
    }

    /// Account kinds picked in step 4 ("stocks" dropped — it's a coming-soon card now).
    @Published var selectedAccountKinds: [String] = ["current", "credit"]

    /// Which account tab is active on the upload screen (index into selectedAccountKinds).
    @Published var uploadKindIndex: Int = 0

    /// Statement files imported per account kind (doc names, in import order).
    @Published var uploadsByKind: [String: [String]] = [:]

    func goToStep(_ n: Int) { onboardStep = max(1, min(7, n)) }

    /// "Take me to Penny →" — model still has to be picked/loaded before chat.
    func finishOnboarding() {
        stage = modelPhase == .ready ? .dashboard : .modelPicker
    }

    /// Welcome-screen "skip" — jump straight to the model-select page.
    func skipToModelPicker() { stage = .modelPicker }

    /// The account kind currently receiving uploads on step 5.
    var currentUploadKind: String? {
        selectedAccountKinds.indices.contains(uploadKindIndex) ? selectedAccountKinds[uploadKindIndex] : nil
    }

    /// Docs imported for a given account kind (dropped docs are filtered out).
    func uploads(for kind: String) -> [LoadedDoc] {
        (uploadsByKind[kind] ?? []).compactMap { name in docs.first { $0.name == name } }
    }

    /// Remove an onboarding upload everywhere it's tracked (incl. on disk).
    func removeDoc(named name: String) {
        let ids = graph.statements.filter { $0.sourceName == name }.map(\.id)
        let removed = Set(ids)
        graph = FinancialGraph(accounts: graph.accounts,
                               statements: graph.statements.filter { !removed.contains($0.id) },
                               transactions: graph.transactions.filter { !removed.contains($0.statementID) },
                               merchants: graph.merchants, categories: graph.categories)
        ids.forEach { statementText[$0] = nil; issuerOverrides[$0] = nil; selectedStatementIDs.remove($0) }
        for (kind, names) in uploadsByKind {
            uploadsByKind[kind] = names.filter { $0 != name }
        }
        StatementStore.remove(sourceName: name)
        deriveDocs()
        recomputeSummary()
    }

    /// Delete everything Penny has persisted — statements and chat history —
    /// and reset the in-memory session. The onboarding privacy copy promises
    /// "you can wipe everything anytime", so this must really erase disk.
    func wipeAllData() {
        // Stop any in-flight categorization first — otherwise it keeps running
        // (and showing "categorizing… N/M") against the now-empty graph.
        recategorizeTask?.cancel()
        recategorizeTask = nil
        isRecategorizing = false
        categorizeProgress = nil

        StatementStore.wipeAll()
        try? FileManager.default.removeItem(at: Self.historyURL)
        // The learned merchant knowledge base is user data too — wipe it.
        merchantKB = MerchantKnowledgeBase()
        try? FileManager.default.removeItem(at: Self.merchantKBURL)

        graph = .empty
        statementText = [:]
        issuerOverrides = [:]
        selectedStatementIDs = []
        uploadsByKind = [:]
        messages.removeAll()
        history.removeAll()
        errorMessage = nil
        bytesSentOut = 0
        deriveDocs()
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
    //
    // Task 0.7 — the canonical `graph` is the ONLY mutable financial source of
    // truth. `docs` is a derived, read-only cache (never mutated directly), rebuilt
    // by `deriveDocs()` after any graph change. `statementText` (grounding) and
    // `issuerOverrides` (presentation) are thin non-financial side-stores that the
    // derivation reads. Selection is canonical (`selectedStatementIDs`);
    // `selectedDocNames` is a compatibility view for the UI/tests.
    @Published private(set) var graph: FinancialGraph = .empty
    @Published private(set) var docs: [LoadedDoc] = []
    @Published var selectedStatementIDs: Set<StatementID> = []

    /// Phase 1.1 routing telemetry: how often the Query Engine answered (parity with
    /// the router), fell back to the router, or the question was unsupported by both.
    struct EngineRoutingStats: Equatable { var routed = 0; var fellBack = 0; var unsupported = 0 }
    private(set) var engineRoutingStats = EngineRoutingStats()
    /// Per-statement grounding text + import time — provenance, not financial data.
    private var statementText: [StatementID: (text: String, importedAt: Date)] = [:]
    /// On-device issuer labels (async, best-effort) — presentation, re-derived each launch.
    private var issuerOverrides: [StatementID: String] = [:]

    /// Compatibility view of the selection as statement filenames (empty ⇒ all),
    /// so existing UI (`toggleDoc`, sidebar) and tests keep working while the
    /// canonical selection is `selectedStatementIDs`.
    var selectedDocNames: Set<String> {
        get {
            guard !selectedStatementIDs.isEmpty else { return [] }   // empty ⇒ all selected
            return Set(graph.statements.filter { selectedStatementIDs.contains($0.id) }.map(\.sourceName))
        }
        set {
            if newValue.isEmpty { selectedStatementIDs = [] }
            else { selectedStatementIDs = Set(graph.statements.filter { newValue.contains($0.sourceName) }.map(\.id)) }
            recomputeSummary()
        }
    }

    @Published var isImporting = false
    @Published var importingName: String?
    @Published var isAnalyzing = false
    @Published var summary = Summary()

    // Progressive multi-statement analysis (up to 6 months): staged progress the
    // loader UI observes, plus a small toast queue for batch-completion messages.
    @Published var analysis: AnalysisProgress = .idle
    @Published var toasts: [ToastMessage] = []

    // Anthropic key powering categorization (API-only, user directive) and the
    // scanned-PDF OCR extraction fallback. Read from the ANTHROPIC_API_KEY
    // environment variable, else from the Keychain (saved via the sidebar's
    // key field). nil → categorization is a no-op and rows keep their
    // deterministic placeholder labels.
    @Published var claudeAPIKey: String? =
        ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? APIKeyStore.load()

    /// The credential + endpoint the categorizer should use. A developer's own key
    /// talks to Anthropic directly (`x-api-key`); everyone else (TestFlight) goes
    /// through the hosted proxy, which holds the key server-side. `nil` only when
    /// there is neither a local key nor a configured proxy — then categorization is
    /// a no-op and rows keep their deterministic placeholders.
    var categorizerConfig: (key: String, endpoint: ClaudeCategorizer.Endpoint)? {
        if let k = claudeAPIKey, !k.isEmpty { return (k, .anthropic) }
        if let url = PennyBackend.proxyURL { return (PennyBackend.appToken, .proxy(url)) }
        return nil
    }

    /// Whether a categorization pass can run at all (own key OR proxy). Drives the
    /// "add your key" prompts — with a proxy configured, no key is needed.
    var categorizationAvailable: Bool { categorizerConfig != nil }

    /// Save the user's API key (Keychain-backed) and immediately run the full
    /// API categorization pass over whatever is loaded.
    func setClaudeAPIKey(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        claudeAPIKey = key
        APIKeyStore.save(key)
        postToast("Claude API key saved — categorizing with the API…", kind: .success)
        refineCategoriesForLoadedStatements(manual: true)
    }

    /// Forget the stored key. Existing API-assigned categories stay.
    func clearClaudeAPIKey() {
        claudeAPIKey = nil
        APIKeyStore.clear()
        postToast("Claude API key removed.", kind: .progress)
    }

    /// Bytes actually sent to Anthropic this session (AI categorization + the
    /// scanned-PDF OCR fallback). Drives the privacy panel honestly — 0 keeps the
    /// "fully offline" badge; > 0 flips it to a "sent to Claude" state. Reset on wipe.
    @Published private(set) var bytesSentOut = 0

    /// An AI re-categorization pass is in flight — disables the manual button and
    /// guards against concurrent runs.
    @Published private(set) var isRecategorizing = false

    /// Live progress of the in-flight categorization pass — `done`/`total` distinct
    /// NEW merchants sent to Claude — so the "spend by category" loader shows a
    /// moving count instead of a frozen skeleton on big statements. nil when idle
    /// or when every merchant was already known (no API call). See `ContextPanelView`.
    struct CategorizeProgress: Equatable { var done: Int; var total: Int }
    @Published private(set) var categorizeProgress: CategorizeProgress?

    /// Handle on the in-flight categorization pass so Wipe (and app teardown) can
    /// cancel it — otherwise it keeps running against a wiped graph.
    private var recategorizeTask: Task<Void, Never>?

    /// The growing merchant knowledge base (spec Steps 6 & 8): once Claude has
    /// identified a merchant we store its business + primary/secondary category
    /// keyed by normalized name, so recognised merchants resolve instantly, the
    /// same merchant is ALWAYS categorized the same way, and only genuinely new
    /// merchants ever reach the API. Loaded at launch, saved after each pass.
    private var merchantKB = MerchantKnowledgeBase.load(from: AppModel.merchantKBURL)

    /// On-disk location of the merchant knowledge base (per-process temp under
    /// TestMode so tests never touch the user's real KB).
    static var merchantKBURL: URL {
        let base: URL = TestMode.active
            ? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("penny-uitest-kb-\(getpid())", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Penny", isDirectory: true)
        return base.appendingPathComponent("merchant_kb.json")
    }

    // chat
    @Published var messages: [ChatMessage] = []
    @Published var isThinking = false
    @Published var errorMessage: String?

    /// Handle on the in-flight streaming generation so the Stop button can cancel
    /// a hallucinating / runaway answer mid-stream. Nil when nothing is generating.
    private var generateTask: Task<Void, Never>?

    // chat history
    @Published var centerView: CenterView = .chat
    @Published var history: [ChatSession] = AppModel.loadHistory()

    // ui prefs

    /// The catalog's 8B model — the upgrade target the brain-panel nudge points
    /// 16 GB+ Macs at while they're still on the default 3B slice.
    static let upgradeModelID = "mlx-community/Llama-3.1-8B-Instruct-4bit"

    /// "8B model available for this Mac" hint dismissed — persisted so the
    /// nudge never nags (in-memory only under TestMode, like `userName`).
    @Published var upgradeNudgeDismissed: Bool =
        TestMode.active ? false : UserDefaults.standard.bool(forKey: "penny.upgradeNudgeDismissed") {
        didSet {
            if !TestMode.active {
                UserDefaults.standard.set(upgradeNudgeDismissed, forKey: "penny.upgradeNudgeDismissed")
            }
        }
    }

    /// Show the brain-panel upgrade hint: this Mac fits the 8B model, the 3B
    /// slice is in use, and the 8B weights aren't already downloaded.
    var showUpgradeNudge: Bool {
        !upgradeNudgeDismissed
            && Self.deviceRAMGB >= 16
            && selectedModelID == PennyLLM.sliceModelID
            && !downloadedModelIDs.contains(Self.upgradeModelID)
    }

    private var llm = PennyLLM(modelID: PennyLLM.sliceModelID)
    private var tickCount = 0   // 0.5 s ticks, for the elapsed clock

    /// Restores persisted statements on launch (decode off-main, apply on the
    /// main actor). Held as a handle so tests can await — or cancel — it.
    private(set) var restoreTask: Task<Void, Never>?

    init() {
        // Bring back the statements persisted by earlier launches: decode off
        // the main thread, then apply + recompute on the main actor. In test
        // mode `StatementStore` points at an empty per-process temp dir, so
        // this is a no-op there unless the test itself persisted docs.
        restoreTask = Task { [weak self] in
            let records = await Task.detached(priority: .userInitiated) { () -> [StatementStore.StatementRecord] in
                StatementStore.migrateV1IfNeeded()   // one-time v1 → v2
                return StatementStore.loadRecords()
            }.value
            guard let self, !Task.isCancelled, !records.isEmpty else { return }
            for r in records where self.statementText[r.statement.id] == nil {
                let slice = FinancialGraph(accounts: [r.account], statements: [r.statement],
                                           transactions: r.transactions,
                                           merchants: r.merchants, categories: r.categories)
                self.addSlice(slice, text: r.text, importedAt: r.importedAt)
            }
            self.deriveDocs()
            self.recomputeSummary()
            // Restored statements may still carry "Other" rows. Run the on-device
            // mop-up now (skips itself when the model isn't loaded yet — the
            // post-load hook in `loadAndContinue` catches that case).
            self.refineCategoriesForLoadedStatements()
        }
        // macOS 26+ with Apple Intelligence: the built-in system model handles chat,
        // categorization, issuer detection and extraction with zero download. Mark the
        // engine ready up front so onboarding skips the MLX model picker and we never
        // bring up MLX/Metal — whose shader-library init (~MTLLibraryDataWithArchive)
        // crashed with SIGTRAP on some client machines. Users can still open the picker
        // to deliberately download an MLX model (chooseModel resets modelPhase).
        if PennyLLM.systemModelAvailable { modelPhase = .ready }
        // XCUITest hooks (inert without `--uitest`): pretend the model is ready,
        // optionally skip to the dashboard, and import a fixture statement
        // directly — the sandboxed NSOpenPanel can't be driven reliably.
        if TestMode.modelReady { modelPhase = .ready }
        if TestMode.startAtDashboard {
            // One runloop later, NOT in the first frame: launching straight
            // into DashboardView kills the XCUITest automation channel (live
            // AX queries die at the XPC timeout), while the same dashboard
            // reached via navigation serves them fine.
            DispatchQueue.main.async { [weak self] in self?.stage = .dashboard }
        }
        if let path = TestMode.importPath {
            // Deferred past app-launch: importing during init races the XCTest
            // automation handshake, leaving the session half-attached — every
            // later AX query/event then times out. Tests already wait for the
            // Today status line, so the extra beat is invisible to them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.importPDF(from: URL(fileURLWithPath: path))
            }
        }
        // Pull the latest categorization vocabulary from the central categories
        // API (penny1.thescript.design) so this device shares the same, current
        // categories as every other. Best-effort and non-blocking: any failure
        // leaves the previous cache (or the bundled file) in place. The next
        // import picks up a refreshed catalog; no need to gate launch on it.
        Task.detached(priority: .utility) { await CategoryCatalog.refresh() }
    }

    // Hybrid-RAG retriever, cached per selected-document set (rebuilding embeds
    // every row, so we only redo it when the selection actually changes).
    private var retriever: TxnRetriever?
    private var retrieverKey = ""

    /// Per-statement header facts extracted by the model on demand (cardholder,
    /// statement date), keyed by `LoadedDoc.id` — cached so repeat metadata
    /// questions about the same statement don't re-run the model. See
    /// `answerHeaderFactDynamically`.
    private var statementFactsCache: [String: PennyCore.StatementFacts] = [:]

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
                if total > 0, DownloadMeter.bytesOnDisk(repo: id, includeTemps: false) >= Int64(Double(total) * 0.95) {
                    done.insert(id)
                }
            }
            await MainActor.run { [weak self] in self?.downloadedModelIDs = done }
        }
    }

    /// The Today panel is ready once we've extracted at least one transaction.
    var contextReady: Bool { summary.count > 0 }
    var transactionCount: Int { summary.count }

    /// Distinct "Other" debit merchants the AI mop-up could still place. Drives
    /// the sidebar button's count.
    var uncategorizedMerchantCount: Int { CategoryMopup.unresolvedDescriptors(in: graph).count }

    /// Distinct merchants a manual AI pass could still re-verify — unplaced ones
    /// plus rows an earlier AI pass labeled. Keeps the sidebar button available
    /// as a "recheck" even after everything is placed (hidden only when there is
    /// truly nothing an AI pass could change).
    var recheckableMerchantCount: Int {
        CategoryMopup.unresolvedDescriptors(in: graph, scope: .unresolvedOrAIRelabeled).count
    }

    /// Human-readable "data sent out" figure for the brain panel.
    var dataSentLabel: String {
        let b = bytesSentOut
        if b == 0 { return "0 bytes" }
        if b < 1024 { return "\(b) bytes" }
        let kb = Double(b) / 1024
        return kb < 1024 ? String(format: "%.1f KB", kb) : String(format: "%.2f MB", kb / 1024)
    }

    /// Real count of auto-detected recurring charges / subscriptions ("ghosts")
    /// across all imported statements — drives the sidebar's Ghosts badge, so it
    /// reflects the actual data instead of a hardcoded placeholder. Needs ≥3
    /// months of history to detect anything, so it's 0 for a single statement.
    var ghostCount: Int { FinanceRouter.recurringCharges(docs.flatMap(\.rows)).count }

    // MARK: model picker

    func chooseModel(_ id: String) {
        guard id != selectedModelID else { return }
        // Cancel any in-flight load of the previous choice: without this, the old
        // download keeps running invisibly (phase was reset to .idle) and races the
        // new one for the temp dir and the progress meter.
        loadTask?.cancel()
        loadTask = nil
        selectedModelID = id
        modelPhase = .idle
        resetLoadTelemetry()
        llm = PennyLLM(modelID: id)
    }

    /// The in-flight `loadAndContinue` task, so switching models can cancel it.
    private var loadTask: Task<Void, Never>?

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
        if modelPhase == .ready {
            stage = .dashboard
            refineIssuersViaLLM()   // label onboarding imports (FM path needs no MLX load)
            refineCategoriesForLoadedStatements()   // place any restored "Other" rows now the model's up
            return
        }
        guard modelPhase == .idle else { return }
        resetLoadTelemetry()
        totalBytes = Self.catalogBytes(selectedModelID)   // provisional denominator
        DownloadMeter.clearStaleTemps()
        modelPhase = .loading(0)
        loadStatus = "connecting…"
        startProgressTimer()
        loadTask = Task {
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
                refineIssuersViaLLM()   // label statements imported before load
                refineCategoriesForLoadedStatements()   // ...and categorize their "Other" rows
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
        /// The canonical-model slice for this file — the single source of truth.
        /// (Phase 0.8 cleanup: the legacy txns/rows/currency/bank/closingBalance/
        /// isCard fields were removed — the runtime uses only the graph + text.)
        let graph: FinancialGraph
        /// Bytes sent to Anthropic while producing this result (OCR extraction +
        /// category mop-up). 0 on the pure-offline path.
        var bytesSent = 0
    }
    private struct ImportFailure: Error, Sendable { let message: String }

    /// Import a statement (PDF or CSV) WITHOUT freezing the UI: text extraction
    /// and the deterministic `PennyTxnStore` parse both run off the main thread
    /// while the picker shows an "importing" state. Results are applied on the
    /// main actor and persisted via `StatementStore` so they survive relaunch.
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
            async let extraction = Self.extract(url: url, aiKey: claudeAPIKey)
            await Self.minimumLoaderDelay()
            let result = await extraction
            isImporting = false
            importingName = nil
            switch result {
            case .success(let r):
                if r.text.isEmpty {
                    isAnalyzing = false
                    errorMessage = r.name.lowercased().hasSuffix(".csv")
                        ? "\(r.name) is empty — no rows to read."
                        : "No selectable text in \(r.name) (is it a scanned image?)"
                    return
                }
                // Text came through but the parser recognized no transactions — the
                // statement's layout (dates / amounts / running balance) wasn't
                // readable. Surface a real error instead of silently saving an empty
                // statement (which shows up as a "0 transactions" account and misleads).
                if r.graph.transactions.isEmpty {
                    isAnalyzing = false
                    errorMessage = r.name.lowercased().hasSuffix(".csv")
                        ? "Couldn't read any transactions from \(r.name) — check it has date, amount and balance columns."
                        : "Couldn't read any transactions from \(r.name). Penny needs a table of dates, amounts and a running balance — this statement's layout isn't recognized yet."
                    return
                }
                // Persist the canonical model slice (the only source of truth) and
                // merge it into the runtime graph; `docs` re-derives from there.
                let record = StatementStore.StatementRecord(from: r.graph, text: r.text)
                StatementStore.save(record)
                addSlice(r.graph, text: r.text)
                bytesSentOut += r.bytesSent
                if let kind, uploadsByKind[kind]?.contains(r.name) != true {
                    uploadsByKind[kind, default: []].append(r.name)
                }
                isAnalyzing = false
                deriveDocs()
                recomputeSummary()   // deterministic figures → fills the Today panel
                detectIssuerViaLLM(for: r.name, text: r.text)   // refine the account label
                refineCategoriesForLoadedStatements()   // on-device "Other"-row mop-up
            case .failure(let failure):
                isAnalyzing = false
                errorMessage = failure.message
            }
        }
    }

    // MARK: - Progressive multi-statement import (up to 6 months)

    /// Import several statements at once, in month-batches, so results appear as
    /// soon as the first batch is parsed while the rest continue in the background.
    /// After each batch the graph is refreshed (the UI reacts to `@Published graph/
    /// docs/summary`) and a toast is posted. A batch that fails is retried on its
    /// own — the others are unaffected — and if it still fails the run continues.
    func importStatements(from urls: [URL], kind: String? = nil) {
        guard !isImporting, !urls.isEmpty else { return }
        // A lone file keeps the simple single-file path (no batching overhead).
        if urls.count == 1 { importPDF(from: urls[0], kind: kind); return }

        isImporting = true
        isAnalyzing = true
        errorMessage = nil
        let batches = StatementBatchPlanner.plan(fileCount: urls.count)
        analysis = StatementBatchPlanner.progress(stage: .readingPDF, batches: batches, batchesDone: 0)

        Task {
            var done = 0
            var anySucceeded = false
            var failedBatches = 0

            // Reading + extracting are quick, deterministic pre-stages.
            setStage(.extractingTransactions, batches, done)

            for batch in batches {
                setStage(.analyzing(monthRange: batch.monthRange), batches, done)
                importingName = "Months \(batch.monthRange)"

                var toRun = batch.fileIndices.map { urls[$0] }
                var current = batch
                var succeededHere = 0
                while true {
                    let failed = await runBatchFiles(toRun, kind: kind)
                    succeededHere += (toRun.count - failed.count)
                    if failed.isEmpty { break }
                    // Retry ONLY the files that failed, on this batch alone.
                    guard let retry = StatementBatchPlanner.nextAttempt(current) else {
                        failedBatches += 1
                        postToast("Couldn't read \(failed.count) file(s) in months \(batch.monthRange) — skipped. You can re-add them.", kind: .warning)
                        break
                    }
                    current = retry
                    toRun = failed
                    postToast("Retrying months \(batch.monthRange)…", kind: .progress)
                }

                anySucceeded = anySucceeded || succeededHere > 0
                done += 1
                // Refresh the UI with whatever landed in this batch.
                deriveDocs()
                recomputeSummary()
                setStage(.analyzing(monthRange: batch.monthRange), batches, done)

                if done == 1 {
                    postToast("The first \(batch.monthRange.contains("–") ? "2 months" : "month") of data have been processed. The remaining statements are still being analyzed.", kind: .progress)
                } else if done < batches.count {
                    postToast("Months \(batch.monthRange) processed — \(done) of \(batches.count) batches done.", kind: .progress)
                }
            }

            // Insights pass (cross-month figures already recomputed above).
            setStage(.generatingInsights, batches, done)
            recomputeSummary()

            isImporting = false
            isAnalyzing = false
            importingName = nil
            analysis = StatementBatchPlanner.progress(stage: .completed, batches: batches, batchesDone: done)

            if anySucceeded {
                postToast(failedBatches == 0
                    ? "Bank statement analysis completed successfully."
                    : "Analysis completed with \(failedBatches) batch(es) skipped.",
                    kind: failedBatches == 0 ? .success : .warning)
                refineIssuersViaLLM()
                refineCategoriesForLoadedStatements()   // on-device "Other"-row mop-up
            } else {
                errorMessage = "Couldn't read any transactions from the selected statements."
            }
            // Let the completed bar linger briefly, then reset.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if self?.isImporting == false { self?.analysis = .idle }
            }
        }
    }

    private func setStage(_ stage: AnalysisStage, _ batches: [StatementBatch], _ done: Int) {
        analysis = StatementBatchPlanner.progress(stage: stage, batches: batches, batchesDone: done)
    }

    /// Parse + persist + merge each file in a batch concurrently. Returns the
    /// URLs that failed to yield any transactions (for retry).
    private func runBatchFiles(_ urls: [URL], kind: String?) async -> [URL] {
        var failures: [URL] = []
        let aiKey = claudeAPIKey   // capture off the main actor for the detached tasks
        await withTaskGroup(of: (URL, Result<ExtractResult, ImportFailure>).self) { group in
            for url in urls {
                group.addTask { (url, await Self.extract(url: url, aiKey: aiKey)) }
            }
            for await (url, result) in group {
                switch result {
                case .success(let r) where !r.text.isEmpty && !r.graph.transactions.isEmpty:
                    let record = StatementStore.StatementRecord(from: r.graph, text: r.text)
                    StatementStore.save(record)
                    addSlice(r.graph, text: r.text)
                    bytesSentOut += r.bytesSent
                    if let kind, uploadsByKind[kind]?.contains(r.name) != true {
                        uploadsByKind[kind, default: []].append(r.name)
                    }
                default:
                    failures.append(url)
                }
            }
        }
        return failures
    }

    // MARK: - Toasts

    func postToast(_ text: String, kind: ToastMessage.Kind = .progress) {
        let toast = ToastMessage(text: text, kind: kind)
        toasts.append(toast)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_200_000_000)
            self?.toasts.removeAll { $0.id == toast.id }
        }
    }

    func dismissToast(_ id: ToastMessage.ID) { toasts.removeAll { $0.id == id } }

    /// Best-effort: ask the on-device model to name the institution, then refine
    /// the account's display name. Runs when the model is loaded OR its weights are
    /// already on disk (loading them into RAM is fine; we just never trigger a fresh
    /// multi-GB *download* to label a row). The synchronous heuristic
    /// (`LoadedDoc.detectIssuer`) covers the window before that, and
    /// `refineIssuersViaLLM()` backfills once the model becomes ready.
    private func detectIssuerViaLLM(for docName: String, text: String) {
        // Test runs never touch the real model (there is no stub for issuer
        // naming): labels stay deterministic via the synchronous heuristic.
        guard !TestMode.active else { return }
        Task { [weak self] in
            guard let self else { return }
            let loaded = await self.llm.isLoaded
            let onDisk = DownloadMeter.bytesOnDisk(repo: self.selectedModelID) > 0
            // The Apple system model (macOS 26+) needs no weights on disk and never
            // brings up MLX — so it's always eligible to name the issuer.
            guard loaded || onDisk || PennyLLM.systemModelAvailable else {
                print("🏦[issuer] skip \(docName): model not loaded and no weights on disk")
                return
            }
            do {
                let issuer = try await self.llm.detectIssuer(from: text)
                print("🏦[issuer] \(docName) → \(issuer ?? "nil")  (model loaded=\(loaded))")
                if let issuer, let stmt = self.graph.statements.first(where: { $0.sourceName == docName }) {
                    // Don't let an LLM guess overturn a confident deterministic
                    // letterhead match: the model can be misled by another bank's
                    // name in transaction lines (e.g. "utib0000100" / "@sliceaxis"
                    // in a Paytm statement reading as "Axis Bank"). The header
                    // heuristic is higher-precision, so keep it when it fired.
                    guard LoadedDoc.detectIssuer(in: text) == nil else {
                        print("🏦[issuer] \(docName): keep letterhead detection, ignore LLM ‘\(issuer)’")
                        return
                    }
                    // Issuer refinement is a presentation layer, not canonical data:
                    // record it as an override and re-derive the label. It's re-derived
                    // each launch, so it is deliberately NOT persisted (the model stays truth).
                    self.issuerOverrides[stmt.id] = issuer
                    self.deriveDocs()
                }
            } catch {
                print("🏦[issuer] \(docName) ERROR: \(error)")
            }
        }
    }

    /// Once the model is loaded, label any already-imported statement the model
    /// hasn't named yet (e.g. files imported during onboarding, before load).
    func refineIssuersViaLLM() {
        for doc in docs where doc.detectedIssuer == nil {
            detectIssuerViaLLM(for: doc.name, text: doc.text)
        }
    }

    nonisolated private static func minimumLoaderDelay() async {
        try? await Task.sleep(nanoseconds: 650_000_000)   // ~0.65 s floor
    }

    nonisolated private static func extract(url: URL, aiKey: String? = nil) async -> Result<ExtractResult, ImportFailure> {
        let raw = await Task.detached(priority: .userInitiated) { () -> Result<ExtractResult, ImportFailure> in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                // Extracted text is the chat grounding (PDFKit page text for
                // PDFs, the raw file contents for CSVs — already plain text);
                // the deterministic parser produces the transactions/figures.
                // Both read the same scoped file.
                let isCSV = url.pathExtension.lowercased() == "csv"
                let text: String
                let parsed: DeterministicIngest.Result
                if isCSV {
                    let data = try Data(contentsOf: url)
                    text = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1) ?? ""
                    parsed = (try? DeterministicIngest.ingest(csvAt: url, statementText: text))
                        ?? DeterministicIngest.Result()
                } else {
                    let digital = try StatementText.extract(from: url)
                    if !ScannedPDFOCR.looksScanned(text: digital) {
                        text = digital
                        parsed = (try? DeterministicIngest.ingest(pdfAt: url, statementText: text))
                            ?? DeterministicIngest.Result()
                    } else if let aiKey, !aiKey.isEmpty,
                              let slice = await Self.ocrAndExtract(url: url, aiKey: aiKey) {
                        // Scanned / image-only PDF → OCR + LLM extraction fallback.
                        return .success(slice)
                    } else {
                        // No text layer and no AI key (or OCR/extraction empty):
                        // fall through with empty text so the caller shows the
                        // existing "is it a scanned image?" guidance.
                        text = ""
                        parsed = DeterministicIngest.Result()
                    }
                }
                return .success(ExtractResult(name: url.lastPathComponent, text: text,
                                              graph: parsed.graph))
            } catch {
                return .failure(ImportFailure(message: error.localizedDescription))
            }
        }.value

        // The category mop-up runs ON-DEVICE after the import lands (see
        // `refineCategoriesForLoadedStatements`) — nothing leaves the Mac here.
        switch raw {
        case .success(let r):
            PennyLog.shared.log("import",
                "\(r.name) → \(r.graph.transactions.count) transactions\(r.text.isEmpty ? " (no readable text)" : "")")
        case .failure(let f):
            PennyLog.shared.log("import", "ERROR: \(url.lastPathComponent): \(f.message)")
        }
        return raw
    }

    /// The Claude API categorization pass — dynamic taxonomy (the model may coin
    /// new category names beyond the seeds); coined names are tamed by the same
    /// normalizer the local path uses so the taxonomy can't fragment.
    ///
    /// One group per issuing bank, each request carrying that statement's
    /// location context (bank name + currency + country) so region-specific
    /// merchants resolve correctly. Groups are further chunked so a 300-row
    /// import can't blow past `max_tokens` and lose verdicts to truncation —
    /// every descriptor gets a real API verdict.
    ///
    /// Sonnet 5 — the user's explicit model choice for categorization
    /// (verified live 2026-08-04: correctly reads ambiguous merchants like the
    /// Latymers pub that Haiku misfiled). Errors/refusals surface as an empty
    /// result. Returns the total request-body size for "data sent out"
    /// accounting.
    nonisolated private static func aiCategorize(_ groups: [CategoryMopup.DescriptorGroup],
                                                 aiKey: String,
                                                 endpoint: ClaudeCategorizer.Endpoint = .anthropic,
                                                 onBatch: @escaping @Sendable ([String]) -> Void = { _ in })
    async -> (results: [ClaudeCategorization], bytesSent: Int, failed: Int, apiError: String?) {
        // Rich merchant-first output is ~130 tokens/merchant, so batches are modest.
        // A batch that truncates or errors is split and retried once (see
        // categorizeChunk) so a single bad batch never silently drops rows.
        let batchSize = 40
        // Flatten every group into ≤batchSize work items tagged with their bank
        // location, so batches from different banks can run together.
        struct Work: Sendable { let chunk: [String]; let location: String? }
        var work: [Work] = []
        for group in groups {
            var i = 0
            while i < group.descriptors.count {
                work.append(Work(chunk: Array(group.descriptors[i ..< min(i + batchSize, group.descriptors.count)]),
                                 location: group.locationContext))
                i += batchSize
            }
        }
        guard !work.isEmpty else { return ([], 0, 0, nil) }
        let descriptorCount = work.reduce(0) { $0 + $1.chunk.count }
        let destination = endpoint.usesProxyAuth ? "proxy \(endpoint.url.host ?? "?")" : "api.anthropic.com"
        PennyLog.shared.log("categorize",
            "sending \(descriptorCount) descriptors in \(work.count) batch(es) via \(destination)")

        // Run batches CONCURRENTLY, bounded, so a 400-merchant statement is a few
        // batches "deep" in wall-clock instead of a dozen sequential Sonnet calls.
        // Each task uses its own categorizer, so there's no shared mutable state
        // (byte counts don't race).
        let maxConcurrent = min(4, work.count)
        var results: [ClaudeCategorization] = []
        var bytes = 0, failed = 0
        var apiError: String? = nil
        await withTaskGroup(of: (results: [ClaudeCategorization], bytes: Int, failed: Int, error: String?).self) { taskGroup in
            var next = 0
            func submit(_ w: Work) {
                taskGroup.addTask {
                    let categorizer = ClaudeCategorizer(apiKey: aiKey, model: "claude-sonnet-5",
                                                        endpoint: endpoint)
                    let out = await categorizeChunk(categorizer, w.chunk, location: w.location, canSplit: true)
                    onBatch(w.chunk)   // advance the loader by the batch's transactions
                    return out
                }
            }
            while next < maxConcurrent { submit(work[next]); next += 1 }
            for await r in taskGroup {
                results.append(contentsOf: r.results); bytes += r.bytes; failed += r.failed
                if apiError == nil { apiError = r.error }   // first failure reason wins
                // Stop feeding new batches once cancelled (e.g. Wipe); the group
                // cancels any still in flight as it unwinds.
                if Task.isCancelled { break }
                if next < work.count { submit(work[next]); next += 1 }
            }
        }
        PennyLog.shared.log("categorize",
            "→ \(results.count) verdicts, \(failed) failed\(apiError.map { "; error: \($0)" } ?? "")")
        return (results, bytes, failed, apiError)
    }

    /// One rich-categorize call, with a single split-and-retry on failure: a large
    /// batch whose JSON truncates (or errors) is halved and each half retried once,
    /// so a single oversized/failed batch surfaces as a small `failed` count
    /// instead of silently vanishing into the deterministic sweep. Returns the
    /// request bytes so the privacy panel stays honest across splits.
    nonisolated private static func categorizeChunk(_ categorizer: ClaudeCategorizer,
                                                    _ chunk: [String], location: String?,
                                                    canSplit: Bool)
    async -> (results: [ClaudeCategorization], bytes: Int, failed: Int, error: String?) {
        do {
            let rich = try await categorizer.dynamicCategorize(
                descriptions: chunk, locationContext: location)
            return (rich, categorizer.lastRequestByteCount, 0, nil)
        } catch {
            let message = friendlyAPIError(error)
            guard canSplit, chunk.count > 8 else {
                return ([], categorizer.lastRequestByteCount, chunk.count, message)
            }
            let mid = chunk.count / 2
            let a = await categorizeChunk(categorizer, Array(chunk[..<mid]), location: location, canSplit: false)
            let b = await categorizeChunk(categorizer, Array(chunk[mid...]), location: location, canSplit: false)
            return (a.results + b.results, a.bytes + b.bytes, a.failed + b.failed, a.error ?? b.error ?? message)
        }
    }

    /// Turn a categorizer error into a short, actionable sentence for the user.
    /// The most important case: an out-of-credits 400 must say to add credits, NOT
    /// "couldn't reach Claude — tap to retry" (retrying an unpaid account just fails
    /// again). Also names a bad key and rate limits distinctly.
    nonisolated static func friendlyAPIError(_ error: Error) -> String {
        if let e = error as? ClaudeCategorizerError {
            switch e {
            case .http(let status, let body):
                let low = body.lowercased()
                if low.contains("credit balance") || low.contains("billing") {
                    return "Claude API credits exhausted — add credits at console.anthropic.com (Plans & Billing) to categorize the rest."
                }
                if status == 401 || low.contains("authentication") || low.contains("invalid x-api-key") {
                    return "Your Anthropic API key was rejected — re-enter it in settings."
                }
                if status == 429 { return "Anthropic rate limit hit — wait a moment and tap ✨ to retry." }
                return "Anthropic API error \(status) — tap ✨ to retry."
            case .missingKey:  return "No Anthropic API key set — add one in settings."
            case .refused:     return "Claude declined the request."
            case .badResponse: return "Couldn't read Claude's response — tap ✨ to retry."
            }
        }
        return "Couldn't reach Claude — check your connection and tap ✨ to retry."
    }

    /// The category the app DISPLAYS for a rich verdict: the specific secondary
    /// when the model gave a usable one (spec Step 5 — prefer specific), else the
    /// broad primary. Guards against a secondary that's actually a sentence.
    nonisolated static func displayCategory(for c: ClaudeCategorization) -> String {
        if let s = c.secondaryCategory?.trimmingCharacters(in: .whitespaces),
           !s.isEmpty, s.split(separator: " ").count <= 4, s.count <= 32,
           s.caseInsensitiveCompare("Other") != .orderedSame {
            return s
        }
        return c.primaryCategory ?? c.category
    }

    // MARK: - AI re-categorization of already-loaded statements

    /// Run the AI categorization pass over the CURRENT graph, apply the accepted
    /// categories — which may include brand-new, model-coined names — re-persist
    /// the affected statements, and refresh the UI.
    ///
    /// Categories come from the Claude API ONLY (user directive): every
    /// transaction — credits included — is checked with the API; the local LLM
    /// is never used for categorization. Automatic runs (launch restore,
    /// post-import) send every row the API hasn't placed yet — deterministic
    /// labels are only instant placeholders — and the manual button re-checks
    /// every row. Idempotent across launches: AI-placed rows carry a
    /// `.category` signal and are skipped. Key-less, this is a no-op (manual
    /// runs surface why) — rows keep their deterministic placeholders.
    func refineCategoriesForLoadedStatements(manual: Bool = false) {
        guard !isRecategorizing else { return }
        guard let config = categorizerConfig else {
            if manual {
                postToast("Categories come from the Claude API — add your API key in settings first.",
                          kind: .progress)
            }
            return
        }
        let scope: CategoryMopup.Scope = manual ? .allDebits : .withoutAIVerdict
        // Every transaction is covered — credits included — grouped per bank so
        // each request carries that statement's location (bank + currency +
        // country) for region-correct categories.
        let groups = CategoryMopup.descriptorGroups(in: graph, scope: scope,
                                                    includeCredits: true)
        let descriptors = groups.flatMap(\.descriptors)
        guard !descriptors.isEmpty else {
            if manual { postToast("Nothing to categorize — every merchant is already placed.", kind: .success) }
            return
        }

        // Resolve already-known merchants from the knowledge base up front (spec
        // Steps 6 & 8): they skip the API entirely and are guaranteed the SAME
        // category as last time. For the rest, dedupe by NORMALIZED merchant key so
        // a statement with many variant strings for the same merchant only sends
        // ONE representative per merchant — then the verdict is expanded to every
        // row sharing that key. Big statements shrink dramatically here.
        var knownVerdicts: [ClaudeCategorization] = []   // one per raw (already expanded)
        var unknownGroups: [CategoryMopup.DescriptorGroup] = []
        var keyToRaws: [String: [String]] = [:]          // key → every raw sharing it
        var repSeen = Set<String>()                      // keys already given a representative
        for group in groups {
            var reps: [String] = []
            for d in group.descriptors {
                if let p = merchantKB.lookup(d) {
                    knownVerdicts.append(ClaudeCategorization(
                        merchant: d, category: p.displayCategory,
                        confidence: max(p.confidence, 0.9),
                        cleanMerchant: p.merchant, business: p.business,
                        primaryCategory: p.primaryCategory,
                        secondaryCategory: p.secondaryCategory))
                    continue
                }
                let k = MerchantKnowledgeBase.key(for: d)
                keyToRaws[k, default: []].append(d)
                if repSeen.insert(k).inserted { reps.append(d) }   // first raw for this key
            }
            if !reps.isEmpty {
                var g = group; g.descriptors = reps; unknownGroups.append(g)
            }
        }
        let unknownCount = repSeen.count

        // Progress is counted in TRANSACTIONS, not merchants — the user counts "55
        // transactions", so the loader must reach 55 even though we make only one
        // API call per distinct merchant and fan the verdict out to its rows.
        var rawTxnCount: [String: Int] = [:]
        for t in graph.transactions { rawTxnCount[t.rawDescription, default: 0] += 1 }
        let totalTxns = descriptors.reduce(0) { $0 + (rawTxnCount[$1] ?? 0) }
        // Transactions already covered by the KB (resolved instantly, no API call).
        let knownTxns = knownVerdicts.reduce(0) { $0 + (rawTxnCount[$1.merchant] ?? 0) }

        isRecategorizing = true
        categorizeProgress = unknownCount > 0 ? CategorizeProgress(done: knownTxns, total: totalTxns) : nil
        // Each finished merchant batch advances the counter by the number of
        // TRANSACTIONS those merchants cover (via keyToRaws), so it climbs 0→55.
        let onBatch: @Sendable ([String]) -> Void = { [weak self, keyToRaws, rawTxnCount] reps in
            let covered = reps.reduce(0) { sum, rep in
                let raws = keyToRaws[MerchantKnowledgeBase.key(for: rep)] ?? [rep]
                return sum + raws.reduce(0) { $0 + (rawTxnCount[$1] ?? 1) }
            }
            Task { @MainActor in
                guard let self, var p = self.categorizeProgress else { return }
                p.done = min(p.total, p.done + covered)
                self.categorizeProgress = p
            }
        }
        recategorizeTask = Task { [weak self] in
            if manual {
                if unknownCount == 0 {
                    self?.postToast("All \(totalTxns) transaction\(totalTxns == 1 ? "" : "s") categorized from memory — no API call needed.",
                                    kind: .success)
                } else {
                    self?.postToast("Categorizing \(totalTxns) transaction\(totalTxns == 1 ? "" : "s") — asking Claude about \(unknownCount) new merchant\(unknownCount == 1 ? "" : "s")…",
                                    kind: .progress)
                }
            }
            let (fresh, bytes, failed, apiError) = await Self.aiCategorize(
                unknownGroups, aiKey: config.key, endpoint: config.endpoint, onBatch: onBatch)
            guard let self else { return }
            self.isRecategorizing = false
            self.categorizeProgress = nil
            // Wiped or superseded mid-flight — drop the results, touch nothing.
            if Task.isCancelled { return }
            self.bytesSentOut += bytes

            // Learn the new recognitions so future passes (and relaunches) reuse
            // them without another API call, then persist the KB.
            for c in fresh { self.merchantKB.learn(c) }
            self.merchantKB.save(to: Self.merchantKBURL)

            // Build the apply list: KB-known verdicts plus the fresh ones. Each
            // fresh verdict (one representative per merchant) is EXPANDED to every
            // row sharing its key, mapped to the DISPLAY (specific) category so
            // "Bike Rental" / "Cafe" / "Food Delivery" replace the broad bucket.
            var results = knownVerdicts
            for c in fresh {
                let display = Self.displayCategory(for: c)
                let k = MerchantKnowledgeBase.key(for: c.merchant)
                for raw in (keyToRaws[k] ?? [c.merchant]) {
                    results.append(ClaudeCategorization(merchant: raw, category: display,
                                                        confidence: c.confidence))
                }
            }

            // NOTE: no early-return on empty results — the deterministic sweep below
            // guarantees no row is left "Other" even when the model returns nothing
            // usable (e.g. it choked on a batch of cryptic UPI descriptors).
            let before = self.graph
            // Every non-"Other" verdict is applied regardless of confidence: the
            // API commits to a label via structured output, and the user's rule
            // is that every transaction's category comes from the API — a
            // confidence gate here would silently hand rows back to the
            // deterministic sweep. "Other" verdicts still fall through to it.
            let minConf = 0.0
            var refined = CategoryMopup.apply(results, to: before, scope: scope,
                                              minConfidence: minConf,
                                              includeCredits: true)
            refined = CategoryMopup.assignConcreteToResidualOther(refined)   // "no Other" guarantee
            if failed > 0 {
                // Show the REAL reason (e.g. out of credits / bad key), not a
                // generic "couldn't reach" — retrying a billing error just fails.
                let reason = apiError ?? "Couldn't reach Claude for \(failed) merchant\(failed == 1 ? "" : "s") — tap ✨ to retry."
                self.postToast(reason, kind: .progress)
            }
            guard refined != before else {
                if manual && failed == 0 {
                    self.postToast("Every merchant is already categorized.", kind: .success)
                }
                return
            }
            let prev = Dictionary(before.transactions.map { ($0.id, $0.enrichment.categoryID?.raw) },
                                  uniquingKeysWith: { a, _ in a })
            let moved = refined.transactions.filter { prev[$0.id] != $0.enrichment.categoryID?.raw }.count
            self.applyRefinedGraph(refined)
            self.postToast("Updated \(moved) categor\(moved == 1 ? "y" : "ies") with Claude.", kind: .success)
        }
    }

    /// Swap in an AI-refined graph and re-persist every statement so the change
    /// survives relaunch, then rebuild the read caches. Mirrors `deriveDocs`'
    /// per-statement record construction.
    private func applyRefinedGraph(_ refined: FinancialGraph) {
        graph = refined
        let txnsByStatement = Dictionary(grouping: refined.transactions, by: \.statementID)
        let accountsByID = Dictionary(refined.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for stmt in refined.statements {
            guard let account = accountsByID[stmt.accountID] else { continue }
            let record = StatementStore.StatementRecord(
                account: account, statement: stmt,
                transactions: txnsByStatement[stmt.id] ?? [],
                merchants: refined.merchants, categories: refined.categories,
                text: statementText[stmt.id]?.text ?? "",
                importedAt: statementText[stmt.id]?.importedAt ?? Date())
            StatementStore.save(record)
        }
        deriveDocs()
        recomputeSummary()
    }

    /// Scanned-PDF fallback: OCR the pages, LLM-extract transactions, and assemble
    /// a canonical graph slice. Results are LLM-read (not exact) — the confidence
    /// is folded into the statement so the UI can flag "AI-extracted, review".
    nonisolated private static func ocrAndExtract(url: URL, aiKey: String) async -> ExtractResult? {
        let pages = await ScannedPDFOCR.recognizePages(at: url)
        let ocrText = pages.joined(separator: "\n")
        guard !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let extractor = ClaudeStatementExtractor(apiKey: aiKey)
        guard let ai = try? await extractor.extract(pages: pages), !ai.rows.isEmpty else { return nil }
        let out = IngestOutput(rows: ai.rows, bankName: ai.bank,
                               confidence: "ai:\(Int((ai.confidence * 100).rounded()))",
                               detectedCurrency: ai.currency, isCard: false)
        let meta = StatementMetadataParser.parse(text: ocrText)
        let graph = ModelAssembler.assemble(out, sourceName: url.lastPathComponent, metadata: meta).graph
        return ExtractResult(name: url.lastPathComponent, text: ocrText, graph: graph,
                             bytesSent: extractor.lastRequestByteCount)
    }

    func toggleDoc(_ name: String) {
        for id in graph.statements.filter({ $0.sourceName == name }).map(\.id) {
            if selectedStatementIDs.contains(id) { selectedStatementIDs.remove(id) }
            else { selectedStatementIDs.insert(id) }
        }
        recomputeSummary()
    }

    // MARK: analysis (deterministic summary from parsed transactions)

    /// The selected documents (all docs when nothing is explicitly selected).
    private func selectedDocs() -> [LoadedDoc] {
        docs.filter { selectedDocNames.isEmpty || selectedDocNames.contains($0.name) }
    }

    // MARK: - canonical graph runtime (Task 0.7)

    /// Merge one statement's model slice into the authoritative `graph` (dedup
    /// accounts/merchants/categories by id; replace a same-id statement + its
    /// transactions on re-import). The graph is the ONLY mutable financial state.
    private func mergeIntoGraph(_ slice: FinancialGraph) {
        var accounts = Dictionary(graph.accounts.map { ($0.id, $0) }, uniquingKeysWith: { _, n in n })
        slice.accounts.forEach { accounts[$0.id] = $0 }
        var merchants = Dictionary(graph.merchants.map { ($0.id, $0) }, uniquingKeysWith: { _, n in n })
        slice.merchants.forEach { merchants[$0.id] = $0 }
        var categories = Dictionary(graph.categories.map { ($0.id, $0) }, uniquingKeysWith: { _, n in n })
        slice.categories.forEach { categories[$0.id] = $0 }
        let replaced = Set(slice.statements.map(\.id))
        var statements = graph.statements.filter { !replaced.contains($0.id) }
        statements.append(contentsOf: slice.statements)
        var transactions = graph.transactions.filter { !replaced.contains($0.statementID) }
        transactions.append(contentsOf: slice.transactions)
        graph = FinancialGraph(accounts: Array(accounts.values), statements: statements,
                               transactions: transactions,
                               merchants: Array(merchants.values), categories: Array(categories.values))
    }

    /// Add a slice + its provenance (text/import time) and select it. No derivation
    /// (callers batch, then call `deriveDocs()` once).
    private func addSlice(_ slice: FinancialGraph, text: String, importedAt: Date? = nil) {
        guard let stmt = slice.statements.first else { return }
        mergeIntoGraph(slice)
        statementText[stmt.id] = (text, importedAt ?? statementText[stmt.id]?.importedAt ?? Date())
        selectedStatementIDs.insert(stmt.id)
    }

    /// Rebuild the read-only `docs` cache from the graph + provenance + issuer
    /// overrides, in import order. `docs` is never mutated any other way.
    private func deriveDocs() {
        let txnsByStatement = Dictionary(grouping: graph.transactions, by: \.statementID)
        let accountsByID = Dictionary(graph.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        docs = graph.statements
            .sorted { l, r in
                let lt = statementText[l.id]?.importedAt ?? .distantPast
                let rt = statementText[r.id]?.importedAt ?? .distantPast
                return lt == rt ? l.sourceName < r.sourceName : lt < rt
            }
            .compactMap { stmt -> LoadedDoc? in
                guard let account = accountsByID[stmt.accountID] else { return nil }
                let record = StatementStore.StatementRecord(
                    account: account, statement: stmt,
                    transactions: txnsByStatement[stmt.id] ?? [],
                    merchants: graph.merchants, categories: graph.categories,
                    text: statementText[stmt.id]?.text ?? "",
                    importedAt: statementText[stmt.id]?.importedAt ?? Date())
                var doc = StatementStore.reconstruct(record)   // graph → LoadedDoc (incl. TxnRow projection)
                doc.statementID = stmt.id
                doc.detectedIssuer = issuerOverrides[stmt.id]
                return doc
            }
    }

    /// Test seam: build the graph from hand-made `LoadedDoc`s (never sets `docs`
    /// directly, honouring "graph is the only mutable state"). Rows come from the
    /// doc's `rows`, or are derived from its `transactions` when absent.
    func loadForTesting(_ inputDocs: [LoadedDoc]) {
        graph = .empty; statementText = [:]; issuerOverrides = [:]; selectedStatementIDs = []
        let base = Date(timeIntervalSince1970: 0)
        for (i, doc) in inputDocs.enumerated() {
            let rows = doc.rows.isEmpty
                ? doc.transactions.enumerated().map { Self.txnRow(from: $1, seq: $0, currency: doc.currency) }
                : doc.rows
            // Fall back to the doc name as institution so distinctly-named test
            // docs get distinct account/statement identities (no accidental merge).
            let out = IngestOutput(rows: rows, bankName: doc.bank ?? doc.name, confidence: "test",
                                   detectedCurrency: doc.currency, closingBalance: doc.closingBalance, isCard: doc.isCard)
            let slice = ModelAssembler.assemble(out, sourceName: doc.name).graph
            addSlice(slice, text: doc.text, importedAt: base.addingTimeInterval(Double(i)))
            if let issuer = doc.detectedIssuer, let stmt = slice.statements.first {
                issuerOverrides[stmt.id] = issuer
            }
        }
        deriveDocs()
        recomputeSummary()
    }

    /// Legacy `PennyCore.Transaction` → `TxnRow` (for test docs built with `txns` only).
    static func txnRow(from t: PennyCore.Transaction, seq: Int, currency: String) -> TxnRow {
        let p = t.date.split(separator: "-").compactMap { Int($0) }
        let (y, mo, d) = p.count == 3 ? (p[0], p[1], p[2]) : (2024, 1, 1)
        return TxnRow(txnDate: t.date, month: String(t.date.prefix(7)), year: y, monthNo: mo, day: d,
                      descr: t.description, merchant: "", category: t.category ?? "",
                      debit: t.debit ?? 0, credit: t.credit ?? 0, balance: t.balance,
                      currency: currency, seq: seq)
    }

    /// Sum the selected documents' transactions in Swift — deterministic, no model.
    func recomputeSummary() {
        let chosen = selectedDocs()
        let txns = chosen.flatMap(\.transactions)
        var s = Summary()
        s.currency = detectCurrency()
        s.count = txns.count
        s.spent = txns.compactMap(\.debit).reduce(0, +)
        // Card repayments (category "Payments") are your own money moving, not
        // income — never count them as earnings.
        s.income = txns.filter { $0.category != "Payments" }.compactMap(\.credit).reduce(0, +)
        s.net = s.income - s.spent
        // Total balance across accounts: each account's latest balance summed,
        // with credit-card balances SUBTRACTED (they're money owed).
        let withBal = chosen.filter { $0.latestBalance != nil }
        if withBal.isEmpty {
            s.balance = nil
        } else {
            s.balance = withBal.reduce(0) { acc, d in
                acc + (d.isCard ? -d.latestBalance! : d.latestBalance!)
            }
        }
        s.categories = categorize(txns)
        // Per-currency breakdown: the same sums grouped by each statement's
        // own currency, so multi-currency imports never show (or hand the
        // model) one meaningless mixed figure.
        var per: [String: CurrencyTotals] = [:]
        for d in chosen {
            let cur = Self.effectiveCurrency(of: d)
            var t = per[cur] ?? CurrencyTotals()
            t.count += d.transactions.count
            t.spent += d.transactions.compactMap(\.debit).reduce(0, +)
            t.income += d.transactions.filter { $0.category != "Payments" }
                .compactMap(\.credit).reduce(0, +)
            t.net = t.income - t.spent
            if let b = d.latestBalance {
                t.balance = (t.balance ?? 0) + (d.isCard ? -b : b)
            }
            per[cur] = t
        }
        s.perCurrency = per
        summary = s
    }

    /// The currency a single statement is denominated in — the per-doc
    /// analogue of `detectCurrency()` (parser's non-INR verdict first, then a
    /// symbol/code sniff of the doc's own text, then the parser value). Groups
    /// the per-currency breakdown.
    static func effectiveCurrency(of doc: LoadedDoc) -> String {
        if doc.currency != "INR", !doc.currency.isEmpty { return doc.currency }
        let text = doc.text
        if text.contains("₹") || text.range(of: "INR", options: .caseInsensitive) != nil { return "INR" }
        if text.contains("£") || text.range(of: "GBP", options: .caseInsensitive) != nil { return "GBP" }
        if text.contains("€") || text.range(of: "EUR", options: .caseInsensitive) != nil { return "EUR" }
        if text.contains("$") || text.range(of: "USD", options: .caseInsensitive) != nil { return "USD" }
        return doc.currency
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

    /// The canonical graph narrowed to the selected statements — the input to the
    /// Query Engine, scoped exactly like `selectedRows()` (empty selection ⇒ all).
    private func selectedGraph() -> FinancialGraph {
        let ids: Set<StatementID> = selectedStatementIDs.isEmpty
            ? Set(graph.statements.map(\.id)) : selectedStatementIDs
        return FinancialGraph(
            accounts: graph.accounts,
            statements: graph.statements.filter { ids.contains($0.id) },
            transactions: graph.transactions.filter { ids.contains($0.statementID) },
            merchants: graph.merchants,
            categories: graph.categories)
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

    /// A comparable `YYYYMMDD` key from an ISO-ish date string ("2026-03-05",
    /// "2026/3/5"), or nil when it isn't a Y-M-D date. Numeric (not lexical) so
    /// non-zero-padded components still order correctly.
    static func isoDateKey(_ s: String) -> Int? {
        let parts = s.split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        return y * 10_000 + m * 100 + d
    }

    // Month vocabulary for the natural-language date parser (mirrors the finance
    // router's table so phrasing behaves identically on the ledger path).
    private static let tableMonthNames: [(String, Int)] = [
        ("january", 1), ("jan", 1), ("february", 2), ("feb", 2), ("march", 3), ("mar", 3),
        ("april", 4), ("apr", 4), ("may", 5), ("june", 6), ("jun", 6), ("july", 7), ("jul", 7),
        ("august", 8), ("aug", 8), ("september", 9), ("sep", 9), ("sept", 9), ("october", 10),
        ("oct", 10), ("november", 11), ("nov", 11), ("december", 12), ("dec", 12)]
    private static let tableMonthFull = ["", "January", "February", "March", "April", "May",
        "June", "July", "August", "September", "October", "November", "December"]
    private static func monthTitle(_ m: Int) -> String {
        (1...12).contains(m) ? tableMonthFull[m] : "\(m)"
    }

    /// True when `pattern` matches anywhere in `s` (regex convenience).
    private static func rx(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }
    /// The first capture group of `pattern` in `s`, or nil.
    private static func rxGroup(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
    /// Add `n` days to an ISO "YYYY-MM-DD" date, returning ISO. Fixed UTC
    /// gregorian calendar so there's no timezone drift across the arithmetic.
    private static func addDaysISO(_ iso: String, _ n: Int) -> String {
        let parts = iso.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return iso }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        var comps = DateComponents(); comps.year = y; comps.month = m; comps.day = d
        guard let base = cal.date(from: comps),
              let moved = cal.date(byAdding: .day, value: n, to: base) else { return iso }
        let e = cal.dateComponents([.year, .month, .day], from: moved)
        return String(format: "%04d-%02d-%02d", e.year ?? y, e.month ?? m, e.day ?? d)
    }

    /// The inclusive date window a table request names, as `YYYYMMDD` keys plus a
    /// header label. Handles both explicit dates and natural language, all anchored
    /// to the loaded statement data (there's no wall-clock "now" for a statement):
    ///   • two ISO dates      — "from 2026-03-05 to 2026-04-05", "between … and …"
    ///   • a named month      — "in March", "March 2026", "for February"
    ///   • this/last month    — the latest / second-latest month in the data
    ///   • this/last year, a bare year — "this year", "in 2025", "2026"
    ///   • rolling windows    — "last 7 days", "first 10 days", "last/this/first week"
    /// Returns nil when no date language is present, so a plain "show all
    /// transactions" still lists the whole ledger.
    private func tableDateRange(_ q: String, txns: [PennyCore.Transaction])
            -> (startKey: Int, endKey: Int, label: String)? {
        let low = q.lowercased()

        // ---- two explicit ISO dates (highest precedence) -------------------
        // `0*` tolerates fat-fingered leading zeros ("2026-03-010" → the 10th) so a
        // typo'd day doesn't silently drop the whole range.
        if let re = try? NSRegularExpression(pattern: #"\b(\d{4})[-/]0*(\d{1,2})[-/]0*(\d{1,2})\b"#) {
            let ns = q as NSString
            let ms = re.matches(in: q, range: NSRange(location: 0, length: ns.length))
            if ms.count >= 2 {
                func parts(_ m: NSTextCheckingResult) -> (key: Int, text: String) {
                    let y = Int(ns.substring(with: m.range(at: 1)))!
                    let mo = Int(ns.substring(with: m.range(at: 2)))!
                    let d = Int(ns.substring(with: m.range(at: 3)))!
                    return (y * 10_000 + mo * 100 + d, String(format: "%04d-%02d-%02d", y, mo, d))
                }
                let a = parts(ms[0]), b = parts(ms[1])
                let (lo, hi) = a.key <= b.key ? (a, b) : (b, a)
                return (lo.key, hi.key, " from \(lo.text) to \(hi.text)")
            }
        }

        // Anchors from the loaded data.
        let keys = txns.compactMap { Self.isoDateKey($0.date) }.sorted()
        guard let minKey = keys.first, let maxKey = keys.last else { return nil }
        func iso(_ k: Int) -> String { String(format: "%04d-%02d-%02d", k / 10_000, (k / 100) % 100, k % 100) }
        func key(_ s: String) -> Int { Self.isoDateKey(s) ?? 0 }
        func month(_ y: Int, _ m: Int) -> (Int, Int) { (y * 10_000 + m * 100 + 1, y * 10_000 + m * 100 + 31) }
        func year(_ y: Int) -> (Int, Int) { (y * 10_000 + 101, y * 10_000 + 1231) }
        // Distinct year*100+month present in the data, ascending.
        let ym = Array(Set(keys.map { ($0 / 10_000) * 100 + ($0 / 100) % 100 })).sorted()
        let maxYear = keys.map { $0 / 10_000 }.max()!
        // A standalone year ("in 2026"), NOT the year inside a date token like
        // "2026-03-05" — otherwise a partially-unparseable date range would fall
        // through and be misread as a whole-year window.
        let explicitYear = Self.rxGroup(low, #"(?<![-/\d])((?:19|20)\d\d)(?![-/]\d)"#).flatMap(Int.init)

        // ---- rolling day windows -------------------------------------------
        if let g = Self.rxGroup(low, #"(?:last|past|previous)\s+(\d{1,3})\s+days?"#),
           let n = Int(g), n > 0 {
            return (key(Self.addDaysISO(iso(maxKey), -(n - 1))), maxKey, " in the last \(n) days")
        }
        if let g = Self.rxGroup(low, #"first\s+(\d{1,3})\s+days?"#), let n = Int(g), n > 0 {
            return (minKey, key(Self.addDaysISO(iso(minKey), n - 1)), " in the first \(n) days")
        }
        // ---- week windows (7 days off the data's edges) --------------------
        if Self.rx(low, #"\b(?:last|past|previous|this|current)\s+week\b"#) {
            return (key(Self.addDaysISO(iso(maxKey), -6)), maxKey, " in the last week")
        }
        if Self.rx(low, #"\bfirst\s+week\b"#) {
            return (minKey, key(Self.addDaysISO(iso(minKey), 6)), " in the first week")
        }

        // ---- this / last month (anchored to the data's months) -------------
        if Self.rx(low, #"\b(?:this|current)\s+month\b"#), let last = ym.last {
            let (y, m) = (last / 100, last % 100); let w = month(y, m)
            return (w.0, w.1, " this month (\(Self.monthTitle(m)) \(y))")
        }
        if Self.rx(low, #"\b(?:last|previous)\s+month\b"#), !ym.isEmpty {
            let t = ym.count >= 2 ? ym[ym.count - 2] : ym[ym.count - 1]
            let (y, m) = (t / 100, t % 100); let w = month(y, m)
            return (w.0, w.1, " last month (\(Self.monthTitle(m)) \(y))")
        }

        // ---- a named month ("in March", "March 2026") ----------------------
        for (name, no) in Self.tableMonthNames where Self.rx(low, #"\b"# + name + #"\b"#) {
            // "may" is also a modal verb — only treat it as the month with clear context.
            if name == "may",
               !Self.rx(low, #"\b(?:in|during|for|of|through|this|last|next)\s+may\b|\bmay\s+(?:20\d\d|month)\b"#) {
                continue
            }
            let y = explicitYear ?? keys.filter { ($0 / 100) % 100 == no }.map { $0 / 10_000 }.max() ?? maxYear
            let w = month(y, no)
            return (w.0, w.1, " in \(Self.monthTitle(no)) \(y)")
        }

        // ---- this / last year, then a bare year ----------------------------
        if Self.rx(low, #"\b(?:this|current)\s+year\b"#) { let w = year(maxYear); return (w.0, w.1, " in \(maxYear)") }
        if Self.rx(low, #"\b(?:last|previous)\s+year\b"#) { let w = year(maxYear - 1); return (w.0, w.1, " in \(maxYear - 1)") }
        if let y = explicitYear { let w = year(y); return (w.0, w.1, " in \(y)") }

        return nil
    }

    /// Build a Markdown table from the extracted transactions. `limit` caps the
    /// rows rendered (nil = every row); the caller passes nil when the user asks
    /// for "all"/"full"/"every" so the whole ledger is shown.
    static func transactionsMarkdown(_ txns: [PennyCore.Transaction], currency: String,
                                     limit: Int? = 200) -> String {
        let cap = limit ?? txns.count
        let shown = Array(txns.prefix(cap))
        var lines = [
            "| # | Date | Description | Category | Debit | Credit | Balance |",
            "|---|------|-------------|----------|-------|--------|---------|",
        ]
        for (i, t) in shown.enumerated() {
            let debit = t.debit.map { Money.format($0, currency: currency) } ?? ""
            let credit = t.credit.map { Money.format($0, currency: currency) } ?? ""
            let balance = t.balance.map { Money.format($0, currency: currency) } ?? ""
            var desc = t.description.replacingOccurrences(of: "|", with: "/")
            if desc.count > 40 { desc = String(desc.prefix(39)) + "…" }
            let category = (t.category ?? "").replacingOccurrences(of: "|", with: "/")
            lines.append("| \(i + 1) | \(t.date) | \(desc) | \(category) | \(debit) | \(credit) | \(balance) |")
        }
        var out = lines.joined(separator: "\n")
        if txns.count > cap {
            out += "\n\n_Showing first \(cap) of \(txns.count). Ask “show all transactions” to see every row._"
        }
        return out
    }

    /// The specific imported statement a question names — by its issuer
    /// (displayName), parsed bank name, or filename — or nil when no single
    /// statement is clearly named (a general question). Generic words like
    /// "bank"/"current"/"statement" never select a document.
    func namedDoc(for question: String) -> LoadedDoc? {
        let low = question.lowercased()
        let stop: Set<String> = ["bank", "banking", "statement", "statements", "account",
                                 "accounts", "current", "credit", "debit", "card", "cards",
                                 "the", "for", "this", "that", "sample"]
        var best: (len: Int, doc: LoadedDoc)?
        for doc in selectedDocs() {
            // Candidate identifiers: issuer/bank/filename (extension dropped).
            let ids = [doc.displayName, doc.bank ?? "",
                       (doc.name as NSString).deletingPathExtension]
            let tokens = ids.flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter }) }
                .map(String.init)
                .filter { $0.count >= 4 && !stop.contains($0) }
            // Letter-boundary match (not `\b`, which counts "_" as a word char, so
            // a filename token like "revolut" in "revolut_dummy" would be missed).
            for t in tokens where low.range(
                of: "(?<![a-z])\(NSRegularExpression.escapedPattern(for: t))(?![a-z])",
                options: .regularExpression) != nil {
                if best == nil || t.count > best!.len { best = (t.count, doc) }
            }
        }
        return best?.doc
    }

    /// When the question names a specific imported statement, return that
    /// statement's header text as labelled grounding, so header-only metadata
    /// questions (the statement period, sort code, account number, payment-due
    /// date, address) are answerable even though the RAG index only holds
    /// transaction rows. Nil when no single statement is clearly named.
    func namedDocHeader(for question: String) -> String? {
        guard let doc = namedDoc(for: question) else { return nil }
        let header = String(doc.text.prefix(3_500))
        return "HEADER OF THE \"\(doc.displayName)\" STATEMENT (use this for statement-level "
             + "details like the statement period, account/sort-code, or due date):\n\(header)"
    }

    /// Deterministic per-document metadata answered straight from the named (or,
    /// when only one is imported, the sole) statement's text — currently the
    /// opening / starting balance, which Barclays-style statements declare in a
    /// header summary and never as a per-row running balance. Returns nil when
    /// the question isn't a metadata lookup, no single statement is identified,
    /// or the figure isn't in the text (so the caller can fall through to the
    /// header-grounded model instead of a wrong deterministic guess).
    // Intent regexes shared by the deterministic answer (`documentMetadataAnswer`)
    // and the dynamic LLM fallback (`dynamicHeaderFactRequest`), so both agree on
    // exactly which questions are header-metadata questions.
    static let statementDateIntent =
        #"statement\s+date|date\s+of\s+(?:the\s+)?statement|statement\s+issued|issue\s+date|when\s+(?:was|is)\s+(?:this|the)\s+statement\s+(?:issued|dated|from)|what\s+date\s+is\s+(?:this|the)\s+statement"#
    static let cardholderIntent =
        #"prepared\s+for|card\s?holder|account\s+holder|whose\s+(?:statement|account|card)|who(?:'?s| is| does).{0,40}(?:statement|account|card|belong|name)|name\s+on\s+(?:the\s+)?(?:statement|account|card)"#

    /// Display form of a header name: title-case an ALL-CAPS name ("PIYUSH MISHRA"
    /// → "Piyush Mishra"); leave an already-mixed-case one ("R Tester") untouched.
    static func displayName(forHolder name: String) -> String {
        name == name.uppercased() ? name.capitalized : name
    }

    /// The header field a question asks for that the deterministic parser can supply
    /// dynamically via the model, paired with the statement it refers to — or nil
    /// when the question isn't one of these, or no single statement is identified.
    /// Callers reach this ONLY after `documentMetadataAnswer` returned nil, i.e. the
    /// label parser couldn't find the field, so the model generalizes to any layout.
    enum HeaderFact { case statementDate, cardholder }
    func dynamicHeaderFactRequest(_ question: String) -> (field: HeaderFact, doc: LoadedDoc)? {
        let low = question.lowercased()
        guard let doc = namedDoc(for: question)
                ?? (selectedDocs().count == 1 ? selectedDocs().first : nil) else { return nil }
        if low.range(of: Self.statementDateIntent, options: .regularExpression) != nil,
           low.range(of: #"period|date\s+range"#, options: .regularExpression) == nil {
            return (.statementDate, doc)
        }
        if low.range(of: Self.cardholderIntent, options: .regularExpression) != nil {
            return (.cardholder, doc)
        }
        return nil
    }

    /// Read a header fact off the statement with the on-device model (Apple system
    /// model → MLX), validate it, and post the answer — the dynamic path that works
    /// for any layout the deterministic label parser doesn't recognise. Extraction
    /// is cached per statement so repeat questions don't re-run the model. Posts a
    /// graceful "couldn't find it" note when the model can't read the field either.
    func answerHeaderFactDynamically(_ question: String, field: HeaderFact, doc: LoadedDoc) {
        messages.append(ChatMessage(role: .assistant, content: "", engine: "ANALYTICS"))
        let idx = messages.count - 1
        isThinking = true

        // UI-test stub: no model in tests — emit a deterministic marker so the
        // routing is exercisable without loading weights.
        if TestMode.modelReady {
            messages[idx].content = "\(TestMode.stubReplyPrefix) · header-fact · \(question)"
            isThinking = false
            return
        }

        let cached = statementFactsCache[doc.id]
        generateTask = Task {
            let facts: PennyCore.StatementFacts
            if let cached {
                facts = cached
            } else {
                do { facts = try await llm.extractStatementFacts(from: doc.text) }
                catch is CancellationError { await MainActor.run { self.isThinking = false }; return }
                catch {
                    await MainActor.run {
                        guard self.messages.indices.contains(idx) else { return }
                        self.messages[idx].content =
                            "Sorry — I couldn't read that off the \(doc.displayName) statement."
                        self.isThinking = false
                    }
                    return
                }
            }
            await MainActor.run {
                self.statementFactsCache[doc.id] = facts
                guard self.messages.indices.contains(idx) else { return }
                let answer = Self.headerFactAnswer(field, facts: facts, doc: doc)
                self.messages[idx].content = answer
                    ?? "I couldn't find the \(field == .statementDate ? "statement date" : "cardholder name") on the \(doc.displayName) statement."
                PennyLog.shared.log("chat", "A (analytics·dynamic): \(self.messages[idx].content)")
                self.isThinking = false
            }
        }
    }

    /// Format a validated header fact into the answer, or nil when the model's value
    /// is missing/unusable (a date that doesn't parse, an empty name) — so a bad
    /// extraction becomes an honest "couldn't find it", never a wrong answer.
    static func headerFactAnswer(_ field: HeaderFact, facts: PennyCore.StatementFacts,
                                 doc: LoadedDoc) -> String? {
        switch field {
        case .statementDate:
            guard let raw = facts.statementDate,
                  let date = StatementMetadataParser.parseDate(raw) else { return nil }
            return "**\(doc.displayName) statement date: \(formatCalendarDate(date)).**"
        case .cardholder:
            guard let raw = facts.cardholder else { return nil }
            let name = raw.trimmingCharacters(in: .whitespaces)
            // Guard against a junk extraction: a real name is letters/spaces, 2+ words
            // or a distinctive single token, and not absurdly long.
            guard name.count >= 3, name.count <= 40,
                  name.range(of: #"^[\p{L}][\p{L}.'\- ]+$"#, options: .regularExpression) != nil
            else { return nil }
            return "**The \(doc.displayName) statement is prepared for \(displayName(forHolder: name)).**"
        }
    }

    func documentMetadataAnswer(_ question: String) -> String? {
        let low = question.lowercased()

        // Statement period — read the header date range deterministically instead of
        // letting the LLM guess (it answers "not stated" when the period line isn't in
        // its RAG window). Answered only when the statement actually declares one.
        if low.range(of: #"statement\s+period|billing\s+period|reporting\s+period|(?:what|which)\s+period|period\s+covered|period\s+does\s+(?:this|it)\s+cover|date\s+range|what\s+dates?\b"#,
                     options: .regularExpression) != nil,
           let doc = namedDoc(for: question) ?? (selectedDocs().count == 1 ? selectedDocs().first : nil),
           let period = StatementMetadataParser.statementPeriod(in: doc.text) {
            return "**\(doc.displayName) statement period: \(Self.formatCalendarDate(period.start)) – \(Self.formatCalendarDate(period.end)).**"
        }

        // Statement date — read from the header (Amex prints it as the "…received by"
        // closing date / the DD/MM/YY value row, with no "Statement date:" label), so
        // the LLM can't misread it (it answered "2026-03-14" for a 15 March statement).
        // Guarded against "period"/"date range" queries, which the block above owns.
        if low.range(of: Self.statementDateIntent, options: .regularExpression) != nil,
           low.range(of: #"period|date\s+range"#, options: .regularExpression) == nil,
           let doc = namedDoc(for: question) ?? (selectedDocs().count == 1 ? selectedDocs().first : nil),
           let date = StatementMetadataParser.statementDate(in: doc.text) {
            return "**\(doc.displayName) statement date: \(Self.formatCalendarDate(date)).**"
        }

        // Cardholder / "prepared for" — the name printed in the header, read straight
        // from the statement (the LLM generic-ified it to "you"). nil when no name is
        // confidently present, so non-Amex layouts fall through to the model unchanged.
        if low.range(of: Self.cardholderIntent, options: .regularExpression) != nil,
           let doc = namedDoc(for: question) ?? (selectedDocs().count == 1 ? selectedDocs().first : nil),
           let name = StatementMetadataParser.holder(in: doc.text) {
            return "**The \(doc.displayName) statement is prepared for \(Self.displayName(forHolder: name)).**"
        }

        // Each field: an intent regex (does the question ask for it?) paired with the
        // statement-text labels that precede its figure, and how to phrase the answer.
        // Order matters — "available credit" is checked before the plainer "credit
        // limit" so "available credit limit" resolves to the remaining figure.
        let fields: [(intent: String, labels: [String], noun: String)] = [
            (#"\b(opening|starting|start|initial|beginning)\s+balance\b|balance\s+(?:brought|carried)\s+forward"#,
             [#"opening\s+balance"#, #"start(?:ing)?\s+balance"#, #"initial\s+balance"#,
              #"beginning\s+balance"#, #"balance\s+brought\s+forward"#, #"brought\s+forward"#,
              #"balance\s+b/?f(?:wd)?"#, #"previous\s+balance"#, #"balance\s+from\s+previous\s+statement"#],
             "opening balance"),
            (#"available\s+credit|credit\s+available|available\s+to\s+spend"#,
             [#"available\s+credit(?:\s+limit)?"#, #"credit\s+available"#, #"available\s+to\s+spend"#],
             "available credit"),
            (#"credit\s+limit|credit\s+line|\blimit\b"#,
             [#"total\s+credit\s+limit"#, #"credit\s+limit"#, #"credit\s+line"#, #"\blimit\b"#],
             "credit limit"),
        ]

        guard let field = fields.first(where: {
            low.range(of: $0.intent, options: .regularExpression) != nil
        }) else { return nil }
        guard let doc = namedDoc(for: question)
                ?? (selectedDocs().count == 1 ? selectedDocs().first : nil) else { return nil }

        // Credit-card "Credit Summary" blocks lay the limit and available credit out
        // as two aligned columns (labels on one line, the two amounts on the next),
        // so a plain label→next-amount read grabs the wrong column. Resolve those
        // from the columnar parse first; fall back to the generic label reader.
        let cur = Self.effectiveCurrency(of: doc)
        func reply(_ amount: Double) -> String {
            "**\(doc.displayName) \(field.noun): \(Money.format(amount, currency: cur)).**"
        }
        let summary = Self.creditSummary(in: doc.text)
        if field.noun == "available credit", let a = summary.available { return reply(a) }
        if field.noun == "credit limit", let l = summary.limit { return reply(l) }

        guard let amount = Self.moneyAfterLabel(in: doc.text, labels: field.labels) else { return nil }
        return reply(amount)
    }

    /// Parse a credit-card "Credit Summary" two-column block —
    ///   `Credit Limit £ Available Credit Limit £`
    ///   `16,100.00 15,470.46`
    /// — into (limit, available). Column order is fixed by the header (limit first,
    /// available second). Returns nils when the block isn't present.
    // Task 0.5: the extraction logic now lives in `StatementMetadataParser`
    // (PennyTxnStore). These remain as thin, behaviour-preserving delegations so
    // the chat metadata answers are unchanged; they're removed in Phase 1.
    static func creditSummary(in text: String) -> (limit: Double?, available: Double?) {
        let s = StatementMetadataParser.creditSummary(in: text)
        return (limit: s.limit.map(Self.double), available: s.available.map(Self.double))
    }

    /// "16 February 2026" — the human form used in statement-period answers.
    static func formatCalendarDate(_ d: CalendarDate) -> String {
        let months = ["January", "February", "March", "April", "May", "June",
                      "July", "August", "September", "October", "November", "December"]
        let name = (1...12).contains(d.month) ? months[d.month - 1] : String(d.month)
        return "\(d.day) \(name) \(d.year)"
    }

    /// Decimal → Double for the legacy Double-based metadata shims. Goes through
    /// the decimal string (exactly as the former inline code did: `Double(digits)`),
    /// so the produced `Double` — and thus every formatted figure — is byte-identical
    /// to the pre-delegation behaviour.
    private static func double(_ d: Decimal) -> Double {
        Double(d.description) ?? NSDecimalNumber(decimal: d).doubleValue
    }

    /// Cross-document content questions: "which statements contain salary
    /// transactions?", "which accounts have groceries?". Answered per-document
    /// from each statement's parsed rows (which only the app holds — the finance
    /// router sees a merged, doc-blind row set), so it must run before that router
    /// (whose income/category handlers would otherwise collapse it to one figure).
    /// Nil when the question isn't a "which statements contain X" lookup.
    func documentContentAnswer(_ question: String) -> String? {
        let low = question.lowercased()
        guard low.range(of: #"\b(which|what|list|name)\b"#, options: .regularExpression) != nil,
              low.range(of: #"\b(statements?|accounts?)\b"#, options: .regularExpression) != nil,
              low.range(of: #"\b(contain\w*|have|has|having|include\w*|with|show\w*)\b"#,
                        options: .regularExpression) != nil else { return nil }

        let all = selectedDocs()
        guard !all.isEmpty else { return nil }

        // Salary / payroll / income — a payroll credit, identified semantically
        // (not by the literal word "salary", which most statements don't use).
        if low.range(of: #"\b(salary|salaries|payroll|wages?|income|paycheck\w*|paycheque\w*|earnings?)\b"#,
                     options: .regularExpression) != nil {
            let hits = all.filter { Self.hasSalary($0.rows) }
            return Self.docListAnswer(hits, subject: "a salary (payroll) transaction",
                                      plural: "salary transactions")
        }

        // Otherwise a category / merchant / keyword term ("groceries", "Tesco").
        guard let term = Self.contentTerm(low) else { return nil }
        let hits = all.filter { doc in
            doc.rows.contains { r in
                "\(r.descr) \(r.merchant) \(r.category)".lowercased().contains(term)
            }
        }
        return Self.docListAnswer(hits, subject: "\(term) transactions", plural: "\(term) transactions")
    }

    /// Cross-document analytics that the doc-blind finance router can't answer:
    /// per-statement counts, which statement has the highest/lowest balance or
    /// most money in/out or most transactions, the largest credit/debit across
    /// ALL statements (with its statement named), the top spending category, which
    /// statement received the highest salary, salary count/total, and high-value
    /// filters. Every figure is summed from the parsed rows. Runs before the
    /// finance router (which would otherwise answer per-merged-ledger). Nil when
    /// the question isn't one of these cross-document lookups.
    func crossDocumentAnswer(_ question: String) -> String? {
        let low = question.lowercased()
        let docs = selectedDocs()
        guard !docs.isEmpty else { return nil }
        let cur = summary.currency
        func money(_ v: Double) -> String { Money.format(v, currency: cur) }
        func closing(_ d: LoadedDoc) -> Double? { d.closingBalance ?? d.latestBalance }
        func moneyIn(_ d: LoadedDoc) -> Double { d.rows.filter { $0.credit > 0 }.reduce(0) { $0 + $1.credit } }
        func moneyOut(_ d: LoadedDoc) -> Double { d.rows.filter { $0.debit > 0 }.reduce(0) { $0 + $1.debit } }
        func has(_ pat: String) -> Bool { low.range(of: pat, options: .regularExpression) != nil }

        // ---- how many statements / accounts / files ------------------------
        if has(#"\bhow many\b|\bnumber of\b|\bhow much\b"#), has(#"\b(statements?|accounts?|files?|uploads?|banks?)\b"#),
           !has(#"transactions?|txns?"#) {
            return "**You uploaded \(docs.count) statement\(docs.count == 1 ? "" : "s").**"
        }

        // ---- per-statement transaction count ("how many Monzo transactions")
        if has(#"\bhow many\b|\bnumber of\b|\bcount\b"#), has(#"transactions?|txns?|purchases?|payments?"#),
           let d = namedDoc(for: question) {
            return "**\(d.displayName) has \(d.rows.count) transaction\(d.rows.count == 1 ? "" : "s").**"
        }

        // ---- most / fewest transactions across statements ------------------
        if has(#"transactions?"#), has(#"\b(most|highest|largest|greatest|fewest|least|lowest|which statement|which account)\b"#),
           has(#"which|most|fewest|least|highest|lowest"#), namedDoc(for: question) == nil {
            let ranked = docs.sorted { $0.rows.count > $1.rows.count }
            let fewest = has(#"\b(fewest|least|lowest)\b"#)
            if let d = (fewest ? ranked.last : ranked.first) {
                return "**\(d.displayName) has the \(fewest ? "fewest" : "most") transactions: \(d.rows.count).**"
            }
        }

        // ---- highest / lowest closing balance ------------------------------
        if has(#"closing balance|closing bal|highest balance|lowest balance"#) || (has(#"balance"#) && has(#"which (statement|account)"#)) {
            let withBal = docs.compactMap { d -> (LoadedDoc, Double)? in closing(d).map { (d, $0) } }
            if !withBal.isEmpty {
                let low_ = has(#"\b(lowest|smallest|least)\b"#)
                let ranked = withBal.sorted { $0.1 > $1.1 }
                if let pick = (low_ ? ranked.last : ranked.first) {
                    return "**\(pick.0.displayName) has the \(low_ ? "lowest" : "highest") closing balance: \(money(pick.1)).**"
                }
            }
        }

        // ---- highest money in / out (never a category or single-txn question)
        if !has(#"categor|largest (credit|debit|expense|transaction|payment)"#),
           has(#"\b(most|highest|largest|greatest)\b"#) || has(#"which (account|statement|bank)"#) {
            if has(#"money in|received|credited|income|inflow|paid in|total in\b"#), !has(#"salary"#) {
                if let d = docs.max(by: { moneyIn($0) < moneyIn($1) }) {
                    return "**\(d.displayName) has the most money in: \(money(moneyIn(d))).**"
                }
            }
            if has(#"money out|spent|debited|outflow|total out\b|spending"#) {
                if let d = docs.max(by: { moneyOut($0) < moneyOut($1) }) {
                    return "**\(d.displayName) has the most money out: \(money(moneyOut(d))).**"
                }
            }
        }

        // ---- largest credit / debit across all statements (single txn, not a
        // category rollup — "highest SPENDING category" is handled below) --------
        if !has(#"categor"#), has(#"\b(largest|biggest|highest|greatest)\b"#),
           has(#"credit|deposit|money (in|received)|income|inflow"#), !has(#"limit|card"#) {
            let all = docs.flatMap { d in d.rows.filter { $0.credit > 0 }.map { ($0, d) } }
            if let (r, d) = all.max(by: { $0.0.credit < $1.0.credit }) {
                return "**Largest credit: \(money(r.credit))** — \(r.descr) (\(d.displayName), \(r.txnDate))."
            }
        }
        if !has(#"categor"#), has(#"\b(largest|biggest|highest|greatest)\b"#),
           has(#"debit|expense|spend|payment|withdrawal|money out|outflow|charge"#) {
            let all = docs.flatMap { d in d.rows.filter { $0.debit > 0 }.map { ($0, d) } }
            if let (r, d) = all.max(by: { $0.0.debit < $1.0.debit }) {
                return "**Largest debit: \(money(r.debit))** — \(r.descr) (\(d.displayName), \(r.txnDate))."
            }
        }

        // ---- top spending category -----------------------------------------
        if has(#"which category|what category|category.*(highest|most|biggest|top)|highest.*category|top category|most spending"#) {
            var totals: [String: Double] = [:]
            for d in docs { for r in d.rows where r.debit > 0 {
                totals[r.category.isEmpty ? "Other" : r.category, default: 0] += r.debit
            } }
            if let (cat, amt) = totals.max(by: { $0.value < $1.value }) {
                return "**\(cat) is your highest-spending category: \(money(amt)).**"
            }
        }

        // ---- which statement received the highest salary -------------------
        if has(#"salary|payroll|wages?"#), has(#"which (bank|account|statement)|highest|most"#), !has(#"how many|total|count|list|contain"#) {
            let withSal = docs.compactMap { d -> (LoadedDoc, Double)? in Self.salaryAmount(d.rows).map { (d, $0) } }
            if let pick = withSal.max(by: { $0.1 < $1.1 }) {
                return "**\(pick.0.displayName) received the highest salary: \(money(pick.1)).**"
            }
        }

        // ---- salary count / total ------------------------------------------
        if has(#"salary|payroll"#), has(#"how many|number of|count|total|how much|sum"#) {
            let sals = docs.compactMap { Self.salaryAmount($0.rows) }
            if has(#"how many|number of|count"#) {
                return "**\(sals.count) salary transaction\(sals.count == 1 ? "" : "s")** — one per statement that's paid a salary."
            }
            let total = sals.reduce(0, +)
            return "**Total salary received: \(money(total))** across \(sals.count) statement\(sals.count == 1 ? "" : "s")."
        }

        // ---- high-value transactions over a threshold ----------------------
        if has(#"above|over|more than|greater than|bigger than|exceed|higher than|at least"#),
           let thr = Self.firstMoney(in: low) {
            let hits = docs.flatMap { d in
                d.rows.filter { max($0.debit, $0.credit) > thr }.map { ($0, d) }
            }.sorted { max($0.0.debit, $0.0.credit) > max($1.0.debit, $1.0.credit) }
            guard !hits.isEmpty else { return "**No transactions above \(money(thr)).**" }
            var lines = ["**\(hits.count) transaction\(hits.count == 1 ? "" : "s") above \(money(thr)):**"]
            for (r, d) in hits.prefix(50) {
                let amt = r.debit > 0 ? r.debit : r.credit
                let dir = r.debit > 0 ? "out" : "in"
                lines.append("- \(money(amt)) \(dir) — \(r.descr) (\(d.displayName), \(r.txnDate))")
            }
            return lines.joined(separator: "\n")
        }

        return nil
    }

    /// First plain money amount in text (thousands + optional decimals), ignoring
    /// 4-digit years — for threshold questions like "above £500".
    static func firstMoney(in low: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: #"[£$€₹]?\s*(\d[\d,]*(?:\.\d+)?)"#),
              let m = re.firstMatch(in: low, range: NSRange(low.startIndex..., in: low)),
              let r = Range(m.range(at: 1), in: low) else { return nil }
        let digits = low[r].filter { $0.isNumber || $0 == "." }
        guard let v = Double(digits) else { return nil }
        return (v >= 1900 && v <= 2100 && !digits.contains(".")) ? nil : v   // skip a bare year
    }

    /// A statement's primary monthly salary: the largest payroll-qualifying credit
    /// in it, or nil when there's none. "Salary" is one payroll inflow per account
    /// (so a current account with several employer-ish credits still counts once),
    /// which is why totals/counts use the max qualifying credit, not every match.
    /// Recognised by an explicit payroll marker (salary / payroll / wages), or a
    /// substantial (≥ the statement currency's rough monthly-pay floor) credit
    /// tagged BGC / "giro received" / from a company (Ltd / Limited / PLC /
    /// Technologies) — how employers appear when there's no "salary" label.
    static func salaryAmount(_ rows: [TxnRow]) -> Double? {
        rows.compactMap { r -> Double? in
            guard r.credit > 0 else { return nil }
            let d = r.descr.lowercased()
            if d.range(of: #"\b(salary|salaries|payroll|wages?|stipend)\b"#,
                       options: .regularExpression) != nil { return r.credit }
            let payrollish = d.range(of: #"\bbgc\b|giro\s+received|\b(ltd|limited|plc|inc|technologies)\b"#,
                                     options: .regularExpression) != nil
            return (payrollish && r.credit >= 500) ? r.credit : nil
        }.max()
    }

    /// Whether a statement contains a salary (payroll) credit.
    static func hasSalary(_ rows: [TxnRow]) -> Bool { salaryAmount(rows) != nil }

    /// The subject noun of a "which statements contain <X> transactions" question
    /// (the words before "transactions/payments/…"), lowercased; nil when absent.
    static func contentTerm(_ low: String) -> String? {
        let pattern = #"(?:contain\w*|have|has|having|include\w*|with|show\w*)\s+(?:any\s+|a\s+|the\s+|some\s+)?([a-z0-9&'\-. ]+?)\s+(?:transactions?|payments?|credits?|debits?|charges?|entries|deposits?|purchases?)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: low, range: NSRange(low.startIndex..., in: low)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: low) else { return nil }
        let term = low[r].trimmingCharacters(in: .whitespaces)
        return term.isEmpty ? nil : term
    }

    /// Render a "which statements contain X" answer: honest "none", a single-line
    /// statement, or a bulleted (sorted) list.
    static func docListAnswer(_ hits: [LoadedDoc], subject: String, plural: String) -> String {
        guard !hits.isEmpty else { return "**No statements contain \(plural).**" }
        let names = hits.map(\.displayName).sorted()
        if names.count == 1 { return "**\(names[0])** contains \(subject)." }
        return (["**These statements contain \(plural):**"] + names.map { "- \($0)" })
            .joined(separator: "\n")
    }

    /// Every plain money amount (thousands + 2 decimals) in `text`, in order.
    // Task 0.5 delegations (see note on `creditSummary`).
    static func moneyValues(in text: String) -> [Double] {
        StatementMetadataParser.moneyValues(in: text).map(Self.double)
    }

    static func openingBalance(in text: String) -> Double? {
        StatementMetadataParser.openingBalance(in: text).map(Self.double)
    }

    static func moneyAfterLabel(in text: String, labels: [String]) -> Double? {
        StatementMetadataParser.moneyAfterLabel(in: text, labels: labels).map(Self.double)
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

    /// Regenerate the reply to the most recent question: drop the last user turn and
    /// its answer, then re-`send` the same question so it re-runs the identical
    /// routing (deterministic LEDGER/ANALYTICS, or a fresh MLX generation).
    func regenerate() {
        guard !isThinking else { return }
        guard let userIdx = messages.lastIndex(where: { $0.role == .user }) else { return }
        let q = messages[userIdx].content
        messages.removeSubrange(userIdx...)   // remove the question + its old reply
        send(q)                               // re-appends the question, produces a new reply
    }

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
    // this Mac only, like everything else. UI-test runs write to a per-process
    // temp file instead, so they start empty and never touch real history.
    private static var historyURL: URL {
        if TestMode.active {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("penny-uitest-history-\(getpid()).json")
        }
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
        PennyLog.shared.log("chat", "Q: \(q)")

        // Deterministic route: if they want the transaction list/table and we've
        // already extracted it, answer straight from the data — complete and correctly
        // aligned — instead of asking the model to re-type it from a clipped context
        // (which truncates rows and garbles columns).
        let txns = selectedTransactions()
        if wantsTransactionTable(q), !txns.isEmpty {
            let l = q.lowercased()
            // If the question names a category we actually hold — by its full name
            // ("…of Dental Care") or just one distinctive word ("a dental table") —
            // narrow the ledger to it rather than dumping every row. We tokenise on
            // whole words (so "barclays" can't hit a "Bar" category), score each
            // category by shared words plus a bonus for a verbatim multi-word phrase,
            // and pick the best (longest name breaks ties, so "Fast Food" beats "Food").
            func tokens(_ s: String) -> Set<String> {
                Set(String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
                    .split(separator: " ").map(String.init).filter { $0.count >= 3 })
            }
            let queryTokens = tokens(l)
            let distinctCategories = Set(txns.compactMap(\.category)).filter { !$0.isEmpty }
            var scored: [(name: String, score: Int)] = []
            for cat in distinctCategories {
                let shared = tokens(cat).intersection(queryTokens).count
                let phrase = (cat.contains(" ") && l.contains(cat.lowercased())) ? 5 : 0
                let total = shared + phrase
                if total > 0 { scored.append((name: cat, score: total)) }
            }
            let best = scored.max {
                $0.score != $1.score ? $0.score < $1.score : $0.name.count < $1.name.count
            }
            let matchedCategory = best?.name

            // Resolve any date window first ("from 2026-03-05 to 2026-04-05", "in
            // March", "last month", "last 7 days") so its words don't leak into the
            // merchant match below, and so the range narrows whatever scope we pick.
            let range = tableDateRange(q, txns: txns)

            // No category named? Try a merchant/description filter, so "table of this
            // TFL TRAVEL CHARGE TFL.GOV.UK/CP" narrows to those rows instead of dumping
            // everything. Strip command/filler words first — a bare "show all
            // transactions" then leaves nothing to filter on and still shows the lot.
            // Date vocabulary is stripped too so "table for March" can't merchant-match.
            let stopwords: Set<String> = [
                "table", "tables", "list", "show", "give", "see", "view", "display",
                "generate", "create", "make", "want", "please", "the", "this", "that",
                "for", "and", "with", "all", "full", "every", "complete", "entire",
                "whole", "transaction", "transactions", "ledger", "entries", "entry",
                "data", "statement", "statements", "record", "records",
                // date words (so "in March", "last month", "last 7 days" don't merchant-match)
                "last", "past", "previous", "current", "next", "recent", "since", "after",
                "before", "until", "during", "between", "from", "day", "days", "week",
                "weeks", "month", "months", "year", "years", "first", "january", "jan",
                "february", "feb", "march", "mar", "april", "apr", "may", "june", "jun",
                "july", "jul", "august", "aug", "september", "sep", "sept", "october",
                "oct", "november", "nov", "december", "dec"]
            // Also drop pure-number tokens (years/day counts) from merchant matching.
            let filterTokens = queryTokens.subtracting(stopwords).filter { Int($0) == nil }
            var matchedMerchant: String?
            var merchantRows: [PennyCore.Transaction] = []
            if matchedCategory == nil, !filterTokens.isEmpty {
                var bestScore = 0
                var bestShared: Set<String> = []
                for t in txns {
                    let shared = tokens(t.description).intersection(filterTokens)
                    if shared.count > bestScore { bestScore = shared.count; bestShared = shared }
                }
                // Guard against filtering on one short, incidental word: need either
                // two matching words or one distinctive (5+ char) one.
                let qualifies = bestScore >= 2 || bestShared.contains { $0.count >= 5 }
                if bestScore >= 1, qualifies {
                    merchantRows = txns.filter {
                        tokens($0.description).intersection(filterTokens).count == bestScore
                    }
                    if let first = merchantRows.first {
                        matchedMerchant = first.description.count > 40
                            ? String(first.description.prefix(39)) + "…" : first.description
                    }
                }
            }

            var rows: [PennyCore.Transaction]
            let scopeLabel: String?
            if let cat = matchedCategory {
                rows = txns.filter { $0.category?.caseInsensitiveCompare(cat) == .orderedSame }
                scopeLabel = cat
            } else if matchedMerchant != nil, !merchantRows.isEmpty {
                rows = merchantRows
                scopeLabel = matchedMerchant
            } else {
                rows = txns
                scopeLabel = nil
            }

            // Narrow to the requested date window, on top of any category/merchant
            // scope. Without this the range was silently ignored and the whole ledger
            // was dumped (`range` was resolved above, before merchant matching).
            if let range = range {
                rows = rows.filter {
                    guard let key = Self.isoDateKey($0.date) else { return false }
                    return key >= range.startKey && key <= range.endKey
                }
            }

            let scope = scopeLabel.map { " \($0)" } ?? ""

            // No rows in the window — say so plainly rather than an empty table.
            if let range = range, rows.isEmpty {
                let msg = "No\(scope) transactions\(range.label)."
                messages.append(ChatMessage(role: .assistant, content: msg, engine: "LEDGER"))
                PennyLog.shared.log("chat", "A (ledger): 0-row transaction table [\(range.label.trimmingCharacters(in: .whitespaces))]")
                return
            }

            // Show every row when the user explicitly asks for the whole ledger, or
            // when a date range is given (those windows are small); otherwise cap at
            // 200 (with a note on how to see the rest).
            let wantsAll = range != nil
                || ["all", "full", "every", "complete", "entire", "whole"].contains { l.contains($0) }
            let limit: Int? = wantsAll ? nil : 200
            let noun = rows.count == 1 ? "transaction" : "transactions"
            let rangeSuffix = range?.label ?? " on record"
            let header = (wantsAll || rows.count <= 200)
                ? "Here \(rows.count == 1 ? "is" : "are") all \(rows.count)\(scope) \(noun)\(rangeSuffix):\n\n"
                : "Here are your \(rows.count)\(scope) \(noun)\(rangeSuffix) (showing the first 200):\n\n"
            let table = Self.transactionsMarkdown(rows, currency: summary.currency, limit: limit)
            messages.append(ChatMessage(role: .assistant, content: header + table, engine: "LEDGER"))
            PennyLog.shared.log("chat", "A (ledger): \(rows.count)-row transaction table\(scopeLabel.map { " [\($0)]" } ?? "")\(range.map { " [\($0.label.trimmingCharacters(in: .whitespaces))]" } ?? "")")
            return
        }

        // Deterministic per-document metadata (opening/starting balance) — read
        // straight from the named statement's text, before the finance router's
        // greedy `balance` handler can answer with the wrong (latest, all-account)
        // figure. Falls through when the figure isn't in the text.
        if let answer = documentMetadataAnswer(q) {
            messages.append(ChatMessage(role: .assistant, content: answer, engine: "ANALYTICS"))
            PennyLog.shared.log("chat", "A (analytics): \(answer)")
            return
        }

        // Dynamic header-metadata fallback: the deterministic label parser above
        // couldn't find the statement date / cardholder for THIS layout, so read it
        // off the header with the on-device model (works on any statement), validated
        // before it's shown. Runs async and posts when ready.
        if let req = dynamicHeaderFactRequest(q) {
            answerHeaderFactDynamically(q, field: req.field, doc: req.doc)
            return
        }

        // Cross-document content lookup ("which statements contain salary?") — must
        // also precede the finance router, whose income/category handlers would
        // otherwise answer with one merged, doc-blind figure.
        if let answer = documentContentAnswer(q) {
            messages.append(ChatMessage(role: .assistant, content: answer, engine: "ANALYTICS"))
            PennyLog.shared.log("chat", "A (analytics): \(answer)")
            return
        }

        // Cross-document analytics (per-statement counts/balances, largest credit/
        // debit with attribution, top category, salary totals, high-value filters).
        if let answer = crossDocumentAnswer(q) {
            messages.append(ChatMessage(role: .assistant, content: answer, engine: "ANALYTICS"))
            PennyLog.shared.log("chat", "A (analytics): \(answer)")
            return
        }

        // Deterministic finance router: answer factual numeric questions (totals,
        // counts, balance — incl. multi-account and as-of-a-date, category/
        // merchant/period spend, largest/top, income, net/profit/loss, average)
        // straight from the parsed rows — no model, no hallucinated figures.
        // Returns nil for advisory/open-ended questions, which fall to MLX.
        let cur = summary.currency
        let accounts = selectedDocs().map {
            FinanceRouter.AccountBalance(name: $0.displayName, balance: $0.latestBalance,
                                         isCard: $0.isCard)
        }
        let money: (Double) -> String = { Money.format($0, currency: cur) }
        let routerAnswer = FinanceRouter.answer(q, rows: selectedRows(), currency: cur,
                                                accounts: accounts, money: money)

        // Phase 1.1 — route through the Query Engine (LegacyQueryBridge → QueryEngine).
        // We adopt the engine's answer ONLY when it exactly reconciles with the router
        // (runtime parity guard): the engine can prove parity or fall back, never change
        // a reply. Unsupported intents (bridge returns nil) fall back automatically.
        if let engineAnswer = EngineRouter.answer(for: q, graph: selectedGraph(), money: money),
           engineAnswer == routerAnswer {
            engineRoutingStats.routed += 1
            messages.append(ChatMessage(role: .assistant, content: engineAnswer, engine: "ANALYTICS"))
            PennyLog.shared.log("chat", "A (analytics): \(engineAnswer)")
            return
        }
        if let routerAnswer {
            engineRoutingStats.fellBack += 1
            messages.append(ChatMessage(role: .assistant, content: routerAnswer, engine: "ANALYTICS"))
            PennyLog.shared.log("chat", "A (analytics): \(routerAnswer)")
            return
        }
        engineRoutingStats.unsupported += 1

        messages.append(ChatMessage(role: .assistant, content: "", engine: "MLX"))
        let idx = messages.count - 1
        isThinking = true

        let rows = selectedRows()
        let fullText = scopedText()
        let key = retrieverSignature()
        let facts = computedFacts()
        // Per-document header context: when the question names a specific imported
        // statement, the RAG rows alone can't answer header-level metadata (the
        // statement period, sort code, account number, payment-due date, address).
        // Supply that statement's header text so the model can read it off directly.
        let namedHeader = namedDocHeader(for: q)
        // UI-test stub: deterministic reply on the MLX fallback path — no model
        // load, no NLEmbedding, so tests are fast and repeatable.
        if TestMode.modelReady {
            messages[idx].content = "\(TestMode.stubReplyPrefix) · grounded on \(rows.count) rows · \(q)"
            PennyLog.shared.log("chat", "A (stub): \(messages[idx].content)")
            isThinking = false
            return
        }
        generateTask = Task {
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
            // A named statement's header goes right next to the retrieved rows, so
            // header-level questions ("statement period for Barclays") are answerable.
            if let namedHeader {
                grounding = namedHeader + "\n\n" + grounding
            }
            // Exact, deterministically-computed figures always ride along, so
            // free-form model answers quote the same numbers the Today panel shows.
            if !facts.isEmpty {
                grounding = facts + "\n\n" + grounding
            }
            do {
                // Concise cap keeps generation fast: chat answers here are advisory
                // prose (transaction tables are served deterministically by the LEDGER
                // path, never the model), and short answers still stop early at
                // end-of-text — so 512 rarely truncates a real answer but bounds the
                // worst-case latency instead of letting it run to thousands of tokens.
                _ = try await llm.ask(question: q, statementText: grounding, maxTokens: 512, onEngine: { [weak self] engine in
                    // The badge reflects the engine that ACTUALLY answered — Apple's
                    // system model and MLX are both possible here (finding: bubbles
                    // said "MLX" while Apple Intelligence did the answering).
                    Task { @MainActor in
                        guard let self, self.messages.indices.contains(idx) else { return }
                        self.messages[idx].engine = engine == "apple" ? "APPLE" : "MLX"
                    }
                }) { [weak self] piece in
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
            // Note any text the user chose to stop mid-stream so a partial answer
            // doesn't read as if the model finished on its own.
            if Task.isCancelled, messages.indices.contains(idx) {
                let partial = messages[idx].content.trimmingCharacters(in: .whitespacesAndNewlines)
                messages[idx].content = partial.isEmpty ? "_(stopped)_" : partial + "\n\n_(stopped)_"
            }
            PennyLog.shared.log("chat",
                "A (mlx): \(messages.indices.contains(idx) ? messages[idx].content : "(no answer)")")
            isThinking = false
            generateTask = nil
        }
    }

    /// Stop an in-flight answer — used by the composer's Stop button when the
    /// model is running away or hallucinating. Cancels the streaming task (the
    /// MLX loop checks `Task.isCancelled`), which appends a "(stopped)" note and
    /// clears `isThinking` on its own.
    func cancelGeneration() {
        generateTask?.cancel()
    }

    /// Exact figures computed in Swift, prepended to the model's grounding so a
    /// free-form answer can never contradict the Today panel. (These are the
    /// same sums `recomputeSummary()` shows — never model-guessed.) When the
    /// statements span currencies, every figure is stated per currency — the
    /// model must never see a mixed-currency sum.
    private func computedFacts() -> String {
        let chosen = selectedDocs()
        guard summary.count > 0 else { return "" }
        let cur = summary.currency
        let multi = summary.isMultiCurrency
        var lines = ["EXACT FIGURES (computed from the parsed statement data — always use these):"]
        if multi {
            for c in summary.currencyList {
                guard let bal = summary.perCurrency[c]?.balance else { continue }
                lines.append("- Total balance across \(c) accounts: \(Money.format(bal, currency: c))")
            }
        } else if let bal = summary.balance {
            lines.append("- Total balance across accounts: \(Money.format(bal, currency: cur))")
        }
        for d in chosen {
            if let b = d.latestBalance {
                let dCur = multi ? Self.effectiveCurrency(of: d) : cur
                lines.append("- \(d.displayName): balance \(Money.format(b, currency: dCur))\(d.isCard ? " owed (credit card)" : "")")
            }
        }
        if multi {
            for c in summary.currencyList {
                guard let t = summary.perCurrency[c] else { continue }
                lines.append("- Total spent in \(c) (sum of debits): \(Money.format(t.spent, currency: c))")
                lines.append("- Total income in \(c) (credits, excl. card repayments): \(Money.format(t.income, currency: c))")
                lines.append("- Net in \(c) (income − spend): \(Money.format(t.net, currency: c))")
            }
        } else {
            lines.append("- Total spent (sum of debits): \(Money.format(summary.spent, currency: cur))")
            lines.append("- Total income (credits, excl. card repayments): \(Money.format(summary.income, currency: cur))")
            lines.append("- Net (income − spend): \(Money.format(summary.net, currency: cur))")
        }
        lines.append("- Transactions: \(summary.count)")
        return lines.joined(separator: "\n")
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
    /// `includeTemps: false` counts only completed cache files — required when
    /// deciding "downloaded ✓", where an in-flight (or orphaned) temp of a
    /// DIFFERENT model would otherwise mark this one as present.
    static func bytesOnDisk(repo: String, includeTemps: Bool = true) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0

        // 1) Completed blobs in the HF cache: <Caches>/huggingface/hub/models--<repo>
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let escaped = "models--" + repo.replacingOccurrences(of: "/", with: "--")
            let modelDir = caches.appendingPathComponent("huggingface/hub/\(escaped)")
            total += dirSize(modelDir, fm: fm)
        }

        // 2) In-flight downloads: URLSession streams to CFNetworkDownload_*.tmp in tmp.
        if includeTemps { total += tempDownloadBytes(fm: fm) }
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
            at: tmp, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return 0 }
        var total: Int64 = 0
        for u in items where u.lastPathComponent.hasPrefix("CFNetworkDownload") {
            // Only temps still being written to count: orphans from killed attempts
            // (gigabytes of them accumulate) would freeze the meter at a bogus number.
            let vals = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let mtime = vals?.contentModificationDate,
                  Date().timeIntervalSince(mtime) < 60 else { continue }
            total += Int64(vals?.fileSize ?? 0)
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
