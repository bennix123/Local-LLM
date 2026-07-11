import re, os, pymupdf, json, urllib.request, csv, pathlib
from .db import connect, init_db
from .formatters import set_currency, _money, inr, grp
from . import formatters

MERCHANT_MAP = {
    "swiggyinstamart": ("Swiggy Instamart", "Groceries"),
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
    "ekart": ("Ekart Logistics", "Shopping"),
    "vyapar": ("Vyapar Merchant", "Shopping"),
    "google": ("Google", "Utilities"),
    "paytm": ("Paytm", "Shopping"),
}

# ---------------------------------------------------------------- Bank Profile Registry (Stage 4 HLD)

_PROFILES_DIR = pathlib.Path(__file__).parent / "bank_profiles"

class BankProfileRegistry:
    """Loads JSON bank profiles from bank_profiles/ and matches them against a document.
    Falls back gracefully if the directory or individual files are missing/corrupt.
    """
    _profiles: list = []
    _loaded: bool = False

    @classmethod
    def _load(cls):
        if cls._loaded:
            return
        cls._profiles = []
        if not _PROFILES_DIR.exists():
            cls._loaded = True
            return
        for fp in _PROFILES_DIR.glob("*.json"):
            try:
                with open(fp, encoding="utf-8") as f:
                    p = json.load(f)
                p["_source"] = fp.stem
                cls._profiles.append(p)
            except Exception as e:
                print(f"[profile-registry] Failed to load {fp.name}: {e}")
        cls._loaded = True

    @classmethod
    def match(cls, document_text: str) -> dict | None:
        """Score document text against all loaded profiles. Return best match above threshold."""
        cls._load()
        low = (document_text or "").lower()
        best_score, best_profile = 0.0, None

        for p in cls._profiles:
            score = 0.0
            ids = p.get("identifiers", {})

            # Text identifier match (each hit = 0.5 points, capped at 1.0)
            for phrase in ids.get("text_contains_any", []):
                if phrase.lower() in low:
                    score += 0.5
            score = min(score, 1.0)

            # Header row keyword match (bonus 0.5 each, capped at 1.0)
            header_score = 0.0
            for kw in ids.get("header_row_contains_any", []):
                if kw.lower() in low:
                    header_score += 0.25
            score += min(header_score, 1.0)

            if score > best_score:
                best_score = score
                best_profile = p

        if best_score >= 0.5:
            print(f"[profile-registry] Matched profile: {best_profile.get('bank_name')} (score={best_score:.2f})")
            return best_profile
        return None

    @classmethod
    def save_learned_profile(cls, bank_name: str, mapping: dict, source_file: str = ""):
        """Persist a heuristically-discovered profile for future fast-path matching."""
        cls._load()
        out = _PROFILES_DIR / f"{bank_name.lower().replace(' ', '_')}_auto.json"
        try:
            _PROFILES_DIR.mkdir(parents=True, exist_ok=True)
            with open(out, "w", encoding="utf-8") as f:
                json.dump({
                    "bank_name": bank_name,
                    "version": 1,
                    "identifiers": {"text_contains_any": [bank_name]},
                    "column_map": mapping.get("column_map", {}),
                    "debit_credit_style": mapping.get("debit_credit_style", "separate_columns"),
                    "date_format": mapping.get("date_format", "%d/%m/%Y"),
                    "number_format": mapping.get("number_format", "indian"),
                    "currency": mapping.get("currency", "INR"),
                    "created_from": "auto",
                    "source_file": source_file,
                    "last_validated": __import__("datetime").date.today().isoformat(),
                    "success_rate": 0.0
                }, f, indent=2)
            # Reload so next call picks it up
            cls._loaded = False
            print(f"[profile-registry] Saved new auto-profile: {out.name}")
        except Exception as e:
            print(f"[profile-registry] Failed to save profile: {e}")


# ---------------------------------------------------------------- Page Classifier (Stage 2 HLD)

_DATE_DENSITY_RE = re.compile(
    r"\b\d{1,2}[-/]\d{1,2}[-/]\d{2,4}\b|\b\d{4}-\d{2}-\d{2}\b"
    r"|\b\d{1,2}[-/ ][A-Za-z]{3}[-/ ]\d{2,4}\b",
    re.I
)
_HEADER_KEYWORDS = re.compile(
    r"\b(date|narration|particulars|description|debit|credit|withdrawal|deposit|balance|amount|remarks)\b",
    re.I
)
_SUMMARY_RE = re.compile(
    r"\b(opening balance|closing balance|statement period|total debit|total credit"
    r"|account summary|account holder|branch|ifsc|micr|sort code|account number"
    r"|statement of account|terms|conditions|page \d+ of \d+)\b",
    re.I
)
_MONEY_TOKEN_RE = re.compile(r"^-?[£$€₹]?[\d,]+\.\d{2}$")


def classify_page(page_text: str) -> tuple[str, float]:
    """Score a page and return (label, confidence).
    Labels: 'transaction_table' | 'account_summary' | 'banner' | 'disclaimer' | 'unknown'
    """
    lines = [l.strip() for l in page_text.splitlines() if l.strip()]
    if not lines:
        return "unknown", 0.0

    total = len(lines)
    # Signal 1: date pattern density (0..1)
    date_hits = sum(1 for l in lines if _DATE_DENSITY_RE.search(l[:30]))
    date_density = date_hits / total

    # Signal 2: numeric density (tokens that look like money amounts)
    tokens = page_text.split()
    money_hits = sum(1 for t in tokens if _MONEY_TOKEN_RE.match(re.sub(r"[£$€₹]", "", t).strip()))
    numeric_density = min(money_hits / max(len(tokens), 1), 1.0)

    # Signal 3: has a recognisable column-header row
    header_line = any(
        len(re.findall(_HEADER_KEYWORDS, l)) >= 3
        for l in lines[:8]   # headers almost always appear in first 8 lines
    )
    has_header = 1.0 if header_line else 0.0

    # Signal 4: row repetition — many lines with similar token count (± 2)
    tcounts = [len(l.split()) for l in lines]
    dominant = max(set(tcounts), key=tcounts.count) if tcounts else 0
    rep_ratio = sum(1 for c in tcounts if abs(c - dominant) <= 2) / total

    # Signal 5: summary page markers (negative signal for transaction_table)
    summary_density = sum(1 for l in lines if _SUMMARY_RE.search(l)) / total

    # Weighted score for TRANSACTION_TABLE
    txn_score = (
        date_density    * 0.30 +
        numeric_density * 0.20 +
        has_header      * 0.25 +
        rep_ratio       * 0.15 -
        summary_density * 0.25
    )

    if txn_score >= 0.30 and date_density >= 0.05:
        return "transaction_table", min(txn_score, 1.0)
    if summary_density >= 0.20:
        return "account_summary", summary_density
    if total <= 5:
        return "banner", 0.7
    return "unknown", 0.0


