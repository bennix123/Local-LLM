// GoldenCorpusTests — drives the FinanceCorpus regression suite (Waves A1 + A2).
// For every entry it verifies the deterministic pipeline in lockstep:
//   1. bridge:  question → expectedQuery (when bridgeExpected)
//   2. engine:  expectedQuery → expectedResult (figures), consuming the recurring analysis
//   3. router:  question → expectedRouter (parity target, when one exists)
//   4. codable: expectedQuery round-trips through JSON (LLM-parser portability)
// Plus the capability-registry invariants and the RecurringAnalyzer↔router parity.
import XCTest
import Foundation
@testable import PennyFinance
import PennyModel
import PennyTxnStore

final class GoldenCorpusTests: XCTestCase {

    private func money(_ v: Double) -> String { "£" + String(format: "%.2f", v) }

    private func row(_ seq: Int, _ date: String, _ descr: String, merchant: String = "", category: String = "",
                     debit: Double = 0, credit: Double = 0, balance: Double? = nil) -> TxnRow {
        let p = date.split(separator: "-").compactMap { Int($0) }
        return TxnRow(txnDate: date, month: String(date.prefix(7)), year: p[0], monthNo: p[1], day: p[2],
                      descr: descr, merchant: merchant, category: category,
                      debit: debit, credit: credit, balance: balance, currency: "GBP", seq: seq)
    }

    // A1 — transaction aggregates.
    private func aggregatesFixture() -> (rows: [TxnRow], graph: FinancialGraph) {
        let rows = [
            row(1, "2026-06-01", "TESCO", category: "Groceries", debit: 45.50),
            row(2, "2026-06-05", "SALARY", credit: 2500.00),
            row(3, "2026-06-10", "AMAZON", category: "Shopping", debit: 120.00),
            row(4, "2026-07-12", "ACME LETTINGS", category: "Rent", debit: 600.00),
        ]
        let out = IngestOutput(rows: rows, bankName: "Monzo", confidence: "test", detectedCurrency: "GBP")
        return (rows, ModelAssembler.assemble(out, sourceName: "monzo.pdf").graph)
    }

    // A2 — balances & recurring: running balances, opening 1000 / closing 2330.03,
    // NETFLIX 9.99 recurring across May/Jun/Jul.
    private func balancesFixture() -> (rows: [TxnRow], graph: FinancialGraph) {
        let rows = [
            row(1, "2026-05-15", "NETFLIX", debit: 9.99,  balance: 990.01),
            row(2, "2026-05-20", "TESCO",   debit: 40.00, balance: 950.01),
            row(3, "2026-06-15", "NETFLIX", debit: 9.99,  balance: 940.02),
            row(4, "2026-06-25", "SALARY",  credit: 2000.00, balance: 2940.02),
            row(5, "2026-07-15", "NETFLIX", debit: 9.99,  balance: 2930.03),
            row(6, "2026-07-28", "RENT",    debit: 600.00, balance: 2330.03),
        ]
        let out = IngestOutput(rows: rows, bankName: "Monzo", confidence: "test",
                               detectedCurrency: "GBP", closingBalance: 2330.03)
        let metadata = StatementMetadata(openingBalance: Money(Decimal(string: "1000.00")!))
        return (rows, ModelAssembler.assemble(out, sourceName: "monzo.pdf", metadata: metadata).graph)
    }

    // B1 — structured scope: merchants + categories across June/July.
    private func scopeFixture() -> (rows: [TxnRow], graph: FinancialGraph) {
        let rows = [
            row(1, "2026-06-01", "TESCO",  merchant: "Tesco",  category: "Groceries", debit: 45.50),
            row(2, "2026-06-10", "AMAZON", merchant: "Amazon", category: "Shopping",  debit: 120.00),
            row(3, "2026-06-15", "TESCO",  merchant: "Tesco",  category: "Groceries", debit: 30.00),
            row(4, "2026-07-12", "AMAZON", merchant: "Amazon", category: "Shopping",  debit: 200.00),
        ]
        let out = IngestOutput(rows: rows, bankName: "Monzo", confidence: "test", detectedCurrency: "GBP")
        return (rows, ModelAssembler.assemble(out, sourceName: "monzo.pdf").graph)
    }

