"""
Generate 1000 questions + VERIFIED answers from the MERGED dataset.

Both statements (statement_1lakh.pdf + statement_5k.pdf, 105,000 rows total) are
already merged in data/live_txn.db. Questions are phrased naturally with NO
"in the 5,000-row / 1-lakh statement" labels; answers are computed by SQL over
the merged table, so the answer key is exact.

Output: data/qa_1000.json  +  data/qa_1000.md
"""
import json
import os
import re
import sqlite3

HERE = os.path.dirname(__file__)
DATA = os.path.join(HERE, "..", "data")
DB = os.path.join(DATA, "live_txn.db")

con = sqlite3.connect(DB)
cur = con.cursor()

MONTHS = ["January", "February", "March", "April", "May", "June", "July",
          "August", "September", "October", "November", "December"]


# ---------- Indian-style formatting ----------
def _ind(s):
    if len(s) <= 3:
        return s
    return re.sub(r"(?<=\d)(?=(\d\d)+$)", ",", s[:-3]) + "," + s[-3:]


def inr(x):
    neg = float(x) < 0
    s = f"{abs(round(float(x), 2)):.2f}"
    i, f = s.split(".")
    return ("-" if neg else "") + "₹" + _ind(i) + "." + f


def grp(n):
    n = int(n)
    return ("-" if n < 0 else "") + _ind(str(abs(n)))


def mlabel(key):
    y, m = key.split("-")
    return f"{MONTHS[int(m) - 1]} {y}"


# ---------- pull all aggregates in a few grouped queries ----------
def rows(sql, *a):
    return cur.execute(sql, a).fetchall()


N_MONTHS = 24

# month list present, sorted
ALL_MONTHS = [r[0] for r in rows("SELECT DISTINCT month FROM transactions ORDER BY month")]
YEARS = [r[0] for r in rows("SELECT DISTINCT year FROM transactions ORDER BY year")]

# spending merchants (debit > 0), ordered by total spend desc
SP_MERCH = [r[0] for r in rows(
    "SELECT merchant, SUM(debit) s FROM transactions GROUP BY merchant HAVING s>0 ORDER BY s DESC")]
# spending categories (debit > 0), ordered by total spend desc
SP_CAT = [r[0] for r in rows(
    "SELECT category, SUM(debit) s FROM transactions GROUP BY category HAVING s>0 ORDER BY s DESC")]

# merchant x month: spend + count
mm_debit, mm_count = {}, {}
for m, mo, s, c in rows(
        "SELECT merchant, month, ROUND(SUM(debit),2), COUNT(*) FROM transactions GROUP BY merchant, month"):
    mm_debit[(m, mo)] = s or 0.0
    mm_count[(m, mo)] = c

# category x month: spend + count
cm_debit, cm_count = {}, {}
for cat, mo, s, c in rows(
        "SELECT category, month, ROUND(SUM(debit),2), COUNT(*) FROM transactions GROUP BY category, month"):
    cm_debit[(cat, mo)] = s or 0.0
    cm_count[(cat, mo)] = c

# merchant totals
m_tot = {}
for m, s, c, mx, dc in rows(
        "SELECT merchant, ROUND(SUM(debit),2), COUNT(*), ROUND(MAX(debit),2), "
        "SUM(CASE WHEN debit>0 THEN 1 ELSE 0 END) FROM transactions GROUP BY merchant"):
    m_tot[m] = {"spend": s or 0.0, "count": c, "max": mx or 0.0, "dcount": dc or 0}

# merchant x year
my_debit = {}
for m, y, s in rows("SELECT merchant, year, ROUND(SUM(debit),2) FROM transactions GROUP BY merchant, year"):
    my_debit[(m, y)] = s or 0.0

# category totals + year
c_tot = {}
for cat, s, c in rows("SELECT category, ROUND(SUM(debit),2), COUNT(*) FROM transactions GROUP BY category"):
    c_tot[cat] = {"spend": s or 0.0, "count": c}
cy_debit = {}
for cat, y, s in rows("SELECT category, year, ROUND(SUM(debit),2) FROM transactions GROUP BY category, year"):
    cy_debit[(cat, y)] = s or 0.0

# month totals
mo_tot = {}
for mo, d, c, n in rows(
        "SELECT month, ROUND(SUM(debit),2), ROUND(SUM(credit),2), COUNT(*) FROM transactions GROUP BY month"):
    mo_tot[mo] = {"debit": d or 0.0, "credit": c or 0.0, "count": n}

# year totals
yr_tot = {}
for y, d, c, n in rows(
        "SELECT year, ROUND(SUM(debit),2), ROUND(SUM(credit),2), COUNT(*) FROM transactions GROUP BY year"):
    yr_tot[y] = {"debit": d or 0.0, "credit": c or 0.0, "count": n}