def find_table_start_page(doc) -> int:
    """Return the first page index classified as 'transaction_table'.
    Replaces the old _find_table_start() with signal-based classification (Stage 2 HLD).
    """
    for page_idx in range(len(doc)):
        text = doc[page_idx].get_text("text")
        label, conf = classify_page(text)
        if label == "transaction_table" and conf >= 0.20:
            return page_idx
    return 0   # graceful fallback

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
        # Check if this is a UPI transaction with format UPI/DR/RRN/NAME/BANK/VPA
        if parts[0].lower() == "upi" and parts[1].lower() in ("dr", "cr") and len(parts) >= 4:
            candidate = parts[3].strip()
            if candidate:
                return candidate, "Other"
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
    re.compile(r"^(\d{2})-([A-Za-z]{3,9})-(\d{2,4})$"),
    re.compile(r"^(\d{2})\s+([A-Za-z]{3,9})\s+(\d{2,4})$"),
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


TABLE_START_MIN_DATE_LINES = 4
RULE_BASED_MAX_VIOLATION_RATIO = 0.10
SCHEMA_MIN_MATCH_RATE = 0.15
SCHEMA_MIN_ROW_COUNT = 3
SCHEMA_MAX_VIOLATION_RATIO = 0.20
MAX_LLM_FALLBACK_PAGES = 10

def _find_table_start(doc) -> int:
    """Backwards-compat alias → delegates to the signal-based PageClassifier (Stage 2 HLD)."""
    return find_table_start_page(doc)


def detect_schema(sample_lines: list[str]) -> dict | None:
    """Send sample lines to Ollama to infer the row structure. Returns dict or None."""
    lines_str = "\n".join(sample_lines)
    prompt = f"""You are analyzing a bank statement text to find the transaction table row structure.
Analyze the following lines from the transaction table and identify the schema pattern:
{lines_str}

Return a JSON object with the following fields:
- "date_format": Description of date format (e.g. "DD-MM-YYYY", "YYYY-MM-DD", "DD MMM YY", "DD/MM/YYYY")
- "column_order": Array of column roles in order. Valid roles are: "date", "description", "debit", "credit", "balance", "amount" (if debit/credit are combined).
- "debit_credit_style": One of "separate_columns", "dr_cr_suffix", "sign"
- "sample_regex": A Python regular expression string matching a single row. Use named groups: (?P<date>...), (?P<desc>...), (?P<debit>...), (?P<credit>...), (?P<balance>...), or (?P<amount>...) if combined. The regex should match typical transaction lines.
- "backup_columns": A JSON object mapping column role to its 0-indexed column position (e.g. {{"date_col": 0, "desc_col": 1, "debit_col": 2, "credit_col": 3, "balance_col": 4}}).

Return ONLY the raw JSON object. Do not include any explanations, introduction, markdown blocks, or code fences."""

    payload = json.dumps({
        "model": os.getenv("LLM_MODEL", "qwen2.5-coder:3b"),
        "stream": False,
        "keep_alive": "10m",
        "options": {"temperature": 0.0, "num_ctx": 2048},
        "prompt": prompt
    }).encode("utf-8")
    
    url = f'{os.getenv("OLLAMA_URL", "http://127.0.0.1:11434")}/api/generate'
    try:
        req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=90) as resp:
            res_data = json.loads(resp.read().decode("utf-8"))
            content = res_data.get("response", "").strip()
            raw_content = content  # keep for debug logging

            # Strip markdown code fences (```json ... ```)
            if "```" in content:
                first_fence = content.find("```")
                last_fence = content.rfind("```")
                if first_fence != last_fence:
                    content = content[first_fence+3:last_fence]
                    content = re.sub(r"^[a-zA-Z0-9]*\s*", "", content).strip()

            # Extract the outermost {...} block
            start = content.find("{")
            end = content.rfind("}")
            if start == -1 or end == -1:
                print(f"[parser-L2] No JSON object found in LLM response. Raw: {raw_content[:200]!r}")
                return None
            content = content[start:end+1]

            # Sanitize non-standard JSON values Mistral sometimes emits
            content = re.sub(r'\bNaN\b', '"NaN"', content)
            content = re.sub(r'\bNone\b', 'null', content)
            content = re.sub(r'\bTrue\b', 'true', content)
            content = re.sub(r'\bFalse\b', 'false', content)
            # Remove trailing commas before } or ]
            content = re.sub(r',\s*([}\]])', r'\1', content)
            # Fix Python raw-string literals: r"..." -> "..." (Mistral emits these in JSON)
            # Convert r"<content>" to "<content>" by stripping the r prefix.
            # This must handle both r"..." and r'...' variants.
            content = re.sub(r'\br("(?:[^"\\]|\\.)*")', r'\1', content)
            content = re.sub(r"\br('(?:[^'\\]|\\.)*')", r'\1', content)

            # Doubling single backslashes in JSON string literals
            def _double_slashes(m):
                s = m.group(0)
                quote_char = s[0]
                inner = s[1:-1]
                fixed = []
                i = 0
                while i < len(inner):
                    if inner[i] == '\\':
                        if i + 1 < len(inner):
                            next_c = inner[i+1]
                            if next_c in ('"', "'", '\\', '/', 'b', 'f', 'n', 'r', 't'):
                                fixed.append('\\' + next_c)
                                i += 2
                                continue
                            elif next_c == 'u' and i + 5 < len(inner) and all(c in '0123456789abcdefABCDEF' for c in inner[i+2:i+6]):
                                fixed.append('\\' + inner[i+1:i+6])
                                i += 6
                                continue
                        fixed.append('\\\\')
                        i += 1
                    else:
                        fixed.append(inner[i])
                        i += 1
                return quote_char + "".join(fixed) + quote_char

            # Double backslashes inside any single or double quoted strings in JSON
            content = re.sub(r'"(?:[^"\\]|\\.)*"', _double_slashes, content)
            content = re.sub(r"'(?:[^'\\]|\\.)*'", _double_slashes, content)

            try:
                parsed = json.loads(content)
            except json.JSONDecodeError as jde:
                print(f"[parser-L2] JSON parse error: {jde}. Cleaned content: {content[:300]!r}")
                return None

            print(f"[parser-L2] LLM schema response: regex={parsed.get('sample_regex','<none>')!r} style={parsed.get('debit_credit_style','?')!r} cols={parsed.get('backup_columns','?')}")
            return parsed
    except Exception as e:
        print(f"[parser-L2] Schema detection failed: {e}")
        return None

def _apply_schema_regex(pattern: re.Pattern, all_lines: list[str]) -> tuple[list[dict], float]:
    matched = []
    candidates = [line for line in all_lines if len(line.strip()) > 5]
    if not candidates:
        return [], 0.0
    for line in candidates:
        m = pattern.search(line)
        if m:
            matched.append(m.groupdict())
    match_rate = len(matched) / len(candidates)
    return matched, match_rate

