import sys, os
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "backend")))
import re, os, threading, json
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from src.services import txn_store as ts
from .prompts import ROUTER_SYSTEM

USER = "local"
# Display name only (capability text). The live model is owned by llm_provider (MLX, in-process).
from src.services.llm_provider import active_model as _active_model, DEFAULT_MODEL
LLM_MODEL = os.getenv("LLM_MODEL", DEFAULT_MODEL)
CHAT_LOG = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "data", "chats.json"))

_log_lock = threading.Lock()

UPLOAD_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "data", "uploads"))
os.makedirs(UPLOAD_DIR, exist_ok=True)

_PINNED_DB = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "data", "live_txn.db"))

_env_db = os.environ.get("FINQ_DB")

def _fmt_date(d):
    """'YYYY-MM-DD' -> '15 Jan 24' for the Penny UI."""
    if not d or len(d) < 10:
        return d or ""
    y, m, day = d[:4], d[5:7], d[8:10]
    return f"{int(day)} {ts.MONTHS.get(m, m)} {y[2:]}"

_ML_CACHE = {}

CONVO_RE = re.compile(
    r"^(hi+|hii+|hey+|hy+|hello+|h(e)?l+o+|yo|hola|namaste|sup|heya|good (morning|afternoon|evening)|"
    r"how are you|how's it going|who are you|what are you|thanks|"
    r"thank you|thx|bye|goodbye)\b", re.I)

HELP_RE = re.compile(r"^(help|\?|what can (you|u) (do|help)|how (do i|to) use|commands?)\b", re.I)

def _capabilities():
    return ("I answer questions about your statement with exact figures. Try:\n\n"
            "- **Totals**  -  \"total spending\", \"total income\", \"net position\"\n"
            "- **By period**  -  \"how much did I spend in 2024\", \"march 2025 summary\"\n"
            "- **By category**  -  \"spending by category\", \"how much on groceries\"\n"
            "- **By merchant**  -  \"how much on swiggy / amazon / zerodha\"\n"
            "- **Extremes**  -  \"biggest expense\", \"top 5 expenses\"\n"
            "- **Coverage**  -  \"which months do you have\"\n"
            "- **Balance**  -  \"current balance\"\n"
            "- **Health score**  -  \"how financially healthy am I?\", \"rate my finances\"\n"
            "- **Risk**  -  \"what risks do you see?\", \"am I overspending?\"\n"
            "- **Patterns & habits**  -  \"what patterns do you see?\", \"what spending habits do I have?\"\n"
            "- **Subscriptions**  -  \"what subscriptions do I have?\", \"recurring bills\"\n"
            "- **Impact & trends**  -  \"which transactions had the biggest impact?\", \"which categories are growing fastest?\"\n"
            f"- **Advice**  -  \"how can I save money?\" (uses local {LLM_MODEL})")

_MON_RE = (r"jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?"
           r"|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?")

def _mon_num(s):
    return {"jan": "01", "feb": "02", "mar": "03", "apr": "04", "may": "05", "jun": "06",
            "jul": "07", "aug": "08", "sep": "09", "oct": "10", "nov": "11", "dec": "12"}[s[:3].lower()]

def _norm_one(s):
    """Normalise a single date expression to YYYY | YYYY-MM | YYYY-MM-DD, or None."""
    s = s.strip().lower().rstrip(".,")
    m = re.fullmatch(rf"(\d{{1,2}})(?:st|nd|rd|th)?\s+(?:of\s+)?({_MON_RE})\.?\s+(\d{{4}})", s)  # 27th (of) sep 2024
    if m:
        return f"{m.group(3)}-{_mon_num(m.group(2))}-{int(m.group(1)):02d}"
    m = re.fullmatch(rf"({_MON_RE})\.?\s+(\d{{1,2}})(?:st|nd|rd|th)?\s+(\d{{4}})", s)  # oct 15 2024
    if m:
        return f"{m.group(3)}-{_mon_num(m.group(1))}-{int(m.group(2)):02d}"
    m = re.fullmatch(r"(\d{1,2})[/-](\d{1,2})[/-](\d{4})", s)               # 15/10/2024 (DD/MM)
    if m:
        return f"{m.group(3)}-{int(m.group(2)):02d}-{int(m.group(1)):02d}"
    m = re.fullmatch(rf"({_MON_RE})\.?\s+(\d{{4}})", s)                     # oct 2024
    if m:
        return f"{m.group(2)}-{_mon_num(m.group(1))}"
    m = re.fullmatch(r"(20\d\d)", s)                                        # 2024
    if m:
        return m.group(1)
    return None

_DATE_EXPR = (rf"(?:\d{{1,2}}(?:st|nd|rd|th)?\s+(?:of\s+)?(?:{_MON_RE})\.?,?\s+\d{{4}}"
              rf"|(?:{_MON_RE})\.?\s+\d{{1,2}}(?:st|nd|rd|th)?,?\s+\d{{4}}"
              rf"|\d{{1,2}}[/-]\d{{1,2}}[/-]\d{{4}}"
              rf"|(?:{_MON_RE})\.?,?\s+\d{{4}}"
              rf"|20\d\d)")

_RANGE_RE = re.compile(rf"({_DATE_EXPR})\s*(?:\-|to|till|until|through|thru|and)\s*({_DATE_EXPR})", re.I)

_SINGLE_RE = re.compile(_DATE_EXPR, re.I)

_INCOME_RE = re.compile(r"\b(income|earn(?:ed|ings|t)?|salary|salaries|inflow|r[ae]cei?ve?d?|r[ae]cie?ve?d?|recevied|racevied)\b", re.I)

_COUNTQ_RE = re.compile(r"\bhow many\b|\bnumber of\b|\bno\.? of\b|\bcount\b|\bhow much time\b|\bhow many times\b|\bhow much\s+(?:trans[ac]*ti(?:on|no|o|n)s?|txns?|purchases?)\b", re.I)

_WORDNUM = {"twenty": 20, "thirty": 30, "twenty one": 21, "twenty two": 22, "twenty three": 23,
            "twenty four": 24, "twenty five": 25, "twenty six": 26, "twenty seven": 27,
            "twenty eight": 28, "twenty nine": 29}

def _sub_word_years(q):
    """'twenty twenty four' -> '2024'."""
    def repl(m):
        return "20" + f"{_WORDNUM.get(m.group(1).lower(), 0):02d}"
    return re.sub(r"\btwenty[- ]twenty[- ](one|two|three|four|five|six|seven|eight|nine)\b",
                  lambda m: "20" + f"{_WORDNUM['twenty ' + m.group(1).lower()] % 100:02d}", q, flags=re.I)

def _anchor_month():
    """Latest YYYY-MM that has data (relative dates resolve against the statement)."""
    cov = ts.coverage(USER)
    return cov[1] if cov else None

def _year_for_month(mm):
    """Concrete year for a bare month 'MM' (question gave no year and no year is carried):
    the latest year that actually has data in that month, else the statement's anchor
    (latest) year  -  so even a no-data month ('August') scopes to a real year and honestly
    returns zero instead of silently falling back to the all-time total."""
    cov = ts.coverage(USER)
    if not cov:
        return ""
    con = ts.connect()
    r = con.execute("SELECT substr(month,1,4) y FROM transactions WHERE user_id=? "
                    "AND substr(month,6,2)=? ORDER BY y DESC LIMIT 1", (USER, mm)).fetchone()
    con.close()
    return r[0] if r else cov[1][:4]

def _anchor_day():
    """The statement's latest transaction DATE (YYYY-MM-DD)  -  the anchor for
    'today'/'yesterday'/'this week' on historical data. None when no data."""
    con = ts.connect()
    r = con.execute("SELECT MAX(txn_date) FROM transactions WHERE user_id=?", (USER,)).fetchone()
    con.close()
    return r[0] if r and r[0] else None

def _shift_day(d, delta):
    return (datetime.strptime(d, "%Y-%m-%d") + timedelta(days=delta)).strftime("%Y-%m-%d")

def _week_range(d, offset):
    """(start, end) full dates of the ISO week containing anchor day `d`, shifted by
    `offset` weeks; 'this week' (offset 0) is capped at the anchor day (no future)."""
    dt = datetime.strptime(d, "%Y-%m-%d")
    monday = dt - timedelta(days=dt.weekday()) + timedelta(weeks=offset)
    start = monday.strftime("%Y-%m-%d")
    end = (monday + timedelta(days=6)).strftime("%Y-%m-%d")
    if offset == 0 and end > d:
        end = d
    return start, end

def _shift_month(ym, delta):
    y, m = int(ym[:4]), int(ym[5:7])
    i = (y * 12 + (m - 1)) + delta
    return f"{i // 12:04d}-{i % 12 + 1:02d}"

def _relative_period(q):
    """Resolve 'this/last month|year', 'last N months', 'last quarter', YTD against
    the statement's latest month. Returns (start, end) or None."""
    low = q.lower()
    a = _anchor_month()
    if not a:
        return None
    ay = a[:4]
    if re.search(r"\b(this|current) month\b", low):
        return a, ""
    if re.search(r"\b(last|previous|prev) month\b", low):
        return _shift_month(a, -1), ""
    if re.search(r"\b(this|current) year\b|\byear[- ]to[- ]date\b|\bytd\b", low):
        return ay, ""
    if re.search(r"\b(last|previous|prev) year\b", low):
        return f"{int(ay)-1}", ""
    # day/week deictics  -  anchored on the statement's latest transaction date, not the
    # wall clock (the data is historical); only hits the DB when the words appear.
    if re.search(r"\btoday\b|\byesterday\b|\b(?:this|current|last|previous|past)\s+week\b", low):
        d = _anchor_day()
        if d:
            if re.search(r"\btoday\b", low):
                return d, ""
            if re.search(r"\byesterday\b", low):
                return _shift_day(d, -1), ""
            if re.search(r"\b(?:this|current)\s+week\b", low):
                return _week_range(d, 0)
            return _week_range(d, -1)                       # last/previous/past week
    # quarters  -  "Q2", "second quarter", optionally with a year, else the anchor year
    qm = re.search(r"\bq([1-4])\b", low) \
        or re.search(r"\b(first|second|third|fourth|1st|2nd|3rd|4th)\s+quarter\b", low)
    if qm:
        g = qm.group(1)
        qn = int(g) if g.isdigit() else {"first": 1, "1st": 1, "second": 2, "2nd": 2,
                                         "third": 3, "3rd": 3, "fourth": 4, "4th": 4}[g]
        ym_ = re.search(r"\b(20\d{2})\b", low)
        y = ym_.group(1) if ym_ else ay
        return f"{y}-{3 * qn - 2:02d}", f"{y}-{3 * qn:02d}"
    m = re.search(r"\b(?:last|past|previous|recent)\s+(\d{1,2}|couple of|few|two|three|four|five|"
                  r"six|seven|eight|nine|ten|eleven|twelve)\s+months?\b", low)
    if m:
        n = {"couple of": 2, "two": 2, "few": 3, "three": 3, "four": 4, "five": 5, "six": 6,
             "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
             "twelve": 12}.get(m.group(1)) or int(m.group(1))
        return _shift_month(a, -(n - 1)), a
    if re.search(r"\b(last|past|previous) quarter\b", low):
        return _shift_month(a, -2), a
    return None

_AMT_CMP_RE = re.compile(
    r"\b(?:over|above|under|below|more than|less than|greater than|bigger than|smaller than|"
    r"exceed\w*|cheaper than|higher than|lower than|at\s?least|atleast|min(?:imum)?|max(?:imum)?)"
    r"\s+(?:Γé╣|₹|┬ú|£|\$|Γé¼|€|rs\.?|inr|gbp|usd|eur|rupees?|rupess|pounds?|quid)?\s*\d[\d,]*(?:\.\d+)?", re.I)

def _strip_cmp_amounts(q):
    """Blank out 'under 2000' / 'over 2024' style amounts so a year-range number used in an
    amount comparison is never misread as a YEAR by the period parser."""
    return _AMT_CMP_RE.sub(" ", q)

