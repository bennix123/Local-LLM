import XCTest
@testable import PennyFinance
import PennyModel

/// The deterministic half of the LLM-as-parser tier: DTO→Query mapping, period
/// tokens (OUR date math, never the model's), entity resolution with the same
/// typo forgiveness the router has, and renderer wording. Always runs — no
/// model involved (`QueryParserLiveTests` covers the live parse, env-gated).
final class QueryParserMappingTests: XCTestCase {

    private let today = CalendarDate(year: 2026, month: 9, day: 3)

    private var vocab: QueryVocabulary {
        QueryVocabulary(
            categories: ["Pharmacy", "Fast Food", "Shopping", "Income"],
            merchants: ["Amazon", "Medplus", "KFC"],
            accounts: [.init(name: "Hdfc Savings", id: "acct-hdfc"),
                       .init(name: "Chase Usd", id: "acct-chase")],
            currencies: ["INR"],
            months: ["2025-11", "2025-12", "2026-01"],
            dateRange: nil)
    }

    private func map(_ dto: ParsedQueryDTO) -> Result<Query, QueryMappingError> {
        QueryDTOMapper.map(dto, vocabulary: vocab, today: today)
    }

    // MARK: aggregates + validator feedback

    func testInvalidAggregateProducesModelReadableError() {
        guard case .failure(let e) = map(.init(aggregate: "summ")) else {
            return XCTFail("'summ' must be rejected")
        }
        XCTAssertTrue(e.message.contains("allowed: sum, count, average"), e.message)
    }

    func testTopNRequiresN() {
        guard case .failure = map(.init(aggregate: "top_n")) else {
            return XCTFail("top_n without topN must be rejected")
        }
        guard case .success(let q) = map(.init(aggregate: "top_n", topN: 3)) else {
            return XCTFail()
        }
        XCTAssertEqual(q.aggregate, .topN(3))
    }

    // MARK: entities — same forgiveness as the router

    func testTypoCategoryResolves() {
        guard case .success(let q) = map(.init(aggregate: "sum", direction: "debit",
                                               category: "pharamcy")) else { return XCTFail() }
        XCTAssertTrue(q.filters.contains(.category(CategoryID("Pharmacy"))), "\(q.filters)")
        XCTAssertTrue(q.filters.contains(.direction(.debit)))
    }

    func testSquashedCategoryResolves() {
        guard case .success(let q) = map(.init(aggregate: "sum", category: "fastfood")) else {
            return XCTFail()
        }
        XCTAssertTrue(q.filters.contains(.category(CategoryID("Fast Food"))))
    }

    func testUnknownCategoryFailsListingPresentOnes() {
        guard case .failure(let e) = map(.init(aggregate: "sum", category: "astrology")) else {
            return XCTFail("unknown category must be rejected, not guessed")
        }
        XCTAssertTrue(e.message.contains("Pharmacy"), e.message)
    }

    func testAccountResolvesByFragment() {
        guard case .success(let q) = map(.init(aggregate: "sum", account: "hdfc")) else {
            return XCTFail()
        }
        XCTAssertTrue(q.filters.contains(.account(AccountID("acct-hdfc"))))
    }

    func testUnknownAccountFailsListingPresentOnes() {
        guard case .failure(let e) = map(.init(aggregate: "sum", account: "monzo")) else {
            return XCTFail()
        }
        XCTAssertTrue(e.message.contains("Hdfc Savings"), e.message)
    }

    // MARK: period tokens — resolved against `today`, never by the model

    private func range(_ token: String) -> CalendarDateRange? {
        guard case .success(let q) = map(.init(aggregate: "sum", period: token)) else { return nil }
        for f in q.filters { if case .dateRange(let r) = f { return r } }
        return nil
    }

    func testLastMonthToken() {
        let r = range("last_month")
        XCTAssertEqual(r?.start, CalendarDate(year: 2026, month: 8, day: 1))
        XCTAssertEqual(r?.end, CalendarDate(year: 2026, month: 8, day: 31))
    }

    func testBareMonthNamePicksLatestPresentInData() {
        // "november" with 2025-11 in the data → November 2025, not 2026.
        let r = range("november")
        XCTAssertEqual(r?.start, CalendarDate(year: 2025, month: 11, day: 1))
        XCTAssertEqual(r?.end, CalendarDate(year: 2025, month: 11, day: 30))
    }

