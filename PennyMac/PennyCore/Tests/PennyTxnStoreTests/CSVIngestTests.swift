// CSVIngestTests — the CSV statement/export ingest path (CSVIngest +
// TxnIngester.ingestCSV): header-row synonyms and discovery below preamble
// lines, quoted-comma fields, BOM + CRLF, latin-1 fallback, dd/mm vs mm/dd
// inference, signed/parenthesised amounts, unquoted lakh-grouped amount
// repair, reverse-order normalization, card semantics, and the real
// test-data/indian_bank.csv (ground truth: 10 data rows, counted with
// python3 csv.reader).
import XCTest
@testable import PennyTxnStore

final class CSVIngestTests: XCTestCase {

    private var ingester: TxnIngester!

    override func setUpWithError() throws {
        ingester = try TestPaths.makeIngester()
    }

    /// Write inline CSV content to a throwaway file, return its path.
    private func tempCSV(_ content: String, _ label: String = "t") throws -> String {
        let path = NSTemporaryDirectory()
            + "penny_csv_\(label)_\(getpid())_\(UUID().uuidString.prefix(8)).csv"
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    private func tempCSV(bytes: [UInt8], _ label: String = "b") throws -> String {
        let path = NSTemporaryDirectory()
            + "penny_csv_\(label)_\(getpid())_\(UUID().uuidString.prefix(8)).csv"
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    // MARK: - UK bank export (Money Out/In, £, quoted commas, footer)

    func testUKBankCSV() throws {
        let csv = """
        Date,Description,Money Out,Money In,Balance
        03/02/2026,TESCO STORES 2314,45.60,,"£2,154.40"
        10/02/2026,SALARY ACME LTD,,"£2,500.00","£4,654.40"
        21/02/2026,"NETFLIX.COM, AMSTERDAM",9.99,,"£4,644.41"
        This file is provided for information purposes only and is not a statement of your account.
        """
        let out = try ingester.ingestCSV(path: try tempCSV(csv, "uk"))
        XCTAssertEqual(out.rows.count, 3, "footer disclaimer must not become a row")
        XCTAssertEqual(out.confidence, "high")
        XCTAssertEqual(out.detectedCurrency, "GBP")
        XCTAssertFalse(out.isCard)

        // dd/mm reading (no second component ever exceeds 12, 21 > 12 in first)
        XCTAssertEqual(out.rows[0].txnDate, "2026-02-03")
        XCTAssertEqual(out.rows[0].debit, 45.60)
        XCTAssertEqual(out.rows[0].credit, 0)
        XCTAssertEqual(out.rows[0].balance, 2154.40)
        XCTAssertEqual(out.rows[0].category, "Groceries")
        XCTAssertEqual(out.rows[0].currency, "GBP")

        XCTAssertEqual(out.rows[1].credit, 2500.00)
        XCTAssertEqual(out.rows[1].category, "Income")
        XCTAssertEqual(out.rows[1].balance, 4654.40)

        XCTAssertEqual(out.rows[2].descr, "NETFLIX.COM, AMSTERDAM",
                       "quoted comma must stay inside the description field")
        XCTAssertEqual(out.rows[2].merchant, "Netflix")
        XCTAssertEqual(out.rows[2].category, "Subscriptions")
        XCTAssertEqual(out.rows.map(\.seq), [1, 2, 3])
    }

    // MARK: - US card export (preamble, mm/dd, owed balance → card semantics)

    func testUSCardCSV() throws {
        let csv = """
        Meridian Card Services,,,
        Credit Card Statement — Card Ending 4523,,,
        "New Balance: $1,204.55",,,
        Transaction Date,Description,Amount,Balance
        06/05/2026,STARBUCKS #221 SEATTLE,6.40,"$1,090.15"
        06/14/2026,AMAZON.COM ORDER,84.99,"$1,175.14"
        06/20/2026,PAYMENT RECEIVED - THANK YOU,-500.00,"$675.14"
        06/30/2026,DELTA AIR LINES,529.41,"$1,204.55"
        """
        let out = try ingester.ingestCSV(path: try tempCSV(csv, "uscard"))
        XCTAssertEqual(out.rows.count, 4, "preamble lines must not become rows")
        XCTAssertTrue(out.isCard)
        XCTAssertEqual(out.detectedCurrency, "USD")
        XCTAssertEqual(out.closingBalance, 1204.55, "stated New Balance wins")

        // mm/dd inferred from 06/14 and 06/30 (second component > 12)
        XCTAssertEqual(out.rows[0].txnDate, "2026-06-05")
        XCTAssertEqual(out.rows[3].txnDate, "2026-06-30")

        // owed balance UP = charge: the positive-amount "credit" reading flips
        XCTAssertEqual(out.rows[1].debit, 84.99)
        XCTAssertEqual(out.rows[1].credit, 0)
        XCTAssertEqual(out.rows[1].category, "Shopping")
        XCTAssertEqual(out.rows[3].debit, 529.41)
        XCTAssertEqual(out.rows[3].credit, 0)

        // repayment: owed DOWN, recategorized out of income
        XCTAssertEqual(out.rows[2].credit, 500.00)
        XCTAssertEqual(out.rows[2].debit, 0)
        XCTAssertEqual(out.rows[2].category, "Payments")
        XCTAssertEqual(out.rows[2].merchant, "Payment Received")
    }

    // MARK: - Indian export: quoted lakh amounts + bracketed Dr/Cr headers

    func testIndianCSVWithLakhAmounts() throws {
        let csv = """
        Txn Date,Narration,Withdrawal (Dr),Deposit (Cr),Balance
        05/04/2025,UPI-DMART-Groceries,"₹3,150.75",,"₹96,849.25"
        12/04/2025,NEFT SALARY CREDIT,,"₹1,25,000.00","₹2,21,849.25"
        18/04/2025,IMPS-RENT-Payment,"₹25,000.00",,"₹1,96,849.25"
        """
        let out = try ingester.ingestCSV(path: try tempCSV(csv, "inr"))
        XCTAssertEqual(out.rows.count, 3)
        XCTAssertEqual(out.detectedCurrency, "INR")
        XCTAssertEqual(out.rows[0].debit, 3150.75)
        XCTAssertEqual(out.rows[0].balance, 96849.25)
        XCTAssertEqual(out.rows[0].category, "Groceries")
        XCTAssertEqual(out.rows[1].credit, 125000.00, "lakh grouping must parse exactly")
        XCTAssertEqual(out.rows[1].balance, 221849.25)
        XCTAssertEqual(out.rows[1].category, "Income")
        XCTAssertEqual(out.rows[2].debit, 25000.00)
        XCTAssertEqual(out.rows[0].txnDate, "2025-04-05", "dd/mm order for Indian dates")
    }

    // MARK: - quoted fields: embedded commas and escaped quotes

    func testQuotedCommaAndEscapedQuoteDescriptions() throws {
        let csv = """
        Date,Description,Amount
        01/03/2026,"SMITH, JONES & CO SOLICITORS",-350.00
        02/03/2026,"HE SAID ""HELLO"" LTD",-10.00
        """
        let out = try ingester.ingestCSV(path: try tempCSV(csv, "quoted"))
        XCTAssertEqual(out.rows.count, 2)
        XCTAssertEqual(out.rows[0].descr, "SMITH, JONES & CO SOLICITORS")
        XCTAssertEqual(out.rows[0].debit, 350.00)
        XCTAssertEqual(out.rows[1].descr, "HE SAID \"HELLO\" LTD")
        XCTAssertEqual(out.rows[1].debit, 10.00)
    }

    // MARK: - BOM + CRLF + trailing blank line

    func testBOMAndCRLF() throws {
        let csv = "\u{FEFF}Date,Description,Amount\r\n"
            + "15/03/2026,COSTA COFFEE,-4.50\r\n"
            + "\r\n"
        let out = try ingester.ingestCSV(path: try tempCSV(csv, "bom"))
        XCTAssertEqual(out.rows.count, 1)
        XCTAssertEqual(out.rows[0].txnDate, "2026-03-15",
                       "a BOM on the header must not break the Date column mapping")
        XCTAssertEqual(out.rows[0].descr, "COSTA COFFEE")
        XCTAssertEqual(out.rows[0].debit, 4.50)
        XCTAssertEqual(out.rows[0].category, "Food & Dining")
    }

    // MARK: - latin-1 fallback (Python's utf-8-sig → latin-1 retry)

    func testLatin1FallbackDecoding() throws {
        var bytes = Array("Date,Description,Amount\n01/02/2025,CAF".utf8)
        bytes.append(0xE9)   // é in latin-1; invalid as UTF-8 here
        bytes.append(contentsOf: Array(" PARIS,-12.50\n".utf8))
        let out = try ingester.ingestCSV(path: try tempCSV(bytes: bytes, "latin1"))
        XCTAssertEqual(out.rows.count, 1)
        XCTAssertEqual(out.rows[0].descr, "CAFé PARIS")
        XCTAssertEqual(out.rows[0].debit, 12.50)
        XCTAssertEqual(out.rows[0].txnDate, "2025-02-01")
    }

    // MARK: - reverse-chronological files are normalized like the PDF path

    func testReversedOrderNormalizedChronologically() throws {
        let csv = """
        Date,Description,Money Out,Money In,Balance
        20/05/2026,COFFEE,3.00,,97.00
        10/05/2026,BOOKSHOP,25.00,,100.00
        01/05/2026,OPENING SALARY,,125.00,125.00
        """
        let out = try ingester.ingestCSV(path: try tempCSV(csv, "rev"))
        XCTAssertEqual(out.rows.map(\.txnDate),
                       ["2026-05-01", "2026-05-10", "2026-05-20"])
        XCTAssertEqual(out.rows[0].credit, 125.00)
        XCTAssertEqual(out.rows[2].descr, "COFFEE")
        XCTAssertEqual(out.rows.map(\.seq), [1, 2, 3], "seq reassigned after reversal")
    }

    // MARK: - single signed amount column (minus and parenthesised negatives)

    func testSignedSingleAmountColumn() throws {
        let csv = """
        Date,Description,Amount
        1/6/2026,GADGET SHOP,-199.99
        5/6/2026,REFUND GADGET SHOP,199.99
        9/6/2026,OFFICE SUPPLIES,(45.00)
        """
        let out = try ingester.ingestCSV(path: try tempCSV(csv, "signed"))
        XCTAssertEqual(out.rows.count, 3)
        XCTAssertEqual(out.rows[0].txnDate, "2026-06-01",
                       "single-digit d/m dates fall back to the numeric pattern")
        XCTAssertEqual(out.rows[0].debit, 199.99)
        XCTAssertEqual(out.rows[0].credit, 0)
        XCTAssertEqual(out.rows[1].credit, 199.99)
        XCTAssertEqual(out.rows[1].debit, 0)
        XCTAssertEqual(out.rows[2].debit, 45.00, "(45.00) is an accountant negative")
        XCTAssertEqual(out.rows[2].credit, 0)
    }

    // MARK: - currency detection

    func testCurrencyColumnWinsOverSniffing() throws {
        let csv = """
        Date,Description,Amount,Currency
        02/01/2026,CONSULTING INVOICE,1500.00,EUR
        """
        let out = try ingester.ingestCSV(path: try tempCSV(csv, "curcol"))
        XCTAssertEqual(out.detectedCurrency, "EUR")
        XCTAssertEqual(out.rows[0].currency, "EUR")
        XCTAssertEqual(out.rows[0].credit, 1500.00)
    }

    func testEuroSymbolSniffing() throws {
        let csv = """
        Date,Description,Amount
        02/01/2026,SUPERMARKT BERLIN,-€12.00
        """
        let out = try ingester.ingestCSV(path: try tempCSV(csv, "eur"))
        XCTAssertEqual(out.detectedCurrency, "EUR")
        XCTAssertEqual(out.rows[0].currency, "EUR")
        XCTAssertEqual(out.rows[0].debit, 12.00)
    }

    // MARK: - Type-column direction (DEBIT/CREDIT in a separate column)

    /// The common Indian export layout: ONE positive amount column plus a
    /// "type" column carrying DEBIT/CREDIT. Every row used to parse as a
    /// credit (direction only came from a Cr/Dr suffix or the sign), and the
    /// "type" header also hijacked the category role from the REAL category
    /// column further right.
    func testTypeColumnDrivesDirection() throws {
        let csv = """
        date,narration,type,amount,category,merchant,mode,balance
        2025-07-01,SALARY CREDIT ACME,CREDIT,120000.0,Salary,Acme,NEFT,200000.0
        2025-07-03,UPI SWIGGY,DEBIT,412.50,Food Delivery,Swiggy,UPI,199587.50
        2025-07-05,ATM WDL,DEBIT,5000.0,Cash Withdrawal,ATM,ATM,194587.50
        """
        let out = try ingester.ingestCSV(path: try tempCSV(csv, "typecol"))
        XCTAssertEqual(out.rows.count, 3)
        XCTAssertEqual(out.rows[0].credit, 120000.0)
        XCTAssertEqual(out.rows[0].debit, 0)
        XCTAssertEqual(out.rows[1].debit, 412.50, "positive amount + Type DEBIT must be a debit")
        XCTAssertEqual(out.rows[1].credit, 0)
        XCTAssertEqual(out.rows[2].debit, 5000.0)
        // The REAL category column must survive the "type" header.
        XCTAssertEqual(out.rows[1].rawCategory, "Food Delivery")
    }

    /// A "Type" column whose values are NOT direction markers is a category
    /// column (some exports use "Type" that way) — the sign fallback still
    /// decides direction.
    func testTypeColumnDemotedToCategoryWhenNotDirectional() throws {
        let csv = """
        Date,Description,Type,Amount
        2025-07-01,STARBUCKS,Dining,-450.0
        2025-07-02,SALARY,Income,90000.0
        """
        let out = try ingester.ingestCSV(path: try tempCSV(csv, "typecat"))
        XCTAssertEqual(out.rows[0].debit, 450.0)
        XCTAssertEqual(out.rows[1].credit, 90000.0)
        XCTAssertEqual(out.rows[0].rawCategory, "Dining")
    }

    // MARK: - unmappable headers

    func testUnmappableHeadersYieldNoRows() throws {
        let out = try ingester.ingestCSV(path: try tempCSV("Foo,Bar\n1,2\n", "bad"))
        XCTAssertTrue(out.rows.isEmpty)
        XCTAssertEqual(out.confidence, "low")
    }

    // MARK: - real file: test-data/indian_bank.csv

    /// Ground truth (python3 csv.reader): 10 data rows below the header; the
    /// lakh amounts are UNQUOTED, so raw records carry split cells that the
    /// grouped-amount repair must reassemble ("₹1","34","550.00" → ₹1,34,550.00).
    func testRealIndianBankCSV() throws {
        let path = TestPaths.testDataDir.appendingPathComponent("indian_bank.csv").path
        let out = try ingester.ingestCSV(path: path)
        XCTAssertEqual(out.rows.count, 10)
        XCTAssertEqual(out.detectedCurrency, "INR")
        XCTAssertFalse(out.isCard)
        XCTAssertEqual(out.rows.map(\.seq), Array(1...10))

        // 15/01: UPI-ZOMATO-Swiggy-Food ₹450.00 Dr → ₹49,550.00
        XCTAssertEqual(out.rows[0].txnDate, "2025-01-15")
        XCTAssertEqual(out.rows[0].descr, "UPI-ZOMATO-Swiggy-Food")
        XCTAssertEqual(out.rows[0].debit, 450.00)
        XCTAssertEqual(out.rows[0].credit, 0)
        XCTAssertEqual(out.rows[0].balance, 49550.00)
        XCTAssertEqual(out.rows[0].category, "Food & Dining")

        // 16/01: NEFT-SALARY-Credit ₹85,000.00 Cr → ₹1,34,550.00 (split cells)
        XCTAssertEqual(out.rows[1].credit, 85000.00)
        XCTAssertEqual(out.rows[1].debit, 0)
        XCTAssertEqual(out.rows[1].balance, 134550.00)
        XCTAssertEqual(out.rows[1].category, "Income")

        // 23/01: UPI-NETFLIX-Subscription ₹649.00 Dr → ₹1,18,611.75
        XCTAssertEqual(out.rows[8].txnDate, "2025-01-23")
        XCTAssertEqual(out.rows[8].debit, 649.00)
        XCTAssertEqual(out.rows[8].merchant, "Netflix")
        XCTAssertEqual(out.rows[8].balance, 118611.75)

        // 24/01: UPI-INSURANCE-Premium ₹4,200.00 Dr → ₹1,14,411.75
        XCTAssertEqual(out.rows[9].txnDate, "2025-01-24")
        XCTAssertEqual(out.rows[9].debit, 4200.00)
        XCTAssertEqual(out.rows[9].balance, 114411.75)
        XCTAssertEqual(out.rows[9].category, "Investment & Insurance")
    }
}
