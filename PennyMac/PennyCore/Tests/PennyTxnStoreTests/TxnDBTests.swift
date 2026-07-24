// TxnDBTests — guards the SQLite transaction store (TxnDB.swift, the db.py port).
// Verifies that a DB created at an arbitrary path materialises the expected schema;
// that inserted TxnRows round-trip field-for-field (including NULL balance vs 0.0,
// NULL bank_name, per-row currency, and the hidden month/year/month_no/day/merchant/seq
// columns); that reads are ordered by seq and scoped to a single user (multi-user
// isolation); that deleteUser / deleteDocument remove exactly their slice of data;
// that insert is append-only so the canonical re-ingest flow is delete-then-insert
// (as penny-conformance's runner does); that a fresh empty DB reads as empty rather
// than erroring; that data persists across connection close/reopen (WAL mode); and
// that a real ingested fixture (Coop_Demo_Statement.pdf) survives the DB round-trip
// bit-for-bit against the ingester's output and the contract's expected figures.
import XCTest
import SQLite3
@testable import PennyTxnStore

final class TxnDBTests: XCTestCase {

    // MARK: - Plumbing

    private var dbPaths: [String] = []

    override func tearDown() {
        let fm = FileManager.default
        for p in dbPaths {
            try? fm.removeItem(atPath: p)
            try? fm.removeItem(atPath: p + "-wal")
            try? fm.removeItem(atPath: p + "-shm")
        }
        dbPaths = []
        super.tearDown()
    }

    /// Fresh throwaway DB path, tracked for cleanup.
    private func newDBPath(_ label: String) -> String {
        let p = TestPaths.tempDBPath(label)
        dbPaths.append(p)
        return p
    }

    /// Minimal TxnRow factory; month/year/monthNo/day derive from the date string.
    private func makeRow(seq: Int,
                         date: String = "2026-06-01",
                         descr: String,
                         merchant: String = "",
                         category: String = "Other",
                         debit: Double = 0,
                         credit: Double = 0,
                         balance: Double? = nil,
                         currency: String = "INR") -> TxnRow {
        TxnRow(txnDate: date,
               month: String(date.prefix(7)),
               year: Int(date.prefix(4)) ?? 0,
               monthNo: Int(date.dropFirst(5).prefix(2)) ?? 0,
               day: Int(date.suffix(2)) ?? 0,
               descr: descr, merchant: merchant, category: category,
               debit: debit, credit: credit, balance: balance,
               currency: currency, seq: seq)
    }

    /// Raw SQL against the store's own connection (via @testable access to `db.db`)
    /// so columns conformanceRows() doesn't expose can be verified too.
    /// NULL -> nil, INTEGER -> Int64, FLOAT -> Double, TEXT -> String.
    private func rawRows(_ db: TxnDB, _ sql: String,
                         file: StaticString = #filePath, line: UInt = #line) -> [[Any?]] {
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db.db, sql, -1, &stmt, nil) == SQLITE_OK else {
            XCTFail("sqlite prepare failed for: \(sql)", file: file, line: line)
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var out: [[Any?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [Any?] = []
            for i in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_NULL:    row.append(nil)
                case SQLITE_INTEGER: row.append(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT:   row.append(sqlite3_column_double(stmt, i))
                default:
                    row.append(sqlite3_column_text(stmt, i).map { String(cString: $0) })
                }
            }
            out.append(row)
        }
        return out
    }

    // MARK: - Creation & empty-DB behaviour

    func testCreateAtTempPathMaterialisesFileAndSchema() throws {
        let path = newDBPath("create")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "temp DB path should start empty: \(path)")
        let db = try TxnDB(path: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "TxnDB(path:) must create the SQLite file on disk")

        let tables = rawRows(db, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            .compactMap { $0.first as? String }
        XCTAssertTrue(tables.contains("transactions"),
                      "schema must include the transactions table; got \(tables)")
        XCTAssertTrue(tables.contains("document_metadata"),
                      "schema must include the document_metadata table; got \(tables)")

        let indexes = rawRows(db, "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_txn_%'")
            .compactMap { $0.first as? String }
        for col in ["user_id", "doc_name", "month", "category", "merchant", "year", "month_no"] {
            XCTAssertTrue(indexes.contains("idx_txn_\(col)"),
                          "missing index idx_txn_\(col); got \(indexes)")
        }
    }

