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
from datetime import datetime

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
# Active display currency — set from the loaded statement (₹ for Indian statements,
# £ for Barclays, etc.). Symbol + digit grouping both follow it.
CURRENCY = "INR"
_CUR_SYM = {
    "INR": "₹", "GBP": "£", "USD": "$", "EUR": "€",
    "OMR": "OMR ", "KWD": "KWD ", "BHD": "BHD ", "JOD": "JOD ", "IQD": "IQD ",
    "": ""
}


def set_currency(cur):
    global CURRENCY
    CURRENCY = (cur or "").upper()


def _group_indian(intpart):
    if len(intpart) <= 3:
        return intpart
    head, tail = intpart[:-3], intpart[-3:]
    groups = []
    while len(head) > 2:
        groups.insert(0, head[-2:]); head = head[:-2]
    if head:
        groups.insert(0, head)
    return ",".join(groups) + "," + tail


def _grouped(intpart):
    """Digit grouping for the active currency: ₹ -> Indian (lakh/crore), else western."""
    return _group_indian(intpart) if CURRENCY == "INR" else f"{int(intpart):,}"


def inr(n):
    """Money formatter for the ACTIVE currency (symbol + locale grouping, 2 or 3 decimals dynamically)."""
    neg = n < 0
    dec_places = 3 if CURRENCY in ("OMR", "KWD", "BHD", "JOD", "IQD") else 2
    n = abs(round(float(n), dec_places))
    fmt_str = f"{{:.{dec_places}f}}"
    intpart, dec = fmt_str.format(n).split(".")
    # Avoid extra spaces for empty currency codes
    prefix = _CUR_SYM.get(CURRENCY, CURRENCY + " " if CURRENCY else "")
    return ("-" if neg else "") + prefix + f"{_grouped(intpart)}.{dec}"



def grp(n):
    """Locale comma grouping for plain integers (counts)."""
    return _grouped(str(int(n)))


def _money(s):
    if not s or not s.strip():
        return 0.0
    s_cleaned = re.sub(r"(?i)(cr|dr)\.?$", "", s.strip())
    s_cleaned = re.sub(r"[^\d.-]", "", s_cleaned)
    try:
        return float(s_cleaned)
    except ValueError:
        return 0.0


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
    rows = sum(1 for line in sample.splitlines() if ROW_RE.match(line))
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
                "balance": _money(balance), "currency": "INR", "seq": seq,
            }
    doc.close()