def _bare_day_month_period(q):
    """Handle 'D MMM' / 'MMM D' (day+month, no year) e.g. '1 jan', 'jan 1st', '15 june'.
    Resolves to a full YYYY-MM-DD single-day period using the statement's year for that month.
    Returns (date, date) so downstream code treats it as a date-range."""
    low = q.lower()
    # Skip if a 4-digit year is present  -  year-qualified paths handle those.
    if re.search(r"\b20\d{2}\b", low):
        return None
    # Skip if this looks like a day-range ("1 jan to 5 jan")  -  _day_range_period owns it.
    _SEP_PAT = r"(?:to|till|until|through|thru|[-\u2013\u2014]|and)"
    if re.search(rf"\b\d{{1,2}}(?:st|nd|rd|th)?\s+(?:{_MON_RE})\b.{{0,10}}{_SEP_PAT}", low):
        return None
    # Match: DD MMM  or  MMM DD (with optional ordinal)
    m = re.search(rf"\b(\d{{1,2}})(?:st|nd|rd|th)?\s+({_MON_RE})\b", low) \
        or re.search(rf"\b({_MON_RE})\s+(\d{{1,2}})(?:st|nd|rd|th)?\b", low)
    if not m:
        return None
    g = m.groups()
    if g[0].isdigit():
        day_s, mon_s = g[0], g[1]   # DD MMM
    else:
        day_s, mon_s = g[1], g[0]   # MMM DD
    day = int(day_s)
    if not (1 <= day <= 31):
        return None
    mm = _mon_num(mon_s)
    y = _year_for_month(mm)
    if not y:
        return None
    date_str = f"{y}-{mm}-{day:02d}"
    return date_str, date_str

def _bare_month_period(q):
    """A bare month name (no year) in a clear period context -> the statement's year for that
    month, e.g. 'in May' / 'May spending' -> ('2026-05', ''). Conservative: skips a bare
    month-to-month RANGE and a day-adjacent month ('15 August' is a day, handled as MD-),
    and only treats the modal-ambiguous 'may' as a month inside an explicit period context.
    This makes bare months resolve on EVERY path (factual, analytics, LLM guards), not just
    the factual slot extractor."""
    low = q.lower()
    if re.search(rf"\b(?:{_MON_RE})\b\s*(?:to|till|until|through|thru|[-\u2013\u2014]|and)\s*\b(?:{_MON_RE})\b", low):
        return None                                   # a range -> handled as a range elsewhere
    m = re.search(rf"\b(?:in|for|during|of|within|month of)\s+({_MON_RE})\b", low) \
        or re.search(rf"\b({_MON_RE})\s+(?:month\b|spend\w*|spent|expenses?|expenditure|"
                     rf"income|earn\w*|total|txns?|transactions?)", low)
    if not m:
        return None
    tok = m.group(1)
    if re.search(rf"\b\d{{1,2}}(?:st|nd|rd|th)?\s+{re.escape(tok)}\b|\b{re.escape(tok)}\s+\d{{1,2}}\b", low):
        return None                                   # a specific day -> MD-/date parsing owns it
    mm = _mon_num(tok)
    y = _year_for_month(mm)
    return (f"{y}-{mm}", "") if y else None

_SEP = r"(?:\-|to|till|until|through|thru|and)"

_DAY_RANGE_RES = [
    # "1 July to 3 August" / "1st Jul - 3rd Aug"        (a month on BOTH ends)
    (re.compile(rf"\b(\d{{1,2}})(?:st|nd|rd|th)?\s+({_MON_RE})\.?\s*{_SEP}\s*"
                rf"(\d{{1,2}})(?:st|nd|rd|th)?\s+({_MON_RE})\b", re.I), "dMdM"),
    # "July 1 to July 3"                                (month FIRST on both ends)
    (re.compile(rf"\b({_MON_RE})\.?\s+(\d{{1,2}})(?:st|nd|rd|th)?\s*{_SEP}\s*"
                rf"({_MON_RE})\.?\s+(\d{{1,2}})(?:st|nd|rd|th)?\b", re.I), "MdMd"),
    # "1 to 3 July" / "between 1 and 3 July" / "1-3 July"   (single trailing month)
    (re.compile(rf"\b(\d{{1,2}})(?:st|nd|rd|th)?\s*{_SEP}\s*"
                rf"(\d{{1,2}})(?:st|nd|rd|th)?\s+({_MON_RE})\b", re.I), "ddM"),
    # "July 1 to 3" / "July 1-3"                        (single leading month)
    (re.compile(rf"\b({_MON_RE})\.?\s+(\d{{1,2}})(?:st|nd|rd|th)?\s*{_SEP}\s*"
                rf"(\d{{1,2}})(?:st|nd|rd|th)?\b", re.I), "Mdd"),
]

def _day_range_period(q):
    """A day-level date range without an explicit year  -  '1 July to 3 July', 'between 1 and 3
    August', 'July 1-3', '1 Jul to 3 Aug'. Returns a full (start, end) date range, using an
    explicit trailing year if present else the statement's year for each month. None if no
    day-range shape is found (year-qualified ranges are handled by _RANGE_RE)."""
    low = q.lower()
    ym = re.search(r"\b(20\d\d)\b", low)

    def dfull(day, mon):
        mm = _mon_num(mon)
        if not mm or not (1 <= int(day) <= 31):
            return None
        yy = ym.group(1) if ym else _year_for_month(mm)
        return f"{yy}-{mm}-{int(day):02d}" if yy else None

    for rx, shape in _DAY_RANGE_RES:
        m = rx.search(low)
        if not m:
            continue
        g = m.groups()
        if shape == "dMdM":
            a, b = dfull(g[0], g[1]), dfull(g[2], g[3])
        elif shape == "MdMd":
            a, b = dfull(g[1], g[0]), dfull(g[3], g[2])
        elif shape == "ddM":
            a, b = dfull(g[0], g[2]), dfull(g[1], g[2])
        else:  # "Mdd"
            a, b = dfull(g[1], g[0]), dfull(g[2], g[0])
        if a and b:
            return (a, b) if a <= b else (b, a)
    return None

_WEEK_ORD_RE = re.compile(
    r"\b(1st|first|2nd|second|3rd|third|4th|fourth|last)\s+week\s+(?:of\s+)?(" + _MON_RE + r")\b|"
    rf"\b({_MON_RE})\s+(1st|first|2nd|second|3rd|third|4th|fourth|last)\s+week\b", re.I
)

def _week_of_month_period(q):
    low = q.lower()
    m = _WEEK_ORD_RE.search(low)
    if not m:
        return None
    ord_str = m.group(1) or m.group(4)
    mon_str = m.group(2) or m.group(3)
    if not ord_str or not mon_str:
        return None
    mm = _mon_num(mon_str)
    if not mm:
        return None
    ym = re.search(r"\b(20\d\d)\b", low)
    yy = ym.group(1) if ym else _year_for_month(mm)
    if not yy:
        yy = _anchor_month()[:4] if _anchor_month() else "2024"
    if ord_str.lower() == "last":
        ld = {"01":31,"02":28,"03":31,"04":30,"05":31,"06":30,
              "07":31,"08":31,"09":30,"10":31,"11":30,"12":31}
        last_day = ld.get(mm, 30)
        days = (22, last_day)
    else:
        days = {"1st": (1, 7), "first": (1, 7),
                "2nd": (8, 14), "second": (8, 14),
                "3rd": (15, 21), "third": (15, 21),
                "4th": (22, 28), "fourth": (22, 28)}.get(ord_str.lower())
    if not days:
        return None
    return f"{yy}-{mm}-{days[0]:02d}", f"{yy}-{mm}-{days[1]:02d}"

_YEAR_MONTH_RE = re.compile(rf"\b(20\d{{2}})\s+({_MON_RE})\b", re.I)

def _parse_period(q, bare_month=True):
    """Deterministic period from the question text: (start, end) or None.
    Handles explicit dates, word-years, and relative dates (this/last month/year).
    bare_month=False skips the bare-month-name resolution  -  the slot extractor wants
    the raw month so a thread's carried YEAR can scope it ('in 2024' -> 'and in May?'
    must be May 2024, not the statement's latest May)."""
    q = _strip_cmp_amounts(_sub_word_years(q))
    wom = _week_of_month_period(q)
    if wom:
        return wom
    rel = _relative_period(q)
    if rel:
        return rel
    dr = _day_range_period(q)                          # yearless day range ("1 Jul to 3 Jul")
    if dr:
        return dr
    m = _RANGE_RE.search(q)
    if m:
        a, b = _norm_one(m.group(1)), _norm_one(m.group(2))
        if a and b:
            return a, b
    m = _SINGLE_RE.search(q)
    if m:
        one = _norm_one(m.group(0))
        if one:
            return one, ""
    # Fix: handle YEAR MONTH order  -  e.g. "in 2026 june" -> 2026-06
    m = _YEAR_MONTH_RE.search(q)
    if m:
        yr, mon = m.group(1), _mon_num(m.group(2))
        if yr and mon:
            ld = {"01":"31","02":"28","03":"31","04":"30","05":"31","06":"30",
                  "07":"31","08":"31","09":"30","10":"31","11":"30","12":"31"}
            return f"{yr}-{mon}-01", f"{yr}-{mon}-{ld.get(mon,'30')}"
    if bare_month:
        bdm = _bare_day_month_period(q)                # e.g. "1 jan", "jan 1st" -> single day
        if bdm:
            return bdm
        bm = _bare_month_period(q)                     # bare month name, no year
        if bm:
            return bm
    return None

_FACTUAL = ("spend", "summary", "income", "count", "category", "merchant", "balance", "breakdown")

_TABLE_RE = re.compile(r"\b(table|breakdown|month[- ]?wise|each month|monthly|by month|per month)\b", re.I)

_SAVINGS_RE = re.compile(
    r"\b(net position|net worth|net savings?|total savings?|overall savings?|my savings"
    r"|how much (?:did|have|money did) i save(?:d)?|how much i save(?:d)?)\b", re.I)

FOLLOWUP_SYSTEM = (
    "You are Penny, a finance assistant. Below is the recent conversation, including the exact "
    "answers already given. Answer the user's follow-up in ONE short sentence using ONLY the "
    "facts and figures already shown in that conversation. NEVER invent a number. If the answer "
    "isn't in the conversation, say you can look it up if they ask the question directly."
)

_NUM_MULT = {"crore": 1e7, "crores": 1e7, "cr": 1e7, "lakh": 1e5, "lakhs": 1e5,
             "lac": 1e5, "lacs": 1e5, "thousand": 1e3, "k": 1e3, "million": 1e6, "mn": 1e6}

_AMT_RE = re.compile(
    r"(?:Γé╣|₹)\s*([\d,]+(?:\.\d+)?)|\b(\d[\d,]*(?:\.\d+)?)\s*(crores?|cr|lakhs?|lacs?|lac|thousand|million|mn|k)\b",
    re.I)

_PCT_RE = re.compile(r"(\d+(?:\.\d+)?)\s*%")

CTX = {}        # {"type","start","end","category","merchant","n"}

_CAT_SYN = {
    "groceries": "Groceries", "grocery": "Groceries",
    "food": "Food & Dining", "dining": "Food & Dining", "restaurant": "Food & Dining",
    "restaurants": "Food & Dining", "eating out": "Food & Dining", "eat out": "Food & Dining",
    "dining out": "Food & Dining", "dine out": "Food & Dining", "takeaway": "Food & Dining",
    "takeaways": "Food & Dining", "take-away": "Food & Dining", "fast food": "Food & Dining",
    "transport": "Transport", "travel": "Transport", "commute": "Transport",
    "petrol": "Transport", "fuel": "Transport",
    "shopping": "Shopping",
    "utilities": "Utilities", "utility": "Utilities", "bills": "Utilities",
    "entertainment": "Entertainment",
    "healthcare": "Healthcare", "health": "Healthcare", "medical": "Healthcare",
    "investment": "Investment & Insurance", "investments": "Investment & Insurance",
    "insurance": "Investment & Insurance",
}

_CAT_STEMS = [
    ("entertain", "Entertainment"), ("grocer", "Groceries"), ("utilit", "Utilities"),
    ("transp", "Transport"), ("healthc", "Healthcare"), ("investm", "Investment & Insurance"),
    ("insuran", "Investment & Insurance"), ("shopp", "Shopping"), ("restaur", "Food & Dining"),
]

_GUARD_STOP = frozenset((
    "the", "a", "an", "all", "my", "me", "it", "them", "that", "this", "these", "those",
    "in", "of", "off", "out", "back", "up", "for", "by", "per", "with", "at", "from", "on", "to",
    "pay", "paid", "paying", "spend", "spent", "spending",
    "above", "below", "such", "said", "earlier", "prior",
    "each", "every", "any", "some", "one", "home", "work", "least", "most", "more", "less",
    "now", "today", "yesterday", "tomorrow", "moment", "last", "next", "past", "previous",
    "recent", "latest", "newest", "oldest", "top", "only", "day", "days", "week", "weeks", "weekend", "weekends", "weekday", "weekdays",
    "month", "months", "year", "years", "quarter", "monday", "tuesday", "wednesday",
    "thursday", "friday", "saturday", "sunday", "saving", "savings",
    "shopping", "buying", "anything", "something", "everything", "nothing", "stuff",
    "things", "average", "total", "credit", "debit", "card", "cards", "account", "accounts", "bank", "banks", "cash",
    "another", "other", "others", "category", "categories", "merchant", "merchants", "different", "difference",
    "what", "which", "how", "when", "where", "details", "detail", "statement", "statements", "transaction", "transactions", "txns", "txn", "payment", "payments"))

