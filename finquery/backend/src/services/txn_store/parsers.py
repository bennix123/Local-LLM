import re, os, pymupdf
from .db import connect, init_db
from .formatters import set_currency, _money, inr, grp
from . import formatters

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

ROW_RE = re.compile(
    r"^(\d{2}-\d{2}-\d{4})\s{2,}(\S.*?)\s{2,}(DR|CR)\s+(-?[\d,]+\.\d{2})\s+(-?[\d,]+\.\d{2})\s*$"
)

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
    where = "user_id=?"
    params = [user_id]
    if doc_name:
        where += " AND doc_name=?"
        params.append(doc_name)
        
    con = connect()
    try:
        r = con.execute(f"SELECT currency, COUNT(*) c FROM transactions WHERE {where} "
                        f"AND currency IS NOT NULL GROUP BY currency ORDER BY c DESC LIMIT 1", params).fetchone()
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

    # Local import to avoid circular dependencies
    from src.services.nl_sql_engine import extract_account_profile
    profile = extract_account_profile(pdf_path, user_id)
    bank_name = profile.get("bank_name")

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
           "(user_id,doc_name,bank_name,txn_date,month,year,month_no,day,descr,merchant,category,"
           "debit,credit,balance,currency,seq)"
           " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
    for t in txns:
        cur = t.get("currency", "INR")
        # Override default INR if a different currency or RAW was detected in the header
        if cur == "INR" and detected_cur != "INR":
            cur = detected_cur

        buf.append((user_id, doc_name, bank_name, t["txn_date"], t["month"], t["year"], t["month_no"], t["day"],
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


