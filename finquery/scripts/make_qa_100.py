"""
Generate 100 questions + VERIFIED correct answers from the two RAG datasets.

Ground truth = data/statement_1lakh_truth.json  (100,000-row statement)
             = data/statement_5k_truth.json      (5,000-row statement)

Every answer is computed deterministically from the truth JSONs (no LLM, no SQL),
so the answer key is exact. Output: data/qa_100.json + data/qa_100.md
"""
import json
import os
import re

HERE = os.path.dirname(__file__)
DATA = os.path.join(HERE, "..", "data")

with open(os.path.join(DATA, "statement_1lakh_truth.json"), encoding="utf-8") as f:
    BIG = json.load(f)
with open(os.path.join(DATA, "statement_5k_truth.json"), encoding="utf-8") as f:
    SMALL = json.load(f)

MONTHS = ["January", "February", "March", "April", "May", "June", "July",
          "August", "September", "October", "November", "December"]


def _ind(intstr):
    """Indian-style grouping of a digit string: 100000 -> 1,00,000."""
    if len(intstr) <= 3:
        return intstr
    last3, rest = intstr[-3:], intstr[:-3]
    rest = re.sub(r"(?<=\d)(?=(\d\d)+$)", ",", rest)
    return rest + "," + last3


def inr(x):
    """Rupee amount, 2 decimals, Indian commas: 374186872.45 -> ₹37,41,86,872.45"""
    neg = float(x) < 0
    s = f"{abs(round(float(x), 2)):.2f}"
    intp, frac = s.split(".")
    return ("-" if neg else "") + "₹" + _ind(intp) + "." + frac


def grp(n):
    """Integer count, Indian commas: 100000 -> 1,00,000"""
    n = int(n)
    return ("-" if n < 0 else "") + _ind(str(abs(n)))


def mlabel(key):
    """'2024-03' -> 'March 2024'"""
    y, m = key.split("-")
    return f"{MONTHS[int(m) - 1]} {y}"


def nonzero_merchants(d):
    return {k: v for k, v in d["by_merchant"].items() if v > 0}


def nonzero_cats(d):
    return {k: v for k, v in d["by_category"].items() if v > 0}


def top_cat(d):
    return max(nonzero_cats(d).items(), key=lambda kv: kv[1])


def top_merch(d):
    return max(nonzero_merchants(d).items(), key=lambda kv: kv[1])


def max_month_debit(d):
    return max(d["by_month"].items(), key=lambda kv: kv[1]["debit"])


def min_month_debit(d):
    return min(d["by_month"].items(), key=lambda kv: kv[1]["debit"])


def max_month_credit(d):
    return max(d["by_month"].items(), key=lambda kv: kv[1]["credit"])


QA = []


def add(dataset, cat, q, a):
    QA.append({"id": len(QA) + 1, "dataset": dataset, "category": cat,
               "question": q, "answer": a})


# Merchants/categories/months chosen for the per-dataset questions
MERCHANTS = ["Zomato", "Swiggy", "Amazon", "Flipkart", "Zerodha", "Netflix",
             "DMart", "LIC Premium", "Axis Bank Car Loan", "Tata Power"]
CATS = ["Groceries", "Shopping", "Investment & Insurance", "Healthcare",
        "Food & Dining", "Transport", "Utilities", "Entertainment"]
DMONTHS = ["2024-01", "2024-06", "2025-12"]      # debit/spend months to ask about
CMONTHS = ["2024-10", "2025-03", "2025-09"]      # credit/income months to ask about


