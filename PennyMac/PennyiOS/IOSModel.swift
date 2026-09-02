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
    /// Underlying bank accounts an aggregator export reveals (harvested at
    /// import by shared core; iOS keeps no page text, so this is persisted).
    var accounts: [String] = []
    let rows: [TxnRow]

    /// What lists show: the bank if known, else a cleaned filename — never
    /// raw "\*.csv"/"\*.pdf" technical names.
    var displayName: String { bankName ?? StatementName.pretty(name) }
}

struct IOSChatMsg: Identifiable, Equatable {
    let id = UUID()
    let role: Role          // .user | .penny
    var text: String
    var engine: String?     // "swift engine" | "apple" | "mlx" | nil while streaming
    var receipts: AnswerReceipts?   // Fixes 4 & 5 — scope + rows behind a figure
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

    // MARK: onboarding
    @AppStorage("penny.ios.onboarded") var onboarded = false

    /// B4 — the last RESOLVED question (fragments expanded), so follow-up
    /// chains stay anchored to a stem that still carries an intent.
    private var lastResolvedQuestion: String?

    private let llm = PennyLLM()
    private var ingester: TxnIngester?

    static let maxImportBatch = 10

    init() {
        restore()
    }

    // MARK: - derived

    var mergedRows: [TxnRow] { statements.flatMap(\.rows) }
    var hasData: Bool { !mergedRows.isEmpty }

    // MARK: - Column-mapping fallback (Fix 2)
    struct PendingMapping: Identifiable, Equatable {
        let id = UUID()
        let records: [[String]]
        let analysis: CSVMapper.Analysis
        let name: String
        let text: String
    }
    @Published var pendingMapping: PendingMapping?

    func confirmMapping(_ mapping: [String: Int]) {
        guard let p = pendingMapping else { return }
        pendingMapping = nil
        do {
            let cats = try Self.mappingCategories()
            let out = CSVMapper.buildRows(records: p.records, headerIdx: p.analysis.headerIdx,
                                          mapping: mapping, categories: cats, rawText: p.text)
            guard !out.rows.isEmpty else {
                importErrors = ["That mapping didn't yield any transactions — check the date and amount columns."]
                return
            }
            let fp = StatementFingerprint.compute(out.rows)
            if statements.contains(where: { StatementFingerprint.compute($0.rows) == fp }) {
                importErrors = ["\(p.name): already loaded — skipped so totals don't double."]
                return
            }
            statements.append(IOSStatement(
                name: p.name, bankName: out.bankName,
                currency: out.detectedCurrency.isEmpty ? "GBP" : out.detectedCurrency,
                isCard: out.isCard, closingBalance: out.closingBalance, rows: out.rows))
            persist()
        } catch {
            importErrors = ["Couldn't build the statement from that mapping."]
        }
    }

    func cancelMapping() { pendingMapping = nil }