_BIG_RE = re.compile(r"\b(big+e?st|larg+e?st|highest|maximum|priciest|most expensive|dearest|sabse bada|sabse zyada)\b", re.I)

_SMALL_RE = re.compile(r"\b(smal{1,2}e?st|low+e?st|cheap+e?st|minimum|least expensive|sabse chota|sabse kam|sabse sasta)\b", re.I)

_ALLTIME_RE = re.compile(r"\ball[- ]?time\b|\boverall\b|\blifetime\b|\bever\b|\bin total\b|"
                         r"\b(?:whole|entire) (?:statement|account)\b", re.I)

_COUNT_X = re.compile(r"\bhow many\b|\bnumber of\b|\bno\.? of\b|\bcount\b|\bkitne\b|\btrans[ac]*ti(?:on|no|o|n)s?\b|\btxns?\b|\bpurchases?\b|\bhow much time\b|\bhow many times\b|\bhow often\b|\bhow much\s+(?:trans[ac]*ti(?:on|no|o|n)s?|txns?|purchases?)\b", re.I)

_TOP_RE = re.compile(r"\btop\s+(\d+)\b", re.I)

_LIST_RE = re.compile(
    r"\b(?:show|list|display|view|see|pull up|give me|let me see|what were|what was)\b[^?]*?"
    r"\b(trans[ac]*ti(?:on|no|o|n)s?|txns?|purchases?|payments?|entries|charges?|deposits?|recei?ve?d?|recie?ve?d?|incomes?|them|these|those|that|list|recent|latest|all|more|\d{1,3})\b", re.I)

_LIST_N_RE = re.compile(
    r"\b(\d{1,3})\s+(?:trans[ac]*ti(?:on|no|o|n)s?|txns?|purchases?|payments?|entries|charges?|deposits?)\b", re.I)

_WHICH_TXN_RE = re.compile(
    r"\b(?:which|what)\s+(?:are\s+|were\s+|was\s+|is\s+)?(?:the\s+|those\s+|these\s+)?"
    r"(?:\d{1,3}\s+)?(?:trans[ac]*ti(?:on|no|o|n)s?|txns?|purchases?|payments?|entries|charges?)\b", re.I)

_LIST_ENT_RE = re.compile(
    r"\b(?:show|list|display|view|see|pull up|give me|let me see)\s+(?:me\s+)?"
    r"([a-z0-9&'.\- ]+?)\s+"
    r"(?:trans[ac]*tion[s]?|txns?|purchases?|payments?|entries|charges?|deposits?)\b", re.I)

_LIST_STOP = frozenset((
    "all", "the", "my", "me", "these", "those", "last", "first", "recent", "latest", "newest", "oldest", "top", "only", "a", "an",
    "some", "any", "of", "them", "it", "new", "old", "total", "individual", "every", "each",
    "received", "recevied", "recieved", "receive", "credit", "debit", "spent", "spending", "payment", "payments"))

def _list_entity(low):
    """The merchant/entity named in a 'show me <X> transactions' listing, or None when only
    filler precedes the noun (a scopeless 'show me all transactions')."""
    m = _LIST_ENT_RE.search(low)
    if not m:
        # Fallback for "list of spent on <X>", "transactions at/from/on <X>", "spent on <X>"
        fm = re.search(r"\b(?:list of |show me |transactions? )(?:spent )?(?:on|at|from|to|for)\s+([a-z0-9&'.\- ]+)", low)
        if fm:
            cand = fm.group(1).strip()
            # Truncate at prepositions or clause starters
            cand = re.split(r"\b(?:in|on|during|for|last|this|the|over|between|per|by|if|any|bank|transaction)\b", cand)[0].strip()
            toks = [t for t in cand.split() if t]
            while toks and toks[0] in _LIST_STOP:
                toks.pop(0)
            if toks and not all(t in _LIST_STOP or t.isdigit() for t in toks):
                cand = " ".join(toks)
                if not (re.match(rf"(?:{_MON_RE})\b", cand) or cand in _GUARD_STOP):
                    return cand
        return None
    toks = [t for t in m.group(1).split() if t]
    while toks and toks[0] in _LIST_STOP:
        toks.pop(0)
    if not toks or all(t in _LIST_STOP or t.isdigit() for t in toks):
        return None
    cand = " ".join(toks)
    if re.match(rf"(?:{_MON_RE})\b", cand) or cand in _GUARD_STOP:
        return None                                    # a month/period word, not a merchant
    return cand

_BAL_RE = re.compile(r"\b(balance|left in (?:the )?(?:bank|account)|bacha)\b", re.I)

_SPEND_RE = re.compile(r"\b(spend|spent|spending|kharcha|kharch|blew|burn)\b", re.I)

_COMPLETE_Q = re.compile(r"\bhow much\b|\bhow many\b|\bhow often\b|\bwhat did i (?:spend|pay)\b"
                         r"|\bwhat'?s my\b|\bwhat is my\b|\btotal\b|\bpayments?\b|\bpaid\b", re.I)

_INCOME_RE2 = re.compile(r"\b(incom(?:e|ings)?|earn(?:ed|ings|t)?|salary|salaries|inflow|recei?ve?d?|recie?ve?d?)\b", re.I)

_EXP_CTXT = ("expense", "spend", "purchase", "transaction", "charge", "buy", "kharcha", "kharch")

_CONT_RE = re.compile(r"^\s*(and\b|also\b|plus\b|then\b|now\b|just\b|ok\b|okay\b|&|aur\b|phir\b|what about|how about|what'?s about)", re.I)

_REFS_RE = re.compile(r"\b(that|then|those|same|it)\b", re.I)

_KM = None

def _known_merchants():
    global _KM
    if _KM is None:
        con = ts.connect()
        _KM = sorted((r[0] for r in con.execute(
            "SELECT DISTINCT merchant FROM transactions WHERE merchant<>''") if r[0]),
            key=len, reverse=True)   # longest first so "Apollo Pharmacy" beats "Apollo"
        con.close()
    return _KM

_KC = None

def _known_categories():
    """Distinct category names in the data (cached)  -  incl. 'Other' / 'Income', which the
    synonym map doesn't cover."""
    global _KC
    if _KC is None:
        con = ts.connect()
        _KC = [r[0] for r in con.execute(
            "SELECT DISTINCT category FROM transactions WHERE category<>''") if r[0]]
        con.close()
    return _KC

def _reset_vocab():
    """The ledger was REPLACED (fresh /upload or a Plaid sync)  -  drop the cached
    merchant/category vocabulary so the router classifies against the NEW data, not
    the previous statement's names (stale names = wrong routing on every question)."""
    global _KM, _KC
    _KM, _KC = None, None

_CATLOOKUP_RE = re.compile(
    r"\bwhat(?:'s| is)?\s+(?:the\s+)?categor(?:y|ies)\b|\bwhich\s+categor(?:y|ies)\b|"
    r"\bcategor(?:y|ies)\s+(?:of|does|do|for|is|are)\b|"
    r"\bcategor(?:y|ies|ized|ised|ize|ise)\s+(?:as|under)\b|"
    r"\bwhat\s+(?:type|kind)\s+of\s+(?:spend|expense|transaction|payment|purchase)\b", re.I)

_DATELOOKUP_RE = re.compile(
    r"\bon\s+what\s+date\b|\bwhat\s+date\b|\bwhich\s+date\b|\bwhat\s+day\b|"
    r"\bwhen\s+(?:did|does|was|is|were)\b|\bdate(?:s)?\s+(?:does|do|of|for|did)\b", re.I)

_INTERVAL_RE = re.compile(
    r"\b(?:how many|number of|no\.?\s*of)?\s*days?\b[^?]*\b(?:between|separat\w*|apart|gap)\b|"
    r"\b(?:between|separat\w*|gap between|interval between|time between|days between)\b[^?]*"
    r"\b(?:payments?|transactions?|deposits?|credits?|charges?|visits?)\b|"
    r"\bhow\s+(?:often|frequently)\b[^?]*\b(?:pay|paid|payment|charge|deposit|transact)\b|"
    r"\baverage\s+(?:gap|interval)\b|\bpayment\s+frequency\b", re.I)

_WHOSENT_RE = re.compile(
    r"\bwho\s+(?:sent|paid|gave|deposited|credited|transferred|wired|remitted)\b|"
    r"\bwho\s+(?:is|are|was|were)\s+(?:my\s+)?(?:the\s+)?(?:payer|sender|income source)|"
    r"\bwhere\s+did\s+(?:the\s+|my\s+)?(?:┬ú|£|\$|Γé¼|€|Γé╣|₹|\d).*\bcome\s+from\b", re.I)

_BAL_DELTA_RE = re.compile(
    r"\bbalance\b[^?]*\b(?:chang|delta|move|increas|decreas|grow|grew|differ|rise|risen|rose|fell|fall|drop)\w*\b|"
    r"\b(?:chang|delta|increas|decreas|differ)\w*\b[^?]*\bbalance\b|"
    r"\bbalance\b[^?]*\bfrom\b[^?]*\bto\b|\bbalance\b[^?]*\bbetween\b[^?]*\band\b", re.I)

_BAL_BEFORE_RE = re.compile(
    r"\bbalance\b[^?]*\bbefore\b|\bbefore\b[^?]*\bbalance\b|\bbalance\b[^?]*\b(?:prior|preceding)\b", re.I)

_BAL_AFTER_RE = re.compile(
    r"\bbalance\b[^?]*\bafter\b|\bafter\b[^?]*\bbalance\b|\bbalance\b[^?]*\bfollowing\b", re.I)

_MONTHS_RE = re.compile(
    r"\b(?:distinct|different|how many|list(?:\s+of)?|number of|separate)\s+(?:calendar\s+)?months?\b|"
    r"\bcalendar\s+months?\b|\bmonths?\b\s+(?:are\s+)?(?:covered|present|available|in the (?:data|statement))\b", re.I)

def _amount_in(low):
    """A currency/number amount in the text, ignoring 4-digit years. None if absent."""
    m = re.search(r"(?:┬ú|£|\$|Γé¼|€|Γé╣|₹|rs\.?|inr|gbp|usd|eur|rupees?)\s*(\d[\d,]*(?:\.\d+)?)", low)
    if m:
        return float(m.group(1).replace(",", ""))
    m = re.search(r"\b(\d[\d,]*(?:\.\d+)?)\b", low)
    if m and not re.fullmatch(r"(?:19|20)\d\d", m.group(1).replace(",", "")):
        return float(m.group(1).replace(",", ""))
    return None

def _entity_after(low, markers):
    """The merchant-ish name that follows one of `markers` ('before'/'after'/...)."""
    for mk in markers:
        m = re.search(rf"\b{mk}\s+(?:the\s+|my\s+|a\s+)?(.+?)"
                      rf"(?:\s+(?:payment|transaction|txn|charge|deposit|on|in|for|dated|was|is)\b|[?.!,]|$)", low)
        if m:
            cand = m.group(1).strip(" '\"?.,")
            if cand:
                return cand
    return ""

def _norm_name(s):
    return re.sub(r"[^a-z0-9]+", " ", (s or "").lower()).strip()

def _levenshtein(s1, s2):
    if len(s1) < len(s2):
        return _levenshtein(s2, s1)
    if len(s2) == 0:
        return len(s1)
    previous_row = range(len(s2) + 1)
    for i, c1 in enumerate(s1):
        current_row = [i + 1]
        for j, c2 in enumerate(s2):
            insertions = previous_row[j + 1] + 1
            deletions = current_row[j] + 1
            substitutions = previous_row[j] + (c1 != c2)
            current_row.append(min(insertions, deletions, substitutions))
        previous_row = current_row
    return previous_row[-1]

def _resolve_merchant(phrase):
    """Map free text to a stored merchant, punctuation/suffix tolerant: 'Shein' ->
    'Shein.Com', 'Higgsfield Inc USA' -> 'Higgsfield Inc. USA'. Returns '' when nothing
    plausibly matches, so the caller gives an honest 'no transactions', never a total."""
    np = _norm_name(phrase)
    if not np:
        return ""
    toks = np.split()
    for m in _known_merchants():                       # exact (normalised) name wins alone
        if _norm_name(m) == np:
            return m
    for m in _known_merchants():                       # containment either way
        nm = _norm_name(m)
        if nm and (np in nm or nm in np):
            return m
    for m in _known_merchants():                       # all phrase tokens in the name
        if toks and set(toks).issubset(set(_norm_name(m).split())):
            return m
    for m in _known_merchants():                       # distinctive first token (>=4 chars)
        mt = _norm_name(m).split()
        if toks and mt and len(toks[0]) >= 4 and toks[0] == mt[0]:
            return m
    # character distance fuzzy fallback for common typos (like sweegy -> Swiggy)
    best, best_dist = None, 99
    for m in _known_merchants():
        dist = _levenshtein(np, _norm_name(m))
        if dist < best_dist and dist <= 2:
            best, best_dist = m, dist
    if best:
        return best
    return ""

