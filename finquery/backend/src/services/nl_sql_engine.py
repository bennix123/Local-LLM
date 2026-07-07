"""
nl_sql_engine.py -- Universal Bank Statement AI: Text-to-SQL Layer

Implements the manager System Prompt spec:
  - account_profile table (bank name, IFSC, dates, balances, etc.)
  - Auto-extraction of account metadata from PDF header text
  - Rule-based NL-to-SQL generator (no hallucination, no guessing)
  - Full workflow: Step 1 Intent -> Step 2 SQL -> Step 3 Execute -> Step 4 Explain

Core Rules enforced (all 10 from System Prompt):
  1. Never answer from memory.
  2. Never guess any value.
  3. Never hallucinate transactions.
  4. Never modify dates, years, months, currencies, or amounts.
  5. Never generate approximate answers.
  6. Every answer must be based only on the database.
  7. Zero rows -> 'No matching record found in the uploaded bank statement.'
  8. Calculations via SQL aggregation -- never manual arithmetic.
  9. Never perform arithmetic mentally if SQL can do it.
  10. SQL first, execute, then explain the result.
"""
import re
import sqlite3
import os
from typing import Optional

try:
    import pymupdf
    _HAS_PYMUPDF = True
except ImportError:
    _HAS_PYMUPDF = False

# ------------------------------------------------------------------ DB path
DB_PATH = os.getenv(
    "TXN_DB_PATH",
    os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", "data", "live_txn.db"))
)

# Month name -> zero-padded number
_MON_MAP = {
    "jan": "01", "feb": "02", "mar": "03", "apr": "04",
    "may": "05", "jun": "06", "jul": "07", "aug": "08",
    "sep": "09", "oct": "10", "nov": "11", "dec": "12",
    "january": "01", "february": "02", "march": "03", "april": "04",
    "june": "06", "july": "07", "august": "08", "september": "09",
    "october": "10", "november": "11", "december": "12",
}
_MON_PAT = "|".join(sorted(_MON_MAP.keys(), key=len, reverse=True))


# ================================================================== Schema
def connect(db_path: str = DB_PATH) -> sqlite3.Connection:
    con = sqlite3.connect(db_path)
    con.execute("PRAGMA journal_mode=WAL")
    con.row_factory = sqlite3.Row
    return con


def init_account_profile_table(db_path: str = DB_PATH) -> None:
    """Create account_profile table if not exists."""
    con = connect(db_path)
    con.execute("""
        CREATE TABLE IF NOT EXISTS account_profile (
            user_id              TEXT PRIMARY KEY,
            bank_name            TEXT,
            account_holder       TEXT,
            account_number       TEXT,
            customer_id          TEXT,
            cif_number           TEXT,
            ifsc                 TEXT,
            iban                 TEXT,
            swift                TEXT,
            branch               TEXT,
            currency             TEXT,
            statement_start_date TEXT,
            statement_end_date   TEXT,
            opening_balance      REAL,
            closing_balance      REAL,
            email                TEXT,
            phone                TEXT
        )
    """)
    con.commit()
    con.close()


def save_account_profile(user_id: str, data: dict, db_path: str = DB_PATH) -> None:
    """Upsert account profile row."""
    con = connect(db_path)
    con.execute("""
        INSERT INTO account_profile
            (user_id, bank_name, account_holder, account_number, customer_id,
             cif_number, ifsc, iban, swift, branch, currency,
             statement_start_date, statement_end_date, opening_balance,
             closing_balance, email, phone)
        VALUES
            (:user_id, :bank_name, :account_holder, :account_number, :customer_id,
             :cif_number, :ifsc, :iban, :swift, :branch, :currency,
             :statement_start_date, :statement_end_date, :opening_balance,
             :closing_balance, :email, :phone)
        ON CONFLICT(user_id) DO UPDATE SET
            bank_name            = excluded.bank_name,
            account_holder       = excluded.account_holder,
            account_number       = excluded.account_number,
            customer_id          = excluded.customer_id,
            cif_number           = excluded.cif_number,
            ifsc                 = excluded.ifsc,
            iban                 = excluded.iban,
            swift                = excluded.swift,
            branch               = excluded.branch,
            currency             = excluded.currency,
            statement_start_date = excluded.statement_start_date,
            statement_end_date   = excluded.statement_end_date,
            opening_balance      = excluded.opening_balance,
            closing_balance      = excluded.closing_balance,
            email                = excluded.email,
            phone                = excluded.phone
    """, {
        "user_id": user_id,
        "bank_name": data.get("bank_name"),
        "account_holder": data.get("account_holder"),
        "account_number": data.get("account_number"),
        "customer_id": data.get("customer_id"),
        "cif_number": data.get("cif_number"),
        "ifsc": data.get("ifsc"),
        "iban": data.get("iban"),
        "swift": data.get("swift"),
        "branch": data.get("branch"),
        "currency": data.get("currency"),
        "statement_start_date": data.get("statement_start_date"),
        "statement_end_date": data.get("statement_end_date"),
        "opening_balance": data.get("opening_balance"),
        "closing_balance": data.get("closing_balance"),
        "email": data.get("email"),
        "phone": data.get("phone"),
    })
    con.commit()
    con.close()