# overview scalars
TOT_DEBIT = rows("SELECT ROUND(SUM(debit),2) FROM transactions")[0][0]
TOT_CREDIT = rows("SELECT ROUND(SUM(credit),2) FROM transactions")[0][0]
TOT_ROWS = rows("SELECT COUNT(*) FROM transactions")[0][0]
DEBIT_CNT = rows("SELECT COUNT(*) FROM transactions WHERE debit>0")[0][0]
CREDIT_CNT = rows("SELECT COUNT(*) FROM transactions WHERE credit>0")[0][0]
UPI_CNT = rows("SELECT COUNT(*) FROM transactions WHERE descr LIKE '%UPI%'")[0][0]
MAX_DEBIT = rows("SELECT ROUND(MAX(debit),2) FROM transactions WHERE debit>0")[0][0]
MIN_DEBIT = rows("SELECT ROUND(MIN(debit),2) FROM transactions WHERE debit>0")[0][0]
MAX_CREDIT = rows("SELECT ROUND(MAX(credit),2) FROM transactions WHERE credit>0")[0][0]


# ---------- build families: list of (type, question, answer) ----------
def F_merch_month_spend():
    out = []
    for mo in ALL_MONTHS:                       # month-major round-robin -> all merchants covered
        for m in SP_MERCH:
            v = mm_debit.get((m, mo), 0.0)
            if v > 0:
                out.append(("merchant×month spend",
                            f"How much did I spend at {m} in {mlabel(mo)}?", f"{inr(v)}."))
    return out


def F_merch_month_count():
    out = []
    for mo in ALL_MONTHS:
        for m in SP_MERCH:
            c = mm_count.get((m, mo), 0)
            if c > 0:
                out.append(("merchant×month count",
                            f"How many transactions did I make at {m} in {mlabel(mo)}?",
                            f"{grp(c)} transactions."))
    return out


def F_cat_month_spend():
    out = []
    for mo in ALL_MONTHS:
        for cat in SP_CAT:
            v = cm_debit.get((cat, mo), 0.0)
            if v > 0:
                out.append(("category×month spend",
                            f"How much did I spend on {cat} in {mlabel(mo)}?", f"{inr(v)}."))
    return out


def F_cat_month_count():
    out = []
    for mo in ALL_MONTHS:
        for cat in SP_CAT:
            c = cm_count.get((cat, mo), 0)
            if c > 0:
                out.append(("category×month count",
                            f"How many {cat} transactions were there in {mlabel(mo)}?",
                            f"{grp(c)} transactions."))
    return out


def F_merch_total_spend():
    return [("merchant total spend", f"How much have I spent at {m} in total?",
             f"{inr(m_tot[m]['spend'])}.") for m in SP_MERCH]


def F_merch_total_count():
    return [("merchant total count", f"How many transactions did I make at {m} in total?",
             f"{grp(m_tot[m]['count'])} transactions.") for m in SP_MERCH]


def F_merch_year_spend():
    out = []
    for m in SP_MERCH:
        for y in YEARS:
            v = my_debit.get((m, y), 0.0)
            if v > 0:
                out.append(("merchant×year spend",
                            f"How much did I spend at {m} in {y}?", f"{inr(v)}."))
    return out


def F_merch_largest():
    return [("merchant largest txn", f"What was my largest single transaction at {m}?",
             f"{inr(m_tot[m]['max'])}.") for m in SP_MERCH if m_tot[m]['max'] > 0]


def F_merch_avg():
    out = []
    for m in SP_MERCH:
        dc = m_tot[m]['dcount']
        if dc > 0:
            out.append(("merchant avg txn", f"What is my average transaction amount at {m}?",
                        f"{inr(m_tot[m]['spend'] / dc)} per transaction."))
    return out


def F_cat_total_spend():
    return [("category total spend", f"How much did I spend on {cat} overall?",
             f"{inr(c_tot[cat]['spend'])}.") for cat in SP_CAT]


def F_cat_total_count():
    return [("category total count", f"How many {cat} transactions are there overall?",
             f"{grp(c_tot[cat]['count'])} transactions.") for cat in SP_CAT]


def F_cat_year_spend():
    out = []
    for cat in SP_CAT:
        for y in YEARS:
            v = cy_debit.get((cat, y), 0.0)
            if v > 0:
                out.append(("category×year spend",
                            f"How much did I spend on {cat} in {y}?", f"{inr(v)}."))
    return out


def F_cat_avg_month():
    return [("category avg monthly", f"What is my average monthly spend on {cat}?",
             f"{inr(c_tot[cat]['spend'] / N_MONTHS)} per month.") for cat in SP_CAT]


def F_month_spend():
    return [("month spend", f"How much did I spend in {mlabel(mo)}?",
             f"{inr(mo_tot[mo]['debit'])}.") for mo in ALL_MONTHS]