def _merchant_candidates(phrase):
    """Distinct stored merchants the phrase could mean, for ambiguity detection: an exact
    (normalised) match is unambiguous; otherwise all merchants CONTAINING the phrase
    ("apple" -> Apple Store, Apple Pay). Resolution itself stays with _resolve_merchant  - 
    this list only decides whether to ASK instead of guessing."""
    np_ = _norm_name(phrase)
    if not np_:
        return []
    exact = [m for m in _known_merchants() if _norm_name(m) == np_]
    if exact:
        return exact[:1]
    return [m for m in _known_merchants() if np_ in _norm_name(m)][:4]

_ORDINAL = {"first": 0, "1st": 0, "second": 1, "2nd": 1, "third": 2, "3rd": 2,
            "fourth": 3, "4th": 3, "fifth": 4, "5th": 4, "last": -1}

def _clarify_choice(q, options):
    """Resolve a reply to a pending clarification into the chosen option, or None when the
    reply isn't a pick (so the caller treats it as a brand-new question). Accepts a name
    ('Loans 2 Go'), a bare number ('2', 'option 2'), or an ordinal ('the first', 'last')."""
    if not options:
        return None
    low = q.lower().strip().rstrip("?.! ")
    # a NAME match first, so "Loans 2 Go" picks by name and not the digit inside it
    for o in options:
        ol = o.lower()
        if low == ol or (len(low) >= 3 and (low in ol or ol in low)):
            return o
    # a reply that is JUST a number ("2", "option 2", "#2", "number 3")
    m = re.fullmatch(r"(?:option\s*|no\.?\s*|#\s*|number\s*|the\s*)?(\d{1,2})", low)
    if m:
        i = int(m.group(1)) - 1
        return options[i] if 0 <= i < len(options) else None
    # ordinal words ("the first", "second one", "last")
    for w, i in _ORDINAL.items():
        if re.search(r"\b" + w + r"\b", low):
            idx = i if i >= 0 else len(options) - 1
            return options[idx] if 0 <= idx < len(options) else None
    # a distinctive token (>=4 chars) shared with EXACTLY one option
    hits = [o for o in options if any(t in o.lower().split() for t in low.split() if len(t) >= 4)]
    return hits[0] if len(hits) == 1 else None

def _sub_clarify(orig, phrase, choice):
    """Rebuild the original question with the chosen entity in place of the ambiguous phrase,
    so the SAME metric/period is answered ('how many <deposit> txns' -> '... SAVINGS DEPOSIT ...')."""
    if phrase and re.search(re.escape(phrase), orig, flags=re.I):
        return re.sub(re.escape(phrase), choice, orig, count=1, flags=re.I)
    return f"how much did I spend at {choice}?"

def _lookup_entity(q):
    """Pull the name a lookup question is about, from the sentence structure."""
    low = q.lower()
    for pat in (
        r"categor(?:y|ies)\s+(?:does|do|of|for|is|are)\s+(.+?)\s+(?:belong|fall|come|classif|go|categor)",
        r"categor(?:y|ies)\s+(?:does\s+)?(.+?)\s+(?:lie|lies|fall|falls|belong|belongs|sit|sits|come[s]?\s+under|classif)",
        r"categor(?:y|ies)\s+(?:does|do|of|for|is|are)\s+(.+?)[?.!]*$",
        r"(?:on\s+what\s+date|what\s+date|which\s+date|what\s+day|when)\s+(?:does|do|did|is|was|were)\s+(.+?)\s+(?:appear|occur|happen|show|come|made?|pays?|paid|charge|fall|list)",
        r"(?:date|day)s?\s+(?:does|do|of|for|did)\s+(.+?)\s+(?:appear|occur|happen|show|fall)",
        r"\b(?:between|separat\w*|consecutive|gap between|interval between)\s+(.+?)\s+(?:payments?|transactions?|deposits?|credits?|charges?|visits?)",
        r"how\s+(?:often|frequently)\b.*?\b(?:pay|paid|to)\s+(?:the\s+)?(.+?)[?.!]*$",
    ):
        m = re.search(pat, low)
        if m:
            cand = m.group(1).strip(" '\"?.,")
            cand = re.sub(r"^(?:the|a|an|my|any|each|all|two|these|those|consecutive)\s+", "", cand)
            if cand:
                return cand
    return ""

def _special_intent(q):
    """A self-contained fine-grained intent as a dict ('type' + any of merchant/amount/
    date1/date2), or None. Merchant lookups fire only when a real merchant resolves and
    balance min/max needs a low/high modifier  -  so ordinary questions stay dormant.
    Merchant keywords are the user's PHRASE (matched token-wildcard by the SQL helpers,
    spanning label variants like 'Piyush Mishra' vs 'Piyush Mishra & PA')."""
    low = q.lower()
    if _WHOSENT_RE.search(low):                                     # who sent/paid me [┬úX]
        return {"type": "who_paid", "amount": _amount_in(low)}
    if _BAL_DELTA_RE.search(low):                                   # balance change between two dates
        ds = _find_periods(q)
        if len(ds) >= 2:
            return {"type": "balance_delta", "date1": ds[0], "date2": ds[1]}
    mb, ma = _BAL_BEFORE_RE.search(low), _BAL_AFTER_RE.search(low)
    if mb or ma:                                                    # balance before/after a txn
        ent = _entity_after(low, ("before", "after", "preceding", "following", "prior to"))
        m = _resolve_merchant(ent) or ent
        if m and not re.fullmatch(r"[\d,.]+", m):                   # a name, not a number
            return {"type": "balance_before" if mb else "balance_after", "merchant": m}
    if _INTERVAL_RE.search(low):
        ent = _lookup_entity(q)
        if _resolve_merchant(ent):
            return {"type": "merchant_interval", "merchant": ent}
    if _CATLOOKUP_RE.search(low):
        ent = _lookup_entity(q)
        if _resolve_merchant(ent):
            return {"type": "merchant_category", "merchant": ent}
    if _DATELOOKUP_RE.search(low):
        dd = ("last" if re.search(r"\b(last|latest|most recent(?:ly)?|recently)\b", low)
              else "first" if re.search(r"\b(first|earliest)\b", low) else "")
        ent = _lookup_entity(q)
        if _resolve_merchant(ent):
            return {"type": "merchant_date", "merchant": ent, "date_dir": dd}
        # the sentence patterns missed it ("what date did my Sky bill go out?", "when did
        # I last shop at Aldi?") -> take the at/from/on entity, else any stored merchant
        # named in the question. Skipped when a superlative is present  -  those are
        # largest/smallest lookups ("when did I spend the most at Tesco"), not date lists.
        if not (_BIG_RE.search(q) or _SMALL_RE.search(q) or re.search(r"\b(most|least)\b", low)):
            ent = _entity_after(low, ("at", "from", "on"))
            m = _resolve_merchant(ent)
            if not m:
                for km in _known_merchants():
                    if re.search(r"\b" + re.escape(km.lower()) + r"\b", low):
                        m = km
                        break
            if m:
                return {"type": "merchant_date", "merchant": m, "date_dir": dd}
    if _MONTHS_RE.search(low):                                      # distinct calendar months
        return {"type": "months"}
    if _BAL_RE.search(low):
        if _SMALL_RE.search(low) or re.search(r"\b(low|lowest|minimum|min)\b", low):
            return {"type": "balance_min"}
        if _BIG_RE.search(low) or re.search(r"\b(high|highest|maximum|max|peak)\b", low):
            return {"type": "balance_max"}
    return None

_SPECIAL_INTENTS = frozenset({
    "who_paid", "balance_before", "balance_after", "balance_delta", "months",
    "merchant_category", "merchant_date", "merchant_interval", "balance_min", "balance_max"})

def _special_factual(s):
    """Build the intent dict for a self-contained special intent  -  period from THIS turn's
    own text only (never inherits a prior turn's scope), plus any amount/date payloads."""
    start, end = "", ""
    if s.get("period_full"):
        start, end = s["period_full"]
    elif s.get("pmonth") and s.get("pday"):
        start = f"MD-{s['pmonth']}-{s['pday']}"
    elif s.get("pmonth"):                       # bare month -> the statement's year
        y = _year_for_month(s["pmonth"])
        start = f"{y}-{s['pmonth']}" if y else ""
    return {"type": s["type"], "merchant": s.get("merchant", ""), "category": "",
            "start": start, "end": end, "n": 0, "count_kind": "", "table": False,
            "amount": s.get("amount"), "date1": s.get("date1"), "date2": s.get("date2"),
            "date_dir": s.get("date_dir", "")}

