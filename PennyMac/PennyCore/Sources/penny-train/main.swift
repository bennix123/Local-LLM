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
do {
    var a = Array(CommandLine.arguments.dropFirst())
    func take(_ f: String) -> String? {
        guard let i = a.firstIndex(of: f), i + 1 < a.count else { return nil }
        let v = a[i + 1]; a.removeSubrange(i...(i + 1)); return v
    }
    if let m = take("--max"), let n = Int(m) { maxQuestions = n }
    if let s = take("--show"), let n = Int(s) { showFails = n }
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
    if l.contains("how many") || l.contains("count") || l.contains("number of") { return "count" }
    if l.contains(" at ") { return "merchant" }
    if l.contains(" in ") && months.contains(where: { monthName($0).lowercased().split(separator: " ").first.map { l.contains($0) } ?? false }) { return "month" }
    if l.contains("income") || l.contains("came in") || l.contains("earn") || l.contains("receive") || l.contains("credit") { return "income" }
    if l.contains("biggest") || l.contains("largest") || l.contains("highest") || l.contains("most") { return "largest" }
    if l.contains("total") && (l.contains("spend") || l.contains("spent") || l.contains("outgoing") || l.contains("expense")) { return "total" }
    return "category"
}

for qa in qas {
    guard let ans = FinanceRouter.answer(qa.q, rows: rows, currency: currency, accounts: accounts, money: money) else {
        deferred += 1
        continue
    }
    let nums = qa.count ? plainInts(ans) : moneyNumbers(ans)
    if nums.contains(where: { abs($0 - qa.expected) < 0.01 }) {
        pass += 1
    } else {
        wrong += 1
        let k = kind(of: qa.q)
        wrongByKind[k, default: 0] += 1
        if wrongExamples.count < showFails {
            let want = qa.count ? String(Int(qa.expected)) : money(qa.expected)
            wrongExamples.append("  [\(k)] \(qa.q)\n        expected \(want) | got: \(ans.replacingOccurrences(of: "\n", with: " / "))")
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
