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

struct Statement {
    let name: String
    let bankName: String?
    let currency: String
    let isCard: Bool
    let closingBalance: Double?
    let rows: [TxnRow]
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
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + filename)
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let out: IngestOutput = (ext == "csv")
            ? try ingester.ingestCSV(path: tmp.path)
            : try ingester.ingestPDF(path: tmp.path)

        let stmt = Statement(name: filename,
                             bankName: out.bankName,
                             currency: out.detectedCurrency.isEmpty ? "GBP" : out.detectedCurrency,
                             isCard: out.isCard,
                             closingBalance: out.closingBalance,
                             rows: out.rows)
        statements.append(stmt)
        return stmt
    }

    // ---- chat ----

    /// Deterministic answer first (FinanceRouter); nil means "defer to MLX".
    func deterministicAnswer(_ question: String) -> String? {
        let rows = mergedRows
        guard !rows.isEmpty else { return nil }
        let fmt = moneyFormatter(primaryCurrency)
        return FinanceRouter.answer(question, rows: rows, currency: primaryCurrency,
                                    accounts: accounts, money: fmt)
    }

    /// On-device MLX answer, grounded in a compact text rendering of the rows.
    func mlxAnswer(_ question: String) async throws -> String {
        let text = statementDigest()
        return try await llm.ask(question: question, statementText: text, onToken: { _ in })
    }

    // ---- model ----

    func startModelLoad() {
        guard !model.loading && !model.loaded else { return }
        model.loading = true
        model.error = nil
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
    }

    // ---- rendering helpers ----

    /// Compact text table of every row — the grounding the MLX model reads.
    private func statementDigest() -> String {
        var lines = ["Date | Description | Debit | Credit | Balance | Category"]
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

    return [
        "currency": currency,
        "symbol": currencySymbol(currency),
        "totals": [
            "spent": totalSpent, "income": totalIncome,
            "net": totalIncome - totalSpent, "count": rows.count,
        ],
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
    ["id": m.id, "loaded": m.loaded, "loading": m.loading,
     "progress": m.progress, "error": m.error as Any? ?? NSNull()]
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
        return .json(200, ["ok": true])

    case ("POST", "/api/parse"):
        let filename = req.header("X-Filename") ?? "statement.pdf"
        guard !req.body.isEmpty else { return .json(400, ["error": "empty body"]) }
        do {
            let stmt = try await engine.ingest(data: req.body, filename: filename)
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
        } catch {
            return .json(500, ["error": "parse failed: \(error.localizedDescription)"])
        }

    case ("POST", "/api/chat"):
        guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let question = obj["question"] as? String, !question.isEmpty else {
            return .json(400, ["error": "missing question"])
        }
        if (await engine.mergedRows).isEmpty {
            return .json(200, ["answer": "Upload a statement first, then ask me about it.",
                               "engine": "none"])
        }
        // 1) deterministic router
        if let det = await engine.deterministicAnswer(question) {
            return .json(200, ["answer": det, "engine": "deterministic"])
        }
        // 2) on-device MLX fallback
        let model = await engine.model
        guard model.loaded else {
            return .json(200, [
                "answer": "That one needs the on-device model. Click **Load on-device model (MLX)** and try again.",
                "engine": "needs-model",
            ])
        }
        do {
            let ans = try await engine.mlxAnswer(question)
            return .json(200, ["answer": ans, "engine": "mlx"])
        } catch {
            return .json(500, ["error": "mlx failed: \(error.localizedDescription)"])
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
    FileHandle.standardError.write(Data("🟢 Penny web server on http://127.0.0.1:\(port)  (Swift + MLX, on-device)\n".utf8))
    FileHandle.standardError.write(Data("   Open that URL in your browser. Ctrl-C to stop.\n".utf8))
} catch {
    FileHandle.standardError.write(Data("fatal: could not start server: \(error.localizedDescription)\n".utf8))
    exit(1)
}

// Keep the process alive.
withExtendedLifetime(server) {
    RunLoop.main.run()
}
