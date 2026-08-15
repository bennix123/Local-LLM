// AmexStatementTests — locks the American Express "Platinum Card — Statement of
// Account" layout end-to-end. The fixture (amex_platinum_statement.pdf) is the
// real statement, detected purely from its content (letterhead + "Membership
// Number"), never its filename. Covers:
//   • issuer detection ("American Express") + GBP + credit-card semantics,
//   • the multi-page transaction table (date-pair rows, "CR" credits, the
//     foreign-spend column) — count, signed direction, and the statement's own
//     stated totals (Total new spend £616.32; Payment received £1,211.84 CR),
//   • the foreign-spend column no longer leaking the original-currency amount
//     into the merchant text, and
//   • structured FX (ISK amount + printed exchange rate + non-sterling fee)
//     surfaced on the canonical Transaction via ModelAssembler.
// Deterministic; no MLX. Grounded against the printed figures on the statement.
import XCTest
@testable import PennyTxnStore
import PennyModel

final class AmexStatementTests: XCTestCase {

    private let posix = Locale(identifier: "en_US_POSIX")
    private var out: IngestOutput!

    override func setUpWithError() throws {
        let pdf = TestPaths.fixturesDir.appendingPathComponent("amex_platinum_statement.pdf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: pdf.path),
                          "amex fixture missing at \(pdf.path)")
        out = try TestPaths.makeIngester().ingestPDF(path: pdf.path)
    }

    // MARK: - issuer / currency / card semantics

    func testIssuerCurrencyAndCardSemantics() {
        XCTAssertEqual(out.bankName, "American Express",
                       "detected from letterhead, not the filename")
        XCTAssertEqual(out.detectedCurrency, "GBP")
        XCTAssertTrue(out.isCard, "a credit-card statement — the balance is money owed")
        XCTAssertEqual(out.closingBalance ?? -1, 255.38, accuracy: 0.001,
                       "stated Closing Balance = £255.38")
    }

    // MARK: - transaction count + the statement's own totals

    func testTransactionCountAndStatedTotals() {
        XCTAssertEqual(out.rows.count, 55, "1 payment credit + 54 spend rows across pages 2–4")

        let debits = out.rows.reduce(0.0) { $0 + $1.debit }
        let credits = out.rows.reduce(0.0) { $0 + $1.credit }
        XCTAssertEqual(debits, 616.32, accuracy: 0.001, "statement: Total new spend £616.32")
        XCTAssertEqual(credits, 1211.84, accuracy: 0.001, "statement: Payment received £1,211.84 CR")

        let creditRows = out.rows.filter { $0.credit > 0 }
        XCTAssertEqual(creditRows.count, 1, "exactly one credit — the repayment")
        XCTAssertEqual(creditRows.first?.credit ?? -1, 1211.84, accuracy: 0.001)
        XCTAssertEqual(creditRows.first?.category, "Payments",
                       "repaying your own card is a transfer, never income")

        // balance-sheet identity: Previous £850.90 − Credits £1,211.84 + Debits £616.32 = £255.38
        XCTAssertEqual(850.90 - credits + debits, out.closingBalance ?? -1, accuracy: 0.01)
    }

    // MARK: - direction + ordering

    func testDirectionAndCurrencyPerRow() {
        XCTAssertTrue(out.rows.allSatisfy { $0.currency == "GBP" })
        // every non-repayment row is a spend (debit), never miscoded as income
        for r in out.rows where r.credit == 0 {
            XCTAssertGreaterThan(r.debit, 0, "spend row must carry a positive debit: \(r.descr)")
        }
        // dates land in the statement period (16 Feb → 15 Mar 2026)
        XCTAssertTrue(out.rows.allSatisfy { $0.txnDate >= "2026-02-15" && $0.txnDate <= "2026-03-15" })
    }

    // MARK: - foreign-spend column must not pollute the merchant text

    func testForeignRowDescriptionIsClean() {
        let teya = out.rows.first { $0.descr.contains("TEYA") }
        XCTAssertEqual(teya?.descr, "TEYA*LITLI DUBLINER FRA REYKJAVIK",
                       "the ISK foreign amount (550) must not leak into the description")
        XCTAssertEqual(teya?.debit ?? -1, 3.47, accuracy: 0.001, "the sterling amount charged")
        XCTAssertEqual(teya?.credit ?? -1, 0, accuracy: 0.001)
    }

    // MARK: - structured FX surfaced on the canonical Transaction

    func testForeignExchangeCapturedOnCanonicalTransaction() throws {
        let asm = ModelAssembler.assemble(out, sourceName: "amex_platinum_statement.pdf")
        XCTAssertEqual(asm.transactions.count, out.rows.count)

        let teya = try XCTUnwrap(asm.transactions.first { $0.rawDescription.contains("TEYA") })
        let fx = try XCTUnwrap(teya.fx, "the Reykjavik ISK charge must carry FX detail")
        XCTAssertEqual(fx.originalCurrency, Currency("ISK"))
        XCTAssertEqual(fx.originalAmount.amount, Decimal(string: "550", locale: posix))
        XCTAssertEqual(fx.rate, Decimal(string: "163.2047", locale: posix), "printed exchange rate")
        XCTAssertEqual(fx.fee?.amount, Decimal(string: "0.1", locale: posix), "non-sterling transaction fee £0.10")

        // domestic rows carry no FX
        let tfl = try XCTUnwrap(asm.transactions.first { $0.rawDescription.contains("TFL") })
        XCTAssertNil(tfl.fx, "a sterling TfL charge is not foreign")
    }
}
