// FinanceRouterParityTests — proves the new QueryEngine reconciles with the legacy
// FinanceRouter on the same data (wrap-then-delete: the engine must match before the
// router is retired in Phase 3). Both run over one dataset (rows for the router,
// the assembled graph for the engine) and the figures must agree.
import XCTest
import Foundation
@testable import PennyFinance
import PennyModel
import PennyTxnStore

final class FinanceRouterParityTests: XCTestCase {

    private func money(_ v: Double) -> String { "£" + String(format: "%.2f", v) }
    private func fmt(_ d: Decimal) -> String { money((d as NSDecimalNumber).doubleValue) }

    private func row(_ seq: Int, _ date: String, _ descr: String, category: String = "",
                     debit: Double = 0, credit: Double = 0) -> TxnRow {
        let p = date.split(separator: "-").compactMap { Int($0) }
        return TxnRow(txnDate: date, month: String(date.prefix(7)), year: p[0], monthNo: p[1], day: p[2],
                      descr: descr, merchant: "", category: category,
                      debit: debit, credit: credit, balance: nil, currency: "GBP", seq: seq)
    }

    /// One statement's rows + the graph assembled from them (kept in sync via the adapter).
    private func fixture() -> (rows: [TxnRow], graph: FinancialGraph) {
        let rows = [
            row(1, "2026-06-01", "TESCO", category: "Groceries", debit: 45.50),
            row(2, "2026-06-05", "SALARY", category: "Income", credit: 2500.00),
            row(3, "2026-06-10", "AMAZON", category: "Shopping", debit: 120.00),
            row(4, "2026-06-12", "ACME LETTINGS", category: "Rent", debit: 600.00),
        ]
        let out = IngestOutput(rows: rows, bankName: "Monzo", confidence: "test", detectedCurrency: "GBP")
        return (rows, ModelAssembler.assemble(out, sourceName: "monzo.pdf").graph)
    }

    private func router(_ q: String, _ rows: [TxnRow]) -> String {
        FinanceRouter.answer(q, rows: rows, currency: "GBP", accounts: [], money: money) ?? ""
    }

    func testCountParity() {
        let (rows, graph) = fixture()
        let engine = QueryEngine.execute(Query(aggregate: .count), in: graph)
        XCTAssertEqual(engine.scalar, .count(rows.count))
        XCTAssertTrue(router("how many transactions do I have?", rows).contains("\(rows.count)"),
                      "router: \(router("how many transactions do I have?", rows))")
    }

    func testTotalSpendParity() {
        let (rows, graph) = fixture()
        let engine = QueryEngine.execute(Query(filters: [.direction(.debit)], aggregate: .sum), in: graph)
        guard case .money(let sum) = engine.scalar else { return XCTFail() }
        // 45.50 + 120 + 600 = 765.50
        XCTAssertEqual(abs(sum), Decimal(string: "765.50"))
        XCTAssertTrue(router("total spending", rows).contains(fmt(abs(sum))),
                      "router must report the same total: \(router("total spending", rows))")
    }

    func testLargestExpenseParity() {
        let (rows, graph) = fixture()
        let engine = QueryEngine.execute(Query(filters: [.direction(.debit)], aggregate: .max), in: graph)
        guard case .money(let m) = engine.scalar else { return XCTFail() }
        XCTAssertEqual(m, Decimal(string: "600.00"))
        XCTAssertTrue(router("biggest expense", rows).contains(fmt(m)),
                      "router: \(router("biggest expense", rows))")
    }

    func testBridgeEndToEndParity() {
        let (rows, graph) = fixture()
        // question → LegacyQueryBridge → QueryEngine, compared to FinanceRouter.
        guard let qc = LegacyQueryBridge.query(for: "how many transactions do I have?") else { return XCTFail("count") }
        XCTAssertEqual(QueryEngine.execute(qc, in: graph).scalar, .count(rows.count))

        guard let qs = LegacyQueryBridge.query(for: "total spending"),
              case .money(let spend)? = QueryEngine.execute(qs, in: graph).scalar else { return XCTFail("spend") }
        XCTAssertEqual(abs(spend), Decimal(string: "765.50"))
        XCTAssertTrue(router("total spending", rows).contains(fmt(abs(spend))))

        guard let ql = LegacyQueryBridge.query(for: "biggest expense"),
              case .money(let big)? = QueryEngine.execute(ql, in: graph).scalar else { return XCTFail("largest") }
        XCTAssertEqual(big, Decimal(string: "600.00"))
        XCTAssertTrue(router("biggest expense", rows).contains(fmt(big)))

        // an unrecognized question returns nil (falls back to the legacy path)
        XCTAssertNil(LegacyQueryBridge.query(for: "roast my spending"))

        // itemised-list phrasings decline: FinanceRouter answers them with a
        // list, and the engine has no list capability yet — mapping them to
        // .sum would make the parity guard log a false divergence.
        XCTAssertNil(LegacyQueryBridge.query(for: "list my credits"))
        XCTAssertNil(LegacyQueryBridge.query(for: "show me my deposits"))
    }

    func testIncomeParity() {
        let (rows, graph) = fixture()
        let engine = QueryEngine.execute(Query(filters: [.direction(.credit)], aggregate: .sum), in: graph)
        guard case .money(let m) = engine.scalar else { return XCTFail() }
        XCTAssertEqual(m, Decimal(string: "2500.00"))
        XCTAssertTrue(router("total income", rows).contains(fmt(m)),
                      "router: \(router("total income", rows))")
    }
}