    private static func mappingCategories() throws -> Categories {
        guard let cats = Bundle.main.url(forResource: "categories", withExtension: "json")?.path else {
            throw NSError(domain: "penny", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "categories.json missing"])
        }
        return try Categories(categoriesJSONPath: cats)
    }

    // MARK: - CSV export (Fix 7) — shares TxnCSVExport with the macOS app.
    @Published var isExportingCSV = false
    var canExportCSV: Bool { hasData }
    func csvExportDocument() -> CSVFileDocument {
        let rows = mergedRows.sorted { ($0.txnDate, $0.seq) < ($1.txnDate, $1.seq) }
        return CSVFileDocument(data: TxnCSVExport.data(from: rows))
    }
    func csvExportFilename() -> String {
        statements.count == 1
            ? (statements[0].name as NSString).deletingPathExtension
            : "penny-transactions"
    }

    // MARK: - Reconciliation handshake (Fix 1) — shares Reconciliation with macOS.
    /// Per-statement check. iOS statements carry no raw text, so the opening
    /// balance is implied from the first running balance when present.
    func reconciliation(for s: IOSStatement) -> Reconciliation.Report {
        let opening: Double? = s.rows.first(where: { $0.balance != nil }).map {
            ($0.balance ?? 0) - $0.credit + $0.debit
        }
        let closing = s.closingBalance ?? s.rows.last(where: { $0.balance != nil })?.balance
        return Reconciliation.check(rows: s.rows, opening: opening, closing: closing)
    }

    /// One trust line across all loaded statements (mirrors AppModel).
    var reconciliationLine: String? {
        let chosen = statements.filter { !$0.rows.isEmpty }
        guard !chosen.isEmpty else { return nil }
        let reports = chosen.map { reconciliation(for: $0) }
        let sym = Self.symbol(primaryCurrency)
        let money: (Double) -> String = { sym + String(format: "%.2f", $0) }

        let mismatches = reports.filter { if case .mismatch = $0.status { return true } else { return false } }
        if let bad = mismatches.first, case .mismatch(let d) = bad.status {
            return mismatches.count == 1
                ? "⚠︎ one statement's totals are off by \(money(abs(d))) — I may have misread it"
                : "⚠︎ \(mismatches.count) statements don't reconcile"
        }
        let verified = reports.filter { $0.reconciles }.count
        if verified == 0 { return "no balance line to reconcile against" }
        let total = reports.count
        return verified == total
            ? "\(total == 1 ? "Statement reconciles" : "All \(total) statements reconcile") ✓"
            : "\(verified) of \(total) statements reconcile ✓"
    }

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

    /// Per-category spend. `amount` is the dominant-currency figure (bar/sort
    /// yardstick); `display` shows each currency's own total joined — ₹ + £ is
    /// never blended into one number (parity with macOS, 2026-09-02 bug).
    var spendByCategory: [(category: String, amount: Double, display: String)] {
        var byCatCur: [String: [String: Double]] = [:]
        for r in mergedRows where r.debit > 0 {
            let c = r.currency.isEmpty ? primaryCurrency : r.currency
            byCatCur[r.category, default: [:]][c, default: 0] += r.debit
        }
        var byCur: [String: Double] = [:]
        for m in byCatCur.values { for (c, v) in m { byCur[c, default: 0] += v } }
        let dom = byCur.max { $0.value < $1.value }?.key ?? primaryCurrency
        return byCatCur
            .map { name, m -> (String, Double, String) in
                let display = m.count > 1
                    ? m.sorted { $0.value > $1.value }
                        .map { self.money($0.value, $0.key) }.joined(separator: " + ")
                    : self.money(m.values.first ?? 0, m.keys.first ?? dom)
                return (name, m[dom] ?? m.values.max() ?? 0, display)
            }
            .sorted { $0.amount > $1.amount }
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
                        // Fix 2 — a CSV we couldn't auto-parse: offer the column-
                        // mapping fallback instead of a dead-end error.
                        if ext == "csv", let text = try? String(contentsOf: url, encoding: .utf8),
                           let analysis = CSVMapper.analyze(records: CSVMapper.parseRecords(text)) {
                            pendingMapping = PendingMapping(
                                records: CSVMapper.parseRecords(text), analysis: analysis,
                                name: url.lastPathComponent, text: text)
                        } else {
                            importErrors.append("\(url.lastPathComponent): no transactions found — is it a bank or card statement?")
                        }
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
                        isCard: out.isCard, closingBalance: out.closingBalance,
                        accounts: out.underlyingAccounts, rows: out.rows))
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

    /// "Roast me" (design B): the engine computes facts + a complete template
    /// roast; Apple's model may rephrase using ONLY those figures; any loop /
    /// invented number / refusal ships the template instead.
    func runRoast(_ userText: String) {
        messages.append(IOSChatMsg(role: .user, text: userText))
        let rows = mergedRows
        guard !rows.isEmpty else {
            messages.append(IOSChatMsg(role: .penny,
                text: "Add a statement first — I can't roast an empty plate.", engine: "swift engine"))
            return
        }
        let byCur = Dictionary(grouping: rows) { $0.currency }
        let dominant = byCur.max { $0.value.count < $1.value.count }?.value ?? rows
        let cur = dominant.first?.currency ?? primaryCurrency
        guard let roast = RoastEngine.roast(rows: dominant,
                                            money: { self.money($0, cur) },
                                            seed: UInt64.random(in: 1...UInt64.max)) else {
            messages.append(IOSChatMsg(role: .penny,
                text: "Nothing to roast yet — no spending rows here.", engine: "swift engine"))
            return
        }
        // Empty bullets = nothing roastable: the model would free-style with no
        // facts and the gate can't catch a ramble that invents no figures.
        guard PennyLLM.systemModelAvailable, !roast.bullets.isEmpty else {
            messages.append(IOSChatMsg(role: .penny, text: roast.fallback, engine: "swift engine"))
            return
        }
        isThinking = true
        let idx = messages.count
        messages.append(IOSChatMsg(role: .penny, text: "", engine: nil))
        let llm = self.llm
        Task {
            var garnish = ""
            do {
                garnish = try await llm.ask(
                    question: "Rewrite these true facts as one short, funny, teasing roast (max 110 words). "
                        + "Charming, never cruel. Use ONLY these numbers, change none of them, "
                        + "and end with the money-saving tip:\n" + roast.bullets.joined(separator: "\n"),
                    statementText: "", maxTokens: 300, allowMLXFallback: false,
                    onToken: { _ in })
            } catch { garnish = "" }
            await MainActor.run {
                guard self.messages.indices.contains(idx) else { self.isThinking = false; return }
                if RoastEngine.garnishAcceptable(garnish, bullets: roast.bullets) {
                    self.messages[idx].text = garnish
                    self.messages[idx].engine = "apple"
                } else {
                    self.messages[idx].text = roast.fallback
                    self.messages[idx].engine = "swift engine"
                }
                self.isThinking = false
            }
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
        // "Roast me" runs the deterministic roast pipeline (design B — mirrors
        // the macOS runRoast: engine facts + template, Apple-only garnish).
        if q.lowercased().contains("roast") { runRoast(q); return }
        // Typed patterns questions get the composed deterministic analysis
        // (the Patterns tab shows the same facts as cards).
        if q.lowercased().range(of: #"spending patterns?|patterns? (?:do you|in my|you) (?:notice|see)|what patterns"#,
                                options: .regularExpression) != nil {
            messages.append(IOSChatMsg(role: .user, text: q))
            let byCur = Dictionary(grouping: mergedRows) { $0.currency }
            var sections: [String] = []
            for (cur, part) in byCur.sorted(by: { $0.value.count > $1.value.count }) {
                let code = cur.isEmpty ? primaryCurrency : cur
                if let s = FinanceRouter.patternsReport(rows: part, money: { self.money($0, code) }) {
                    sections.append(byCur.count > 1 ? "**\(code)**\n\(s)" : s)
                }
            }
            messages.append(IOSChatMsg(role: .penny,
                text: sections.isEmpty ? "Not enough transactions yet to read patterns from."
                                       : sections.joined(separator: "\n\n"),
                engine: "swift engine"))
            return
        }
        // B4: resolve elliptical follow-ups against the last RESOLVED question,
        // then route/ground/remember the resolved form (the raw fragment still
        // shows in the chat). Resolving against raw fragments would chain
        // "and in July?" → "what about transport?" onto an intent-less stem.
        let resolvedQ = FinanceRouter.resolveFollowUp(q, previous: lastResolvedQuestion,
                                                      rows: mergedRows)
        lastResolvedQuestion = resolvedQ
        messages.append(IOSChatMsg(role: .user, text: q))

        guard hasData else {
            messages.append(IOSChatMsg(role: .penny, text: "Add a statement first — then ask me anything about it.", engine: nil))
            return
        }

        // Account-dimension questions — direct ("which bank accounts did I use
        // for zara?") or back-referencing ("from which accounts?", "this
        // transaction") — answered from the statements themselves (mirrors the
        // macOS pipeline).
        if q.lowercased().range(
            of: #"(?:from |in |on |to )?(?:which|what) (?:bank\s+)?(?:accounts?|statements?|banks?)\b"#,
            options: .regularExpression) != nil {
            // Superlatives first ("to which account did i receive most?") —
            // ranked per-statement totals from the shared brain, never a
            // cross-currency ranking. Parity with macOS.
            if let sup = StatementsQuery.superlative(resolvedQ, statements: statements.map {
                StatementsQuery.Statement(name: $0.displayName, rows: $0.rows, currency: $0.currency)
            }) {
                messages.append(IOSChatMsg(role: .penny, text: sup.text, engine: "swift engine",
                                           receipts: AnswerReceipts(rows: sup.rows, label: sup.label)))
                return
            }
            func attribute(_ rows: [(date: String, name: String, amount: Double, isCredit: Bool)]) -> Bool {
                var byDoc: [String: Int] = [:]
                for r in rows {
                    if let s = statements.first(where: { st in
                        st.rows.contains {
                            $0.txnDate == r.date
                                && (r.isCredit ? $0.credit : $0.debit) == r.amount
                                && ($0.merchant.isEmpty ? $0.descr : $0.merchant) == r.name
                        }
                    }) { byDoc[s.name, default: 0] += 1 }
                }
                guard !byDoc.isEmpty else { return false }
                let text: String
                if byDoc.count == 1, let only = byDoc.first {
                    text = rows.count == 1
                        ? "**That transaction is from \(only.key).**"
                        : "**All \(rows.count) transactions are from \(only.key).**"
                } else {
                    let parts = byDoc.sorted { $0.value > $1.value }.map { "\($0.key) (\($0.value))" }
                    text = "**Those transactions span \(byDoc.count) statements:** " + parts.joined(separator: " · ")
                }
                messages.append(IOSChatMsg(role: .penny, text: text, engine: "swift engine"))
                return true
            }
            if let ctx = FinanceRouter.context(for: resolvedQ, rows: mergedRows),
               !ctx.rows.isEmpty, ctx.label != (ctx.directionNote ?? "") {
                if attribute(ctx.rows.map {
                    (date: $0.txnDate, name: $0.merchant.isEmpty ? $0.descr : $0.merchant,
                     amount: $0.credit > 0 ? $0.credit : $0.debit, isCredit: $0.credit > 0)
                }) { return }
            }
            let backRef = q.lowercased().range(of: #"\b(?:this|that|these|those)\b"#,
                                               options: .regularExpression) != nil
                || q.split(whereSeparator: { $0.isWhitespace }).count <= 4
            if backRef,
               let receipts = messages.last(where: { $0.role == .penny })?.receipts,
               !receipts.rows.isEmpty {
                if attribute(receipts.rows.map {
                    (date: $0.date, name: $0.name, amount: $0.amount, isCredit: $0.isCredit)
                }) { return }
            }
        }

        // Bank-name roster ("whats the bank name?") — session metadata, never
        // a merchant search; the word "bank" lives inside countless payment
        // descriptions. Mirrors the macOS gate, including the underlying
        // accounts an aggregator export names (harvested at import by core).
        if q.lowercased().range(
            of: #"\bbank names?\b|(?:what|which|whats|what's|name|names) (?:is |are |of )?(?:the |my |these |those )?banks?\b"#,
            options: .regularExpression) != nil,
           // Money questions ABOUT a bank ("which bank did I pay most from?")
           // are the router's dimension-superlative, not a roster (parity).
           q.lowercased().range(of: #"transactions?|txns?|spen[dt]|balance|charge|pa(?:y|id)|receiv|\bmost\b|\bleast\b|\bmore\b|\bless\b|highest|lowest"#,
                                options: .regularExpression) == nil {
            let text: String
            if statements.count == 1 {
                let s = statements[0]
                var head = "**This statement is from \(s.displayName).**"
                if !s.accounts.isEmpty {
                    head += " Payments moved through: \(s.accounts.joined(separator: ", "))."
                }
                text = head
            } else {
                let lines = statements.map { s -> String in
                    var line = "- **\(s.displayName)** — \(s.currency), \(s.rows.count) transaction\(s.rows.count == 1 ? "" : "s")"
                    if !s.accounts.isEmpty { line += " · via \(s.accounts.joined(separator: ", "))" }
                    return line
                }
                text = "**Your \(statements.count) statements:**\n" + lines.joined(separator: "\n")
            }
            messages.append(IOSChatMsg(role: .penny, text: text, engine: "swift engine"))
            return
        }

        // Account dimension / senders / self-transfers ("how much did I pay
        // from Union Bank?", "who sent me money?", "did I transfer between my
        // own accounts?") — shared deterministic gate, mirrors macOS.
        if let acct = AccountQuery.answer(q, rows: mergedRows,
                                          money: { self.money($0, self.primaryCurrency) }) {
            messages.append(IOSChatMsg(role: .penny, text: acct, engine: "swift engine"))
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
        if var det = FinanceRouter.answer(resolvedQ, rows: rows, currency: cur,
                                          accounts: accounts,
                                          money: { self.money($0, cur) }) {
            // A "£0 on X" honest-zero whose X is really a STATEMENT name means
            // the router mistook session metadata for a merchant ("what
            // transaction did i make from paytm…"). Parity with macOS.
            if det.contains("I couldn't find any transactions matching"),
               let tr = det.range(of: #"matching “([^”]+)”"#, options: .regularExpression) {
                let phantom = String(String(det[tr]).dropFirst("matching “".count).dropLast()).lowercased()
                if let s = statements.first(where: { st in
                    [st.displayName, (st.name as NSString).deletingPathExtension]
                        .map { $0.lowercased() }.filter { !$0.isEmpty }
                        .contains { $0.contains(phantom) || phantom.contains($0) }
                }) {
                    let out = s.rows.reduce(0) { $0 + $1.debit }
                    let inc = s.rows.reduce(0) { $0 + $1.credit }
                    det = "**\(s.displayName) is one of your statements, not a merchant.** "
                        + "It has \(s.rows.count) transaction\(s.rows.count == 1 ? "" : "s") — "
                        + "\(money(out, s.currency)) out, \(money(inc, s.currency)) in."
                }
            }
            // Fixes 4 & 5 — scope + the transactions behind the figure.
            let receipts = FinanceRouter.context(for: resolvedQ, rows: rows)
                .flatMap { AnswerReceipts(from: $0) }
            messages.append(IOSChatMsg(role: .penny, text: det, engine: "swift engine", receipts: receipts))
            return
        }

        // Timing questions ("when did X pay me?") get dates from the matched
        // rows, not a generic count and not the model — parity with macOS.
        if AccountQuery.isTimingQuestion(resolvedQ),
           let ctx = FinanceRouter.context(for: resolvedQ, rows: rows), !ctx.rows.isEmpty {
            let text = AccountQuery.timingAnswer(matched: ctx.rows, label: ctx.label,
                                                 money: { self.money($0, cur) })
            messages.append(IOSChatMsg(role: .penny, text: text, engine: "swift engine",
                                       receipts: AnswerReceipts(from: ctx)))
            return
        }

        // Existence questions ("do i have prime?", "did i go to starbucks?")
        // get a yes-lead with the sums, deterministically — parity with macOS.
        if AccountQuery.isExistenceQuestion(resolvedQ),
           let ctx = FinanceRouter.context(for: resolvedQ, rows: rows), !ctx.rows.isEmpty {
            var outByCur: [String: Double] = [:], incByCur: [String: Double] = [:]
            for r in ctx.rows {
                let c = r.currency.isEmpty ? cur : r.currency
                if r.debit > 0 { outByCur[c, default: 0] += r.debit }
                if r.credit > 0 { incByCur[c, default: 0] += r.credit }
            }
            var text = AccountQuery.existenceLead(count: ctx.rows.count, label: ctx.label)
            let outs = outByCur.sorted { $0.value > $1.value }.map { self.money($0.value, $0.key) }
            let incs = incByCur.sorted { $0.value > $1.value }.map { self.money($0.value, $0.key) }
            if !outs.isEmpty { text += " Spent \(outs.joined(separator: " + "))." }
            if !incs.isEmpty { text += " Received \(incs.joined(separator: " + "))." }
            messages.append(IOSChatMsg(role: .penny, text: text, engine: "swift engine",
                                       receipts: AnswerReceipts(from: ctx)))
            return
        }

        // 2) Apple's on-device system model — iOS's ONLY generative engine (user
        //    directive: no MLX download on the phone; the deterministic layer
        //    carries every factual question regardless).
        guard PennyLLM.systemModelAvailable else {
            messages.append(IOSChatMsg(role: .penny,
                text: "That one needs Apple Intelligence, which isn't available on this device. Exact answers still work — ask me totals, categories, merchants, recurring charges, comparisons…",
                engine: nil))
            return
        }
        isThinking = true
        let idx = messages.count
        messages.append(IOSChatMsg(role: .penny, text: "", engine: nil))
        Task {
            do {
                _ = try await llm.ask(question: resolvedQ, statementText: digest(for: resolvedQ),
                                      maxTokens: 512,
                                      allowMLXFallback: false,   // iOS is Apple-only — never download weights
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
            } catch {
                if messages.indices.contains(idx) {
                    messages[idx].text = "Sorry — I couldn't answer that. \(error.localizedDescription)"
                    messages[idx].engine = nil
                }
            }
            isThinking = false
        }
    }

    /// The model's grounding (B2/B3): rows the router's scope parse deems
    /// relevant to the question + an exact facts card, with honest disclosure
    /// when the window can't hold every matching row.
    private func digest(for question: String) -> String {
        let all = mergedRows
        let scoped = FinanceRouter.relevantRows(for: question, in: all, limit: 400)
        var rows = scoped.rows
        var total = scoped.total
        let spent = rows.reduce(0) { $0 + $1.debit }
        let income = rows.filter { $0.category != "Payments" }.reduce(0) { $0 + $1.credit }
        var scopeName = scoped.scopeLabel.isEmpty ? "all transactions" : scoped.scopeLabel
        // Direction-scoped question ("my credits") → ground the model on rows of
        // that direction only (mirrors the Mac app and penny-server): a mixed
        // ledger reliably makes small models blend money-in and money-out.
        if let dir = FinanceRouter.directionScope(question) {
            let filtered = rows.filter { dir == .credit ? $0.credit > 0 : $0.debit > 0 }
            if !filtered.isEmpty {
                rows = filtered
                total = min(total, filtered.count)
                scopeName += dir == .credit ? " — credits (money in) only" : " — debits (money out) only"
            }
        }

        var lines = ["All amounts are in \(primaryCurrency) (\(Self.symbol(primaryCurrency)))."]
        // B4: the last few exchanges, so "why is that so high?" has a referent.
        // The most recent reply carries more (1200 chars) — a deterministic list
        // truncated to 300 left the model unable to discuss what the analytics
        // engine just showed (mirrors the macOS digest).
        let turns = Array(messages.suffix(7).filter { !$0.text.isEmpty }.dropLast())
        if turns.count > 0 {
            lines.append("RECENT CONVERSATION:")
            for (i, m) in turns.enumerated() {
                let cap = i >= turns.count - 2 ? 1200 : 300
                lines.append("\(m.role == .user ? "User" : "Penny"): \(String(m.text.prefix(cap)))")
            }
        }
        lines.append("EXACT FIGURES (computed, trust these over any sum you attempt): "
            + "\(scopeName): spent \(money(spent)), received \(money(income)), \(rows.count) transactions shown.")
        if total > rows.count {
            lines.append("NOTE: showing the \(rows.count) most recent of \(total) matching transactions — "
                + "say so if the user asks about completeness.")
        }
        lines.append("Date | Description | Debit | Credit | Balance | Category")
        for r in rows {
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
        var account: String?             // nil in pre-existing stores
        var selfTransfer: Bool?          // nil in pre-existing stores
        init(_ r: TxnRow) {
            date = r.txnDate; month = r.month; year = r.year; monthNo = r.monthNo; day = r.day
            descr = r.descr; merchant = r.merchant; category = r.category
            debit = r.debit; credit = r.credit; balance = r.balance
            currency = r.currency; seq = r.seq
            account = r.account; selfTransfer = r.isSelfTransfer ? true : nil
        }
        var row: TxnRow {
            var r = TxnRow(txnDate: date, month: month, year: year, monthNo: monthNo, day: day,
                           descr: descr, merchant: merchant, category: category,
                           debit: debit, credit: credit, balance: balance, currency: currency, seq: seq)
            r.account = account
            r.isSelfTransfer = selfTransfer ?? false
            return r
        }
    }
    private struct StatementDTO: Codable {
        var name: String, bankName: String?, currency: String
        var isCard: Bool, closingBalance: Double?
        var accounts: [String]?          // nil in pre-existing stores
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
                         accounts: s.accounts.isEmpty ? nil : s.accounts,
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
                         accounts: d.accounts ?? [], rows: d.rows.map(\.row))
        }
        importedRowCount = mergedRows.count
    }
}
