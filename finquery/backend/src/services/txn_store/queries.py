import sqlite3, re
from datetime import datetime
from .db import connect
from .formatters import inr, grp, _money, _mlabel, _plabel, _norm_period, _mname, _dlabel, _table, _pct, MONTHS
from . import formatters
from .parsers import MERCHANT_MAP

DISCRETIONARY = {"Shopping", "Entertainment", "Food & Dining", "Other"}
SUBSCRIPTION_MERCHANTS = {"netflix", "spotify", "jio", "airtel", "tata power", "amazon prime"}

ACTIVE_DOC_NAME = None

def _scope(user_id, doc_name, period=None):
    """period filter on txn_date (YYYY-MM-DD), so a prefix works at any granularity:
         None                          -> no filter
         "YYYY" / "YYYY-MM" / "YYYY-MM-DD" -> prefix match (year / month / day)
         ("YYYY-MM-DD", "YYYY-MM-DD")  -> inclusive date range (BETWEEN)
    """
    where = "user_id=?"
    params = [user_id]
    target_doc = doc_name if doc_name is not None else ACTIVE_DOC_NAME
    
    if target_doc:
        if isinstance(target_doc, list):
            where += f" AND doc_name IN ({','.join(['?']*len(target_doc))})"
            params.extend(target_doc)
        else:
            where += " AND doc_name=?"; params.append(target_doc)
    elif formatters.CURRENCY:
        # Only apply currency filter if this user actually HAS rows with that currency.
        # This prevents 'Upload a statement first' when formatters.CURRENCY=INR but data is GBP.
        try:
            _con = connect()
            _cnt = _con.execute(
                "SELECT COUNT(*) FROM transactions WHERE user_id=? AND currency=?",
                (user_id, formatters.CURRENCY)).fetchone()[0]
            _con.close()
        except Exception:
            _cnt = 0
        if _cnt > 0:
            try:
                _con = connect()
                _uniq_curs = len(_con.execute(
                    "SELECT DISTINCT currency FROM transactions WHERE user_id=? AND currency IS NOT NULL",
                    (user_id,)).fetchall())
                _con.close()
            except Exception:
                _uniq_curs = 1
            if _uniq_curs <= 1:
                where += " AND currency=?"; params.append(formatters.CURRENCY)
        # else: drop the currency filter — let all currencies through
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


def reconciliation_rate(user_id, doc_name=None):
    """Parse-quality signal: the % of consecutive rows whose running balance is arithmetically
    consistent (balance[i] == balance[i-1] + credit - debit, within 1 paisa/penny). 100% means
    every parsed figure ties out against the statement's own balance column. Rows are read in
    stored seq order (ingest_pdf writes them oldest-first). Returns {percent, checked, breaks}."""
    w, p = _scope(user_id, doc_name)
    con = connect()
    rows = con.execute(f"SELECT debit, credit, balance FROM transactions WHERE {w} ORDER BY seq", p).fetchall()
    con.close()
    checks = breaks = 0
    prev = None
    for deb, cr, bal in rows:
        if bal is None:
            prev = None
            continue
        if prev is not None:
            checks += 1
            if abs(bal - (prev + (cr or 0.0) - (deb or 0.0))) > 0.01:
                breaks += 1
        prev = bal
    percent = round(100.0 * (checks - breaks) / checks, 1) if checks else None
    return {"percent": percent, "checked": checks, "breaks": breaks}


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
    # MULTI-DOCUMENT STRATEGY: Running balance is a per-account concept. Summing balance
    # directly across multiple documents (doc_name=None) is semantically wrong.
    # If doc_name is None, the dispatcher must intercept and call overall_balance(user_id) instead.
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


