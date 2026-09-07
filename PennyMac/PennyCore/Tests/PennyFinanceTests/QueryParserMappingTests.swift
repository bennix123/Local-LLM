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
        // Since the judge run (2026-09-04), text must ALSO be substantiated by
        // the data — "refund" names no merchant/category in this vocabulary, so
        // it drops too (see testUnsubstantiatedTextIsDropped for the policy).
        guard case .success(let q2) = map(.init(aggregate: "sum", text: "refund")) else { return XCTFail() }
        XCTAssertFalse(q2.filters.contains(.text("refund")))
    }

    func testHallucinatedEntityIsDropped() {
        // Live-caught 2026-09-03: "show me largest transactions from top 2
        // catagories." — the model grabbed "Pharmacy" from the vocabulary and
        // leaked text:"largest". Neither may survive the mapper.
        let r = QueryDTOMapper.map(
            .init(aggregate: "max", direction: "debit", category: "Pharmacy", text: "largest"),
            vocabulary: vocab, today: today,
            question: "show me largest transactions from top 2 catagories.")
        guard case .success(let q) = r else { return XCTFail() }
        XCTAssertFalse(q.filters.contains { if case .category = $0 { return true }; return false },
                       "hallucinated category must be dropped: \(q.filters)")
        XCTAssertFalse(q.filters.contains { if case .text = $0 { return true }; return false },
                       "superlative text noise must be dropped: \(q.filters)")
    }

    func testGenuinelySaidEntitySurvivesTheGuard() {
        let r = QueryDTOMapper.map(
            .init(aggregate: "sum", direction: "debit", category: "pharamcy"),
            vocabulary: vocab, today: today,
            question: "how much did i spend on pharamcy?")
        guard case .success(let q) = r else { return XCTFail() }
        XCTAssertTrue(q.filters.contains(.category(CategoryID("Pharmacy"))), "\(q.filters)")
    }

    func testSemanticSynonymMappingIsTrusted() {
        // "eating out" shares no word with "Fast Food" — but that's exactly the
        // semantic mapping the model is FOR. The guard must not drop it
        // (2026-09-04: the original shares-a-word guard did).
        let r = QueryDTOMapper.map(
            .init(aggregate: "sum", direction: "debit", category: "Fast Food"),
            vocabulary: vocab, today: today,
            question: "how much did i spend eating out?")
        guard case .success(let q) = r else { return XCTFail() }
        XCTAssertTrue(q.filters.contains(.category(CategoryID("Fast Food"))), "\(q.filters)")
    }

    func testQuestionWordOverridesModelsCategorySlip() {
        // The question plainly says "shoping" (→ Shopping); a model slip to
        // Pharmacy is overridden by our own resolution — the question wins.
        let r = QueryDTOMapper.map(
            .init(aggregate: "sum", direction: "debit", category: "Pharmacy"),
            vocabulary: vocab, today: today,
            question: "how much did i spend on shoping?")
        guard case .success(let q) = r else { return XCTFail() }
        XCTAssertTrue(q.filters.contains(.category(CategoryID("Shopping"))), "\(q.filters)")
        XCTAssertFalse(q.filters.contains(.category(CategoryID("Pharmacy"))), "\(q.filters)")
    }

    func testMonthlyGroupByAliasResolves() {
        guard case .success(let q) = map(.init(aggregate: "sum", groupBy: "monthly")) else { return XCTFail() }
        XCTAssertEqual(q.groupBy, .month)
    }

    // MARK: judge-run absorptions (real engine wrongs, 2026-09-04)

    func testSuperlativeByDimensionBecomesGroupedSum() {
        // "Which category did I spend the most on?" parsed as max (single
        // largest transaction). A superlative + generic dimension noun means
        // ranked per-dimension totals.
        let r = QueryDTOMapper.map(
            .init(aggregate: "max", direction: "debit"),
            vocabulary: vocab, today: today,
            question: "Which category did I spend the most on?")
        guard case .success(let q) = r else { return XCTFail() }
        XCTAssertEqual(q.aggregate, .sum)
        XCTAssertEqual(q.groupBy, .category)
    }

    func testLeastSuperlativeFlagsAscending() {
        let r = QueryDTOMapper.map(
            .init(aggregate: "min", direction: "debit"),
            vocabulary: vocab, today: today,
            question: "which month did i spend the least?")
        guard case .success(let q) = r else { return XCTFail() }
        XCTAssertEqual(q.aggregate, .sum)
        XCTAssertEqual(q.groupBy, .month)
        XCTAssertEqual(q.sort.first?.order, .ascending)
    }

    func testScopedSuperlativeStaysAMax() {
        // "biggest transaction this month" — the noun is a PERIOD, not a
        // dimension; the conversion must not fire.
        let r = QueryDTOMapper.map(
            .init(aggregate: "max", direction: "debit", period: "this_month"),
            vocabulary: vocab, today: today,
            question: "biggest transaction this month?")
        guard case .success(let q) = r else { return XCTFail() }
        XCTAssertEqual(q.aggregate, .max)
        XCTAssertNil(q.groupBy)
    }

    func testModelSetGroupByWithMinStillBecomesTotals() {
        // Round 2: model emitted min + groupBy month for "which month did i
        // spend the least?" — the engine computed the smallest TXN per month
        // (Dec ₹300, not the ₹750 total). Converts to sum even when the model
        // already grouped.
        let r = QueryDTOMapper.map(
            .init(aggregate: "min", direction: "debit", groupBy: "month"),
            vocabulary: vocab, today: today,
            question: "Which month did I spend the least?")
        guard case .success(let q) = r else { return XCTFail() }
        XCTAssertEqual(q.aggregate, .sum)
        XCTAssertEqual(q.groupBy, .month)
        XCTAssertEqual(q.sort.first?.order, .ascending)
    }

    func testTopNWithDimensionNounGroups() {
        // Round 2: "top merchant by spend?" returned the top TRANSACTION.
        let r = QueryDTOMapper.map(
            .init(aggregate: "top_n", topN: 1),
            vocabulary: vocab, today: today, question: "top merchant by spend?")
        guard case .success(let q) = r else { return XCTFail() }
        XCTAssertEqual(q.aggregate, .topN(1))
        XCTAssertEqual(q.groupBy, .merchant)
        XCTAssertTrue(q.filters.contains(.direction(.debit)), "\(q.filters)")
    }

    func testShortQuestionWordsCannotVouchForEntities() {
        // Round 2: the question word "i" matched inside "dInIng", letting a
        // hallucinated "Food & Dining" through the guard on a generic
        // categories question.
        let r = QueryDTOMapper.map(
            .init(aggregate: "max", direction: "debit", category: "Food & Dining",
                  groupBy: "category"),
            vocabulary: vocab, today: today,
            question: "Which category did I spend the most on?")
        guard case .success(let q) = r else { return XCTFail() }
        XCTAssertFalse(q.filters.contains { if case .category = $0 { return true }; return false },
                       "hallucinated category must drop: \(q.filters)")
        XCTAssertEqual(q.aggregate, .sum)
        XCTAssertEqual(q.groupBy, .category)
    }

    func testUndirectedSuperlativeDefaultsToDebit() {
        // Undirected max crowned a ₹5,200 SALARY credit "your largest expense".
        let r = QueryDTOMapper.map(
            .init(aggregate: "max"),
            vocabulary: vocab, today: today, question: "biggest transaction amount?")
        guard case .success(let q) = r else { return XCTFail() }
        XCTAssertTrue(q.filters.contains(.direction(.debit)), "\(q.filters)")
    }

    func testUnsubstantiatedTextIsDropped() {
        // text:"inflow"/"aamdani"/"outgoing payments" each made a confident
        // ₹0.00 — text survives only when the DATA contains it.
        for noise in ["inflow", "aamdani", "outgoing payments", "receive"] {
            guard case .success(let q) = map(.init(aggregate: "sum", direction: "credit",
                                                   text: noise)) else { return XCTFail() }
            XCTAssertFalse(q.filters.contains { if case .text = $0 { return true }; return false },
                           "'\(noise)' must not become a text filter")
        }
        // …but a term the data substantiates survives (Medplus is a merchant).
        guard case .success(let q) = map(.init(aggregate: "sum", text: "medplus")) else { return XCTFail() }
        XCTAssertTrue(q.filters.contains(.text("medplus")), "\(q.filters)")
    }

    func testHallucinatedTodayPeriodIsDropped() {
        let r = QueryDTOMapper.map(
            .init(aggregate: "average", direction: "debit", period: "today"),
            vocabulary: vocab, today: today,
            question: "typical amount I spend each time")
        guard case .success(let q) = r else { return XCTFail() }
        XCTAssertFalse(q.filters.contains { if case .dateRange = $0 { return true }; return false },
                       "unsaid 'today' must be dropped: \(q.filters)")
    }

    func testRendererShowsMagnitudesForDirectedSums() {
        // Engine sums are signed (debits negative); "You spent ₹-3,670.00" is
        // nonsense to a reader.
        let q = Query(filters: [.direction(.debit)], aggregate: .sum)
        let r = QueryResult(scalar: .money(-3670), citations: [TransactionID("a")],
                            currency: Currency("INR"))
        let text = ResultRenderer.render(r, query: q, vocabulary: vocab,
                                         money: { amt, _ in "₹\(amt)" })
        XCTAssertEqual(text, "**You spent ₹3670** across 1 transaction.")
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
