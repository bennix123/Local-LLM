// StatementSweepTests — full-corpus regression sweep of the deterministic ingest
// pipeline (PDFTextExtractor → parser routing → TxnIngester) over every statement
// PDF in test-data/ plus the two repo-root PDFs (TEST-1000.pdf and
// indian_bank_statement.pdf). Every expectation below was ground-truthed against
// the current pipeline via `penny-conformance dump-rows` / `rows-json`, so this
// suite pins exact per-file row counts, bank/currency detection, first/last row
// contents and debit/credit totals, and enforces cross-file row invariants
// (well-formed dates, non-empty description/category, non-negative finite
// amounts, seq numbering, chronological order and running-balance arithmetic
// where the ground truth shows they hold). It also guards the SQLite round-trip
// (TxnDB.insert → conformanceRows) and fails when a new PDF lands in test-data/
// without a matching pin, so parser drift on any layout is caught immediately.
import XCTest
@testable import PennyTxnStore

/// The subset of a TxnRow we pin exactly for the first/last row of each file.
private struct RowPin {
    let date: String
    let descr: String
    let debit: Double
    let credit: Double
    let balance: Double?
}

/// Ground-truthed expectation for one statement PDF.
private struct SweepPin {
    let file: String            // file name (test-data/ or repo root)
    let inTestData: Bool        // false → resolves against the repo root
    let rows: Int               // exact parsed row count
    let currency: String        // IngestOutput.detectedCurrency
    let bank: String?           // IngestOutput.bankName
    let fullBalanceChain: Bool  // bal[i] == bal[i-1] + credit - debit holds throughout
    let datesMonotonic: Bool    // txnDate is non-decreasing across rows
    let totalDebit: Double
    let totalCredit: Double
    let first: RowPin?
    let last: RowPin?

    var path: String {
        (inTestData ? TestPaths.testDataDir : TestPaths.repoRoot)
            .appendingPathComponent(file).path
    }
}

