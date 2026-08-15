// CardStatementTests — guards the generic credit-card support: conservative
// two-cue detection with bank-account vetoes (a false positive would flip a
// bank statement's debits and credits!), the stated-owed extraction, and the
// card-semantics post-pass (owed-balance polarity re-derivation, chain-break
// passthrough, repayment recategorization to "Payments").
import XCTest
@testable import PennyTxnStore

final class CardStatementTests: XCTestCase {

    // MARK: - detection

    func testDetectRequiresTwoIndependentCues() {
        XCTAssertTrue(CardStatement.detect(
            "Meridian Card Services — Credit Card Statement\nCredit Limit: 8,000.00"))
        XCTAssertTrue(CardStatement.detect(
            "New Balance: 1,204.55  Minimum Payment Due: 35.00  Payment Due Date: 08/15/2026"))
        XCTAssertFalse(CardStatement.detect("Credit Limit: 8,000.00"),
                       "one cue alone must not flip a statement to card semantics")
        XCTAssertFalse(CardStatement.detect("Monthly statement for your account"))
    }

    func testBankAccountCuesVetoDetection() {
        XCTAssertFalse(CardStatement.detect(
            "Credit Card Statement mention… Credit Limit: 500\nSort Code: 20-44-91"),
            "sort code marks a UK bank account — veto")
        XCTAssertFalse(CardStatement.detect(
            "New Balance: 1.00 Minimum Payment Due: 1.00 Routing Number: 021000021"),
            "routing number marks a US bank account — veto")
        XCTAssertFalse(CardStatement.detect(
            "Credit Limit and Payment Due Date… IFSC: SYNB0001234"),
            "IFSC marks an Indian bank account — veto")
        XCTAssertFalse(CardStatement.detect(
            "Chase Total Checking — new balance 100.00, credit limit 0"),
            "'checking' vetoes — bank statements may mention card-ish phrases")
    }

    func testExistingFixturesNeverDetectAsCards() throws {
        // Every bank-account fixture must read as a bank account; a regression here
        // would corrupt real users' figures. The Amex Platinum statement is the one
        // genuine credit-card layout in the corpus — it routes to its own dedicated
        // parser (`.ukLayout` → parseAmexCard) and is legitimately `isCard`, so it is
        // asserted separately rather than swept up by this bank-account guard.
        let fm = FileManager.default
        let ingester = try TestPaths.makeIngester()
        let pdfs = try fm.contentsOfDirectory(atPath: TestPaths.fixturesDir.path)
            .filter { $0.hasSuffix(".pdf") }.sorted()
        XCTAssertFalse(pdfs.isEmpty)
        let knownCards: Set<String> = ["amex_platinum_statement.pdf"]
        for pdf in pdfs where !knownCards.contains(pdf) {
            let out = try ingester.ingestPDF(path: TestPaths.fixturesDir.appendingPathComponent(pdf).path)
            XCTAssertFalse(out.isCard, "\(pdf) wrongly detected as a credit card statement")
        }
        // the one genuine card layout must still be recognised as a card
        let amex = try ingester.ingestPDF(
            path: TestPaths.fixturesDir.appendingPathComponent("amex_platinum_statement.pdf").path)
        XCTAssertTrue(amex.isCard, "the Amex Platinum statement is a credit-card statement")
    }

    // MARK: - stated owed amount

    func testStatedClosingBalanceVariants() {
        XCTAssertEqual(CardStatement.statedClosingBalance("New Balance: $1,204.55"), 1204.55)
        XCTAssertEqual(CardStatement.statedClosingBalance("TOTAL AMOUNT DUE ₹45,231.10"), 45231.10)
        XCTAssertEqual(CardStatement.statedClosingBalance("Closing Balance £860.00"), 860.00)
        XCTAssertNil(CardStatement.statedClosingBalance("no figures here"))
    }

    // MARK: - card semantics post-pass

    private func row(_ day: Int, _ descr: String, debit: Double, credit: Double,
                     balance: Double?) -> TxnRow {
        TxnRow(txnDate: String(format: "2026-06-%02d", day), month: "2026-06", year: 2026,
               monthNo: 6, day: day, descr: descr, merchant: "", category: "Other",
               debit: debit, credit: credit, balance: balance, currency: "USD", seq: day)
    }

    func testPolarityReDerivedFromOwedBalanceChain() {
        // Generic bank-walk output for a card: balance UP was read as credit.
        let parsed = [
            row(1, "OPENING CHARGE COFFEE", debit: 10, credit: 0, balance: 110),   // first row: kept as-is
            row(2, "AMAZON.COM", debit: 0, credit: 50, balance: 160),              // owed +50 → must become charge
            row(3, "PAYMENT RECEIVED - THANK YOU", debit: 100, credit: 0, balance: 60), // owed -100 → credit
            row(4, "STARBUCKS", debit: 0, credit: 25, balance: 85),                // owed +25 → charge
        ]
        let out = CardStatement.applyCardSemantics(parsed)
        XCTAssertEqual(out[1].debit, 50);  XCTAssertEqual(out[1].credit, 0)
        XCTAssertEqual(out[2].debit, 0);   XCTAssertEqual(out[2].credit, 100)
        XCTAssertEqual(out[3].debit, 25);  XCTAssertEqual(out[3].credit, 0)
        XCTAssertEqual(out[0].debit, 10, "first row (no prior balance) is left as parsed")
        XCTAssertEqual(out[2].category, "Payments")
        XCTAssertEqual(out[2].merchant, "Payment Received")
    }

    func testChainBreakRowsAreLeftAsParsed() {
        let parsed = [
            row(1, "A", debit: 10, credit: 0, balance: 100),
            row(2, "B", debit: 0, credit: 40, balance: 175),   // delta 75 ≠ amount 40 → untouched
            row(3, "C", debit: 0, credit: 30, balance: 205),   // delta 30 == 30 → becomes charge
        ]
        let out = CardStatement.applyCardSemantics(parsed)
        XCTAssertEqual(out[1].credit, 40, "inconsistent delta row must not be rewritten")
        XCTAssertEqual(out[2].debit, 30)
        XCTAssertEqual(out[2].credit, 0)
    }

    func testRowsWithoutBalancesOnlyGetRepaymentRecategorization() {
        let parsed = [
            row(1, "AUTOPAY PAYMENT", debit: 0, credit: 200, balance: nil),
            row(2, "AMAZON.COM", debit: 60, credit: 0, balance: nil),
        ]
        let out = CardStatement.applyCardSemantics(parsed)
        XCTAssertEqual(out[0].category, "Payments")
        XCTAssertEqual(out[1].debit, 60, "no balance chain → amounts untouched")
        XCTAssertEqual(out[1].category, "Other")
    }

    func testRepaymentPhrasesRecategorize() {
        for phrase in ["PAYMENT RECEIVED - THANK YOU", "AUTOPAY PAYMENT RECEIVED",
                       "DIRECT DEBIT PAYMENT RECEIVED", "THANK YOU FOR YOUR PAYMENT"] {
            let out = CardStatement.applyCardSemantics(
                [row(1, phrase, debit: 0, credit: 10, balance: nil)])
            XCTAssertEqual(out[0].category, "Payments", phrase)
        }
        // A DEBIT with payment-ish wording is never touched (it's not a repayment).
        let out = CardStatement.applyCardSemantics(
            [row(1, "PAYMENT TO PLUMBER", debit: 80, credit: 0, balance: nil)])
        XCTAssertEqual(out[0].category, "Other")
    }
}