    func testMonthNameWithYearAndISOAndRange() {
        XCTAssertEqual(range("november 2025")?.start, CalendarDate(year: 2025, month: 11, day: 1))
        XCTAssertEqual(range("2025-12")?.end, CalendarDate(year: 2025, month: 12, day: 31))
        XCTAssertEqual(range("2025")?.start, CalendarDate(year: 2025, month: 1, day: 1))
        let r = range("2026-01-05..2026-01-15")
        XCTAssertEqual(r?.start, CalendarDate(year: 2026, month: 1, day: 5))
        XCTAssertEqual(r?.end, CalendarDate(year: 2026, month: 1, day: 15))
    }

    func testLast30DaysAndInvalidToken() {
        XCTAssertEqual(range("last_30_days")?.start, CalendarDate(year: 2026, month: 8, day: 5))
        guard case .failure(let e) = map(.init(aggregate: "sum", period: "someday")) else {
            return XCTFail("invalid period must be rejected")
        }
        XCTAssertTrue(e.message.contains("last_month"), e.message)
    }

    func testAddDaysCrossesMonthAndYearAndLeap() {
        XCTAssertEqual(QueryDTOMapper.addDays(CalendarDate(year: 2026, month: 1, day: 1), -1),
                       CalendarDate(year: 2025, month: 12, day: 31))
        XCTAssertEqual(QueryDTOMapper.addDays(CalendarDate(year: 2024, month: 3, day: 1), -1),
                       CalendarDate(year: 2024, month: 2, day: 29))
    }

    // MARK: small-model slips the mapper absorbs (live-caught 2026-09-03)

    func testPeriodGrainWordBecomesGroupBy() {
        // "spending by month" → the model slotted period:"month"; that's a
        // groupBy, not a date range.
        guard case .success(let q) = map(.init(aggregate: "sum", direction: "debit",
                                               period: "month")) else { return XCTFail() }
        XCTAssertEqual(q.groupBy, .month)
        XCTAssertFalse(q.filters.contains { if case .dateRange = $0 { return true }; return false })
    }

    func testIntentWordNeverBecomesATextFilter() {
        // A leaked text:"spending" would text-filter descriptions → wrong zero.
        guard case .success(let q) = map(.init(aggregate: "sum", direction: "debit",
                                               text: "spending")) else { return XCTFail() }
        XCTAssertFalse(q.filters.contains { if case .text = $0 { return true }; return false })
        // …but a genuine needle survives.
        guard case .success(let q2) = map(.init(aggregate: "sum", text: "refund")) else { return XCTFail() }
        XCTAssertTrue(q2.filters.contains(.text("refund")))
    }

    func testMonthlyGroupByAliasResolves() {
        guard case .success(let q) = map(.init(aggregate: "sum", groupBy: "monthly")) else { return XCTFail() }
        XCTAssertEqual(q.groupBy, .month)
    }

    // MARK: renderer wording

    private let money: (Decimal, String?) -> String = { amt, _ in "₹\(amt)" }

    func testRendererSpendScalar() {
        let q = Query(filters: [.direction(.debit), .category(CategoryID("Pharmacy"))], aggregate: .sum)
        let r = QueryResult(scalar: .money(700), citations: [TransactionID("a"), TransactionID("b")],
                            currency: Currency("INR"))
        let text = ResultRenderer.render(r, query: q, vocabulary: vocab, money: money)
        XCTAssertEqual(text, "**You spent ₹700 on Pharmacy** across 2 transactions.")
    }

    func testRendererCountAndEmpty() {
        let q = Query(filters: [.direction(.debit)], aggregate: .count)
        let r = QueryResult(scalar: .count(7))
        XCTAssertEqual(ResultRenderer.render(r, query: q, vocabulary: vocab, money: money),
                       "**7 debits.**")
        let none = QueryResult(scalar: ScalarValue.none)
        XCTAssertTrue(ResultRenderer.render(none, query: q, vocabulary: vocab, money: money)!
            .contains("Nothing matching"))
    }

    func testRendererGroupedByMonth() {
        let q = Query(filters: [.direction(.debit)], aggregate: .sum, groupBy: .month)
        let r = QueryResult(groups: [
            GroupResult(key: "2026-01", result: QueryResult(scalar: .money(950), citations: [TransactionID("x")], currency: Currency("INR"))),
            GroupResult(key: "2025-12", result: QueryResult(scalar: .money(750), citations: [TransactionID("y")], currency: Currency("INR"))),
        ])
        let text = ResultRenderer.render(r, query: q, vocabulary: vocab, money: money)!
        XCTAssertTrue(text.hasPrefix("**By month:**"), text)
        XCTAssertTrue(text.contains("1. 2026-01 — ₹950"), text)
    }
}