// Ground truth captured from `penny-conformance rows-json` / `dump-rows` on the
// current pipeline. If a parser change legitimately improves a file, re-derive
// its pin the same way rather than loosening the asserts.
private let sweepPins: [SweepPin] = [
    // Bank-agnostic Date | Narration | Debit | Credit | Balance column layout. The
    // amounts carry a mis-decoded ₹ glyph ("n85,000.00"); direction is positional
    // (Credit column = income), so the salary + refund are the only two credits.
    // One parser serves every issuer in this family — Kotak and Axis share a body.
    SweepPin(file: "Kotak_Dummy_Statement.pdf", inTestData: true, rows: 12,
             currency: "INR", bank: "Kotak Mahindra Bank",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 40855.0, totalCredit: 86250.0,
             first: RowPin(date: "2026-10-01", descr: "Salary Credit - TechNova Pvt Ltd", debit: 0, credit: 85000, balance: 290327.5),
             last: RowPin(date: "2026-10-29", descr: "Mutual Fund SIP", debit: 10000, credit: 0, balance: 250722.5)),
    SweepPin(file: "Axis_Dummy_Statement.pdf", inTestData: true, rows: 12,
             currency: "INR", bank: "Axis Bank",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 40855.0, totalCredit: 86250.0,
             first: RowPin(date: "2026-10-01", descr: "Salary Credit - TechNova Pvt Ltd", debit: 0, credit: 85000, balance: 290327.5),
             last: RowPin(date: "2026-10-29", descr: "Mutual Fund SIP", debit: 10000, credit: 0, balance: 250722.5)),
    // The hard case: FIVE monthly sections in one document, year-less "DD-MMM"
    // date cells (the year lives only in each section header), no-decimal amounts
    // ("85,000"), and continuation pages that don't repeat the column header. 62
    // rows, and the balance chain reconciles across every one of them.
    SweepPin(file: "Dummy_Bank_Statements.pdf", inTestData: true, rows: 62,
             currency: "INR", bank: "Dummy Bank",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 222451.0, totalCredit: 427353.0,
             first: RowPin(date: "2026-06-01", descr: "Salary - TechNova Pvt Ltd", debit: 0, credit: 85000, balance: 130820.5),
             last: RowPin(date: "2026-10-29", descr: "SIP", debit: 10000, credit: 0, balance: 250722.5)),
    SweepPin(file: "Coop_Demo_Statement.pdf", inTestData: true, rows: 37,
             currency: "GBP", bank: "Coop Demo",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 1948.55, totalCredit: 3498.74,
             first: RowPin(date: "2026-06-01", descr: "TESCO STORES 2431 PATNA", debit: 42.15, credit: 0, balance: 2407.85),
             last: RowPin(date: "2026-06-30", descr: "STANDING ORDER - CAR INSURANCE", debit: 55, credit: 0, balance: 4000.19)),
    // Re-grounded after the currency-declaration fix: the statement's explicit
    // "Currency: EUR" header is now honored (rows used to ship with "").
    SweepPin(file: "DeutscheBank_Demo_Statement.pdf", inTestData: true, rows: 37,
             currency: "EUR", bank: "Deutschebank Demo",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 1948.55, totalCredit: 3498.74,
             first: RowPin(date: "2026-06-01", descr: "TESCO STORES 2431 PATNA", debit: 42.15, credit: 0, balance: 2407.85),
             last: RowPin(date: "2026-06-30", descr: "STANDING ORDER - CAR INSURANCE", debit: 55, credit: 0, balance: 4000.19)),
    SweepPin(file: "GoldmanSachs_Demo_Statement.pdf", inTestData: true, rows: 37,
             currency: "GBP", bank: "Goldmansachs Demo",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 1948.55, totalCredit: 3498.74,
             first: RowPin(date: "2026-06-01", descr: "TESCO STORES 2431 PATNA", debit: 42.15, credit: 0, balance: 2407.85),
             last: RowPin(date: "2026-06-30", descr: "STANDING ORDER - CAR INSURANCE", debit: 55, credit: 0, balance: 4000.19)),
    SweepPin(file: "Handelsbanken_Demo_Statement.pdf", inTestData: true, rows: 37,
             currency: "GBP", bank: "Handelsbanken Demo",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 1948.55, totalCredit: 3498.74,
             first: RowPin(date: "2026-06-01", descr: "TESCO STORES 2431 PATNA", debit: 42.15, credit: 0, balance: 2407.85),
             last: RowPin(date: "2026-06-30", descr: "STANDING ORDER - CAR INSURANCE", debit: 55, credit: 0, balance: 4000.19)),
    SweepPin(file: "NatWest_Demo_Statement.pdf", inTestData: true, rows: 37,
             currency: "GBP", bank: "Natwest Demo",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 1948.55, totalCredit: 3498.74,
             first: RowPin(date: "2026-06-01", descr: "TESCO STORES 2431 PATNA", debit: 42.15, credit: 0, balance: 2407.85),
             last: RowPin(date: "2026-06-30", descr: "STANDING ORDER - CAR INSURANCE", debit: 55, credit: 0, balance: 4000.19)),
    SweepPin(file: "Nationwide_Demo_Statement.pdf", inTestData: true, rows: 37,
             currency: "GBP", bank: "Nationwide Demo",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 1948.55, totalCredit: 3498.74,
             first: RowPin(date: "2026-06-01", descr: "TESCO STORES 2431 PATNA", debit: 42.15, credit: 0, balance: 2407.85),
             last: RowPin(date: "2026-06-30", descr: "STANDING ORDER - CAR INSURANCE", debit: 55, credit: 0, balance: 4000.19)),
    SweepPin(file: "Starling_Demo_Statement.pdf", inTestData: true, rows: 37,
             currency: "GBP", bank: "Starling Demo",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 1948.55, totalCredit: 3498.74,
             first: RowPin(date: "2026-06-01", descr: "TESCO STORES 2431 PATNA", debit: 42.15, credit: 0, balance: 2407.85),
             last: RowPin(date: "2026-06-30", descr: "STANDING ORDER - CAR INSURANCE", debit: 55, credit: 0, balance: 4000.19)),
    SweepPin(file: "Wrenfield_Bank_Statement_Tinku_Kesariya-1.pdf", inTestData: true, rows: 1000,
             currency: "GBP", bank: "Wrenfield Bank",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 25863.36000000002, totalCredit: 25634.510000000006,
             first: RowPin(date: "2025-07-01", descr: "Landlord Properties Ltd (", debit: 750, credit: 0, balance: 1650),
             last: RowPin(date: "2026-06-30", descr: "COSTA COFFEE LUTON GBR (pending)", debit: 13.06, credit: 0, balance: 2171.15)),
    SweepPin(file: "boi_dummy_statement.pdf", inTestData: true, rows: 31,
             currency: "GBP", bank: "NOT A REAL BANK DOCUMENT",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 3119.63, totalCredit: 7674.55,
             first: RowPin(date: "2026-06-07", descr: "26 TRANSFER FROM SAVINGS", debit: 0, credit: 649.99, balance: 1899.99),
             last: RowPin(date: "2026-07-06", descr: "26 IKEA", debit: 176.21, credit: 0, balance: 5804.92)),
    // Re-grounded after the US MM/DD date-order fix: dates are chronological,
    // debits/credits follow the (now correctly ordered) balance walk, and the
    // trailing ENDING BALANCE display line is skipped (33 → 32 rows).
    SweepPin(file: "chase_dummy_statement.pdf", inTestData: true, rows: 31,
             currency: "USD", bank: "NOT A REAL BANK DOCUMENT",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 3073.09, totalCredit: 7674.55,
             first: RowPin(date: "2026-06-07", descr: "ZELLE TRANSFER RECEIVED", debit: 0, credit: 649.99, balance: 1899.99),
             last: RowPin(date: "2026-07-06", descr: "AT&T WIRELESS", debit: 129.67, credit: 0, balance: 5851.46)),
    SweepPin(file: "lloyds_dummy_statement.pdf", inTestData: true, rows: 31,
             currency: "GBP", bank: "NOT A REAL BANK DOCUMENT",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 3743.35, totalCredit: 5114.54,
             first: RowPin(date: "2026-06-07", descr: "26 REFUND - JOHN LEWIS", debit: 0, credit: 723.82, balance: 1973.82),
             last: RowPin(date: "2026-07-06", descr: "26 UBER TRIP", debit: 35.24, credit: 0, balance: 2621.19)),
    SweepPin(file: "metrobank_dummy_statement.pdf", inTestData: true, rows: 31,
             currency: "GBP", bank: "NOT A REAL BANK DOCUMENT",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 3119.63, totalCredit: 7674.55,
             first: RowPin(date: "2026-06-07", descr: "26 TRANSFER FROM SAVINGS", debit: 0, credit: 649.99, balance: 1899.99),
             last: RowPin(date: "2026-07-06", descr: "26 IKEA", debit: 176.21, credit: 0, balance: 5804.92)),
    SweepPin(file: "revolut_dummy_statement.pdf", inTestData: true, rows: 31,
             currency: "GBP", bank: "Revolut Dummy",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 4599.96, totalCredit: 5817.08,
             first: RowPin(date: "2026-06-07", descr: "26 TOP-UP FROM BANK ACCOUNT", debit: 0, credit: 649.99, balance: 1899.99),
             last: RowPin(date: "2026-07-06", descr: "26 SHELL GARAGE", debit: 224.01, credit: 0, balance: 2467.12)),
    SweepPin(file: "santander_dummy_statement.pdf", inTestData: true, rows: 31,
             currency: "GBP", bank: "NOT A REAL BANK DOCUMENT",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 3119.63, totalCredit: 7674.55,
             first: RowPin(date: "2026-06-07", descr: "26 TRANSFER FROM SAVINGS", debit: 0, credit: 649.99, balance: 1899.99),
             last: RowPin(date: "2026-07-06", descr: "26 IKEA", debit: 176.21, credit: 0, balance: 5804.92)),
    SweepPin(file: "specimen_bnp_paribas_statement.pdf", inTestData: true, rows: 40,
             currency: "GBP", bank: "Specimen Bnp Paribas",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 4075.1699999999987, totalCredit: 5705.179999999999,
             first: RowPin(date: "2026-04-01", descr: "SAMPLE LOYER SARL", debit: 84.38, credit: 0, balance: 2656.47),
             last: RowPin(date: "2026-04-18", descr: "FAKE CINEMA SARL REAL A NOT Fictional SPECIMEN data - not a real person, account", debit: 121.75, credit: 0, balance: 4370.86)),
    SweepPin(file: "specimen_coutts_statement.pdf", inTestData: true, rows: 32,
             currency: "GBP", bank: "Specimen Coutts",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 17805.51, totalCredit: 36857.2,
             first: RowPin(date: "2026-04-01", descr: "SAMPLE EMPLOYER LTD -", debit: 0, credit: 6663.82, balance: 24914.22),
             last: RowPin(date: "2026-04-18", descr: "FAKE PETROL STATION SPECIMEN REAL A NOT Fictional SPECIMEN data - not a real per", debit: 32.98, credit: 0, balance: 37302.09)),
    SweepPin(file: "specimen_credit_suisse_statement.pdf", inTestData: true, rows: 34,
             currency: "GBP", bank: "Specimen Credit Suisse",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 29175.46, totalCredit: 24289.57,
             first: RowPin(date: "2026-01-01", descr: "TEST STREAMING SERVICE", debit: 624.82, credit: 0, balance: 53575.28),
             last: RowPin(date: "2026-01-17", descr: "TEST HAUSRATVERSICHERUNG SPECIMEN REAL A NOT Fictional SPECIMEN data - not a rea", debit: 905.58, credit: 0, balance: 49314.21)),
    SweepPin(file: "specimen_hsbc_uk_statement.pdf", inTestData: true, rows: 120,
             currency: "GBP", bank: "Specimen Hsbc Uk",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 19770.65999999999, totalCredit: 26368.550000000003,
             first: RowPin(date: "2026-01-02", descr: "EXAMPLE RESTAURANT", debit: 168.74, credit: 0, balance: 1082.01),
             last: RowPin(date: "2026-03-09", descr: "INTEREST PAID (SPECIMEN) A NOT Fictional SPECIMEN data - not a real person, acco", debit: 0, credit: 1299.23, balance: 7848.64)),
    SweepPin(file: "specimen_monzo_statement.pdf", inTestData: true, rows: 36,
             currency: "GBP", bank: "Monzo Bank  (SPECIMEN / FICTIONAL SAMPLE)",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 2998.07, totalCredit: 9998.34,
             first: RowPin(date: "2026-05-01", descr: "DEMO ELECTRONICS STORE", debit: 50.15, credit: 0, balance: 565.15),
             last: RowPin(date: "2026-05-12", descr: "SAMPLE SPECIMEN WATER COMPANY REAL A NOT Fictional SPECIMEN data - not a real pe", debit: 227.04, credit: 0, balance: 7615.57)),
    SweepPin(file: "specimen_standard_chartered_statement.pdf", inTestData: true, rows: 38,
             currency: "GBP", bank: "Specimen Standard Chartered",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 6574.21, totalCredit: 9010.08,
             first: RowPin(date: "2026-02-01", descr: "EXAMPLE RESTAURANT", debit: 34.21, credit: 0, balance: 3365.99),
             last: RowPin(date: "2026-02-18", descr: "SPECIMEN BRANCH ATM REAL A NOT Fictional SPECIMEN data - not a real person, acco", debit: 322.95, credit: 0, balance: 5836.07)),
    SweepPin(file: "specimen_virgin_money_statement.pdf", inTestData: true, rows: 34,
             currency: "GBP", bank: "Specimen Virgin Money",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 6191.700000000001, totalCredit: 10064.37,
             first: RowPin(date: "2026-03-01", descr: "SAMPLE AIRLINE BOOKING", debit: 449.36, credit: 0, balance: 441.19),
             last: RowPin(date: "2026-03-18", descr: "SPECIMEN COUNCIL TAX SPECIMEN REAL A NOT Fictional SPECIMEN data - not a real pe", debit: 250.84, credit: 0, balance: 4763.22)),
    SweepPin(file: "tsb_dummy_statement.pdf", inTestData: true, rows: 31,
             currency: "GBP", bank: "NOT A REAL BANK DOCUMENT",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 3119.63, totalCredit: 7674.55,
             first: RowPin(date: "2026-06-07", descr: "26 TRANSFER FROM SAVINGS", debit: 0, credit: 649.99, balance: 1899.99),
             last: RowPin(date: "2026-07-06", descr: "26 IKEA", debit: 176.21, credit: 0, balance: 5804.92)),
    // TEST-1000.pdf is a Q&A benchmark document, not a bank statement: the
    // pipeline correctly refuses to hallucinate transactions out of it.
    SweepPin(file: "TEST-1000.pdf", inTestData: false, rows: 0,
             currency: "INR", bank: "Local LLM Bank Assistant — 1000-Question Test",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 0, totalCredit: 0,
             first: nil,
             last: nil),
    SweepPin(file: "indian_bank_statement.pdf", inTestData: false, rows: 1000,
             currency: "INR", bank: "HDFC Bank",
             fullBalanceChain: true, datesMonotonic: true,
             totalDebit: 22713091.839999966, totalCredit: 35097262.40000001,
             first: RowPin(date: "2024-04-01", descr: "UPI/242102499471/AMAZON PRIME 242102499471 01/04/2024", debit: 23549.76, credit: 0, balance: 61882.74),
             last: RowPin(date: "2025-03-31", descr: "UPI CR/033970519582/RENT RECEIVED 033970519582 31/03/2025", debit: 0, credit: 32310.36, balance: 12469603.06)),
]

