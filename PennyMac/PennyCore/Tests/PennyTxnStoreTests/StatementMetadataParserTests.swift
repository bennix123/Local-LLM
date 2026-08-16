// StatementMetadataParserTests — header-metadata extraction (Task 0.5): balances,
// the Amex columnar credit summary, period/statement date, account number / sort
// code / holder, and honest nil on no-match. Hermetic (text snippets mirroring the
// real statements' layout).
import XCTest
import Foundation
@testable import PennyTxnStore
import PennyModel

final class StatementMetadataParserTests: XCTestCase {

    private func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }

    // MARK: balances

    func testOpeningAndClosingBalance() {
        XCTAssertEqual(StatementMetadataParser.openingBalance(in: "Opening Balance £42.20"), dec("42.20"))
        XCTAssertEqual(StatementMetadataParser.openingBalance(in: "Balance brought forward 1,234.56"), dec("1234.56"))
        XCTAssertNil(StatementMetadataParser.openingBalance(in: "Closing balance £900.00"),
                     "must not read closing as opening")
        XCTAssertEqual(StatementMetadataParser.Balances.closing("Closing balance £900.00"), dec("900.00"))
    }

    // MARK: Amex columnar credit summary

    func testCreditSummaryColumnar() {
        let text = "Credit Summary\nCredit Limit £ Available Credit Limit £\n16,100.00 15,470.46\nRates"
        let s = StatementMetadataParser.creditSummary(in: text)
        XCTAssertEqual(s.limit, dec("16100.00"))
        XCTAssertEqual(s.available, dec("15470.46"))
    }

    func testCreditSummaryFallbackSingleLabels() {
        let s = StatementMetadataParser.creditSummary(in: "Credit Limit £5,000.00\nAvailable Credit £1,200.00")
        XCTAssertEqual(s.limit, dec("5000.00"))
        XCTAssertEqual(s.available, dec("1200.00"))
    }

    // MARK: dates

    func testStatementPeriodAcrossFormats() {
        let a = StatementMetadataParser.parse(text: "Statement period: 16 May 2026 to 15 June 2026")
        XCTAssertEqual(a.period, CalendarDateRange(start: CalendarDate(year: 2026, month: 5, day: 16),
                                                   end: CalendarDate(year: 2026, month: 6, day: 15)))
        let b = StatementMetadataParser.parse(text: "Period: 01/06/2026 - 30/06/2026")
        XCTAssertEqual(b.period, CalendarDateRange(start: CalendarDate(year: 2026, month: 6, day: 1),
                                                   end: CalendarDate(year: 2026, month: 6, day: 30)))
    }

    func testStatementDate() {
        XCTAssertEqual(StatementMetadataParser.parse(text: "Statement date: 1 July 2026").statementDate,
                       CalendarDate(year: 2026, month: 7, day: 1))
        XCTAssertEqual(StatementMetadataParser.parse(text: "Issued: 2026-07-01").statementDate,
                       CalendarDate(year: 2026, month: 7, day: 1))
    }

    func testAmexStatementDateAndHolder() {
        // Real Amex "Platinum Card" header layout (no "Statement date:" label).
        let header = """
        Prepared for Membership Number Date
        PIYUSH MISHRA xxxx-xxxxxx-01001 15/03/26
        Account Summary
        Statement includes payments and charges received by 15 March 2026
        """
        let m = StatementMetadataParser.parse(text: header)
        XCTAssertEqual(m.statementDate, CalendarDate(year: 2026, month: 3, day: 15),
                       "Amex closing date should be read as 15 March 2026")
        XCTAssertEqual(m.holder, "PIYUSH MISHRA",
                       "Amex 'Prepared for' name should be captured before the membership mask")
    }

    // MARK: account details

    func testAccountDetails() {
        let m = StatementMetadataParser.parse(text:
            "Account holder: R Tester\nAccount number: 12345678\nSort code: 04-00-04")
        XCTAssertEqual(m.accountNumber, "12345678")
        XCTAssertEqual(m.sortCode, "04-00-04")
        XCTAssertEqual(m.holder, "R Tester")
    }

    // MARK: honest absence

    func testMissingMetadataIsNil() {
        let m = StatementMetadataParser.parse(text: "just some transactions, no header block here")
        XCTAssertNil(m.openingBalance); XCTAssertNil(m.creditLimit); XCTAssertNil(m.period)
        XCTAssertNil(m.statementDate); XCTAssertNil(m.accountNumber); XCTAssertNil(m.sortCode); XCTAssertNil(m.holder)
    }
}
