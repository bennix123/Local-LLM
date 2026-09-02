import XCTest
@testable import PennyTxnStore

/// 2026-09-02 manual bugs, batch 2 — the statement dimension. "(to/from) which
/// account did i receive/spend most [on X]?" over multiple statements must rank
/// the statements (the statement IS the account for non-Paytm imports), never
/// decline per currency three times, never answer a bare count roster, and
/// NEVER rank totals across different currencies.
final class StatementsQueryTests: XCTestCase {

    private func row(_ seq: Int, _ date: String, _ descr: String, cat: String,
                     debit: Double = 0, credit: Double = 0, cur: String) -> TxnRow {
        let p = date.split(separator: "-")
        return TxnRow(txnDate: date, month: "\(p[0])-\(p[1])", year: Int(p[0])!,
                      monthNo: Int(p[1])!, day: Int(p[2])!, descr: descr,
                      merchant: descr, category: cat, debit: debit, credit: credit,
                      balance: nil, currency: cur, seq: seq)
    }

    // Mixed currencies: Hdfc (INR) 2 credits 10200 · 3 pharmacy · 2 taxi 400
    //                   Chase (USD) 1 credit 300 · 1 pharmacy · 1 taxi 60
    //                   Barclays (GBP) 1 taxi 10
    private var mixed: [StatementsQuery.Statement] {
        [
            .init(name: "Hdfc Savings", rows: [
                row(1, "2026-01-03", "SALARY", cat: "Income", credit: 5000, cur: "INR"),
                row(2, "2026-02-03", "SALARY", cat: "Income", credit: 5200, cur: "INR"),
                row(3, "2026-01-10", "MEDPLUS", cat: "Pharmacy", debit: 450, cur: "INR"),
                row(4, "2026-01-14", "APOLLO PHARMACY", cat: "Pharmacy", debit: 300, cur: "INR"),
                row(5, "2026-02-01", "MEDPLUS", cat: "Pharmacy", debit: 250, cur: "INR"),
                row(6, "2026-01-20", "UBER TAXI", cat: "Transport", debit: 250, cur: "INR"),
                row(7, "2026-02-11", "OLA TAXI", cat: "Transport", debit: 150, cur: "INR"),
            ], currency: "INR"),
            .init(name: "Chase Usd", rows: [
                row(1, "2026-01-05", "REFUND", cat: "Income", credit: 300, cur: "USD"),
                row(2, "2026-01-09", "CVS PHARMACY", cat: "Pharmacy", debit: 40, cur: "USD"),
                row(3, "2026-01-22", "NYC TAXI", cat: "Transport", debit: 60, cur: "USD"),
            ], currency: "USD"),
            .init(name: "Barclays Gbp", rows: [
                row(1, "2026-01-07", "LONDON TAXI", cat: "Transport", debit: 10, cur: "GBP"),
            ], currency: "GBP"),
        ]
    }

    // Same-currency: two INR statements, credits 10200 vs 900.
    private var sameCurrency: [StatementsQuery.Statement] {
        [
            .init(name: "Hdfc Savings", rows: [
                row(1, "2026-01-03", "SALARY", cat: "Income", credit: 10200, cur: "INR"),
                row(2, "2026-01-10", "MEDPLUS", cat: "Pharmacy", debit: 450, cur: "INR"),
            ], currency: "INR"),
            .init(name: "Icici Current", rows: [
                row(1, "2026-01-05", "REFUND", cat: "Income", credit: 900, cur: "INR"),
                row(2, "2026-01-12", "UBER", cat: "Transport", debit: 100, cur: "INR"),
            ], currency: "INR"),
        ]
    }

    // Exact manual phrasing (typo included): mixed currencies must NOT be
    // ranked, and must NOT be a per-currency triple decline.
    func testToWhichAccountDidIRecieveMostMixedCurrencies() {
        let a = StatementsQuery.superlative("to which account did i recieve most?", statements: mixed)?.text
        XCTAssertNotNil(a, "must answer, not fall to the per-currency decline")
        XCTAssertTrue(a!.contains("different currencies"), a!)
        XCTAssertTrue(a!.contains("Hdfc Savings") && a!.contains("Chase Usd"), a!)
        XCTAssertTrue(a!.contains("₹10,200.00") && a!.contains("$300.00"), a!)
        XCTAssertFalse(a!.contains("doesn't say which of your accounts"), a!)
    }

    func testSameCurrencyRanksByAmountWithRunnerUp() {
        let a = StatementsQuery.superlative("which account received the most money?",
                                            statements: sameCurrency)?.text
        XCTAssertNotNil(a)
        XCTAssertTrue(a!.contains("came into Hdfc Savings"), a!)
        XCTAssertTrue(a!.contains("₹10,200.00"), a!)
        XCTAssertTrue(a!.contains("Runner-up: Icici Current"), a!)
    }

    // Exact manual phrasing: entity-scoped spend superlative. Taxi rows exist
    // in all three currencies → honest no-ranking with per-account totals.
    func testFromWhichAccountDidISpendMostOnTaxi() {
        let a = StatementsQuery.superlative("from which account did i spend most on taxi?",
                                            statements: mixed)?.text
        XCTAssertNotNil(a)
        XCTAssertTrue(a!.contains("₹400.00"), "Hdfc taxi total: \(a!)")
        XCTAssertTrue(a!.contains("$60.00"), a!)
        XCTAssertTrue(a!.contains("£10.00"), a!)
        XCTAssertFalse(a!.contains("₹10,200.00"), "credits must not leak in: \(a!)")
    }

    // Exact manual phrasing: count-mode names a winner, not a bare roster.
    func testMostOfThePharmacyTransactionsNamesTheWinner() {
        let a = StatementsQuery.superlative(
            "from which account did i make most of the pharmacy related transactions?",
            statements: mixed)?.text
        XCTAssertNotNil(a)
        XCTAssertTrue(a!.contains("Most of your Pharmacy transactions were from Hdfc Savings — 3 of 4."), a!)
        XCTAssertTrue(a!.contains("Chase Usd: 1"), a!)
    }

    // Generated paraphrases (standing rule).
    func testParaphrases() {
        XCTAssertNotNil(StatementsQuery.superlative("into which bank did most of my money come?",
                                                    statements: mixed))
        XCTAssertNotNil(StatementsQuery.superlative("wich account did i spend the most from",
                                                    statements: mixed))
        let least = StatementsQuery.superlative("which statement did i receive the least into?",
                                                statements: sameCurrency)?.text
        XCTAssertNotNil(least)
        XCTAssertTrue(least!.contains("Icici Current"), least!)
    }

    // Guards: rosters, balances, single-statement sets and non-superlatives
    // stay with their own handlers.
    func testDeclinesWhatItDoesNotOwn() {
        XCTAssertNil(StatementsQuery.superlative("whats the bank name?", statements: mixed))
        XCTAssertNil(StatementsQuery.superlative("which account has the highest closing balance?",
                                                 statements: mixed))
        XCTAssertNil(StatementsQuery.superlative("from which account did i make pharmacy transactions?",
                                                 statements: mixed),
                     "no superlative → the span-roster handler owns it")
        XCTAssertNil(StatementsQuery.superlative("to which account did i receive most?",
                                                 statements: [mixed[0]]),
                     "single statement → row-account resolver owns it")
        XCTAssertNil(StatementsQuery.superlative("which month did i spend the most?", statements: mixed))
    }
}
