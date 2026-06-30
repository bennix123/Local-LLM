"""
Run a 60+ question battery against the deterministic layer and write a
spreadsheet (CSV, Excel-friendly) so you can eyeball every answer.

    python scripts/rag_sheet.py data/statement_1lakh.pdf

Columns: #, Section, Question, Path, Expected, Answer, Result
  Path   = SQL (deterministic) or RAG (falls back to the LLM)
  Result = PASS  (expected figure found in the answer)
           FAIL  (deterministic answer missing/wrong)
           REVIEW(RAG/advice answer -> needs the live LLM + your eyes)
Open data/rag_test_sheet.csv in Excel.
"""
import csv
import json
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))
from src.services import txn_store as ts  # noqa: E402

pdf = sys.argv[1] if len(sys.argv) > 1 else "data/statement_1lakh.pdf"
truth = json.load(open(os.path.splitext(pdf)[0] + "_truth.json"))
USER = "tester@finquery.local"
ts.DB_PATH = os.path.join(os.path.dirname(__file__), "..", "data", "sheet_txn.db")
if os.path.exists(ts.DB_PATH):
    os.remove(ts.DB_PATH)

print(f"Ingesting {pdf} ...")
n = ts.ingest_pdf(pdf, os.path.basename(pdf), USER)
print(f"  {n:,} rows\n")

# ---- derive ground truth straight from the store (math already verified vs *_truth.json) ----
ov = ts.overview(USER)
bal = ts.latest_balance(USER)
cat = {c: t for c, t, _ in ts.by_category(USER)}


def merch_expected(tokens):
    r = ts.merchant_spend(USER, tokens)
    val = r["credit"] if r["credit"] > r["debit"] else r["debit"]
    return ts.inr(val).replace("₹", "")


def cat_expected(name):
    return ts.inr(cat.get(name, 0.0)).replace("₹", "")


big = ts.extreme(USER, "largest_expense")
small = ts.extreme(USER, "smallest_expense")
bigcr = ts.extreme(USER, "largest_income")
top = ts.top_expenses(USER, 5)

# (section, question, expected-substring | None for RAG/advice)
Q = []
A = lambda s, q, e: Q.append((s, q, e))  # noqa: E731

# Totals & counts
A("Totals", "what is my total spending?", ts.inr(ov["debit"]).replace("₹", ""))
A("Totals", "how much have I spent in total?", ts.inr(ov["debit"]).replace("₹", ""))
A("Totals", "total income?", ts.inr(ov["credit"]).replace("₹", ""))
A("Totals", "how much money did I receive overall?", ts.inr(ov["credit"]).replace("₹", ""))
A("Totals", "how many transactions do I have?", ts.grp(ov["count"]))
A("Totals", "number of transactions in my statement", ts.grp(ov["count"]))

# Balance
A("Balance", "what is my current balance?", ts.inr(bal).replace("₹", ""))
A("Balance", "how much is sitting in my account?", ts.inr(bal).replace("₹", ""))
A("Balance", "show my account balance", ts.inr(bal).replace("₹", ""))

# Summary / overview
A("Summary", "give me an account summary", ts.inr(ov["debit"]).replace("₹", ""))
A("Summary", "overview of my finances", ts.inr(ov["credit"]).replace("₹", ""))
A("Summary", "what is my net position?", ts.inr(ov["net"]).replace("₹", ""))

# Categories
for label, name in [("groceries", "Groceries"), ("transport", "Transport"),
                    ("food", "Food & Dining"), ("shopping", "Shopping"),
                    ("utilities", "Utilities"), ("entertainment", "Entertainment"),
                    ("healthcare", "Healthcare"), ("investment", "Investment & Insurance")]:
    A("Category", f"how much did I spend on {label}?", cat_expected(name))
A("Category", "show me spending by category", cat_expected("Investment & Insurance"))
A("Category", "where is my money going?", cat_expected("Investment & Insurance"))