    func testGoldenCorpus() {
        let fixtures: [CorpusFixture: (rows: [TxnRow], graph: FinancialGraph)] = [
            .aggregates: aggregatesFixture(), .balances: balancesFixture(), .scope: scopeFixture(),
        ]

        for e in FinanceCorpus.entries {
            let (rows, graph) = fixtures[e.fixture]!
            let analysis = AnalysisContext.from(recurring: RecurringAnalyzer.analyze(graph))
            let context = QueryContext(vocabulary: QueryVocabulary.from(graph))

            // 1. bridge: question → expectedQuery (interpreted against the data vocabulary)
            if e.bridgeExpected {
                XCTAssertEqual(LegacyQueryBridge.query(for: e.query, context: context), e.expectedQuery,
                               "[\(e.intent)] bridge query mismatch")
            }

            // 2. engine: expectedQuery → expectedResult (consuming the recurring analysis)
            let result = QueryEngine.execute(e.expectedQuery, in: graph, analysis: analysis)
            assertResult(result, matches: e.expectedResult, intent: e.intent)

            // 3. router parity (when the router has a faithful equivalent)
            if let expectedRouter = e.expectedRouter {
                let actual = FinanceRouter.answer(e.query, rows: rows, currency: "GBP",
                                                  accounts: [], money: money)
                XCTAssertEqual(actual, expectedRouter, "[\(e.intent)] FinanceRouter output mismatch")
            }

            // 4. Codable round-trip (LLM-parser portability)
            do {
                let data = try JSONEncoder().encode(e.expectedQuery)
                let decoded = try JSONDecoder().decode(Query.self, from: data)
                XCTAssertEqual(decoded, e.expectedQuery, "[\(e.intent)] Query is not JSON-stable")
            } catch { XCTFail("[\(e.intent)] Query failed to encode/decode: \(error)") }
        }
    }

    /// The dedicated analyzer must reconcile with FinanceRouter.recurringCharges.
    func testRecurringAnalyzerParity() {
        let (rows, graph) = balancesFixture()
        let engine = RecurringAnalyzer.analyze(graph)
        let router = FinanceRouter.recurringCharges(rows)

        XCTAssertEqual(engine.count, 1)
        XCTAssertEqual(router.count, 1)
        guard let e = engine.first, let r = router.first else { return XCTFail() }
        XCTAssertEqual(e.name, r.name)
        XCTAssertEqual(e.name, "NETFLIX")
        XCTAssertEqual(e.months, r.months)
        XCTAssertEqual(e.count, r.count)
        XCTAssertEqual(e.amount, r.amount, accuracy: 0.0001)
        XCTAssertEqual(e.confidence, r.confidence, accuracy: 0.0001)
        XCTAssertEqual(e.transactionIDs.count, 3)
    }

    // MARK: - ScopeResolver (Wave B1 structured resolution)

    func testScopeResolverAccountAndCurrency() {
        // account resolves by name → id; currency by code, only if present in data.
        let vocab = QueryVocabulary(
            accounts: [.init(name: "American Express", id: "acc-amex")],
            currencies: ["GBP", "USD"])
        let acct = ScopeResolver.resolve("what did I spend in USD on American Express", vocabulary: vocab)
        XCTAssertTrue(acct.filters.contains(.account(AccountID("acc-amex"))))
        XCTAssertTrue(acct.filters.contains(.currency(Currency("USD"))))

        // a currency not present in the data is not resolved
        let eur = ScopeResolver.resolve("spending in EUR", vocabulary: QueryVocabulary(currencies: ["GBP"]))
        XCTAssertTrue(eur.filters.isEmpty)
    }

    func testScopeResolverExplicitDateForms() {
        let june15 = Filter.dateRange(CalendarDateRange(start: CalendarDate(year: 2026, month: 6, day: 15),
                                                        end: CalendarDate(year: 2026, month: 6, day: 15)))
        for q in ["on 2026-06-15", "on 15/06/2026", "on 15 June 2026", "on June 15, 2026"] {
            XCTAssertEqual(ScopeResolver.resolve(q, vocabulary: .empty).filters, [june15], "date form: \(q)")
        }
        // a month+year yields the whole month; a bare year yields the whole year
        XCTAssertEqual(ScopeResolver.resolve("in June 2026", vocabulary: .empty).filters,
                       [.dateRange(CalendarDateRange(start: CalendarDate(year: 2026, month: 6, day: 1),
                                                     end: CalendarDate(year: 2026, month: 6, day: 30)))])
        XCTAssertEqual(ScopeResolver.resolve("during 2026", vocabulary: .empty).filters,
                       [.dateRange(CalendarDateRange(start: CalendarDate(year: 2026, month: 1, day: 1),
                                                     end: CalendarDate(year: 2026, month: 12, day: 31)))])
    }

