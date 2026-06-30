"""
Deterministic transaction store (the "Penny SQL layer" for FinQuery).

Bank/card statements with lakh-scale rows cannot be answered by RAG: retrieving
the top-k chunks and asking an LLM to sum them is wrong by construction. This
module parses transaction rows out of a statement PDF into SQLite and answers
aggregate questions (totals, category/merchant spend, month-wise, balance,
extremes) with exact SQL -- numbers never touch the LLM.

Narrative / open-ended questions return None here so the caller can fall back to
the RAG engine.

Pure stdlib (sqlite3) + PyMuPDF for text extraction. No Camelot, no cloud LLM.
"""
import json
import os
import re
import sqlite3

import pymupdf

DB_PATH = os.getenv("TXN_DB_PATH", os.path.join(os.path.dirname(__file__), "..", "..", "finquery_txn.db"))

# merchant token -> (canonical name, category). Used to categorise parsed rows.
MERCHANT_MAP = {
    "swiggy": ("Swiggy", "Food & Dining"), "zomato": ("Zomato", "Food & Dining"),
    "amazon": ("Amazon", "Shopping"), "flipkart": ("Flipkart", "Shopping"),
    "myntra": ("Myntra", "Shopping"), "bigbasket": ("BigBasket", "Groceries"),
    "blinkit": ("Blinkit", "Groceries"), "dmart": ("DMart", "Groceries"),
    "uber": ("Uber", "Transport"), "ola": ("Ola", "Transport"),
    "irctc": ("IRCTC", "Transport"), "netflix": ("Netflix", "Entertainment"),
    "spotify": ("Spotify", "Entertainment"), "bookmyshow": ("BookMyShow", "Entertainment"),
    "jio": ("Jio", "Utilities"), "airtel": ("Airtel", "Utilities"),
    "tata_power": ("Tata Power", "Utilities"), "tata power": ("Tata Power", "Utilities"),
    "apollo": ("Apollo Pharmacy", "Healthcare"), "pharmeasy": ("PharmEasy", "Healthcare"),
    "lic": ("LIC Premium", "Investment & Insurance"), "zerodha": ("Zerodha", "Investment & Insurance"),
    "axis_bank_car_loan": ("Axis Bank Car Loan", "Investment & Insurance"),
    "salary": ("Salary Credit", "Income"), "interest": ("Interest Earned", "Income"),
    "refund": ("Refund", "Income"),
}

# A transaction row. Only ONE of debit/credit is ever present, so an empty
# numeric column collapses to whitespace. We therefore capture exactly the two
# numbers that DO appear (amount, balance) and use the DR/CR flag to decide
# which side the amount belongs to. Balance may be negative.
ROW_RE = re.compile(
    r"^(\d{2}-\d{2}-\d{4})\s{2,}(\S.*?)\s{2,}(DR|CR)\s+(-?[\d,]+\.\d{2})\s+(-?[\d,]+\.\d{2})\s*$"
)


# ------------------------------------------------------------------ formatting
def inr(n):
    """Indian comma grouping with 2 decimals."""
    neg = n < 0
    n = abs(round(float(n), 2))
    intpart, dec = f"{n:.2f}".split(".")
    if len(intpart) > 3:
        head, tail = intpart[:-3], intpart[-3:]
        groups = []
        while len(head) > 2:
            groups.insert(0, head[-2:]); head = head[:-2]
        if head:
            groups.insert(0, head)
        intpart = ",".join(groups) + "," + tail
    return ("-" if neg else "") + f"₹{intpart}.{dec}"


def grp(n):
    """Indian comma grouping for plain integers (counts)."""
    s = str(int(n));
    if len(s) <= 3:
        return s
    head, tail = s[:-3], s[-3:]
    out = []
    while len(head) > 2:
        out.insert(0, head[-2:]); head = head[:-2]
    if head:
        out.insert(0, head)
    return ",".join(out) + "," + tail


def _money(s):
    return float(s.replace(",", "")) if s and s.strip() else 0.0


