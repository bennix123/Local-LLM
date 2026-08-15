import Foundation
import PennyTxnStore

// penny-train — eval-driven hardening of Penny's deterministic chat router.
//
//   parse a statement → compute ground truth from the rows → generate thousands
//   of user-style questions → run each through FinanceRouter → report every wrong
//   answer, grouped by kind, so the router can be fixed (the "training" loop).
//
// Usage: penny-train [statement.pdf] [--max N] [--show N]

// MARK: - Args

var pdfPath = "/Users/shivduttchauhan/Desktop/Acct Statement_XX2635_04032025.pdf"
var maxQuestions = 10_000
var showFails = 60
var emitDir: String? = nil   // --emit <dir>: write the grounded Q&A dataset, eval report, and failures
do {
    var a = Array(CommandLine.arguments.dropFirst())
    func take(_ f: String) -> String? {
        guard let i = a.firstIndex(of: f), i + 1 < a.count else { return nil }
        let v = a[i + 1]; a.removeSubrange(i...(i + 1)); return v
    }
    if let m = take("--max"), let n = Int(m) { maxQuestions = n }
    if let s = take("--show"), let n = Int(s) { showFails = n }
    if let e = take("--emit") { emitDir = e }
    if let p = a.first(where: { !$0.hasPrefix("-") }) { pdfPath = p }
}

// MARK: - Parse

guard let categories = Bundle.module.url(forResource: "categories", withExtension: "json")?.path else {
    FileHandle.standardError.write(Data("categories.json missing\n".utf8)); exit(1)
}
let profiles = Bundle.module.url(forResource: "bank_profiles", withExtension: nil)?.path ?? ""
let ingester = try TxnIngester(categoriesJSONPath: categories, bankProfilesDir: profiles)
let out = try ingester.ingestPDF(path: pdfPath)
let rows = out.rows
let currency = out.detectedCurrency.isEmpty ? "INR" : out.detectedCurrency
guard !rows.isEmpty else { print("No transactions parsed from \(pdfPath)"); exit(1) }

let mf = NumberFormatter()
mf.numberStyle = .decimal; mf.minimumFractionDigits = 2; mf.maximumFractionDigits = 2; mf.groupingSeparator = ","
let symbol = ["INR": "₹", "GBP": "£", "USD": "$", "EUR": "€"][currency] ?? (currency + " ")
let money: (Double) -> String = { symbol + (mf.string(from: NSNumber(value: $0)) ?? String(format: "%.2f", $0)) }
let accounts = [FinanceRouter.AccountBalance(name: out.bankName ?? "Account",
                                             balance: out.closingBalance, isCard: out.isCard)]

print("📄 \(URL(fileURLWithPath: pdfPath).lastPathComponent) — \(rows.count) transactions · \(currency) · \(out.bankName ?? "?")")

// MARK: - Ground truth

let debits = rows.filter { $0.debit > 0 }
let totalSpent = debits.reduce(0) { $0 + $1.debit }
let totalIncome = rows.filter { $0.credit > 0 && $0.category != "Payments" }.reduce(0) { $0 + $1.credit }
let largestExpense = debits.map(\.debit).max() ?? 0

var byCat: [String: Double] = [:]; var byCatCount: [String: Int] = [:]
for r in debits { byCat[r.category, default: 0] += r.debit; byCatCount[r.category, default: 0] += 1 }

var byMerch: [String: Double] = [:], byMerchCredit: [String: Double] = [:]
for r in debits { let m = r.merchant.isEmpty ? r.descr : r.merchant; byMerch[m, default: 0] += r.debit }
for r in rows where r.credit > 0 { let m = r.merchant.isEmpty ? r.descr : r.merchant; byMerchCredit[m, default: 0] += r.credit }

var monthSpent: [String: Double] = [:], monthCount: [String: Int] = [:]
for r in debits { monthSpent[r.month, default: 0] += r.debit }
for r in rows { monthCount[r.month, default: 0] += 1 }   // ALL rows — matches the router's month count

