import XCTest
@testable import PennyTxnStore

/// 2026-09-02 manual bugs (found on the synthetic multi-bank test data) —
/// exact phrasings pinned per the standing rule, plus generated same-class
/// paraphrases. App-level halves of these bugs (cross-statement comparer
/// theft, existence phrasing on the keyword fallback) are pinned in
/// AppModelLogicTests; these are the router-level halves.
final class ManualBugs20260902Tests: XCTestCase {

    private let money: (Double) -> String = { "₹" + String(format: "%.2f", $0) }

    private func row(_ seq: Int, _ date: String, _ descr: String, cat: String,
                     debit: Double = 0, credit: Double = 0) -> TxnRow {
        let p = date.split(separator: "-")
        return TxnRow(txnDate: date, month: "\(p[0])-\(p[1])", year: Int(p[0])!,
                      monthNo: Int(p[1])!, day: Int(p[2])!, descr: descr,
                      merchant: descr, category: cat, debit: debit, credit: credit,
                      balance: nil, currency: "INR", seq: seq)
    }

    // Truths: spent 3400 · Shopping 2000 > Fast Food 800 (KFC 500 > MCDONALDS
    // 300) > Pharmacy 450 > Transport 150 · received 5000.
    private var rows: [TxnRow] {
        [
            row(1, "2026-01-03", "SALARY ACME CORP PAYROLL", cat: "Income", credit: 5000),
            row(2, "2026-01-05", "KFC", cat: "Fast Food", debit: 500),
            row(3, "2026-01-08", "MCDONALDS", cat: "Fast Food", debit: 300),
            row(4, "2026-01-10", "AMAZON", cat: "Shopping", debit: 1200),
            row(5, "2026-02-02", "AMAZON", cat: "Shopping", debit: 800),
            row(6, "2026-02-04", "MEDPLUS", cat: "Pharmacy", debit: 450),
            row(7, "2026-02-08", "UBER", cat: "Transport", debit: 150),
        ]
    }

    private func ask(_ q: String) -> String? {
        AccountQuery.answer(q, rows: rows, money: money)
            ?? FinanceRouter.answer(q, rows: rows, currency: "INR", money: money)
    }

    // "which catagory did i spend most amount?" → the multi-doc comparer stole
    // it ("Hdfc Savings has the most money out"); single-doc the typo dodged
    // every category handler. Dimension-noun typos now canonicalize at router
    // entry, so this is a category superlative like any other.
    func testWhichCatagoryTypoDidISpendMostAmount() {
        let a = ask("which catagory did i spend most amount?")
        XCTAssertNotNil(a, "must answer, not defer")
        XCTAssertTrue(a!.contains("Shopping"), a!)
        XCTAssertTrue(a!.contains("₹2000.00"), a!)
        XCTAssertFalse(a!.contains("₹3400.00"), "whole total is the wrong answer: \(a!)")
    }

    func testWhichCatagorieTypoGetsTheMostToo() {
        let a = ask("wich catagorie did i spend the most in?")
        XCTAssertNotNil(a)
        XCTAssertTrue(a!.contains("Shopping"), a!)
        XCTAssertFalse(a!.contains("₹3400.00"), a!)
    }

    // "on what did i spend most in fastfood?" → same theft multi-doc; single-doc
    // the "what" shape wasn't a recognized dimension. A "what" question already
    // scoped to a category asks for the merchant within it.
    func testOnWhatDidISpendMostInFastfood() {
        let a = ask("on what did i spend most in fastfood?")
        XCTAssertNotNil(a, "must answer, not defer")
        XCTAssertTrue(a!.contains("KFC"), a!)
        XCTAssertTrue(a!.contains("₹500.00"), a!)
        XCTAssertFalse(a!.contains("₹3400.00"), a!)
        XCTAssertFalse(a!.contains("₹800.00"), "category total is not the merchant answer: \(a!)")
    }

    // "how much did i spend on appolo?" → answered the whole multi-currency
    // total (884 transactions). "on"-targets are now captured like at/to/from,
    // so an unknown target gets the honest zero.
    func testSpendOnUnknownMerchantIsAnHonestZeroNotTheTotal() {
        let a = ask("how much did i spend on appolo?")
        XCTAssertNotNil(a)
        XCTAssertTrue(a!.contains("₹0.00"), a!)
        XCTAssertTrue(a!.lowercased().contains("appolo"), a!)
        XCTAssertFalse(a!.contains("₹3400.00"), a!)
    }

    func testSpendOnOtherUnknownTargetsAlsoHonestZero() {
        for q in ["how much did i spend on zomatoo?", "how much did i spend for netflix?"] {
            let a = ask(q)
            XCTAssertNotNil(a, q)
            XCTAssertTrue(a!.contains("₹0.00"), "\(q) → \(a!)")
            XCTAssertFalse(a!.contains("₹3400.00"), "\(q) → \(a!)")
        }
    }

    // Temporal words after "on" must NOT become phantom targets now that "on"
    // captures preposition targets.
    func testOnWeekdayNeverBecomesAPhantomTarget() {
        for q in ["how much did i spend on friday?", "how much did i spend on weekends?"] {
            if let a = ask(q) {
                XCTAssertFalse(a.contains("on Friday.** I couldn't find"), "\(q) → \(a)")
                XCTAssertFalse(a.contains("on Weekends.** I couldn't find"), "\(q) → \(a)")
            }
        }
    }

    // The existence detector (app fallback uses it; unit-pin the brain here).
    func testExistenceDetector() {
        XCTAssertTrue(AccountQuery.isExistenceQuestion("do i have prime?"))
        XCTAssertTrue(AccountQuery.isExistenceQuestion("do i got to starbucks?"))
        XCTAssertTrue(AccountQuery.isExistenceQuestion("did i ever order from swiggy"))
        XCTAssertTrue(AccountQuery.isExistenceQuestion("have i paid netflix"))
        XCTAssertFalse(AccountQuery.isExistenceQuestion("how much did i spend at starbucks?"))
        XCTAssertFalse(AccountQuery.isExistenceQuestion("show my starbucks transactions"))
    }

    // Typo'd dimension words must never leak into phantom zero targets.
    func testCatagoryTypoIsNeverAPhantomTarget() {
        let a = ask("which catagory did i spend most amount?")
        XCTAssertFalse(a?.contains("₹0.00 on Catagory") == true, a ?? "")
        XCTAssertFalse(a?.contains("₹0.00 on Category") == true, a ?? "")
    }
}
