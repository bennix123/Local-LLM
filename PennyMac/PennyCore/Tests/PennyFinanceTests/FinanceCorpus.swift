// FinanceCorpus — the golden query corpus (Waves A1 + A2).
//
// The long-term regression suite for the bridge, the Query Engine, and the future
// LLM parser. Each entry ties together the things that must stay in lockstep:
//
//   • query          — the natural-language question
//   • expectedQuery  — the Query the bridge must produce (when bridgeExpected)
//   • expectedResult — the QueryResult the engine must compute (figures)
//   • expectedRouter — the FinanceRouter string (parity target; nil when the router
//                      has no faithful equivalent — verified vs the parsed source)
//   • fixture        — which dataset the figures belong to
//
// Lifecycle state is NOT stored per entry: a *capability* owns it (see
// `CapabilityRegistry`), and each intent belongs to a capability. Only capabilities
// in the `.activated` state may replace FinanceRouter (Decision 1).
//
// `Query` is Codable, so the whole corpus is exportable to JSON for the LLM parser.
import Foundation
import PennyFinance
import PennyModel

/// The engine outcome an entry expects (money compared by magnitude — sign is the
/// engine's signed convention; the router reports magnitudes).
enum ExpectedResult: Equatable {
    case count(Int)
    case money(Decimal, citations: Int)
    case rows(magnitudes: [Decimal])
    case groups([String: Decimal])
}

/// Which shared dataset an entry's figures belong to.
enum CorpusFixture { case aggregates, balances, scope }

struct CorpusEntry {
    let intent: String
    let query: String
    let expectedQuery: Query
    let expectedResult: ExpectedResult
    let expectedRouter: String?
    let fixture: CorpusFixture
    /// False when the bridge can't yet produce the query from language alone
    /// (e.g. it needs date parsing — Wave B); the engine/router are still checked.
    let bridgeExpected: Bool

    init(intent: String, query: String, expectedQuery: Query, expectedResult: ExpectedResult,
         expectedRouter: String?, fixture: CorpusFixture = .aggregates, bridgeExpected: Bool = true) {
        self.intent = intent; self.query = query; self.expectedQuery = expectedQuery
        self.expectedResult = expectedResult; self.expectedRouter = expectedRouter
        self.fixture = fixture; self.bridgeExpected = bridgeExpected
    }
}

enum FinanceCorpus {