def _apply_schema_positional(all_lines: list[str], backup_cols: dict) -> tuple[list[dict], float]:
    matched = []
    candidates = [line for line in all_lines if len(line.strip()) > 5]
    if not candidates:
        return [], 0.0
    
    key_mapping = {
        "date_col": "date",
        "desc_col": "desc",
        "debit_col": "debit",
        "credit_col": "credit",
        "balance_col": "balance",
        "amount_col": "amount"
    }
    
    valid_indices = [val for val in backup_cols.values() if isinstance(val, int)]
    max_idx = max(valid_indices, default=0)
    
    for line in candidates:
        if '|' in line:
            tokens = [t.strip() for t in line.split('|') if t.strip()]
        else:
            tokens = [t.strip() for t in re.split(r'\s{2,}', line.strip()) if t.strip()]
            if len(tokens) <= max_idx:
                tokens = [t.strip() for t in line.strip().split() if t.strip()]
        
        tokens = [t.strip().strip('|').strip() for t in tokens if t.strip()]
        
        row_dict = {}
        for col_name, idx in backup_cols.items():
            if idx is not None and idx < len(tokens):
                target_key = key_mapping.get(col_name, col_name.replace("_col", ""))
                row_dict[target_key] = tokens[idx]
        
        if "date" not in row_dict or not parse_date(row_dict["date"]):
            for t in tokens:
                if parse_date(t):
                    row_dict["date"] = t
                    break
        
        has_money_val = any(k in row_dict for k in ("debit", "credit", "amount"))
        if not has_money_val:
            money_candidates = []
            for t in tokens:
                t_clean = re.sub(r"[₹£$€]", "", t).strip()
                t_clean_num = re.sub(r"(cr|dr)\.?$", "", t_clean, flags=re.I).strip()
                if MONEY_PAT.match(t_clean_num) and not parse_date(t):
                    money_candidates.append(t)
            if len(money_candidates) >= 2:
                row_dict["debit"] = money_candidates[0]
                row_dict["credit"] = money_candidates[1]
            elif len(money_candidates) == 1:
                row_dict["amount"] = money_candidates[0]
        
        if "desc" not in row_dict or len(row_dict["desc"]) < 3:
            non_desc_tokens = {row_dict.get("date"), row_dict.get("debit"), row_dict.get("credit"), row_dict.get("amount"), row_dict.get("balance")}
            desc_candidates = [t for t in tokens if t not in non_desc_tokens]
            if desc_candidates:
                row_dict["desc"] = " ".join(desc_candidates)
        
        if "date" in row_dict and ("debit" in row_dict or "credit" in row_dict or "amount" in row_dict):
            matched.append(row_dict)
            
    match_rate = len(matched) / len(candidates)
    return matched, match_rate

def _validate_and_convert_schema_rows(matched_rows: list[dict], schema: dict, local_cur: str) -> list[dict]:
    converted = []
    seq = 0
    
    for row in matched_rows:
        date_raw = row.get("date", "").strip()
        desc_raw = row.get("desc", row.get("description", "")).strip()
        
        parsed_d = parse_date(date_raw)
        if not parsed_d:
            continue
            
        yr, mon, day = parsed_d
        iso = f"{yr:04d}-{mon:02d}-{day:02d}"
        
        style = schema.get("debit_credit_style", "separate_columns")
        debit, credit, balance = 0.0, 0.0, 0.0
        
        try:
            if style == "separate_columns":
                deb_val = row.get("debit")
                crd_val = row.get("credit")
                debit = abs(_money(deb_val)) if deb_val else 0.0
                credit = abs(_money(crd_val)) if crd_val else 0.0
            elif style == "dr_cr_suffix":
                amt_raw = row.get("amount") or row.get("debit") or row.get("credit") or ""
                amt = abs(_money(amt_raw)) if amt_raw else 0.0
                if "dr" in str(amt_raw).lower():
                    debit = amt
                else:
                    credit = amt
            elif style == "sign":
                amt_raw = row.get("amount") or row.get("debit") or row.get("credit") or ""
                amt = _money(amt_raw) if amt_raw else 0.0
                if amt < 0:
                    debit = abs(amt)
                else:
                    credit = amt
            
            bal_val = row.get("balance")
            balance = _money(bal_val) if bal_val else 0.0
        except Exception:
            continue
            
        seq += 1
        merchant, category = (_barclays_merchant(desc_raw, credit > 0) if local_cur == "GBP" else _classify(desc_raw))
        
        converted.append({
            "txn_date": iso, "month": iso[:7],
            "year": yr, "month_no": mon, "day": day,
            "descr": desc_raw, "merchant": merchant, "category": category,
            "debit": debit, "credit": credit, "balance": balance,
            "currency": local_cur or "INR", "seq": seq
        })
        
    return converted

def try_schema_inference(pdf_path: str, local_cur: str) -> tuple[list[dict], str] | None:
    """Orchestrates L2: detect_schema -> apply regex -> validate match rate and reconciliation."""
    try:
        doc = pymupdf.open(pdf_path)
        start_page = _find_table_start(doc)
        
        sample_text = doc[start_page].get_text("text")
        sample_lines = [line.strip() for line in sample_text.splitlines() if len(line.strip()) > 10][:15]
        
        if not sample_lines:
            print("[parser-L2] No sample lines found on first table page.")
            doc.close()
            return None
            
        schema = detect_schema(sample_lines)
        if not schema:
            print("[parser-L2] LLM returned no schema. Aborting L2.")
            doc.close()
            return None
            
        print(f"[parser-L2] Schema detected: debit_credit_style={schema.get('debit_credit_style')} has_regex={'sample_regex' in schema} has_backup_cols={'backup_columns' in schema}")
        
        all_lines = []
        for page_idx in range(start_page, len(doc)):
            page_text = doc[page_idx].get_text("text")
            all_lines.extend([line.strip() for line in page_text.splitlines() if line.strip()])
            
        matched_rows = []
        match_rate = 0.0
        used_path = "none"
        
        if "sample_regex" in schema:
            try:
                pattern = re.compile(schema["sample_regex"])
                matched_rows, match_rate = _apply_schema_regex(pattern, all_lines)
                used_path = "regex"
                print(f"[parser-L2] Regex path: match_rate={match_rate:.3f} matched_rows={len(matched_rows)}")
            except re.error as re_err:
                print(f"[parser-L2] Regex compilation FAILED ({re_err}), trying positional fallback.")
                
        if (not matched_rows or match_rate < SCHEMA_MIN_MATCH_RATE) and "backup_columns" in schema:
            matched_rows, match_rate = _apply_schema_positional(all_lines, schema["backup_columns"])
            used_path = "positional"
            print(f"[parser-L2] Positional path: match_rate={match_rate:.3f} matched_rows={len(matched_rows)}")
            
        if match_rate < SCHEMA_MIN_MATCH_RATE or len(matched_rows) < SCHEMA_MIN_ROW_COUNT:
            print(f"[parser-L2] L2 REJECTED: match_rate={match_rate:.3f} < {SCHEMA_MIN_MATCH_RATE} or rows={len(matched_rows)} < {SCHEMA_MIN_ROW_COUNT}")
            doc.close()
            return None
            
        if matched_rows:
            for idx, r in enumerate(matched_rows):
                print(f"[parser-L2] DEBUG matched row {idx}: {r}")
            
        converted = _validate_and_convert_schema_rows(matched_rows, schema, local_cur)
        if len(converted) < SCHEMA_MIN_ROW_COUNT:
            print(f"[parser-L2] L2 REJECTED: only {len(converted)} rows survived date/money conversion.")
            doc.close()
            return None
            
        breaks = _generic_breaks(converted)
        violation_ratio = breaks / len(converted)
        print(f"[parser-L2] Balance check: breaks={breaks} violation_ratio={violation_ratio:.3f} (limit={SCHEMA_MAX_VIOLATION_RATIO}) via {used_path} path")
        if violation_ratio > SCHEMA_MAX_VIOLATION_RATIO:
            print(f"[parser-L2] L2 REJECTED: balance violation_ratio {violation_ratio:.3f} > {SCHEMA_MAX_VIOLATION_RATIO}. Falls through to L3.")
            doc.close()
            return None
            
        print(f"[parser-L2] >>> L2 ACCEPTED: {len(converted)} rows, {breaks} balance violations, via {used_path} path")
        doc.close()
        return converted, "medium"
    except Exception as e:
        print(f"[parser-L2] Schema inference failed: {e}")
        return None