def F_month_income():
    return [("month income", f"How much did I receive in {mlabel(mo)}?",
             f"{inr(mo_tot[mo]['credit'])}.") for mo in ALL_MONTHS]


def F_month_count():
    return [("month count", f"How many transactions were there in {mlabel(mo)}?",
             f"{grp(mo_tot[mo]['count'])} transactions.") for mo in ALL_MONTHS]


def F_year_totals():
    out = []
    for y in YEARS:
        out.append(("year totals", f"How much did I spend in {y}?", f"{inr(yr_tot[y]['debit'])}."))
        out.append(("year totals", f"How much did I receive in {y}?", f"{inr(yr_tot[y]['credit'])}."))
        out.append(("year totals", f"How many transactions were there in {y}?",
                    f"{grp(yr_tot[y]['count'])} transactions."))
    return out


def F_overview():
    return [
        ("overview", "How much have I spent in total?", f"{inr(TOT_DEBIT)}."),
        ("overview", "How much money have I received in total?", f"{inr(TOT_CREDIT)}."),
        ("overview", "What is my net cash flow?", f"{inr(TOT_CREDIT - TOT_DEBIT)} (credits minus debits)."),
        ("overview", "How many transactions are there in total?", f"{grp(TOT_ROWS)} transactions."),
        ("overview", "How many debit transactions are there?", f"{grp(DEBIT_CNT)} debit transactions."),
        ("overview", "How many credit transactions are there?", f"{grp(CREDIT_CNT)} credit transactions."),
        ("overview", "How many UPI transactions are there?", f"{grp(UPI_CNT)} UPI transactions."),
        ("overview", "What was my largest single expense?", f"{inr(MAX_DEBIT)}."),
        ("overview", "What was my smallest single expense?", f"{inr(MIN_DEBIT)}."),
        ("overview", "What was my largest single deposit?", f"{inr(MAX_CREDIT)}."),
        ("overview", "What is my average debit transaction value?", f"{inr(TOT_DEBIT / DEBIT_CNT)} per debit."),
        ("overview", "What is my average monthly spend?", f"{inr(TOT_DEBIT / N_MONTHS)} per month."),
    ]


def F_derived():
    out = []
    tc = SP_CAT[0]
    out.append(("derived", "Which category did I spend the most on?",
                f"{tc} — {inr(c_tot[tc]['spend'])}."))
    out.append(("derived", "Which category did I spend the least on?",
                f"{SP_CAT[-1]} — {inr(c_tot[SP_CAT[-1]]['spend'])}."))
    tm = SP_MERCH[0]
    out.append(("derived", "Which merchant did most of my money go to?",
                f"{tm} — {inr(m_tot[tm]['spend'])}."))
    # top 3 merchants
    top3 = ", ".join(f"{m} ({inr(m_tot[m]['spend'])})" for m in SP_MERCH[:3])
    out.append(("derived", "What are my top 3 merchants by spending?", f"{top3}."))
    # biggest / lowest spend month, highest income month
    bm = max(ALL_MONTHS, key=lambda mo: mo_tot[mo]['debit'])
    lm = min(ALL_MONTHS, key=lambda mo: mo_tot[mo]['debit'])
    hi = max(ALL_MONTHS, key=lambda mo: mo_tot[mo]['credit'])
    bc = max(ALL_MONTHS, key=lambda mo: mo_tot[mo]['count'])
    out.append(("derived", "Which month did I spend the most?", f"{mlabel(bm)} — {inr(mo_tot[bm]['debit'])}."))
    out.append(("derived", "Which month did I spend the least?", f"{mlabel(lm)} — {inr(mo_tot[lm]['debit'])}."))
    out.append(("derived", "Which month did I receive the most money?", f"{mlabel(hi)} — {inr(mo_tot[hi]['credit'])}."))
    out.append(("derived", "Which month had the most transactions?", f"{mlabel(bc)} — {grp(mo_tot[bc]['count'])}."))
    # % share per spending category
    for cat in SP_CAT:
        out.append(("derived", f"What percentage of my spending went to {cat}?",
                    f"{c_tot[cat]['spend'] / TOT_DEBIT * 100:.1f}% ({inr(c_tot[cat]['spend'])} of {inr(TOT_DEBIT)})."))
    # food delivery combo
    sz = m_tot.get('Swiggy', {}).get('spend', 0) + m_tot.get('Zomato', {}).get('spend', 0)
    out.append(("derived", "How much did I spend on food delivery (Swiggy + Zomato)?", f"{inr(sz)}."))
    # category comparisons
    def cmp_cat(a, b):
        va, vb = c_tot[a]['spend'], c_tot[b]['spend']
        hi_, lo_ = (a, b) if va >= vb else (b, a)
        out.append(("derived", f"Did I spend more on {a} or {b}, and by how much?",
                    f"{hi_} — by {inr(abs(va - vb))} ({inr(va)} vs {inr(vb)})."))
    cmp_cat("Shopping", "Groceries")
    cmp_cat("Healthcare", "Transport")
    cmp_cat("Utilities", "Entertainment")
    # merchant comparisons
    def cmp_m(a, b):
        va, vb = m_tot[a]['spend'], m_tot[b]['spend']
        hi_, lo_ = (a, b) if va >= vb else (b, a)
        out.append(("derived", f"Did I spend more at {a} or {b}, and by how much?",
                    f"{hi_} — by {inr(abs(va - vb))} ({inr(va)} vs {inr(vb)})."))
    cmp_m("Amazon", "Flipkart")
    cmp_m("Swiggy", "Zomato")
    cmp_m("Zerodha", "LIC Premium")
    return out