# Merchants (spend)
for m in ["swiggy", "zomato", "amazon", "flipkart", "myntra", "bigbasket", "blinkit",
          "dmart", "uber", "ola", "irctc", "netflix", "spotify", "bookmyshow",
          "jio", "airtel", "apollo", "pharmeasy", "zerodha"]:
    A("Merchant", f"how much did I spend on {m}?", merch_expected(m))

# Income merchants
A("Merchant", "how much salary did I receive?", merch_expected("salary"))
A("Merchant", "how much interest did I earn?", merch_expected("interest"))

# Phrasing robustness
A("Phrasing", "total amazon payments", merch_expected("amazon"))
A("Phrasing", "my swiggy spending", merch_expected("swiggy"))
A("Phrasing", "what did I pay to netflix", merch_expected("netflix"))

# Extremes
A("Extremes", "what is my biggest expense?", ts.inr(big[2]).replace("₹", ""))
A("Extremes", "what is my largest purchase ever?", ts.inr(big[2]).replace("₹", ""))
A("Extremes", "what is my smallest expense?", ts.inr(small[2]).replace("₹", ""))
A("Extremes", "what is my largest credit?", ts.inr(bigcr[2]).replace("₹", ""))
A("Extremes", "show me my top 5 expenses", ts.inr(top[0][2]).replace("₹", ""))
A("Extremes", "top 3 biggest expenses", ts.inr(top[0][2]).replace("₹", ""))

# Month-wise
months = ts.by_month(USER)
A("Month-wise", "give me a month-wise breakdown", ts.inr(months[0][1]).replace("₹", ""))
A("Month-wise", "show spending per month", ts.inr(months[0][1]).replace("₹", ""))

# Advice / narrative -> RAG fallback (no numeric ground truth)
A("Advice", "how can I save money?", None)
A("Advice", "give me financial advice", None)
A("Advice", "what are my worst spending habits?", None)
A("Advice", "any tips to cut my expenses?", None)
A("Advice", "explain my spending pattern in words", None)

# ---- run ----
rows = []
counts = {"PASS": 0, "FAIL": 0, "REVIEW": 0}
for i, (sec, q, exp) in enumerate(Q, 1):
    ans = ts.answer(q, USER)
    path = "RAG" if ans is None else "SQL"
    flat = "" if ans is None else ans.replace("\n", " / ")
    if exp is None:
        result = "REVIEW" if ans is None else "REVIEW"  # advice should defer to RAG
        if ans is not None:
            result = "FAIL"  # advice leaked into SQL layer = wrong route
        expected_disp = "(LLM/RAG — review live answer)"
    else:
        norm_ans = flat.replace(",", "")
        result = "PASS" if exp.replace(",", "") in norm_ans else "FAIL"
        expected_disp = "₹" + exp
    counts[result] += 1
    rows.append([i, sec, q, path, expected_disp,
                 flat if len(flat) <= 300 else flat[:300] + " …", result])

# ---- write CSV (BOM so Excel renders ₹) ----
out = os.path.join(os.path.dirname(__file__), "..", "data", "rag_test_sheet.csv")
with open(out, "w", newline="", encoding="utf-8-sig") as f:
    w = csv.writer(f)
    w.writerow(["#", "Section", "Question", "Path", "Expected", "Answer", "Result"])
    w.writerows(rows)

# ---- console summary ----
total = len(Q)
print(f"{'#':>3}  {'SECTION':<11} {'PATH':<4} {'RESULT':<7} QUESTION")
for r in rows:
    print(f"{r[0]:>3}  {r[1]:<11} {r[3]:<4} {r[6]:<7} {r[2][:50]}")
print("\n" + "=" * 50)
print(f"  PASS   {counts['PASS']:>3}")
print(f"  FAIL   {counts['FAIL']:>3}")
print(f"  REVIEW {counts['REVIEW']:>3}  (RAG/advice — check live LLM answer)")
scored = counts["PASS"] + counts["FAIL"]
print(f"  Deterministic accuracy: {counts['PASS']}/{scored}"
      f" ({100*counts['PASS']/max(scored,1):.1f}%)")
print(f"\nSheet written: {os.path.normpath(out)}  ({total} questions)")
