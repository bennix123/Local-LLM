import XCTest
@testable import PennyTxnStore

/// Coverage for a growing fleet of real Indian-bank statements that all share the
/// Date | Narration/Description | Debit | Credit | Balance layout the universal
/// columnar parser handles. Fixtures live in `test-data/columnar-family/` (a
/// subdirectory the sweep manifest deliberately doesn't scan) and are driven from
/// disk: drop another bank's statement in that folder (and add its expected
/// bank/row-count below) and it extends coverage with no new parser code.
///
/// One of these (PNB) also exercises the universal FALLBACK: "Punjab National
/// Bank" matches the legacy PNB bank profile, which forces the old `.pnb` route;
/// that parser can't read the modern columnar format, so ingest must recover via
/// the columnar parser rather than returning zero rows.
final class ColumnarFamilyTests: XCTestCase {

    /// file name → (expected detected bank, expected row count). Pack 1 bodies have
    /// 8 rows, Pack 2 have 11 — the exact count guards against silent row drops.
    private let expected: [String: (bank: String, rows: Int)] = [
        // Pack 1
        "AU_Statement.pdf": ("AU Small Finance Bank", 8),
        "BOB_Statement.pdf": ("Bank of Baroda", 8),
        "Bandhan_Statement.pdf": ("Bandhan Bank", 8),
        "Canara_Statement.pdf": ("Canara Bank", 8),
        "Federal_Statement.pdf": ("Federal Bank", 8),
        "IDFC_FIRST_Statement.pdf": ("IDFC FIRST Bank", 8),
        "IndusInd_Statement.pdf": ("IndusInd Bank", 8),
        "PNB_Statement.pdf": ("Punjab National Bank", 8),
        "Union_Statement.pdf": ("Union Bank of India", 8),
        "YesBank_Statement.pdf": ("Yes Bank", 8),
        // Pack 2
        "Bank_of_Maharashtra_Statement.pdf": ("Bank of Maharashtra", 11),
        "CSB_Bank_Statement.pdf": ("CSB Bank", 11),
        "Central_Bank_of_India_Statement.pdf": ("Central Bank of India", 11),
        "City_Union_Bank_Statement.pdf": ("City Union Bank", 11),
        "DCB_Bank_Statement.pdf": ("DCB Bank", 11),
        "Indian_Bank_Statement.pdf": ("Indian Bank", 11),
        "Jammu_&_Kashmir_Bank_Statement.pdf": ("Jammu & Kashmir Bank", 11),
        "Karnataka_Bank_Statement.pdf": ("Karnataka Bank", 11),
        "Karur_Vysya_Bank_Statement.pdf": ("Karur Vysya Bank", 11),
        "Nainital_Bank_Statement.pdf": ("Nainital Bank", 11),
        "Punjab_&_Sind_Bank_Statement.pdf": ("Punjab & Sind Bank", 11),
        "RBL_Bank_Statement.pdf": ("RBL Bank", 11),
        "South_Indian_Bank_Statement.pdf": ("South Indian Bank", 11),
        "Tamilnad_Mercantile_Bank_Statement.pdf": ("Tamilnad Mercantile Bank", 11),
        "UCO_Bank_Statement.pdf": ("UCO Bank", 11),
    ]

    private var familyDir: URL {
        TestPaths.testDataDir.appendingPathComponent("columnar-family", isDirectory: true)
    }

    func testEveryColumnarFamilyStatementParses() throws {
        let ing = try TestPaths.makeIngester()
        let pdfs = try FileManager.default.contentsOfDirectory(atPath: familyDir.path)
            .filter { $0.lowercased().hasSuffix(".pdf") }.sorted()
        XCTAssertFalse(pdfs.isEmpty, "no fixtures found in columnar-family/")

        for file in pdfs {
            let out = try ing.ingestPDF(path: familyDir.appendingPathComponent(file).path)

            // Universal invariants — hold for every statement in this family.
            XCTAssertFalse(out.rows.isEmpty, "\(file): parsed to zero rows (the regression this guards)")
            XCTAssertEqual(out.detectedCurrency, "INR", file)

            for (i, r) in out.rows.enumerated() {
                // Positional direction: each row is exactly one of debit/credit.
                XCTAssertTrue((r.debit > 0) != (r.credit > 0),
                              "\(file) row \(i): a row must be debit XOR credit")
            }
            for i in 1..<out.rows.count {
                XCTAssertLessThanOrEqual(out.rows[i - 1].txnDate, out.rows[i].txnDate, "\(file) order \(i)")
                // The running balance reconciles on every row — the completeness
                // proof that no row was dropped or mis-columned.
                let expectedBal = (out.rows[i - 1].balance ?? 0) + out.rows[i].credit - out.rows[i].debit
                XCTAssertEqual(expectedBal, out.rows[i].balance ?? 0, accuracy: 0.01, "\(file) chain \(i)")
            }

            // Pinned specifics where known (exact bank + row count catch drift).
            if let want = expected[file] {
                XCTAssertEqual(out.bankName, want.bank, "\(file): bank name")
                XCTAssertEqual(out.rows.count, want.rows, "\(file): row count drifted")
            }
        }
    }
}
