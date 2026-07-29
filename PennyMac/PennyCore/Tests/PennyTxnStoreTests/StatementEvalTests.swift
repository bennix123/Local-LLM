// StatementEvalTests — evaluates FinanceRouter against the Amex Platinum
// statement (16 Feb – 15 Mar 2026): the same data behind the 2000-question
// Q&A set. Ground truth is summed independently in-test from the same rows,
// so any router answer that doesn't contain the correct figure is a real bug.
// "WRONG" (router gave a wrong figure) always fails; "DEFER" (router returned
// nil → the app sends it to the on-device model) fails only for the core
// analytic question types the router is meant to own.
import XCTest
@testable import PennyTxnStore

final class StatementEvalTests: XCTestCase {
    static let gbp: (Double) -> String = { String(format: "£%.2f", $0) }
    static func money(_ v: Double) -> String { String(format: "£%.2f", v) }

    static func r(_ date: String, _ descr: String, merchant: String = "",
                  category: String = "", debit: Double = 0, credit: Double = 0,
                  seq: Int = 0) -> TxnRow {
        let p = date.split(separator: "-").compactMap { Int($0) }
        return TxnRow(txnDate: date, month: String(date.prefix(7)), year: p[0],
                      monthNo: p[1], day: p[2], descr: descr, merchant: merchant,
                      category: category, debit: debit, credit: credit,
                      balance: nil, currency: "GBP", seq: seq)
    }