def _chunk_text(lines: list[str], chunk_size: int = 18, overlap: int = 2) -> list[str]:
    chunks = []
    i = 0
    while i < len(lines):
        chunk = lines[i:i+chunk_size]
        chunks.append("\n".join(chunk))
        if i + chunk_size >= len(lines):
            break
        i += chunk_size - overlap
    return chunks

def parse_chunk_with_llm(chunk_text: str) -> list[dict]:
    prompt = f"""You are a data extraction assistant. Extract transaction rows from the following bank statement text chunk.
Text chunk:
\"\"\"
{chunk_text}
\"\"\"

Return a JSON array of objects. Each object represents a single transaction with the following keys:
- "date": string in YYYY-MM-DD format (if year is missing, infer it from surrounding context or assume 2026)
- "description": string (the merchant / payee name or transaction description)
- "debit": number (amount spent/debited, 0 if it was a credit/deposit)
- "credit": number (amount received/credited, 0 if it was a debit/withdrawal)
- "balance": number or null (running balance after transaction)

Do not include headers, footers, summary metrics, or page numbers. Only return transactions.
Return ONLY the raw JSON array. Do not include markdown code fences, comments, or explanations."""

    payload = json.dumps({
        "model": os.getenv("LLM_MODEL", "llama3.1:8b"),
        "stream": False,
        "keep_alive": "10m",
        "options": {"temperature": 0.0, "num_ctx": 2048},
        "prompt": prompt
    }).encode("utf-8")
    
    url = f'{os.getenv("OLLAMA_URL", "http://127.0.0.1:11434")}/api/generate'
    try:
        req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            res_data = json.loads(resp.read().decode("utf-8"))
            content = res_data.get("response", "").strip()
            
            if "```" in content:
                first_fence = content.find("```")
                last_fence = content.rfind("```")
                if first_fence != last_fence:
                    content = content[first_fence:last_fence]
                    content = re.sub(r"^```[a-zA-Z0-9]*\s*", "", content).strip()
            
            start = content.find("[")
            end = content.rfind("]")
            if start != -1 and end != -1:
                content = content[start:end+1]
                
            return json.loads(content)
    except Exception as e:
        print(f"[parser-L3] Chunk parsing failed: {e}")
        return []

def parse_with_llm_fallback(pdf_path: str, local_cur: str) -> tuple[list[dict], str]:
    """Last resort: chunk the document and call LLM for full extraction."""
    try:
        doc = pymupdf.open(pdf_path)
        start_page = _find_table_start(doc)
        total_pages = len(doc)
        
        skipped_pages = max(0, total_pages - (start_page + MAX_LLM_FALLBACK_PAGES))
        confidence = "partial" if skipped_pages > 0 else "low"
        
        all_lines = []
        end_page = min(start_page + MAX_LLM_FALLBACK_PAGES, len(doc))
        for page_idx in range(start_page, end_page):
            page_text = doc[page_idx].get_text("text")
            all_lines.extend([line.strip() for line in page_text.splitlines() if len(line.strip()) > 5])
            
        doc.close()
        
        print(f"[parser-L3] total_pages={total_pages} start_page={start_page} end_page={end_page} skipped_pages={skipped_pages} confidence={confidence!r}")
        
        chunks = _chunk_text(all_lines)
        print(f"[parser-L3] Processing {len(chunks)} chunks from {len(all_lines)} lines...")
        extracted = []
        
        for chunk_idx, chunk in enumerate(chunks):
            chunk_rows = parse_chunk_with_llm(chunk)
            if chunk_rows:
                print(f"[parser-L3] Chunk {chunk_idx+1}/{len(chunks)}: extracted {len(chunk_rows)} rows")
                extracted.extend(chunk_rows)
            else:
                print(f"[parser-L3] Chunk {chunk_idx+1}/{len(chunks)}: 0 rows")
                
        # Deduplicate rows by (date, description, debit, credit)
        seen = set()
        deduped = []
        seq = 0
        
        for row in extracted:
            date_str = row.get("date", "").strip()
            desc = row.get("description", "").strip()
            debit = float(row.get("debit") or 0.0)
            credit = float(row.get("credit") or 0.0)
            balance = float(row.get("balance") or 0.0) if row.get("balance") is not None else 0.0
            
            parsed_d = parse_date(date_str)
            if not parsed_d:
                continue
                
            yr, mon, day = parsed_d
            iso = f"{yr:04d}-{mon:02d}-{day:02d}"
            
            key = (iso, desc, debit, credit)
            if key not in seen:
                seen.add(key)
                seq += 1
                merchant, category = (_barclays_merchant(desc, credit > 0) if local_cur == "GBP" else _classify(desc))
                deduped.append({
                    "txn_date": iso, "month": iso[:7],
                    "year": yr, "month_no": mon, "day": day,
                    "descr": desc, "merchant": merchant, "category": category,
                    "debit": debit, "credit": credit, "balance": balance,
                    "currency": local_cur or "INR", "seq": seq
                })
                
        # Sort chronologically
        deduped.sort(key=lambda r: (r["txn_date"], r["seq"]))
        for idx, r in enumerate(deduped, 1):
            r["seq"] = idx
            
        return deduped, confidence
    except Exception as e:
        print(f"[parser-L3] Full LLM extraction failed: {e}")
        return [], "low"

MONEY_PAT = re.compile(r"^-?[\d,]+\.\d{2}$")


