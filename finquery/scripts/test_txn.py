"""
End-to-end harness for the deterministic SQL layer, independent of FastAPI.

    python scripts/test_txn.py data/statement_5k.pdf

Ingests the PDF into SQLite, verifies SQL aggregates against the *_truth.json
sidecar, prints timings, and runs a battery of natural-language questions
through txn_store.answer() to confirm they return exact comma-formatted tables.
"""
import json
import os
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))
from src.services import txn_store as ts  # noqa: E402

pdf = sys.argv[1] if len(sys.argv) > 1 else "data/statement_5k.pdf"
truth = json.load(open(os.path.splitext(pdf)[0] + "_truth.json"))
USER = "tester@finquery.local"
ts.DB_PATH = os.path.join(os.path.dirname(__file__), "..", "data", "test_txn.db")
if os.path.exists(ts.DB_PATH):
    os.remove(ts.DB_PATH)

print(f"== ingest {pdf} ==")
t0 = time.time()
n = ts.ingest_pdf(pdf, os.path.basename(pdf), USER)
t_ing = time.time() - t0
print(f"  parsed+inserted {n:,} rows in {t_ing:.2f}s  ({n/max(t_ing,0.001):,.0f} rows/s)")

# ---- verify aggregates vs ground truth ----
def close(a, b, tol=0.05):
    return abs(a - b) <= tol

ov = ts.overview(USER)
checks = []
checks.append(("row count", n, truth["rows"], n == truth["rows"]))
checks.append(("total debit", ov["debit"], truth["total_debit"], close(ov["debit"], truth["total_debit"], 1.0)))
checks.append(("total credit", ov["credit"], truth["total_credit"], close(ov["credit"], truth["total_credit"], 1.0)))
checks.append(("net", ov["net"], truth["net"], close(ov["net"], truth["net"], 1.0)))
bal = ts.latest_balance(USER)
checks.append(("final balance", bal, truth["final_balance"], close(bal, truth["final_balance"], 1.0)))

# category totals
cat_db = {c: t for c, t, _ in ts.by_category(USER)}
for cat, exp in truth["by_category"].items():
    if exp <= 0:
        continue
    got = cat_db.get(cat, 0.0)
    checks.append((f"cat {cat}", got, exp, close(got, exp, 1.0)))

t0 = time.time()
qtime = ts.overview(USER)
print(f"\n== aggregate checks (ground-truth) ==")
ok = 0
for name, got, exp, passed in checks:
    ok += passed
    flag = "OK " if passed else "XX "
    print(f"  {flag} {name:<28} got={got:<18} exp={exp}")
print(f"  {ok}/{len(checks)} aggregate checks passed")

# ---- query latency at this scale ----
t0 = time.time()
for _ in range(50):
    ts.overview(USER)
print(f"\n== query latency ==  overview x50: {(time.time()-t0)*1000/50:.1f} ms/query")

# ---- NL question battery ----
print(f"\n== natural-language answers (deterministic) ==")
questions = [
    "what is my total spending?",
    "how much total income did I get?",
    "give me an account summary",
    "show me spending by category",
    "how much did I spend on swiggy?",
    "how much did I spend on amazon?",
    "how much did I spend on groceries?",
    "what is my current balance?",
    "how many transactions do I have?",
    "what is my biggest expense?",
    "what is my smallest expense?",
    "show me my top 5 expenses",
    "give me a month-wise breakdown",
    "how can I save money?",  # -> should return None (RAG fallback)
]
for q in questions:
    a = ts.answer(q, USER)
    if a is None:
        print(f"\nQ: {q}\n   -> (None: falls back to RAG)")
    else:
        first = a.split(chr(10))[0]
        print(f"\nQ: {q}\n   {a if len(a) < 400 else first + ' ...[table]'}")
