import Foundation
import PennyCore
import PennyTxnStore

// penny-server — the macOS Penny pipeline on a web page.
//
//   browser  ──HTTP──▶  penny-server
//                         ├─ PennyTxnStore : PDF/CSV → rows + categories (deterministic)
//                         ├─ FinanceRouter : natural-language finance Q&A (deterministic)
//                         └─ PennyLLM/MLX  : on-device fallback answers (the ONLY LLM)
//
// One self-contained binary: serves the single-page UI at "/" and the JSON API.
// No cloud, no Python — MLX is the only model, and it runs locally.

// MARK: - Session model

/// User-facing ingest failures — `localizedDescription` is shown verbatim in the UI.
struct IngestUserError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Statement {
    let name: String
    let bankName: String?
    let currency: String
    let isCard: Bool
    let closingBalance: Double?
    let rows: [TxnRow]
    /// Content identity (rows, not filename) — duplicate uploads are rejected.
    let fingerprint: String
}

struct ModelState {
    var id: String = PennyLLM.sliceModelID
    var loaded = false
    var loading = false
    var progress: Double = 0
    var error: String?
}

// MARK: - Engine (serialised session state + the Swift pipeline)

actor PennyEngine {
    private let ingester: TxnIngester
    private let llm = PennyLLM()
    private(set) var statements: [Statement] = []
    private(set) var model = ModelState()

    init() throws {
        guard let categories = Bundle.module.url(forResource: "categories", withExtension: "json")?.path else {
            throw NSError(domain: "penny", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "categories.json missing from bundle"])
        }
        let profilesDir = Bundle.module.url(forResource: "bank_profiles", withExtension: nil)?.path ?? ""
        self.ingester = try TxnIngester(categoriesJSONPath: categories, bankProfilesDir: profilesDir)
    }

    // ---- statements ----

    var mergedRows: [TxnRow] { statements.flatMap(\.rows) }

    var primaryCurrency: String {
        // Most common currency across loaded statements (default GBP).
        let codes = statements.map(\.currency).filter { !$0.isEmpty }
        let counts = Dictionary(grouping: codes, by: { $0 }).mapValues(\.count)
        return counts.max(by: { $0.value < $1.value })?.key ?? "GBP"
    }

    var accounts: [FinanceRouter.AccountBalance] {
        statements.map { .init(name: $0.bankName ?? $0.name, balance: $0.closingBalance, isCard: $0.isCard) }
    }

    func reset() { statements.removeAll() }

    /// Parse an uploaded statement (bytes + filename) through the deterministic pipeline.
    func ingest(data: Data, filename: String) throws -> Statement {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard ["pdf", "csv", "xlsx"].contains(ext) else {
            let hint = ext == "xls"
                ? "That's the pre-2007 Excel format — re-save it as .xlsx or .csv and try again."
                : "Export the file as PDF, CSV or XLSX and try again."
            throw IngestUserError(message: "“.\(ext)” files aren't supported — Penny reads PDF, CSV and Excel (.xlsx) statements. \(hint)")
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + filename)
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let out: IngestOutput
        do {
            switch ext {
            case "csv":  out = try ingester.ingestCSV(path: tmp.path)
            case "xlsx": out = try ingester.ingestXLSX(path: tmp.path)
            default:     out = try ingester.ingestPDF(path: tmp.path)
            }
        } catch {
            throw IngestUserError(message: "Couldn't read “\(filename)” — it doesn't look like a readable \(ext.uppercased()) file. If it came from your bank, try re-downloading it.")
        }
        guard !out.rows.isEmpty else {
            throw IngestUserError(message: "No transactions found in “\(filename)”. Is it a bank or card statement? Scanned (image-only) PDFs aren't supported yet.")
        }

        // Duplicate guard: identical rows under any filename would silently
        // double every total on the dashboard and in chat answers.
        let fp = StatementFingerprint.compute(out.rows)
        if let existing = statements.first(where: { $0.fingerprint == fp }) {
            throw IngestUserError(message: "“\(filename)” is already loaded\(existing.name == filename ? "" : " (as “\(existing.name)”)") — skipped so your totals don't double.")
        }

        let stmt = Statement(name: filename,
                             bankName: out.bankName,
                             currency: out.detectedCurrency.isEmpty ? "GBP" : out.detectedCurrency,
                             isCard: out.isCard,
                             closingBalance: out.closingBalance,
                             rows: out.rows,
                             fingerprint: fp)
        statements.append(stmt)
        return stmt
    }

    // ---- chat ----

    /// Every currency present across the loaded statements (row currency, falling
    /// back to the statement's). More than one means aggregates mix currencies.
    var loadedCurrencies: [String] {
        var set = Set<String>()
        for s in statements {
            for r in s.rows { set.insert(r.currency.isEmpty ? s.currency : r.currency) }
        }
        return set.sorted()
    }

    /// Deterministic answer first (FinanceRouter); nil means "defer to MLX".
    func deterministicAnswer(_ question: String) -> String? {
        let rows = mergedRows
        guard !rows.isEmpty else { return nil }
        let fmt = moneyFormatter(primaryCurrency)
        guard var answer = FinanceRouter.answer(question, rows: rows, currency: primaryCurrency,
                                                accounts: accounts, money: fmt) else { return nil }
        let currencies = loadedCurrencies
        if currencies.count > 1 {
            answer += "\n\n⚠️ Your statements use different currencies (\(currencies.joined(separator: ", "))) — combined figures mix them. For exact numbers, load one currency at a time."
        }
        return answer
    }

    /// On-device answer, grounded in a compact text rendering of the rows.
    /// Returns the text plus the engine that actually produced it ("apple"/"mlx") —
    /// previously the caller guessed from loaded-state and badged Apple answers as MLX.
    func mlxAnswer(_ question: String) async throws -> (answer: String, engine: String) {
        let text = statementDigest()
        final class EngineBox: @unchecked Sendable { var name = "mlx" }
        let box = EngineBox()
        let answer = try await llm.ask(question: question, statementText: text,
                                       onEngine: { box.name = $0 }, onToken: { _ in })
        return (answer, box.name)
    }

    // ---- model ----

    /// Plain `swift build` can't compile MLX's Metal shaders; initializing MLX then
    /// aborts the whole process from C++ (uncatchable — the server just dies mid-
    /// request). Detect the missing metallib up front and fail with instructions.
    private static func metallibMissingMessage() -> String? {
        guard let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let lib = exeDir.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
        if FileManager.default.fileExists(atPath: lib.path) { return nil }
        return "MLX Metal shader library missing next to the binary. Launch via run-penny-web.sh (it installs it), or build the Xcode app once and copy mlx-swift_Cmlx.bundle into .build/debug/."
    }

    func startModelLoad() {
        guard !model.loading && !model.loaded else { return }
        if let missing = Self.metallibMissingMessage() {
            model.error = missing
            ServerLog.shared.log("model", "ERROR: \(missing)")
            return
        }
        model.loading = true
        model.error = nil
        ServerLog.shared.log("model", "load started: \(model.id)")
        Task {
            do {
                _ = try await llm.load(onProgress: { p in
                    Task { await self.setProgress(p.fraction) }
                })
                await self.finishLoad(ok: true, error: nil)
            } catch {
                await self.finishLoad(ok: false, error: error.localizedDescription)
            }
        }
    }
    private func setProgress(_ f: Double) { model.progress = f }
    private func finishLoad(ok: Bool, error: String?) {
        model.loading = false; model.loaded = ok; model.error = error
        if ok { model.progress = 1 }
        ServerLog.shared.log("model", ok ? "load finished: \(model.id)"
                                         : "ERROR: load failed: \(error ?? "unknown")")
    }

    // ---- rendering helpers ----

    /// Compact text table of every row — the grounding the MLX model reads.
    private func statementDigest() -> String {
        // Without the currency line the model guesses (usually "$") — wrong for ₹/£/€ statements.
        var lines = ["All amounts are in \(loadedCurrencies.joined(separator: " and ")) (\(currencySymbol(primaryCurrency))).",
                     "Date | Description | Debit | Credit | Balance | Category"]
        for r in mergedRows.prefix(400) {
            let debit = r.debit == 0 ? "" : String(format: "%.2f", r.debit)
            let credit = r.credit == 0 ? "" : String(format: "%.2f", r.credit)
            let bal = r.balance.map { String(format: "%.2f", $0) } ?? ""
            lines.append("\(r.txnDate) | \(r.descr) | \(debit) | \(credit) | \(bal) | \(r.category)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Money formatting (mirrors the app's currency-symbol mapping)

func currencySymbol(_ code: String) -> String {
    switch code.uppercased() {
    case "GBP": return "£"
    case "INR": return "₹"
    case "EUR": return "€"
    case "USD": return "$"
    default: return code.isEmpty ? "$" : code + " "
    }
}

func moneyFormatter(_ code: String) -> (Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.minimumFractionDigits = 2
    f.maximumFractionDigits = 2
    f.groupingSeparator = ","
    let sym = currencySymbol(code)
    return { amt in sym + (f.string(from: NSNumber(value: amt)) ?? String(format: "%.2f", amt)) }
}

// MARK: - JSON shaping

func rowJSON(_ r: TxnRow) -> [String: Any] {
    [
        "date": r.txnDate, "month": r.month, "description": r.descr,
        "merchant": r.merchant, "category": r.category,
        "debit": r.debit, "credit": r.credit,
        "balance": r.balance as Any? ?? NSNull(),
        "currency": r.currency,
    ]
}

func dashboardJSON(_ engine: PennyEngine) async -> [String: Any] {
    let statements = await engine.statements
    let rows = await engine.mergedRows
    let currency = await engine.primaryCurrency

    let totalSpent = rows.reduce(0) { $0 + $1.debit }
    let totalIncome = rows.filter { $0.category != "Payments" }.reduce(0) { $0 + $1.credit }

    // spend by category
    var byCat: [String: Double] = [:]
    for r in rows where r.debit > 0 { byCat[r.category, default: 0] += r.debit }
    let categories = byCat.sorted { $0.value > $1.value }
        .map { ["category": $0.key, "amount": $0.value] as [String: Any] }

    // spend/income by month
    var monthSpent: [String: Double] = [:], monthIncome: [String: Double] = [:]
    for r in rows {
        if r.debit > 0 { monthSpent[r.month, default: 0] += r.debit }
        if r.credit > 0 && r.category != "Payments" { monthIncome[r.month, default: 0] += r.credit }
    }
    let months = Set(monthSpent.keys).union(monthIncome.keys).sorted()
        .map { ["month": $0, "spent": monthSpent[$0] ?? 0, "income": monthIncome[$0] ?? 0] as [String: Any] }

    // top merchants by spend
    var byMerchant: [String: Double] = [:]
    for r in rows where r.debit > 0 { byMerchant[r.merchant.isEmpty ? r.descr : r.merchant, default: 0] += r.debit }
    let topMerchants = byMerchant.sorted { $0.value > $1.value }.prefix(8)
        .map { ["merchant": $0.key, "amount": $0.value] as [String: Any] }

    // Per-currency totals: summing £ and € into one figure is meaningless, so when
    // statements mix currencies the UI shows one figure per currency instead.
    var curSpent: [String: Double] = [:], curIncome: [String: Double] = [:]
    for r in rows {
        let c = r.currency.isEmpty ? currency : r.currency
        if r.debit > 0 { curSpent[c, default: 0] += r.debit }
        if r.credit > 0 && r.category != "Payments" { curIncome[c, default: 0] += r.credit }
    }
    let byCurrency = Set(curSpent.keys).union(curIncome.keys).sorted()
        .map { c -> [String: Any] in
            let spent = curSpent[c] ?? 0, income = curIncome[c] ?? 0
            return ["currency": c, "symbol": currencySymbol(c),
                    "spent": spent, "income": income, "net": income - spent]
        }

    return [
        "currency": currency,
        "symbol": currencySymbol(currency),
        "totals": [
            "spent": totalSpent, "income": totalIncome,
            "net": totalIncome - totalSpent, "count": rows.count,
        ],
        "byCurrency": byCurrency,
        "statements": statements.map {
            [
                "name": $0.name, "bank": $0.bankName as Any? ?? NSNull(),
                "currency": $0.currency, "isCard": $0.isCard,
                "closingBalance": $0.closingBalance as Any? ?? NSNull(),
                "count": $0.rows.count,
            ] as [String: Any]
        },
        "categories": categories,
        "months": months,
        "topMerchants": topMerchants,
        "transactions": rows.suffix(500).map(rowJSON),
    ]
}

func modelJSON(_ m: ModelState) -> [String: Any] {
    // `systemAvailable`: Apple's on-device system model (FoundationModels) is ready,
    // so chat works with no MLX download — the UI advertises this and drops the
    // "load the model first" gate. See AppleFoundationLLM / WWDC26-326.
    ["id": m.id, "loaded": m.loaded, "loading": m.loading,
     "progress": m.progress, "error": m.error as Any? ?? NSNull(),
     "systemAvailable": PennyLLM.systemModelAvailable]
}

// MARK: - Routing

func handle(_ req: HTTPRequest, engine: PennyEngine, indexHTML: Data) async -> HTTPResponse {
    if req.method == "OPTIONS" { return HTTPResponse(status: 204) }

    switch (req.method, req.path) {
    case ("GET", "/"), ("GET", "/index.html"):
        return .html(indexHTML)

    case ("GET", "/api/health"):
        return .json(200, ["status": "ok", "engine": "swift+mlx"])

    case ("GET", "/api/state"):
        let dash = await dashboardJSON(engine)
        let model = modelJSON(await engine.model)
        return .json(200, ["dashboard": dash, "model": model])

    case ("GET", "/api/dashboard"):
        return .json(200, await dashboardJSON(engine))

    case ("GET", "/api/model"):
        return .json(200, modelJSON(await engine.model))

    case ("POST", "/api/model/load"):
        await engine.startModelLoad()
        return .json(200, modelJSON(await engine.model))

    case ("POST", "/api/reset"):
        await engine.reset()
        await ServerLog.shared.write("session", "reset — all statements cleared")
        return .json(200, ["ok": true])

    case ("POST", "/api/parse"):
        let filename = req.header("X-Filename") ?? "statement.pdf"
        guard !req.body.isEmpty else {
            await ServerLog.shared.write("parse", "rejected \(filename): empty body")
            return .json(400, ["error": "empty body"])
        }
        do {
            let stmt = try await engine.ingest(data: req.body, filename: filename)
            await ServerLog.shared.write("parse",
                "\(filename) → \(stmt.rows.count) rows (\(stmt.bankName ?? "unknown bank"), \(stmt.currency))")
            let dash = await dashboardJSON(engine)
            return .json(200, [
                "ok": true,
                "statement": [
                    "name": stmt.name, "bank": stmt.bankName as Any? ?? NSNull(),
                    "currency": stmt.currency, "isCard": stmt.isCard,
                    "count": stmt.rows.count,
                ] as [String: Any],
                "dashboard": dash,
            ])
        } catch let error as IngestUserError {
            await ServerLog.shared.write("parse", "rejected \(filename): \(error.message)")
            return .json(400, ["error": error.message])
        } catch {
            await ServerLog.shared.write("parse", "ERROR: \(filename) failed: \(error.localizedDescription)")
            return .json(500, ["error": "parse failed: \(error.localizedDescription)"])
        }

    case ("POST", "/api/chat"):
        guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let question = obj["question"] as? String, !question.isEmpty else {
            await ServerLog.shared.write("chat", "rejected request: missing question")
            return .json(400, ["error": "missing question"])
        }
        // Short id ties this question to its answer if requests overlap in the log.
        let chatID = "chat #" + String(UUID().uuidString.prefix(4))
        await ServerLog.shared.write(chatID, "Q: \(question)")
        if (await engine.mergedRows).isEmpty {
            let answer = "Upload a statement first, then ask me about it."
            await ServerLog.shared.write(chatID, "A (none): \(answer)")
            return .json(200, ["answer": answer, "engine": "none"])
        }
        // 1) deterministic router
        if let det = await engine.deterministicAnswer(question) {
            await ServerLog.shared.write(chatID, "A (deterministic): \(det)")
            return .json(200, ["answer": det, "engine": "deterministic"])
        }
        // 2) on-device model fallback — Apple's system model (no download) if the
        //    machine has Apple Intelligence, else the MLX model once it's loaded.
        let model = await engine.model
        guard model.loaded || PennyLLM.systemModelAvailable else {
            let answer = "That one needs the on-device model. Click **Load on-device model (MLX)** and try again."
            await ServerLog.shared.write(chatID, "A (needs-model): \(answer)")
            return .json(200, ["answer": answer, "engine": "needs-model"])
        }
        do {
            let (ans, engineName) = try await engine.mlxAnswer(question)
            await ServerLog.shared.write(chatID, "A (\(engineName)): \(ans)")
            return .json(200, ["answer": ans, "engine": engineName])
        } catch {
            await ServerLog.shared.write(chatID, "ERROR: on-device model failed: \(error.localizedDescription)")
            return .json(500, ["error": "on-device model failed: \(error.localizedDescription)"])
        }

    default:
        return .text(404, "Not Found")
    }
}

// MARK: - Bootstrap

let port: UInt16 = UInt16(ProcessInfo.processInfo.environment["PENNY_PORT"] ?? "8088") ?? 8088

guard let indexURL = Bundle.module.url(forResource: "index", withExtension: "html"),
      let indexHTML = try? Data(contentsOf: indexURL) else {
    FileHandle.standardError.write(Data("fatal: index.html missing from bundle\n".utf8))
    exit(1)
}

let engine: PennyEngine
do {
    engine = try PennyEngine()
} catch {
    FileHandle.standardError.write(Data("fatal: \(error.localizedDescription)\n".utf8))
    exit(1)
}

// Held for the program's lifetime — a local inside a `do` block would deallocate
// before RunLoop.run(), leaving a dead listener that accepts connections but drops them.
let server: HTTPServer
do {
    server = try HTTPServer(port: port) { req in
        await handle(req, engine: engine, indexHTML: indexHTML)
    }
    server.start()
    ServerLog.shared.log("server", "🟢 Penny web server on http://127.0.0.1:\(port)  (Swift + MLX, on-device)\nlogging to \(ServerLog.shared.fileURL.path)")
    FileHandle.standardError.write(Data("   Open that URL in your browser. Ctrl-C to stop.\n".utf8))
} catch {
    FileHandle.standardError.write(Data("fatal: could not start server: \(error.localizedDescription)\n".utf8))
    exit(1)
}

// Keep the process alive.
withExtendedLifetime(server) {
    RunLoop.main.run()
}