def _parse_generic_columnar(pdf_path):
    """Generic fallback: extract transactions from visual layout coordinates, one date-bearing
    row = one transaction. Great for column layouts with a date on every row; blind to layouts
    that print the date once per day (see _parse_generic_dateinherited)."""
    doc = pymupdf.open(pdf_path)
    start_page = _find_table_start(doc)
    
    # Detect currency locally to avoid global NameError
    head = ""
    try:
        head = "".join(doc[i].get_text("text") for i in range(start_page, min(start_page + 3, len(doc))))
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
        if page_idx < start_page:
            continue
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
    start_page = _find_table_start(doc)
    head = "".join(doc[i].get_text("text") for i in range(start_page, min(start_page + 3, len(doc))))
    low = head.lower()
    cur = ("GBP" if any(k in low for k in ("barclays", "sort code", "£", "iban gb", "castlemere", "wrenfield"))
           else "OMR" if any(k in low for k in ("oman", "muscat", "omr"))
           else "USD" if "$" in low else "INR")
    years = [int(y) for y in re.findall(r"\b(20\d\d)\b", head)]
    base_year = min(years) if years else 2000

    txns, cur_date, cur_txn = [], None, None
    for page_idx, page in enumerate(doc):
        if page_idx < start_page:
            continue
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


def _parse_generic_statement_list(pdf_path) -> tuple[list[dict], str]:
    # Determine local_cur first
    try:
        doc = pymupdf.open(pdf_path)
        start_page = _find_table_start(doc)
        head = "".join(doc[i].get_text("text") for i in range(start_page, min(start_page + 3, len(doc))))
        doc.close()
    except Exception:
        head = ""
        
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

    # Layer 1: Rule-based columnar / dateinherited
    print("[cascade] Layer 1 (rule-based) running...")
    columnar = list(_parse_generic_columnar(pdf_path))
    if columnar:
        # Self-validation: if > 30% of descriptions are pure numbers, it means columns are misaligned
        num_descs = sum(1 for r in columnar if r["descr"].strip().isdigit())
        if (num_descs / len(columnar)) > 0.30:
            print(f"[cascade] Layer 1 columnar rejected: {num_descs}/{len(columnar)} descriptions are pure numbers (misaligned columns)")
            columnar = []

    inherited = list(_parse_generic_dateinherited(pdf_path))
    if inherited:
        num_descs = sum(1 for r in inherited if r["descr"].strip().isdigit())
        if (num_descs / len(inherited)) > 0.30:
            print(f"[cascade] Layer 1 dateinherited rejected: {num_descs}/{len(inherited)} descriptions are pure numbers (misaligned columns)")
            inherited = []
    
    best_l1 = None
    best_l1_breaks = 10**9
    
    if columnar:
        best_l1 = columnar
        best_l1_breaks = _generic_breaks(columnar)
        print(f"[cascade] Layer 1 columnar: {len(columnar)} rows, {best_l1_breaks} balance violations")
    if inherited:
        inherited_breaks = _generic_breaks(inherited)
        print(f"[cascade] Layer 1 dateinherited: {len(inherited)} rows, {inherited_breaks} balance violations")
        if not best_l1 or inherited_breaks < best_l1_breaks:
            best_l1 = inherited
            best_l1_breaks = inherited_breaks
            
    if best_l1 and len(best_l1) >= 3:
        violation_ratio = best_l1_breaks / len(best_l1)
        if best_l1_breaks == 0:
            print(f"[cascade] >>> Layer 1 ACCEPTED (0 violations, confidence=high)")
            return best_l1, "high"
        if violation_ratio <= RULE_BASED_MAX_VIOLATION_RATIO:
            print(f"[cascade] >>> Layer 1 ACCEPTED (violation_ratio={violation_ratio:.3f} <= {RULE_BASED_MAX_VIOLATION_RATIO}, confidence=medium)")
            return best_l1, "medium"
        print(f"[cascade] Layer 1 REJECTED (violation_ratio={violation_ratio:.3f} > {RULE_BASED_MAX_VIOLATION_RATIO}), escalating to Layer 2")
    else:
        print(f"[cascade] Layer 1 produced insufficient rows (best_l1={len(best_l1) if best_l1 else 0}), escalating to Layer 2")

    # Layer 2: Schema Inference
    print("[cascade] Layer 2 (LLM schema inference) running...")
    try:
        l2_res = try_schema_inference(pdf_path, local_cur)
        if l2_res:
            l2_rows, l2_conf = l2_res
            if len(l2_rows) >= SCHEMA_MIN_ROW_COUNT:
                print(f"[cascade] >>> Layer 2 ACCEPTED ({len(l2_rows)} rows, confidence={l2_conf})")
                return l2_rows, l2_conf
            else:
                print(f"[cascade] Layer 2 produced too few rows ({len(l2_rows)} < {SCHEMA_MIN_ROW_COUNT}), escalating to Layer 3")
        else:
            print("[cascade] Layer 2 returned None (regex/match-rate/balance validation failed), escalating to Layer 3")
    except Exception as e:
        print(f"[cascade] Layer 2 ERROR: {e} — escalating to Layer 3")

    # Layer 3: Full LLM chunk extraction
    print("[cascade] Layer 3 (full LLM chunk extraction) running...")
    try:
        l3_res = parse_with_llm_fallback(pdf_path, local_cur)
        if l3_res:
            l3_rows, l3_conf = l3_res
            if len(l3_rows) >= 3:
                l3_breaks = _generic_breaks(l3_rows)
                if best_l1 and best_l1_breaks <= l3_breaks:
                    print(f"[cascade] Layer 3 produced {len(l3_rows)} rows but L1 is better ({best_l1_breaks} vs {l3_breaks} breaks); returning L1 flagged medium")
                    return best_l1, "medium"
                print(f"[cascade] >>> Layer 3 ACCEPTED ({len(l3_rows)} rows, {l3_breaks} breaks, confidence={l3_conf})")
                return l3_rows, l3_conf
            else:
                print(f"[cascade] Layer 3 produced too few rows ({len(l3_rows)})")
    except Exception as e:
        print(f"[cascade] Layer 3 ERROR: {e}")

    # Final fallback: return best L1 or empty
    # When ALL LLMs exhausted, grade the confidence honestly by L1 violation rate.
    # If L1 itself was high-violation (exceeded RULE_BASED_MAX_VIOLATION_RATIO), flag as "low"
    # not "medium" — so the caller can surface this to the user.
    if best_l1:
        if best_l1_breaks > 0:
            final_violation_ratio = best_l1_breaks / len(best_l1)
        else:
            final_violation_ratio = 0.0
        if final_violation_ratio > RULE_BASED_MAX_VIOLATION_RATIO:
            fallback_conf = "low"
            print(f"[cascade] All layers exhausted. Returning best Layer 1 result ({len(best_l1)} rows) with confidence='low' (L1 violation_ratio={final_violation_ratio:.3f} > {RULE_BASED_MAX_VIOLATION_RATIO})")
        else:
            fallback_conf = "medium"
            print(f"[cascade] All layers exhausted. Returning best Layer 1 result ({len(best_l1)} rows, confidence=medium)")
        return best_l1, fallback_conf
    print("[cascade] All layers exhausted with no valid result.")
    return [], "low"


def parse_generic_statement(pdf_path):
    """Generic fallback parser with 4-layer cascade."""
    rows, confidence = _parse_generic_statement_list(pdf_path)
    
    class RowGenerator:
        def __init__(self, rows, confidence):
            self.rows = rows
            self.parse_confidence = confidence
        def __iter__(self):
            return iter(self.rows)
            
    return RowGenerator(rows, confidence)