# ordered: small/diverse families first (fully included), big cross-tabs last (filler)
FAMILIES = [
    ("overview", F_overview()),
    ("derived", F_derived()),
    ("month spend", F_month_spend()),
    ("month income", F_month_income()),
    ("month count", F_month_count()),
    ("year totals", F_year_totals()),
    ("category total spend", F_cat_total_spend()),
    ("category total count", F_cat_total_count()),
    ("category avg monthly", F_cat_avg_month()),
    ("category×year spend", F_cat_year_spend()),
    ("merchant total spend", F_merch_total_spend()),
    ("merchant total count", F_merch_total_count()),
    ("merchant largest txn", F_merch_largest()),
    ("merchant avg txn", F_merch_avg()),
    ("merchant×year spend", F_merch_year_spend()),
    ("category×month spend", F_cat_month_spend()),
    ("category×month count", F_cat_month_count()),
    ("merchant×month spend", F_merch_month_spend()),
    ("merchant×month count", F_merch_month_count()),
]

# quotas: take the whole of the small families, then fill the rest from the big
# cross-tab families so the total is exactly 1000.
TARGET = 1000
QUOTA = {
    "overview": 12, "derived": 999, "month spend": 24, "month income": 24,
    "month count": 24, "year totals": 6, "category total spend": 99,
    "category total count": 99, "category avg monthly": 99, "category×year spend": 99,
    "merchant total spend": 99, "merchant total count": 99, "merchant largest txn": 99,
    "merchant avg txn": 99, "merchant×year spend": 99, "category×month spend": 150,
    "category×month count": 110, "merchant×month spend": 220, "merchant×month count": 150,
}

selected = []
for name, items in FAMILIES:
    take = min(QUOTA.get(name, 0), len(items))
    selected.extend(items[:take])

# waterfall: if under target, pull more from the biggest families; if over, trim last
order_fill = ["merchant×month spend", "merchant×month count", "category×month spend", "category×month count"]
fam_map = dict(FAMILIES)
i = 0
while len(selected) < TARGET:
    name = order_fill[i % len(order_fill)]
    items = fam_map[name]
    already = sum(1 for s in selected if s[0] == name)
    if already < len(items):
        selected.append(items[already])
    i += 1
    if i > 100000:
        break
selected = selected[:TARGET]

assert len(selected) == TARGET, f"got {len(selected)}"

QA = [{"id": n + 1, "type": t, "question": q, "answer": a}
      for n, (t, q, a) in enumerate(selected)]

# ---------- write JSON ----------
with open(os.path.join(DATA, "qa_1000.json"), "w", encoding="utf-8") as f:
    json.dump(QA, f, ensure_ascii=False, indent=2)

# ---------- write Markdown (grouped by type for easy manual checking) ----------
groups = {}
for r in QA:
    groups.setdefault(r["type"], []).append(r)
lines = ["# FinQuery — 1000 Verified Q&A (merged dataset, answers from SQL over live_txn.db)\n",
         f"_Merged data: {grp(TOT_ROWS)} transactions from both statements. Every answer computed by SQL._\n"]
for t, rs in groups.items():
    lines.append(f"\n## {t}  ({len(rs)})\n")
    lines.append("| # | Question | Correct Answer |")
    lines.append("|---|----------|----------------|")
    for r in rs:
        lines.append(f"| {r['id']} | {r['question'].replace('|', chr(92)+'|')} | {r['answer'].replace('|', chr(92)+'|')} |")
with open(os.path.join(DATA, "qa_1000.md"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

con.close()
print(f"Wrote {len(QA)} Q&A -> data/qa_1000.json + data/qa_1000.md\n")
print("Breakdown by type:")
for t, rs in sorted(groups.items(), key=lambda kv: -len(kv[1])):
    print(f"  {len(rs):>4}  {t}")
