// TxnDB — SQLite store for parsed transactions (db.py port, system sqlite3).
import Foundation
import SQLite3

public final class TxnDB {
    var db: OpaquePointer? = nil
    static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw NSError(domain: "TxnDB", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot open \(path)"])
        }
        exec("PRAGMA journal_mode=WAL")
        exec("""
            CREATE TABLE IF NOT EXISTS transactions (
                id        INTEGER PRIMARY KEY,
                user_id   TEXT,
                doc_name  TEXT,
                bank_name TEXT,
                txn_date  TEXT,
                month     TEXT,
                year      INTEGER,
                month_no  INTEGER,
                day       INTEGER,
                descr     TEXT,
                merchant  TEXT,
                category  TEXT,
                debit     REAL,
                credit    REAL,
                balance   REAL,
                currency  TEXT DEFAULT 'INR',
                seq       INTEGER,
                extraction_confidence REAL DEFAULT 1.0
            )
            """)
        exec("""
            CREATE TABLE IF NOT EXISTS document_metadata (
                user_id          TEXT,
                doc_name         TEXT,
                parse_confidence TEXT,
                upload_ts        TEXT,
                extraction_confidence REAL DEFAULT 1.0,
                PRIMARY KEY (user_id, doc_name)
            )
            """)
        for col in ["user_id", "doc_name", "month", "category", "merchant", "year", "month_no"] {
            exec("CREATE INDEX IF NOT EXISTS idx_txn_\(col) ON transactions(\(col))")
        }
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    public func deleteDocument(userID: String, docName: String) {
        var stmt: OpaquePointer? = nil
        sqlite3_prepare_v2(db, "DELETE FROM transactions WHERE user_id=? AND doc_name=?", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, userID, -1, Self.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, docName, -1, Self.SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    public func deleteUser(userID: String) {
        var stmt: OpaquePointer? = nil
        sqlite3_prepare_v2(db, "DELETE FROM transactions WHERE user_id=?", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, userID, -1, Self.SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    public func insert(rows: [TxnRow], userID: String, docName: String, bankName: String?) {
        exec("BEGIN")
        var stmt: OpaquePointer? = nil
        sqlite3_prepare_v2(db, """
            INSERT INTO transactions
            (user_id,doc_name,bank_name,txn_date,month,year,month_no,day,descr,merchant,category,
             debit,credit,balance,currency,seq)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, -1, &stmt, nil)
        for t in rows {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, userID, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, docName, -1, Self.SQLITE_TRANSIENT)
            if let bankName {
                sqlite3_bind_text(stmt, 3, bankName, -1, Self.SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_text(stmt, 4, t.txnDate, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, t.month, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 6, Int64(t.year))
            sqlite3_bind_int64(stmt, 7, Int64(t.monthNo))
            sqlite3_bind_int64(stmt, 8, Int64(t.day))
            sqlite3_bind_text(stmt, 9, t.descr, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 10, t.merchant, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 11, t.category, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 12, t.debit)
            sqlite3_bind_double(stmt, 13, t.credit)
            if let b = t.balance {
                sqlite3_bind_double(stmt, 14, b)
            } else {
                sqlite3_bind_null(stmt, 14)
            }
            sqlite3_bind_text(stmt, 15, t.currency, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 16, Int64(t.seq))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        exec("COMMIT")
    }

    public struct StoredRow {
        public let date: String
        public let description: String
        public let debit: Double
        public let credit: Double
        public let balance: Double?
        public let category: String
        public let bank: String?
    }

    /// The conformance query: SELECT txn_date, descr, debit, credit, balance,
    /// category, bank_name ... ORDER BY seq.
    public func conformanceRows(userID: String) -> [StoredRow] {
        var stmt: OpaquePointer? = nil
        sqlite3_prepare_v2(db, """
            SELECT txn_date, descr, debit, credit, balance, category, bank_name
            FROM transactions WHERE user_id = ? ORDER BY seq
            """, -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, userID, -1, Self.SQLITE_TRANSIENT)
        var out: [StoredRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ i: Int32) -> String? {
                guard let c = sqlite3_column_text(stmt, i) else { return nil }
                return String(cString: c)
            }
            let balance: Double? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil : sqlite3_column_double(stmt, 4)
            out.append(StoredRow(date: text(0) ?? "",
                                 description: text(1) ?? "",
                                 debit: sqlite3_column_double(stmt, 2),
                                 credit: sqlite3_column_double(stmt, 3),
                                 balance: balance,
                                 category: text(5) ?? "",
                                 bank: text(6)))
        }
        sqlite3_finalize(stmt)
        return out
    }
}