def per_dataset(d, name):
    nmonths = len(d["by_month"])

    # ---- overview (11) ----
    add(name, "overview", f"How many transactions are in the {name} statement?",
        f"{grp(d['rows'])} transactions.")
    add(name, "overview", f"What is the total amount spent (total debits) in the {name} statement?",
        f"{inr(d['total_debit'])} spent across {grp(d['debit_count'])} debit transactions.")
    add(name, "overview", f"What is the total money received (total credits) in the {name} statement?",
        f"{inr(d['total_credit'])} received across {grp(d['credit_count'])} credit transactions.")
    add(name, "overview", f"What is the net cash flow in the {name} statement?",
        f"{inr(d['net'])} net (credits minus debits).")
    add(name, "overview", f"What is the final/closing balance in the {name} statement?",
        f"{inr(d['final_balance'])}.")
    add(name, "overview", f"How many UPI transactions are there in the {name} statement?",
        f"{grp(d['upi_count'])} UPI transactions.")
    add(name, "overview", f"How many debit transactions are there in the {name} statement?",
        f"{grp(d['debit_count'])} debit transactions.")
    add(name, "overview", f"How many credit transactions are there in the {name} statement?",
        f"{grp(d['credit_count'])} credit transactions.")
    add(name, "overview", f"What was the largest single debit (biggest expense) in the {name} statement?",
        f"{inr(d['largest_debit'])}.")
    add(name, "overview", f"What was the smallest single debit in the {name} statement?",
        f"{inr(d['smallest_debit'])}.")
    add(name, "overview", f"What was the largest single credit (biggest deposit) in the {name} statement?",
        f"{inr(d['largest_credit'])}.")

    # ---- categories (8) ----
    for c in CATS:
        add(name, "category", f"How much was spent on {c} in the {name} statement?",
            f"{inr(d['by_category'][c])}.")

    # ---- merchants (10) ----
    for m in MERCHANTS:
        add(name, "merchant", f"How much was spent at {m} in the {name} statement?",
            f"{inr(d['by_merchant'][m])}.")

    # ---- months (6) ----
    for mk in DMONTHS:
        add(name, "month", f"How much was spent in {mlabel(mk)} in the {name} statement?",
            f"{inr(d['by_month'][mk]['debit'])} in debits.")
    for mk in CMONTHS:
        add(name, "month", f"How much was received in {mlabel(mk)} in the {name} statement?",
            f"{inr(d['by_month'][mk]['credit'])} in credits.")

    # ---- derived / analytics (10) ----
    tc, tcv = top_cat(d)
    add(name, "derived", f"Which category had the highest spend in the {name} statement?",
        f"{tc} — {inr(tcv)}.")
    tm, tmv = top_merch(d)
    add(name, "derived", f"Which merchant did the most money go to in the {name} statement?",
        f"{tm} — {inr(tmv)}.")
    mk, mv = max_month_debit(d)
    add(name, "derived", f"Which month had the highest spending in the {name} statement?",
        f"{mlabel(mk)} — {inr(mv['debit'])}.")
    mk2, mv2 = min_month_debit(d)
    add(name, "derived", f"Which month had the lowest spending in the {name} statement?",
        f"{mlabel(mk2)} — {inr(mv2['debit'])}.")
    ck, cv = max_month_credit(d)
    add(name, "derived", f"Which month had the highest income/credits in the {name} statement?",
        f"{mlabel(ck)} — {inr(cv['credit'])}.")
    add(name, "derived", f"What is the average monthly spend in the {name} statement?",
        f"{inr(d['total_debit'] / nmonths)} per month (over {nmonths} months).")
    add(name, "derived", f"What is the average value of a debit transaction in the {name} statement?",
        f"{inr(d['total_debit'] / d['debit_count'])} per debit.")
    inv = d["by_category"]["Investment & Insurance"]
    add(name, "derived",
        f"What share of total spending went to Investment & Insurance in the {name} statement?",
        f"{inv / d['total_debit'] * 100:.1f}% ({inr(inv)} of {inr(d['total_debit'])}).")
    sz = d["by_merchant"]["Swiggy"] + d["by_merchant"]["Zomato"]
    add(name, "derived", f"How much was spent on food delivery (Swiggy + Zomato) in the {name} statement?",
        f"{inr(sz)} (Swiggy {inr(d['by_merchant']['Swiggy'])} + Zomato {inr(d['by_merchant']['Zomato'])}).")
    sh, gr = d["by_category"]["Shopping"], d["by_category"]["Groceries"]
    hi, lo = ("Shopping", "Groceries") if sh >= gr else ("Groceries", "Shopping")
    add(name, "derived", f"Did Shopping or Groceries cost more in the {name} statement, and by how much?",
        f"{hi} cost more — by {inr(abs(sh - gr))} ({inr(sh)} vs {inr(gr)}).")