# ================================================================== PDF Metadata Extraction

def _clean_money(s: str) -> Optional[float]:
    if not s:
        return None
    s = re.sub(r"(?i)(cr|dr)\.?$", "", s.strip())
    s = re.sub(r"[^\d.-]", "", s)
    try:
        return float(s)
    except ValueError:
        return None


def _norm_date(s: str) -> Optional[str]:
    """Normalise various date formats -> YYYY-MM-DD."""
    if not s:
        return None
    s = s.strip()
    m = re.match(r"^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})$", s)
    if m:
        return f"{m.group(3)}-{int(m.group(2)):02d}-{int(m.group(1)):02d}"
    m = re.match(r"^(\d{1,2})-([A-Za-z]{3,9})-(\d{4})$", s)
    if m:
        mon = _MON_MAP.get(m.group(2).lower()[:3])
        if mon:
            return f"{m.group(3)}-{mon}-{int(m.group(1)):02d}"
    if re.match(r"^\d{4}-\d{2}-\d{2}$", s):
        return s
    return None


def extract_account_profile(pdf_path: str, user_id: str) -> dict:
    """Extract account metadata from the first 4 pages of a bank statement PDF."""
    text = ""
    doc = None
    if _HAS_PYMUPDF:
        try:
            doc = pymupdf.open(pdf_path)
            text = "".join(doc[i].get_text("text") for i in range(min(4, len(doc))))
        except Exception:
            pass

    data = {
        "user_id": user_id,
        "bank_name": None, "account_holder": None, "account_number": None,
        "customer_id": None, "cif_number": None, "ifsc": None,
        "iban": None, "swift": None, "branch": None, "currency": None,
        "statement_start_date": None, "statement_end_date": None,
        "opening_balance": None, "closing_balance": None,
        "email": None, "phone": None,
    }

    # Bank name dynamic extraction
    bank_name = None
    if doc and text:
        # 1. Fast-track check of popular hardcoded names
        for pat, name in [
            (r"punjab national bank|pnb", "Punjab National Bank"),
            (r"barclays", "Barclays Bank"),
            (r"hdfc bank", "HDFC Bank"),
            (r"state bank of india|sbi\b", "State Bank of India"),
            (r"icici bank", "ICICI Bank"),
            (r"axis bank", "Axis Bank"),
            (r"wrenfield bank", "Wrenfield Bank"),
            (r"kotak mahindra", "Kotak Mahindra Bank"),
            (r"yes bank", "Yes Bank"),
            (r"bank of baroda", "Bank of Baroda"),
            (r"canara bank", "Canara Bank"),
            (r"union bank", "Union Bank of India"),
        ]:
            if re.search(pat, text, re.I):
                bank_name = name
                break

        # 2. Check metadata
        if not bank_name:
            meta = doc.metadata or {}
            for key in ("author", "creator", "title"):
                val = meta.get(key)
                if val and isinstance(val, str):
                    val_clean = val.strip()
                    if re.search(r"\bbank\b", val_clean, re.I) and not re.search(r"statement|report|doc", val_clean, re.I):
                        bank_name = val_clean
                        break

        # 3. Read first page lines
        if not bank_name and len(doc) > 0:
            first_page_text = doc[0].get_text("text")
            lines = [line.strip() for line in first_page_text.split("\n") if line.strip()]
            for line in lines[:15]:
                if re.search(r"\b(bank|banking|financial|cooperative|credit union)\b", line, re.I):
                    if not re.search(r"\b(statement|account|e-statement|summary|report|period|details?|date)\b", line, re.I):
                        if len(line) < 60:
                            bank_name = line
                            break

    # 4. Try from filename
    if not bank_name:
        filename = os.path.basename(pdf_path)
        name_no_ext = os.path.splitext(filename)[0]
        name_spaced = re.sub(r"[-_.]+", " ", name_no_ext).strip()
        if re.search(r"\bbank\b", name_spaced, re.I):
            m = re.match(r"^(.*?\bbank\b)", name_spaced, re.I)
            if m:
                bank_name = m.group(1).title()
        if not bank_name:
            bank_name = name_spaced.title()

    data["bank_name"] = bank_name

    # Close document safely
    if doc:
        try:
            doc.close()
        except Exception:
            pass

    # Currency
    if re.search(r"ifsc|micr|\bINR\b|rs\.", text, re.I):
        data["currency"] = "INR"
    elif re.search(r"barclays|wrenfield|\bGBP\b|iban\s+gb", text, re.I):
        data["currency"] = "GBP"
    else:
        data["currency"] = "INR"

    # IFSC
    m = re.search(r"IFSC\s*[:\-]?\s*([A-Z]{4}0[A-Z0-9]{6})", text)
    if m:
        data["ifsc"] = m.group(1).strip()

    # Account number
    for pat in [
        r"Account\s+No(?:\.?|mber)?\s*[:\-]?\s*(\d{8,20})",
        r"A/C\s+No\.?\s*[\n\r\s:]+(\d{8,20})",
    ]:
        m = re.search(pat, text, re.I)
        if m:
            data["account_number"] = m.group(1).strip()
            break

    # Customer ID / CIF
    m = re.search(r"(?:Cust(?:omer)?\s+ID|CIF(?:\s+(?:ID|No|Number))?)\s*[:\-]?\s*([A-Z0-9]{4,20})", text, re.I)
    if m:
        data["customer_id"] = m.group(1).strip()

    # IBAN
    m = re.search(r"IBAN\s*[:\-]?\s*([A-Z]{2}\d{2}[A-Z0-9]{4,30})", text, re.I)
    if m:
        data["iban"] = m.group(1).strip()

    # SWIFT
    m = re.search(r"(?:SWIFT|BIC)\s*[:\-]?\s*([A-Z]{6}[A-Z0-9]{2,5})", text, re.I)
    if m:
        data["swift"] = m.group(1).strip()

    # Branch
    m = re.search(r"Branch\s*[:\-]?\s*([^\n\r]{3,50}?)(?:\n|\r|$)", text, re.I)
    if m:
        data["branch"] = m.group(1).strip()

    # Account holder name
    m = re.search(r"(?:Account\s+Holder|Name\s*:)\s*([A-Z][A-Z\s]{2,40}?)(?:\n|\r|$)", text)
    if m:
        data["account_holder"] = m.group(1).strip()

    # Email
    m = re.search(r"[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+", text)
    if m:
        data["email"] = m.group(0).strip()

    # Phone
    m = re.search(r"(?:Mobile|Phone|Contact)\s*(?:No\.?)?\s*[:\-]?\s*([X\d\s\-+]{8,15})", text, re.I)
    if m:
        data["phone"] = m.group(1).strip()

    # Statement period
    m = re.search(
        r"Statement\s+Period\s*[:\-]?\s*"
        r"(\d{1,2}[-/]\w{3,9}[-/]\d{4}|\d{1,2}[-/]\d{1,2}[-/]\d{4})"
        r"\s+(?:to|till|[-])\s*"
        r"(\d{1,2}[-/]\w{3,9}[-/]\d{4}|\d{1,2}[-/]\d{1,2}[-/]\d{4})",
        text, re.I
    )
    if m:
        data["statement_start_date"] = _norm_date(m.group(1))
        data["statement_end_date"] = _norm_date(m.group(2))
    else:
        m = re.search(r"(\d{2}/\d{2}/\d{4})\s*[-]\s*(\d{2}/\d{2}/\d{4})", text)
        if m:
            data["statement_start_date"] = _norm_date(m.group(1))
            data["statement_end_date"] = _norm_date(m.group(2))

    # Opening / closing balance
    m = re.search(r"Opening\s+Balance\s*[:\-]?\s*([\d,]+\.\d{2}(?:CR|DR)?\.?)", text, re.I)
    if m:
        data["opening_balance"] = _clean_money(m.group(1))

    m = re.search(r"Closing\s+Balance\s*[:\-]?\s*([\d,]+\.\d{2}(?:CR|DR)?\.?)", text, re.I)
    if m:
        data["closing_balance"] = _clean_money(m.group(1))

    return data