    static let rows: [TxnRow] = [
        r("2026-02-24", "PAYMENT RECEIVED - THANK YOU", merchant: "", category: "Payments", debit: 0, credit: 1211.84, seq: 1),
        r("2026-02-15", "TFL TRAVEL CHARGE TFL.GOV.UK/CP", merchant: "TfL", category: "Transport", debit: 2.10, credit: 0, seq: 2),
        r("2026-02-16", "CAREDENTALPLATINUM.COM CRAWLEY", merchant: "Care Dental Platinum", category: "Healthcare", debit: 100.00, credit: 0, seq: 3),
        r("2026-02-16", "FOREST LONDON", merchant: "Forest", category: "Transport", debit: 2.99, credit: 0, seq: 4),
        r("2026-02-16", "FOREST LONDON", merchant: "Forest", category: "Transport", debit: 1.00, credit: 0, seq: 5),
        r("2026-02-17", "CARE DENTAL PLATINUM LONDON", merchant: "Care Dental Platinum", category: "Healthcare", debit: 82.00, credit: 0, seq: 6),
        r("2026-02-17", "DOJO*BEEHIVE LONDON", merchant: "Beehive", category: "Food & Dining", debit: 13.60, credit: 0, seq: 7),
        r("2026-02-17", "PRET A MANGER London", merchant: "Pret A Manger", category: "Food & Dining", debit: 7.30, credit: 0, seq: 8),
        r("2026-02-17", "TFL TRAVEL CHARGE TFL.GOV.UK/CP", merchant: "TfL", category: "Transport", debit: 8.90, credit: 0, seq: 9),
        r("2026-02-18", "DOJO*THE CRAFT BEER CO LONDON", merchant: "The Craft Beer Co", category: "Food & Dining", debit: 14.90, credit: 0, seq: 10),
        r("2026-02-18", "TST-BKC - SOHO LONDON", merchant: "BKC Soho", category: "Food & Dining", debit: 40.70, credit: 0, seq: 11),
        r("2026-02-18", "LONDIS LONDON", merchant: "Londis", category: "Groceries", debit: 7.99, credit: 0, seq: 12),
        r("2026-02-18", "TFL TRAVEL CHARGE TFL.GOV.UK/CP", merchant: "TfL", category: "Transport", debit: 5.80, credit: 0, seq: 13),
        r("2026-02-19", "TFL TRAVEL CHARGE TFL.GOV.UK/CP", merchant: "TfL", category: "Transport", debit: 5.80, credit: 0, seq: 14),
        r("2026-02-21", "TFL TRAVEL CHARGE TFL.GOV.UK/CP", merchant: "TfL", category: "Transport", debit: 2.90, credit: 0, seq: 15),
        r("2026-02-21", "TFL TRAVEL CHARGE TFL.GOV.UK/CP", merchant: "TfL", category: "Transport", debit: 2.90, credit: 0, seq: 16),
        r("2026-02-22", "Latymers - Hammersmith London", merchant: "Latymers", category: "Food & Dining", debit: 6.50, credit: 0, seq: 17),
        r("2026-02-22", "DOJO*THE CRAFT BEER CO LONDON", merchant: "The Craft Beer Co", category: "Food & Dining", debit: 7.25, credit: 0, seq: 18),
        r("2026-02-22", "DOJO*THE CRAFT BEER CO LONDON", merchant: "The Craft Beer Co", category: "Food & Dining", debit: 7.25, credit: 0, seq: 19),
        r("2026-02-22", "DOJO*THE CRAFT BEER CO LONDON", merchant: "The Craft Beer Co", category: "Food & Dining", debit: 7.25, credit: 0, seq: 20),
        r("2026-02-22", "DOJO*THE CRAFT BEER CO LONDON", merchant: "The Craft Beer Co", category: "Food & Dining", debit: 7.25, credit: 0, seq: 21),
        r("2026-02-22", "DOJO*THE CRAFT BEER CO LONDON", merchant: "The Craft Beer Co", category: "Food & Dining", debit: 7.25, credit: 0, seq: 22),
        r("2026-02-22", "DOJO*THE CRAFT BEER CO LONDON", merchant: "The Craft Beer Co", category: "Food & Dining", debit: 7.25, credit: 0, seq: 23),
        r("2026-02-22", "NAYAXAU*DATATEK PAYMENT LONDON", merchant: "Nayax Datatek", category: "Other", debit: 0.50, credit: 0, seq: 24),
        r("2026-02-23", "DELIVEROO LONDON", merchant: "Deliveroo", category: "Food & Dining", debit: 11.56, credit: 0, seq: 25),
        r("2026-02-23", "FOREST LONDON", merchant: "Forest", category: "Transport", debit: 1.00, credit: 0, seq: 26),
        r("2026-02-23", "FOREST LONDON", merchant: "Forest", category: "Transport", debit: 2.99, credit: 0, seq: 27),
        r("2026-02-24", "AD FREE FOR PRIMEVIDEO 353-12477661", merchant: "Prime Video", category: "Subscriptions", debit: 2.99, credit: 0, seq: 28),
        r("2026-02-24", "TFL TRAVEL CHARGE TFL.GOV.UK/CP", merchant: "TfL", category: "Transport", debit: 5.80, credit: 0, seq: 29),
        r("2026-02-25", "DELIVEROO LONDON", merchant: "Deliveroo", category: "Food & Dining", debit: 12.19, credit: 0, seq: 30),
        r("2026-03-01", "TEYA*LITLI DUBLINER FRA REYKJAVIK", merchant: "Litli Dubliner", category: "Food & Dining", debit: 3.47, credit: 0, seq: 31),
        r("2026-03-02", "TFL TRAVEL CHARGE TFL.GOV.UK/CP", merchant: "TfL", category: "Transport", debit: 2.60, credit: 0, seq: 32),
        r("2026-03-02", "FOREST LONDON", merchant: "Forest", category: "Transport", debit: 2.99, credit: 0, seq: 33),
        r("2026-03-03", "APPLE.COM/BILL HOLLYHILL", merchant: "Apple", category: "Subscriptions", debit: 8.99, credit: 0, seq: 34),
        r("2026-03-03", "TFL TRAVEL CHARGE TFL.GOV.UK/CP", merchant: "TfL", category: "Transport", debit: 6.20, credit: 0, seq: 35),
        r("2026-03-04", "AMAZON PRIME*227DM1GO5 AMZN.CO.UK/PM", merchant: "Amazon Prime", category: "Subscriptions", debit: 8.99, credit: 0, seq: 36),
        r("2026-03-05", "NOW LONDON", merchant: "NOW", category: "Entertainment", debit: 34.99, credit: 0, seq: 37),
        r("2026-03-05", "TST-THE KATI ROLL POLA LONDON", merchant: "The Kati Roll", category: "Food & Dining", debit: 21.60, credit: 0, seq: 38),
        r("2026-03-05", "TFL TRAVEL CHARGE TFL.GOV.UK/CP", merchant: "TfL", category: "Transport", debit: 6.20, credit: 0, seq: 39),
        r("2026-03-05", "3500728 Kings Arms Oxfo Westminster", merchant: "Kings Arms", category: "Food & Dining", debit: 23.43, credit: 0, seq: 40),
        r("2026-03-07", "TFL TRAVEL CHARGE TFL.GOV.UK/CP", merchant: "TfL", category: "Transport", debit: 8.90, credit: 0, seq: 41),
        r("2026-03-08", "TFL TRAVEL CHARGE TFL.GOV.UK/CP", merchant: "TfL", category: "Transport", debit: 4.80, credit: 0, seq: 42),
        r("2026-03-08", "LOKAL HOUNSLOW", merchant: "Lokal", category: "Food & Dining", debit: 20.00, credit: 0, seq: 43),
        r("2026-03-08", "Unit 6 281-287 High Str HOUNSLOW", merchant: "Unit 6 Hounslow", category: "Other", debit: 20.00, credit: 0, seq: 44),
        r("2026-03-10", "DOJO*BEEHIVE LONDON", merchant: "Beehive", category: "Food & Dining", debit: 13.60, credit: 0, seq: 45),
        r("2026-03-10", "LIME*PASS DXIZ LONDON", merchant: "Lime", category: "Transport", debit: 6.99, credit: 0, seq: 46),
        r("2026-03-10", "LIME*RIDE DXIZ LONDON", merchant: "Lime", category: "Transport", debit: 1.00, credit: 0, seq: 47),
        r("2026-03-10", "TFL TRAVEL CHARGE TFL.GOV.UK/CP", merchant: "TfL", category: "Transport", debit: 3.10, credit: 0, seq: 48),
        r("2026-03-10", "TAMESIS DOCK London", merchant: "Tamesis Dock", category: "Food & Dining", debit: 14.40, credit: 0, seq: 49),
        r("2026-03-10", "TFL TRAVEL CHARGE TFL.GOV.UK/CP", merchant: "TfL", category: "Transport", debit: 1.75, credit: 0, seq: 50),
        r("2026-03-14", "LIME*PASS DXIZ LONDON", merchant: "Lime", category: "Transport", debit: 6.99, credit: 0, seq: 51),
        r("2026-03-14", "LIME*RIDE DXIZ LONDON", merchant: "Lime", category: "Transport", debit: 3.36, credit: 0, seq: 52),
        r("2026-03-14", "TFL TRAVEL CHARGE TFL.GOV.UK/CP", merchant: "TfL", category: "Transport", debit: 1.75, credit: 0, seq: 53),
        r("2026-03-14", "FOREST LONDON", merchant: "Forest", category: "Transport", debit: 1.32, credit: 0, seq: 54),
        r("2026-03-14", "FOREST LONDON", merchant: "Forest", category: "Transport", debit: 2.99, credit: 0, seq: 55),
    ]