def is_statement_pdf(path):
    """True if the PDF at `path` looks like a parseable bank statement (any supported
    format: Barclays columnar, or the DR/CR row layout, or PNB, or Wrenfield, or generic fallback). Used to pick statements out of
    a ZIP and to reject non-statement PDFs."""
    try:
        d = pymupdf.open(path)
        start_page = _find_table_start(d)
        head = "".join(d[i].get_text("text") for i in range(start_page, min(start_page + 3, len(d))))
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


def categorize_descriptions_with_llm(descriptions: list) -> dict[str, dict]:
    """Uses the local Ollama LLM to extract clean merchant names and classify categories for a batch of transaction descriptions."""
    valid_categories = ["Groceries", "Transport", "Food & Dining", "Shopping", "Utilities",
                        "Entertainment", "Healthcare", "Investment & Insurance", "Income", "Other"]
    
    items_to_send = []
    idx_to_desc = {}
    for idx, item in enumerate(descriptions):
        desc = item.get("descr", "") if isinstance(item, dict) else item
        hint = item.get("raw_category", "") if isinstance(item, dict) else ""
        idx_str = str(idx)
        idx_to_desc[idx_str] = desc
        items_to_send.append({
            "id": idx_str,
            "description": desc,
            "hint": hint
        })

    prompt = f"""You are a financial assistant. For each of the following transaction items, extract the clean merchant/payee name and classify it into one of these standard categories:
{json.dumps(valid_categories)}

Guideline:
- Analyze both the transaction description and the statement hint (if provided). Map it to the closest matching standard category.
- Avoid the "Other" category as much as possible. Only classify as "Other" if the transaction cannot fit into any of the standard categories (e.g. Groceries, Transport, Food & Dining, Shopping, Utilities, Entertainment, Healthcare, Investment & Insurance, Income).
- Return a JSON object where the keys are the exact "id" from the input.

Return ONLY the raw JSON object mapping each "id" to an object containing "merchant" and "category". Do not include markdown code fences, comments, or explanations.

Input items:
{json.dumps(items_to_send)}"""

    payload = json.dumps({
        "model": os.getenv("LLM_MODEL", "llama3.1:8b"),
        "stream": False,
        "keep_alive": "10m",
        "options": {"temperature": 0.0, "num_ctx": 2048},
        "prompt": prompt
    }).encode("utf-8")
    
    url = f'{os.getenv("OLLAMA_URL", "http://127.0.0.1:11434")}/api/generate'
    try:
        req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=45) as resp:
            res_data = json.loads(resp.read().decode("utf-8"))
            content = res_data.get("response", "").strip()
            
            if "```" in content:
                first_fence = content.find("```")
                last_fence = content.rfind("```")
                if first_fence != last_fence:
                    content = content[first_fence:last_fence]
                    content = re.sub(r"^```[a-zA-Z0-9]*\s*", "", content).strip()
            
            start = content.find("{")
            end = content.rfind("}")
            if start != -1 and end != -1:
                content = content[start:end+1]
                
            parsed_res = json.loads(content)
            mapped_res = {}
            for idx_str, val in parsed_res.items():
                orig_desc = idx_to_desc.get(str(idx_str).strip())
                if orig_desc:
                    mapped_res[orig_desc] = val
            return mapped_res
    except Exception as e:
        print(f"[categorizer] LLM classification failed: {e}")
        return {}



def ingest_pdf(pdf_path, doc_name, user_id, batch=5000):
    """Parse a statement PDF into SQLite (auto-detecting bank via profile registry + cascade).
    Returns count of rows ingested and sets the active display currency to the data."""
    init_db()
    head = ""
    try:
        d = pymupdf.open(pdf_path)
        start_page = _find_table_start(d)
        head = "".join(d[i].get_text("text") for i in range(start_page, min(start_page + 3, len(d))))
        d.close()
    except Exception:
        pass

    # Stage 4 HLD: try profile registry first for known banks
    matched_profile = BankProfileRegistry.match(head)
    profile_currency = matched_profile.get("currency", "") if matched_profile else ""

    # Detect currency code from header text (fallback if profile doesn't have it)
    detected_cur = profile_currency or "INR"
    if not profile_currency:
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
            detected_cur = ""  # clean fallback: no symbol

    # Parser selection: profile-matched banks use their dedicated parsers,
    # everything else falls through to the 3-layer generic cascade.
    profile_bank = (matched_profile.get("bank_name", "") if matched_profile else "").lower()
    if profile_bank in ("barclays",) or is_barclays(head):
        parser = parse_barclays
    elif profile_bank in ("pnb",) or is_pnb(head):
        parser = parse_pnb
    elif profile_bank in ("wrenfield",) or is_wrenfield(head):
        parser = parse_wrenfield
    elif profile_bank in ("hdfc",) or is_transaction_statement(head):
        parser = parse_pdf
    else:
        parser = parse_generic_statement

    # Local import to avoid circular dependencies
    from src.services.nl_sql_engine import extract_account_profile
    acct_profile = extract_account_profile(pdf_path, user_id)
    bank_name = acct_profile.get("bank_name") or (matched_profile.get("bank_name") if matched_profile else None)

    con = connect()
    con.execute("DELETE FROM transactions WHERE user_id=? AND doc_name=?", (user_id, doc_name))

    
    txns_iterable = parser(pdf_path)
    txns = list(txns_iterable)

    # Extract category hints from description text ends for PDF rows
    for t in txns:
        if "descr" in t:
            clean_desc, hint = _extract_description_category_hint(t["descr"])
            if hint:
                t["descr"] = clean_desc
                t["raw_category"] = hint
                norm = _normalize_category(hint)
                if norm:
                    t["category"] = norm

    confidence = getattr(txns_iterable, "parse_confidence", "high")
    
    if not txns:
        con.close()
        return 0

    # Batch classify "Other" categories using local LLM with category hints
    other_txns = []
    seen_descs = set()
    for t in txns:
        if t.get("category") == "Other" and t["descr"] not in seen_descs:
            seen_descs.add(t["descr"])
            other_txns.append({
                "descr": t["descr"],
                "raw_category": t.get("raw_category", "")
            })
            
    if other_txns:
        print(f"[categorizer] Found {len(other_txns)} unique descriptions with category 'Other'. Running LLM categorization...")
        batch_size = 50
        categorized_map = {}
        for i in range(0, len(other_txns), batch_size):
            chunk = other_txns[i:i+batch_size]
            try:
                mapping = categorize_descriptions_with_llm(chunk)
                if mapping:
                    categorized_map.update(mapping)
            except Exception as e:
                print(f"[categorizer] Batch classification failed for chunk {i}: {e}")
        
        valid_categories = {"Groceries", "Transport", "Food & Dining", "Shopping", "Utilities",
                            "Entertainment", "Healthcare", "Investment & Insurance", "Income", "Other"}
        cat_lower_map = {c.lower(): c for c in valid_categories}
        
        for t in txns:
            if t["descr"] in categorized_map:
                val = categorized_map[t["descr"]]
                if isinstance(val, dict):
                    cat = val.get("category")
                    mer = val.get("merchant")
                    if isinstance(cat, str):
                        norm_cat = cat_lower_map.get(cat.strip().lower())
                        if norm_cat:
                            t["category"] = norm_cat
                    if isinstance(mer, str) and mer.strip():
                        # Overwrite merchant if it was poorly parsed (like DR/CR, empty, or fallback raw slice)
                        if t.get("merchant") in ("DR", "CR", "") or t.get("merchant") == t["descr"][:40]:
                            t["merchant"] = mer.strip()
                elif isinstance(val, str):
                    norm_cat = cat_lower_map.get(val.strip().lower())
                    if norm_cat:
                        t["category"] = norm_cat


    import datetime
    now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    con.execute("DELETE FROM document_metadata WHERE user_id=? AND doc_name=?", (user_id, doc_name))
    con.execute("INSERT INTO document_metadata (user_id, doc_name, parse_confidence, upload_ts) VALUES (?, ?, ?, ?)",
                (user_id, doc_name, confidence, now_str))

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


