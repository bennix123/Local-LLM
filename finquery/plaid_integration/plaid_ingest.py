"""Map Plaid transactions onto Penny's SQLite ledger.

Writes to the SAME database txn_store uses (via ts.connect()/ts.DB_PATH), matching
the real ``transactions`` schema + INSERT column order created by txn_store.init_db().
A sync REPLACES the user's rows (single-currency, single-user analysis — same as the
/upload endpoint). The LLM never sees any of this; every figure stays SQL-grounded.
"""
import os
import re
import sys

# Import txn_store the way the repo does from scripts/ ( ../backend on sys.path ),
# but resolve it ourselves so this module is importable from anywhere.
_BACKEND = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "backend"))
if _BACKEND not in sys.path:
    sys.path.insert(0, _BACKEND)
from src.services import txn_store as ts  # noqa: E402

USER = "local"
DOC_NAME = "Plaid Sandbox"

# Plaid Personal-Finance-Category PRIMARY -> Penny's canonical spend label.
# Penny's labels are exactly those txn_store uses (DISCRETIONARY | FIXED_CATS + the
# UK classifier): Shopping, Food & Dining, Entertainment, Utilities, Healthcare,
# Investment & Insurance, Groceries, Transport  (+ Income for credits, Other fallback).
# Only CONCRETE spend labels live here; Income/Transfer/unknown fall through to the
# keyword + sign fallback below, mirroring the Barclays parser's _barclays_merchant.
CATEGORY_MAP = {
    "FOOD_AND_DRINK":     "Food & Dining",
    "GENERAL_MERCHANDISE": "Shopping",
    "HOME_IMPROVEMENT":   "Shopping",
    "ENTERTAINMENT":      "Entertainment",
    "RENT_AND_UTILITIES": "Utilities",
    "MEDICAL":            "Healthcare",
    "PERSONAL_CARE":      "Healthcare",
    "TRANSPORTATION":     "Transport",
    "TRAVEL":             "Transport",
    "LOAN_PAYMENTS":      "Investment & Insurance",
    "BANK_FEES":          "Investment & Insurance",
}


def _pfc(txn):
    """(primary, detailed) from a Plaid personal_finance_category, tolerant of both
    dict-style and model-attribute access. ('', '') when absent."""
    pfc = txn.get("personal_finance_category")
    if not pfc:
        return "", ""
    primary = pfc.get("primary") if hasattr(pfc, "get") else getattr(pfc, "primary", "")
    detailed = pfc.get("detailed") if hasattr(pfc, "get") else getattr(pfc, "detailed", "")
    return str(primary or "").upper(), str(detailed or "").upper()


def _category(txn, merchant, is_credit):
    """Penny category for a Plaid txn. Precedence mirrors the PDF parser: structured
    category first, then merchant keyword (reusing txn_store.UK_MERCHANT_CAT so the
    labels stay identical), then the sign fallback (Income for credits, else Other)."""
    primary, detailed = _pfc(txn)
    if "GROCER" in detailed:
        return "Groceries"
    if primary in CATEGORY_MAP:
        return CATEGORY_MAP[primary]
    low = (merchant or "").lower()
    for kw, cat in ts.UK_MERCHANT_CAT.items():
        if kw in low:
            return cat
    return "Income" if is_credit else "Other"


def _merchant(txn, is_credit):
    """Canonical counterparty name, cleaned the way _barclays_merchant does
    (whitespace collapsed, capped at 60) so merchant_spend/_merch_where/_resolve_merchant
    all resolve it from chat."""
    name = txn.get("merchant_name") or txn.get("name") or ""
    name = re.sub(r"\s{2,}", " ", str(name)).strip(" -:")
    if not name:
        name = "Income" if is_credit else "Unknown"
    return name[:60]


def _row(txn):
    """One Plaid transaction -> the row dict the parsers yield. None if undatable.
    Plaid amount convention: positive = money OUT (debit), negative = money IN (credit)."""
    date = str(txn.get("date") or txn.get("authorized_date") or "")
    if len(date) < 10:
        return None
    amt = float(txn.get("amount") or 0.0)
    debit = amt if amt > 0 else 0.0
    credit = -amt if amt < 0 else 0.0
    is_credit = credit > 0
    merchant = _merchant(txn, is_credit)
    currency = (txn.get("iso_currency_code") or txn.get("unofficial_currency_code")
                or ("GBP" if _default_gbp else "USD"))
    return {
        "txn_date": date, "month": date[:7],
        "year": int(date[:4]), "month_no": int(date[5:7]), "day": int(date[8:10]),
        "descr": str(txn.get("name") or merchant)[:200],
        "merchant": merchant,
        "category": _category(txn, merchant, is_credit),
        "debit": round(debit, 2), "credit": round(credit, 2),
        "currency": str(currency),
        "_tid": str(txn.get("transaction_id") or ""),
    }


_default_gbp = True  # only used when a txn carries no currency at all


def _current_balance(accounts):
    """Anchor for the running balance: the summed CURRENT balance of the depository
    account(s) Plaid returns. None if unavailable (then balances are cumulative-from-0)."""
    if not accounts:
        return None
    dep = [a for a in accounts if str(a.get("type") or "") == "depository"]
    use = dep or list(accounts)
    total, found = 0.0, False
    for a in use:
        bal = a.get("balances")
        cur = (bal.get("current") if bal is not None else None)
        if cur is not None:
            total += float(cur)
            found = True
    return round(total, 2) if found else None


def ingest(transactions, accounts=None, user_id=USER, doc_name=DOC_NAME):
    """Replace this user's rows with the Plaid transactions. Rows are ordered
    chronologically (seq ascending = oldest→newest) and a running ``balance`` is
    reconstructed so the newest row (max seq) equals the account's current balance,
    which is what latest_balance() / 'what's my balance' report. Returns row count."""
    ts.init_db()
    rows = [r for r in (_row(t) for t in transactions) if r]
    # chronological order; transaction_id breaks ties deterministically
    rows.sort(key=lambda r: (r["txn_date"], r["_tid"]))

    anchor = _current_balance(accounts)
    net = sum(r["credit"] - r["debit"] for r in rows)
    running = (anchor - net) if anchor is not None else 0.0
    for i, r in enumerate(rows, start=1):
        running += (r["credit"] - r["debit"])
        r["balance"] = round(running, 2)
        r["seq"] = i

    sql = ("INSERT INTO transactions"
           "(user_id,doc_name,txn_date,month,year,month_no,day,descr,merchant,category,"
           "debit,credit,balance,currency,seq)"
           " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
    params = [(user_id, doc_name, r["txn_date"], r["month"], r["year"], r["month_no"],
               r["day"], r["descr"], r["merchant"], r["category"], r["debit"],
               r["credit"], r["balance"], r["currency"], r["seq"]) for r in rows]

    con = ts.connect()
    con.execute("DELETE FROM transactions WHERE user_id=?", (user_id,))  # replace, like /upload
    if params:
        con.executemany(sql, params)
    con.commit()
    con.close()
    return len(rows)