    func testFreshEmptyDBReadsEmptyAndDeletesAreNoOps() throws {
        let db = try TxnDB(path: newDBPath("empty"))
        XCTAssertEqual(db.conformanceRows(userID: "nobody").count, 0,
                       "fresh DB must return zero rows, not error")
        // Deletes against a user/doc that never existed must be harmless no-ops.
        db.deleteUser(userID: "ghost")
        db.deleteDocument(userID: "ghost", docName: "ghost.pdf")
        // Inserting an empty batch must also be a harmless no-op.
        db.insert(rows: [], userID: "u", docName: "d.pdf", bankName: "B")
        XCTAssertEqual(db.conformanceRows(userID: "u").count, 0,
                       "empty insert batch must store nothing")
    }

    // MARK: - Field-for-field round-trip

    func testInsertAndReadBackFieldForField() throws {
        let db = try TxnDB(path: newDBPath("roundtrip"))
        let rows = [
            makeRow(seq: 0, date: "2026-06-01", descr: "TESCO STORES 2431",
                    merchant: "tesco", category: "Groceries",
                    debit: 42.15, credit: 0, balance: 2407.85, currency: "GBP"),
            makeRow(seq: 1, date: "2026-06-02", descr: "SALARY - ACME CORP LTD",
                    merchant: "acme corp", category: "Income",
                    debit: 0, credit: 2100.0, balance: 4507.85, currency: "GBP"),
            makeRow(seq: 2, date: "2026-06-03", descr: "CAFÉ ₹ — VADA PAV & CHAI",
                    merchant: "café", category: "Food & Dining",
                    debit: 120.5, credit: 0, balance: nil, currency: "INR"),
        ]
        db.insert(rows: rows, userID: "alice", docName: "june.pdf", bankName: "Coop Demo")

        let got = db.conformanceRows(userID: "alice")
        XCTAssertEqual(got.count, 3, "expected all 3 inserted rows back")
        guard got.count == 3 else { return }

        for (i, (g, r)) in zip(got, rows).enumerated() {
            XCTAssertEqual(g.date, r.txnDate, "row \(i) date")
            XCTAssertEqual(g.description, r.descr, "row \(i) description (unicode must survive)")
            XCTAssertEqual(g.debit, r.debit, "row \(i) debit")
            XCTAssertEqual(g.credit, r.credit, "row \(i) credit")
            XCTAssertEqual(g.balance, r.balance, "row \(i) balance")
            XCTAssertEqual(g.category, r.category, "row \(i) category")
            XCTAssertEqual(g.bank, "Coop Demo", "row \(i) bank_name")
        }

        // Columns conformanceRows() doesn't surface must be stored exactly too.
        let raw = rawRows(db, """
            SELECT user_id, doc_name, month, year, month_no, day, merchant, currency, seq
            FROM transactions WHERE user_id='alice' ORDER BY seq
            """)
        XCTAssertEqual(raw.count, 3)
        for (i, (cols, r)) in zip(raw, rows).enumerated() {
            XCTAssertEqual(cols[0] as? String, "alice", "row \(i) user_id")
            XCTAssertEqual(cols[1] as? String, "june.pdf", "row \(i) doc_name")
            XCTAssertEqual(cols[2] as? String, r.month, "row \(i) month (YYYY-MM)")
            XCTAssertEqual(cols[3] as? Int64, Int64(r.year), "row \(i) year")
            XCTAssertEqual(cols[4] as? Int64, Int64(r.monthNo), "row \(i) month_no")
            XCTAssertEqual(cols[5] as? Int64, Int64(r.day), "row \(i) day")
            XCTAssertEqual(cols[6] as? String, r.merchant, "row \(i) merchant")
            XCTAssertEqual(cols[7] as? String, r.currency, "row \(i) currency")
            XCTAssertEqual(cols[8] as? Int64, Int64(r.seq), "row \(i) seq")
        }
    }