# ---------------------------------------------------------------- CSV / XLSX ingest (Stage 1 HLD)

_CSV_DATE_ALIASES    = {"date", "txn date", "transaction date", "value date", "tran date", "trans date"}
_CSV_DESC_ALIASES    = {"description", "narration", "particulars", "remarks", "details", "transaction remarks"}
_CSV_DEBIT_ALIASES   = {"debit", "withdrawal", "withdrawal amt", "dr", "money out", "payments out", "outgoings"}
_CSV_CREDIT_ALIASES  = {"credit", "deposit", "deposit amt", "cr", "money in", "payments in", "incomings"}
_CSV_BALANCE_ALIASES = {"balance", "closing balance", "running balance", "outstanding amount (inr)", "balance (inr)"}
_CSV_AMOUNT_ALIASES  = {"amount", "transaction amount"}
_CSV_CATEGORY_ALIASES = {"category", "transaction category", "type", "transaction type", "details", "sub-category", "group", "class", "narrative", "remarks"}


def _map_csv_headers(headers: list[str]) -> dict:
    """Map raw CSV column headers to canonical roles. Returns {role: col_index}."""
    mapping = {}
    for idx, h in enumerate(headers):
        hl = h.strip().lower()
        if hl in _CSV_DATE_ALIASES and "date" not in mapping:
            mapping["date"] = idx
        elif hl in _CSV_DESC_ALIASES and "desc" not in mapping:
            mapping["desc"] = idx
        elif hl in _CSV_DEBIT_ALIASES and "debit" not in mapping:
            mapping["debit"] = idx
        elif hl in _CSV_CREDIT_ALIASES and "credit" not in mapping:
            mapping["credit"] = idx
        elif hl in _CSV_BALANCE_ALIASES and "balance" not in mapping:
            mapping["balance"] = idx
        elif hl in _CSV_AMOUNT_ALIASES and "amount" not in mapping:
            mapping["amount"] = idx
        elif hl in _CSV_CATEGORY_ALIASES and "category" not in mapping:
            mapping["category"] = idx
    return mapping


def _normalize_category(val: str) -> str | None:
    if not val:
        return None
    vl = val.strip().lower()
    if any(k in vl for k in ("dining", "restaurant", "cafe", "food", "eat", "takeaway", "pub", "bar")):
        return "Food & Dining"
    if any(k in vl for k in ("utilities", "gas", "water", "electricity", "bills", "energy", "power", "telecom", "mobile")):
        return "Utilities"
    if any(k in vl for k in ("groceries", "supermarket", "grocery", "sainsbury", "tesco", "waitrose", "m&s", "coop", "stores")):
        return "Groceries"
    if any(k in vl for k in ("transport", "travel", "fuel", "petrol", "train", "bus", "tube", "tfl", "uber", "taxi")):
        return "Transport"
    if any(k in vl for k in ("shopping", "retail", "clothing", "amazon", "argos", "boots", "john lewis", "ebay")):
        return "Shopping"
    if any(k in vl for k in ("subscriptions", "subscription", "entertainment", "netflix", "spotify", "gym", "pure gym", "cinema")):
        return "Entertainment"
    if any(k in vl for k in ("salary", "income", "freelance", "interest", "refund", "dividend", "bonus", "pension")):
        return "Income"
    if any(k in vl for k in ("insurance", "investment", "isa", "savings", "shares", "stocks", "bond")):
        return "Investment & Insurance"
    if any(k in vl for k in ("healthcare", "health", "pharmacy", "doctor", "dentist", "medical")):
        return "Healthcare"
    return None


_CATEGORY_HINT_WORDS_2 = {
    "transfer in", "transfer out", "direct debit", "standing order", "card payment"
}
_CATEGORY_HINT_WORDS_1 = {
    "groceries", "grocer", "salary", "income", "transport", "travel", "dining", "food", 
    "utilities", "bills", "shopping", "rent", "subscriptions", "subscription", "entertainment", 
    "healthcare", "health", "insurance", "pension", "refund", "interest", "deposit", 
    "transfer", "outgoings", "incomings", "fees", "fee", "bonus", "cash", "fuel", "dining"
}

def _extract_description_category_hint(desc: str) -> tuple[str, str | None]:
    """Helper to detect and strip category hints from the end of description text.
    Returns (clean_desc, raw_category_hint).
    """
    if not desc:
        return desc, None
        
    # Try 2 words first
    parts = desc.rsplit(maxsplit=2)
    if len(parts) >= 3:
        two_words = f"{parts[-2]} {parts[-1]}".strip().strip(".,()")
        if two_words.lower() in _CATEGORY_HINT_WORDS_2:
            clean = desc[:desc.lower().rfind(two_words.lower())].strip()
            return clean, two_words

    # Try 1 word
    parts_1 = desc.rsplit(maxsplit=1)
    if len(parts_1) == 2:
        last_word = parts_1[1].strip().strip(".,()")
        if last_word.lower() in _CATEGORY_HINT_WORDS_1:
            return parts_1[0].strip(), last_word
            
    return desc, None


def _rows_from_csv_mapping(rows: list[list[str]], mapping: dict, currency: str) -> list[dict]:
    """Convert raw CSV rows + column mapping to canonical transaction dicts."""
    out, seq = [], 0
    for row in rows:
        if not row or all(not c.strip() for c in row):
            continue
        def _cell(role):
            idx = mapping.get(role)
            return row[idx].strip() if idx is not None and idx < len(row) else ""

        date_raw = _cell("date")
        parsed_d = parse_date(date_raw)
        if not parsed_d:
            continue
        yr, mon, day = parsed_d
        iso = f"{yr:04d}-{mon:02d}-{day:02d}"

        desc = _cell("desc") or _cell("description") or ""
        raw_cat = _cell("category")

        # Amount logic: separate debit/credit OR single amount column
        debit_raw  = _cell("debit")
        credit_raw = _cell("credit")
        amount_raw = _cell("amount")

        try:
            if debit_raw or credit_raw:
                debit  = abs(_money(debit_raw))  if debit_raw  else 0.0
                credit = abs(_money(credit_raw)) if credit_raw else 0.0
            elif amount_raw:
                val = _money(amount_raw)
                debit  = abs(val) if val < 0 else 0.0
                credit = val      if val > 0 else 0.0
            else:
                continue   # no money column found — skip row
        except Exception:
            continue

        try:
            balance = _money(_cell("balance")) if _cell("balance") else 0.0
        except Exception:
            balance = 0.0

        merchant, category = _classify(desc)
        norm_cat = _normalize_category(raw_cat)
        if norm_cat:
            category = norm_cat

        seq += 1
        out.append({
            "txn_date": iso, "month": iso[:7],
            "year": yr, "month_no": mon, "day": day,
            "descr": desc[:200], "merchant": merchant, "category": category,
            "debit": debit, "credit": credit, "balance": balance,
            "currency": currency, "seq": seq,
            "raw_category": raw_cat
        })
    return out


