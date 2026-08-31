import XCTest
@testable import PennyTxnStore

/// UniversalRecordIngest: bank-agnostic record-block parsing gated on the
/// document proving itself (balance chain or printed totals). All fixtures
/// are synthetic — layout mimics real app exports, data is invented.
final class UniversalRecordIngestTests: XCTestCase {

    private func cats() throws -> Categories {
        try Categories(categoriesJSONPath: TestPaths.categoriesJSON.path)
    }

    // Paytm-app-shaped: multi-line records, signed amounts, no balance column,
    // printed totals + counts in the header. Newest first, two-year period.
    private var recordBlockPages: [String] {
        let p1 = """
        SOME PERSON
        Statement for
        27 AUG'25 - 26 AUG'26
        Total Money Paid
        - Rs.510.00
        3 Payments made
        Total Money Received
        + Rs.200.00
        1 Payments received
        Date & Time Transaction Details Amount
        23 Aug
        9:58 AM
        Metro QR Tickets
        UPI Ref No: 623573163635
        Tag: # Travel
        - Rs.60
        Page of
        1 2
        """
        let p2 = """
        Date & Time Transaction Details Amount
        22 Aug
        4:19 PM
        Received from Some Friend
        UPI Ref No: 623500000001
        + Rs.200
        21 Aug
        1:00 PM
        Paid to Grocer Uncle
        UPI Ref No: 623500000002
        - Rs.250
        20 Aug
        Paid to Tea Stall
        UPI Ref No: 623500000003
        - Rs.200.00
        Page of
        2 2
        """
        return [p1, p2]
    }

    func testRecordBlockWithPrintedTotalsParsesAndVerifies() throws {
        let out = try XCTUnwrap(UniversalRecordIngest.parse(pages: recordBlockPages, categories: cats()))
        XCTAssertEqual(out.verification, "printed-totals")
        XCTAssertEqual(out.rows.count, 4)
        XCTAssertEqual(out.currency, "INR")
        let debits = out.rows.filter { $0.debit > 0 }
        XCTAssertEqual(debits.count, 3)
        XCTAssertEqual(debits.reduce(0) { $0 + $1.debit }, 510, accuracy: 0.001)
        XCTAssertEqual(out.rows.filter { $0.credit > 0 }.reduce(0) { $0 + $1.credit }, 200, accuracy: 0.001)
        // Bare "23 Aug" at the TOP of a newest-first AUG'25–AUG'26 export sits
        // near the period END — 2026. (The old month>=start rule said 2025,
        // which stamped a year's worth of closing rows wrong; 2026-08-31 fix.)
        XCTAssertEqual(out.rows[0].txnDate, "2026-08-23")
        // ID lines dropped from descriptions; Tag became a category hint.
        XCTAssertFalse(out.rows[0].descr.contains("623573163635"))
    }

    func testWrongRowsAreRejectedNotStored() throws {
        // Same statement but the totals disagree with the rows (a misread) —
        // the gate must refuse the whole file.
        let pages = recordBlockPages.map {
            $0.replacingOccurrences(of: "- Rs.510.00", with: "- Rs.9,999.00")
        }
        XCTAssertNil(UniversalRecordIngest.parse(pages: pages, categories: try cats()),
                     "totals mismatch must reject the import")
    }

    func testBalanceChainVerification() throws {
        // Unknown-bank record layout WITH a running balance and no totals:
        // every consecutive balance reconciles → accepted via balance-chain.
        let page = """
        Anybank Passbook
        01/03/2026
        Opening things
        SALARY CREDIT ACME
        + 1,000.00 5,000.00
        05/03/2026
        POS PURCHASE GROCERY MART
        - 250.00 4,750.00
        09/03/2026
        ATM WITHDRAWAL MAIN ST
        - 500.00 4,250.00
        """
        let out = try XCTUnwrap(UniversalRecordIngest.parse(pages: [page], categories: cats()))
        XCTAssertEqual(out.verification, "balance-chain")
        XCTAssertEqual(out.rows.count, 3)
        XCTAssertEqual(out.rows[0].credit, 1000, accuracy: 0.001)
        XCTAssertEqual(out.rows[2].balance ?? 0, 4250, accuracy: 0.001)
    }

    func testBrokenBalanceChainRejects() throws {
        let page = """
        Anybank Passbook
        01/03/2026
        SALARY CREDIT ACME
        + 1,000.00 5,000.00
        05/03/2026
        POS PURCHASE GROCERY MART
        - 250.00 4,000.00
        09/03/2026
        ATM WITHDRAWAL MAIN ST
        - 500.00 3,500.00
        """
        XCTAssertNil(UniversalRecordIngest.parse(pages: [page], categories: try cats()),
                     "a broken chain with no printed totals must reject")
    }

    func testFewRecordsRejects() throws {
        XCTAssertNil(UniversalRecordIngest.parse(pages: ["23 Aug\nPaid to X\n- Rs.10"],
                                                 categories: try cats()))
    }
}