NAME_BIG = "1-lakh (100,000-row)"
NAME_SMALL = "5,000-row"
per_dataset(BIG, NAME_BIG)      # 45 questions
per_dataset(SMALL, NAME_SMALL)  # 45 questions

# ---- combined / cross-dataset (10) ----
B = "Both datasets combined"
add(B, "combined", "How many transactions are there in total across both statements?",
    f"{grp(BIG['rows'] + SMALL['rows'])} transactions "
    f"({grp(BIG['rows'])} + {grp(SMALL['rows'])}).")
add(B, "combined", "What is the total amount spent across both statements?",
    f"{inr(BIG['total_debit'] + SMALL['total_debit'])}.")
add(B, "combined", "What is the total money received across both statements?",
    f"{inr(BIG['total_credit'] + SMALL['total_credit'])}.")
add(B, "combined", "What is the combined net cash flow across both statements?",
    f"{inr(BIG['net'] + SMALL['net'])}.")
add(B, "combined", "Which statement has more transactions, and by how many?",
    f"The 1-lakh statement — by {grp(BIG['rows'] - SMALL['rows'])} "
    f"({grp(BIG['rows'])} vs {grp(SMALL['rows'])}).")
add(B, "combined", "Which statement had higher total spending, and by how much?",
    f"The 1-lakh statement — by {inr(BIG['total_debit'] - SMALL['total_debit'])}.")
add(B, "combined", "How much was spent at Zerodha across both statements?",
    f"{inr(BIG['by_merchant']['Zerodha'] + SMALL['by_merchant']['Zerodha'])}.")
add(B, "combined", "How much was spent at Amazon across both statements?",
    f"{inr(BIG['by_merchant']['Amazon'] + SMALL['by_merchant']['Amazon'])}.")
add(B, "combined", "How much was spent on Shopping across both statements?",
    f"{inr(BIG['by_category']['Shopping'] + SMALL['by_category']['Shopping'])}.")
add(B, "combined", "What was the largest single debit seen in either statement?",
    f"{inr(max(BIG['largest_debit'], SMALL['largest_debit']))} "
    f"(in the {'1-lakh' if BIG['largest_debit'] >= SMALL['largest_debit'] else '5,000-row'} statement).")

assert len(QA) == 100, f"expected 100, got {len(QA)}"

# ---- write JSON ----
out_json = os.path.join(DATA, "qa_100.json")
with open(out_json, "w", encoding="utf-8") as f:
    json.dump(QA, f, ensure_ascii=False, indent=2)

# ---- write Markdown ----
out_md = os.path.join(DATA, "qa_100.md")
groups = {}
for r in QA:
    groups.setdefault(r["dataset"], []).append(r)
lines = ["# FinQuery — 100 Verified Q&A (answers computed from the truth JSONs)\n"]
for ds, rows in groups.items():
    lines.append(f"\n## {ds}  ({len(rows)} questions)\n")
    lines.append("| # | Question | Correct Answer |")
    lines.append("|---|----------|----------------|")
    for r in rows:
        q = r["question"].replace("|", "\\|")
        a = r["answer"].replace("|", "\\|")
        lines.append(f"| {r['id']} | {q} | {a} |")
with open(out_md, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")

print(f"Wrote {len(QA)} Q&A")
print(f"  {out_json}")
print(f"  {out_md}")
print("\nBreakdown by dataset:")
for ds, rows in groups.items():
    print(f"  {ds}: {len(rows)}")
print("\nBreakdown by type:")
bytype = {}
for r in QA:
    bytype[r["category"]] = bytype.get(r["category"], 0) + 1
for t, n in bytype.items():
    print(f"  {t}: {n}")
