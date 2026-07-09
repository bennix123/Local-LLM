import re, sqlite3
from .db import connect, init_db
from .formatters import inr, grp, _money, _mlabel, _plabel, _norm_period, _mname, _dlabel, _table, _pct, format_money, MONTHS
from . import formatters
from .parsers import MERCHANT_MAP
from .queries import (
    overview, coverage, latest_balance, by_category, merchant_spend, by_month,
    income_by_source, top_merchants, txn_count, amount_filter, filtered_summary,
    top_expenses, extreme, merchant_category, merchant_dates, list_transactions,
    balance_extreme, payment_interval, who_paid, balance_after, balance_before,
    balance_delta, months_list, subscription_costs, overall_overview
)
from .insights import save_insights, compute_insights

USER = "local"

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
        cap = int(intent.get("n") or 0) or 100
        ttype = intent.get("txn_type")
        rows, total = list_transactions(user_id, m or None, cat or None, doc_name, period, cap, ttype)
        who = ""
        if m and cat:   who = f" for {_mname(m)} ({cat})"
        elif m:         who = f" for {_mname(m)}"
        elif cat:       who = f" in {cat}"
        if not rows:
            return f"**No transactions found{who}{sfx}.**"
        body = []
        for d, bank, mer, descr, deb, cr, curr in rows:
            name = (mer or descr or "").strip() or "-"
            bank_label = bank or "Unknown Bank"
            amt = format_money(deb, curr) if (deb or 0) > 0 else format_money(cr, curr)
            body.append((_dlabel(d), bank_label, _mname(name[:34]),
                         amt, "Spent" if (deb or 0) > 0 else "Received"))
        head = f"**{grp(total)} transaction{'s' if total != 1 else ''}{who}{sfx}**"
        tail = f"\n\n_Showing the first {grp(len(rows))}._" if total > len(rows) else ""
        return head + "\n\n" + _table(["Date", "Bank", "Merchant", "Amount", "Type"], body) + tail

    if t == "spend":
        oo = overall_overview(user_id, doc_name, period)
        if len(oo["breakdown"]) > 1:
            lines = [f"**Total spending{sfx}:** {inr(oo['debit'])} across {grp(oo['count'])} transactions"]
            for b in oo["breakdown"]:
                dc = txn_count(user_id, "debit", b["doc_name"], period)
                cc = txn_count(user_id, "credit", b["doc_name"], period)
                extra = ""
                if b["credit"] > 0:
                    extra = f" (You also received {format_money(b['credit'], b['currency'])} across {grp(cc)} transaction{'s' if cc != 1 else ''})"
                lines.append(f"  - **{b['bank_name']}**: {format_money(b['debit'], b['currency'])} across {grp(dc)} transactions{extra}")
            return "\n".join(lines)
        else:
            o = overview(user_id, doc_name, period)
            dc = txn_count(user_id, "debit", doc_name, period)   # debit rows only, not income
            extra = ""
            if o.get("credit", 0) > 0:
                cc = txn_count(user_id, "credit", doc_name, period)
                extra = f" (You also received {inr(o['credit'])} across {grp(cc)} transaction{'s' if cc != 1 else ''})"
            return f"**Total spending{sfx}:** {inr(o['debit'])} across {grp(dc)} transactions{extra}"

    if t == "income":
        oo = overall_overview(user_id, doc_name, period)
        if len(oo["breakdown"]) > 1:
            lines = [f"**Total income{sfx}:** {inr(oo['credit'])} across {grp(oo['count'])} transactions"]
            for b in oo["breakdown"]:
                cc = txn_count(user_id, "credit", b["doc_name"], period)
                lines.append(f"  - **{b['bank_name']}**: {format_money(b['credit'], b['currency'])} across {grp(cc)} transactions")
            return "\n".join(lines)
        else:
            o = overview(user_id, doc_name, period)
            return f"**Total income{sfx}:** {inr(o['credit'])}"

    if t == "summary":
        oo = overall_overview(user_id, doc_name, period)
        if len(oo["breakdown"]) > 1:
            lines = [f"**Account summary{sfx}:**"]
            for b in oo["breakdown"]:
                bal = latest_balance(user_id, b["doc_name"], period)
                bal_str = format_money(bal, b["currency"]) if bal is not None else "-"
                lines.append(f"  - **{b['bank_name']}**: Spent {format_money(b['debit'], b['currency'])} | Received {format_money(b['credit'], b['currency'])} | Closing: {bal_str}")
            return "\n".join(lines)
        else:
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

    # ---- loaded bank statements / history of banks ----
    if re.search(r"\blist bank|\bshow.*bank|\bwhat bank|\bwhich bank|\buploaded statement|\bmy statement|\blist document|\bwhat document|\bshow document|\bhistory of bank", q):
        from src.services.txn_store.queries import list_user_documents
        docs = list_user_documents(user_id)
        if not docs:
            return "No bank statements have been uploaded yet."
        lines = ["**Loaded bank statements:**"]
        for d in docs:
            date_range = f"{d['from_date']} to {d['to_date']}" if d["from_date"] else "no dates"
            lines.append(f"  - **{d['bank_name']}** (`{d['doc_name']}`): {d['txn_count']} transactions ({date_range})")
        return "\n".join(lines)

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
        if doc_name is None:
            from src.services.txn_store.queries import overall_balance
            ob = overall_balance(user_id)
            if ob["mixed_currency"]:
                lines = ["**Current balances (mixed currencies):**"]
                for b in ob["breakdown"]:
                    lines.append(f"  - **{b['bank_name']}**: {b['currency']} {b['balance']:,.2f}")
                return "\n".join(lines)
            else:
                lines = [f"**Overall balance:** {ob['currency']} {ob['total']:,.2f}"]
                for b in ob["breakdown"]:
                    lines.append(f"  - **{b['bank_name']}**: {b['currency']} {b['balance']:,.2f}")
                return "\n".join(lines)
        else:
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
        oo = overall_overview(user_id, doc_name, period)
        if oo["mixed_currency"]:
            lines = [f"**Total spending{_suffix(plabel)} (mixed currencies):**"]
            for b in oo["breakdown"]:
                dc = txn_count(user_id, "debit", b["doc_name"], period)
                cc = txn_count(user_id, "credit", b["doc_name"], period)
                extra = ""
                if b["credit"] > 0:
                    extra = f" (You also received {format_money(b['credit'], b['currency'])} across {grp(cc)} transaction{'s' if cc != 1 else ''})"
                lines.append(f"  - **{b['bank_name']}**: {format_money(b['debit'], b['currency'])} across {grp(dc)} transactions{extra}")
            return "\n".join(lines)
        else:
            o = overview(user_id, doc_name, period)
            dc = txn_count(user_id, "debit", doc_name, period)
            extra = ""
            if o.get("credit", 0) > 0:
                cc = txn_count(user_id, "credit", doc_name, period)
                extra = f" (You also received {inr(o['credit'])} across {grp(cc)} transaction{'s' if cc != 1 else ''})"
            return f"**Total spending{_suffix(plabel)}:** {inr(o['debit'])} across {grp(dc)} transactions{extra}"

    if re.search(r"total income|total credit|how much.*(income|earn|credit|receiv)", q):
        oo = overall_overview(user_id, doc_name, period)
        if oo["mixed_currency"]:
            lines = [f"**Total income{_suffix(plabel)} (mixed currencies):**"]
            for b in oo["breakdown"]:
                lines.append(f"  - **{b['bank_name']}**: {format_money(b['credit'], b['currency'])}")
            return "\n".join(lines)
        else:
            o = overview(user_id, doc_name, period)
            return f"**Total income{_suffix(plabel)}:** {inr(o['credit'])}"

    if re.search(r"summary|overview|net position|net (gain|loss)|snapshot", q):
        oo = overall_overview(user_id, doc_name, period)
        if oo["mixed_currency"]:
            lines = [f"**Account summary{_suffix(plabel)} (mixed currencies):**"]
            for b in oo["breakdown"]:
                bal = latest_balance(user_id, b["doc_name"], period)
                bal_str = format_money(bal, b["currency"]) if bal is not None else "-"
                lines.append(f"  - **{b['bank_name']}**: Spent {format_money(b['debit'], b['currency'])} | Received {format_money(b['credit'], b['currency'])} | Closing: {bal_str}")
            return "\n".join(lines)
        else:
            o = overview(user_id, doc_name, period)
            b = latest_balance(user_id, doc_name, period)
            body = [("Transactions", grp(o["count"])), ("Total spending", inr(o["debit"])),
                    ("Total income", inr(o["credit"])), ("Net", inr(o["net"])),
                    ("Closing balance", inr(b) if b is not None else "-")]
            return f"**Account summary{_suffix(plabel)}**\n\n" + _table(["Metric", "Value"], body)

    # if they named a period but we didn't match a known metric, answer the
    # natural default (spend for that period) rather than dropping to advice.
    if has_period:
        oo = overall_overview(user_id, doc_name, period)
        if oo["mixed_currency"]:
            lines = [f"**{plabel} summary (mixed currencies):**"]
            for b in oo["breakdown"]:
                lines.append(f"  - **{b['bank_name']}**: Spent {format_money(b['debit'], b['currency'])} | Received {format_money(b['credit'], b['currency'])}")
            return "\n".join(lines)
        else:
            o = overview(user_id, doc_name, period)
            return (f"**{plabel} summary** — spending {inr(o['debit'])}, income {inr(o['credit'])}, "
                    f"net {inr(o['net'])} over {grp(o['count'])} transactions")

    # not an aggregate question -> let RAG answer
    return None