    private static func dec(_ s: String) -> Decimal {
        Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))!
    }

    static let entries: [CorpusEntry] = aggregates + balances + scoped

    // MARK: Wave A1 — transaction aggregates
    // Fixture: TESCO 45.50 Groceries · SALARY 2500 credit · AMAZON 120 Shopping ·
    //          ACME 600 Rent, spanning June/July 2026.
    private static let aggregates: [CorpusEntry] = [
        CorpusEntry(
            intent: "count",
            query: "how many transactions do I have?",
            expectedQuery: Query(aggregate: .count),
            expectedResult: .count(4),
            expectedRouter: "**4 transactions.**"),

        CorpusEntry(
            intent: "count_debits",
            query: "how many payments did I make?",
            expectedQuery: Query(filters: [.direction(.debit)], aggregate: .count),
            expectedResult: .count(3),
            expectedRouter: "**3 debits.**"),

        CorpusEntry(
            intent: "count_credits",
            query: "number of credits?",
            expectedQuery: Query(filters: [.direction(.credit)], aggregate: .count),
            expectedResult: .count(1),
            expectedRouter: "**1 credit.**"),

        CorpusEntry(
            intent: "total_spend",
            query: "total spending",
            expectedQuery: Query(filters: [.direction(.debit)], aggregate: .sum),
            expectedResult: .money(dec("765.50"), citations: 3),
            expectedRouter: "**You spent £765.50** across 3 transactions."),

        CorpusEntry(
            intent: "total_income",
            query: "total income",
            expectedQuery: Query(filters: [.direction(.credit)], aggregate: .sum),
            expectedResult: .money(dec("2500.00"), citations: 1),
            expectedRouter: "**You received £2500.00** across 1 credit."),

        CorpusEntry(
            intent: "net_cashflow",
            query: "what is my net cash flow?",
            expectedQuery: Query(filters: [], aggregate: .sum),
            expectedResult: .money(dec("1734.50"), citations: 4),
            expectedRouter: "**Net: £1734.50** — £2500.00 in minus £765.50 out. You kept £1734.50."),

        CorpusEntry(
            intent: "average_transaction",
            query: "what's my average transaction?",
            expectedQuery: Query(filters: [.direction(.debit)], aggregate: .average),
            expectedResult: .money(dec("765.50") / 3, citations: 3),
            expectedRouter: "**Your average transaction is £255.17** across 3 debits."),

        CorpusEntry(
            intent: "largest_expense",
            query: "biggest expense",
            expectedQuery: Query(filters: [.direction(.debit)], aggregate: .max),
            expectedResult: .money(dec("600.00"), citations: 1),
            expectedRouter: "**Your largest expense was £600.00** — ACME LETTINGS on 12th July 2026."),

        CorpusEntry(
            intent: "smallest_expense",
            query: "what's my smallest purchase?",
            expectedQuery: Query(filters: [.direction(.debit)], aggregate: .min),
            expectedResult: .money(dec("45.50"), citations: 1),
            expectedRouter: "**Your smallest expense was £45.50** — TESCO on 1st June 2026."),

        CorpusEntry(
            intent: "topN_expenses",
            query: "top 3 expenses",
            expectedQuery: Query(filters: [.direction(.debit)], aggregate: .topN(3),
                                 sort: [SortKey(.amount, .descending)]),
            expectedResult: .rows(magnitudes: [dec("600.00"), dec("120.00"), dec("45.50")]),
            expectedRouter: "**Your top 3 expenses:**\n1. £600.00 — ACME LETTINGS (12th July 2026)\n2. £120.00 — AMAZON (10th June 2026)\n3. £45.50 — TESCO (1st June 2026)"),

        CorpusEntry(
            intent: "spend_by_category",
            query: "spending by category",
            expectedQuery: Query(filters: [.direction(.debit)], aggregate: .sum, groupBy: .category),
            expectedResult: .groups(["Rent": dec("600.00"), "Shopping": dec("120.00"), "Groceries": dec("45.50")]),
            expectedRouter: "**Spending by category:**\n- **Rent**: £600.00 (78.4%)\n- **Shopping**: £120.00 (15.7%)\n- **Groceries**: £45.50 (5.9%)"),

        CorpusEntry(
            intent: "monthly_summary",
            query: "spending by month",
            expectedQuery: Query(filters: [.direction(.debit)], aggregate: .sum, groupBy: .month),
            expectedResult: .groups(["2026-06": dec("165.50"), "2026-07": dec("600.00")]),
            // A1 class 2: the router now has a real month-by-month capability —
            // the previous expectation pinned its old fallback (the bare total).
            expectedRouter: "**Month by month:**\n- June 2026 — spent £165.50, received £2500.00\n- July 2026 — spent £600.00"),
    ]

    // MARK: Wave A2 — balances & recurring
    // Fixture: one current account, opening 1000 / closing 2330.03, running balances,
    // NETFLIX 9.99 in May/Jun/Jul (recurring), plus TESCO, SALARY 2000, RENT 600.
    private static let balances: [CorpusEntry] = [
        // Opening/closing have no faithful FinanceRouter string (the router defers
        // opening to the document text and reports closing as "latest") — verified
        // against the parsed statement field.
        CorpusEntry(
            intent: "balance_opening",
            query: "opening balance",
            expectedQuery: Query(aggregate: .balance(.opening)),
            expectedResult: .money(dec("1000.00"), citations: 0),
            expectedRouter: nil, fixture: .balances),

        CorpusEntry(
            intent: "balance_closing",
            query: "closing balance",
            expectedQuery: Query(aggregate: .balance(.closing)),
            expectedResult: .money(dec("2330.03"), citations: 0),
            expectedRouter: nil, fixture: .balances),

        CorpusEntry(
            intent: "balance_running",
            query: "what is my latest balance?",
            expectedQuery: Query(aggregate: .balance(.running)),
            expectedResult: .money(dec("2330.03"), citations: 1),
            expectedRouter: "**Your latest balance is £2330.03.**", fixture: .balances),

        // Balance-at-date needs date parsing (Wave B): the engine + router are still
        // verified from a directly-built query.
        CorpusEntry(
            intent: "balance_at_date",
            query: "what was my balance on 30 June 2026?",
            expectedQuery: Query(aggregate: .balance(.atDate(CalendarDate(year: 2026, month: 6, day: 30)))),
            expectedResult: .money(dec("2940.02"), citations: 1),
            expectedRouter: "**Your balance at the end of 30th June 2026 was £2940.02.**",
            fixture: .balances, bridgeExpected: false),

        // The engine consumes the RecurringAnalyzer output (3 NETFLIX debits). The
        // router's recurring answer is a summary, not a count, so analyzer↔router
        // parity is checked separately in testRecurringAnalyzerParity.
        CorpusEntry(
            intent: "recurring",
            query: "what are my recurring charges?",
            expectedQuery: Query(filters: [.recurring], aggregate: .count),
            expectedResult: .count(3),
            expectedRouter: nil, fixture: .balances),
    ]

    // MARK: Wave B1 — structured scope resolution
    // Fixture: TESCO 45.50 Groceries (Jun 1) · AMAZON 120 Shopping (Jun 10) ·
    //          TESCO 30 Groceries (Jun 15) · AMAZON 200 Shopping (Jul 12).
    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Filter {
        .dateRange(CalendarDateRange(start: CalendarDate(year: y, month: m, day: d),
                                     end: CalendarDate(year: y, month: m, day: d)))
    }
    private static let scoped: [CorpusEntry] = [
        CorpusEntry(
            intent: "scope_category",
            query: "how much did I spend on groceries",
            expectedQuery: Query(filters: [.category(CategoryID("Groceries")), .direction(.debit)], aggregate: .sum),
            expectedResult: .money(dec("75.50"), citations: 2),
            expectedRouter: "**You spent £75.50 on Groceries** across 2 transactions.", fixture: .scope),

        CorpusEntry(
            intent: "scope_merchant",
            query: "how much did I spend at Amazon",
            expectedQuery: Query(filters: [.merchant(.name("Amazon")), .direction(.debit)], aggregate: .sum),
            expectedResult: .money(dec("320.00"), citations: 2),
            expectedRouter: "**You spent £320.00 at Amazon** across 2 transactions.", fixture: .scope),

        CorpusEntry(
            intent: "scope_date",
            query: "what did I spend on 15 June 2026",
            expectedQuery: Query(filters: [day(2026, 6, 15), .direction(.debit)], aggregate: .sum),
            expectedResult: .money(dec("30.00"), citations: 1),
            expectedRouter: "**You spent £30.00 on 15th June 2026** across 1 transaction.", fixture: .scope),

        CorpusEntry(
            intent: "scope_month",
            query: "how much did I spend in June 2026",
            expectedQuery: Query(filters: [june2026, .direction(.debit)], aggregate: .sum),
            expectedResult: .money(dec("195.50"), citations: 3),
            expectedRouter: "**You spent £195.50 in June 2026** across 3 transactions.", fixture: .scope),

        // Wave B2 — category synonym ("grocery" → Groceries), parity with the router.
        CorpusEntry(
            intent: "scope_synonym",
            query: "how much did I spend on grocery",
            expectedQuery: Query(filters: [.category(CategoryID("Groceries")), .direction(.debit)], aggregate: .sum),
            expectedResult: .money(dec("75.50"), citations: 2),
            expectedRouter: "**You spent £75.50 on Groceries** across 2 transactions.", fixture: .scope),

        // Wave B2 — relative dates anchored to the data's months (Jun, Jul).
        CorpusEntry(
            intent: "scope_relative_month",
            query: "how much did I spend last month",
            expectedQuery: Query(filters: [june2026, .direction(.debit)], aggregate: .sum),
            expectedResult: .money(dec("195.50"), citations: 3),
            expectedRouter: "**You spent £195.50 last month** across 3 transactions.", fixture: .scope),

        CorpusEntry(
            intent: "scope_relative_month",
            query: "how much did I spend this month",
            expectedQuery: Query(filters: [.dateRange(CalendarDateRange(
                start: CalendarDate(year: 2026, month: 7, day: 1),
                end: CalendarDate(year: 2026, month: 7, day: 31))), .direction(.debit)], aggregate: .sum),
            expectedResult: .money(dec("200.00"), citations: 1),
            expectedRouter: "**You spent £200.00 this month** across 1 transaction.", fixture: .scope),
    ]

    private static let june2026 = Filter.dateRange(CalendarDateRange(
        start: CalendarDate(year: 2026, month: 6, day: 1),
        end: CalendarDate(year: 2026, month: 6, day: 30)))
}