def _extract_slots(q):
    low = q.lower()
    merch = ""
    # the LONGEST matching stored name wins, so "JD Sports" is picked over the separate
    # merchant "Sports" (a sub-name of it)  -  not whichever happens to come first.
    _mhits = [m for m in _known_merchants()
              if re.search(r"\b" + re.escape(m.lower()) + r"\b", low)]
    if _mhits:
        merch = max(_mhits, key=lambda x: len(x.lower()))
    if not merch:
        # truncation-tolerant: a multi-word stored name (possibly cut off by the statement's
        # narrow column, e.g. "Putney Cricket Clu") that appears as a normalised substring of
        # the query ("...Putney Cricket Club"). Length + multi-word guarded so short single
        # names can't false-match; longest-first so the fullest name wins.
        nlow = re.sub(r"[^a-z0-9]+", " ", low)
        for m in _known_merchants():
            nm = _norm_name(m)
            if " " in nm and len(nm) >= 8 and nm in nlow:
                merch = m
                break
    cat = ""
    if not merch:
        for kw, c in _CAT_SYN.items():
            if re.search(r"\b" + kw + r"\b", low):
                cat = c
                break
    if not merch and not cat:
        # canonical category names (incl. 'Other'/'Income'), case-insensitive exact word.
        # The generic ones need a category context so "other" as filler can't false-match.
        for c in _known_categories():
            cl = c.lower()
            if cl in ("other", "income"):
                # 'other'/'income' double as filler words, so require a real category context:
                # the word 'category', or 'on <cat>', or '<cat> spending/expenses'.
                if re.search(rf"\b{re.escape(cl)}\b", low) and (
                        re.search(r"categor", low)
                        or re.search(rf"\bon\s+{re.escape(cl)}\b", low)
                        or re.search(rf"\b{re.escape(cl)}\s+(?:spend\w*|expenses?|expenditure|txns?|transactions?)\b", low)):
                    cat = c
                    break
            elif re.search(rf"\b{re.escape(cl)}\b", low):
                cat = c
                break
    if not merch and not cat:                        # typo-tolerant category fallback
        for stem, c in _CAT_STEMS:
            if re.search(rf"\b{stem}\w*", low):
                cat = c
                break
    # bank/service fees aren't a category or a stored merchant name  -  search them as a
    # merchant keyword (merchant_spend also matches descr), so the answer is the real fee
    # total or an honest "no transactions found", never the account-wide spend.
    if not merch and not cat:
        fm = re.search(r"\b(bank|account|service|overdraft|late|card)[- ](fees?|charges?)\b", low)
        if fm:
            merch = f"{fm.group(1)} {fm.group(2)}".rstrip("s")
    # honesty guard: an explicit "at/from/on <Name>" that is NOT a known merchant or
    # category -> treat as that merchant (resolved if it's a truncated real one), so dispatch
    # answers about the right merchant, or an honest "no transactions found for X"  -  never
    # the account-wide total ("how much did I spend on <unknown>" must not read as ALL spend).
    if not merch and not cat:
        um = re.search(r"\b(?:at|from|on|to|with|in|pay(?:ing)?|paid)\s+(?:to\s+|the\s+|my\s+|an?\s+)?"
                       r"([a-z][a-z0-9&'.\-]*(?:\s+[a-z0-9&'.\-]+){0,2}?)"
                       r"(?:\s+(?:in|on|during|for|last|this|the|over|between|per|by)\b|[?.!,]|$)", low)
        if um:
            cand = um.group(1).strip()
            first = cand.split()[0] if cand else ""
            if cand and cand not in _CAT_SYN and first not in _GUARD_STOP \
                    and not re.match(rf"(?:{_MON_RE})\b", cand) \
                    and not cand.endswith((" more", " less")):
                cands = _merchant_candidates(cand)
                if len(cands) >= 2:
                    # the phrase genuinely matches several stored merchants ("apple" ->
                    # Apple Store, Apple Pay)  -  ask instead of silently picking one.
                    return {"type": "clarify", "options": cands, "phrase": cand,
                            "period_full": None, "pmonth": "", "pday": "", "prange": None,
                            "category": "", "merchant": "", "n": 0, "count_kind": ""}
                merch = _resolve_merchant(cand) or cand
    pf = _parse_period(q, bare_month=False)   # raw month kept below so a carried year applies
    pmonth = pday = ""
    prange = None
    if not pf:
        # bare "July to December" (no year)  -  carry the year to both bounds later
        mr = re.search(rf"\b({_MON_RE})\b\s*(?:to|till|until|through|thru|[--]|and)\s*\b({_MON_RE})\b", low)
        if mr:
            prange = (_mon_num(mr.group(1)), _mon_num(mr.group(2)))
        else:
            mm = re.search(rf"\b({_MON_RE})\b", low)
            if mm:
                pmonth = _mon_num(mm.group(1))
                # a day number adjacent to the month, even WITHOUT an ordinal ("15 august")
                dm = re.search(rf"\b(\d{{1,2}})\s+{re.escape(mm.group(1))}\b|"
                               rf"\b{re.escape(mm.group(1))}\s+(\d{{1,2}})\b", low)
                if dm:
                    pday = f"{int(dm.group(1) or dm.group(2)):02d}"
            dd = re.search(r"\b(\d{1,2})(?:st|nd|rd|th)\b", low)
            if dd:
                pday = f"{int(dd.group(1)):02d}"
    # fine-grained lookup intents win over the generic ladder (period still applies)
    sp = _special_intent(q)
    if sp:
        return {"type": sp["type"], "period_full": pf, "pmonth": pmonth, "pday": pday,
                "prange": prange, "category": "", "merchant": sp.get("merchant", ""),
                "n": 0, "count_kind": "", "amount": sp.get("amount"),
                "date1": sp.get("date1"), "date2": sp.get("date2"),
                "date_dir": sp.get("date_dir", "")}
    topm = _TOP_RE.search(q)
    has_exp = any(w in low for w in _EXP_CTXT)
    has_cr = bool(_INCOME_RE.search(low) or re.search(r"\b(deposit|credit)\b", low))
    t = None
    if _BIG_RE.search(q) and has_cr and not has_exp:    # "largest deposit/credit"
        t = "largest_income"
    elif _BIG_RE.search(q) and has_exp:        # "largest transaction" before count
        t = "largest_expense"
    elif _SMALL_RE.search(q) and has_exp:
        t = "smallest_expense"
    elif _COUNT_X.search(q):
        t = "count"
    elif _INCOME_RE2.search(q):
        t = "income"
    elif has_cr and not _COUNT_X.search(q):   # "total credit amount", "credit balance", etc.
        t = "income"
    elif _BAL_RE.search(q):
        t = "balance"
    elif topm:
        t = "top_expenses"
    elif merch:
        t = "merchant"
    elif cat:
        t = "category"
    elif re.search(r"\bcategor(?:y|ies)\b|\bspending\s+breakdown\b", low):
        t = "category"                    # no specific category named -> the full table
    elif _SPEND_RE.search(q):
        t = "spend"
    elif _BIG_RE.search(q):           # bare "and the biggest?" continuation
        t = "largest_expense"
    elif _SMALL_RE.search(q):
        t = "smallest_expense"
    # an explicit "show me / list the transactions" LISTS the rows  -  overrides a plain
    # count/spend/merchant/category (a named merchant/category stays as a scope), but never
    # hijacks a real count ("how many") or an extreme. "show me top N transactions" is the
    # N largest, so it stays a top-N, not a chronological list.
    list_n = 0
    if (_LIST_RE.search(q) or _WHICH_TXN_RE.search(q) or re.search(r"\bdetails?\b", low)) \
            and t in (None, "count", "spend", "merchant", "category", "income") \
            and not re.search(r"\bhow many\b|\bnumber of\b|\bno\.? of\b|\bcount\b", low):
        if topm:
            t = "top_expenses"
        else:
            t = "list"
            mn = _LIST_N_RE.search(low) or re.search(r"\b(?:only|top|latest|first|last|limit|recent|next|another|more|show|list)\s*(\d{1,3})\b", low)
            list_n = int(mn.group(1)) if mn else 0
            # Detect "all" keyword -> unlimited fetch
            if re.search(r"\b(all|every|everything|complete|full)\b", low):
                list_n = "all"
            if not merch and not cat:              # an unknown named entity -> honest "none",
                ent = _list_entity(low)            # never a silent list of the whole ledger
                if ent:
                    merch = _resolve_merchant(ent) or ent
    ckind = ""
    if t == "count":
        if re.search(r"\bupi\b", low):
            ckind = "upi"
        elif re.search(r"\bcard\b|\bvisa\b|\bpos\b", low):
            ckind = "card"
        elif re.search(r"\b(credit|deposit)\b", low) or _INCOME_RE.search(low):
            ckind = "credit"
        elif re.search(r"\b(debit|spend|spent|expense|payment|paid|purchase|withdrawal)\b", low):
            ckind = "debit"
    # Extract page number: "page 2", "page two", etc.
    page_m = re.search(r"\bpage\s+(\d+)\b", low)
    page_num = int(page_m.group(1)) if page_m else 1
    return {"type": t, "period_full": pf, "pmonth": pmonth, "pday": pday, "prange": prange,
            "category": cat, "merchant": merch,
            "n": (int(topm.group(1)) if topm else list_n),
            "page": page_num,
            "count_kind": ckind}

def _resolve_factual(q, ctx):
    """Deterministically resolve a factual money query, carrying missing slots from
    the THREAD's ctx for elliptical follow-ups. Returns an intent dict, or None
    (let the LLM handle smalltalk / help / advice / summary / coverage / etc.)."""
    low = q.lower()
    if _ADVICE_RE.search(q) or _REASON_RE.search(q) or _WHY_RE.search(q) or "plan" in low:
        return None

    s = _extract_slots(q)
    if s.get("type") == "clarify":             # ambiguous merchant  -  ask, don't guess
        return {"type": "clarify", "options": s["options"], "phrase": s["phrase"]}
    if s.get("type") in _SPECIAL_INTENTS:      # self-contained; no stale scope inherited
        return _special_factual(s)
    cont = bool(_CONT_RE.search(q))
    refs = bool(_REFS_RE.search(q)) and not s["period_full"]
    low = q.lower()
    alltime = bool(_ALLTIME_RE.search(low)) and not s["period_full"] \
        and not (s["pmonth"] or s["pday"] or s["prange"])   # don't let "overall" drop a date
    # "and the whole year?" / "the entire year" -> widen the thread's period to its full
    # year while KEEPING the carried category/merchant (don't fall through to the LLM).
    whole_year = bool(re.search(r"\b(?:whole|entire|full|complete|rest of the)\s+year\b"
                                r"|\bfor the (?:whole |entire |full )?year\b|\ball year\b", low)) \
        and not s["period_full"]
    has_new = any([s["type"], s["category"], s["merchant"], s["period_full"],
                   s["pmonth"], s["pday"], s["prange"], alltime, whole_year])
    if not has_new:
        return None

    t = s["type"]
    if not t and ctx:
        t = ctx.get("type")
    # a lone period with NO metric anywhere ("what about June?", "and 2024?") defaults to
    # spend  -  the app's most common question  -  instead of falling to the LLM, which guesses
    # (e.g. "highest month"). Only fires when neither this turn nor the thread has a metric,
    # so metric-carrying follow-ups are untouched.
    if not t and (s["period_full"] or s["pmonth"] or s["pday"] or s["prange"]):
        t = "spend"
    # a named merchant/category sets the metric to merchant/category  -  UNLESS the
    # question is an explicit count ("how many at Amazon" stays a count-of-Amazon).
    _KEEP_TYPE = ("count", "income", "largest_expense", "smallest_expense", "largest_income",
                  "merchant_category", "merchant_date", "merchant_interval",
                  "balance_min", "balance_max", "list")
    if s["merchant"] and t not in _KEEP_TYPE:
        t = "merchant"
    elif s["category"] and t not in _KEEP_TYPE:
        t = "category"
    if not t:
        return None

    _cs = ctx.get("start", "") if ctx else ""
    cy = _cs[:4] if _cs[:4].isdigit() else ""        # carried year (guards MD-/empty markers)
    cym = _cs[:7] if (len(_cs) >= 7 and cy) else (cy + "-01" if cy else "")
    if s["period_full"]:
        start, end = s["period_full"]
    elif whole_year and cy:
        start, end = cy, ""               # widen the thread's period to its full year
    elif alltime:
        start, end = "", ""               # explicit "all time" / "overall" reset
    elif s["prange"] and cy:
        start, end = f"{cy}-{s['prange'][0]}", f"{cy}-{s['prange'][1]}"
    elif s["prange"]:                     # bare "July to December" (no year) -> the data's year(s)
        y0, y1 = _year_for_month(s["prange"][0]), _year_for_month(s["prange"][1])
        start, end = (f"{y0}-{s['prange'][0]}", f"{y1}-{s['prange'][1]}") if (y0 and y1) else ("", "")
    elif s["pmonth"] and s["pday"]:       # explicit day-and-month -> a full calendar date
        start, end = (f"{cy}-{s['pmonth']}-{s['pday']}" if cy
                      else f"MD-{s['pmonth']}-{s['pday']}"), ""   # no year -> that day, all years
    elif s["pmonth"] and cy:
        start, end = f"{cy}-{s['pmonth']}", ""
    elif s["pmonth"]:                     # bare month ("in May", "August") with no carried year
        y = _year_for_month(s["pmonth"])  # -> the statement's year, so it scopes (not all-time)
        start, end = (f"{y}-{s['pmonth']}", "") if y else ("", "")
    elif s["pday"] and cym:
        start, end = f"{cym}-{s['pday']}", ""
    elif t in ("largest_expense", "smallest_expense", "largest_income", "top_expenses"):
        # non-metric "whole-picture" intents default ACCOUNT-WIDE when this turn names no
        # date  -  so a stale period from a prior turn can't silently scope "the largest debit"
        # to last month. (No-op on a fresh thread; the safer failure mode.)
        start, end = "", ""
    else:
        # No period in THIS question -> inherit the thread's period (all-time if the
        # thread has none). This is the markerless context-carry, made safe by the
        # thread model: a fresh thread has no period to carry.
        start, end = ctx.get("start", ""), ctx.get("end", "")
        # ...but a stale scope never applies to a turn that NAMES its own entity and isn't an
        # explicit continuation. Two cases:
        #   ΓÇó a carried DAY / day-RANGE scope  -  always dropped for ANY entity turn (a day
        #     lookup is a one-off; "IKEA" after "1-3 July" is IKEA all-time, not in those days);
        #   ΓÇó a carried MONTH / YEAR scope  -  dropped only when the turn is a COMPLETE question
        #     ("How much did I spend on Bupa?"), which is a fresh query and must not silently
        #     inherit a month set turns ago (the real user protested "I am not asking for July").
        # A bare fragment ("on transport?") keeps a month scope; continuations/back-references
        # ("and Bupa?", "what about that?") keep any scope.
        _complete_q = bool(_SPEND_RE.search(q) or _COMPLETE_Q.search(low))
        if (s["merchant"] or s["category"]) and not (cont or refs) \
                and (start.startswith("MD-") or len(start) == 10 or (_complete_q and start)):
            start = end = ""

    cat, mer = s["category"], s["merchant"]
    if t == "category" and not cat and ctx:
        cat = ctx.get("category", "")
    if t == "merchant" and not mer and ctx:
        mer = ctx.get("merchant", "")
    # "show me the transactions" is an elliptical listing  -  inherit the thread's merchant/
    # category so it lists THAT scope's rows ("IKEA" -> "show me all 3 transactions"), not
    # the whole account. But a listing turn that names its OWN fresh period and isn't an
    # explicit continuation ("1 July to 3 July" after browsing IKEA) is a standalone range
    # listing, not IKEA-in-that-range  -  don't drag the stale merchant into it.
    if t == "list" and ctx and not (s["merchant"] or s["category"]):
        turn_period = bool(s["period_full"] or s["pmonth"] or s["pday"] or s["prange"])
        if cont or refs or not turn_period:
            mer = mer or ctx.get("merchant", "")
            cat = cat or ctx.get("category", "")
    # an extreme follow-up that refers to the carried set inherits it: either a BARE
    # continuation with no expense noun ("and the biggest?") OR an explicit REFERENTIAL
    # phrasing ("which one was the biggest purchase?", "the biggest one", "of those")  -  even
    # with an expense noun, because "which one" clearly points back at the thread's topic.
    # A standalone "what's my biggest expense?" (no referential cue) stays account-wide
    # (the c011bdc standalone rule), and a scoped answer keeps ctx.merchant for the next turn.
    _extreme_ref = bool(
        (re.search(r"\b(?:which|what)\b", low) and re.search(r"\bone\b|\bof\s+(?:those|these|them)\b", low))
        or re.search(r"\bthe\s+\w+\s+one\b", low))
    if t in ("largest_expense", "smallest_expense") and not mer and not cat and ctx \
            and (cont or refs or _extreme_ref or not any(w in low for w in _EXP_CTXT)):
        if ctx.get("merchant"):
            mer = ctx["merchant"]
        elif ctx.get("category"):
            cat = ctx["category"]
    # a bare "how many transactions?" inside a merchant/category thread (nothing new
    # but the count itself) stays scoped to that merchant/category.
    own_period = bool(s["period_full"] or s["pmonth"] or s["pday"] or s["prange"] or whole_year)
    # topic stickiness: a bare metric (spend/count) inside a merchant/category thread
    # inherits that scope  -  on an explicit continuation ("and how much?") or a
    # back-reference ("how much was that?"). A markerless COMPLETE question ("how much
    # did I spend?") is account-wide: the entity set turns ago must not scope it (the
    # same standalone-question rule the R13 suite case pins for metric questions).
    # The PERIOD still carries on markerless turns (else-branch above)  -  that part of
    # the thread model is suite-tested and unchanged.
    if t in ("spend", "count") and not mer and not cat and ctx and (cont or refs):
        if ctx.get("merchant"):
            mer = ctx["merchant"]
            if t == "spend":
                t = "merchant"
        elif ctx.get("category"):
            cat = ctx["category"]
            if t == "spend":
                t = "category"
    n = s["n"] or (ctx.get("n", 0) if (cont and t == "top_expenses") else 0)
    txn_type = ("credit" if _INCOME_RE.search(low) or re.search(r"\b(credit|deposit)\b", low)
                else "debit" if re.search(r"\b(debit|spend|spent|expense|payment|paid|purchase|withdrawal)\b", low) else "")
    if not txn_type and ctx:
        txn_type = ctx.get("txn_type", "")
    page_m = re.search(r"\bpage\s+(\d+)\b", low)
    page_num = int(page_m.group(1)) if page_m else 1
    return {"type": t, "category": cat, "merchant": mer, "n": n,
            "start": start, "end": end, "table": bool(_TABLE_RE.search(q)),
            "count_kind": s.get("count_kind", ""), "txn_type": txn_type,
            "page": page_num}