# ---------------------------------------------------------------- Barclays parser
_BARCLAYS_MON = {m: i + 1 for i, m in enumerate(
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"])}
_BARCLAYS_AMT = re.compile(r"^-?[\d,]+\.\d{2}$")
# UK merchant token -> category (light; falls back to Income for credits, else Other).
UK_MERCHANT_CAT = {
    "o2": "Utilities", "vodafone": "Utilities", "virgin media": "Utilities",
    "british gas": "Utilities", "thames water": "Utilities", "council tax": "Utilities",
    "octopus energy": "Utilities", "sky": "Utilities",
    "google": "Entertainment", "youtube": "Entertainment", "netflix": "Entertainment",
    "spotify": "Entertainment", "disney": "Entertainment", "cricket": "Entertainment",
    "puregym": "Entertainment", "gym": "Entertainment", "cinema": "Entertainment",
    "tesco": "Groceries", "sainsbury": "Groceries", "asda": "Groceries", "aldi": "Groceries",
    "lidl": "Groceries", "morrisons": "Groceries", "waitrose": "Groceries", "co-op": "Groceries",
    "amazon": "Shopping", "argos": "Shopping", "ebay": "Shopping", "ikea": "Shopping",
    "uber": "Transport", "tfl": "Transport", "trainline": "Transport", "national rail": "Transport",
    "deliveroo": "Food & Dining", "just eat": "Food & Dining", "mcdonald": "Food & Dining",
    "greggs": "Food & Dining", "costa": "Food & Dining", "starbucks": "Food & Dining", "pret": "Food & Dining",
}


def _barclays_merchant(descr, is_credit):
    """Pull the counterparty + a category from a Barclays narrative line."""
    m = re.search(r"(?:Card Payment to|Payment to|Direct Debit to|Standing Order to|Bill Payment to|"
                  r"Transfer to|Faster Payment to|Received From|Paid In(?: from)?|From|to)\s+(.+)",
                  descr, re.I)
    name = m.group(1) if m else descr
    name = re.split(r"\s+(?:On\s+\d|Ref:|Ref\b|on\s+\d)", name, 1)[0]
    name = re.sub(r"\s{2,}", " ", name).strip(" -:")
    low = name.lower()
    cat = next((c for kw, c in UK_MERCHANT_CAT.items() if kw in low), None)
    if cat is None:
        cat = "Income" if is_credit else "Other"
    return (name[:60] or ("Income" if is_credit else "Other")), cat


def is_barclays(text):
    low = (text or "").lower()
    return "barclays" in low and ("money out" in low or "sort code" in low
                                  or "current account statement" in low)


_BARCLAYS_MON_RE = r"(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*"


def _barclays_end_anchor(full, pdf_path):
    """(end_month, end_year) of the statement period — the anchor for year resolution when the
    primary 'DD Mon - DD Mon YYYY' header doesn't match (most often a CROSS-YEAR statement whose
    header carries two years, e.g. '5 Dec 2025 - 5 Jan 2026'). Tries, in order: the END side of a
    broader period range, the statement date in the FILENAME ('05-JAN-26'), then any 'Mon YYYY'
    in the text. Returns (0, 0) if nothing is found, so the caller still degrades to year 0000."""
    M = _BARCLAYS_MON_RE
    m = re.search(rf"(?:to|through|[-–—])\s*(?:\d{{1,2}}\s+)?{M}\.?\s+(\d{{4}})", full, re.I)
    if m:
        return _BARCLAYS_MON[m.group(1)[:3].title()], int(m.group(2))
    fm = re.search(r"(\d{1,2})-([A-Za-z]{3})-(\d{2})\b", os.path.basename(pdf_path or ""))
    if fm and fm.group(2).title() in _BARCLAYS_MON:
        return _BARCLAYS_MON[fm.group(2).title()], 2000 + int(fm.group(3))
    m = re.search(rf"\b(?:\d{{1,2}}\s+)?{M}\.?\s+(\d{{4}})", full, re.I)
    if m:
        return _BARCLAYS_MON[m.group(1)[:3].title()], int(m.group(2))
    return 0, 0


def parse_barclays(pdf_path):
    """Parse a Barclays current-account statement by COLUMN position (PyMuPDF word x/y).
    Dates are 'DD MMM' with the year inferred from the statement-period header; same-day
    rows inherit the date; multi-line descriptions are stitched; Start/End balance bound
    the table. Yields the standard row dict (currency='GBP')."""
    doc = pymupdf.open(pdf_path)
    full = "".join(p.get_text("text") for p in doc)
    pm = re.search(r"(\d{1,2})\s+([A-Z][a-z]{2})\s*[-–]\s*(\d{1,2})\s+([A-Z][a-z]{2})\s+(\d{4})", full)
    if pm:
        em, ey = _BARCLAYS_MON[pm.group(4)], int(pm.group(5))     # end month, end year
    else:
        # cross-year / two-year / filename-only statements — don't lose the year as 0000
        em, ey = _barclays_end_anchor(full, pdf_path)

    def year_for(mon):
        # a transaction whose month is AFTER the statement's END month belongs to the previous
        # year — a Dec row on a "5 Jan 2026" statement is Dec 2025. 0 only if no anchor at all.
        if not ey:
            return 0
        return ey if mon <= em else ey - 1

    cur_date = None; cur = None; started = False; done = False; pending = []
    for page in doc:
        lines = {}
        for x0, y0, x1, y1, w, *_ in page.get_text("words"):
            lines.setdefault(round(y0 / 3.0), []).append((x0, w))
        for k in sorted(lines):
            row = sorted(lines[k])
            dcol = [w for x, w in row if x < 90]
            desc = [w for x, w in row if 90 <= x < 268]
            ocol = [w for x, w in row if 268 <= x < 312]
            icol = [w for x, w in row if 312 <= x < 372]
            bcol = [w for x, w in row if x >= 372]
            day = next((w for w in dcol if re.fullmatch(r"\d{1,2}", w)), None)
            mon = next((w for w in dcol if w in _BARCLAYS_MON), None)
            if day and mon:
                cur_date = (int(day), _BARCLAYS_MON[mon])
            dtext = " ".join(desc).strip()
            out = next((_money(w) for w in ocol if _BARCLAYS_AMT.match(w)), None)
            inn = next((_money(w) for w in icol if _BARCLAYS_AMT.match(w)), None)
            bal = next((_money(w) for w in bcol if _BARCLAYS_AMT.match(w)), None)
            if re.search(r"start balance", dtext, re.I):
                started = True; continue
            if re.search(r"end balance", dtext, re.I):
                if cur: pending.append(cur); cur = None
                done = True; break
            if not started or done:
                continue
            if out is not None or inn is not None:
                if cur: pending.append(cur)
                cur = {"date": cur_date, "desc": dtext, "out": out, "in": inn, "bal": bal}
            elif dtext and cur:
                cur["desc"] = (cur["desc"] + " " + dtext).strip()
        if done:
            break
    if cur:
        pending.append(cur)
    doc.close()

    seq = 0
    for c in pending:
        if c["date"] is None:
            continue
        dd, mm = c["date"]; yr = year_for(mm)
        iso = f"{yr:04d}-{mm:02d}-{dd:02d}"
        out = c["out"] or 0.0; inn = c["in"] or 0.0
        merchant, category = _barclays_merchant(c["desc"], inn > 0)
        seq += 1
        yield {"txn_date": iso, "month": iso[:7], "year": yr, "month_no": mm, "day": dd,
               "descr": c["desc"][:200], "merchant": merchant, "category": category,
               "debit": out, "credit": inn, "balance": c["bal"], "currency": "GBP", "seq": seq}


def detect_currency(user_id, doc_name=None):
    """The dominant stored currency for this user/doc (defaults INR)."""
    w, p = _scope(user_id, doc_name)
    con = connect()
    try:
        r = con.execute(f"SELECT currency, COUNT(*) c FROM transactions WHERE {w} "
                        f"AND currency IS NOT NULL GROUP BY currency ORDER BY c DESC LIMIT 1", p).fetchone()
    except Exception:
        r = None
    con.close()
    return r[0] if r else "INR"


def is_pnb(text):
    low = (text or "").lower()
    return "pnb" in low and "particulars" in low and ("withdrawal" in low or "deposit" in low)


def is_wrenfield(text):
    low = (text or "").lower()
    return "wrenfield" in low and "outgoings" in low and "incomings" in low


_PNB_MON = {
    "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
    "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12
}


def parse_pnb(pdf_path):
    """Parse Punjab National Bank statements."""
    doc = pymupdf.open(pdf_path)
    seq = 0
    lines = []
    for page in doc:
        lines.extend(page.get_text("text").splitlines())
    doc.close()

    date_re = re.compile(r"^(\d{2})-([A-Za-z]{3})-(\d{4})$")
    bal_re = re.compile(r"^(-?[\d,]+\.\d{2})(CR|DR)\.?$", re.I)

    running_balance = 0.0
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        
        if "opening balance" in line.lower():
            if i + 1 < len(lines):
                nxt = lines[i+1].strip()
                bm = bal_re.match(nxt)
                if bm:
                    val_str, suffix = bm.groups()
                    running_balance = _money(val_str)
                    if suffix.upper() == "DR":
                        running_balance = -running_balance
        
        dm = date_re.match(line)
        if dm:
            date = line
            day_str, mon_name, yr_str = dm.groups()
            day = int(day_str)
            month_no = _PNB_MON.get(mon_name[:3].title(), 1)
            year = int(yr_str)
            iso = f"{year:04d}-{month_no:02d}-{day:02d}"

            desc_parts = []
            amount_str = None
            balance_str = None
            j = i + 1
            while j < len(lines):
                next_line = lines[j].strip()
                if date_re.match(next_line):
                    break
                bm = bal_re.match(next_line)
                if bm:
                    balance_str = next_line
                    if desc_parts:
                        amount_str = desc_parts.pop()
                    break
                else:
                    desc_parts.append(next_line)
                j += 1

            if amount_str and balance_str:
                desc = " ".join(desc_parts).strip()
                desc = re.sub(r"\s+", " ", desc)
                
                amt = _money(amount_str)
                bal_val_str, bal_suffix = bal_re.match(balance_str).groups()
                curr_bal = _money(bal_val_str)
                if bal_suffix.upper() == "DR":
                    curr_bal = -curr_bal

                diff = curr_bal - running_balance
                is_credit = False
                if abs(diff - amt) < 0.01:
                    is_credit = True
                elif abs(diff + amt) < 0.01:
                    is_credit = False
                else:
                    if "/CR/" in desc or "CR." in balance_str or "INTT." in desc:
                        is_credit = True
                    else:
                        is_credit = False

                debit = amt if not is_credit else 0.0
                credit = amt if is_credit else 0.0

                merchant, category = _classify(desc)
                seq += 1
                yield {
                    "txn_date": iso, "month": iso[:7],
                    "year": year, "month_no": month_no, "day": day,
                    "descr": desc, "merchant": merchant, "category": category,
                    "debit": debit, "credit": credit,
                    "balance": curr_bal, "currency": "INR", "seq": seq
                }
                running_balance = curr_bal
                i = j
            else:
                i += 1
        else:
            i += 1


def parse_wrenfield(pdf_path):
    """Parse Wrenfield Bank statements."""
    doc = pymupdf.open(pdf_path)
    seq = 0
    lines = []
    for page in doc:
        lines.extend(page.get_text("text").splitlines())
    doc.close()

    date_re = re.compile(r"^(\d{2})/(\d{2})/(\d{4})$")
    num_re = re.compile(r"^-?[\d,]+\.\d{2}$")

    i = 0
    while i < len(lines):
        line = lines[i].strip()
        dm = date_re.match(line)
        if dm:
            date = line
            day = int(dm.group(1))
            month_no = int(dm.group(2))
            year = int(dm.group(3))
            iso = f"{year:04d}-{month_no:02d}-{day:02d}"

            desc_parts = []
            amount_str = None
            balance_str = None
            j = i + 1
            while j < len(lines):
                next_line = lines[j].strip()
                if date_re.match(next_line):
                    break
                if num_re.match(next_line):
                    if j + 1 < len(lines) and num_re.match(lines[j+1].strip()):
                        amount_str = next_line
                        balance_str = lines[j+1].strip()
                        j += 2
                        break
                desc_parts.append(next_line)
                j += 1

            if amount_str and balance_str:
                desc = " ".join(desc_parts)
                desc = re.sub(r"Wrenfield Bank\s*?\s*Statement\s*?\s*Page \d+ of \d+", "", desc)
                desc = re.sub(r"Date\s+Description\s+\(GBP\)\s+Amount\s+\(GBP\)\s+Balance", "", desc)
                desc = re.sub(r"\s+", " ", desc).strip()

                amt = _money(amount_str)
                bal = _money(balance_str)

                if amount_str.startswith("-"):
                    debit = abs(amt)
                    credit = 0.0
                else:
                    debit = 0.0
                    credit = amt

                merchant, category = _barclays_merchant(desc, credit > 0)
                seq += 1
                yield {
                    "txn_date": iso, "month": iso[:7],
                    "year": year, "month_no": month_no, "day": day,
                    "descr": desc, "merchant": merchant, "category": category,
                    "debit": debit, "credit": credit,
                    "balance": bal, "currency": "GBP", "seq": seq
                }
                i = j
            else:
                i += 1
        else:
            i += 1


DATE_PATTERNS = [
    re.compile(r"^(\d{4})[-/.](\d{2})[-/.](\d{2})$"),
    re.compile(r"^(\d{2})[-/.](\d{2})[-/.](\d{4})$"),
    re.compile(r"^(\d{2})-([A-Za-z]{3,9})-(\d{4})$"),
    re.compile(r"^(\d{2})\s+([A-Za-z]{3,9})\s+(\d{4})$"),
    re.compile(r"^(\d{2})/(\d{2})/(\d{2})$"),
]


def parse_date(t):
    t_clean = t.strip()
    for pat in DATE_PATTERNS:
        m = pat.match(t_clean)
        if m:
            g = m.groups()
            if len(g) == 3:
                if len(g[0]) == 4:
                    return int(g[0]), int(g[1]), int(g[2])
                if g[1].isalpha():
                    mon = _PNB_MON.get(g[1][:3].title(), 1)
                else:
                    mon = int(g[1])
                day = int(g[0])
                yr = int(g[2])
                if yr < 100:
                    yr += 2000
                return yr, mon, day
    return None


MONEY_PAT = re.compile(r"^-?[\d,]+\.\d{2}$")


def _parse_generic_columnar(pdf_path):
    """Generic fallback: extract transactions from visual layout coordinates, one date-bearing
    row = one transaction. Great for column layouts with a date on every row; blind to layouts
    that print the date once per day (see _parse_generic_dateinherited)."""
    doc = pymupdf.open(pdf_path)
    
    # Detect currency locally to avoid global NameError
    head = ""
    try:
        head = "".join(doc[i].get_text("text") for i in range(min(3, len(doc))))
    except Exception:
        pass
    
    local_cur = "INR"
    low_head = head.lower()
    if any(k in low_head for k in ("ifsc", "micr", "state bank", "hdfc", "icici", "₹", "rs.", "pnb")):
        local_cur = "INR"
    elif any(k in low_head for k in ("barclays", "sort code", "£", "iban gb", "wrenfield")):
        local_cur = "GBP"
    elif any(k in low_head for k in ("oman", "muscat", "omr")):
        local_cur = "OMR"
    elif any(k in low_head for k in ("chase", "routing", "$")):
        local_cur = "USD"
    else:
        local_cur = ""
        
    raw_rows = []
    
    for page_idx, page in enumerate(doc):
        words = page.get_text("words")
        lines = {}
        for x0, y0, x1, y1, w, *_ in words:
            lines.setdefault(round(y0 / 2.0) * 2, []).append((x0, w))
            
        for y in sorted(lines):
            row_words = sorted(lines[y])
            tokens = [w for x, w in row_words]
            
            date_idx = -1
            date_val = None
            for idx, t in enumerate(tokens):
                d_parsed = parse_date(t)
                if d_parsed:
                    date_idx = idx
                    date_val = d_parsed
                    break
                    
            if date_idx != -1:
                money_tokens = []
                other_tokens = []
                for idx, t in enumerate(tokens):
                    if idx == date_idx:
                        continue
                    t_clean = re.sub(r"[₹£$€]", "", t).strip()
                    t_clean_num = re.sub(r"(cr|dr)\.?$", "", t_clean, flags=re.I).strip()
                    if MONEY_PAT.match(t_clean_num):
                        money_tokens.append((idx, t))
                    else:
                        other_tokens.append(t)
                
                desc = " ".join(other_tokens).strip()
                if not money_tokens or any(w in desc.lower() for w in ("statement period", "opening balance", "closing balance", "total balance")):
                    continue
                
                raw_rows.append({
                    "date_val": date_val,
                    "money_tokens": money_tokens,
                    "desc": desc
                })
    doc.close()
    
    if not raw_rows:
        return
        
    first_date = raw_rows[0]["date_val"]
    last_date = raw_rows[-1]["date_val"]
    if first_date > last_date:
        raw_rows.reverse()
        
    seq = 0
    running_balance = None
    
    for row in raw_rows:
        date_val = row["date_val"]
        money_tokens = row["money_tokens"]
        desc = row["desc"]
        
        amt = 0.0
        bal = 0.0
        is_credit = False
        
        if len(money_tokens) >= 2:
            amt_str = money_tokens[0][1]
            bal_str = money_tokens[-1][1]
            
            amt = abs(_money(amt_str))
            bal = _money(bal_str)
            if "dr" in bal_str.lower():
                bal = -bal
                
            if running_balance is not None:
                diff = bal - running_balance
                if diff > 0.01:
                    is_credit = True
                elif diff < -0.01:
                    is_credit = False
                else:
                    if amt_str.startswith("-"):
                        is_credit = False
                    elif "/cr/" in desc.lower() or "/cr " in desc.lower() or "cr/" in desc.lower():
                        is_credit = True
                    elif "/dr/" in desc.lower() or "/dr " in desc.lower() or "dr/" in desc.lower():
                        is_credit = False
                    elif "cr" in amt_str.lower() or "cr" in bal_str.lower():
                        is_credit = True
                    else:
                        is_credit = False
            else:
                if amt_str.startswith("-"):
                    is_credit = False
                elif "/cr/" in desc.lower() or "/cr " in desc.lower() or "cr/" in desc.lower():
                    is_credit = True
                elif "/dr/" in desc.lower() or "/dr " in desc.lower() or "dr/" in desc.lower():
                    is_credit = False
                elif "cr" in amt_str.lower() or "cr" in bal_str.lower() or "deposit" in desc.lower():
                    is_credit = True
                else:
                    is_credit = False
            running_balance = bal
        elif len(money_tokens) == 1:
            amt_str = money_tokens[0][1]
            val = _money(amt_str)
            # A lone money value that EQUALS the running balance is a balance-display /
            # carried-forward line (only the Balance column populated, no Withdrawal/Deposit) —
            # not a transaction. Skip it, otherwise it's mistaken for an amount and added twice.
            if running_balance is not None and abs(abs(val) - running_balance) < 0.005:
                continue
            amt = abs(val)
            is_credit = not amt_str.startswith("-")
            if running_balance is not None:
                bal = running_balance + (amt if is_credit else -amt)
                running_balance = bal
            else:
                bal = 0.0
                
        yr, mon, day = date_val
        iso = f"{yr:04d}-{mon:02d}-{day:02d}"
        seq += 1
        
        # Categorize
        if local_cur == "GBP":
            merchant, category = _barclays_merchant(desc, is_credit)
        else:
            merchant, category = _classify(desc)
            
        yield {
            "txn_date": iso, "month": iso[:7],
            "year": yr, "month_no": mon, "day": day,
            "descr": desc, "merchant": merchant, "category": category,
            "debit": amt if not is_credit else 0.0,
            "credit": amt if is_credit else 0.0,
            "balance": bal, "currency": local_cur or "INR", "seq": seq
        }


_GEN_MON3 = {m: i + 1 for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"])}
_GEN_MONEY_RE = re.compile(r"^-?[£$€₹]?[\d,]+\.\d{2}(?:\s?(?:cr|dr))?$", re.I)
_GEN_SUMMARY_RE = re.compile(
    r"start balance|end balance|opening balance|closing balance|total balance|money in|"
    r"money out|at a glance|statement period|brought forward|balance b/?f", re.I)


def _gen_money(s):
    return float(re.sub(r"[£$€₹,]|(?:\s?(?:cr|dr))", "", s, flags=re.I).strip())


def _gen_valid(mo, d):
    return 1 <= mo <= 12 and 1 <= d <= 31


def _gen_row_date(toks):
    """((year|None, month, day), {consumed indices}) — a full date token, or 'D Mon [YYYY]' /
    'Mon D [YYYY]' across tokens, validated so a sort code ('11-47-29') isn't read as a date."""
    for i, t in enumerate(toks):
        m = re.fullmatch(r"(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})", t) or re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})", t)
        if m:
            g = m.groups()
            if len(g[0]) == 4:
                y, mo, d = int(g[0]), int(g[1]), int(g[2])
            else:
                y = int(g[2]); y += 2000 if y < 100 else 0; mo, d = int(g[1]), int(g[0])
            if _gen_valid(mo, d):
                return (y, mo, d), {i}
    for i in range(len(toks) - 1):
        a, b = toks[i].strip(".,"), toks[i + 1].strip(".,")
        used = {i, i + 1}; yr = None
        if i + 2 < len(toks) and re.fullmatch(r"20\d\d", toks[i + 2]):
            yr = int(toks[i + 2]); used.add(i + 2)
        if re.fullmatch(r"\d{1,2}", a) and b[:3].lower() in _GEN_MON3 and _gen_valid(_GEN_MON3[b[:3].lower()], int(a)):
            return (yr, _GEN_MON3[b[:3].lower()], int(a)), used
        if a[:3].lower() in _GEN_MON3 and re.fullmatch(r"\d{1,2}", b) and _gen_valid(_GEN_MON3[a[:3].lower()], int(b)):
            return (yr, _GEN_MON3[a[:3].lower()], int(b)), used
    return None, set()


def _gen_rows(page):
    """Cluster a page's words into visual rows (tokens sorted left-to-right)."""
    ws = sorted((round(y0), round(x0), w) for x0, y0, x1, y1, w, *_ in page.get_text("words"))
    out = []
    for y, x, w in ws:
        if out and y - out[-1][0] <= 3:
            out[-1][1].append((x, w)); out[-1][0] = y
        else:
            out.append([y, [(x, w)]])
    return [[w for _x, w in sorted(toks)] for _y, toks in out]


def _parse_generic_dateinherited(pdf_path):
    """Generic fallback for layouts that print the DATE ONCE PER DAY (e.g. Castlemere): the
    date is carried across rows, multi-token/yearless dates are recognised with chronological
    year rollover, continuation lines ('SO', 'Ref: …') are stitched into the description, and
    debit/credit is read from the BALANCE DIRECTION. Yields the standard row dict."""
    doc = pymupdf.open(pdf_path)
    head = "".join(doc[i].get_text("text") for i in range(min(3, len(doc))))
    low = head.lower()
    cur = ("GBP" if any(k in low for k in ("barclays", "sort code", "£", "iban gb", "castlemere", "wrenfield"))
           else "OMR" if any(k in low for k in ("oman", "muscat", "omr"))
           else "USD" if "$" in low else "INR")
    years = [int(y) for y in re.findall(r"\b(20\d\d)\b", head)]
    base_year = min(years) if years else 2000

    txns, cur_date, cur_txn = [], None, None
    for page in doc:
        for toks in _gen_rows(page):
            money = [t for t in toks if _GEN_MONEY_RE.match(t)]
            dt, used = _gen_row_date(toks)
            text = " ".join(t for j, t in enumerate(toks) if j not in used and not _GEN_MONEY_RE.match(t)).strip()
            if dt:
                cur_date = dt
            if money and cur_date and not _GEN_SUMMARY_RE.search(text):
                if cur_txn:
                    txns.append(cur_txn)
                cur_txn = {"date": cur_date, "desc": text, "money": money}
            elif text and cur_txn and not dt and not _GEN_SUMMARY_RE.search(text):
                cur_txn["desc"] = (cur_txn["desc"] + " " + text).strip()
    if cur_txn:
        txns.append(cur_txn)
    doc.close()
    if not txns:
        return

    prev_m, yr = None, base_year                    # chronological year rollover for yearless dates
    for t in txns:
        y0, m, d = t["date"]
        if y0 is not None:
            yr = y0
        elif prev_m is not None and m < prev_m:
            yr += 1
        prev_m = m
        t["iso"] = (yr, m, d)
    if txns[0]["iso"] > txns[-1]["iso"]:
        txns.reverse()

    seq, running = 0, None
    for t in txns:
        mny = t["money"]
        amt = abs(_gen_money(mny[0])); bal = _gen_money(mny[-1])
        if running is not None:
            diff = bal - running
            is_credit = diff > 0.005 if abs(diff) > 0.005 else mny[0].lower().rstrip().endswith("cr")
        else:
            is_credit = ("cr" in mny[0].lower()) or ("deposit" in t["desc"].lower())
        running = bal
        yr, mm, dd = t["iso"]
        seq += 1
        desc = t["desc"][:80]
        merchant, category = (_barclays_merchant(desc, is_credit) if cur == "GBP" else _classify(desc))
        yield {"txn_date": f"{yr:04d}-{mm:02d}-{dd:02d}", "month": f"{yr:04d}-{mm:02d}",
               "year": yr, "month_no": mm, "day": dd, "descr": desc, "merchant": merchant,
               "category": category, "debit": 0.0 if is_credit else amt,
               "credit": amt if is_credit else 0.0, "balance": bal, "currency": cur, "seq": seq}


def _generic_breaks(rows):
    """Order-aware count of running-balance violations (min over both row orderings). Returns a
    large number when there are too few rows to verify, so a genuinely reconciling parse always
    wins the strategy comparison."""
    def chk(seq):
        prev, b = None, 0
        for r in seq:
            bal = r["balance"]
            if prev is not None and abs(bal - (prev + r["credit"] - r["debit"])) > 0.005:
                b += 1
            prev = bal
        return b
    if len(rows) < 2:
        return 10 ** 9
    return min(chk(rows), chk(rows[::-1]))


def parse_generic_statement(pdf_path):
    """Generic fallback parser. Runs the columnar strategy first; if it doesn't reconcile
    against the running balance, tries the date-inherited strategy and keeps whichever parse
    RECONCILES BEST (fewest balance violations). Because the balance column picks the correct
    parse, adding a strategy can never regress a statement the previous one already got right."""
    columnar = list(_parse_generic_columnar(pdf_path))
    if columnar and _generic_breaks(columnar) == 0:
        yield from columnar
        return
    inherited = list(_parse_generic_dateinherited(pdf_path))
    if inherited and (not columnar or _generic_breaks(inherited) < _generic_breaks(columnar)):
        yield from inherited
    else:
        yield from columnar


def is_statement_pdf(path):
    """True if the PDF at `path` looks like a parseable bank statement (any supported
    format: Barclays columnar, or the DR/CR row layout, or PNB, or Wrenfield, or generic fallback). Used to pick statements out of
    a ZIP and to reject non-statement PDFs."""
    try:
        d = pymupdf.open(path)
        head = "".join(d[i].get_text("text") for i in range(min(3, len(d))))
        d.close()
    except Exception:
        return False
    if is_barclays(head) or is_transaction_statement(head) or is_pnb(head) or is_wrenfield(head):
        return True
    try:
        txns = list(parse_generic_statement(path))
        return len(txns) >= 3
    except Exception:
        return False


def ingest_pdf(pdf_path, doc_name, user_id, batch=5000):
    """Parse a statement PDF into SQLite (auto-detecting Barclays vs the row format).
    Returns count of rows ingested and sets the active display currency to the data."""
    init_db()
    head = ""
    try:
        d = pymupdf.open(pdf_path)
        head = "".join(d[i].get_text("text") for i in range(min(3, len(d))))
        d.close()
    except Exception:
        pass

    # Detect currency code from header text metadata
    detected_cur = "INR"
    low_head = head.lower()
    if any(k in low_head for k in ("ifsc", "micr", "state bank", "hdfc", "icici", "₹", "rs.", "pnb")):
        detected_cur = "INR"
    elif any(k in low_head for k in ("barclays", "sort code", "£", "iban gb", "wrenfield")):
        detected_cur = "GBP"
    elif any(k in low_head for k in ("oman", "muscat", "omr")):
        detected_cur = "OMR"
    elif any(k in low_head for k in ("chase", "routing", "$")):
        detected_cur = "USD"
    else:
        detected_cur = "" # clean fallback: no symbol

    if is_barclays(head):
        parser = parse_barclays
    elif is_pnb(head):
        parser = parse_pnb
    elif is_wrenfield(head):
        parser = parse_wrenfield
    else:
        # Check if transaction statement format (HDFC) is matched, else fallback to generic parser
        parser = parse_pdf if is_transaction_statement(head) else parse_generic_statement

    con = connect()
    con.execute("DELETE FROM transactions WHERE user_id=? AND doc_name=?", (user_id, doc_name))
    
    txns = list(parser(pdf_path))
    if not txns:
        con.close()
        return 0

    # Detect reverse-chronological order and reverse the list if needed
    is_rev = False
    if len(txns) >= 2:
        first_date = txns[0]["txn_date"]
        last_date = txns[-1]["txn_date"]
        if first_date > last_date:
            is_rev = True
        elif first_date == last_date:
            bal_curr = txns[0]["balance"]
            bal_next = txns[1]["balance"]
            amt_curr = (txns[0]["credit"] or 0.0) - (txns[0]["debit"] or 0.0)
            if bal_curr is not None and bal_next is not None:
                if abs((bal_next + amt_curr) - bal_curr) < 0.01:
                    is_rev = True

    if is_rev:
        txns.reverse()

    # Re-assign seq numbers in strict chronological order
    for idx, t in enumerate(txns, 1):
        t["seq"] = idx

    buf, n = [], 0
    sql = ("INSERT INTO transactions"
           "(user_id,doc_name,txn_date,month,year,month_no,day,descr,merchant,category,"
           "debit,credit,balance,currency,seq)"
           " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
    for t in txns:
        cur = t.get("currency", "INR")
        # Override default INR if a different currency or RAW was detected in the header
        if cur == "INR" and detected_cur != "INR":
            cur = detected_cur

        buf.append((user_id, doc_name, t["txn_date"], t["month"], t["year"], t["month_no"], t["day"],
                    t["descr"], t["merchant"], t["category"], t["debit"], t["credit"], t["balance"],
                    cur, t["seq"]))
        if len(buf) >= batch:
            con.executemany(sql, buf); n += len(buf); buf = []
    if buf:
        con.executemany(sql, buf); n += len(buf)
    con.commit(); con.close()
    set_currency(detect_currency(user_id))      # display currency follows the loaded data
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
    elif CURRENCY:
        where += " AND currency=?"; params.append(CURRENCY)
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
    kw = keyword.lower()
    cols = """COALESCE(SUM(debit),0), COALESCE(SUM(credit),0), COUNT(*),
              SUM(CASE WHEN debit>0 THEN 1 ELSE 0 END)"""
    # Prefer an EXACT canonical-merchant match. Only if there is none do we broaden to a
    # description substring — otherwise "CHIP" would also swallow "Alfies Fish & Chips"
    # (…Chip s), inflating the total. The substring fallback still catches names that live
    # only in the description ("Axis_Bank_Car_Loan"), which the merchant column misses.
    r = con.execute(f"SELECT {cols} FROM transactions WHERE {w} AND LOWER(merchant)=?",
                    p + [kw]).fetchone()
    if not r or r[2] == 0:
        r = con.execute(f"SELECT {cols} FROM transactions WHERE {w} AND "
                        f"(LOWER(merchant) LIKE ? OR LOWER(descr) LIKE ?)",
                        p + [f"%{kw}%", f"%{kw}%"]).fetchone()
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
    """Count transactions, optionally restricted to debit / credit / UPI / card rows."""
    w, p = _scope(user_id, doc_name, period)
    cond = {"debit": " AND debit>0", "credit": " AND credit>0",
            "upi": " AND LOWER(descr) LIKE '%upi%'",
            "card": " AND (LOWER(descr) LIKE '%card%' OR LOWER(descr) LIKE '%visa%' OR LOWER(descr) LIKE '%contactless%' OR LOWER(descr) LIKE '%pos%')"}.get(kind, "")
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


def extreme(user_id, kind, doc_name=None, period=None, merchant=None, category=None):
    w, p = _scope(user_id, doc_name, period)
    col, order = ("debit", "DESC") if kind in ("largest_expense", "smallest_expense") else ("credit", "DESC")
    if kind == "smallest_expense":
        order = "ASC"
    mfilter, mp = "", []
    if merchant:
        mfilter += " AND (LOWER(merchant)=? OR LOWER(descr) LIKE ?)"
        mp += [merchant.lower(), f"%{merchant.lower()}%"]
    if category:                                   # "biggest Shopping expense" stays in-category
        mfilter += " AND category=?"
        mp += [category]
    con = connect()
    r = con.execute(f"""SELECT txn_date, merchant, {col} FROM transactions
                        WHERE {w} AND {col}>0{mfilter} ORDER BY {col} {order} LIMIT 1""",
                    p + mp).fetchone()
    con.close()
    return r


# ---- fine-grained lookups (merchant category / dates / balance extreme / interval) ----
# All deterministic, every figure from SQL. Merchant matching mirrors merchant_spend:
# the canonical `merchant` column (exact) OR a `descr LIKE` (handles multi-word/underscored
# and split labels like "Piyush Mishra" vs "Piyush Mishra & PA").

def _merch_where(keyword):
    """Punctuation-insensitive, variant-spanning match for the lookup helpers: the keyword
    is tokenised and joined with wildcards, so "piyush mishra" catches both 'Piyush Mishra'
    and 'Piyush Mishra & PA', and "higgsfield inc usa" catches 'Higgsfield Inc. USA'. (Kept
    separate from merchant_spend's exact match, which the factual/aggregate paths rely on.)"""
    toks = [t for t in re.split(r"[^a-z0-9]+", keyword.lower()) if t]
    pat = "%" + "%".join(toks) + "%" if toks else f"%{keyword.lower()}%"
    return "(LOWER(merchant) LIKE ? OR LOWER(descr) LIKE ?)", [pat, pat]


def merchant_category(user_id, keyword, doc_name=None, period=None):
    """Which category(ies) a merchant's transactions are classified under. [(category, n)]."""
    w, p = _scope(user_id, doc_name, period)
    mw, mp = _merch_where(keyword)
    con = connect()
    rows = con.execute(f"""SELECT category, COUNT(*) FROM transactions
                           WHERE {w} AND {mw} GROUP BY category ORDER BY 2 DESC""",
                       p + mp).fetchall()
    con.close()
    return rows


def merchant_dates(user_id, keyword, doc_name=None, period=None, limit=500):
    """The dates a merchant appears on (chronological). [(txn_date, debit, credit, balance)].
    Placeholder year-0000 rows (a known Barclays-parser gap) are excluded so the answer
    never shows a broken '0000' date."""
    w, p = _scope(user_id, doc_name, period)
    mw, mp = _merch_where(keyword)
    con = connect()
    rows = con.execute(f"""SELECT txn_date, debit, credit, balance FROM transactions
                           WHERE {w} AND {mw} AND txn_date NOT LIKE '0000%'
                           ORDER BY txn_date, seq LIMIT ?""",
                       p + mp + [limit]).fetchall()
    con.close()
    return rows


def list_transactions(user_id, merchant=None, category=None, doc_name=None, period=None, limit=25, txn_type=None):
    """Individual transaction ROWS for a 'show me the transactions' listing, scoped by any of
    merchant keyword / category / period, in chronological order. Returns (rows, total) where
    rows is [(txn_date, merchant, descr, debit, credit)] capped at `limit` and total is the
    full count for that scope (so the caller can say '+N more'). Placeholder year-0000 rows
    are excluded so a broken date never shows."""
    w, p = _scope(user_id, doc_name, period)
    clauses, params = [], []
    if merchant:
        mw, mp = _merch_where(merchant)
        clauses.append(mw); params += mp
    if category:
        clauses.append("category=?"); params.append(category)
    if txn_type == "debit":
        clauses.append("debit>0")
    elif txn_type == "credit":
        clauses.append("credit>0")
    extra = (" AND " + " AND ".join(clauses)) if clauses else ""
    base = f"FROM transactions WHERE {w}{extra} AND txn_date NOT LIKE '0000%'"
    con = connect()
    total = con.execute(f"SELECT COUNT(*) {base}", p + params).fetchone()[0]
    rows = con.execute(f"""SELECT txn_date, merchant, descr, debit, credit {base}
                           ORDER BY txn_date, seq LIMIT ?""", p + params + [limit]).fetchall()
    con.close()
    return rows, total


def balance_extreme(user_id, kind, doc_name=None, period=None):
    """Minimum or maximum RUNNING balance recorded (kind='min'|'max'). (txn_date, balance) | None.
    Distinct from latest_balance (the closing balance)."""
    w, p = _scope(user_id, doc_name, period)
    order = "ASC" if kind == "min" else "DESC"
    con = connect()
    r = con.execute(f"""SELECT txn_date, balance FROM transactions
                        WHERE {w} AND balance IS NOT NULL
                        ORDER BY balance {order}, seq LIMIT 1""", p).fetchone()
    con.close()
    return r


def payment_interval(user_id, keyword, doc_name=None, period=None):
    """Average number of days between a merchant/person's consecutive transactions.
    Placeholder year-0000 rows (a known Barclays-parser gap) are excluded so a bad
    date can't dominate the average. Returns a dict of stats."""
    w, p = _scope(user_id, doc_name, period)
    mw, mp = _merch_where(keyword)
    con = connect()
    rows = con.execute(f"""SELECT DISTINCT txn_date FROM transactions
                           WHERE {w} AND {mw} AND txn_date NOT LIKE '0000%'
                           ORDER BY txn_date""", p + mp).fetchall()
    con.close()
    dates = []
    for r in rows:
        try:
            dates.append(datetime.strptime(r[0], "%Y-%m-%d"))
        except (ValueError, TypeError):
            continue
    if len(dates) < 2:
        return {"count": len(dates), "avg_days": None, "min_days": None, "max_days": None,
                "first": rows[0][0] if rows else None, "last": rows[-1][0] if rows else None}
    gaps = [(dates[i + 1] - dates[i]).days for i in range(len(dates) - 1)]
    return {"count": len(dates), "avg_days": sum(gaps) / len(gaps),
            "min_days": min(gaps), "max_days": max(gaps),
            "first": dates[0].strftime("%Y-%m-%d"), "last": dates[-1].strftime("%Y-%m-%d")}


def who_paid(user_id, amount=None, doc_name=None, period=None, tol=0.02):
    """Who sent money in (income). With `amount`, the sender(s) of a credit of ~that size,
    each with its date: [(merchant, txn_date, credit)]. Without, income grouped by source:
    [(merchant, Σcredit, n)]. Year-0000 rows excluded from the dated (amount) view."""
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    if amount is not None:
        lo, hi = amount * (1 - tol) - 0.01, amount * (1 + tol) + 0.01
        rows = con.execute(f"""SELECT merchant, txn_date, credit FROM transactions
                               WHERE {w} AND credit>0 AND credit BETWEEN ? AND ?
                               AND txn_date NOT LIKE '0000%'
                               ORDER BY ABS(credit-?), txn_date""", p + [lo, hi, amount]).fetchall()
    else:
        rows = con.execute(f"""SELECT merchant, SUM(credit), COUNT(*) FROM transactions
                               WHERE {w} AND credit>0 GROUP BY merchant ORDER BY 2 DESC""", p).fetchall()
    con.close()
    return rows


def balance_at(user_id, date, doc_name=None):
    """Running balance as of `date` — the last non-null balance on/before it (year-0000 excluded)."""
    w, p = _scope(user_id, doc_name)
    con = connect()
    r = con.execute(f"""SELECT balance FROM transactions WHERE {w} AND txn_date<=?
                        AND txn_date NOT LIKE '0000%' AND balance IS NOT NULL
                        ORDER BY txn_date DESC, seq DESC LIMIT 1""", p + [date]).fetchone()
    con.close()
    return r[0] if r else None


def _target_txn(user_id, keyword, doc_name=None, period=None):
    """The (seq, balance, txn_date, debit, credit) of a merchant's transaction — the latest
    within scope. Year-0000 rows excluded. None if not found."""
    w, p = _scope(user_id, doc_name, period)
    mw, mp = _merch_where(keyword)
    con = connect()
    r = con.execute(f"""SELECT seq, balance, txn_date, debit, credit FROM transactions
                        WHERE {w} AND {mw} AND txn_date NOT LIKE '0000%'
                        ORDER BY txn_date DESC, seq DESC LIMIT 1""", p + mp).fetchone()
    con.close()
    return r


def balance_after(user_id, keyword, doc_name=None, period=None):
    """Running balance immediately AFTER a merchant's transaction (its own balance column)."""
    r = _target_txn(user_id, keyword, doc_name, period)
    if not r:
        return None
    return {"balance": r[1], "date": r[2]}


def balance_before(user_id, keyword, doc_name=None, period=None):
    """Running balance immediately BEFORE a merchant's transaction. Reconstructed from the
    txn's own after-balance (after + debit − credit); falls back to the prior row's balance."""
    r = _target_txn(user_id, keyword, doc_name, period)
    if not r:
        return None
    seq, bal, date, debit, credit = r
    if bal is not None:
        return {"balance": bal + (debit or 0.0) - (credit or 0.0), "date": date}
    w, p = _scope(user_id, doc_name)
    con = connect()
    prev = con.execute(f"""SELECT balance FROM transactions WHERE {w} AND seq<?
                           AND txn_date NOT LIKE '0000%' AND balance IS NOT NULL
                           ORDER BY seq DESC LIMIT 1""", p + [seq]).fetchone()
    con.close()
    return {"balance": prev[0], "date": date} if prev else None


def balance_delta(user_id, date1, date2, doc_name=None):
    """Change in running balance between two dates: {start, end, delta} or None."""
    b1, b2 = balance_at(user_id, date1, doc_name), balance_at(user_id, date2, doc_name)
    if b1 is None or b2 is None:
        return None
    return {"start": b1, "end": b2, "delta": b2 - b1}


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
        if ck in ("debit", "credit", "upi", "card"):           # "how many debit/credit/UPI/card transactions"
            label = {"debit": "Debit transactions", "credit": "Credit transactions",
                     "upi": "UPI transactions", "card": "Card transactions"}[ck]
            return f"**{label}{sfx}:** {grp(txn_count(user_id, ck, doc_name, period))}"
        o = overview(user_id, doc_name, period)
        return f"**Transactions{sfx}:** {grp(o['count'])}"

    if t == "list":                                    # "show me the transactions" -> the rows
        m = (intent.get("merchant") or "").strip()
        cat = (intent.get("category") or "").strip()
        cap = int(intent.get("n") or 0) or 25
        ttype = intent.get("txn_type")
        rows, total = list_transactions(user_id, m or None, cat or None, doc_name, period, cap, ttype)
        who = ""
        if m and cat:   who = f" for {_mname(m)} ({cat})"
        elif m:         who = f" for {_mname(m)}"
        elif cat:       who = f" in {cat}"
        if not rows:
            return f"**No transactions found{who}{sfx}.**"
        body = []
        for d, mer, descr, deb, cr in rows:
            name = (mer or descr or "").strip() or "-"
            body.append((_dlabel(d), _mname(name[:34]),
                         inr(deb) if (deb or 0) > 0 else inr(cr),
                         "Spent" if (deb or 0) > 0 else "Received"))
        head = f"**{grp(total)} transaction{'s' if total != 1 else ''}{who}{sfx}**"
        tail = f"\n\n_Showing the first {grp(len(rows))}._" if total > len(rows) else ""
        return head + "\n\n" + _table(["Date", "Merchant", "Amount", "Type"], body) + tail

    if t == "spend":
        o = overview(user_id, doc_name, period)
        dc = txn_count(user_id, "debit", doc_name, period)   # debit rows only, not income
        extra = ""
        if o.get("credit", 0) > 0:
            cc = txn_count(user_id, "credit", doc_name, period)
            extra = f" (You also received {inr(o['credit'])} across {grp(cc)} transaction{'s' if cc != 1 else ''})"
        return f"**Total spending{sfx}:** {inr(o['debit'])} across {grp(dc)} transactions{extra}"

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
        if cat:
            for c, total, cnt in rows:
                if c == cat:
                    return f"**{c}{sfx}:** {inr(total)} across {grp(cnt)} transactions"
            # a SPECIFIC category was asked for but has no spend in this period -> an honest
            # zero, not the whole breakdown (which reads as that category's spend). by_category
            # only returns categories with debit>0, so an absent one means zero.
            return f"**{cat}{sfx}:** {inr(0)} across 0 transactions"
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
            n = (r["count"] - r["dcount"]) if side == "received" else r["dcount"]  # direction-matched count
            return f"**{_mname(m)}{sfx}:** {side} {inr(amt)} across {grp(n or r['count'])} transactions"

    if t == "merchant_category":
        m = (intent.get("merchant") or "").strip()
        rows = merchant_category(user_id, m, doc_name, period)
        if not rows:
            return f"**No transactions found for '{m}'{sfx}.**"
        if len(rows) == 1:
            return (f"**{_mname(m)}** is categorised under **{rows[0][0]}**{sfx} "
                    f"({grp(rows[0][1])} transaction{'s' if rows[0][1] != 1 else ''}).")
        body = ", ".join(f"{c} ({grp(n)})" for c, n in rows)
        return f"**{_mname(m)}{sfx}** appears under {len(rows)} categories: {body}."

    if t == "merchant_date":
        m = (intent.get("merchant") or "").strip()
        rows = merchant_dates(user_id, m, doc_name, period)
        if not rows:
            return f"**No transactions found for '{m}'{sfx}.**"
        dd = (intent.get("date_dir") or "")
        if dd in ("last", "first") and len(rows) > 1:   # "when did I LAST shop at Aldi?"
            d, deb, cr, _bal = rows[-1] if dd == "last" else rows[0]
            return f"**{_mname(m)}{sfx}** {dd} appears on **{_dlabel(d)}** ({inr(deb or cr)})."
        if len(rows) == 1:
            d, deb, cr, _bal = rows[0]
            return f"**{_mname(m)}{sfx}** appears once — on **{_dlabel(d)}** ({inr(deb or cr)})."
        shown = ", ".join(_dlabel(r[0]) for r in rows[:12])
        more = f" (+{grp(len(rows) - 12)} more)" if len(rows) > 12 else ""
        return f"**{_mname(m)}{sfx}** appears on {grp(len(rows))} dates: {shown}{more}."

    if t in ("balance_min", "balance_max"):
        kind = "min" if t == "balance_min" else "max"
        r = balance_extreme(user_id, kind, doc_name, period)
        if r:
            label = "Lowest" if kind == "min" else "Highest"
            return f"**{label} recorded balance{sfx}:** {inr(r[1])} (on {_dlabel(r[0])})"

    if t == "merchant_interval":
        m = (intent.get("merchant") or "").strip()
        g = payment_interval(user_id, m, doc_name, period)
        if not g or g["count"] == 0:
            return f"**No transactions found for '{m}'{sfx}.**"
        if g["count"] < 2 or g["avg_days"] is None:
            return (f"**Only one dated {_mname(m)} transaction{sfx}** — need at least two to "
                    f"measure the interval between payments.")
        return (f"**{_mname(m)} payments{sfx}:** about **{g['avg_days']:.0f} days** between "
                f"consecutive payments on average (range {g['min_days']}–{g['max_days']} days, "
                f"across {grp(g['count'])} dated payments from {_dlabel(g['first'])} to "
                f"{_dlabel(g['last'])}).")

    if t == "who_paid":
        amt = intent.get("amount")
        rows = who_paid(user_id, amt, doc_name, period)
        if not rows:
            w = f" of {inr(amt)}" if amt is not None else ""
            return f"**No income{w} found{sfx}.**"
        if amt is not None:                                # sender(s) of a ~specific amount
            if len(rows) == 1:
                m, d, c = rows[0]
                return f"**{inr(c)} received from {_mname(m)}** on {_dlabel(d)}{sfx}."
            body = ", ".join(f"{_mname(m)} ({inr(c)} on {_dlabel(d)})" for m, d, c in rows[:8])
            return f"**Income around {inr(amt)}{sfx}:** {body}."
        body = [(_mname(m), inr(c), grp(n)) for m, c, n in rows]
        return f"**Who paid you{sfx}**\n\n" + _table(["Source", "Received", "Txns"], body)

    if t in ("balance_before", "balance_after"):
        m = (intent.get("merchant") or "").strip()
        r = (balance_before if t == "balance_before" else balance_after)(user_id, m, doc_name, period)
        if not r or r["balance"] is None:
            return f"**No dated transaction found for '{m}'{sfx}.**"
        word = "before" if t == "balance_before" else "after"
        return f"**Balance {word} {_mname(m)}{sfx}:** {inr(r['balance'])} (on {_dlabel(r['date'])})"

    if t == "balance_delta":
        d1, d2 = intent.get("date1"), intent.get("date2")
        r = balance_delta(user_id, d1, d2, doc_name)
        if not r:
            return "**Couldn't read the balance on those dates.**"
        direction = "increased" if r["delta"] > 0 else "decreased" if r["delta"] < 0 else "was unchanged"
        by = "" if r["delta"] == 0 else f" by {inr(abs(r['delta']))}"
        return (f"**Balance {direction}{by}** between {_dlabel(d1)} and {_dlabel(d2)} "
                f"(from {inr(r['start'])} to {inr(r['end'])}).")

    if t == "months":
        ms = months_list(user_id, doc_name, period)
        if not ms:
            return "**No months found.**"
        return (f"**{grp(len(ms))} distinct month{'s' if len(ms) != 1 else ''}{sfx}:** "
                + ", ".join(_mlabel(x) for x in ms))

    if t == "top_expenses":
        n = intent.get("n") or 5
        rows = top_expenses(user_id, n, doc_name, period)
        body = [(i + 1, _dlabel(d), mc, inr(v)) for i, (d, mc, v) in enumerate(rows)]
        return f"**Top {n} expenses{sfx}**\n\n" + _table(["#", "Date", "Merchant", "Amount"], body)

    if t in ("largest_expense", "smallest_expense", "largest_income"):
        m = (intent.get("merchant") or "").strip()
        cat = (intent.get("category") or "").strip()
        r = extreme(user_id, t, doc_name, period, merchant=m or None, category=cat or None)
        if r:
            label = {"largest_expense": "Largest expense", "smallest_expense": "Smallest expense",
                     "largest_income": "Largest credit"}[t]
            at = f" at {_mname(m)}" if m else f" in {cat}" if cat else ""
            return f"**{label}{at}{sfx}:** {inr(r[2])} - {r[1]} on {_dlabel(r[0])}"
        if m or cat:
            return f"**No transactions found for '{m or cat}'{sfx}.**"

    if t == "subscriptions":
        rec = subscription_costs(user_id, doc_name, period)
        if not rec and period:      # recurring bills span months — a one-month scope
            rec = subscription_costs(user_id, doc_name, None)   # can't show a cadence
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
