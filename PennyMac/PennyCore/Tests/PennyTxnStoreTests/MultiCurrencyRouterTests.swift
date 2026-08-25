import XCTest
@testable import PennyTxnStore

/// FinanceRouter's mixed-currency behavior: one answer per currency, correct
/// symbols and grouping, honest-zero collapsing, and untouched single-currency
/// behavior (the 46k-question evals all run single-currency).
final class MultiCurrencyRouterTests: XCTestCase {

    private func row(_ seq: Int, date: String = "2026-06-01", descr: String,
                     debit: Double = 0, credit: Double = 0, currency: String) -> TxnRow {
        TxnRow(txnDate: date, month: String(date.prefix(7)), year: 2026, monthNo: 6, day: 1,
               descr: descr, merchant: descr, category: "Shopping",
               debit: debit, credit: credit, balance: nil, currency: currency, seq: seq)
    }

    private var mixedRows: [TxnRow] {
        [row(1, descr: "ZARA", debit: 100, currency: "GBP"),
         row(2, descr: "TESCO", debit: 50, currency: "GBP"),
         row(3, descr: "ZARA", debit: 5000, currency: "INR"),
         row(4, descr: "SWIGGY", debit: 300, currency: "INR"),
         row(5, descr: "SALARY", credit: 90000, currency: "INR")]
    }

    private let gbpMoney: (Double) -> String = { "£" + String(format: "%.2f", $0) }

    func testMixedTotalSpentAnswersPerCurrency() throws {
        let ans = try XCTUnwrap(FinanceRouter.answer("How much did I spend in total?",
                                                     rows: mixedRows, currency: "GBP", money: gbpMoney))
        XCTAssertTrue(ans.contains("**INR**"), "needs an INR section: \(ans)")
        XCTAssertTrue(ans.contains("**GBP**"), "needs a GBP section: \(ans)")
        XCTAssertTrue(ans.contains("₹5,300.00"), "INR spend is ₹5,300: \(ans)")
        XCTAssertTrue(ans.contains("£150.00"), "GBP spend is £150: \(ans)")
        XCTAssertFalse(ans.contains("5,450"), "currencies must never blend: \(ans)")
    }

    func testScopedMerchantAcrossCurrencies() throws {
        let ans = try XCTUnwrap(FinanceRouter.answer("How much did I spend at Zara?",
                                                     rows: mixedRows, currency: "GBP", money: gbpMoney))
        XCTAssertTrue(ans.contains("₹5,000.00"), "\(ans)")
        XCTAssertTrue(ans.contains("£100.00"), "\(ans)")
    }

    func testMerchantInOneCurrencyOnlySuppressesZeroSections() throws {
        let ans = try XCTUnwrap(FinanceRouter.answer("How much did I spend at Swiggy?",
                                                     rows: mixedRows, currency: "GBP", money: gbpMoney))
        XCTAssertTrue(ans.contains("₹300.00"), "\(ans)")
        XCTAssertFalse(ans.contains("£0.00"), "GBP honest-zero must be suppressed when INR has hits: \(ans)")
    }

    func testAbsentMerchantCollapsesToOneHonestZero() throws {
        let ans = try XCTUnwrap(FinanceRouter.answer("How much did I spend at Ferrari?",
                                                     rows: mixedRows, currency: "GBP", money: gbpMoney))
        XCTAssertEqual(ans.components(separatedBy: "couldn't find").count - 1, 1,
                       "exactly one honest zero, not one per currency: \(ans)")
    }

    func testDollarsNeverLakhGrouped() throws {
        let rows = [row(1, descr: "AMAZON", debit: 288153.34, currency: "USD"),
                    row(2, descr: "SWIGGY", debit: 100, currency: "INR")]
        let ans = try XCTUnwrap(FinanceRouter.answer("How much did I spend in total?",
                                                     rows: rows, currency: "USD", money: gbpMoney))
        XCTAssertTrue(ans.contains("$288,153.34"), "USD uses western grouping: \(ans)")
        XCTAssertFalse(ans.contains("$2,88,153.34"), "no lakh grouping on dollars: \(ans)")
    }

    func testSingleCurrencyPathUnchanged() throws {
        let rows = [row(1, descr: "ZARA", debit: 100, currency: "GBP"),
                    row(2, descr: "TESCO", debit: 50, currency: "GBP")]
        let ans = try XCTUnwrap(FinanceRouter.answer("How much did I spend in total?",
                                                     rows: rows, currency: "GBP", money: gbpMoney))
        XCTAssertTrue(ans.contains("£150.00"), "\(ans)")
        XCTAssertFalse(ans.contains("**GBP**"), "no currency headers in single-currency mode: \(ans)")
    }
}