    func testBalanceZeroIsDistinctFromNullBalance() throws {
        let db = try TxnDB(path: newDBPath("balnull"))
        db.insert(rows: [
            makeRow(seq: 0, descr: "ZERO BALANCE ROW", debit: 5, balance: 0.0),
            makeRow(seq: 1, descr: "NO BALANCE ROW", debit: 6, balance: nil),
        ], userID: "u", docName: "d.pdf", bankName: "B")

        let got = db.conformanceRows(userID: "u")
        XCTAssertEqual(got.count, 2)
        guard got.count == 2 else { return }
        XCTAssertEqual(got[0].balance, 0.0,
                       "a real 0.0 balance must read back as 0.0, not nil")
        XCTAssertNil(got[1].balance,
                     "a nil balance must be stored as SQL NULL and read back nil (Barclays-style rows)")
    }

    func testNilBankNameStoredAsNull() throws {
        let db = try TxnDB(path: newDBPath("nilbank"))
        db.insert(rows: [makeRow(seq: 0, descr: "MYSTERY BANK ROW", debit: 1)],
                  userID: "u", docName: "d.pdf", bankName: nil)
        let got = db.conformanceRows(userID: "u")
        XCTAssertEqual(got.count, 1)
        XCTAssertNil(got.first?.bank, "bankName nil must round-trip as nil, not \"\" ")
    }

    func testRowsComeBackOrderedBySeqNotInsertionOrder() throws {
        let db = try TxnDB(path: newDBPath("seqorder"))
        // Insert deliberately out of seq order.
        db.insert(rows: [
            makeRow(seq: 2, descr: "THIRD", debit: 3),
            makeRow(seq: 0, descr: "FIRST", debit: 1),
            makeRow(seq: 1, descr: "SECOND", debit: 2),
        ], userID: "u", docName: "d.pdf", bankName: "B")
        let descrs = db.conformanceRows(userID: "u").map(\.description)
        XCTAssertEqual(descrs, ["FIRST", "SECOND", "THIRD"],
                       "conformanceRows must ORDER BY seq, not by insertion/rowid order")
    }

    // MARK: - Multi-user isolation & deletes

    func testMultiUserIsolation() throws {
        let db = try TxnDB(path: newDBPath("isolation"))
        db.insert(rows: [makeRow(seq: 0, descr: "A ROW 1", debit: 10),
                         makeRow(seq: 1, descr: "A ROW 2", credit: 20)],
                  userID: "userA", docName: "a.pdf", bankName: "BankA")
        db.insert(rows: [makeRow(seq: 0, descr: "B ROW 1", debit: 99)],
                  userID: "userB", docName: "b.pdf", bankName: "BankB")

        let aRows = db.conformanceRows(userID: "userA")
        let bRows = db.conformanceRows(userID: "userB")
        XCTAssertEqual(aRows.map(\.description), ["A ROW 1", "A ROW 2"],
                       "userA must see exactly their own rows")
        XCTAssertEqual(bRows.map(\.description), ["B ROW 1"],
                       "userB must not see userA's rows")
        XCTAssertEqual(bRows.first?.bank, "BankB")
        XCTAssertEqual(db.conformanceRows(userID: "userC").count, 0,
                       "unknown user must read empty, not leak other users' data")
    }

    func testDeleteUserRemovesExactlyThatUsersData() throws {
        let db = try TxnDB(path: newDBPath("deluser"))
        db.insert(rows: [makeRow(seq: 0, descr: "A ROW", debit: 1)],
                  userID: "userA", docName: "a.pdf", bankName: "BankA")
        db.insert(rows: [makeRow(seq: 0, descr: "B ROW", debit: 2, balance: 50)],
                  userID: "userB", docName: "b.pdf", bankName: "BankB")

        db.deleteUser(userID: "userA")

        XCTAssertEqual(db.conformanceRows(userID: "userA").count, 0,
                       "deleteUser must remove all of userA's rows")
        let bRows = db.conformanceRows(userID: "userB")
        XCTAssertEqual(bRows.count, 1, "deleteUser(userA) must not touch userB")
        XCTAssertEqual(bRows.first?.description, "B ROW")
        XCTAssertEqual(bRows.first?.debit, 2)
        XCTAssertEqual(bRows.first?.balance, 50)

        // Deleting an already-deleted user is a harmless no-op.
        db.deleteUser(userID: "userA")
        XCTAssertEqual(db.conformanceRows(userID: "userB").count, 1)
    }