final class StatementSweepTests: XCTestCase {

    // MARK: shared ingest cache (each PDF parses once for the whole class)

    private static var ingester: TxnIngester?
    private static var cache: [String: Result<IngestOutput, Error>] = [:]

    private static func ingest(_ path: String) throws -> IngestOutput {
        if let cached = cache[path] { return try cached.get() }
        if ingester == nil { ingester = try TestPaths.makeIngester() }
        let result = Result { try ingester!.ingestPDF(path: path) }
        cache[path] = result
        return try result.get()
    }

    // MARK: assertion helpers

    private func assertRow(_ row: TxnRow?, matches pin: RowPin, label: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        guard let row else {
            XCTFail("\(label): row missing", file: file, line: line)
            return
        }
        XCTAssertEqual(row.txnDate, pin.date, "\(label): date drifted", file: file, line: line)
        XCTAssertEqual(row.descr, pin.descr, "\(label): description drifted", file: file, line: line)
        XCTAssertEqual(row.debit, pin.debit, accuracy: 0.001,
                       "\(label): debit drifted", file: file, line: line)
        XCTAssertEqual(row.credit, pin.credit, accuracy: 0.001,
                       "\(label): credit drifted", file: file, line: line)
        if let expBal = pin.balance {
            guard let gotBal = row.balance else {
                XCTFail("\(label): balance nil, expected \(expBal)", file: file, line: line)
                return
            }
            XCTAssertEqual(gotBal, expBal, accuracy: 0.001,
                           "\(label): balance drifted", file: file, line: line)
        } else {
            XCTAssertNil(row.balance, "\(label): balance should be nil", file: file, line: line)
        }
    }