def ingest_csv(csv_path: str, doc_name: str, user_id: str, currency: str = "INR", batch: int = 5000) -> int:
    """Ingest a CSV bank statement into SQLite. Returns row count."""
    init_db()
    rows_raw: list[list[str]] = []
    headers: list[str] = []
    try:
        with open(csv_path, newline="", encoding="utf-8-sig") as f:
            reader = csv.reader(f)
            for i, row in enumerate(reader):
                if i == 0:
                    headers = row
                else:
                    rows_raw.append(row)
    except UnicodeDecodeError:
        with open(csv_path, newline="", encoding="latin-1") as f:
            reader = csv.reader(f)
            for i, row in enumerate(reader):
                if i == 0:
                    headers = row
                else:
                    rows_raw.append(row)

    mapping = _map_csv_headers(headers)
    if "date" not in mapping or ("debit" not in mapping and "credit" not in mapping and "amount" not in mapping):
        print(f"[ingest-csv] Could not map required columns from headers: {headers}")
        return 0

    txns = _rows_from_csv_mapping(rows_raw, mapping, currency)
    if not txns:
        return 0

    # LLM categorization for "Other" categories with metadata hints
    other_txns = []
    seen_descs = set()
    for t in txns:
        if t.get("category") == "Other" and t["descr"] not in seen_descs:
            seen_descs.add(t["descr"])
            other_txns.append({
                "descr": t["descr"],
                "raw_category": t.get("raw_category", "")
            })
            
    if other_txns:
        try:
            cmap = categorize_descriptions_with_llm(other_txns)
            valid_cats = {"Groceries","Transport","Food & Dining","Shopping","Utilities",
                          "Entertainment","Healthcare","Investment & Insurance","Income","Other"}
            cat_lower = {c.lower(): c for c in valid_cats}
            for t in txns:
                if t["descr"] in cmap:
                    val = cmap[t["descr"]]
                    if isinstance(val, dict):
                        nc = cat_lower.get((val.get("category") or "").strip().lower())
                        if nc: t["category"] = nc
                        if isinstance(val.get("merchant"), str) and val["merchant"].strip():
                            t["merchant"] = val["merchant"].strip()
        except Exception as e:
            print(f"[ingest-csv] LLM categorization failed: {e}")

    import datetime
    now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    con = connect()
    con.execute("DELETE FROM transactions WHERE user_id=? AND doc_name=?", (user_id, doc_name))
    con.execute("DELETE FROM document_metadata WHERE user_id=? AND doc_name=?", (user_id, doc_name))
    con.execute("INSERT INTO document_metadata (user_id, doc_name, parse_confidence, upload_ts, extraction_confidence) VALUES (?,?,?,?,?)",
                (user_id, doc_name, "high", now_str, 1.0))

    sql = ("INSERT INTO transactions"
           "(user_id,doc_name,bank_name,txn_date,month,year,month_no,day,descr,merchant,category,"
           "debit,credit,balance,currency,seq,extraction_confidence)"
           " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
    buf, n = [], 0
    for t in txns:
        buf.append((user_id, doc_name, None, t["txn_date"], t["month"], t["year"], t["month_no"], t["day"],
                    t["descr"], t["merchant"], t["category"], t["debit"], t["credit"], t["balance"],
                    t["currency"], t["seq"], 1.0))
        if len(buf) >= batch:
            con.executemany(sql, buf); n += len(buf); buf = []
    if buf:
        con.executemany(sql, buf); n += len(buf)
    con.commit(); con.close()
    set_currency(detect_currency(user_id))
    print(f"[ingest-csv] Ingested {n} rows from {csv_path}")
    return n


def ingest_xlsx(xlsx_path: str, doc_name: str, user_id: str, currency: str = "INR", batch: int = 5000) -> int:
    """Ingest an XLSX bank statement into SQLite. Returns row count.
    Requires openpyxl (pip install openpyxl). Gracefully degrades to 0 if not installed.
    """
    try:
        import openpyxl
    except ImportError:
        print("[ingest-xlsx] openpyxl not installed. Run: pip install openpyxl")
        return 0

    try:
        wb = openpyxl.load_workbook(xlsx_path, read_only=True, data_only=True)
        ws = wb.active
        rows_iter = ws.iter_rows(values_only=True)
    except Exception as e:
        print(f"[ingest-xlsx] Failed to open {xlsx_path}: {e}")
        return 0

    raw_rows = []
    headers = []
    for i, row in enumerate(rows_iter):
        cells = [str(c) if c is not None else "" for c in row]
        if i == 0:
            headers = cells
        else:
            raw_rows.append(cells)
    wb.close()

    # Try to convert XLSX to CSV-like and reuse the CSV pipeline
    import io, csv as _csv
    buf = io.StringIO()
    writer = _csv.writer(buf)
    writer.writerow(headers)
    writer.writerows(raw_rows)
    buf.seek(0)

    # Write to a temp file and call ingest_csv
    import tempfile
    with tempfile.NamedTemporaryFile(mode="w", suffix=".csv", delete=False, encoding="utf-8") as tmp:
        tmp.write(buf.getvalue())
        tmp_path = tmp.name

    count = ingest_csv(tmp_path, doc_name, user_id, currency=currency, batch=batch)
    try:
        os.unlink(tmp_path)
    except Exception:
        pass
    return count


def ingest_file(file_path: str, doc_name: str, user_id: str, batch: int = 5000) -> int:
    """Top-level dispatcher: routes .pdf / .csv / .xlsx to the right ingest function.
    This is the single entry point callers should use (Stage 1 HLD file normalizer).
    Returns count of rows ingested.
    """
    ext = pathlib.Path(file_path).suffix.lower()
    if ext == ".pdf":
        return ingest_pdf(file_path, doc_name, user_id, batch=batch)
    elif ext == ".csv":
        return ingest_csv(file_path, doc_name, user_id, batch=batch)
    elif ext in (".xlsx", ".xls"):
        return ingest_xlsx(file_path, doc_name, user_id, batch=batch)
    else:
        print(f"[ingest-file] Unsupported file type: {ext} — attempting PDF parse")
        return ingest_pdf(file_path, doc_name, user_id, batch=batch)