    func testScopeResolverFlagsAmbiguityAndAvoidsSubstrings() {
        // two disjoint categories in one question → ambiguous: emit NO filter (don't guess)
        let vocab = QueryVocabulary(categories: ["Groceries", "Rent"])
        let amb = ScopeResolver.resolve("groceries and rent", vocabulary: vocab)
        XCTAssertTrue(amb.isAmbiguous)
        XCTAssertTrue(amb.filters.isEmpty, "an ambiguous category scope must not resolve to a filter")
        XCTAssertEqual(amb.unresolvedTerms, ["Groceries", "Rent"])
        // "rent" must not match inside "current" (word boundary + word-stem synonym)
        XCTAssertTrue(ScopeResolver.resolve("my current account", vocabulary: QueryVocabulary(categories: ["Rent"])).filters.isEmpty)
    }

    func testScopeResolverMerchantAlias() {
        // "amex" resolves to the present "American Express" (alias, engine-only — the
        // router has no alias support, so this is a deterministic enhancement).
        let vocab = QueryVocabulary(merchants: ["American Express"])
        let r = ScopeResolver.resolve("how much on amex", vocabulary: vocab)
        XCTAssertEqual(r.filters, [.merchant(.name("American Express"))])
    }

    func testScopeResolverLongestMatch() {
        // "Tesco" is subsumed by the more specific "Tesco Express".
        let vocab = QueryVocabulary(merchants: ["Tesco", "Tesco Express"])
        let r = ScopeResolver.resolve("spent at tesco express", vocabulary: vocab)
        XCTAssertEqual(r.filters, [.merchant(.name("Tesco Express"))])
        XCTAssertFalse(r.isAmbiguous)
    }

    func testScopeSynonymOnlyResolvesPresentCategories() {
        // "cash flow" must NOT scope to Cash & ATM when that category isn't in the data.
        let r = ScopeResolver.resolve("what is my net cash flow", vocabulary: QueryVocabulary(categories: ["Groceries"]))
        XCTAssertTrue(r.filters.isEmpty)
    }

    // MARK: - capability registry invariants (Decision 1)

    /// Every corpus intent belongs to a registered capability.
    func testEveryIntentHasACapability() {
        for e in FinanceCorpus.entries {
            XCTAssertNotNil(CapabilityRegistry.capability(forIntent: e.intent),
                            "[\(e.intent)] has no owning capability")
        }
    }

    /// Only capabilities that reconcile with the router may reach `.activated`:
    /// every entry of an activated capability must have a router parity target.
    func testActivatedCapabilitiesHaveRouterParity() {
        for e in FinanceCorpus.entries {
            guard let cap = CapabilityRegistry.capability(forIntent: e.intent), cap.state == .activated
            else { continue }
            XCTAssertNotNil(e.expectedRouter, "[\(e.intent)] activated capability without router parity")
        }
    }

    // MARK: - result matching

    private func assertResult(_ r: QueryResult, matches expected: ExpectedResult, intent: String) {
        switch expected {
        case .count(let n):
            XCTAssertEqual(r.scalar, .count(n), "[\(intent)] count")

        case .money(let amount, let citations):
            guard case .money(let m)? = r.scalar else { return XCTFail("[\(intent)] expected money scalar") }
            XCTAssertEqual(abs(m), amount, "[\(intent)] money magnitude")
            XCTAssertEqual(r.citations.count, citations, "[\(intent)] citations")

        case .rows(let magnitudes):
            XCTAssertEqual(r.rows.map { $0.amount.magnitude }, magnitudes, "[\(intent)] row magnitudes")

        case .groups(let expected):
            let actual = Dictionary(uniqueKeysWithValues: (r.groups ?? []).map { g -> (String, Decimal) in
                if case .money(let m)? = g.result.scalar { return (g.key, abs(m)) }
                return (g.key, 0)
            })
            XCTAssertEqual(actual, expected, "[\(intent)] group breakdown")
        }
    }
}
