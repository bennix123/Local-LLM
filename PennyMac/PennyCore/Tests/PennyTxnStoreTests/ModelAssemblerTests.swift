// ModelAssemblerTests — the parser→model translation layer (Task 0.4): faithful
// mapping of parsed facts, signed-amount reconciliation, exact Double→Decimal
// bridging, deterministic filename-independent identity, and the documented legacy
// merchant/category projection. Hermetic (synthetic rows) — no PDF dependency.
import XCTest
import Foundation
@testable import PennyTxnStore
import PennyModel

final class ModelAssemblerTests: XCTestCase {

    private func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }

    private func row(_ seq: Int, date: String, descr: String, merchant: String = "",
                     category: String = "", debit: Double = 0, credit: Double = 0,
                     balance: Double? = nil, currency: String = "GBP") -> TxnRow {
        let p = date.split(separator: "-").compactMap { Int($0) }
        return TxnRow(txnDate: date, month: String(date.prefix(7)), year: p[0], monthNo: p[1], day: p[2],
                      descr: descr, merchant: merchant, category: category,
                      debit: debit, credit: credit, balance: balance, currency: currency, seq: seq)
    }

    private func output(_ rows: [TxnRow], bank: String? = "Monzo", currency: String = "GBP",
                        isCard: Bool = false, closing: Double? = nil) -> IngestOutput {
        IngestOutput(rows: rows, bankName: bank, confidence: "high",
                     detectedCurrency: currency, closingBalance: closing, isCard: isCard)
    }

    // MARK: parsed facts + count parity

    func testMapsParsedFactsAndCountParity() {
        let rows = [row(1, date: "2026-06-15", descr: "TESCO STORES", debit: 45.50, balance: 100.00)]
        let r = ModelAssembler.assemble(output(rows), sourceName: "monzo.pdf")
        XCTAssertEqual(r.transactions.count, rows.count)
        let t = r.transactions[0]
        XCTAssertEqual(t.date, CalendarDate(year: 2026, month: 6, day: 15))
        XCTAssertEqual(t.rawDescription, "TESCO STORES")
        XCTAssertEqual(t.amount.amount, dec("-45.50"))
        XCTAssertEqual(t.balance?.amount, dec("100"))
        XCTAssertEqual(t.currency, .gbp)
        XCTAssertNil(t.fx, "legacy carries no FX")
        XCTAssertNil(t.processDate)
    }

    // MARK: signed amount + Double→Decimal precision + reconciliation

    func testSignedAmountPrecisionAndSumReconciles() {
        let rows = [row(1, date: "2026-05-22", descr: "ACME LETTINGS", debit: 1102.66),
                    row(2, date: "2026-05-22", descr: "NAZARA", credit: 7881.82)]
        let r = ModelAssembler.assemble(output(rows), sourceName: "monzo.pdf")
        XCTAssertEqual(r.transactions[0].amount.amount, dec("-1102.66"))
        XCTAssertEqual(r.transactions[1].amount.amount, dec("7881.82"))
        let sum = r.transactions.reduce(Money.zero) { $0 + $1.amount }
        XCTAssertEqual(sum.amount, dec("6779.16"), "signed sum = credits − debits, exact")
    }

    // MARK: account + statement mapping

    func testAccountAndStatementMapping() {
        let r = ModelAssembler.assemble(
            output([row(1, date: "2026-06-15", descr: "X", debit: 1)],
                   bank: "American Express", currency: "GBP", isCard: true, closing: 629.54),
            sourceName: "amex.pdf")
        XCTAssertEqual(r.account.institution, "American Express")
        XCTAssertEqual(r.account.kind, .credit)
        XCTAssertEqual(r.account.currency, .gbp)
        XCTAssertNil(r.account.number, "account number arrives in Task 0.5")
        XCTAssertEqual(r.statement.sourceName, "amex.pdf")
        XCTAssertEqual(r.statement.closingBalance?.amount, dec("629.54"))
        XCTAssertNil(r.statement.period, "period arrives in Task 0.5")
    }

    func testCurrencyAndBankDefaults() {
        let r = ModelAssembler.assemble(
            output([row(1, date: "2026-06-15", descr: "X", debit: 1, currency: "")],
                   bank: nil, currency: ""),
            sourceName: "x.pdf")
        XCTAssertEqual(r.account.institution, "Unknown")
        XCTAssertEqual(r.account.currency, Currency("INR"))
        XCTAssertEqual(r.transactions[0].currency, Currency("INR"), "empty row currency ⇒ account currency")
    }

    // MARK: legacy merchant/category projection (Decision A)

    func testLegacyProjection() {
        let rows = [row(1, date: "2026-06-15", descr: "TESCO", merchant: "Tesco", category: "Groceries", debit: 10),
                    row(2, date: "2026-06-16", descr: "MYSTERY", debit: 5)]  // no merchant/category
        let r = ModelAssembler.assemble(output(rows), sourceName: "x.pdf")
        XCTAssertEqual(r.transactions[0].enrichment.categoryID, CategoryID("Groceries"))
        XCTAssertNotNil(r.transactions[0].enrichment.merchantID)
        XCTAssertNil(r.transactions[0].enrichment.cleanDescription, "legacy has no clean description")
        XCTAssertNil(r.transactions[1].enrichment.merchantID, "empty merchant ⇒ nil")
        XCTAssertNil(r.transactions[1].enrichment.categoryID)
        XCTAssertEqual(r.categories.map(\.name), ["Groceries"])
        XCTAssertEqual(r.merchants.map(\.canonicalName), ["Tesco"])
        // enrichment link resolves to the projected merchant.
        XCTAssertEqual(r.transactions[0].enrichment.merchantID, r.merchants[0].id)
    }

    // MARK: deterministic, filename-independent identity

    func testIdentityIsDeterministicAndFilenameIndependent() {
        let rows = [row(1, date: "2026-06-15", descr: "TESCO", merchant: "Tesco", debit: 10)]
        let a = ModelAssembler.assemble(output(rows), sourceName: "file-a.pdf")
        let b = ModelAssembler.assemble(output(rows), sourceName: "different-name.pdf")
        XCTAssertEqual(a.account.id, b.account.id, "identity is content-derived, not filename-derived")
        XCTAssertEqual(a.statement.id, b.statement.id)
        XCTAssertEqual(a.transactions[0].id, b.transactions[0].id)
        // stable across repeated runs
        let c = ModelAssembler.assemble(output(rows), sourceName: "file-a.pdf")
        XCTAssertEqual(a.transactions[0].id, c.transactions[0].id)
    }

    // MARK: graph composition + edge cases

    func testGraphCompositionAndEmptyRows() {
        let empty = ModelAssembler.assemble(output([]), sourceName: "empty.pdf")
        XCTAssertEqual(empty.transactions.count, 0)
        XCTAssertEqual(empty.graph.accounts.count, 1)
        XCTAssertEqual(empty.graph.statements.count, 1)

        let rows = [row(1, date: "2026-06-15", descr: "A", merchant: "Tesco", category: "Groceries", debit: 1),
                    row(2, date: "2026-06-16", descr: "B", merchant: "Tesco", category: "Groceries", debit: 2)]
        let r = ModelAssembler.assemble(output(rows), sourceName: "x.pdf")
        XCTAssertEqual(r.graph.transactions.count, 2)
        XCTAssertEqual(r.graph.merchants.count, 1, "duplicate merchant deduped")
        XCTAssertEqual(r.graph.categories.count, 1)
    }

    // MARK: Task 0.5 — statement metadata mapping + account-number identity

    func testMetadataMapsIntoStatementAndAccount() {
        let meta = StatementMetadata(
            openingBalance: Money(dec("42.20")), availableBalance: Money(dec("15470.46")),
            creditLimit: Money(dec("16100.00")),
            period: CalendarDateRange(start: CalendarDate(year: 2026, month: 6, day: 1),
                                      end: CalendarDate(year: 2026, month: 6, day: 30)),
            statementDate: CalendarDate(year: 2026, month: 7, day: 1),
            accountNumber: "12345678", sortCode: "04-00-04", holder: "R Tester")
        let r = ModelAssembler.assemble(output([row(1, date: "2026-06-15", descr: "X", debit: 1)]),
                                        sourceName: "x.pdf", metadata: meta)
        XCTAssertEqual(r.statement.openingBalance?.amount, dec("42.20"))
        XCTAssertEqual(r.statement.availableBalance?.amount, dec("15470.46"))
        XCTAssertEqual(r.statement.creditLimit?.amount, dec("16100.00"))
        XCTAssertEqual(r.statement.statementDate, CalendarDate(year: 2026, month: 7, day: 1))
        XCTAssertNotNil(r.statement.period)
        XCTAssertEqual(r.account.number, "12345678")
        XCTAssertEqual(r.account.sortCode, "04-00-04")
        XCTAssertEqual(r.account.holder, "R Tester")
    }

    func testAccountIdentityKeysOnAccountNumber() {
        let rows = [row(1, date: "2026-06-15", descr: "X", debit: 1)]
        let acctA = StatementMetadata(accountNumber: "11111111", sortCode: "04-00-04")
        let acctB = StatementMetadata(accountNumber: "22222222", sortCode: "04-00-04")
        let a = ModelAssembler.assemble(output(rows, bank: "Monzo"), sourceName: "a.pdf", metadata: acctA)
        let b = ModelAssembler.assemble(output(rows, bank: "Monzo"), sourceName: "b.pdf", metadata: acctB)
        XCTAssertNotEqual(a.account.id, b.account.id,
                          "same institution, different account number ⇒ distinct AccountID")
        // Same institution + same number ⇒ same id (still content-derived).
        let a2 = ModelAssembler.assemble(output(rows, bank: "Monzo"), sourceName: "other.pdf", metadata: acctA)
        XCTAssertEqual(a.account.id, a2.account.id)
    }

    func testProvisionalFallbackWhenNoAccountNumber() {
        let rows = [row(1, date: "2026-06-15", descr: "X", debit: 1)]
        let a = ModelAssembler.assemble(output(rows, bank: "Monzo"), sourceName: "a.pdf")   // no metadata
        let b = ModelAssembler.assemble(output(rows, bank: "Monzo"), sourceName: "b.pdf", metadata: .empty)
        XCTAssertEqual(a.account.id, b.account.id, "no number/sort code ⇒ provisional institution+currency key")
    }

    // MARK: helpers (direct)

    func testDecimalBridgeAndIdentityHelpers() {
        XCTAssertEqual(DecimalBridge.decimal(0.1) + DecimalBridge.decimal(0.2), dec("0.3"))
        XCTAssertEqual(DecimalBridge.signedMoney(debit: 45.50, credit: 0).amount, dec("-45.50"))
        XCTAssertNil(DecimalBridge.money(nil))
        // FNV-1a is stable across calls.
        XCTAssertEqual(ModelIdentity.hash("penny"), ModelIdentity.hash("penny"))
        XCTAssertNotEqual(ModelIdentity.hash("a"), ModelIdentity.hash("b"))
    }
}