let monthName: (String) -> String = { ym in
    let parts = ym.split(separator: "-")
    guard parts.count == 2, let mo = Int(parts[1]) else { return ym }
    let names = ["", "January", "February", "March", "April", "May", "June",
                 "July", "August", "September", "October", "November", "December"]
    return "\(names[safe: mo] ?? ym) \(parts[0])"
}
extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

// A merchant is "askable" (a realistic thing a user names) when its name is
// clean prose — not a cryptic UPI/ref blob, not income-dominant (so "spend at X"
// makes sense), and not colliding with a category word (which the router would,
// correctly, read as the category rather than the merchant).
let categoryWords = Set(byCat.keys.map { $0.lowercased() })
func askable(_ m: String) -> Bool {
    let low = m.lowercased()
    let letters = m.filter { $0.isLetter }.count
    let digits = m.filter { $0.isNumber }.count
    guard m.count >= 4, letters >= 4, digits <= 2 else { return false }
    guard !m.contains("@"), !low.hasPrefix("upi-") else { return false }
    // income-dominant (salary/refunds) — "spend at" is the wrong frame
    if (byMerchCredit[m] ?? 0) > (byMerch[m] ?? 0) { return false }
    // collides with a category name → ambiguous by construction
    if low.split(separator: " ").contains(where: { categoryWords.contains(String($0)) }) { return false }
    return true
}
let topMerchants = byMerch.filter { askable($0.key) }.sorted { $0.value > $1.value }.prefix(150).map(\.key)
let months = monthSpent.keys.sorted()

// MARK: - Question generation

struct QA { let q: String; let expected: Double; let count: Bool }
var qas: [QA] = []
func add(_ q: String, _ expected: Double, count: Bool = false) { qas.append(QA(q: q, expected: expected, count: count)) }

func spendPhrasings(_ e: String) -> [String] {
    ["how much did I spend on \(e)?", "how much have I spent on \(e)?", "what did I spend on \(e)?",
     "total spent on \(e)?", "how much on \(e)?", "\(e) spending", "my \(e) spend",
     "how much money did I spend on \(e)?", "spending on \(e)", "what's my total for \(e)?",
     "how much for \(e)?", "\(e) total", "how much did i pay for \(e)?"]
}
func atMerchant(_ m: String) -> [String] {
    ["how much did I spend at \(m)?", "how much have I spent at \(m)?", "total at \(m)?",
     "how much at \(m)?", "\(m) total", "what did I spend at \(m)?", "spending at \(m)",
     "how much money went to \(m)?"]
}

// 1) Global totals — many phrasings each.
for p in ["how much did I spend?", "how much did I spend in total?", "what's my total spending?",
          "total spent", "how much have I spent overall?", "what did I spend altogether?",
          "sum of my spending", "how much money did I spend?", "my total outgoings",
          "how much went out?", "total debits", "what are my total expenses?"] { add(p, totalSpent) }
for p in ["how much money came in?", "what's my total income?", "how much did I earn?",
          "total income", "how much did I receive?", "sum of my income", "money received",
          "how much came into my account?", "total credits", "what did I bring in?"] { add(p, totalIncome) }
for p in ["what's my biggest expense?", "what is my largest expense?", "biggest single spend",
          "what's the largest transaction?", "my biggest purchase", "largest debit",
          "what did I spend the most on in one go?", "highest expense"] { add(p, largestExpense) }
for p in ["how many transactions are there?", "how many transactions?", "count my transactions",
          "number of transactions", "how many entries?", "total number of transactions",
          "how many transactions do I have?"] { add(p, Double(rows.count), count: true) }

// 2) Per category (spend + count).
for (cat, amt) in byCat where amt > 0 {
    for q in spendPhrasings(cat) { add(q, amt) }
    for q in ["how many \(cat) transactions?", "how many times did I spend on \(cat)?",
              "number of \(cat) transactions", "\(cat) transaction count"] {
        add(q, Double(byCatCount[cat] ?? 0), count: true)
    }
}