    func testDeleteDocumentScopedToUserAndDoc() throws {
        let db = try TxnDB(path: newDBPath("deldoc"))
        db.insert(rows: [makeRow(seq: 0, descr: "A DOC1", debit: 1)],
                  userID: "userA", docName: "doc1.pdf", bankName: "B")
        db.insert(rows: [makeRow(seq: 0, descr: "A DOC2", debit: 2)],
                  userID: "userA", docName: "doc2.pdf", bankName: "B")
        // userB owns a doc with the SAME name as userA's doc1 — must survive.
        db.insert(rows: [makeRow(seq: 0, descr: "B DOC1", debit: 3)],
                  userID: "userB", docName: "doc1.pdf", bankName: "B")

        db.deleteDocument(userID: "userA", docName: "doc1.pdf")

        XCTAssertEqual(db.conformanceRows(userID: "userA").map(\.description), ["A DOC2"],
                       "deleteDocument must remove only (userA, doc1.pdf) rows")
        XCTAssertEqual(db.conformanceRows(userID: "userB").map(\.description), ["B DOC1"],
                       "userB's doc1.pdf must survive userA's deleteDocument for the same doc name")
    }

    // MARK: - Re-ingest semantics

    func testInsertIsAppendOnlySoReingestFlowIsDeleteThenInsert() throws {
        // TxnDB.insert() never deletes: the conformance runner (main.swift) calls
        // deleteUser before insert. So a naive double-insert duplicates, and the
        // canonical re-ingest is deleteDocument (or deleteUser) followed by insert.
        let db = try TxnDB(path: newDBPath("reingest"))
        let v1 = [makeRow(seq: 0, descr: "V1 ROW A", debit: 10),
                  makeRow(seq: 1, descr: "V1 ROW B", credit: 20)]

        db.insert(rows: v1, userID: "u", docName: "stmt.pdf", bankName: "B")
        db.insert(rows: v1, userID: "u", docName: "stmt.pdf", bankName: "B")
        XCTAssertEqual(db.conformanceRows(userID: "u").count, 4,
                       "insert is append-only: inserting the same doc twice without deleting must duplicate rows")

        // Canonical replace flow: delete the doc, then insert the new parse.
        let v2 = [makeRow(seq: 0, descr: "V2 ROW A", debit: 11),
                  makeRow(seq: 1, descr: "V2 ROW B", credit: 22),
                  makeRow(seq: 2, descr: "V2 ROW C", debit: 33)]
        db.deleteDocument(userID: "u", docName: "stmt.pdf")
        db.insert(rows: v2, userID: "u", docName: "stmt.pdf", bankName: "B")
        let got = db.conformanceRows(userID: "u")
        XCTAssertEqual(got.map(\.description), ["V2 ROW A", "V2 ROW B", "V2 ROW C"],
                       "delete-then-insert must leave exactly the re-ingested rows, no v1 leftovers")
    }

    // MARK: - Currency metadata

    func testPerRowCurrencyRoundTrips() throws {
        let db = try TxnDB(path: newDBPath("currency"))
        db.insert(rows: [
            makeRow(seq: 0, descr: "UK ROW", debit: 1, currency: "GBP"),
            makeRow(seq: 1, descr: "IN ROW", debit: 2, currency: "INR"),
            makeRow(seq: 2, descr: "OM ROW", debit: 3, currency: "OMR"),
        ], userID: "u", docName: "d.pdf", bankName: "B")
        let currencies = rawRows(db, "SELECT currency FROM transactions WHERE user_id='u' ORDER BY seq")
            .compactMap { $0.first as? String }
        XCTAssertEqual(currencies, ["GBP", "INR", "OMR"],
                       "insert must store each row's own currency, not the schema default 'INR'")
    }

    // MARK: - Persistence across connections