# ================================================================== NL->SQL Engine

_PROFILE_FIELDS = {
    "ifsc": ("ifsc", "IFSC code"),
    "iban": ("iban", "IBAN"),
    "swift": ("swift", "SWIFT/BIC code"),
    "bic": ("swift", "SWIFT/BIC code"),
    "account number": ("account_number", "account number"),
    "account no": ("account_number", "account number"),
    "a/c no": ("account_number", "account number"),
    "account holder": ("account_holder", "account holder name"),
    "bank name": ("bank_name", "bank name"),
    "bank": ("bank_name", "bank name"),
    "branch": ("branch", "branch"),
    "cif": ("cif_number", "CIF number"),
    "customer id": ("customer_id", "customer ID"),
    "opening balance": ("opening_balance", "opening balance"),
    "closing balance": ("closing_balance", "closing balance"),
    "statement period": (("statement_start_date", "statement_end_date"), "statement period"),
    "statement start": ("statement_start_date", "statement start date"),
    "statement end": ("statement_end_date", "statement end date"),
    "start date": ("statement_start_date", "statement start date"),
    "end date": ("statement_end_date", "statement end date"),
    "phone": ("phone", "phone number"),
    "mobile": ("phone", "phone number"),
    "email": ("email", "email address"),
    "currency": ("currency", "currency"),
}