// 3) Per month.
for m in months {
    let nm = monthName(m)
    for q in ["how much did I spend in \(nm)?", "what did I spend in \(nm)?", "total spending in \(nm)?",
              "how much in \(nm)?", "\(nm) spending", "my spend for \(nm)", "how much did i spend during \(nm)?"] {
        add(q, monthSpent[m] ?? 0)
    }
    for q in ["how many transactions in \(nm)?", "number of transactions in \(nm)?", "\(nm) transaction count"] {
        add(q, Double(monthCount[m] ?? 0), count: true)
    }
}

// 4) Category × month (adds breadth).
for (cat, _) in byCat {
    for m in months {
        let amt = debits.filter { $0.category == cat && $0.month == m }.reduce(0) { $0 + $1.debit }
        guard amt > 0 else { continue }
        let nm = monthName(m)
        for q in ["how much did I spend on \(cat) in \(nm)?", "\(cat) spending in \(nm)",
                  "what did I spend on \(cat) in \(nm)?", "how much on \(cat) in \(nm)?"] { add(q, amt) }
    }
}

// 5) Per merchant (the long tail — brings the set toward 10k).
for m in topMerchants {
    for q in atMerchant(m) { add(q, byMerch[m] ?? 0) }
}

// 6) Merchant × month (only non-zero combos, for realistic breadth).
for m in topMerchants {
    for mo in months {
        let amt = debits.filter { ($0.merchant.isEmpty ? $0.descr : $0.merchant) == m && $0.month == mo }
            .reduce(0) { $0 + $1.debit }
        guard amt > 0 else { continue }
        let nm = monthName(mo)
        for q in ["how much did I spend at \(m) in \(nm)?", "\(m) spending in \(nm)",
                  "how much at \(m) in \(nm)?"] { add(q, amt) }
    }
}

// ===== ADVANCED question shapes (harder reasoning; numeric ground truth) =====

// 7) Nth-largest / smallest expense.
let sortedDebits = debits.map(\.debit).sorted(by: >)
for (word, idx) in [("2nd", 1), ("second", 1), ("3rd", 2), ("third", 2), ("4th", 3), ("5th", 4)] where idx < sortedDebits.count {
    for q in ["what's my \(word) largest expense?", "\(word) biggest expense", "\(word) largest transaction"] { add(q, sortedDebits[idx]) }
}
if let smallest = debits.map(\.debit).min() {
    for q in ["what's my smallest expense?", "smallest transaction", "cheapest purchase",
              "what was my smallest debit?", "lowest single spend"] { add(q, smallest) }
}

// 8) Largest / smallest / average per category.
for (cat, _) in byCat {
    let ds = debits.filter { $0.category == cat }.map(\.debit)
    guard !ds.isEmpty else { continue }
    if let mx = ds.max() { for q in ["what's my biggest \(cat) expense?", "largest \(cat) charge", "most expensive \(cat) transaction"] { add(q, mx) } }
    if let mn = ds.min() { for q in ["smallest \(cat) expense", "cheapest \(cat) charge"] { add(q, mn) } }
    let avg = ds.reduce(0, +) / Double(ds.count)
    for q in ["average \(cat) spend", "what's my average \(cat) transaction?", "mean \(cat) spend"] { add(q, avg) }
}

// 9) Largest per month.
for m in months {
    guard let mx = debits.filter({ $0.month == m }).map(\.debit).max() else { continue }
    let nm = monthName(m)
    for q in ["what's my biggest expense in \(nm)?", "largest transaction in \(nm)", "most expensive purchase in \(nm)"] { add(q, mx) }
}

// 10) Overall average transaction.
if !debits.isEmpty {
    let avg = totalSpent / Double(debits.count)
    for q in ["what's my average transaction?", "average spend per transaction", "mean transaction amount", "on average how much do I spend?"] { add(q, avg) }
}

