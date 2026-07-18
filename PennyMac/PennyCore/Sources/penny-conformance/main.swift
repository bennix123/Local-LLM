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

default:
    fail("unknown subcommand: \(cmd)")
}