    /// Cross-row invariants every parsed statement must satisfy, plus the
    /// per-file properties (monotonic dates, running-balance arithmetic) that
    /// ground truth showed hold for this document.
    private func assertRowInvariants(_ out: IngestOutput, pin: SweepPin,
                                     file: StaticString = #filePath, line: UInt = #line) {
        var violations: [String] = []
        func flag(_ i: Int, _ msg: String) {
            if violations.count < 8 { violations.append("row \(i): \(msg)") }
        }
        var prevDate = ""
        var prevBalance: Double? = nil
        var chainBreaks: [String] = []
        for (i, r) in out.rows.enumerated() {
            let parts = r.txnDate.split(separator: "-", omittingEmptySubsequences: false)
            if r.txnDate.count != 10 || parts.count != 3
                || Int(parts[0]) != r.year || Int(parts[1]) != r.monthNo || Int(parts[2]) != r.day {
                flag(i, "date '\(r.txnDate)' inconsistent with y/m/d fields \(r.year)/\(r.monthNo)/\(r.day)")
            }
            if !(1...12).contains(r.monthNo) || !(1...31).contains(r.day) {
                flag(i, "monthNo/day out of range: \(r.monthNo)/\(r.day)")
            }
            if r.month != String(r.txnDate.prefix(7)) {
                flag(i, "month '\(r.month)' != txnDate prefix '\(r.txnDate.prefix(7))'")
            }
            if r.descr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flag(i, "empty description")
            }
            if r.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flag(i, "empty category")
            }
            if !r.debit.isFinite || r.debit < 0 { flag(i, "bad debit \(r.debit)") }
            if !r.credit.isFinite || r.credit < 0 { flag(i, "bad credit \(r.credit)") }
            if r.debit == 0, r.credit == 0 { flag(i, "debit and credit both zero ('\(r.descr)')") }
            if r.debit > 0, r.credit > 0 {
                flag(i, "debit \(r.debit) and credit \(r.credit) both set ('\(r.descr)')")
            }
            if let b = r.balance, !b.isFinite { flag(i, "non-finite balance") }
            if r.seq != i + 1 { flag(i, "seq \(r.seq) != \(i + 1)") }
            if r.currency != out.detectedCurrency {
                flag(i, "currency '\(r.currency)' != detected '\(out.detectedCurrency)'")
            }
            if pin.datesMonotonic, i > 0, r.txnDate < prevDate {
                flag(i, "date \(r.txnDate) went backwards from \(prevDate)")
            }
            prevDate = r.txnDate
            if let pb = prevBalance, let b = r.balance,
               abs((pb + r.credit - r.debit) - b) > 0.01, chainBreaks.count < 4 {
                chainBreaks.append("row \(i): \(pb) + \(r.credit) - \(r.debit) != \(b) ('\(r.descr)')")
            }
            prevBalance = r.balance
        }
        XCTAssertTrue(violations.isEmpty,
                      "\(pin.file): row invariants violated — " + violations.joined(separator: " | "),
                      file: file, line: line)
        if pin.fullBalanceChain {
            XCTAssertTrue(chainBreaks.isEmpty,
                          "\(pin.file): running-balance arithmetic broke — " + chainBreaks.joined(separator: " | "),
                          file: file, line: line)
        }
    }

    private func check(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard let pin = sweepPins.first(where: { $0.file == name }) else {
            XCTFail("no sweep pin registered for \(name)", file: file, line: line)
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pin.path),
                      "\(name): PDF missing at \(pin.path)", file: file, line: line)
        let out = try Self.ingest(pin.path)
        XCTAssertEqual(out.rows.count, pin.rows,
                       "\(name): row count drifted from ground truth", file: file, line: line)
        XCTAssertEqual(out.detectedCurrency, pin.currency,
                       "\(name): detected currency drifted", file: file, line: line)
        XCTAssertEqual(out.bankName, pin.bank,
                       "\(name): detected bank name drifted", file: file, line: line)
        let totalDebit = out.rows.reduce(0.0) { $0 + $1.debit }
        let totalCredit = out.rows.reduce(0.0) { $0 + $1.credit }
        XCTAssertEqual(totalDebit, pin.totalDebit, accuracy: 0.01,
                       "\(name): total debit drifted", file: file, line: line)
        XCTAssertEqual(totalCredit, pin.totalCredit, accuracy: 0.01,
                       "\(name): total credit drifted", file: file, line: line)
        if let firstPin = pin.first {
            assertRow(out.rows.first, matches: firstPin, label: "\(name) first row",
                      file: file, line: line)
        }
        if let lastPin = pin.last {
            assertRow(out.rows.last, matches: lastPin, label: "\(name) last row",
                      file: file, line: line)
        }
        assertRowInvariants(out, pin: pin, file: file, line: line)
    }

    // MARK: manifest completeness

    /// Every *.pdf that lands in test-data/ must be pinned here (non-PDF files
    /// like the .xlsx/.csv companions are intentionally skipped).
    func testManifestCoversEveryPDFInTestData() throws {
        let found = try FileManager.default.contentsOfDirectory(atPath: TestPaths.testDataDir.path)
            .filter { $0.lowercased().hasSuffix(".pdf") }
        let pinned = sweepPins.filter { $0.inTestData }.map(\.file)
        XCTAssertEqual(Set(found), Set(pinned),
                       "test-data/*.pdf and the sweep manifest diverged — "
                       + "unpinned: \(Set(found).subtracting(pinned).sorted()), "
                       + "stale pins: \(Set(pinned).subtracting(found).sorted())")
    }

    // MARK: per-file sweeps

    func testCoopDemoStatement() throws { try check("Coop_Demo_Statement.pdf") }
    func testDeutscheBankDemoStatement() throws { try check("DeutscheBank_Demo_Statement.pdf") }
    func testGoldmanSachsDemoStatement() throws { try check("GoldmanSachs_Demo_Statement.pdf") }
    func testHandelsbankenDemoStatement() throws { try check("Handelsbanken_Demo_Statement.pdf") }
    func testNatWestDemoStatement() throws { try check("NatWest_Demo_Statement.pdf") }
    func testNationwideDemoStatement() throws { try check("Nationwide_Demo_Statement.pdf") }
    func testStarlingDemoStatement() throws { try check("Starling_Demo_Statement.pdf") }
    func testBoiDummyStatement() throws { try check("boi_dummy_statement.pdf") }
    func testChaseDummyStatement() throws { try check("chase_dummy_statement.pdf") }
    func testLloydsDummyStatement() throws { try check("lloyds_dummy_statement.pdf") }
    func testMetrobankDummyStatement() throws { try check("metrobank_dummy_statement.pdf") }
    func testRevolutDummyStatement() throws { try check("revolut_dummy_statement.pdf") }
    func testSantanderDummyStatement() throws { try check("santander_dummy_statement.pdf") }
    func testSpecimenBNPParibasStatement() throws { try check("specimen_bnp_paribas_statement.pdf") }
    func testSpecimenCouttsStatement() throws { try check("specimen_coutts_statement.pdf") }
    func testSpecimenCreditSuisseStatement() throws { try check("specimen_credit_suisse_statement.pdf") }
    func testSpecimenHSBCUKStatement() throws { try check("specimen_hsbc_uk_statement.pdf") }
    func testSpecimenMonzoStatement() throws { try check("specimen_monzo_statement.pdf") }
    func testSpecimenStandardCharteredStatement() throws { try check("specimen_standard_chartered_statement.pdf") }
    func testSpecimenVirginMoneyStatement() throws { try check("specimen_virgin_money_statement.pdf") }
    func testTsbDummyStatement() throws { try check("tsb_dummy_statement.pdf") }
    func testIndianBankStatement() throws { try check("indian_bank_statement.pdf") }

    /// The Type0/CID-font Wrenfield statement (WeasyPrint, Identity-H encoded).
    /// Per the dev log this must decode to exactly 1000 rows — a regression in
    /// CID glyph decoding shows up here first as a row-count collapse.
    func testWrenfieldType0CIDFontYields1000Rows() throws {
        try check("Wrenfield_Bank_Statement_Tinku_Kesariya-1.pdf")
        let out = try Self.ingest(
            sweepPins.first { $0.file == "Wrenfield_Bank_Statement_Tinku_Kesariya-1.pdf" }!.path)
        XCTAssertEqual(out.rows.count, 1000,
                       "Wrenfield Type0/CID statement must decode to exactly 1000 rows")
    }

    /// TEST-1000.pdf is a 37-page LLM Q&A benchmark, not a statement. Current
    /// (and correct) behaviour: zero transactions, no invented rows.
    func testTest1000QuestionDocParsesToZeroRows() throws {
        try check("TEST-1000.pdf")
    }

    // MARK: SQLite round-trip

    /// The full pipeline the app uses: ingest → TxnDB.insert → conformanceRows.
    /// Every field must survive the SQLite round-trip bit-for-bit, in seq order.
    func testDBRoundTripPreservesParsedRows() throws {
        let dbPath = TestPaths.tempDBPath("sweep_roundtrip")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: dbPath + suffix)
            }
        }
        let db = try TxnDB(path: dbPath)
        for name in ["Coop_Demo_Statement.pdf", "Wrenfield_Bank_Statement_Tinku_Kesariya-1.pdf"] {
            let pin = sweepPins.first { $0.file == name }!
            let out = try Self.ingest(pin.path)
            let userID = "sweep_roundtrip_\(name)"
            db.insert(rows: out.rows, userID: userID, docName: name, bankName: out.bankName)
            let stored = db.conformanceRows(userID: userID)
            XCTAssertEqual(stored.count, out.rows.count,
                           "\(name): DB round-trip changed the row count")
            var mismatches: [String] = []
            for (i, (r, s)) in zip(out.rows, stored).enumerated() where mismatches.count < 5 {
                if r.txnDate != s.date { mismatches.append("row \(i) date \(s.date) != \(r.txnDate)") }
                if r.descr != s.description { mismatches.append("row \(i) descr '\(s.description)' != '\(r.descr)'") }
                if r.debit != s.debit { mismatches.append("row \(i) debit \(s.debit) != \(r.debit)") }
                if r.credit != s.credit { mismatches.append("row \(i) credit \(s.credit) != \(r.credit)") }
                if r.balance != s.balance {
                    mismatches.append("row \(i) balance \(String(describing: s.balance)) != \(String(describing: r.balance))")
                }
                if r.category != s.category { mismatches.append("row \(i) category \(s.category) != \(r.category)") }
                if s.bank != out.bankName {
                    mismatches.append("row \(i) bank \(String(describing: s.bank)) != \(String(describing: out.bankName))")
                }
            }
            XCTAssertTrue(mismatches.isEmpty,
                          "\(name): DB round-trip corrupted fields — " + mismatches.joined(separator: " | "))
        }
    }
}
