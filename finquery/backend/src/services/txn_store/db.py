import sqlite3, os
DB_PATH = os.getenv("TXN_DB_PATH", os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", "data", "live_txn.db")))

def connect():
    con = sqlite3.connect(DB_PATH)
    con.execute("PRAGMA journal_mode=WAL")
    return con


def init_db():
    con = connect()
    con.execute("""
        CREATE TABLE IF NOT EXISTS transactions (
            id        INTEGER PRIMARY KEY,
            user_id   TEXT,
            doc_name  TEXT,
            bank_name TEXT,
            txn_date  TEXT,    -- YYYY-MM-DD
            month     TEXT,    -- YYYY-MM
            year      INTEGER, -- YYYY
            month_no  INTEGER, -- 1-12
            day       INTEGER, -- 1-31
            descr     TEXT,
            merchant  TEXT,
            category  TEXT,
            debit     REAL,
            credit    REAL,
            balance   REAL,
            currency  TEXT DEFAULT 'INR',
            seq       INTEGER  -- row order within the document
        )""")
    # Migrate DBs created before the split year/month_no/day columns existed.
    cols = {r[1] for r in con.execute("PRAGMA table_info(transactions)")}
    for col in ("year", "month_no", "day"):
        if col not in cols:
            con.execute(f"ALTER TABLE transactions ADD COLUMN {col} INTEGER")
    if "currency" not in cols:
        con.execute("ALTER TABLE transactions ADD COLUMN currency TEXT DEFAULT 'INR'")
    if "bank_name" not in cols:
        con.execute("ALTER TABLE transactions ADD COLUMN bank_name TEXT")
    # Backfill the split parts from txn_date for any rows that lack them.
    con.execute("""UPDATE transactions
                      SET year     = CAST(substr(txn_date,1,4) AS INTEGER),
                          month_no = CAST(substr(txn_date,6,2) AS INTEGER),
                          day      = CAST(substr(txn_date,9,2) AS INTEGER)
                    WHERE year IS NULL AND txn_date IS NOT NULL AND txn_date <> ''""")
    for col in ("user_id", "doc_name", "month", "category", "merchant", "year", "month_no"):
        con.execute(f"CREATE INDEX IF NOT EXISTS idx_txn_{col} ON transactions({col})")
    # Pre-computed financial-intelligence findings (the "Insight Engine" store).
    # Populated on upload by compute_insights(); read back deterministically.
    con.execute("""
        CREATE TABLE IF NOT EXISTS insights (
            id          INTEGER PRIMARY KEY,
            user_id     TEXT,
            doc_name    TEXT,
            type        TEXT,    -- health | risk | pattern | behavior | impact
            title       TEXT,
            explanation TEXT,
            score       REAL,
            evidence    TEXT,    -- JSON blob of the supporting numbers
            created     TEXT DEFAULT CURRENT_TIMESTAMP
        )""")
    con.execute("""
        CREATE TABLE IF NOT EXISTS document_metadata (
            user_id          TEXT,
            doc_name         TEXT,
            parse_confidence TEXT,
            PRIMARY KEY (user_id, doc_name)
        )""")
    
    if "extraction_confidence" not in cols:
        con.execute("ALTER TABLE transactions ADD COLUMN extraction_confidence REAL DEFAULT 1.0")
    cols_meta = {r[1] for r in con.execute("PRAGMA table_info(document_metadata)")}
    if "upload_ts" not in cols_meta:
        con.execute("ALTER TABLE document_metadata ADD COLUMN upload_ts TEXT")
    if "extraction_confidence" not in cols_meta:
        con.execute("ALTER TABLE document_metadata ADD COLUMN extraction_confidence REAL DEFAULT 1.0")
        
    con.execute("CREATE INDEX IF NOT EXISTS idx_insights_user ON insights(user_id)")
    con.commit()
    con.close()



# ------------------------------------------------------------------ ingest