def amount_filter(user_id, op, amount, doc_name=None, period=None, merchant=None, category=None, txn_type="debit"):
    """Count + total of transactions over/under an amount, optionally filtered by txn_type (debit/credit)
    and scoped to a merchant and/or a category."""
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
    col = "credit" if txn_type == "credit" else "debit"
    con = connect()
    r = con.execute(f"""SELECT COUNT(*), COALESCE(SUM({col}),0), COALESCE(MAX({col}),0)
                        FROM transactions WHERE {w} AND {col}>0 AND {col} {cmp} ?{extra}""",
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
    rows = con.execute(f"""SELECT txn_date, bank_name, merchant, descr, debit, credit, currency {base}
                           ORDER BY txn_date, seq LIMIT ?""", p + params + [limit]).fetchall()
    con.close()
    return rows, total


def balance_extreme(user_id, kind, doc_name=None, period=None):
    """Minimum or maximum RUNNING balance recorded (kind='min'|'max'). (txn_date, balance) | None.
    Distinct from latest_balance (the closing balance)."""
    # MULTI-DOCUMENT STRATEGY: Extreme balance values are only meaningful per-account.
    # If doc_name=None, this function returns the global min/max across all accounts, which
    # is useful but the caller should specify which bank/doc the extreme value belongs to.
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
    # MULTI-DOCUMENT STRATEGY: Point-in-time balance must be queried per-document.
    # Querying with doc_name=None would return the balance of whichever document had the
    # latest sequence on/before that date, which is incorrect.
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
    # MULTI-DOCUMENT STRATEGY: Scoped to specific merchant transaction. If doc_name=None,
    # the helper _target_txn will find the latest matching transaction across all accounts,
    # which is semantically acceptable but results are clearest when scoped to a single bank.
    r = _target_txn(user_id, keyword, doc_name, period)
    if not r:
        return None
    return {"balance": r[1], "date": r[2]}


def balance_before(user_id, keyword, doc_name=None, period=None):
    """Running balance immediately BEFORE a merchant's transaction. Reconstructed from the
    txn's own after-balance (after + debit − credit); falls back to the prior row's balance."""
    # MULTI-DOCUMENT STRATEGY: Reconstructed per-account. If doc_name=None, it uses the
    # sequence prefix of the matching document, keeping context scoped to that single bank.
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
    # MULTI-DOCUMENT STRATEGY: Computed by subtracting two point-in-time balance_at queries.
    # If doc_name=None, this delta would mix accounts and be incorrect.
    b1, b2 = balance_at(user_id, date1, doc_name), balance_at(user_id, date2, doc_name)
    if b1 is None or b2 is None:
        return None
    return {"start": b1, "end": b2, "delta": b2 - b1}


# ------------------------------------------------------------------ md tables


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


def list_user_documents(user_id):
    """Returns every distinct document a user has uploaded, with bank name, date coverage,
    and row count. Ordered by most-recently-uploaded first."""
    con = connect()
    # Check upload_ts in document_metadata. If missing, fall back to MAX(txn_date)
    has_upload_ts = False
    try:
        r = con.execute("PRAGMA table_info(document_metadata)").fetchall()
        has_upload_ts = any(col[1] == "upload_ts" for col in r)
    except Exception:
        pass

    order_by = "m.upload_ts DESC" if has_upload_ts else "MAX(t.txn_date) DESC"
    
    query = f"""
        SELECT t.doc_name, 
               COALESCE(t.bank_name, t.doc_name) as bank, 
               MIN(t.txn_date) as start_d, 
               MAX(t.txn_date) as end_d, 
               COUNT(*) as cnt, 
               COALESCE(t.currency, 'INR') as curr
        FROM transactions t
        LEFT JOIN document_metadata m ON t.user_id = m.user_id AND t.doc_name = m.doc_name
        WHERE t.user_id = ?
        GROUP BY t.doc_name
        ORDER BY {order_by}
    """
    
    rows = con.execute(query, (user_id,)).fetchall()
    con.close()
    
    return [
        {
            "doc_name": r[0],
            "bank_name": r[1],
            "from_date": r[2],
            "to_date": r[3],
            "txn_count": r[4],
            "currency": r[5]
        }
        for r in rows
    ]


def user_bank_count(user_id):
    """Returns the count of distinct accounts/banks for a user."""
    docs = list_user_documents(user_id)
    return len(docs)


def overall_balance(user_id):
    """Aggregates closing balance across all distinct user documents, with mixed currency safety."""
    docs = list_user_documents(user_id)
    if not docs:
        return {"total": 0.0, "currency": "INR", "mixed_currency": False, "breakdown": []}
    
    breakdown = []
    currencies = set()
    total_val = 0.0
    
    for d in docs:
        bal = latest_balance(user_id, d["doc_name"])
        balance_val = bal if bal is not None else 0.0
        breakdown.append({
            "doc_name": d["doc_name"],
            "bank_name": d["bank_name"],
            "balance": balance_val,
            "currency": d["currency"]
        })
        currencies.add(d["currency"])
        total_val += balance_val
        
    mixed = len(currencies) > 1
    return {
        "total": total_val if not mixed else None,  # mixed currencies should not be summed blindly
        "currency": list(currencies)[0] if len(currencies) == 1 else "MIXED",
        "mixed_currency": mixed,
        "breakdown": breakdown
    }


def overall_overview(user_id, doc_name=None, period=None):
    """Aggregates overview across distinct user documents, with mixed currency safety."""
    docs = list_user_documents(user_id)
    if not docs:
        return {"mixed_currency": False, "count": 0, "debit": 0.0, "credit": 0.0, "net": 0.0, "breakdown": []}
    
    if doc_name:
        if isinstance(doc_name, list):
            docs = [d for d in docs if d["doc_name"] in doc_name]
        else:
            docs = [d for d in docs if d["doc_name"] == doc_name]
            
    breakdown = []
    currencies = set()
    total_debit = 0.0
    total_credit = 0.0
    total_count = 0
    
    for d in docs:
        o = overview(user_id, d["doc_name"], period)
        breakdown.append({
            "doc_name": d["doc_name"],
            "bank_name": d["bank_name"],
            "count": o["count"],
            "debit": o["debit"],
            "credit": o["credit"],
            "net": o["net"],
            "currency": d["currency"]
        })
        currencies.add(d["currency"])
        total_debit += o["debit"]
        total_credit += o["credit"]
        total_count += o["count"]
        
    mixed = len(currencies) > 1
    return {
        "mixed_currency": mixed,
        "count": total_count,
        "debit": total_debit if not mixed else None,
        "credit": total_credit if not mixed else None,
        "net": (total_credit - total_debit) if not mixed else None,
        "currency": list(currencies)[0] if len(currencies) == 1 else "MIXED",
        "breakdown": breakdown
    }



