// EntitiesTests — the canonical entities after Amendment 01: lossless Codable
// round-trips (incl. a whole FinancialGraph), `direction` derivation, the
// parsed-state defaults, and the parsed/enriched boundary (merchant + clean
// description now live in Enrichment, dates are CalendarDate, fx is parsed).
import XCTest
import Foundation
@testable import PennyModel

final class EntitiesTests: XCTestCase {

    private func dec(_ s: String) -> Decimal {
        Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))!
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: try JSONEncoder().encode(value))
    }

    private let june15 = CalendarDate(year: 2026, month: 6, day: 15)

    // MARK: direction derivation

    func testTransactionDirectionDerivesFromSignedAmount() {
        let debit = Transaction(id: TransactionID("t1"), accountID: AccountID("a1"),
                                statementID: StatementID("s1"), date: june15,
                                rawDescription: "TESCO", amount: Money(dec("-45.50")), currency: .gbp)
        XCTAssertEqual(debit.direction, .debit, "negative amount ⇒ debit")

        let credit = Transaction(id: TransactionID("t2"), accountID: AccountID("a1"),
                                 statementID: StatementID("s1"), date: june15,
                                 rawDescription: "SALARY", amount: Money(dec("2500.00")), currency: .gbp)
        XCTAssertEqual(credit.direction, .credit, "positive amount ⇒ credit")
    }

    // MARK: parsed/enriched boundary + defaults

    func testParsedStateDefaultsAndEnrichedFieldsLiveInEnrichment() {
        let t = Transaction(id: TransactionID("t1"), accountID: AccountID("a1"),
                            statementID: StatementID("s1"), date: june15,
                            rawDescription: "RAW", amount: Money(dec("-1.00")), currency: .gbp)
        XCTAssertEqual(t.enrichment, .empty)
        // merchant + cleanDescription are now in Enrichment, not on Transaction.
        XCTAssertNil(t.enrichment.merchantID)
        XCTAssertNil(t.enrichment.cleanDescription)
        XCTAssertNil(t.enrichment.categoryID)
        XCTAssertEqual(t.enrichment.tags, [])
        XCTAssertTrue(t.enrichment.confidence.isEmpty)
        XCTAssertNil(t.fx, "fx is parsed and absent by default")
    }

    // MARK: Codable round-trips

    func testEntityCodableRoundTrips() throws {
        let account = Account(id: AccountID("a1"), institution: "Monzo", kind: .current,
                              number: "12345678", sortCode: "04-00-04", holder: "R Tester",
                              currency: .gbp)
        XCTAssertEqual(try roundTrip(account), account)

        let statement = Statement(id: StatementID("s1"), accountID: account.id, sourceName: "monzo.pdf",
                                  period: CalendarDateRange(start: CalendarDate(year: 2026, month: 6, day: 1),
                                                            end: CalendarDate(year: 2026, month: 6, day: 30)),
                                  statementDate: CalendarDate(year: 2026, month: 7, day: 1),
                                  openingBalance: Money(dec("100.00")),
                                  closingBalance: Money(dec("250.50")))
        XCTAssertEqual(try roundTrip(statement), statement)

        let enrichment = Enrichment(merchantID: MerchantID("bistro"), cleanDescription: "Le Petit Bistro",
                                    categoryID: CategoryID("food"), tags: [.foreign, .recurring],
                                    confidence: [.merchant: 0.9, .category: 0.75])
        XCTAssertEqual(try roundTrip(enrichment), enrichment)

        let fx = FXInfo(originalAmount: Money(dec("42.00")), originalCurrency: .eur,
                        rate: dec("0.86"), fee: Money(dec("1.20")), country: "FR")
        XCTAssertEqual(try roundTrip(fx), fx)

        let txn = Transaction(id: TransactionID("t1"), accountID: account.id, statementID: statement.id,
                              date: june15, processDate: CalendarDate(year: 2026, month: 6, day: 16),
                              rawDescription: "LE PETIT BISTRO PARIS", amount: Money(dec("-36.29")),
                              balance: Money(dec("213.71")), currency: .gbp, fx: fx, enrichment: enrichment)
        XCTAssertEqual(try roundTrip(txn), txn)

        let merchant = Merchant(id: MerchantID("amazon"), canonicalName: "Amazon",
                                defaultCategoryID: CategoryID("shopping"))
        XCTAssertEqual(try roundTrip(merchant), merchant)

        let category = Category(id: CategoryID("groceries"), name: "Groceries")
        XCTAssertEqual(try roundTrip(category), category)
    }

    func testFinancialGraphRoundTripAndEmpty() throws {
        XCTAssertEqual(FinancialGraph.empty.transactions.count, 0)
        XCTAssertEqual(FinancialGraph.empty.merchants.count, 0)

        let account = Account(id: AccountID("a1"), institution: "Monzo", kind: .current, currency: .gbp)
        let statement = Statement(id: StatementID("s1"), accountID: account.id, sourceName: "monzo.pdf")
        let txn = Transaction(id: TransactionID("t1"), accountID: account.id, statementID: statement.id,
                              date: june15, rawDescription: "TESCO",
                              amount: Money(dec("-45.50")), currency: .gbp)
        let graph = FinancialGraph(accounts: [account], statements: [statement], transactions: [txn])
        XCTAssertEqual(try roundTrip(graph), graph)
    }
}