def _save_ctx(ctx, intent):
    for k in ("type", "start", "end", "category", "merchant", "txn_type"):
        ctx[k] = intent.get(k, "")
    ctx["n"] = intent.get("n", 0)
    new_entity = ctx.get("merchant") or ctx.get("category")
    if new_entity:
        prev = list(ctx.get("prev_entities") or [])
        if not prev or prev[-1] != new_entity:
            prev.append(new_entity)
            if len(prev) > 5:
                prev.pop(0)
            ctx["prev_entities"] = prev

@dataclass
class ConversationState:
    topic: str = ""            # legacy `type`: merchant|category|count|spend|...
    merchant: str = ""
    category: str = ""
    txn_type: str = ""         # debit|credit|income
    payment_mode: str = ""     # upi (cash/card are not separable in statement data)
    account: str = ""          # doc_name scope (multi-statement)
    start: str = ""            # period start  (YYYY | YYYY-MM | YYYY-MM-DD)
    end: str = ""              # period end
    metric: str = ""           # spend|count|average|extreme|trend|breakdown|top|compare
    filters: dict = field(default_factory=dict)      # {"weekend":True, "txn_type":"debit"}
    comparison: list = field(default_factory=list)   # entities last compared
    sort: str = ""
    limit: int = 0             # legacy `n`
    prev_route: str = ""
    prev_query: str = ""
    prev_entities: list = field(default_factory=list)
    prev_answer: str = ""

    @staticmethod
    def _to_int(v):
        # ctx["n"] may hold the sentinel "all" (unlimited list) — treat any
        # non-numeric value as "no explicit limit".
        try:
            return int(v)
        except (TypeError, ValueError):
            return 0

    @classmethod
    def from_ctx(cls, ctx):
        c = ctx or {}
        return cls(
            topic=c.get("type", "") or "", merchant=c.get("merchant", "") or "",
            category=c.get("category", "") or "", txn_type=c.get("txn_type", "") or "",
            payment_mode=c.get("payment_mode", "") or "", account=c.get("account", "") or "",
            start=c.get("start", "") or "", end=c.get("end", "") or "",
            metric=c.get("metric", "") or "", filters=dict(c.get("filters") or {}),
            comparison=list(c.get("comparison") or []), sort=c.get("sort", "") or "",
            limit=cls._to_int(c.get("n") or c.get("limit") or 0),
            prev_route=c.get("prev_route", "") or "", prev_query=c.get("prev_query", "") or "",
            prev_entities=list(c.get("prev_entities") or []), prev_answer=c.get("prev_answer", "") or "")

    def to_ctx(self, ctx):
        """Mutate `ctx` in place  -  keep legacy keys for backward compat, add new ones."""
        ctx["type"] = self.topic; ctx["merchant"] = self.merchant
        ctx["category"] = self.category; ctx["start"] = self.start; ctx["end"] = self.end
        ctx["n"] = self.limit
        ctx["txn_type"] = self.txn_type; ctx["payment_mode"] = self.payment_mode
        ctx["account"] = self.account; ctx["metric"] = self.metric
        ctx["filters"] = self.filters; ctx["comparison"] = self.comparison
        ctx["sort"] = self.sort; ctx["limit"] = self.limit
        ctx["prev_route"] = self.prev_route; ctx["prev_query"] = self.prev_query
        ctx["prev_entities"] = self.prev_entities; ctx["prev_answer"] = self.prev_answer
        return ctx

    @property
    def entity(self):
        return self.merchant or self.category

def _period_phrase(start, end=""):
    """Human period text for query rewriting, re-parseable by the SAME parsers the engines
    use: 'in 2024' / 'in May 2024' / 'on YYYY-MM-DD' / 'between A and B' round-trip through
    `_parse_period`; a yearless `MD-MM-DD` marker renders as 'on <D> <Mon>', which
    `_extract_slots` re-reads as that day across all years (fixes the old 'in MD-12-19')."""
    if not start:
        return ""
    if start.startswith("MD-"):                      # yearless day: 'MD-12-19' -> 'on 19 Dec'
        mm, dd = start[3:5], start[6:8]
        return f"on {int(dd)} {ts.MONTHS.get(mm, mm)}"
    if end:
        return f"between {ts._plabel(start)} and {ts._plabel(end)}"
    n = len(start)
    if n == 7:
        return f"in {ts._mlabel(start)}"
    if n == 10:                                      # full date -> 'on 27 Mar 2026'
        return f"on {int(start[8:10])} {ts.MONTHS.get(start[5:7], start[5:7])} {start[:4]}"
    return f"in {start}"                              # year: 'in 2024'

_METRIC_RE = re.compile(
    r"\b(average|avg|mean|highest|biggest|largest|max(?:imum)?|priciest|lowest|smallest|min(?:imum)?|"
    r"cheapest|monthly|month[- ]?wise|breakdown|by month|trend|trending|top\s*\d*|total|sum|count|"
    r"how many|compare|comparison|versus|\bvs\b|percentage|share|proportion)\b", re.I)

_FILTER_RE = re.compile(
    r"\b(weekend|weekends|weekday|weekdays|only (?:on )?(?:debit|credit)|(?:debit|credit) only|"
    r"just (?:debit|credit))\b", re.I)

_CMP_WORD_RE = re.compile(r"\b(compare|comparison|versus|\bvs\b|against)\b", re.I)

_ARGMAX_ENT_RE = re.compile(
    r"\bwhich\s+(?:merchant|payee|store|shop|vendor|person|category|place)\b|"
    r"\bwhat\s+(?:merchant|store|category)\b", re.I)

_RESET_RE = re.compile(
    r"\b(reset(?:\s+context)?|start over|starting over|new (?:chat|conversation|topic)|"
    r"forget (?:that|it|this|context|everything|all that)|never ?mind|"
    r"clear (?:the )?(?:context|chat|conversation)|fresh start|change (?:the )?topic)\b", re.I)

_SCOPE_CLEAR_RE = re.compile(
    r"\b(overall|in total|all[- ]time|everything|across (?:all|everything|the (?:account|statement))|"
    r"(?:entire|whole) (?:account|statement)|all merchants|all categories|for all|account[- ]wide)\b", re.I)

_NO_ENTITY_INJECT_RE = re.compile(
    r"\b(income|salary|salaries|earn\w*|\bcredit\b|deposit\w*|balance|net worth|inflow|recei?ve?d?|recie?ve?d?|"
    r"savings? rate|runway|health|risk|net position)\b", re.I)

_CANON = [
    (re.compile(r"^\s*(?:what'?s|what is|show|give me|tell me)?\s*(?:the|my)?\s*(?:average|avg|mean)"
                r"(?:\s+(?:amount|value|transaction|spend(?:ing)?|txn|per (?:transaction|txn|order)))?\s*\??$", re.I),
     "average transaction"),
    (re.compile(r"^\s*(?:and|what about|the)?\s*(?:highest|biggest|largest|max(?:imum)?|priciest|"
                r"most expensive|dearest)(?:\s+(?:one|expense|transaction|txn|amount|spend))?\s*\??$", re.I),
     "biggest expense"),
    (re.compile(r"^\s*(?:and|what about|the)?\s*(?:lowest|smallest|min(?:imum)?|cheapest|"
                r"least expensive)(?:\s+(?:one|expense|transaction|txn|amount))?\s*\??$", re.I),
     "smallest expense"),
    (re.compile(r"^\s*(?:and|the)?\s*(?:monthly|month[- ]?wise|by month|per month|breakdown|"
                r"monthly breakdown|month[- ]wise breakdown)\s*\??$", re.I), "monthly breakdown"),
    (re.compile(r"^\s*(?:and|the)?\s*(?:trend|trends|trending|how(?:'s| is) it trending)\s*\??$", re.I),
     "spending trend"),
    (re.compile(r"^\s*(?:and|the)?\s*total\s*\??$", re.I), "total spending"),
    (re.compile(r"^\s*(?:and|the)?\s*(?:count|how many|number of (?:them|transactions)?)\s*\??$", re.I),
     "how many transactions"),
    (re.compile(r"^\s*(?:show\s+)?details?\s*\??$", re.I), "list"),
]

_CANON_TOPN = re.compile(r"^\s*(?:and|the)?\s*top\s*(\d+)\s*\??$", re.I)

def _detect_metric(low):
    """The kind of question (for state tracking)  -  never a number, just intent."""
    if _CMP_WORD_RE.search(low):                                  return "compare"
    if re.search(r"\baverage|avg|mean\b", low):                   return "average"
    if re.search(r"\b(trend|trending)\b", low):                   return "trend"
    if re.search(r"\b(monthly|month[- ]?wise|breakdown|by month)\b", low): return "breakdown"
    if re.search(r"\btop\s*\d", low):                             return "top"
    if re.search(r"\b(how many|count|number of)\b", low):         return "count"
    if re.search(r"\b(biggest|largest|highest|max|smallest|lowest|min|priciest|cheapest)\b", low): return "extreme"
    if re.search(r"\b(total|sum|spend|spent|spending)\b", low):   return "spend"
    return ""