    private func ask(_ q: String) -> String? {
        FinanceRouter.answer(q, rows: Self.rows, currency: "GBP", money: Self.gbp)
    }

    private var wrong: [String] = []
    private var deferred: [String] = []
    private var checks = 0

    /// mustAnswer=true: a DEFER counts as a failure (core router responsibility).
    private func check(_ q: String, contains expected: String, mustAnswer: Bool = true) {
        checks += 1
        guard let a = ask(q) else {
            let line = "\(q) | expected \(expected)"
            if mustAnswer { wrong.append("DEFER | " + line) } else { deferred.append(line) }
            return
        }
        if !a.contains(expected) {
            wrong.append("WRONG | \(q) | expected \(expected) | got: \(a.replacingOccurrences(of: "\n", with: " / "))")
        }
    }

    func testRouterMatchesGroundTruth() {
        let debits = Self.rows.filter { $0.debit > 0 }
        let total = debits.reduce(0) { $0 + $1.debit }

        // ---- totals (core) ----
        for q in ["how much did I spend in total", "what did I spend altogether",
                  "how much have I spent", "total spending"] {
            check(q, contains: Self.money(total))
        }
        check("how many transactions", contains: "\(Self.rows.count)")

        // ---- per category (core): total + count + month split + exclusion ----
        let cats = Dictionary(grouping: debits, by: { $0.category })
        for (cat, ts) in cats {
            let sum = ts.reduce(0) { $0 + $1.debit }
            check("how much did I spend on \(cat)", contains: Self.money(sum))
            check("how many \(cat) transactions", contains: "\(ts.count)")
            // month-scoped (exploratory — DEFER ok)
            let feb = ts.filter { $0.txnDate.hasPrefix("2026-02") }.reduce(0) { $0 + $1.debit }
            check("how much did I spend on \(cat) in February", contains: Self.money(feb), mustAnswer: false)
            // exclusion (exploratory)
            let excl = total - sum
            check("how much did I spend excluding \(cat)", contains: Self.money(excl), mustAnswer: false)
        }

        // ---- per merchant (core): total; count (exploratory) ----
        let merch = Dictionary(grouping: debits.filter { !$0.merchant.isEmpty }, by: { $0.merchant })
        for (m, ts) in merch {
            let sum = ts.reduce(0) { $0 + $1.debit }
            check("how much did I spend at \(m)", contains: Self.money(sum))
            check("how many times did I use \(m)", contains: "\(ts.count)", mustAnswer: false)
        }

        // ---- per date (core) ----
        let monthName = ["02": "February", "03": "March"]
        for (iso, ts) in Dictionary(grouping: debits, by: { $0.txnDate }) {
            let sum = ts.reduce(0) { $0 + $1.debit }
            let p = iso.split(separator: "-")
            check("how much did I spend on \(Int(p[2])!) \(monthName[String(p[1])]!) 2026", contains: Self.money(sum))
        }

        // ---- largest / smallest / income (core) ----
        check("what was my largest purchase", contains: Self.money(debits.max { $0.debit < $1.debit }!.debit))
        check("what was my smallest purchase", contains: Self.money(debits.min { $0.debit < $1.debit }!.debit))
        check("how much did I earn", contains: "£0.00")
        check("what is my income", contains: "£0.00")

        // ---- report ----
        print("=== ROUTER EVAL: \(checks) checks | \(wrong.count) failing | \(deferred.count) deferred-to-LLM (by design) ===")
        for f in wrong { print("FAIL| " + f) }
        for d in deferred.prefix(40) { print("DEFER-LLM| " + d) }
        XCTAssertTrue(wrong.isEmpty, "\(wrong.count) router answers were wrong or wrongly deferred")
    }
}
