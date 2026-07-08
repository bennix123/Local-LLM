MONTHS = {"01": "Jan", "02": "Feb", "03": "Mar", "04": "Apr", "05": "May", "06": "Jun",
          "07": "Jul", "08": "Aug", "09": "Sep", "10": "Oct", "11": "Nov", "12": "Dec"}

import re
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


def format_money(n, cur):
    """Money formatter for a SPECIFIC currency (symbol + locale grouping, 2 or 3 decimals dynamically)."""
    neg = n < 0
    currency = (cur or "").upper()
    dec_places = 3 if currency in ("OMR", "KWD", "BHD", "JOD", "IQD") else 2
    n = abs(round(float(n), dec_places))
    fmt_str = f"{{:.{dec_places}f}}"
    intpart, dec = fmt_str.format(n).split(".")
    def grouped(intpart):
        return _group_indian(intpart) if currency == "INR" else f"{int(intpart):,}"
    prefix = _CUR_SYM.get(currency, currency + " " if currency else "")
    return ("-" if neg else "") + prefix + f"{grouped(intpart)}.{dec}"


def inr(n):
    """Money formatter for the ACTIVE currency (symbol + locale grouping, 2 or 3 decimals dynamically)."""
    return format_money(n, CURRENCY)


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


def _dlabel(yyyy_mm_dd):
    return f"{yyyy_mm_dd[8:10]} {MONTHS.get(yyyy_mm_dd[5:7], '')} {yyyy_mm_dd[:4]}"


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