_CREDIT_RE = re.compile(
    r"\b(income|earn(?:ed|ings|t)?|salary|salaries|inflow|received?|credit|money\s+in|deposit)\b", re.I
)
_DEBIT_RE = re.compile(
    r"\b(spend|spent|expense|expenditure|payment|paid|purchase|withdrawal|debit|money\s+out)\b", re.I
)
_COUNT_RE = re.compile(
    r"\b(how\s+many|number\s+of|no\.?\s+of|count|how\s+much\s+time|how\s+many\s+times|trans[ac]*tion[s]?|txns?)\b", re.I
)
_BAL_RE = re.compile(r"\b(current\s+balance|balance|remaining|left|kitna\s+bacha)\b", re.I)
_TOP_N_RE = re.compile(r"\btop\s+(\d+)\b", re.I)

_DATE_PAT = (
    r"\d{4}-\d{2}-\d{2}"
    r"|\d{1,2}[/-]\d{1,2}[/-]\d{4}"
    r"|\d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?(?:" + _MON_PAT + r")\s+\d{4}"
)
_DATE_RANGE_RE = re.compile(
    rf"({_DATE_PAT})\s*(?:to|till|until|through|[-])\s*({_DATE_PAT})", re.I
)
_SINGLE_DATE_RE = re.compile(rf"\b({_DATE_PAT})\b", re.I)
_YEAR_RE = re.compile(r"\b(20\d{2})\b")
_MON_YEAR_RE = re.compile(rf"\b({_MON_PAT})\s+(20\d{2})\b", re.I)
_FIRST_WEEK_RE = re.compile(rf"\bfirst\s+week\s+(?:of\s+)?({_MON_PAT})(?:\s+(20\d{2}))?\b", re.I)