    func testDataPersistsAcrossCloseAndReopen() throws {
        let path = newDBPath("persist")
        let rows = [makeRow(seq: 0, date: "2026-06-01", descr: "PERSISTED ROW",
                            merchant: "tesco", category: "Groceries",
                            debit: 42.15, balance: 2407.85, currency: "GBP")]

        var db1: TxnDB? = try TxnDB(path: path)
        db1?.insert(rows: rows, userID: "u", docName: "d.pdf", bankName: "Coop Demo")
        XCTAssertEqual(db1?.conformanceRows(userID: "u").count, 1)
        db1 = nil    // deinit -> sqlite3_close (WAL checkpoint)

        let db2 = try TxnDB(path: path)   // re-running the schema DDL must NOT wipe data
        let got = db2.conformanceRows(userID: "u")
        XCTAssertEqual(got.count, 1, "rows must survive close + reopen of the DB file")
        guard let g = got.first else { return }
        XCTAssertEqual(g.date, "2026-06-01")
        XCTAssertEqual(g.description, "PERSISTED ROW")
        XCTAssertEqual(g.debit, 42.15)
        XCTAssertEqual(g.credit, 0)
        XCTAssertEqual(g.balance, 2407.85)
        XCTAssertEqual(g.category, "Groceries")
        XCTAssertEqual(g.bank, "Coop Demo")

        // A second live connection (WAL) must see committed rows too.
        let db3 = try TxnDB(path: path)
        XCTAssertEqual(db3.conformanceRows(userID: "u").count, 1,
                       "a concurrent second connection must read committed data (WAL)")
    }

    // MARK: - Real-pipeline integration (grounded via penny-conformance / expected JSON)

    func testIngestedCoopFixtureRoundTripsThroughDB() throws {
        // Ground truth from the contract fixture Coop_Demo_Statement.pdf
        // (penny-conformance dump-rows + Coop_Demo_Statement_expected.json):
        // 37 rows, GBP, bank "Coop Demo".
        let pdf = TestPaths.fixturesDir.appendingPathComponent("Coop_Demo_Statement.pdf")
        let ingester = try TestPaths.makeIngester()
        let out = try ingester.ingestPDF(path: pdf.path)
        XCTAssertEqual(out.rows.count, 37, "Coop fixture must parse to 37 rows")
        XCTAssertEqual(out.bankName, "Coop Demo")

        let db = try TxnDB(path: newDBPath("coop"))
        db.insert(rows: out.rows, userID: "coop_user",
                  docName: "Coop_Demo_Statement.pdf", bankName: out.bankName)
        let got = db.conformanceRows(userID: "coop_user")
        XCTAssertEqual(got.count, out.rows.count,
                       "every ingested row must be stored and read back")

        // Stored rows must match the ingester's output bit-for-bit, in seq order.
        for (i, (g, r)) in zip(got, out.rows).enumerated() {
            XCTAssertEqual(g.date, r.txnDate, "fixture row \(i) date")
            XCTAssertEqual(g.description, r.descr, "fixture row \(i) description")
            XCTAssertEqual(g.debit, r.debit, "fixture row \(i) debit")
            XCTAssertEqual(g.credit, r.credit, "fixture row \(i) credit")
            XCTAssertEqual(g.balance, r.balance, "fixture row \(i) balance")
            XCTAssertEqual(g.category, r.category, "fixture row \(i) category")
            XCTAssertEqual(g.bank, "Coop Demo", "fixture row \(i) bank")
        }

        // Spot-check exact contract figures (from Coop_Demo_Statement_expected.json).
        guard let first = got.first, let last = got.last else { return }
        XCTAssertEqual(first.date, "2026-06-01")
        XCTAssertEqual(first.description, "TESCO STORES 2431 PATNA")
        XCTAssertEqual(first.debit, 42.15)
        XCTAssertEqual(first.credit, 0.0)
        XCTAssertEqual(first.balance, 2407.85)
        XCTAssertEqual(first.category, "Groceries")
        XCTAssertEqual(last.date, "2026-06-30")
        XCTAssertEqual(last.description, "STANDING ORDER - CAR INSURANCE")
        XCTAssertEqual(last.debit, 55.0)
        XCTAssertEqual(last.balance, 4000.19)
        XCTAssertEqual(last.category, "Investment & Insurance")
    }
}