// 11) Threshold counts.
for t in [5.0, 10.0, 20.0, 50.0, 100.0] {
    let n = debits.filter { $0.debit > t }.count
    guard n > 0 else { continue }
    for q in ["how many transactions over \(money(t))?", "how many purchases above \(money(t))?",
              "number of transactions greater than \(money(t))"] { add(q, Double(n), count: true) }
}

// 12) Date-range totals + counts — the large combinatorial advanced set.
let distinctDates = Array(Set(rows.map(\.txnDate))).sorted()
func humanDate(_ iso: String) -> String {
    let p = iso.split(separator: "-")
    guard p.count == 3, let mo = Int(p[1]), let d = Int(p[2]) else { return iso }
    let names = ["", "January", "February", "March", "April", "May", "June",
                 "July", "August", "September", "October", "November", "December"]
    return "\(d) \(names[safe: mo] ?? "")"
}
for i in 0..<distinctDates.count {
    for j in (i + 1)..<distinctDates.count {
        let d1 = distinctDates[i], d2 = distinctDates[j]
        let sum = debits.filter { $0.txnDate >= d1 && $0.txnDate <= d2 }.reduce(0) { $0 + $1.debit }
        let cnt = rows.filter { $0.txnDate >= d1 && $0.txnDate <= d2 }.count
        let h1 = humanDate(d1), h2 = humanDate(d2)
        if sum > 0 {
            for q in ["how much did I spend between \(h1) and \(h2)?",
                      "total spend from \(h1) to \(h2)", "how much between \(h1) and \(h2)?"] { add(q, sum) }
        }
        for q in ["how many transactions between \(h1) and \(h2)?",
                  "number of transactions from \(h1) to \(h2)"] { add(q, Double(cnt), count: true) }
    }
}

// Trim to the requested budget.
if qas.count > maxQuestions { qas = Array(qas.prefix(maxQuestions)) }

// MARK: - Number extraction

func moneyNumbers(_ s: String) -> [Double] {
    let rx = try! NSRegularExpression(pattern: "[₹£$€]\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)")
    return rx.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
        guard let r = Range($0.range(at: 1), in: s) else { return nil }
        return Double(s[r].replacingOccurrences(of: ",", with: ""))
    }
}
func plainInts(_ s: String) -> [Double] {
    // integers NOT preceded by a currency symbol (so counts, not amounts)
    let stripped = s.replacingOccurrences(of: "[₹£$€]\\s*[0-9][0-9,]*(?:\\.[0-9]+)?",
                                          with: " ", options: .regularExpression)
    let rx = try! NSRegularExpression(pattern: "\\b([0-9][0-9,]*)\\b")
    return rx.matches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)).compactMap {
        guard let r = Range($0.range(at: 1), in: stripped) else { return nil }
        return Double(stripped[r].replacingOccurrences(of: ",", with: ""))
    }
}

// MARK: - Evaluate

var pass = 0, wrong = 0, deferred = 0
var wrongByKind: [String: Int] = [:]
var wrongExamples: [String] = []

func kind(of q: String) -> String {
    let l = q.lowercased()
    // advanced shapes first (they contain words the basic buckets also match)
    if l.contains("between ") || (l.contains(" from ") && l.contains(" to ")) { return "date-range" }
    if l.contains("over ") || l.contains("above ") || l.contains("greater than") { return "threshold" }
    if l.contains("average") || l.contains("mean ") { return "average" }
    if l.contains("smallest") || l.contains("cheapest") || l.contains("lowest") { return "smallest" }
    if ["2nd", "3rd", "4th", "5th", "second", "third", "fourth", "fifth"].contains(where: l.contains) { return "nth-largest" }
    if l.contains("how many") || l.contains("count") || l.contains("number of") { return "count" }
    if l.contains(" at ") { return "merchant" }
    if l.contains(" in ") && months.contains(where: { monthName($0).lowercased().split(separator: " ").first.map { l.contains($0) } ?? false }) { return "month" }
    if l.contains("income") || l.contains("came in") || l.contains("earn") || l.contains("receive") || l.contains("credit") { return "income" }
    if l.contains("biggest") || l.contains("largest") || l.contains("highest") || l.contains("most") { return "largest" }
    if l.contains("total") && (l.contains("spend") || l.contains("spent") || l.contains("outgoing") || l.contains("expense")) { return "total" }
    return "category"
}

