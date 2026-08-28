import XCTest
@testable import PennyTxnStore

/// RoastEngine policy + safety: discretionary-only targeting, exact figures,
/// off-limits categories never mentioned, and the garnish gate that keeps
/// model failures (loops, invented numbers, refusals) from ever shipping.
final class RoastEngineTests: XCTestCase {

    private func row(_ seq: Int, date: String, descr: String, category: String,
                     debit: Double = 0, credit: Double = 0) -> TxnRow {
        let parts = date.split(separator: "-")
        return TxnRow(txnDate: date, month: "\(parts[0])-\(parts[1])", year: Int(parts[0]) ?? 2026,
                      monthNo: Int(parts[1]) ?? 1, day: Int(parts[2]) ?? 1,
                      descr: descr, merchant: descr, category: category,
                      debit: debit, credit: credit, balance: nil, currency: "GBP", seq: seq)
    }

    private let money: (Double) -> String = { "£" + String(format: "%.2f", $0) }

    // Heavy essential spending + modest vice spending: the roast must aim ONLY
    // at the vices, whatever their relative size.
    private var rows: [TxnRow] {
        [row(1, date: "2026-05-01", descr: "CITY HOSPITAL", category: "Healthcare", debit: 5000),
         row(2, date: "2026-05-02", descr: "RENT MAYFAIR", category: "Rent", debit: 3000),
         row(3, date: "2026-05-03", descr: "BRITISH GAS", category: "Utilities", debit: 400),
         row(4, date: "2026-05-04", descr: "STUDENT LOAN CO", category: "Loan Repayment", debit: 300),
         row(5, date: "2026-05-09", descr: "ZOMATO", category: "Food Delivery", debit: 24.50),   // Saturday
         row(6, date: "2026-05-10", descr: "ZOMATO", category: "Food Delivery", debit: 31.20),   // Sunday
         row(7, date: "2026-05-12", descr: "ZOMATO", category: "Food Delivery", debit: 18.00),
         row(8, date: "2026-05-16", descr: "ZARA", category: "Shopping", debit: 220.00),          // Saturday
         row(9, date: "2026-06-06", descr: "ZOMATO", category: "Food Delivery", debit: 22.10),   // Saturday
         row(10, date: "2026-06-13", descr: "ZOMATO", category: "Food Delivery", debit: 27.40)]  // Saturday
    }

    func testOffLimitsCategoriesNeverAppear() throws {
        let out = try XCTUnwrap(RoastEngine.roast(rows: rows, money: money, seed: 7))
        for banned in ["HOSPITAL", "Healthcare", "RENT", "Rent", "BRITISH GAS",
                       "Utilities", "LOAN", "5,000", "5000.00", "3000.00", "£3,000"] {
            XCTAssertFalse(out.fallback.contains(banned), "off-limits leak “\(banned)”:\n\(out.fallback)")
            XCTAssertFalse(out.bullets.joined().contains(banned), "off-limits in bullets: \(banned)")
        }
    }

    func testRoastTargetsTheViceWithExactFigures() throws {
        let out = try XCTUnwrap(RoastEngine.roast(rows: rows, money: money, seed: 7))
        // ZARA (£220 in one hit) legitimately tops Zomato (£123.20 across 5).
        XCTAssertTrue(out.fallback.contains("ZARA") && out.bullets.joined().contains("£220.00"),
                      "\(out.bullets)")
        XCTAssertFalse(out.fallback.contains("1 visits"), "pluralization: \(out.fallback)")
        // The close must carry the real discretionary monthly figure.
        XCTAssertTrue(out.bullets.joined().contains("£343.20"), "\(out.bullets)")
    }

    func testSeedIsDeterministic() throws {
        let a = try XCTUnwrap(RoastEngine.roast(rows: rows, money: money, seed: 42))
        let b = try XCTUnwrap(RoastEngine.roast(rows: rows, money: money, seed: 42))
        XCTAssertEqual(a, b)
    }

    func testAllEssentialSpendingGetsTheCleanRoast() throws {
        let essential = Array(rows.prefix(4))
        let out = try XCTUnwrap(RoastEngine.roast(rows: essential, money: money, seed: 1))
        XCTAssertFalse(out.fallback.contains("£"), "no figures to tease: \(out.fallback)")
        XCTAssertTrue(out.fallback.lowercased().contains("nothing to roast")
                      || out.fallback.lowercased().contains("responsib"), "\(out.fallback)")
    }

    // MARK: - garnish gate

    func testGarnishGateRejectsInventedFigures() {
        let bullets = ["Top discretionary merchant: ZOMATO — £123.20 across 5 visits"]
        XCTAssertTrue(RoastEngine.garnishAcceptable(
            "You spent £123.20 at Zomato across five visits — impressive commitment to not cooking.",
            bullets: bullets))
        XCTAssertFalse(RoastEngine.garnishAcceptable(
            "You spent £999.99 at Zomato which is frankly heroic and also a little sad honestly.",
            bullets: bullets), "an invented figure must be rejected")
    }

    func testGarnishGateRejectsLoops() {
        let loop = Array(repeating: "that's like so much for shopping", count: 6).joined(separator: " and ")
        XCTAssertFalse(RoastEngine.garnishAcceptable(loop, bullets: []))
    }

    func testGarnishGateRejectsRefusals() {
        XCTAssertFalse(RoastEngine.garnishAcceptable(
            "I'm sorry, but I cannot roast your spending. I'm here to help you with your finances.",
            bullets: []))
    }
}
