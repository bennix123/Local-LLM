// penny-conformance — contract conformance runner + extraction debug dumps.
//
// Subcommands:
//   dump-words <pdf>          JSON: per page, pymupdf-style word tuples
//   dump-text  <pdf>          JSON: per page, get_text("text") string
//   dump-meta  <pdf>          JSON: document Info metadata
//   run [contractDir]         parse fixtures, exact-match *_expected.json
import Foundation
import PennyTxnStore

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fail("usage: penny-conformance <dump-words|dump-text|dump-meta|run> ...")
}

let cmd = args[1]

switch cmd {
case "dump-words":
    guard args.count >= 3 else { fail("usage: penny-conformance dump-words <pdf>") }
    let ex = try PDFTextExtractor(path: args[2])
    var pages: [[[Any]]] = []
    for i in 0..<ex.pageCount {
        guard let pg = ex.page(i) else { pages.append([]); continue }
        pages.append(pg.words.map { [$0.x0, $0.y0, $0.x1, $0.y1, $0.text] })
    }
    let data = try JSONSerialization.data(withJSONObject: pages)
    print(String(data: data, encoding: .utf8)!)

case "dump-text":
    guard args.count >= 3 else { fail("usage: penny-conformance dump-text <pdf>") }
    let ex = try PDFTextExtractor(path: args[2])
    var pages: [String] = []
    for i in 0..<ex.pageCount {
        pages.append(ex.page(i)?.text ?? "")
    }
    let data = try JSONSerialization.data(withJSONObject: pages)
    print(String(data: data, encoding: .utf8)!)

case "dump-meta":
    guard args.count >= 3 else { fail("usage: penny-conformance dump-meta <pdf>") }
    let ex = try PDFTextExtractor(path: args[2])
    let data = try JSONSerialization.data(withJSONObject: ex.metadata)
    print(String(data: data, encoding: .utf8)!)

case "dump-rows":
    // usage: penny-conformance dump-rows <pdf> [contractDir] [bankProfilesDir]
    // Ingests the PDF via the deterministic parser and prints the parsed rows as
    // JSON — the machine-readable input for the pdfplumber cross-validation harness.
    guard args.count >= 3 else { fail("usage: penny-conformance dump-rows <pdf>") }
    let base = "/Users/shivduttchauhan/Desktop/delulu/Penny/finquery"
    let contractDir = args.count > 3 ? args[3] : base + "/contract"
    let profilesDir = args.count > 4 ? args[4] : base + "/backend/src/services/txn_store/bank_profiles"
    let ingester = try TxnIngester(categoriesJSONPath: contractDir + "/categories.json",
                                   bankProfilesDir: profilesDir)
    let out = try ingester.ingestPDF(path: args[2])
    let rows: [[String: Any]] = out.rows.map { r in
        [
            "date": r.txnDate, "descr": r.descr, "merchant": r.merchant,
            "category": r.category, "debit": r.debit, "credit": r.credit,
            "balance": r.balance.map { $0 as Any } ?? NSNull(),
        ]
    }
    let payload: [String: Any] = [
        "bank": out.bankName.map { $0 as Any } ?? NSNull(),
        "currency": out.detectedCurrency, "count": rows.count, "rows": rows,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    print(String(data: data, encoding: .utf8)!)

case "run":
    // usage: penny-conformance run [contractDir] [bankProfilesDir]
    // Defaults resolve relative to the finquery repo layout.
    let contractDir = args.count > 2 ? args[2]
        : "/Users/shivduttchauhan/Desktop/delulu/Penny/finquery/contract"
    let profilesDir = args.count > 3 ? args[3]
        : "/Users/shivduttchauhan/Desktop/delulu/Penny/finquery/backend/src/services/txn_store/bank_profiles"
    let fixturesDir = contractDir + "/fixtures"
    let categoriesPath = contractDir + "/categories.json"

    let ingester = try TxnIngester(categoriesJSONPath: categoriesPath, bankProfilesDir: profilesDir)
    let dbPath = NSTemporaryDirectory() + "penny_conformance_\(getpid()).db"
    defer { try? FileManager.default.removeItem(atPath: dbPath) }
    let db = try TxnDB(path: dbPath)

    let fm = FileManager.default
    let pdfs = (try fm.contentsOfDirectory(atPath: fixturesDir))
        .filter { $0.hasSuffix(".pdf") }
        .sorted()
    if pdfs.isEmpty { fail("No PDF files found in \(fixturesDir)") }

    var allPass = true
    for pdfName in pdfs {
        let pdfPath = fixturesDir + "/" + pdfName
        let expectedPath = fixturesDir + "/" + String(pdfName.dropLast(4)) + "_expected.json"
        print("\nProcessing \(pdfName)...")

        let userID = "conformance_test_\(pdfName)"
        db.deleteUser(userID: userID)
        let output: IngestOutput
        do {
            output = try ingester.ingestPDF(path: pdfPath)
        } catch {
            print("[ERROR] ingest failed: \(error)")
            allPass = false
            continue
        }
        db.insert(rows: output.rows, userID: userID, docName: pdfName, bankName: output.bankName)
        let got = db.conformanceRows(userID: userID)

        guard fm.fileExists(atPath: expectedPath),
              let expData = fm.contents(atPath: expectedPath),
              let expected = (try? JSONSerialization.jsonObject(with: expData)) as? [[String: Any]] else {
            print("[ERROR] Missing/unreadable expected JSON for \(pdfName)")
            allPass = false
            continue
        }

        var mismatches: [String] = []
        if got.count != expected.count {
            mismatches.append("row count: expected \(expected.count), got \(got.count)")
        } else {
            for (i, (g, e)) in zip(got, expected).enumerated() {
                func num(_ v: Any?) -> Double? {
                    if v is NSNull || v == nil { return nil }
                    return (v as? NSNumber)?.doubleValue
                }
                var diffs: [String] = []
                if g.date != (e["date"] as? String ?? "") { diffs.append("date \(g.date) != \(e["date"] ?? "")") }
                if g.description != (e["description"] as? String ?? "") {
                    diffs.append("description \(g.description) != \(e["description"] ?? "")")
                }
                if g.debit != (num(e["debit"]) ?? 0) { diffs.append("debit \(g.debit) != \(e["debit"] ?? "")") }
                if g.credit != (num(e["credit"]) ?? 0) { diffs.append("credit \(g.credit) != \(e["credit"] ?? "")") }
                if g.balance != num(e["balance"]) {
                    diffs.append("balance \(String(describing: g.balance)) != \(e["balance"] ?? "null")")
                }
                if g.category != (e["category"] as? String ?? "") {
                    diffs.append("category \(g.category) != \(e["category"] ?? "")")
                }
                let expBank = e["bank"] is NSNull ? nil : e["bank"] as? String
                if g.bank != expBank {
                    diffs.append("bank \(String(describing: g.bank)) != \(String(describing: expBank))")
                }
                if !diffs.isEmpty, mismatches.count < 6 {
                    mismatches.append("row \(i): " + diffs.joined(separator: "; "))
                }
            }
        }

        if mismatches.isEmpty {
            print("[PASS] \(pdfName) MATCHED perfectly!")
        } else {
            print("[FAIL] \(pdfName) MISMATCHED!")
            for m in mismatches { print("   " + m) }
            allPass = false
        }
    }
    if allPass {
        print("\n[SUCCESS] ALL TESTS PASSED SUCCESSFULLY!")
        exit(0)
    } else {
        print("\n[FAIL] SOME TESTS FAILED!")
        exit(1)
    }

case "query":
    // usage: penny-conformance query <pdf> "<question>"
    // Ingests the PDF, then answers via the deterministic FinanceRouter (no LLM).
    guard args.count >= 4 else { fail("usage: penny-conformance query <pdf> \"<question>\"") }
    let base = "/Users/shivduttchauhan/Desktop/delulu/Penny/finquery"
    let ingester = try TxnIngester(
        categoriesJSONPath: base + "/contract/categories.json",
        bankProfilesDir: base + "/backend/src/services/txn_store/bank_profiles")
    let out = try ingester.ingestPDF(path: args[2])
    let cur = out.detectedCurrency.isEmpty ? "INR" : out.detectedCurrency
    let sym: String = ["INR": "₹", "GBP": "£", "USD": "$", "EUR": "€", "OMR": "﷼"][cur] ?? ""
    let money: (Double) -> String = { String(format: "\(sym)%.2f", $0) }
    print("[ingest] \(out.rows.count) rows · \(cur) · bank=\(out.bankName ?? "?")")
    if let ans = FinanceRouter.answer(args[3], rows: out.rows, currency: cur, money: money) {
        print("[router] \(ans)")
    } else {
        print("[router] (no deterministic match → would fall back to the LLM)")
    }

case "dump-rows":
    // usage: penny-conformance dump-rows <pdf> [limit]
    // Ingests and prints the parsed canonical rows (date | descr | debit | credit | balance | cat).
    guard args.count >= 3 else { fail("usage: penny-conformance dump-rows <pdf> [limit]") }
    let base = "/Users/shivduttchauhan/Desktop/delulu/Penny/finquery"
    let ingester = try TxnIngester(
        categoriesJSONPath: base + "/contract/categories.json",
        bankProfilesDir: base + "/backend/src/services/txn_store/bank_profiles")
    let out = try ingester.ingestPDF(path: args[2])
    let limit = args.count > 3 ? (Int(args[3]) ?? 40) : 40
    print("[dump] \(out.rows.count) rows · \(out.detectedCurrency) · bank=\(out.bankName ?? "?")")
    for r in out.rows.prefix(limit) {
        let dr = r.debit > 0 ? String(format: "%.2f", r.debit) : ""
        let cr = r.credit > 0 ? String(format: "%.2f", r.credit) : ""
        let bal = r.balance.map { String(format: "%.2f", $0) } ?? ""
        print(String(format: "%-11@ | %-38@ | D:%-10@ | C:%-10@ | B:%-11@ | %@",
                     r.txnDate as NSString, String(r.descr.prefix(38)) as NSString,
                     dr as NSString, cr as NSString, bal as NSString, r.category as NSString))
    }

case "rows-json":
    // usage: penny-conformance rows-json <pdf>   -> JSON array for Swift-vs-Python parity
    guard args.count >= 3 else { fail("usage: penny-conformance rows-json <pdf>") }
    let base = "/Users/shivduttchauhan/Desktop/delulu/Penny/finquery"
    let ingester = try TxnIngester(
        categoriesJSONPath: base + "/contract/categories.json",
        bankProfilesDir: base + "/backend/src/services/txn_store/bank_profiles")
    let out = try ingester.ingestPDF(path: args[2])
    let arr: [[String: Any]] = out.rows.map { r in
        [
            "date": r.txnDate, "descr": r.descr,
            "debit": r.debit, "credit": r.credit,
            "balance": r.balance as Any? ?? NSNull(),
            "category": r.category,
        ]
    }
    let data = try JSONSerialization.data(withJSONObject: arr)
    print(String(data: data, encoding: .utf8)!)

case "ingest-meta":
    // usage: penny-conformance ingest-meta <pdf> -> {bank, currency, confidence, isCard, closingBalance, rows}
    guard args.count >= 3 else { fail("usage: penny-conformance ingest-meta <pdf>") }
    let base = "/Users/shivduttchauhan/Desktop/delulu/Penny/finquery"
    let ingester = try TxnIngester(
        categoriesJSONPath: base + "/contract/categories.json",
        bankProfilesDir: base + "/backend/src/services/txn_store/bank_profiles")
    let out = try ingester.ingestPDF(path: args[2])
    let meta: [String: Any] = [
        "bank": out.bankName as Any? ?? NSNull(),
        "currency": out.detectedCurrency,
        "confidence": out.confidence,
        "isCard": out.isCard,
        "closingBalance": out.closingBalance as Any? ?? NSNull(),
        "rows": out.rows.count,
    ]
    print(String(data: try JSONSerialization.data(withJSONObject: meta), encoding: .utf8)!)

case "retrieve":
    // usage: penny-conformance retrieve <pdf> "<query>" [k]
    // Ingests the PDF, then shows the top-k most relevant rows (hybrid RAG).
    guard args.count >= 4 else { fail("usage: penny-conformance retrieve <pdf> \"<query>\" [k]") }
    let base = "/Users/shivduttchauhan/Desktop/delulu/Penny/finquery"
    let ingester = try TxnIngester(
        categoriesJSONPath: base + "/contract/categories.json",
        bankProfilesDir: base + "/backend/src/services/txn_store/bank_profiles")
    let out = try ingester.ingestPDF(path: args[2])
    let k = args.count > 4 ? (Int(args[4]) ?? 8) : 8
    let retriever = TxnRetriever(rows: out.rows)
    let hits = retriever.topK(args[3], k: k)
    print("[retrieve] \(out.rows.count) rows indexed · top \(hits.count) for “\(args[3])”:")
    for (i, r) in hits.enumerated() {
        let amt = r.debit > 0 ? "-\(r.debit)" : "+\(r.credit)"
        print("  \(i + 1). \(r.txnDate) | \(r.descr) | \(r.category) | \(amt) \(r.currency)")
    }

case "battery":
    // usage: penny-conformance battery <pdf> <questionsFile>
    // Ingests ONCE, then answers every question (one per line in the file) via the
    // deterministic FinanceRouter. Emits JSONL: {"q":…, "a":…|null}. `a` null means
    // the router deferred (would fall back to the LLM).
    guard args.count >= 4 else { fail("usage: penny-conformance battery <pdf> <questionsFile>") }
    let base = "/Users/shivduttchauhan/Desktop/delulu/Penny/finquery"
    let ingester = try TxnIngester(
        categoriesJSONPath: base + "/contract/categories.json",
        bankProfilesDir: base + "/backend/src/services/txn_store/bank_profiles")
    let out = try ingester.ingestPDF(path: args[2])
    let cur = out.detectedCurrency.isEmpty ? "INR" : out.detectedCurrency
    let sym: String = ["INR": "₹", "GBP": "£", "USD": "$", "EUR": "€", "OMR": "﷼"][cur] ?? ""
    let money: (Double) -> String = { String(format: "\(sym)%.2f", $0) }
    // Single-account context so card-balance ("you owe") semantics fire, mirroring the app.
    let accounts = [FinanceRouter.AccountBalance(
        name: out.bankName ?? "Card",
        balance: out.closingBalance ?? out.rows.last(where: { $0.balance != nil })?.balance,
        isCard: out.isCard)]
    let qs = (try String(contentsOfFile: args[3], encoding: .utf8))
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    for q in qs {
        let a = FinanceRouter.answer(q, rows: out.rows, currency: cur, accounts: accounts, money: money)
        let obj: [String: Any] = ["q": q, "a": a as Any? ?? NSNull()]
        print(String(data: try JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!)
    }

case "classify":
    // usage: penny-conformance classify <merchantsFile> [categoriesJSON]
    // Runs each line through the deterministic categorizer. Emits JSONL:
    // {"merchant":…, "category":…}. Used to measure merchant→category coverage.
    guard args.count >= 3 else { fail("usage: penny-conformance classify <file> [categoriesJSON]") }
    let catPath = args.count > 3 ? args[3]
        : "/Users/shivduttchauhan/Desktop/delulu/Penny/finquery/contract/categories.json"
    let cats = try Categories(categoriesJSONPath: catPath)
    let lines = (try String(contentsOfFile: args[2], encoding: .utf8))
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    for m in lines {
        let obj: [String: Any] = ["merchant": m, "category": cats.categorize(m)]
        print(String(data: try JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!)
    }

case "ai-mopup":
    // usage: penny-conformance ai-mopup <pdf> [model]
    // Ingests the PDF, finds rows the deterministic engine left as "Other", and
    // classifies those merchants via the Claude API fallback. Needs ANTHROPIC_API_KEY.
    guard args.count >= 3 else { fail("usage: penny-conformance ai-mopup <pdf> [model]") }
    guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
        fail("set ANTHROPIC_API_KEY in the environment")
    }
    let aiModel = args.count > 3 ? args[3] : "claude-opus-4-8"
    let base = "/Users/shivduttchauhan/Desktop/delulu/Penny/finquery"
    let ingester = try TxnIngester(
        categoriesJSONPath: base + "/contract/categories.json",
        bankProfilesDir: base + "/backend/src/services/txn_store/bank_profiles")
    let out = try ingester.ingestPDF(path: args[2])
    let otherRows = out.rows.filter { $0.category == "Other" && $0.debit > 0 }
    let descrs = Array(Set(otherRows.map { $0.descr })).sorted()
    print("[ingest] \(out.rows.count) rows · \(otherRows.count) still 'Other' · \(descrs.count) distinct merchants")
    if descrs.isEmpty { print("Nothing to mop up — deterministic engine covered everything."); exit(0) }
    print("[ai] classifying \(descrs.count) merchants via \(aiModel) …\n")

    let categorizer = ClaudeCategorizer(apiKey: key, model: aiModel)
    let results = try await categorizer.categorize(descriptions: descrs)
    var accepted = 0, logged = 0, kept = 0
    for r in results.sorted(by: { $0.confidence > $1.confidence }) {
        let action: String
        switch r.confidence {
        case 0.90...: action = "✓ ACCEPT   "; accepted += 1
        case 0.70..<0.90: action = "~ accept+log"; logged += 1
        default: action = "· keep Other"; kept += 1
        }
        print(String(format: "  %@  %-18@  %.2f   %@", action as NSString,
                     r.category as NSString, r.confidence, String(r.merchant.prefix(44)) as NSString))
    }
    let moved = accepted + logged
    // How many "Other" rows would leave the bucket (any row whose merchant scored ≥0.70).
    var movedRows = 0
    for row in otherRows {
        let hit = results.first(where: { $0.merchant == row.descr })
        if let hit, hit.confidence >= 0.70 { movedRows += 1 }
    }
    let remaining = max(0, otherRows.count - movedRows)
    print("\n[result] \(moved)/\(descrs.count) merchants confidently categorized "
          + "(\(accepted) accept, \(logged) accept+log, \(kept) keep). "
          + "'Other' rows would drop from \(otherRows.count) to \(remaining).")

case "extract-ai":
    // usage: penny-conformance extract-ai <pdf> [model]
    // Reads each page's text (as OCR would produce for a scanned PDF), runs the
    // Claude LLM-extraction fallback, and compares the row count to the
    // deterministic parser. Needs ANTHROPIC_API_KEY.
    guard args.count >= 3 else { fail("usage: penny-conformance extract-ai <pdf> [model]") }
    guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
        fail("set ANTHROPIC_API_KEY in the environment")
    }
    let exModel = args.count > 3 ? args[3] : "claude-opus-4-8"
    let doc = try PDFTextExtractor(path: args[2])
    var pageTexts: [String] = []
    for i in 0..<doc.pageCount { pageTexts.append(doc.page(i)?.text ?? "") }
    // deterministic baseline for comparison
    let base = "/Users/shivduttchauhan/Desktop/delulu/Penny/finquery"
    let ingester = try TxnIngester(categoriesJSONPath: base + "/contract/categories.json",
                                   bankProfilesDir: base + "/backend/src/services/txn_store/bank_profiles")
    let det = (try? ingester.ingestPDF(path: args[2]))?.rows.filter { $0.debit > 0 || $0.credit > 0 } ?? []
    print("[pages] \(doc.pageCount) · deterministic baseline: \(det.count) transactions")
    print("[ai] extracting via \(exModel) …\n")
    let extractor = ClaudeStatementExtractor(apiKey: key, model: exModel)
    let out = try await extractor.extract(pages: pageTexts, hintCurrency: nil)
    print("[result] \(out.rows.count) transactions · currency \(out.currency) · bank \(out.bank ?? "?") · confidence \(String(format: "%.2f", out.confidence))")
    let dsum = det.reduce(0.0) { $0 + $1.debit }
    let asum = out.rows.reduce(0.0) { $0 + $1.debit }
    print(String(format: "[compare] total debits — deterministic %.2f vs AI %.2f  (Δ %.2f)", dsum, asum, abs(dsum - asum)))
    for r in out.rows.prefix(12) {
        let dr = r.debit > 0 ? String(format: "%.2f", r.debit) : ""
        let cr = r.credit > 0 ? String(format: "%.2f", r.credit) : ""
        print(String(format: "   %-11@ | %-34@ | D:%-9@ | C:%-9@ | %@",
                     r.txnDate as NSString, String(r.descr.prefix(34)) as NSString,
                     dr as NSString, cr as NSString, r.category as NSString))
    }
    if out.rows.count > 12 { print("   … \(out.rows.count - 12) more") }

default:
    fail("unknown subcommand: \(cmd)")
}