// Per-question evaluation records (drives both the console report and --emit artifacts).
struct EvalRecord {
    let id: Int; let q: String; let kind: String
    let expected: Double; let isCount: Bool
    let groundTruth: String            // the deterministic answer string ("£11.98" / "12")
    let modelAnswer: String?           // router reply, nil = deferred to the LLM
    let status: String                 // "correct" | "wrong" | "deferred"
}
var records: [EvalRecord] = []
var passByKind: [String: Int] = [:], totalByKind: [String: Int] = [:]

for (i, qa) in qas.enumerated() {
    let k = kind(of: qa.q)
    let gt = qa.count ? String(Int(qa.expected)) : money(qa.expected)
    totalByKind[k, default: 0] += 1
    guard let ans = FinanceRouter.answer(qa.q, rows: rows, currency: currency, accounts: accounts, money: money) else {
        deferred += 1
        records.append(EvalRecord(id: i + 1, q: qa.q, kind: k, expected: qa.expected,
                                  isCount: qa.count, groundTruth: gt, modelAnswer: nil, status: "deferred"))
        continue
    }
    let nums = qa.count ? plainInts(ans) : moneyNumbers(ans)
    if nums.contains(where: { abs($0 - qa.expected) < 0.01 }) {
        pass += 1; passByKind[k, default: 0] += 1
        records.append(EvalRecord(id: i + 1, q: qa.q, kind: k, expected: qa.expected,
                                  isCount: qa.count, groundTruth: gt, modelAnswer: ans, status: "correct"))
    } else {
        wrong += 1
        wrongByKind[k, default: 0] += 1
        records.append(EvalRecord(id: i + 1, q: qa.q, kind: k, expected: qa.expected,
                                  isCount: qa.count, groundTruth: gt, modelAnswer: ans, status: "wrong"))
        if wrongExamples.count < showFails {
            wrongExamples.append("  [\(k)] \(qa.q)\n        expected \(gt) | got: \(ans.replacingOccurrences(of: "\n", with: " / "))")
        }
    }
}

// MARK: - Report

let answered = pass + wrong
let acc = answered > 0 ? Double(pass) / Double(answered) * 100 : 0
print("""

════════════════════════════════════════════════════════
  penny-train — \(qas.count) questions
────────────────────────────────────────────────────────
  ✅ correct      \(pass)
  ❌ wrong        \(wrong)
  ⏭  deferred     \(deferred)  (router returned nil → on-device LLM)
  ── accuracy on answered: \(String(format: "%.2f", acc))%   coverage: \(String(format: "%.1f", Double(answered) / Double(qas.count) * 100))%
════════════════════════════════════════════════════════
""")
if !wrongByKind.isEmpty {
    print("  wrong answers by kind:")
    for (k, n) in wrongByKind.sorted(by: { $0.value > $1.value }) { print("    \(k): \(n)") }
    print("\n  sample failures:")
    for e in wrongExamples { print(e) }
}

// MARK: - Emit deliverable artifacts (--emit <dir>)