# ------------------------------------------------------------------ db
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
            seq       INTEGER  -- row order within the document
        )""")
    # Migrate DBs created before the split year/month_no/day columns existed.
    cols = {r[1] for r in con.execute("PRAGMA table_info(transactions)")}
    for col in ("year", "month_no", "day"):
        if col not in cols:
            con.execute(f"ALTER TABLE transactions ADD COLUMN {col} INTEGER")
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
    con.execute("CREATE INDEX IF NOT EXISTS idx_insights_user ON insights(user_id)")
    con.commit()
    con.close()


# ------------------------------------------------------------------ ingest
def is_transaction_statement(text):
    """Heuristic: many DD-MM-YYYY rows carrying DR/CR + a balance column."""
    sample = text[:20000]
    rows = ROW_RE.findall_count if False else len(ROW_RE.findall(sample))
    has_cols = bool(re.search(r"\bDebit\b.*\bCredit\b.*\bBalance\b", sample, re.I))
    return rows >= 5 or (has_cols and rows >= 1)


def _classify(descr):
    low = descr.lower()
    for token, (name, cat) in MERCHANT_MAP.items():
        if token in low:
            return name, cat
    # fall back to the slug between the first two slashes: TYPE/MERCHANT/REF
    parts = descr.split("/")
    if len(parts) >= 2:
        return parts[1].replace("_", " ").strip(), "Other"
    return descr.strip()[:40], "Other"


def parse_pdf(pdf_path):
    """Yield transaction dicts parsed from the PDF text (streaming, low memory)."""
    doc = pymupdf.open(pdf_path)
    seq = 0
    for page in doc:
        for line in page.get_text("text").splitlines():
            m = ROW_RE.match(line)
            if not m:
                continue
            d, descr, drcr, amount, balance = m.groups()
            yyyy_mm_dd = f"{d[6:10]}-{d[3:5]}-{d[0:2]}"
            merchant, category = _classify(descr)
            amt = _money(amount)
            seq += 1
            yield {
                "txn_date": yyyy_mm_dd, "month": yyyy_mm_dd[:7],
                "year": int(d[6:10]), "month_no": int(d[3:5]), "day": int(d[0:2]),
                "descr": descr, "merchant": merchant, "category": category,
                "debit": amt if drcr == "DR" else 0.0,
                "credit": amt if drcr == "CR" else 0.0,
                "balance": _money(balance), "seq": seq,
            }
    doc.close()


def ingest_pdf(pdf_path, doc_name, user_id, batch=5000):
    """Parse a statement PDF into SQLite. Returns count of rows ingested."""
    init_db()
    con = connect()
    con.execute("DELETE FROM transactions WHERE user_id=? AND doc_name=?", (user_id, doc_name))
    rows, buf, n = con, [], 0
    sql = ("INSERT INTO transactions"
           "(user_id,doc_name,txn_date,month,year,month_no,day,descr,merchant,category,debit,credit,balance,seq)"
           " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
    for t in parse_pdf(pdf_path):
        buf.append((user_id, doc_name, t["txn_date"], t["month"], t["year"], t["month_no"], t["day"],
                    t["descr"], t["merchant"], t["category"], t["debit"], t["credit"], t["balance"], t["seq"]))
        if len(buf) >= batch:
            con.executemany(sql, buf); n += len(buf); buf = []
    if buf:
        con.executemany(sql, buf); n += len(buf)
    con.commit(); con.close()
    return n


# ------------------------------------------------------------------ queries
def _scope(user_id, doc_name, period=None):
    """period filter on txn_date (YYYY-MM-DD), so a prefix works at any granularity:
         None                          -> no filter
         "YYYY" / "YYYY-MM" / "YYYY-MM-DD" -> prefix match (year / month / day)
         ("YYYY-MM-DD", "YYYY-MM-DD")  -> inclusive date range (BETWEEN)
    """
    where = "user_id=?"
    params = [user_id]
    if doc_name:
        where += " AND doc_name=?"; params.append(doc_name)
    if period:
        if isinstance(period, (tuple, list)):
            # Pad partial bounds so a 'YYYY' / 'YYYY-MM' tuple can't silently drop
            # the edge month/day (string BETWEEN '2024-05' AND '2024-07' would
            # exclude all of July). dispatch already passes full dates; this just
            # makes _scope correct for any caller.
            s, e = period[0], period[1]
            s = s if len(s) == 10 else (s + "-01" if len(s) == 7 else s + "-01-01")
            e = e if len(e) == 10 else (e + "-31" if len(e) == 7 else e + "-12-31")
            where += " AND txn_date BETWEEN ? AND ?"; params += [s, e]
        elif isinstance(period, str) and period.startswith("MD-"):
            # a calendar day across ALL years ("MD-08-15" -> any 15 August)
            where += " AND substr(txn_date,6,5)=?"; params.append(period[3:])
        else:
            where += " AND txn_date LIKE ?"; params.append(period + "%")
    return where, params


def coverage(user_id, doc_name=None):
    """Returns (min_month, max_month, [years]) of available data, or None."""
    w, p = _scope(user_id, doc_name)
    con = connect()
    r = con.execute(f"SELECT MIN(month), MAX(month) FROM transactions WHERE {w}", p).fetchone()
    if not r or not r[0]:
        con.close(); return None
    years = [row[0] for row in con.execute(
        f"SELECT DISTINCT substr(month,1,4) FROM transactions WHERE {w} ORDER BY 1", p).fetchall()]
    con.close()
    return r[0], r[1], years


def overview(user_id, doc_name=None, period=None):
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    r = con.execute(f"""SELECT COUNT(*), COALESCE(SUM(debit),0), COALESCE(SUM(credit),0)
                        FROM transactions WHERE {w}""", p).fetchone()
    con.close()
    return {"count": r[0], "debit": r[1], "credit": r[2], "net": r[2] - r[1]}


def latest_balance(user_id, doc_name=None, period=None):
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    r = con.execute(f"SELECT balance FROM transactions WHERE {w} ORDER BY seq DESC LIMIT 1", p).fetchone()
    con.close()
    return r[0] if r else None


def by_category(user_id, doc_name=None, period=None):
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    rows = con.execute(f"""SELECT category, SUM(debit), COUNT(*) FROM transactions
                           WHERE {w} AND debit>0 GROUP BY category ORDER BY 2 DESC""", p).fetchall()
    con.close()
    return rows


def merchant_spend(user_id, keyword, doc_name=None, period=None):
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    # Match the canonical merchant column (exact, case-insensitive) OR the description
    # text. Descriptions store multi-word names with underscores ("Axis_Bank_Car_Loan"),
    # so a spaced LIKE alone misses them — the merchant-column match fixes that.
    r = con.execute(f"""SELECT COALESCE(SUM(debit),0), COALESCE(SUM(credit),0), COUNT(*),
                        SUM(CASE WHEN debit>0 THEN 1 ELSE 0 END)
                        FROM transactions WHERE {w} AND (LOWER(merchant)=? OR LOWER(descr) LIKE ?)""",
                    p + [keyword.lower(), f"%{keyword.lower()}%"]).fetchone()
    con.close()
    return {"debit": r[0], "credit": r[1], "count": r[2], "dcount": r[3] or 0}


def by_month(user_id, doc_name=None, period=None):
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    rows = con.execute(f"""SELECT month, SUM(debit), SUM(credit), COUNT(*) FROM transactions
                           WHERE {w} GROUP BY month ORDER BY month""", p).fetchall()
    con.close()
    return rows


def income_by_source(user_id, doc_name=None, period=None):
    """Credit (income) grouped by source merchant, largest first."""
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    rows = con.execute(f"""SELECT merchant, SUM(credit), COUNT(*) FROM transactions
                           WHERE {w} AND credit>0 GROUP BY merchant ORDER BY 2 DESC""", p).fetchall()
    con.close()
    return rows


def top_merchants(user_id, n=8, doc_name=None, period=None):
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    rows = con.execute(f"""SELECT merchant, SUM(debit), COUNT(*) FROM transactions
                           WHERE {w} AND debit>0 GROUP BY merchant ORDER BY 2 DESC LIMIT ?""",
                       p + [n]).fetchall()
    con.close()
    return rows


def txn_count(user_id, kind=None, doc_name=None, period=None):
    """Count transactions, optionally restricted to debit / credit / UPI rows."""
    w, p = _scope(user_id, doc_name, period)
    cond = {"debit": " AND debit>0", "credit": " AND credit>0",
            "upi": " AND LOWER(descr) LIKE '%upi%'"}.get(kind, "")
    con = connect()
    r = con.execute(f"SELECT COUNT(*) FROM transactions WHERE {w}{cond}", p).fetchone()[0]
    con.close()
    return r


def amount_filter(user_id, op, amount, doc_name=None, period=None, merchant=None, category=None):
    """Count + total of expense transactions over/under an amount, optionally scoped to a
    merchant (canonical name or descr match) and/or a category."""
    w, p = _scope(user_id, doc_name, period)
    cmp = ">=" if op == "over" else "<="
    params = list(p) + [amount]
    extra = ""
    if merchant:
        extra += " AND (LOWER(merchant)=? OR LOWER(descr) LIKE ?)"
        params += [merchant.lower(), f"%{merchant.lower()}%"]
    if category:
        extra += " AND category=?"
        params += [category]
    con = connect()
    r = con.execute(f"""SELECT COUNT(*), COALESCE(SUM(debit),0), COALESCE(MAX(debit),0)
                        FROM transactions WHERE {w} AND debit>0 AND debit {cmp} ?{extra}""",
                    params).fetchone()
    con.close()
    return {"count": r[0], "total": r[1], "max": r[2]}


def filtered_summary(user_id, merchant=None, category=None, period=None, doc_name=None,
                     weekend=None, txn_type=None):
    """Count + total of transactions matching optional merchant / category / period /
    weekend / txn_type filters. weekend: True = Sat/Sun only, False = weekdays only.
    txn_type: 'debit' | 'credit'. Every figure from SQL."""
    w, p = _scope(user_id, doc_name, period)
    clauses = [w]
    params = list(p)
    if merchant:
        clauses.append("(LOWER(merchant)=? OR LOWER(descr) LIKE ?)")
        params += [merchant.lower(), f"%{merchant.lower()}%"]
    if category:
        clauses.append("category=?")
        params += [category]
    if txn_type == "debit":
        clauses.append("debit>0")
    elif txn_type == "credit":
        clauses.append("credit>0")
    if weekend is True:
        clauses.append("CAST(strftime('%w',txn_date) AS INT) IN (0,6)")
    elif weekend is False:
        clauses.append("CAST(strftime('%w',txn_date) AS INT) NOT IN (0,6)")
    con = connect()
    r = con.execute(f"""SELECT COUNT(*), COALESCE(SUM(debit),0), COALESCE(SUM(credit),0)
                        FROM transactions WHERE {" AND ".join(clauses)}""", params).fetchone()
    con.close()
    return {"count": r[0], "debit": r[1], "credit": r[2], "total": (r[2] if txn_type == "credit" else r[1])}


# categories that are realistically discretionary (easy to trim) vs largely fixed
DISCRETIONARY = {"Shopping", "Food & Dining", "Entertainment"}
FIXED_CATS = {"Utilities", "Healthcare", "Investment & Insurance"}


def advice_context(user_id, doc_name=None, period=None):
    """
    Returns (snapshot_markdown, grounding_text):
      - snapshot_markdown: a REAL comma-formatted table (exact SQL figures) shown to the user.
      - grounding_text:    a NUMBER-FREE but information-RICH profile for the LLM: ranked
                           categories with qualitative dominance, correct merchant->category
                           groups (so it can't mislabel), surplus/deficit, and which
                           categories are discretionary vs fixed. No figures leak.
    """
    o = overview(user_id, doc_name, period)
    cats = by_category(user_id, doc_name, period)
    present = {m for m, _t, _n in top_merchants(user_id, 50, doc_name)}

    snap_rows = [(c, inr(t), grp(n)) for c, t, n in cats]
    snapshot = ("**Your spending snapshot**\n\n"
                + _table(["Category", "Spent", "Txns"], snap_rows)
                + f"\n\nTotal spending {inr(o['debit'])} · total income {inr(o['credit'])} "
                  f"· net {inr(o['net'])} over {grp(o['count'])} transactions.")

    if not cats:
        return snapshot, "The user has no spending recorded."

    total = o["debit"] or 1
    top_cat, top_total = cats[0][0], cats[0][1]
    share = top_total / total
    dom = ("by far the largest, dwarfing everything else" if share > 0.45
           else "the largest" if share > 0.25 else "the top category")

    ranked = ", ".join(c for c, _t, _n in cats)
    smallest = ", ".join(c for c, _t, _n in cats[-3:][::-1])

    # correct category -> merchant groups, only for merchants actually present
    cat_to_merch = {}
    for _tok, (name, cat) in MERCHANT_MAP.items():
        if name in present and cat != "Income":
            cat_to_merch.setdefault(cat, [])
            if name not in cat_to_merch[cat]:
                cat_to_merch[cat].append(name)
    groups = "; ".join(f"{c} = {', '.join(ms)}" for c, ms in cat_to_merch.items())

    disc = [c for c, _t, _n in cats if c in DISCRETIONARY]  # already in spend order
    fixed = [c for c, _t, _n in cats if c in FIXED_CATS]
    surplus = ("a healthy surplus (income clearly exceeds spending)" if o["net"] > 0
               else "roughly break-even" if o["net"] == 0
               else "a deficit (spending exceeds income)")
    cut_line = (f"Among discretionary spending, {disc[0]} is the largest and the best target "
                f"for cuts; {', '.join(disc[1:])} are smaller but also flexible."
                if len(disc) > 1 else
                (f"{disc[0]} is the main discretionary category to trim." if disc else
                 "No clearly discretionary categories stand out."))

    grounding = (
        "FACTUAL PROFILE of the user's spending (use this; do NOT repeat any of the exact "
        "figures — the user already sees them in a table):\n"
        f"- Overall they are running {surplus}.\n"
        f"- Categories ranked from MOST spent to LEAST: {ranked}.\n"
        f"- {top_cat} is {dom}.\n"
        f"- The three lowest-spend categories are: {smallest}.\n"
        f"- Merchant groupings (use ONLY these; never attribute a product a merchant "
        f"doesn't sell): {groups}.\n"
        f"- To save money, cut DISCRETIONARY categories, not size: {cut_line}\n"
        f"- Largely fixed/committed (hard to cut): {', '.join(fixed) or 'none'}.\n"
        "Note: a category can be both large AND discretionary (e.g. Shopping) — large "
        "discretionary categories are the best savings targets, do not call them 'small'."
    )
    return snapshot, grounding


def top_expenses(user_id, n=5, doc_name=None, period=None):
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    rows = con.execute(f"""SELECT txn_date, merchant, debit FROM transactions
                           WHERE {w} AND debit>0 ORDER BY debit DESC LIMIT ?""", p + [n]).fetchall()
    con.close()
    return rows


def extreme(user_id, kind, doc_name=None, period=None, merchant=None):
    w, p = _scope(user_id, doc_name, period)
    col, order = ("debit", "DESC") if kind in ("largest_expense", "smallest_expense") else ("credit", "DESC")
    if kind == "smallest_expense":
        order = "ASC"
    mfilter, mp = "", []
    if merchant:
        mfilter = " AND (LOWER(merchant)=? OR LOWER(descr) LIKE ?)"
        mp = [merchant.lower(), f"%{merchant.lower()}%"]
    con = connect()
    r = con.execute(f"""SELECT txn_date, merchant, {col} FROM transactions
                        WHERE {w} AND {col}>0{mfilter} ORDER BY {col} {order} LIMIT 1""",
                    p + mp).fetchone()
    con.close()
    return r


# ------------------------------------------------------------------ md tables
def _table(headers, rows):
    out = ["| " + " | ".join(headers) + " |",
           "| " + " | ".join("---" for _ in headers) + " |"]
    for r in rows:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return "\n".join(out)


# ------------------------------------------------------------------ insights
# Every figure below is computed in SQL — none of it is ever produced by the LLM,
# so these insights cannot be hallucinated. Merchants we treat as recurring bills.
SUBSCRIPTION_MERCHANTS = {"Netflix", "Spotify", "Jio", "Airtel", "LIC Premium",
                          "Axis Bank Car Loan"}


def _pct(cur, prev):
    if prev <= 0:
        return "new" if cur > 0 else "—"
    d = (cur - prev) / prev * 100
    arrow = "▲" if d >= 0 else "▼"
    return f"{arrow}{abs(d):.0f}%"


def months_list(user_id, doc_name=None, period=None):
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    rows = [r[0] for r in con.execute(
        f"SELECT DISTINCT month FROM transactions WHERE {w} ORDER BY month", p).fetchall()]
    con.close()
    return rows


def subscription_costs(user_id, doc_name=None, period=None):
    """Known recurring bills/subscriptions, with months active and monthly average."""
    if not SUBSCRIPTION_MERCHANTS:
        return []
    w, p = _scope(user_id, doc_name, period)
    qmarks = ",".join("?" * len(SUBSCRIPTION_MERCHANTS))
    con = connect()
    rows = con.execute(
        f"""SELECT merchant, COUNT(DISTINCT month) m, SUM(debit) tot, COUNT(*) c
            FROM transactions WHERE {w} AND debit>0 AND merchant IN ({qmarks})
            GROUP BY merchant ORDER BY tot DESC""",
        p + sorted(SUBSCRIPTION_MERCHANTS)).fetchall()
    con.close()
    return rows  # (merchant, months_active, total, count)


def subscription_trends(user_id, doc_name=None, period=None):
    """Per-subscription cost trend: average ₹/month in the first half of the covered
    period vs the second half, with % change. Returns (merchant, avg_h1, avg_h2, pct)."""
    if not SUBSCRIPTION_MERCHANTS:
        return []
    months = months_list(user_id, doc_name, period)
    if len(months) < 2:
        return []
    half = len(months) // 2
    h1m, h2m = months[:half], months[half:]
    qmarks = ",".join("?" * len(SUBSCRIPTION_MERCHANTS))
    h1set = ",".join("?" * len(h1m))
    h2set = ",".join("?" * len(h2m))
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    rows = con.execute(
        f"""SELECT merchant,
                   SUM(CASE WHEN month IN ({h1set}) THEN debit ELSE 0 END) h1,
                   SUM(CASE WHEN month IN ({h2set}) THEN debit ELSE 0 END) h2
            FROM transactions
            WHERE {w} AND debit>0 AND merchant IN ({qmarks})
            GROUP BY merchant""",
        h1m + h2m + p + sorted(SUBSCRIPTION_MERCHANTS)).fetchall()
    con.close()
    n1, n2 = len(h1m) or 1, len(h2m) or 1
    out = []
    for m, h1, h2 in rows:
        a1, a2 = h1 / n1, h2 / n2
        chg = ((a2 - a1) / a1 * 100) if a1 > 0 else (100.0 if a2 > 0 else 0.0)
        out.append((m, a1, a2, chg))
    out.sort(key=lambda r: r[3], reverse=True)
    return out


def category_movers(user_id, doc_name=None, period=None):
    """Per-category change between the two most recent months."""
    months = months_list(user_id, doc_name, period)
    if len(months) < 2:
        return None
    prev_m, cur_m = months[-2], months[-1]
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    rows = con.execute(
        f"""SELECT category,
                   SUM(CASE WHEN month=? THEN debit ELSE 0 END) cur,
                   SUM(CASE WHEN month=? THEN debit ELSE 0 END) prev
            FROM transactions WHERE {w} AND debit>0 GROUP BY category""",
        [cur_m, prev_m] + p).fetchall()
    con.close()
    movers = [(c, cur, prev, cur - prev) for c, cur, prev in rows]
    movers.sort(key=lambda x: abs(x[3]), reverse=True)
    return prev_m, cur_m, movers


def advice_facts(user_id, doc_name=None, period=None):
    """A fully pre-computed, number-RICH fact sheet for grounded advisory answers.

    Every figure an advisory answer could possibly cite — totals, monthly averages,
    savings rate, the investable surplus, per-category shares + discretionary/fixed
    flags, income-source shares + single-source dependence, top-merchant concentration,
    recurring bills, first-half-vs-second-half trends and extreme months — is computed
    HERE in SQL. The LLM that turns this into prose therefore only ever PHRASES these
    numbers; it never derives one, so it cannot introduce a hallucinated figure.
    Returns a plain-text block (one fact per line).
    """
    o = overview(user_id, doc_name, period)
    if o["count"] == 0:
        return "The user has no transactions on record."
    months = months_list(user_id, doc_name, period)
    nmon = max(len(months), 1)
    inc, sp, net = o["credit"], o["debit"], o["net"]
    rate = (net / inc * 100) if inc > 0 else 0.0
    minc, msp, mnet = inc / nmon, sp / nmon, net / nmon
    tot = sp or 1
    cov = coverage(user_id, doc_name)
    span = f"{_mlabel(cov[0])} to {_mlabel(cov[1])}" if cov else "the statement period"

    L = [f"PERIOD: {nmon} months ({span})."]
    L.append(f"INCOME: total {inr(inc)}; average {inr(minc)} per month.")
    L.append(f"SPENDING: total {inr(sp)}; average {inr(msp)} per month.")
    L.append(f"NET SAVED: total {inr(net)}; average {inr(mnet)} per month; savings rate {rate:.1f}%.")
    L.append(f"INVESTABLE SURPLUS: the money left over each month after ALL spending averages "
             f"{inr(mnet)} — that surplus is the cash genuinely available to save or invest monthly.")
    L.append(f"SAVINGS-TARGET BENCHMARK: 20% of average monthly income is {inr(minc * 0.20)} "
             f"(a common minimum to aim for; this user already saves {rate:.1f}% of income).")

    bal = latest_balance(user_id, doc_name, period)
    if bal is not None and msp > 0:
        L.append(f"EMERGENCY RUNWAY: the closing balance of {inr(bal)} would cover about "
                 f"{bal / msp:.1f} months at the current average monthly spend.")

    cats = by_category(user_id, doc_name, period)
    if cats:
        def kind(c):
            return ("discretionary/flexible, easy to cut" if c in DISCRETIONARY
                    else "largely fixed/committed, hard to cut" if c in FIXED_CATS else "other")
        L.append("SPENDING BY CATEGORY (highest to lowest):")
        for c, a, n in cats:
            L.append(f"  - {c}: {inr(a)} = {a / tot * 100:.1f}% of spending, {grp(n)} txns, {kind(c)}.")
        disc = [(c, a) for c, a, _n in cats if c in DISCRETIONARY]
        if disc:
            L.append("MOST FLEXIBLE CATEGORIES TO CAP (discretionary, largest first): "
                     + ", ".join(f"{c} {inr(a)}" for c, a in disc) + ".")

    inc_src = [r for r in income_by_source(user_id, doc_name, period) if r[1] > 0]
    if inc_src and inc > 0:
        L.append("INCOME SOURCES (largest first):")
        for m, c, n in inc_src:
            L.append(f"  - {m}: {inr(c)} = {c / inc * 100:.1f}% of income, {grp(n)} txns.")
        top_src, top_amt = inc_src[0][0], inc_src[0][1]
        dep = top_amt / inc * 100
        verdict = ("very high — income is heavily concentrated in one source" if dep >= 70
                   else "high" if dep >= 50 else "moderate" if dep >= 30
                   else "low — income is well diversified")
        L.append(f"INCOME DEPENDENCE: {dep:.1f}% of all income comes from the single largest "
                 f"source ({top_src}); single-source dependence is {verdict}.")

    tm = top_merchants(user_id, 6, doc_name, period)
    if tm and sp > 0:
        top5 = sum(t for _m, t, _c in tm[:5])
        L.append("TOP MERCHANTS BY SPEND: " + ", ".join(f"{m} {inr(t)}" for m, t, _c in tm) + ".")
        L.append(f"MERCHANT CONCENTRATION: the top 5 merchants account for {inr(top5)} = "
                 f"{top5 / tot * 100:.1f}% of all spending.")

    rec = subscription_costs(user_id, doc_name, period)
    if rec:
        per_month = sum(t / mo for _m, mo, t, _c in rec if mo)
        L.append(f"RECURRING BILLS & SUBSCRIPTIONS: about {inr(per_month)} every month — "
                 + ", ".join(f"{m} {inr(t / mo)}/mo" for m, mo, t, _c in rec if mo) + ".")

    tx = top_expenses(user_id, 5, doc_name, period)
    if tx:
        parts = []
        for dt, mer, amt in tx:
            lbl = (f"{dt[8:10]} {MONTHS.get(dt[5:7], dt[5:7])} {dt[:4]}" if len(str(dt)) >= 10 else str(dt))
            parts.append(f"{inr(amt)} to {mer} on {lbl}")
        L.append("LARGEST SINGLE TRANSACTIONS (top 5 by amount — the individual debits with the "
                 "biggest impact): " + "; ".join(parts) + ".")

    upi = txn_count(user_id, "upi", doc_name, period)
    if o["count"]:
        L.append(f"DIGITAL FOOTPRINT: {grp(upi)} of {grp(o['count'])} transactions are UPI/digital "
                 f"({upi / o['count'] * 100:.0f}%); cash/ATM withdrawals are not separately "
                 f"categorised in this statement, so an exact cash-vs-digital split isn't available.")

    bm = by_month(user_id, doc_name, period)
    if len(bm) >= 2:
        half = len(bm) // 2
        n1, n2 = half or 1, (len(bm) - half) or 1
        sp1, sp2 = sum(r[1] for r in bm[:half]) / n1, sum(r[1] for r in bm[half:]) / n2
        ic1, ic2 = sum(r[2] for r in bm[:half]) / n1, sum(r[2] for r in bm[half:]) / n2
        spc = ((sp2 - sp1) / sp1 * 100) if sp1 else 0.0
        icc = ((ic2 - ic1) / ic1 * 100) if ic1 else 0.0
        L.append(f"SPENDING TREND: average monthly spend was {inr(sp1)} in the first half of the "
                 f"period vs {inr(sp2)} in the second half ({spc:+.1f}%).")
        L.append(f"INCOME TREND: average monthly income was {inr(ic1)} in the first half vs "
                 f"{inr(ic2)} in the second half ({icc:+.1f}%).")
        hi = max(bm, key=lambda r: r[1]); lo = min(bm, key=lambda r: r[1])
        hic = max(bm, key=lambda r: r[2]); busy = max(bm, key=lambda r: r[3])
        L.append(f"HIGHEST-SPEND MONTH: {_mlabel(hi[0])} ({inr(hi[1])}); LOWEST-SPEND MONTH: "
                 f"{_mlabel(lo[0])} ({inr(lo[1])}).")
        L.append(f"HIGHEST-INCOME MONTH: {_mlabel(hic[0])} ({inr(hic[2])}); BUSIEST MONTH: "
                 f"{_mlabel(busy[0])} ({grp(busy[3])} transactions).")
    L.append(f"PROJECTION (run-rate): at the current pace, annual spending is about {inr(msp * 12)} "
             f"and annual net savings about {inr(mnet * 12)}; next month's spend is likely near the "
             f"{inr(msp)} monthly average and next month's saving near {inr(mnet)}.")
    return "\n".join(L)


def build_insights(user_id, doc_name=None, period=None):
    """
    Returns (report_markdown, oneliner_grounding).
      report_markdown: deterministic, exact-figure insights (subscriptions, trend,
                       savings rate, concentration, projection). No LLM, no hallucination.
      oneliner_grounding: a NUMBER-FREE headline list for the LLM to turn into ONE sentence.
    """
    o = overview(user_id, doc_name, period)
    if o["count"] == 0:
        return "_No transactions to analyse._", "There is no data."
    months = months_list(user_id, doc_name, period)
    nmon = max(len(months), 1)

    parts = ["## Insights"]
    head = []  # number-free headlines for the LLM

    # 1) savings rate
    rate = (o["net"] / o["credit"] * 100) if o["credit"] > 0 else 0
    over = 0
    if months:
        w, p = _scope(user_id, doc_name, period)
        con = connect()
        mrows = con.execute(f"""SELECT month, SUM(debit), SUM(credit) FROM transactions
                                WHERE {w} GROUP BY month""", p).fetchall()
        con.close()
        over = sum(1 for _m, d, c in mrows if d > c)
    verdict = ("strong" if rate >= 30 else "healthy" if rate >= 15
               else "thin" if rate >= 0 else "negative")
    parts.append(
        f"**💰 Savings rate: {rate:.0f}%** ({verdict}) — you keep {inr(o['net'])} of "
        f"{inr(o['credit'])} income. " + (f"You overspent income in {over} of {nmon} months."
                                          if over else "You stayed within income every month."))
    head.append(f"savings rate is {verdict}")

    # 2) recurring subscriptions / committed bills
    rec = subscription_costs(user_id, doc_name, period)
    if rec:
        per_month = sum(t / mo for _m, mo, t, _c in rec if mo)
        body = [(m, grp(mo), inr(t), inr(t / mo)) for m, mo, t, _c in rec]
        parts.append("**🔁 Recurring bills & subscriptions** — about "
                     f"{inr(per_month)} every month:\n\n"
                     + _table(["Merchant", "Months", "Total", "Avg / month"], body))
        head.append(f"the largest recurring bill is {rec[0][0]}")

    # 3) month-over-month movers
    mv = category_movers(user_id, doc_name, period)
    if mv:
        prev_m, cur_m, movers = mv
        body = [(c, inr(prev), inr(cur), _pct(cur, prev))
                for c, cur, prev, _d in movers[:5]]
        parts.append(f"**📈 Change: {_mlabel(prev_m)} → {_mlabel(cur_m)}**\n\n"
                     + _table(["Category", _mlabel(prev_m), _mlabel(cur_m), "Change"], body))
        top_mv = movers[0]
        if abs(top_mv[3]) > 0:
            direction = "up" if top_mv[3] > 0 else "down"
            head.append(f"{top_mv[0]} spending went {direction} most recently")

    # 4) concentration
    tm = top_merchants(user_id, 5, doc_name)
    if tm and o["debit"] > 0:
        top5 = sum(t for _m, t, _c in tm)
        share = top5 / o["debit"] * 100
        names = ", ".join(m for m, _t, _c in tm)
        parts.append(f"**🎯 Concentration:** your top 5 merchants ({names}) account for "
                     f"{inr(top5)} — **{share:.0f}%** of all spending.")
        head.append("spending is concentrated in a few merchants" if share >= 50
                    else "spending is spread across many merchants")

    # 5) run-rate projection
    avg_m = o["debit"] / nmon
    parts.append(f"**🔮 Run-rate:** averaging {inr(avg_m)} spend/month → about "
                 f"{inr(avg_m * 12)} per year at this pace.")

    grounding = ("Headline findings about the user's finances (do NOT mention any numbers, "
                 "percentages or amounts — they are shown in a table): "
                 + "; ".join(head) + ".")
    return "\n\n".join(parts), grounding


# ============================================================ intelligence engines
# Health Score, Risk Engine, Behavioural Analytics, Transaction Impact, Category
# Trend and the Insight store. Every figure below is computed in SQL here, so the
# LLM that phrases any of it only ever repeats a number it never derived.

def _rating(score, bands):
    """First band whose floor the score meets. bands: [(floor, label), ...] high→low."""
    for lo, label in bands:
        if score >= lo:
            return label
    return bands[-1][1]


def _monthly_series(user_id, doc_name=None, period=None):
    """[(month, debit, credit)] in chronological order — the spine of stability/overspend."""
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    rows = con.execute(f"""SELECT month, COALESCE(SUM(debit),0), COALESCE(SUM(credit),0)
                           FROM transactions WHERE {w} GROUP BY month ORDER BY month""", p).fetchall()
    con.close()
    return rows


def _cv(xs):
    """Coefficient of variation (std/mean); 0 = perfectly steady. 1.0 if mean<=0."""
    xs = [x for x in xs]
    if not xs:
        return 1.0
    m = sum(xs) / len(xs)
    if m <= 0:
        return 1.0
    var = sum((x - m) ** 2 for x in xs) / len(xs)
    return (var ** 0.5) / m


def health_score(user_id, doc_name=None, period=None):
    """Composite financial-health score (0-100) from four 0-25 pillars: savings,
    spending discipline, income stability and diversification. Returns a dict
    (score/rating/components/supporting figures) or None when there is no data."""
    o = overview(user_id, doc_name, period)
    if o["count"] == 0:
        return None
    months = months_list(user_id, doc_name, period)
    nmon = max(len(months), 1)
    inc, sp, net = o["credit"], o["debit"], o["net"]
    rate = (net / inc * 100) if inc > 0 else (0.0 if net >= 0 else -100.0)

    mrows = _monthly_series(user_id, doc_name, period)
    incs = [c for _m, _d, c in mrows]
    over = sum(1 for _m, d, c in mrows if d > c)

    # 1) SAVINGS (0-25): savings rate, 30%+ tops out the pillar.
    sav = max(0.0, min(25.0, rate / 30.0 * 25.0))
    # 2) SPENDING DISCIPLINE (0-25): share of months kept within income.
    disc = 25.0 * (1 - over / nmon)
    # 3) STABILITY (0-25): income consistency; CV 0 -> 25, CV >= 0.5 -> 0.
    icv = _cv(incs)
    stab = max(0.0, min(25.0, 25.0 * (1 - min(icv / 0.5, 1.0))))
    # 4) DIVERSIFICATION (0-25): penalised by income- and merchant-concentration.
    src = [r for r in income_by_source(user_id, doc_name, period) if r[1] > 0]
    dep = (src[0][1] / inc * 100) if (src and inc > 0) else 100.0
    tm = top_merchants(user_id, 5, doc_name, period)
    mconc = (sum(t for _m, t, _c in tm) / sp * 100) if (tm and sp > 0) else 0.0
    div = max(0.0, min(25.0, 25.0
                       - max(0.0, (dep - 50) / 50 * 12.5)
                       - max(0.0, (mconc - 50) / 50 * 12.5)))

    comp = {"Savings": round(sav, 1), "Spending discipline": round(disc, 1),
            "Income stability": round(stab, 1), "Diversification": round(div, 1)}
    score = round(sav + disc + stab + div)
    rating = _rating(score, [(85, "Excellent"), (70, "Good"), (55, "Fair"),
                             (40, "Needs work"), (0, "Poor")])
    return {"score": score, "rating": rating, "components": comp,
            "savings_rate": rate, "overspent_months": over, "months": nmon,
            "income_dependence": dep, "merchant_concentration": mconc, "income_cv": icv}


def risk_assessment(user_id, doc_name=None, period=None):
    """Rule-based structural risk. risk_score (0-100) is the sum of triggered-flag
    severities; risk_level bands it. Differs from anomaly detection: this is about
    standing financial structure, not one-off odd transactions. Returns dict/None."""
    o = overview(user_id, doc_name, period)
    if o["count"] == 0:
        return None
    months = months_list(user_id, doc_name, period)
    nmon = max(len(months), 1)
    inc, sp, net = o["credit"], o["debit"], o["net"]
    rate = (net / inc * 100) if inc > 0 else 0.0
    msp = sp / nmon

    mrows = _monthly_series(user_id, doc_name, period)
    over = sum(1 for _m, d, c in mrows if d > c)

    flags = []
    # 1) thin / negative savings
    if rate < 0:
        flags.append(("Negative savings", 35,
                      f"You spent more than you earned over the period (savings rate {rate:.0f}%)."))
    elif rate < 10:
        flags.append(("Low savings rate", 22,
                      f"Savings rate is just {rate:.0f}% — under the 10% safety floor."))
    # 2) overspending months (only when not already overall-negative)
    if over and rate >= 0:
        sev = 15 if over <= max(1, nmon // 3) else 22
        flags.append(("Overspending months", sev,
                      f"Spending beat income in {over} of {nmon} months."))
    # 3) rising discretionary spend (food/shopping/entertainment), half over half
    if len(months) >= 2 and DISCRETIONARY:
        half = len(months) // 2
        h1, h2 = months[:half], months[half:]
        qm = ",".join("?" * len(DISCRETIONARY))
        s1 = ",".join("?" * len(h1)) or "''"
        s2 = ",".join("?" * len(h2)) or "''"
        w, p = _scope(user_id, doc_name, period)
        con = connect()
        d1, d2 = con.execute(
            f"""SELECT COALESCE(SUM(CASE WHEN month IN ({s1}) THEN debit END),0),
                       COALESCE(SUM(CASE WHEN month IN ({s2}) THEN debit END),0)
                FROM transactions WHERE {w} AND category IN ({qm})""",
            h1 + h2 + p + sorted(DISCRETIONARY)).fetchone()
        con.close()
        a1, a2 = d1 / (len(h1) or 1), d2 / (len(h2) or 1)
        if a1 > 0 and (a2 - a1) / a1 * 100 > 30:
            g = (a2 - a1) / a1 * 100
            flags.append(("Rising discretionary spend", 15,
                          f"Discretionary spend (food/shopping/entertainment) climbed {g:.0f}% — "
                          f"{inr(a1)} to {inr(a2)} per month."))
    # 4) single-income-source dependence
    src = [r for r in income_by_source(user_id, doc_name, period) if r[1] > 0]
    if src and inc > 0:
        dep = src[0][1] / inc * 100
        if dep >= 80:
            flags.append(("Single income source", 20,
                          f"{dep:.0f}% of income comes from one source ({_mname(src[0][0])})."))
        elif dep >= 60:
            flags.append(("Income concentration", 12,
                          f"{dep:.0f}% of income comes from one source ({_mname(src[0][0])})."))
    # 5) merchant concentration
    tm = top_merchants(user_id, 5, doc_name, period)
    if tm and sp > 0:
        mc = sum(t for _m, t, _c in tm) / sp * 100
        if mc >= 60:
            flags.append(("Spending concentration", 10,
                          f"Your top 5 merchants are {mc:.0f}% of all spending."))
    # 6) thin cash buffer
    bal = latest_balance(user_id, doc_name, period)
    if bal is not None and msp > 0 and bal / msp < 1:
        flags.append(("Thin cash buffer", 10,
                      f"Closing balance of {inr(bal)} covers under a month of spending."))

    score = min(100, sum(s for _r, s, _d in flags))
    level = _rating(score, [(66, "High"), (35, "Medium"), (15, "Low"), (0, "Minimal")])
    flags.sort(key=lambda f: f[1], reverse=True)
    return {"risk_score": score, "risk_level": level,
            "flags": [{"rule": r, "severity": s, "detail": d} for r, s, d in flags]}


def behavior_metrics(user_id, doc_name=None, period=None):
    """Behavioural diagnostics (how you spend, not how much): weekend-vs-weekday
    intensity, month-end vs month-start, impulse/small-spend frequency and the
    single-merchant dependency. Returns a dict, or None when there is no spend."""
    o = overview(user_id, doc_name, period)
    if o["count"] == 0 or o["debit"] <= 0:
        return None
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    we_sum, wd_sum, we_days, wd_days = con.execute(
        f"""SELECT
              COALESCE(SUM(CASE WHEN CAST(strftime('%w',txn_date) AS INT) IN (0,6) THEN debit END),0),
              COALESCE(SUM(CASE WHEN CAST(strftime('%w',txn_date) AS INT) NOT IN (0,6) THEN debit END),0),
              COUNT(DISTINCT CASE WHEN CAST(strftime('%w',txn_date) AS INT) IN (0,6) THEN txn_date END),
              COUNT(DISTINCT CASE WHEN CAST(strftime('%w',txn_date) AS INT) NOT IN (0,6) THEN txn_date END)
            FROM transactions WHERE {w} AND debit>0""", p).fetchone()
    eom, som = con.execute(
        f"""SELECT COALESCE(SUM(CASE WHEN day>=21 THEN debit END),0),
                   COALESCE(SUM(CASE WHEN day<=10 THEN debit END),0)
            FROM transactions WHERE {w} AND debit>0""", p).fetchone()
    thr = 500.0
    dcount, small = con.execute(
        f"""SELECT COUNT(*), COALESCE(SUM(CASE WHEN debit<? THEN 1 ELSE 0 END),0)
            FROM transactions WHERE {w} AND debit>0""", [thr] + p).fetchone()
    con.close()

    we_per = we_sum / we_days if we_days else 0.0
    wd_per = wd_sum / wd_days if wd_days else 0.0
    tm = top_merchants(user_id, 1, doc_name, period)
    return {
        "weekend_spend": we_sum, "weekday_spend": wd_sum,
        "weekend_per_day": we_per, "weekday_per_day": wd_per,
        "weekend_ratio": (we_per / wd_per) if wd_per else 0.0,
        "eom_spend": eom, "som_spend": som,
        "eom_ratio": (eom / som) if som else 0.0,
        "debit_count": dcount, "small_count": small, "small_threshold": thr,
        "impulse_share": (small / dcount * 100) if dcount else 0.0,
        "top_merchant": _mname(tm[0][0]) if tm else None,
        "top_merchant_share": (tm[0][1] / o["debit"] * 100) if (tm and o["debit"] > 0) else 0.0,
    }


def transaction_impact(user_id, n=5, doc_name=None, period=None):
    """Rank the individual transactions that move the financial picture most.
    impact = signed (credit +, debit -) size of the transaction relative to the
    single largest transaction on record, plus a small bump for committed
    obligations and income. Deduped to one (the heaviest) line per merchant so the
    list shows variety, not five identical salary credits. Returns top-n dicts."""
    o = overview(user_id, doc_name, period)
    if o["count"] == 0:
        return []
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    # Pull the biggest debits and biggest credits SEPARATELY, so large expenses are
    # never crowded out of the candidate pool by even-larger salary credits.
    deb_rows = con.execute(
        f"""SELECT txn_date, merchant, category, debit FROM transactions
            WHERE {w} AND debit>0 ORDER BY debit DESC LIMIT 80""", p).fetchall()
    cre_rows = con.execute(
        f"""SELECT txn_date, merchant, category, credit FROM transactions
            WHERE {w} AND credit>0 ORDER BY credit DESC LIMIT 80""", p).fetchall()
    con.close()
    max_deb = max((r[3] for r in deb_rows), default=1.0) or 1.0
    max_cre = max((r[3] for r in cre_rows), default=1.0) or 1.0
    heavy = {"Investment & Insurance", "Income"}
    best = {}  # merchant -> heaviest-impact transaction seen
    def consider(dt, mer, cat, amt, credit):
        base = amt / (max_cre if credit else max_deb) * 100
        bump = 8 if cat in heavy else 0
        impact = round((1 if credit else -1) * min(100.0, base + bump))
        rec = {"date": dt, "merchant": _mname(mer), "category": cat, "amount": amt,
               "direction": "credit" if credit else "debit", "impact": impact}
        if mer not in best or abs(impact) > abs(best[mer]["impact"]):
            best[mer] = rec
    for dt, mer, cat, amt in cre_rows:
        consider(dt, mer, cat, amt, True)
    for dt, mer, cat, amt in deb_rows:
        consider(dt, mer, cat, amt, False)
    out = sorted(best.values(), key=lambda r: abs(r["impact"]), reverse=True)
    return out[:n]


def category_trend(user_id, window=3, doc_name=None, period=None):
    """Longitudinal category trend: average monthly spend over the most recent
    `window` months vs the `window` months before, per category, % change,
    fastest-growing first. Returns dict or None (needs >= 2 months)."""
    months = months_list(user_id, doc_name, period)
    if len(months) < 2:
        return None
    window = max(1, min(window, len(months) // 2))
    recent = months[-window:]
    prior = months[-2 * window:-window]
    if not prior:
        return None
    rs = ",".join("?" * len(recent))
    ps = ",".join("?" * len(prior))
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    rows = con.execute(
        f"""SELECT category,
                   COALESCE(SUM(CASE WHEN month IN ({rs}) THEN debit END),0),
                   COALESCE(SUM(CASE WHEN month IN ({ps}) THEN debit END),0)
            FROM transactions WHERE {w} AND debit>0 GROUP BY category""",
        recent + prior + p).fetchall()
    con.close()
    nr, npr = len(recent), len(prior)
    movers = []
    for cat, r, pr in rows:
        ar, ap = r / nr, pr / npr
        if ar == 0 and ap == 0:
            continue
        chg = ((ar - ap) / ap * 100) if ap > 0 else (100.0 if ar > 0 else 0.0)
        movers.append({"category": cat, "recent_avg": ar, "prior_avg": ap, "change": chg})
    movers.sort(key=lambda d: d["change"], reverse=True)
    return {"window": window, "recent": recent, "prior": prior, "movers": movers}


# ------------------------------------------------------------------ insight store
def save_insights(user_id, items, doc_name=None):
    """Replace this user/doc's stored insights with a freshly computed set."""
    con = connect()
    con.execute("DELETE FROM insights WHERE user_id=? AND COALESCE(doc_name,'')=COALESCE(?,'')",
                (user_id, doc_name or ""))
    con.executemany(
        "INSERT INTO insights(user_id,doc_name,type,title,explanation,score,evidence) "
        "VALUES(?,?,?,?,?,?,?)",
        [(user_id, doc_name, it["type"], it["title"], it.get("explanation", ""),
          it.get("score"), it.get("evidence", "")) for it in items])
    con.commit()
    con.close()
    return len(items)


def get_insights(user_id, doc_name=None, type=None):
    """Read back stored insights (highest score first). Empty list if none."""
    w = "user_id=?"
    p = [user_id]
    if doc_name:
        w += " AND doc_name=?"; p.append(doc_name)
    if type:
        w += " AND type=?"; p.append(type)
    con = connect()
    rows = con.execute(f"""SELECT type,title,explanation,score,evidence FROM insights
                           WHERE {w} ORDER BY score DESC""", p).fetchall()
    con.close()
    return [{"type": t, "title": ti, "explanation": e, "score": s, "evidence": ev}
            for t, ti, e, s, ev in rows]


def compute_insights(user_id, doc_name=None, period=None):
    """The Insight Engine: run the deterministic engines once and emit a list of
    insight rows (type/title/explanation/score/evidence) ready to persist. Pure SQL
    — no LLM, no sklearn (auto-recurring is surfaced separately at the ML layer)."""
    items = []
    h = health_score(user_id, doc_name, period)
    if h:
        c = h["components"]
        items.append({
            "type": "health",
            "title": f"Financial health: {h['rating']} ({h['score']}/100)",
            "explanation": (f"Savings {c['Savings']}/25, spending discipline "
                            f"{c['Spending discipline']}/25, income stability "
                            f"{c['Income stability']}/25, diversification {c['Diversification']}/25."),
            "score": h["score"], "evidence": json.dumps(h)})
    r = risk_assessment(user_id, doc_name, period)
    if r:
        items.append({
            "type": "risk",
            "title": f"Risk level: {r['risk_level']} ({r['risk_score']}/100)",
            "explanation": ("; ".join(f["detail"] for f in r["flags"])
                            or "No significant structural risks detected."),
            "score": r["risk_score"], "evidence": json.dumps(r)})
    ct = category_trend(user_id, 3, doc_name, period)
    if ct and ct["movers"]:
        top = ct["movers"][0]
        if top["change"] > 15:
            items.append({
                "type": "pattern",
                "title": f"{top['category']} spending is rising",
                "explanation": (f"{top['category']} averaged {inr(top['recent_avg'])}/month recently "
                                f"vs {inr(top['prior_avg'])} before (+{top['change']:.0f}%)."),
                "score": round(min(100, abs(top["change"]))), "evidence": json.dumps(top)})
    b = behavior_metrics(user_id, doc_name, period)
    if b and b["weekend_ratio"] >= 1.3:
        items.append({
            "type": "behavior",
            "title": "Weekend spending spikes",
            "explanation": (f"You spend about {b['weekend_ratio']:.1f}x as much per weekend day "
                            f"({inr(b['weekend_per_day'])}) as per weekday ({inr(b['weekday_per_day'])})."),
            "score": round(min(100, b["weekend_ratio"] * 30)), "evidence": json.dumps(b)})
    if b and b["impulse_share"] >= 50:
        items.append({
            "type": "behavior",
            "title": "Lots of small, frequent spends",
            "explanation": (f"{grp(b['small_count'])} of {grp(b['debit_count'])} debits "
                            f"({b['impulse_share']:.0f}%) are under {inr(b['small_threshold'])}."),
            "score": round(b["impulse_share"]), "evidence": json.dumps(b)})
    for it in transaction_impact(user_id, 3, doc_name, period):
        if it["direction"] == "debit" and abs(it["impact"]) >= 50:
            items.append({
                "type": "impact",
                "title": f"High-impact expense: {it['merchant']}",
                "explanation": f"{inr(it['amount'])} to {it['merchant']} was a large single hit on your balance.",
                "score": abs(it["impact"]), "evidence": json.dumps(it)})
    return items


# ------------------------------------------------------------------ router
MONTHS = {"01": "Jan", "02": "Feb", "03": "Mar", "04": "Apr", "05": "May", "06": "Jun",
          "07": "Jul", "08": "Aug", "09": "Sep", "10": "Oct", "11": "Nov", "12": "Dec"}


def _mlabel(ym):
    return f"{MONTHS.get(ym[5:7], ym[5:7])} {ym[:4]}"


def _plabel(p):
    """Human label for 'YYYY' / 'YYYY-MM' / 'YYYY-MM-DD' / 'MD-MM-DD' (cross-year day)."""
    if p.startswith("MD-"):
        return f"{int(p[6:8])} {MONTHS.get(p[3:5], p[3:5])} (all years)"
    return _dlabel(p) if len(p) == 10 else _mlabel(p) if len(p) == 7 else p


def _norm_period(start, end):
    """Turn LLM-parsed start/end ('YYYY' | 'YYYY-MM' | 'YYYY-MM-DD' | '') into a
    _scope period (string prefix or (start,end) range) plus a human label."""
    start = (start or "").strip()
    end = (end or "").strip()
    if start and end:
        # pad to full dates for a txn_date BETWEEN range
        s = start if len(start) == 10 else (start + "-01" if len(start) == 7 else start + "-01-01")
        e = end if len(end) == 10 else (end + "-31" if len(end) == 7 else end + "-12-31")
        return (s, e), f"{_plabel(start)} – {_plabel(end)}"
    if start:
        return start, _plabel(start)
    return None, None


def _mname(m):
    """Display a merchant name: keep canonical casing (LIC Premium, DMart) if it
    already has any uppercase; title-case only raw lowercase user text."""
    return m if any(c.isupper() for c in m) else m.title()


def dispatch_intent(intent, user_id, doc_name=None):
    """
    Answer a STRUCTURED intent (parsed by the LLM router) deterministically from SQL.
    The LLM never produced a number — it only classified. Returns markdown, or None
    if this intent isn't a factual one (caller handles advice/smalltalk).
    """
    t = (intent.get("type") or "").lower()
    period, plabel = _norm_period(intent.get("start"), intent.get("end"))
    sfx = f" in {plabel}" if plabel else ""

    # period named but empty -> don't fabricate all-time totals
    if period and overview(user_id, doc_name, period)["count"] == 0:
        cov = coverage(user_id, doc_name)
        span = f" Your data covers {_mlabel(cov[0])}–{_mlabel(cov[1])}." if cov else ""
        return f"**No transactions found for {plabel}.**{span}"

    # "...in table format" on a time-aggregate -> per-month breakdown table
    # (only for the whole-account totals, not a merchant/category-scoped count)
    if (intent.get("table") and t in ("count", "spend", "income")
            and not intent.get("merchant") and not intent.get("category")):
        rows = by_month(user_id, doc_name, period)
        if len(rows) > 1:
            body = [(_mlabel(m), inr(d), inr(c), grp(n)) for m, d, c, n in rows]
            return (f"**Month-wise breakdown{sfx}**\n\n"
                    + _table(["Month", "Spending", "Income", "Txns"], body))

    if t == "coverage":
        cov = coverage(user_id, doc_name)
        return (f"**Data available:** {_mlabel(cov[0])} → {_mlabel(cov[1])} "
                f"(years: {', '.join(cov[2])})") if cov else None

    if t == "count":
        m = (intent.get("merchant") or "").strip()
        cat = (intent.get("category") or "").strip()
        if m:                                          # "how many transactions at Amazon"
            r = merchant_spend(user_id, m, doc_name, period)
            if r["count"] == 0:
                return f"**No transactions found for '{m}'{sfx}.**"
            return f"**Transactions at {_mname(m)}{sfx}:** {grp(r['count'])}"
        if cat:                                        # "how many groceries transactions"
            for c, total, cnt in by_category(user_id, doc_name, period):
                if c == cat:
                    return f"**{c} transactions{sfx}:** {grp(cnt)}"
            return f"**{cat} transactions{sfx}:** 0"
        ck = (intent.get("count_kind") or "").strip()
        if ck in ("debit", "credit", "upi"):           # "how many debit/credit/UPI transactions"
            label = {"debit": "Debit transactions", "credit": "Credit transactions",
                     "upi": "UPI transactions"}[ck]
            return f"**{label}{sfx}:** {grp(txn_count(user_id, ck, doc_name, period))}"
        o = overview(user_id, doc_name, period)
        return f"**Transactions{sfx}:** {grp(o['count'])}"

    if t == "spend":
        o = overview(user_id, doc_name, period)
        return f"**Total spending{sfx}:** {inr(o['debit'])} across {grp(o['count'])} transactions"

    if t == "income":
        o = overview(user_id, doc_name, period)
        return f"**Total income{sfx}:** {inr(o['credit'])}"

    if t == "summary":
        o = overview(user_id, doc_name, period)
        b = latest_balance(user_id, doc_name, period)
        body = [("Transactions", grp(o["count"])), ("Total spending", inr(o["debit"])),
                ("Total income", inr(o["credit"])), ("Net", inr(o["net"])),
                ("Closing balance", inr(b) if b is not None else "-")]
        return f"**Account summary{sfx}**\n\n" + _table(["Metric", "Value"], body)

    if t == "balance":
        b = latest_balance(user_id, doc_name, period)
        if b is not None:
            return f"**{'Closing' if plabel else 'Current'} balance{sfx}:** {inr(b)}"

    if t == "breakdown":
        rows = by_month(user_id, doc_name, period)
        if rows:
            body = [(_mlabel(m), inr(d), inr(c), grp(n)) for m, d, c, n in rows]
            return (f"**Month-wise breakdown{sfx}**\n\n"
                    + _table(["Month", "Spending", "Income", "Txns"], body))

    if t == "category":
        cat = intent.get("category") or ""
        rows = by_category(user_id, doc_name, period)
        for c, total, cnt in rows:
            if cat and c == cat:
                return f"**{c}{sfx}:** {inr(total)} across {grp(cnt)} transactions"
        body = [(c, inr(t2), grp(n)) for c, t2, n in rows]
        return f"**Spending by category{sfx}**\n\n" + _table(["Category", "Spent", "Txns"], body)

    if t == "merchant":
        m = (intent.get("merchant") or "").strip()
        if m:
            r = merchant_spend(user_id, m, doc_name, period)
            if r["count"] == 0:
                return f"**No transactions found for '{m}'{sfx}.**"
            side = "received" if r["credit"] > r["debit"] else "spent"
            amt = r["credit"] if side == "received" else r["debit"]
            return f"**{_mname(m)}{sfx}:** {side} {inr(amt)} across {grp(r['count'])} transactions"

    if t == "top_expenses":
        n = intent.get("n") or 5
        rows = top_expenses(user_id, n, doc_name, period)
        body = [(i + 1, _dlabel(d), mc, inr(v)) for i, (d, mc, v) in enumerate(rows)]
        return f"**Top {n} expenses{sfx}**\n\n" + _table(["#", "Date", "Merchant", "Amount"], body)

    if t in ("largest_expense", "smallest_expense", "largest_income"):
        m = (intent.get("merchant") or "").strip()
        r = extreme(user_id, t, doc_name, period, merchant=m or None)
        if r:
            label = {"largest_expense": "Largest expense", "smallest_expense": "Smallest expense",
                     "largest_income": "Largest credit"}[t]
            at = f" at {_mname(m)}" if m else ""
            return f"**{label}{at}{sfx}:** {inr(r[2])} - {r[1]} on {_dlabel(r[0])}"
        if m:
            return f"**No transactions found for '{m}'{sfx}.**"

    if t == "subscriptions":
        rec = subscription_costs(user_id, doc_name, period)
        if rec:
            body = [(m, grp(mo), inr(tot), inr(tot / mo)) for m, mo, tot, _c in rec]
            return ("**Recurring bills & subscriptions**\n\n"
                    + _table(["Merchant", "Months", "Total", "Avg / month"], body))

    return None  # not a factual intent -> caller handles advice/smalltalk


MONTH_NAMES = {
    "january": "01", "jan": "01", "february": "02", "feb": "02", "march": "03", "mar": "03",
    "april": "04", "apr": "04", "may": "05", "june": "06", "jun": "06", "july": "07", "jul": "07",
    "august": "08", "aug": "08", "september": "09", "sept": "09", "sep": "09", "october": "10",
    "oct": "10", "november": "11", "nov": "11", "december": "12", "dec": "12",
}


def _period(q):
    """Parse a time filter from the question.
    Returns (period_prefix | None, label | None, requested_bool).
      "2024"      -> ("2024", "2024", True)
      "march 2024"-> ("2024-03", "Mar 2024", True)
    """
    ym = re.search(r"\b(20\d{2})\b", q)
    year = ym.group(1) if ym else None
    mon = None
    for name, num in MONTH_NAMES.items():
        if re.search(r"\b" + name + r"\b", q):
            mon = num
            break
    if year and mon:
        return f"{year}-{mon}", f"{MONTHS[mon]} {year}", True
    if year:
        return year, year, True
    return None, None, False


def _suffix(label):
    return f" in {label}" if label else ""


def answer(question, user_id, doc_name=None):
    """
    Try to answer deterministically from SQL. Returns a Markdown string, or None
    if this isn't an aggregate/factual transaction question (caller -> RAG).
    """
    q = question.lower().strip()
    init_db()

    # nothing ingested for this user? let RAG handle it
    if overview(user_id, doc_name)["count"] == 0:
        return None

    period, plabel, has_period = _period(q)

    # ---- data coverage (which months/years exist) ----
    if re.search(r"which (months?|years?)|what (months?|years?)|(months?|years?|data).*"
                 r"(available|do you have|present)|date range|coverage|what.*period", q):
        cov = coverage(user_id, doc_name)
        if cov:
            mn, mx, years = cov
            return (f"**Data available:** {_mlabel(mn)} → {_mlabel(mx)} "
                    f"(years: {', '.join(years)})")

    # ---- guard: an explicit period with NO data must not return all-time totals ----
    if has_period and overview(user_id, doc_name, period)["count"] == 0:
        cov = coverage(user_id, doc_name)
        span = f" Your data covers {_mlabel(cov[0])}–{_mlabel(cov[1])}." if cov else ""
        return f"**No transactions found for {plabel}.**{span}"

    # ---- month-wise breakdown ----
    if re.search(r"month[- ]?wise|each month|per month|monthly|month by month|by month", q):
        rows = by_month(user_id, doc_name, period)
        body = [(_mlabel(m), inr(d), inr(c), grp(n)) for m, d, c, n in rows]
        head = f"**Month-wise breakdown{_suffix(plabel)}**"
        return head + "\n\n" + _table(["Month", "Spending", "Income", "Txns"], body)

    # ---- current balance ----
    if re.search(r"\bbalance\b|in my account|sitting in", q):
        b = latest_balance(user_id, doc_name, period)
        if b is not None:
            lbl = "Closing balance" if has_period else "Current balance"
            return f"**{lbl}{_suffix(plabel)}:** {inr(b)}"

    # ---- counts ----
    if re.search(r"how many (transactions|txns|entries)|number of transactions", q):
        o = overview(user_id, doc_name, period)
        return f"**Transactions{_suffix(plabel)}:** {grp(o['count'])}"

    # ---- top N expenses ----
    mtop = re.search(r"top\s+(\d+)|biggest\s+(\d+)|largest\s+(\d+)", q)
    if mtop and re.search(r"expense|spend|purchase|debit|transaction", q):
        n = int(next(g for g in mtop.groups() if g))
        rows = top_expenses(user_id, n, doc_name, period)
        body = [(i + 1, _dlabel(d), m, inr(v)) for i, (d, m, v) in enumerate(rows)]
        return f"**Top {n} expenses{_suffix(plabel)}**\n\n" + _table(["#", "Date", "Merchant", "Amount"], body)

    # ---- single extremes ----
    if re.search(r"biggest|largest|highest|max", q) and re.search(r"expense|spend|purchase|debit", q):
        r = extreme(user_id, "largest_expense", doc_name, period)
        if r:
            return f"**Largest expense{_suffix(plabel)}:** {inr(r[2])} - {r[1]} on {_dlabel(r[0])}"
    if re.search(r"smallest|lowest|min", q) and re.search(r"expense|spend|purchase|debit", q):
        r = extreme(user_id, "smallest_expense", doc_name, period)
        if r:
            return f"**Smallest expense{_suffix(plabel)}:** {inr(r[2])} - {r[1]} on {_dlabel(r[0])}"
    if re.search(r"biggest|largest|highest|max", q) and re.search(r"credit|income|deposit|received", q):
        r = extreme(user_id, "largest_income", doc_name, period)
        if r:
            return f"**Largest credit{_suffix(plabel)}:** {inr(r[2])} - {r[1]} on {_dlabel(r[0])}"

    # ---- category spend ----
    for cat in ("groceries", "transport", "food", "dining", "shopping", "utilities",
                "entertainment", "healthcare", "investment", "insurance"):
        if cat in q and re.search(r"spend|spent|spending|cost|paid|expense", q):
            rows = by_category(user_id, doc_name, period)
            target = "Food & Dining" if cat in ("food", "dining") else \
                     "Investment & Insurance" if cat in ("investment", "insurance") else cat.capitalize()
            for c, total, cnt in rows:
                if c.lower().startswith(cat) or c == target:
                    return f"**{c}{_suffix(plabel)}:** {inr(total)} across {grp(cnt)} transactions"

    # ---- merchant / person spend ----
    for token, (name, _cat) in MERCHANT_MAP.items():
        tok = token.replace("_", " ")
        if tok in q:
            r = merchant_spend(user_id, token.split("_")[0] if "_" not in tok else tok, doc_name, period)
            if r["count"] == 0:
                continue
            if r["credit"] > r["debit"]:
                return f"**{name}{_suffix(plabel)}:** received {inr(r['credit'])} across {grp(r['count'])} transactions"
            return f"**{name}{_suffix(plabel)}:** spent {inr(r['debit'])} across {grp(r['count'])} transactions"

    # ---- category overview (full table) ----
    if re.search(r"categor|breakdown by|where.*money|spending breakdown", q):
        rows = by_category(user_id, doc_name, period)
        body = [(c, inr(t), grp(n)) for c, t, n in rows]
        return f"**Spending by category{_suffix(plabel)}**\n\n" + _table(["Category", "Spent", "Txns"], body)

    # ---- totals / income / overview ----
    if re.search(r"total spend|total spent|total spending|how much.*(spend|spent)|overall spend", q):
        o = overview(user_id, doc_name, period)
        return f"**Total spending{_suffix(plabel)}:** {inr(o['debit'])} across {grp(o['count'])} transactions"
    if re.search(r"total income|total credit|how much.*(income|earn|credit|receiv)", q):
        o = overview(user_id, doc_name, period)
        return f"**Total income{_suffix(plabel)}:** {inr(o['credit'])}"
    if re.search(r"summary|overview|net position|net (gain|loss)|snapshot", q):
        o = overview(user_id, doc_name, period)
        b = latest_balance(user_id, doc_name, period)
        body = [("Transactions", grp(o["count"])), ("Total spending", inr(o["debit"])),
                ("Total income", inr(o["credit"])), ("Net", inr(o["net"])),
                ("Closing balance", inr(b) if b is not None else "-")]
        return f"**Account summary{_suffix(plabel)}**\n\n" + _table(["Metric", "Value"], body)

    # if they named a period but we didn't match a known metric, answer the
    # natural default (spend for that period) rather than dropping to advice.
    if has_period:
        o = overview(user_id, doc_name, period)
        return (f"**{plabel} summary** — spending {inr(o['debit'])}, income {inr(o['credit'])}, "
                f"net {inr(o['net'])} over {grp(o['count'])} transactions")

    # not an aggregate question -> let RAG answer
    return None


def _dlabel(yyyy_mm_dd):
    return f"{yyyy_mm_dd[8:10]} {MONTHS.get(yyyy_mm_dd[5:7], '')} {yyyy_mm_dd[:4]}"