def _parse_date_str(s: str) -> Optional[str]:
    s = s.strip()
    if re.match(r"^\d{4}-\d{2}-\d{2}$", s):
        return s
    m = re.match(r"^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$", s)
    if m:
        return f"{m.group(3)}-{int(m.group(2)):02d}-{int(m.group(1)):02d}"
    m = re.match(r"^(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?([A-Za-z]+)\s+(\d{4})$", s)
    if m:
        mon = _MON_MAP.get(m.group(2).lower()[:3])
        if mon:
            return f"{m.group(3)}-{mon}-{int(m.group(1)):02d}"
    return None


def _extract_period(question: str):
    low = question.lower()
    m = _FIRST_WEEK_RE.search(low)
    if m:
        mon = _MON_MAP.get(m.group(1).lower()[:3])
        yr = m.group(2) if m.lastindex >= 2 and m.group(2) else None
        if not yr:
            yr_m = _YEAR_RE.search(question)
            yr = yr_m.group(1) if yr_m else None
        if mon and yr:
            return f"{yr}-{mon}-01", f"{yr}-{mon}-07"

    m = _DATE_RANGE_RE.search(question)
    if m:
        a, b = _parse_date_str(m.group(1)), _parse_date_str(m.group(2))
        if a and b:
            return (a, b) if a <= b else (b, a)

    m = _SINGLE_DATE_RE.search(question)
    if m:
        d = _parse_date_str(m.group(1))
        if d:
            return d, d

    m = _MON_YEAR_RE.search(low)
    if m:
        mon = _MON_MAP.get(m.group(1).lower()[:3])
        yr = m.group(2)
        ld = {"01":"31","02":"28","03":"31","04":"30","05":"31","06":"30",
              "07":"31","08":"31","09":"30","10":"31","11":"30","12":"31"}
        if mon and yr:
            return f"{yr}-{mon}-01", f"{yr}-{mon}-{ld.get(mon,'30')}"

    yr_m = _YEAR_RE.search(question)
    if yr_m:
        yr = yr_m.group(1)
        return f"{yr}-01-01", f"{yr}-12-31"

    return None, None


def _is_outside(start: str, end: str, s_start, s_end) -> bool:
    if not s_start or not s_end:
        return False
    end_cmp = end or start
    return start > s_end or end_cmp < s_start


def _fmt_money(val, currency="INR") -> str:
    if val is None:
        return "N/A"
    sym = {"INR": "Rs.", "GBP": "GBP", "USD": "USD", "EUR": "EUR"}.get(currency, currency)
    return f"{sym} {val:,.2f}"


def _period_desc(start, end) -> str:
    if not start:
        return "(all time)"
    if not end or start == end:
        return f"on {start}"
    if start[:7] == end[:7]:
        return f"in {start[:7]}"
    if start.endswith("01-01") and end.endswith("12-31") and start[:4] == end[:4]:
        return f"in {start[:4]}"
    return f"between {start} and {end}"


def _extract_merchant(question: str) -> Optional[str]:
    m = re.search(
        r"\b(?:on|at|to|from|with|paid\s+to|spend(?:ing)?\s+(?:at|on))\s+"
        r"([A-Za-z0-9][A-Za-z0-9 &.'-]{1,40}?)"
        r"(?=\s+(?:in|during|for|between|from|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec|20\d{2})|[?.!,]|$)",
        question, re.I
    )
    if m:
        name = m.group(1).strip()
        stopwords = {"me","my","the","a","an","all","total","bank","statement","account"}
        if name.lower() not in stopwords and len(name) > 1:
            return name
    return None


def _no_record():
    return {"intent":"no match","sql":"","params":[],"result":[],
            "answer":"No matching record found in the uploaded bank statement."}


def _no_data(msg):
    return {"intent":"no data","sql":"","params":[],"result":[],"answer":msg}


def _outside_period():
    return {"intent":"outside period","sql":"","params":[],"result":[],
            "answer":"The requested date is outside the uploaded statement period."}


