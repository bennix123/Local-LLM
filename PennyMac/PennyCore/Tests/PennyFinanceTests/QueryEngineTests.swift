// QueryEngineTests — the deterministic engine over a small canonical graph:
// filters, aggregations, grouping, the per-currency guard, magnitude amounts,
// citations, and sorting/paging. Figures are hand-verified.
import XCTest
import Foundation
@testable import PennyFinance
import PennyModel

final class QueryEngineTests: XCTestCase {

    private func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }
    private func date(_ m: Int, _ d: Int) -> CalendarDate { CalendarDate(year: 2026, month: m, day: d) }

    /// A two-account graph (Monzo current + Amex credit) with GBP transactions.
    private func graph() -> FinancialGraph {
        let monzo = Account(id: AccountID("acc-monzo"), institution: "Monzo", kind: .current, currency: .gbp)
        let amex = Account(id: AccountID("acc-amex"), institution: "American Express", kind: .credit, currency: .gbp)
        let sM = Statement(id: StatementID("st-monzo"), accountID: monzo.id, sourceName: "monzo.pdf")
        let sA = Statement(id: StatementID("st-amex"), accountID: amex.id, sourceName: "amex.pdf")
        let tesco = Merchant(id: MerchantID("m-tesco"), canonicalName: "Tesco")
        let amazon = Merchant(id: MerchantID("m-amazon"), canonicalName: "Amazon")
        let groceries = Category(id: CategoryID("Groceries"), name: "Groceries")
        let shopping = Category(id: CategoryID("Shopping"), name: "Shopping")
        func tx(_ id: String, _ acc: Account, _ st: Statement, _ m: Int, _ d: Int, _ amt: String,
                merchant: MerchantID?, category: CategoryID?, tags: Set<Tag> = []) -> Transaction {
            Transaction(id: TransactionID(id), accountID: acc.id, statementID: st.id, date: date(m, d),
                        rawDescription: id, amount: Money(dec(amt)), currency: .gbp,
                        enrichment: Enrichment(merchantID: merchant, categoryID: category, tags: tags))
        }
        let txns = [
            tx("t1", monzo, sM, 6, 1, "-45.50", merchant: tesco.id, category: groceries.id),
            tx("t2", monzo, sM, 6, 5, "2500.00", merchant: nil, category: nil, tags: [.salary]),
            tx("t3", monzo, sM, 6, 10, "-120.00", merchant: amazon.id, category: shopping.id),
            tx("t4", amex, sA, 6, 3, "-30.25", merchant: tesco.id, category: groceries.id),
            tx("t5", amex, sA, 6, 8, "-600.00", merchant: nil, category: shopping.id),
        ]
        return FinancialGraph(accounts: [monzo, amex], statements: [sM, sA], transactions: txns,
                              merchants: [tesco, amazon], categories: [groceries, shopping])
    }

    func testCountAndFilters() {
        let g = graph()
        XCTAssertEqual(QueryEngine.execute(Query(aggregate: .count), in: g).scalar, .count(5))
        XCTAssertEqual(QueryEngine.execute(Query(filters: [.account(AccountID("acc-amex"))], aggregate: .count), in: g).scalar, .count(2))
        XCTAssertEqual(QueryEngine.execute(Query(filters: [.direction(.debit)], aggregate: .count), in: g).scalar, .count(4))
        XCTAssertEqual(QueryEngine.execute(Query(filters: [.merchant(.name("Tesco"))], aggregate: .count), in: g).scalar, .count(2))
        XCTAssertEqual(QueryEngine.execute(Query(filters: [.category(CategoryID("Shopping"))], aggregate: .count), in: g).scalar, .count(2))
        XCTAssertEqual(QueryEngine.execute(Query(filters: [.tag(.salary)], aggregate: .count), in: g).scalar, .count(1))
    }

    func testAmountMagnitudeAndDate() {
        let g = graph()
        // "over £100" by magnitude ⇒ t3 (-120), t5 (-600), t2 (+2500) = 3
        let over100 = Query(filters: [.amount(ComparableRange(lowerBound: 100, lowerInclusive: false))], aggregate: .count)
        XCTAssertEqual(QueryEngine.execute(over100, in: g).scalar, .count(3))
        // date range 1–5 June ⇒ t1, t2, t4 = 3
        let june1to5 = Query(filters: [.dateRange(CalendarDateRange(start: date(6, 1), end: date(6, 5)))], aggregate: .count)
        XCTAssertEqual(QueryEngine.execute(june1to5, in: g).scalar, .count(3))
    }

    func testSumSpendAndLargest() {
        let g = graph()
        // total spend (debits): magnitude of the signed sum = 45.50+120+30.25+600 = 795.75
        let spend = QueryEngine.execute(Query(filters: [.direction(.debit)], aggregate: .sum), in: g)
        if case .money(let m) = spend.scalar { XCTAssertEqual(abs(m), dec("795.75")) } else { XCTFail() }
        XCTAssertEqual(spend.currency, .gbp)
        XCTAssertEqual(spend.citations.count, 4)
        // largest debit = £600 (t5)
        let maxDebit = QueryEngine.execute(Query(filters: [.direction(.debit)], aggregate: .max), in: g)
        XCTAssertEqual(maxDebit.scalar, .money(dec("600.00")))
        XCTAssertEqual(maxDebit.rows.first?.id, TransactionID("t5"))
    }

    func testGroupedCategoryBreakdownAndTopMerchants() {
        let g = graph()
        // spending by category (debits), grouped
        let byCat = QueryEngine.execute(Query(filters: [.direction(.debit)], aggregate: .sum, groupBy: .category), in: g)
        let cats = byCat.groups?.map(\.key) ?? []
        XCTAssertEqual(Set(cats), ["Groceries", "Shopping"])
        // top 1 merchant by spend ⇒ Tesco appears twice but small; Amazon 120; groups ranked by |sum|
        let top = QueryEngine.execute(Query(filters: [.direction(.debit)], aggregate: .topN(1), groupBy: .merchant), in: g)
        XCTAssertEqual(top.groups?.count, 1)
    }

    func testDistinctStatementsWithSalary() {
        let g = graph()
        let r = QueryEngine.execute(Query(filters: [.tag(.salary)], aggregate: .distinctCount(.statement)), in: g)
        XCTAssertEqual(r.scalar, .count(1))
    }

    func testListSortingAndPaging() {
        let g = graph()
        let top2 = QueryEngine.execute(Query(filters: [.direction(.debit)], aggregate: .list,
                                             sort: [SortKey(.amount, .descending)], page: Page(limit: 2)), in: g)
        XCTAssertEqual(top2.rows.map(\.id), [TransactionID("t5"), TransactionID("t3")], "largest two debits, in order")
    }
}