def _resolve_conversation(q, state):
    """Rewrite an elliptical analytics/filter/comparison follow-up into a STANDALONE query
    by injecting the thread's carried scope (merchant/category/period). Returns a dict:
      resolved : the standalone query string to route on
      reset    : the user asked to start over
      changed  : a rewrite happened
      scope    : the merged scope to persist into state (entities of THIS turn)
      signals  : what was injected (for logging)
    Conservative  -  a fresh thread (no carried scope) is always a passthrough, so single-turn
    suites (golden, 1000-factual) are unaffected; only multi-turn behaviour changes."""
    low = q.lower().strip()
    out = {"resolved": q, "reset": False, "changed": False, "scope": {}, "signals": []}
    if _RESET_RE.search(low):
        out["reset"] = True; out["signals"] = ["reset"]
        return out

    # entity back-reference: "this/that category|merchant" -> the carried NAME, so every
    # engine  -  including the advice path  -  sees the real topic. ("Tell me some insights
    # in this category" after a Healthcare turn must not drift to whatever category the
    # LLM finds salient.)
    if state.category:
        q2 = re.sub(r"\b(?:this|that|the same)\s+category\b", lambda _m: state.category,
                    q, flags=re.I)
        if q2 != q:
            q, low = q2, q2.lower().strip()
            out["resolved"], out["changed"] = q, True
            out["signals"].append("this-category")
    if state.merchant:
        q2 = re.sub(r"\b(?:this|that|the same)\s+(?:merchant|shop|store|place|company|brand)\b",
                    lambda _m: state.merchant, q, flags=re.I)
        if q2 != q:
            q, low = q2, q2.lower().strip()
            out["resolved"], out["changed"] = q, True
            out["signals"].append("this-merchant")

    s = _extract_slots(q)
    own_merch, own_cat = s["merchant"], s["category"]
    own_entity = bool(own_merch or own_cat)
    own_period = bool(s["period_full"] or s["pmonth"] or s["pday"] or s["prange"])
    q_ents = _find_merchants(low) + _find_categories(low)
    n_ents = len(set(q_ents))
    scope_clear = bool(_SCOPE_CLEAR_RE.search(low))
    income_ctx = bool(_NO_ENTITY_INJECT_RE.search(low))

    carry_merch, carry_cat = state.merchant, state.category
    carry_entity = carry_merch or carry_cat
    carry_start, carry_end = state.start, state.end

    # ---- merged scope for THIS turn (new overrides carried; persists otherwise) ----
    metric = _detect_metric(low)
    txn_type = ("credit" if re.search(r"\b(credit|deposit|income|received|inflow)\b", low)
                else "debit" if re.search(r"\bdebit\b", low) else "")
    new_merch = own_merch or ("" if (scope_clear or income_ctx) else carry_merch)
    new_cat = own_cat or ("" if (scope_clear or income_ctx or own_merch) else carry_cat)
    # period: mirror _resolve_factual so a bare month/day/range combines with the carried
    # YEAR instead of clearing it ("february?" after "...january 2024" -> 2024-02).
    cy = (carry_start or "")[:4] if (carry_start or "")[:4].isdigit() else ""
    cym = (carry_start or "")[:7] if (len(carry_start or "") >= 7 and cy) else (cy + "-01" if cy else "")
    if s["period_full"]:
        new_start, new_end = s["period_full"]
    elif s["prange"] and cy:
        new_start, new_end = f"{cy}-{s['prange'][0]}", f"{cy}-{s['prange'][1]}"
    elif s["pmonth"] and s["pday"]:
        new_start, new_end = (f"{cy}-{s['pmonth']}-{s['pday']}" if cy
                              else f"MD-{s['pmonth']}-{s['pday']}"), ""
    elif s["pmonth"] and cy:
        new_start, new_end = f"{cy}-{s['pmonth']}", ""
    elif s["pday"] and cym:
        new_start, new_end = f"{cym}-{s['pday']}", ""
    elif scope_clear:
        new_start, new_end = "", ""
    else:
        new_start, new_end = carry_start, carry_end
    out["scope"] = {"merchant": new_merch, "category": new_cat, "start": new_start,
                    "end": new_end, "metric": metric, "txn_type": txn_type}

    # nothing carried -> passthrough (single-turn suites unaffected)
    if not carry_entity and not carry_start:
        return out

    # ---- comparison follow-up: "compare both" or "compare them" ----
    if re.search(r"\bcompare (?:both|them)\b", low):
        unique_prev = []
        for ent in reversed(state.prev_entities):
            if ent and ent not in unique_prev:
                unique_prev.append(ent)
                if len(unique_prev) == 2:
                    break
        if len(unique_prev) >= 2:
            entity1, entity2 = unique_prev[1], unique_prev[0]
            ph = "" if own_period else _period_phrase(carry_start, carry_end)
            out["resolved"] = (f"compare {entity1} vs {entity2}" + (f" {ph}" if ph else "")).strip()
            out["changed"] = True
            out["signals"] = [f"compare-both:{entity1}|{entity2}"]
            out["scope"]["comparison"] = [entity1, entity2]
            return out

    # ---- comparison follow-up: "compare with swiggy" / "vs amazon" ----
    if _CMP_WORD_RE.search(low) and carry_entity and n_ents == 1:
        other = q_ents[0]
        if other.lower() != carry_entity.lower():
            ph = "" if own_period else _period_phrase(carry_start, carry_end)
            out["resolved"] = (f"compare {carry_entity} vs {other}" + (f" {ph}" if ph else "")).strip()
            out["changed"] = True; out["signals"] = [f"compare:{carry_entity}|{other}"]
            out["scope"]["comparison"] = [carry_entity, other]
            return out
    # full comparison (>=2 entities) -> standalone, fall through to passthrough

    # ---- entity/period injection for elliptical follow-ups ----
    # A follow-up that carries scope from the thread comes in three shapes, all handled here:
    #   ΓÇó bare metric   ("average", "highest", "monthly")   -> _METRIC_RE / _FILTER_RE
    #   ΓÇó amount filter ("above 500", "under 2000")          -> _AMT_CMP_RE
    #   ΓÇó argmax entity ("which merchant did I spend more")  -> _ARGMAX_ENT_RE
    has_metric = bool(_METRIC_RE.search(low) or _FILTER_RE.search(low))
    has_amt = bool(_AMT_CMP_RE.search(low))
    has_argmax_ent = bool(_ARGMAX_ENT_RE.search(low))
    has_period_word = bool(re.search(r"\b(year|month|quarter|week|day|annual|monthly|ytd|half)\b", low))
    # bare-metric follow-ups map to a canonical stem ("average", "the biggest?", "top 3")
    stem = None
    if not (has_amt or has_argmax_ent):
        for rx, canon in _CANON:
            if rx.match(low):
                stem = canon; break
        mtop = _CANON_TOPN.match(low)
        if mtop:
            stem = f"top {mtop.group(1)} expenses"
    is_period_only = bool(own_period and not own_entity and not has_metric and not has_amt and not has_argmax_ent)
    # Only ELLIPTICAL follow-ups inherit the carried scope: a bare-metric stem, a bare amount
    # filter, a "which-merchant" argmax, or a continuation/back-reference. A COMPLETE question
    # ("what is my biggest expense?") is a fresh account-wide query and is NEVER pinned to the
    # previous turn's merchant  -  that leak was the reported bug. An amount filter that names
    # its OWN period ("show me all transactions over ┬ú100 in June") is likewise complete,
    # not a bare "and over ┬ú500?" follow-up.
    elliptical = bool(stem or (has_amt and not own_period) or has_argmax_ent
                      or _CONT_RE.search(q) or (_REFS_RE.search(q) and not own_entity))
    is_followup = bool(stem or has_metric or has_amt or has_argmax_ent or _CONT_RE.search(q)
                       or (_REFS_RE.search(q) and not own_entity) or is_period_only)
    # merchant/category: inherit the carried entity  -  UNLESS this turn asks across entities
    # ("which merchant ..."), cleared the scope ("overall"), or is income-scoped.
    needs_entity = bool(carry_entity and not own_entity and not scope_clear and not income_ctx
                        and not has_argmax_ent and (elliptical or is_period_only))
    # period: inject the carried period for elliptical metric/amount/argmax follow-ups; pure
    # period/factual follow-ups ("february?", "the whole year") stay with _resolve_factual.
    needs_period = bool(carry_start and not own_period and not scope_clear and not has_period_word
                        and (stem or has_metric or has_amt or has_argmax_ent) and elliptical)
    if not is_followup or (not needs_entity and not needs_period):
        return out

    resolved = stem if stem else q.strip().rstrip("?.! ")

    if needs_entity:
        ent = carry_merch or carry_cat
        resolved = f"{resolved} {'at' if carry_merch else 'on'} {ent}"
        out["signals"].append(f"+entity:{ent}")
        out["scope"]["merchant"] = carry_merch
        out["scope"]["category"] = "" if carry_merch else carry_cat
    if needs_period:
        ph = _period_phrase(carry_start, carry_end)
        if ph:
            resolved = f"{resolved} {ph}"
            out["signals"].append(f"+period:{carry_start}{('..'+carry_end) if carry_end else ''}")
            out["scope"]["start"], out["scope"]["end"] = carry_start, carry_end
    out["resolved"] = resolved
    out["changed"] = resolved.lower() != low
    return out

def _log_conv(tid, original, resolved, rinfo, state, before):
    """Structured one-line trace of a context rewrite (only when something was injected)."""
    if not rinfo.get("signals") and original.strip() == (resolved or "").strip():
        return
    try:
        print("[conv] " + json.dumps({
            "tid": tid, "original": original, "resolved": resolved,
            "signals": rinfo.get("signals", []),
            "before": {k: before.get(k, "") for k in ("merchant", "category", "start", "end")},
            "after": {"merchant": state.merchant, "category": state.category,
                      "start": state.start, "end": state.end, "metric": state.metric},
        }, ensure_ascii=False), flush=True)
    except Exception:
        pass

_ADVICE_RE = re.compile(
    r"\broast\b|how am i doing|am i doing (?:ok|well|good|bad|fine|alright|great)|"
    r"should i (?:cut|save|spend|reduce|budget)|cut back|cut down|save money|saving enough|"
    r"spending too much|am i (?:broke|rich|overspending)|give me (?:advice|tips)|"
    r"financial advice|help me save|improve my (?:finance|spending|budget|habit)|"
    r"where can i (?:save|cut)|tips to save|how (?:can|do) i save|"
    # solution-seeking follow-ups ("any solutions to the above problems?") are advice,
    # never an entity lookup  -  'above problems' must not become a "merchant".
    r"any (?:solutions?|suggestions?|recommendations?|ideas|fixes)\b|"
    r"what (?:can|should) i do\b|how (?:can|do) i (?:fix|solve|address)\b", re.I)

_WHY_RE = re.compile(
    r"^\s*why\b|\bwhy (?:was|were|did|do|does|am|is|are|have|has) (?:i|my|there|it|the)\b", re.I)

_REASON_RE = re.compile(
    # money recommendations
    r"how (?:can|should|do) i (?:save|invest|budget|cut|reduce|spend less|afford|"
    r"manage (?:my )?(?:money|finances?|budget|spend)|improve (?:my )?(?:finances?|saving|budget))|"
    r"how much (?:can|should) i (?:save|invest|afford|spend|put aside|set aside)|"
    r"where (?:should|can) i (?:cut|save|reduce|invest)|"
    r"can i (?:safely|comfortably) (?:invest|save|afford|spend)|can i afford|"
    r"safe to (?:invest|spend)|safely invest|should i (?:cut|save|spend|reduce|budget|invest)|"
    r"give me (?:financial )?(?:advice|tips)|financial advice|any (?:saving|budget|money|spending) tips|"
    # judgment about THEIR finances
    r"how am i doing(?: financially| with (?:money|saving|spending|my finances?))?|"
    r"am i (?:doing (?:ok|okay|well|good|bad|fine|alright)|on track|overspending|"
    r"saving enough|spending too much|broke|rich|financially)|"
    r"roast my (?:spending|finances?|budget|money)|"
    r"rate my (?:spending|finances?|financial|budget|money|saving)|"
    r"review my (?:spending|finances?|budget|money)|assess my (?:finances?|spending|budget|money)|"
    r"how (?:healthy|risky) (?:is|are) my (?:finances?|spending|money|saving)|"
    r"financially (?:healthy|fit|stable|secure|sound)|how financially|"
    # diagnostic about income / concentration
    r"how (?:dependent|reliant) am i|over[- ]?reliant|too reliant|"
    r"is my income (?:reliable|dependable|stable|secure|safe)|(?:reliable|dependable) income|"
    r"income (?:concentrat|diversif)|"
    # what to limit / what's draining savings
    r"(?:which|what) (?:categor|spending|expense|area)\w*.{0,30}(?:limit|cut|reduce|control|cap|trim|watch)|"
    r"need (?:strict|tighter|some)? ?(?:limits?|to cut|to control|capping)|strict limits?|"
    r"what.?s eating (?:my|into).{0,12}(?:saving|money)|eat\w* into my (?:saving|money)|"
    r"drain\w* my (?:saving|money|account)|what.?s (?:preventing|stopping|keeping) me from saving|"
    # trends / insights / habits / worries (finance-scoped)
    r"what (?:financial )?(?:trends?|patterns?|insights?)|"
    r"\btrends?\b.{0,20}\bobserve|observe.{0,20}\btrends?\b|"
    r"what should i (?:do|change|cut|reduce|prioriti|focus)|what habits|habits.{0,20}(?:reconsider|change)|"
    r"should i (?:worry|be worried|be concerned) about (?:my )?(?:money|spend|finances?|saving)|"
    r"red flags?|anything (?:concerning|worrying|wrong) (?:about )?(?:my )?(?:spend|money|finances?)|"
    # risk analysis
    r"future (?:financial )?risk|financial risk|at risk|risks? to (?:my )?(?:financ|money|saving)|"
    r"(?:suggest|indicate|signal)\w*.{0,25}risk|transactions?.{0,30}\brisk|"
    # financial health / impact
    r"financial(?:ly)? (?:health|wellbeing|fitness|stability)|"
    r"impact on (?:my )?(?:financial health|finances?|savings|money)|biggest impact|"
    # insights / takeaways / hidden patterns
    r"key takeaways?|takeaways?|key (?:points|findings|insights?)|"
    r"most surprising|surprising (?:insight|thing|fact|finding)|\binsights?\b|"
    r"hidden (?:spending )?pattern|spending pattern|pattern.{0,15}i (?:may|might|don.?t|wouldn|never)|"
    r"things? i (?:may|might|don.?t) notice|"
    # monitor / recommend what to watch
    r"what should i (?:monitor|watch|track|look out for|keep an eye)|what to (?:monitor|watch|track)|"
    r"monitor (?:every|each|my|monthly)|keep an eye|watch out for|look out for|"
    # summarise the statement
    r"summar(?:y|ise|ize) (?:of |my )?(?:statement|account|spending|finances?)|"
    r"key takeaways? from my (?:statement|account)|"
    # concept comparisons the deterministic layer can't resolve to known entities
    r"cash (?:withdrawal|vs|versus)|withdrawals?.{0,15}(?:vs|versus|compared)|digital payment|"
    r"online (?:payment|spend|transaction)s?.{0,15}(?:vs|versus)|cash vs|"
    # concentration / diversification
    r"\bconcentrat|diversif|too reliant on (?:a few|one|my)|spread (?:too )?thin|all my eggs|"
    # anomaly detection
    r"unusual|anomal|suspicious|out[- ]of[- ]pattern|larger than (?:normal|usual)|far larger|"
    r"stands? out|\boutlier|abnormal|strange (?:transaction|spend|charge|payment)|anything (?:odd|weird)|"
    # forecasting / projection (narrative; the deterministic what-if is in analytics_answer)
    r"project(?:ed|ion)?|run[- ]?rate|at this (?:rate|pace)|annual (?:spend|spending|saving)|"
    r"next month|how much will i (?:spend|save)|going to (?:spend|save)|on track to|"
    r"this year.{0,15}(?:save|spend)|forecast",
    re.I)