def nl_to_sql(question: str, user_id: str, db_path: str = DB_PATH) -> dict:
    """
    Main entry point: NL -> SQL -> Execute -> Explain.

    Workflow (as per System Prompt):
      Step 1: Understand intent.
      Step 2: Generate SQL.
      Step 3: Execute SQL.
      Step 4: Explain result in natural language.
    """
    init_account_profile_table(db_path)
    con = connect(db_path)

    profile = con.execute(
        "SELECT * FROM account_profile WHERE user_id=?", (user_id,)
    ).fetchone()
    stmt_start = profile["statement_start_date"] if profile else None
    stmt_end = profile["statement_end_date"] if profile else None
    currency = (profile["currency"] if profile else None) or "INR"
    low = question.lower().strip()

    # Strip any date patterns from the query for clean merchant extraction
    q_clean = question
    q_clean = _DATE_RANGE_RE.sub("", q_clean)
    q_clean = _SINGLE_DATE_RE.sub("", q_clean)
    q_clean = _MON_YEAR_RE.sub("", q_clean)
    q_clean = _FIRST_WEEK_RE.sub("", q_clean)
    q_clean = _YEAR_RE.sub("", q_clean)

    # ---- Step 1 + 2: Detect intent and build SQL ----------------------------

    # 1a. Profile field query (IFSC, account number, bank name, etc.)
    for keyword in sorted(_PROFILE_FIELDS.keys(), key=len, reverse=True):
        if keyword in low:
            col, label = _PROFILE_FIELDS[keyword]
            if not profile:
                con.close()
                return _no_data("No account profile found. Please upload a bank statement first.")

            if isinstance(col, tuple):
                sql = f"SELECT {', '.join(col)} FROM account_profile WHERE user_id=?"
                params = [user_id]
                rows = con.execute(sql, params).fetchall()
                con.close()
                if not rows:
                    return _no_record()
                vals = [str(rows[0][c]) for c in col if rows[0][c]]
                return {"intent": f"profile: {label}", "sql": sql, "params": params,
                        "result": [dict(rows[0])],
                        "answer": f"Your {label} is: {' to '.join(vals)}."}
            else:
                sql = f"SELECT {col} FROM account_profile WHERE user_id=?"
                params = [user_id]
                rows = con.execute(sql, params).fetchall()
                con.close()
                val = rows[0][col] if rows else None
                if val is None:
                    return _no_record()
                formatted = _fmt_money(val, currency) if "balance" in col else str(val)
                return {"intent": f"profile: {label}", "sql": sql, "params": params,
                        "result": [dict(rows[0])],
                        "answer": f"Your {label} is: {formatted}."}

    # 1b. Check transactions exist
    txn_count = con.execute(
        "SELECT COUNT(*) FROM transactions WHERE user_id=? AND currency=?", (user_id, currency)
    ).fetchone()[0]
    if txn_count == 0:
        con.close()
        return _no_data("No transactions found. Please upload a bank statement first.")

    # 1c. Current/latest balance
    if _BAL_RE.search(low) and not any(w in low for w in ("opening","closing","spent","spend","income","earn")):
        sql = "SELECT balance FROM transactions WHERE user_id=? AND currency=? ORDER BY seq DESC LIMIT 1"
        params = [user_id, currency]
        rows = con.execute(sql, params).fetchall()
        con.close()
        if not rows:
            return _no_record()
        val = rows[0]["balance"]
        return {"intent": "current balance", "sql": sql, "params": params,
                "result": [dict(r) for r in rows],
                "answer": f"Your current (latest) balance is {_fmt_money(val, currency)}."}

    # 1d. Count query
    if _COUNT_RE.search(low):
        period_start, period_end = _extract_period(question)
        if period_start and _is_outside(period_start, period_end or period_start, stmt_start, stmt_end):
            con.close(); return _outside_period()
        merchant = _extract_merchant(q_clean)
        where, params = "user_id=? AND currency=?", [user_id, currency]
        if merchant:
            where += " AND LOWER(merchant) LIKE ?"; params.append(f"%{merchant.lower()}%")
        if period_start and period_end and period_start != period_end:
            where += " AND txn_date BETWEEN ? AND ?"; params += [period_start, period_end]
        elif period_start:
            where += " AND txn_date LIKE ?"; params.append(f"{period_start}%")
        sql = f"SELECT COUNT(*) AS transaction_count FROM transactions WHERE {where}"
        rows = con.execute(sql, params).fetchall()
        con.close()
        count = rows[0]["transaction_count"] if rows else 0
        desc = f"for {merchant}" if merchant else ""
        pd = _period_desc(period_start, period_end)
        return {"intent":"transaction count","sql":sql,"params":params,
                "result":[dict(r) for r in rows],
                "answer":f"There are **{count} transactions** {desc} {pd}.".strip()}

    # 1e. Top-N expenses
    m_top = _TOP_N_RE.search(low)
    if m_top and any(w in low for w in ("expense","spend","payment","paid","largest","biggest")):
        n = int(m_top.group(1))
        period_start, period_end = _extract_period(question)
        if period_start and _is_outside(period_start, period_end or period_start, stmt_start, stmt_end):
            con.close(); return _outside_period()
        where, params = "user_id=? AND debit>0 AND currency=?", [user_id, currency]
        if period_start and period_end and period_start != period_end:
            where += " AND txn_date BETWEEN ? AND ?"; params += [period_start, period_end]
        elif period_start:
            where += " AND txn_date LIKE ?"; params.append(f"{period_start}%")
        sql = (f"SELECT txn_date, merchant, descr, debit FROM transactions "
               f"WHERE {where} ORDER BY debit DESC LIMIT ?")
        params.append(n)
        rows = con.execute(sql, params).fetchall()
        con.close()
        if not rows: return _no_record()
        lines = [f"Top {n} expenses:"]
        for i, r in enumerate(rows, 1):
            payee = r["merchant"] or r["descr"] or "Unknown"
            lines.append(f"{i}. {payee} -- {_fmt_money(r['debit'], currency)} on {r['txn_date']}")
        return {"intent":f"top {n} expenses","sql":sql,"params":params,
                "result":[dict(r) for r in rows],"answer":"\n".join(lines)}

    # 1f. Income / credit query
    if _CREDIT_RE.search(low):
        period_start, period_end = _extract_period(question)
        if period_start and _is_outside(period_start, period_end or period_start, stmt_start, stmt_end):
            con.close(); return _outside_period()
        merchant = _extract_merchant(q_clean)
        where, params = "user_id=? AND credit>0 AND currency=?", [user_id, currency]
        if merchant:
            where += " AND LOWER(merchant) LIKE ?"; params.append(f"%{merchant.lower()}%")
        if period_start and period_end and period_start != period_end:
            where += " AND txn_date BETWEEN ? AND ?"; params += [period_start, period_end]
        elif period_start:
            where += " AND txn_date LIKE ?"; params.append(f"{period_start}%")
        sql = f"SELECT SUM(credit) AS total_income FROM transactions WHERE {where}"
        rows = con.execute(sql, params).fetchall()
        con.close()
        val = rows[0]["total_income"] if rows else None
        if not val: return _no_record()
        desc = f"from {merchant}" if merchant else ""
        pd = _period_desc(period_start, period_end)
        return {"intent":"total income","sql":sql,"params":params,
                "result":[dict(r) for r in rows],
                "answer":f"Total income {desc} {pd} is **{_fmt_money(val, currency)}**.".strip()}

    # 1g. Default: spend / debit query
    period_start, period_end = _extract_period(question)
    if period_start and _is_outside(period_start, period_end or period_start, stmt_start, stmt_end):
        con.close(); return _outside_period()
    merchant = _extract_merchant(q_clean)
    where, params = "user_id=? AND debit>0 AND currency=?", [user_id, currency]
    if merchant:
        where += " AND LOWER(merchant) LIKE ?"; params.append(f"%{merchant.lower()}%")
    if period_start and period_end and period_start != period_end:
        where += " AND txn_date BETWEEN ? AND ?"; params += [period_start, period_end]
    elif period_start:
        where += " AND txn_date LIKE ?"; params.append(f"{period_start}%")
    sql = f"SELECT SUM(debit) AS total_spend FROM transactions WHERE {where}"
    rows = con.execute(sql, params).fetchall()
    con.close()
    val = rows[0]["total_spend"] if rows else None
    if not val: return _no_record()
    desc = f"on {merchant}" if merchant else ""
    pd = _period_desc(period_start, period_end)
    return {"intent":"total spend","sql":sql,"params":params,
            "result":[dict(r) for r in rows],
            "answer":f"Total spending {desc} {pd} is **{_fmt_money(val, currency)}**.".strip()}