if let dir = emitDir {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let source = URL(fileURLWithPath: pdfPath).lastPathComponent
    let stem = URL(fileURLWithPath: pdfPath).deletingPathExtension().lastPathComponent
        .replacingOccurrences(of: " ", with: "_")

    func write(_ name: String, _ content: String) {
        let p = (dir as NSString).appendingPathComponent(name)
        try? content.write(toFile: p, atomically: true, encoding: .utf8)
        print("  · wrote \(name) (\(content.utf8.count) bytes)")
    }
    func jline(_ o: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // 1) full grounded dataset (JSONL + Markdown). `answer`/`ground_truth` is the
    //    deterministic figure computed from the parsed rows — the source of truth.
    var jsonl = "", md = "# \(source) — grounded Q&A dataset (\(records.count) pairs)\n\n"
    md += "Every answer is computed deterministically from the parsed statement rows "
    md += "(not model-generated). `category` is the question shape.\n\n"
    for r in records {
        jsonl += jline(["id": r.id, "question": r.q, "answer": r.groundTruth,
                        "category": r.kind, "source": source,
                        "ground_truth": r.groundTruth, "expected": r.expected, "is_count": r.isCount]) + "\n"
        md += "## Question \(String(format: "%05d", r.id))\n\n**Q:** \(r.q)\n\n**A:** \(r.groundTruth)  _(\(r.kind))_\n\n---\n\n"
    }
    write("\(stem)_qa.jsonl", jsonl)
    write("\(stem)_qa.md", md)

    // 2) fixed held-out test split — deterministic 15% by id, for tracking accuracy
    //    across iterations. (Informational: the engine is rule-based, not trained.)
    let test = records.filter { $0.id % 100 < 15 }
    write("\(stem)_test_set.jsonl",
          test.map { jline(["id": $0.id, "question": $0.q, "answer": $0.groundTruth,
                            "category": $0.kind, "source": source]) }.joined(separator: "\n") + "\n")

    // 3) failures (JSONL + Markdown) — the hardening backlog
    let fails = records.filter { $0.status == "wrong" }
    var fjsonl = "", fmd = "# \(source) — failed questions (\(fails.count))\n\n"
    for r in fails {
        fjsonl += jline(["question": r.q, "expected_answer": r.groundTruth,
                         "model_answer": r.modelAnswer ?? "", "category": r.kind,
                         "error_type": "wrong_\(r.kind)"]) + "\n"
        fmd += "- **\(r.q)**\n  - expected: \(r.groundTruth)\n  - got: "
             + "\((r.modelAnswer ?? "").replacingOccurrences(of: "\n", with: " / "))\n  - kind: \(r.kind)\n\n"
    }
    write("failed_questions.jsonl", fjsonl.isEmpty ? "" : fjsonl)
    write("failed_questions.md", fails.isEmpty ? "# \(source) — no failures 🎉\n" : fmd)

    // 4) evaluation report
    var rep = "# \(source) — Evaluation Report (Penny deterministic engine)\n\n"
    rep += "- Source: `\(source)` · transactions: \(rows.count) · currency: \(currency) · issuer: \(out.bankName ?? "?")\n"
    rep += "- Engine: `FinanceRouter` (deterministic, no MLX)\n\n"
    rep += "| Metric | Value |\n|---|---|\n"
    rep += "| Total questions | \(qas.count) |\n| Answered | \(answered) |\n| Correct | \(pass) |\n"
    rep += "| Wrong | \(wrong) |\n| Deferred to on-device LLM | \(deferred) |\n"
    rep += "| **Accuracy (answered)** | **\(String(format: "%.2f", acc))%** |\n"
    rep += "| Coverage | \(String(format: "%.1f", Double(answered)/Double(max(1, qas.count))*100))% |\n\n"
    rep += "## Accuracy by category\n\n| Category | Correct | Total | Accuracy |\n|---|--:|--:|--:|\n"
    for k in totalByKind.keys.sorted() {
        let c = passByKind[k] ?? 0, t = totalByKind[k] ?? 0
        rep += "| \(k) | \(c) | \(t) | \(String(format: "%.1f", t > 0 ? Double(c)/Double(t)*100 : 0))% |\n"
    }
    let weakest = totalByKind.keys.map { k -> (String, Double) in
        let c = passByKind[k] ?? 0, t = totalByKind[k] ?? 0
        return (k, t > 0 ? Double(c)/Double(t)*100 : 0)
    }.sorted { $0.1 < $1.1 }.prefix(3).map { "\($0.0) (\(String(format: "%.1f", $0.1))%)" }
    rep += "\n**Weakest categories:** \(weakest.isEmpty ? "none" : weakest.joined(separator: ", "))\n"
    write("evaluation_report.md", rep)
}