_FIN_RE = re.compile(
    r"money|cash|spen[dt]|saving|\bsave\b|\bsaved\b|invest|budget|income|salary|earn|afford|"
    r"expense|\bcost|financ|categor|merchant|transaction|\btxn|rupee|Γé╣|₹|debt|loan|\bemi\b|"
    r"subscription|\bbill|balance|net worth|\brich\b|broke|overspend|\bpay\b|paying|purchase|"
    r"shopping|grocer|deposit|withdraw|\baccount|statement|cut back|cut down|fund|wealth|"
    r"portfolio|retire|\btax|afford|spend less|monthly|per month|buy|buying|plan|planning|car|house|home|wedding|education|travel|splurg", re.I)

def _find_categories(low):
    out = []
    for kw, c in _CAT_SYN.items():
        if re.search(r"\b" + kw + r"\b", low) and c not in out:
            out.append(c)
    for c in _known_categories():                # canonical names incl. 'Other'/'Income'
        cl = c.lower()
        if c in out or not re.search(rf"\b{re.escape(cl)}\b", low):
            continue
        if cl in ("other", "income") and not re.search(r"categor", low):
            continue                             # generic word without category context
        out.append(c)
    if not out:                                  # typo-tolerant fallback
        for stem, c in _CAT_STEMS:
            if re.search(rf"\b{stem}\w*", low):
                out.append(c)
                break
    return out

def _find_merchants(low):
    hits = [m for m in _known_merchants()
            if re.search(r"\b" + re.escape(m.lower()) + r"\b", low)]
    # Drop a hit whose name is a word-subset of a LONGER hit  -  "Sports" inside "JD Sports"
    # is a false sub-name match, and letting it through spawns a bogus second entity that
    # the multi-entity combine then merges ("JD Sports + Sports"). Keep the longer name.
    keep = []
    for m in sorted(set(hits), key=lambda x: -len(x)):
        if any(re.search(r"\b" + re.escape(m.lower()) + r"\b", k.lower()) for k in keep):
            continue
        keep.append(m)
    return [m for m in _known_merchants() if m in keep]   # stable original order

def _find_periods(q):
    q = _strip_cmp_amounts(_sub_word_years(q))
    out = []
    for m in _SINGLE_RE.finditer(q):
        one = _norm_one(m.group(0))
        if one and one not in out:
            out.append(one)
    if len(out) < 2:
        # bare month names resolve to the statement's year, so "did I spend more in
        # May or June?" yields TWO periods and reaches the compare gate (it used to
        # yield none and silently answer May's total only).
        for tok in re.findall(rf"\b({_MON_RE})\b", q.lower()):
            mm = _mon_num(tok)
            y = _year_for_month(mm)
            one = f"{y}-{mm}" if y else None
            if one and one not in out:
                out.append(one)
    return out

def _parse_amount(low):
    m = re.search(r"(\d[\d,]*(?:\.\d+)?)\s*(lakhs?|lac|crores?|cr|k|thousand|million|mn|m)\b", low)
    if m:
        v = float(m.group(1).replace(",", ""))
        mult = {"lakh": 1e5, "lakhs": 1e5, "lac": 1e5, "crore": 1e7, "crores": 1e7, "cr": 1e7,
                "k": 1e3, "thousand": 1e3, "million": 1e6, "mn": 1e6, "m": 1e6}[m.group(2)]
        return v * mult
    # "<dir> [Γé╣|rs|rupees] <number>[.dd]"  -  any amount (incl. 3-digit + decimals), but NOT
    # a time span ("over 3 months"), a percentage, or a transaction/order count.
    m = re.search(
        r"(?:over|above|under|below|more than|less than|greater than|bigger than|smaller than|"
        r"exceed\w*|cheaper than|higher than|lower than|at\s?least|atleast|min(?:imum)?|max(?:imum)?)"
        r"\s+(?:Γé╣|₹|┬ú|£|\$|Γé¼|€|rs\.?|inr|gbp|usd|eur|rupees?|rupess|pounds?|quid)?\s*(\d[\d,]*(?:\.\d+)?)"
        r"(?!\s*(?:months?|days?|years?|yrs?|weeks?|wks?|hours?|%|percent|transactions?|txns?|times|orders?))",
        low)
    if m:
        return float(m.group(1).replace(",", ""))
    return None

_CONCEPTS = [
    ("gambling", re.compile(r"\b(gambl\w*|bett?ing|casinos?|bookmakers?|bookies?|wagers?)\b", re.I),
     re.compile(r"\bbet\w*\b|unibet|casino|poker|bingo|lotter|ladbrokes|betfair|paddy\s*power|"
                r"william\s*hill|betway|\b888\b|sky\s*bet|skybet|\bcoral\b|bwin|betfred", re.I)),
    ("loan repayments", re.compile(r"\b(loans?|repay\w*|mortgages?|emis?|borrow\w*|debts?)\b", re.I),
     re.compile(r"loan|lend|mortgage|\bemis?\b|klarna|\bfinance\b|financing", re.I)),
    ("bank fees", re.compile(r"\b(bank\s+fees?|fees?|service\s+charges?|overdrafts?|penalt\w*)\b", re.I),
     re.compile(r"\bfees?\b|\bcharges?\b|overdraft|penalt", re.I)),
    ("flights", re.compile(r"\b(flights?|airfares?|air travel|plane tickets?|airlines?|flying)\b", re.I),
     re.compile(r"ryanair|easyjet|jet2|wizz|\btui\b|british airways|virgin atlantic|aer lingus|"
                r"loganair|vueling|\bklm\b|lufthansa|emirates|qatar airways|etihad|"
                r"airlines?\b|airways\b|air france", re.I)),
    ("coffee", re.compile(r"\b(coffees?|lattes?|cappuccinos?|espressos?)\b", re.I),
     re.compile(r"costa|starbucks|caff[e├¿] nero|\bnero\b|coffee", re.I)),
    ("taxis & rides", re.compile(r"\b(taxis?|cabs?|rideshares?|ride[- ]hail\w*|minicabs?)\b", re.I),
     re.compile(r"\buber\b(?!\s?eats)|\bbolt\b|addison lee|free ?now|\btaxis?\b|minicab|\bcabs?\b", re.I)),
]

_FUP_ATTR = re.compile(r"^\s*(which|who|whom|why|when|where|whose)\b", re.I)

_WHICH_MONTHS_RE = re.compile(r"\b(?:which|what|list|show)\b[^?]*\bmonths\b", re.I)

_ANOM_RE = re.compile(
    r"unusual|anomal|suspicious|out[- ]of[- ]pattern|larger than (?:normal|usual)|far larger|"
    r"stands? out|\boutlier|abnormal|strange (?:transaction|spend|charge|payment)|"
    r"anything (?:odd|weird)|\bflag\b|fraud|irregular", re.I)

_FCAST_RE = re.compile(
    r"\bforecast|\bpredict|next month|coming month|next few months|expected (?:to )?spend|"
    r"how much will i (?:likely )?spend (?:next|in the coming)|what will i spend", re.I)

_PROJ_RE = re.compile(
    r"\b(?:annual|yearly|per year|a year|run[- ]?rate)\b|at this (?:rate|pace)|"
    r"this year.{0,20}(?:save|saving|spend)|(?:save|spend)\w*.{0,20}this year", re.I)

_HEALTH_RE = re.compile(
    r"financ\w* health|how healthy|health score|health check|rate my (?:money|finances?|spending|financial|budget)|"
    r"financial report card|report card|money management|how (?:am i|are my finances?) doing|"
    r"how good (?:are|is) my (?:finances?|money)|grade my (?:finances?|money|spending)|"
    r"score my (?:finances?|money|spending)", re.I)

_RISK_RE = re.compile(
    r"what (?:are |financial )?(?:my )?risks?|any risks?|risks? (?:do you see|in my|should i|am i)|"
    r"what should i worry|should i (?:be )?worr|am i overspending|am i at risk|red flags?|warning signs?|"
    r"what.{0,20}worry about|financial(?:ly)? (?:at )?risk|in danger|money (?:risks?|danger)", re.I)

_RECUR_RE = re.compile(
    r"subscription|recurring|recurr\w*|standing (?:instruction|order)s?|"
    r"direct[- ]debits?|auto[- ]?debit|"
    r"repeat(?:ed|ing)? (?:payment|charge|bill)|regular (?:payment|bill|charge)s?|"
    r"what (?:do i pay|am i paying).{0,25}(?:every|each) month|monthly (?:bill|commitment)s?", re.I)

_BEHAVE_RE = re.compile(
    r"spending (?:habit|behaviou?r|personality|style|pattern of)|\bhabits?\b|behaviou?r|"
    r"weekend (?:spend|vs|versus)|do i overspend on weekend|impuls\w*|"
    r"end of (?:the )?month|month[- ]end|am i an? (?:impulsive|big|frequent) spender|how do i spend", re.I)

_IMPACT_RE = re.compile(
    r"(?:which|what)\b.{0,30}\btransactions?\b.{0,30}(?:impact|affect|hurt|hit|matter|biggest|most|moved|damage)|"
    r"biggest impact|most impact(?:ful)?|transaction impact|high[- ]impact|impact (?:on|to) my (?:finances?|health)|"
    r"which (?:expenses?|purchases?)\b.{0,25}(?:hurt|matter|biggest|impact)", re.I)

_CATTREND_RE = re.compile(
    r"categor\w+.{0,30}(?:grow|growing|rising|risen|fastest|out of control|increasing|spiral|trend)|"
    r"which (?:categor\w+|expenses?|spending).{0,25}(?:grow|growing|rising|fastest|out of control|getting|increas)|"
    r"fastest[- ]growing|getting out of (?:hand|control)|spiralling|spiraling|"
    r"what.{0,20}(?:expenses?|spending|categor\w+).{0,20}out of control", re.I)

_PATTERN_RE = re.compile(
    r"what patterns?|spending patterns?|patterns? (?:do you|in my|you see|emerge|here)|"
    r"what (?:do you )?(?:notice|observe|see)\b|any (?:insights?|patterns?)|key insights?|what insights?|"
    r"what stands out|anything (?:interesting|notable)|what can you tell me about my (?:spending|finances?|statement|money)", re.I)

_RECUR_DEFER = re.compile(
    r"increas|rose|went up|grew|gone up|climb|more expensive|trend|chang|cancel|"
    r"should i|\bcut\b|reduce|lower|trim|save money|get rid", re.I)

_DOCS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "docs"))
