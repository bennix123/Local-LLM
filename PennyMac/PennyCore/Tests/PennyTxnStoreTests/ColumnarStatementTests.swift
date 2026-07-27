import XCTest
@testable import PennyTxnStore

/// Regression coverage for the bank-agnostic "Date | Narration | Debit | Credit |
/// Balance" column layout (Kotak, Axis, and any Indian-bank lookalike). These
/// statements previously parsed to ZERO transactions (the sidebar showed "0"
/// while the LLM, reading the raw text, still answered) because:
///   1. the amounts carry a stray leading letter — the ₹ glyph mis-decoded by the
///      PDF font subset (e.g. "n85,000.00") — so the generic money regex rejected
///      every amount, and
///   2. even with that fixed, the generic running-balance walk mis-classifies the
///      first row (a salary credit) since nothing seeds the opening balance.
/// The columnar parser assigns debit/credit by column x-position, so direction is
/// positional and unambiguous — and it keys on the column structure, not the bank
/// name, so every issuer using this format is covered by one parser.
final class ColumnarStatementTests: XCTestCase {

    /// Every fixture in this family shares the same generated body, so the same
    /// expectations hold — only the bank name differs. Add a new fixture here and
    /// it is covered automatically.
    private let fixtures: [(file: String, bank: String)] = [
        ("Kotak_Dummy_Statement.pdf", "Kotak Mahindra Bank"),
        ("Axis_Dummy_Statement.pdf",  "Axis Bank"),
    ]

    private func ingest(_ file: String) throws -> IngestOutput {
        let pdf = TestPaths.testDataDir.appendingPathComponent(file).path
        return try TestPaths.makeIngester().ingestPDF(path: pdf)
    }

    func testColumnarExtractsAllTransactions() throws {
        for f in fixtures {
            let out = try ingest(f.file)

            XCTAssertEqual(out.bankName, f.bank, f.file)
            XCTAssertEqual(out.detectedCurrency, "INR", f.file)
            XCTAssertEqual(out.rows.count, 12, "\(f.file): all 12 transactions should be extracted")

            // Positional direction: the two credit-column rows are income.
            XCTAssertEqual(out.rows.filter { $0.credit > 0 }.count, 2, "\(f.file): salary + refund are credits")
            XCTAssertEqual(out.rows.filter { $0.debit > 0 }.count, 10, f.file)

            // The first row is a salary CREDIT — the case the generic walk gets wrong.
            let first = try XCTUnwrap(out.rows.first)
            XCTAssertEqual(first.txnDate, "2026-10-01", f.file)
            XCTAssertEqual(first.credit, 85000.0, accuracy: 0.001, f.file)
            XCTAssertEqual(first.debit, 0.0, f.file)

            // Amounts parsed despite the ₹→"n" glyph corruption.
            let netflix = try XCTUnwrap(out.rows.first { $0.descr.lowercased().contains("netflix") }, f.file)
            XCTAssertEqual(netflix.debit, 649.0, accuracy: 0.001, f.file)

            // Totals.
            XCTAssertEqual(out.rows.reduce(0) { $0 + $1.credit }, 86250.0, accuracy: 0.001, f.file)
            XCTAssertEqual(out.rows.reduce(0) { $0 + $1.debit }, 40855.0, accuracy: 0.001, f.file)
        }
    }

    /// Prove the parsed rows answer real questions deterministically (what the user
    /// does in the app chat), not just that rows exist.
    func testColumnarAnswersQuestions() throws {
        for f in fixtures {
            let out = try ingest(f.file)
            let inr: (Double) -> String = { "₹" + String(format: "%.2f", $0) }
            func ask(_ q: String) -> String {
                FinanceRouter.answer(q, rows: out.rows, currency: "INR", money: inr) ?? "<deferred>"
            }

            XCTAssertTrue(ask("how many transactions are there?").contains("12"), f.file)
            let spend = ask("how much did I spend in total?")
            XCTAssertTrue(spend.contains("40855") || spend.contains("40,855"), "\(f.file): \(spend)")
            let income = ask("how much income did I receive?")
            XCTAssertTrue(income.contains("86250") || income.contains("86,250"), "\(f.file): \(income)")
            let biggest = ask("what was my largest expense?")
            XCTAssertTrue(biggest.contains("12499") || biggest.contains("12,499"), "\(f.file): \(biggest)")
        }
    }

    /// The hard multi-section case: five monthly statements in one document, with
    /// year-less date cells, no-decimal amounts, and header-less continuation pages.
    /// The balance chain reconciling end-to-end is the proof nothing was dropped.
    func testMultiSectionDocumentParsesEveryRow() throws {
        let out = try ingest("Dummy_Bank_Statements.pdf")
        XCTAssertEqual(out.bankName, "Dummy Bank")
        XCTAssertEqual(out.detectedCurrency, "INR")
        XCTAssertEqual(out.rows.count, 62, "all rows across the five sections")

        // Year filled from the section headers onto bare "DD-MMM" cells.
        XCTAssertEqual(out.rows.first?.txnDate, "2026-06-01")
        XCTAssertEqual(out.rows.last?.txnDate, "2026-10-29")

        // Dates non-decreasing and the running balance reconciles on every row —
        // a dropped or mis-columned row would break one or the other.
        for i in 1..<out.rows.count {
            XCTAssertLessThanOrEqual(out.rows[i - 1].txnDate, out.rows[i].txnDate, "row \(i)")
            let expected = (out.rows[i - 1].balance ?? 0) + out.rows[i].credit - out.rows[i].debit
            XCTAssertEqual(expected, out.rows[i].balance ?? 0, accuracy: 0.01, "balance chain at row \(i)")
        }
    }
}
