"""
SERIOUS battery: 200+ well-formed, precise questions where the exact answer is
computable from SQL. Every question's expected value is taken straight from the
deterministic layer (txn_store), then compared to what the live /query returns.

This is a true CORRECTNESS test (not just routing): it catches the router
sending a question to the wrong intent/period (right number, wrong question).

Writes data/rag_serious_sheet.csv.
"""
import os
import sys
import json
import time
import re
import csv
import urllib.request

sys.stdout.reconfigure(encoding="utf-8")
BASE = "http://127.0.0.1:8000"
SHEET = os.path.join(os.path.dirname(__file__), "..", "data", "rag_serious_sheet.csv")

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend", "src"))
from services import txn_store as ts
ts.DB_PATH = os.environ.get(
    "FINQ_DB", os.path.join(os.path.dirname(__file__), "..", "data", "live_txn.db"))
USER = "local"

MON = ["", "January", "February", "March", "April", "May", "June",
       "July", "August", "September", "October", "November", "December"]


def plabel(p):
    if len(p) == 4:
        return p
    if len(p) == 7:
        return f"{MON[int(p[5:7])]} {p[:4]}"
    return f"{int(p[8:10])} {MON[int(p[5:7])]} {p[:4]}"


# ---------- server call ----------
def ask(q, timeout=300):
    data = json.dumps({"question": q}).encode()
    req = urllib.request.Request(BASE + "/query", data=data,
                                 headers={"Content-Type": "application/json"})
    path, parts, t0 = "?", [], time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for line in resp:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            if d.get("type") == "meta":
                path = d.get("path", "?")
            elif d.get("type") == "chunk":
                parts.append(d.get("content", ""))
    return path, " ".join("".join(parts).split()), round(time.time() - t0, 1)


def money(s):
    m = re.search(r"₹\s*([\d,]+(?:\.\d+)?)", s)
    return float(m.group(1).replace(",", "")) if m else None


def last_int(s):
    nums = re.findall(r"[\d][\d,]*", s.split(":")[-1])
    return int(nums[-1].replace(",", "")) if nums else None


# ---------- expected from SQL ----------
def e_over(P):
    return ts.overview(USER, None, P)


def e_category(cat, P):
    for c, amt, _ in ts.by_category(USER, None, P):
        if c == cat:
            return amt
    return 0.0


def e_merchant(m, P):
    return ts.merchant_spend(USER, m, None, P)["debit"]


def e_extreme(P, biggest=True):
    w, pr = ts._scope(USER, None, P)
    con = ts.connect()
    fn = "MAX" if biggest else "MIN"
    r = con.execute(f"SELECT {fn}(debit) FROM transactions WHERE {w} AND debit>0", pr).fetchone()
    con.close()
    return r[0]


# ---------- build the battery ----------
def build():
    cases = []
    years = ["2024", "2025"]
    months = [f"2024-{m:02d}" for m in range(1, 13)] + [f"2025-{m:02d}" for m in range(1, 13)]
    days24 = [f"2024-{m:02d}-15" for m in range(1, 13)]
    days25 = [f"2025-{m:02d}-10" for m in range(1, 13)]
    ranges = [("2024-01", "2024-03"), ("2024-04", "2024-06"), ("2024-07", "2024-09"),
              ("2024-10", "2024-12"), ("2025-01", "2025-06"), ("2024-06", "2025-06")]

    for P in years + months:
        L = plabel(P)
        cases.append((f"how many transactions in {L}?", "count", P, None))
        cases.append((f"how much did I spend in {L}?", "spend", P, None))
        cases.append((f"how much income did I receive in {L}?", "income", P, None))
    for P in days24:
        L = plabel(P)
        cases.append((f"how many transactions on {L}?", "count", P, None))
        cases.append((f"how much did I spend on {L}?", "spend", P, None))
    for P in days25:
        cases.append((f"how many transactions on {plabel(P)}?", "count", P, None))
    for a, b in ranges:
        L = f"{plabel(a)} to {plabel(b)}"
        cases.append((f"how many transactions from {L}?", "count", (a, b), None))
        cases.append((f"how much did I spend from {L}?", "spend", (a, b), None))

    cats = ["Groceries", "Food & Dining", "Transport", "Shopping", "Utilities",
            "Entertainment", "Healthcare", "Investment & Insurance"]
    for cat in cats:
        for P in ["2024", "2025", "2024-06", "2025-03", "2024-12"]:
            cases.append((f"how much did I spend on {cat} in {plabel(P)}?", "category", P, cat))

    merch = ["Swiggy", "Zomato", "Amazon", "Flipkart", "Netflix", "Spotify",
             "Zerodha", "Uber", "BigBasket", "Jio"]
    for m in merch:
        cases.append((f"how much did I spend at {m}?", "merchant", None, m))
        cases.append((f"how much did I spend at {m} in 2024?", "merchant", "2024", m))
        cases.append((f"how much did I spend at {m} in 2025?", "merchant", "2025", m))

    for P in [None, "2024", "2025"]:
        sfx = f" in {plabel(P)}" if P else ""
        cases.append((f"what was my biggest expense{sfx}?", "biggest", P, None))
        cases.append((f"what was my smallest expense{sfx}?", "smallest", P, None))

    cases.append(("show me my top 5 expenses", "topmax", None, None))
    cases.append(("top 10 expenses in 2024", "topmax", "2024", None))
    cases.append(("top 5 expenses in 2025", "topmax", "2025", None))
    cases.append(("what is my current balance?", "balance", None, None))
    return cases


def expected(kind, P, arg):
    if kind == "count":
        return e_over(P)["count"]
    if kind == "spend":
        return e_over(P)["debit"]
    if kind == "income":
        return e_over(P)["credit"]
    if kind == "category":
        return e_category(arg, P)
    if kind == "merchant":
        return e_merchant(arg, P)
    if kind in ("biggest", "topmax"):
        return e_extreme(P, biggest=True)
    if kind == "smallest":
        return e_extreme(P, biggest=False)
    if kind == "balance":
        return ts.latest_balance(USER)
    return None


def check(kind, want, ans):
    if kind == "count":
        got = last_int(ans)
        return (got == int(want)), got
    got = money(ans)
    if want in (0, 0.0) and got is None:
        return True, 0
    ok = got is not None and abs(got - want) < 1.0
    return ok, got


def main():
    cases = build()
    print(f"SERIOUS battery: {len(cases)} precise questions vs SQL truth\n")
    rows, npass = [], 0
    t_all = time.time()
    for i, (q, kind, P, arg) in enumerate(cases, 1):
        want = expected(kind, P, arg)
        try:
            path, ans, dt = ask(q)
        except Exception as e:
            path, ans, dt = "ERROR", f"{type(e).__name__}: {e}", 0.0
        ok, got = check(kind, want, ans)
        npass += ok
        rows.append((q, kind, path, "PASS" if ok else "FAIL",
                     "" if want is None else round(want, 2) if isinstance(want, float) else want,
                     got, dt, ans[:120]))
        if not ok:
            print(f"{i:>3} FAIL [{kind}] {q}\n     want={want} got={got} :: {ans[:80]}")
        if i % 25 == 0:
            print(f"   …{i}/{len(cases)} done ({npass} pass)")

    n = len(cases)
    print(f"\n================= RESULTS =================")
    print(f"CORRECT: {npass}/{n}  ({100*npass/n:.1f}%)   in {time.time()-t_all:.0f}s")
    from collections import Counter
    bykind = Counter(r[1] for r in rows)
    okkind = Counter(r[1] for r in rows if r[3] == "PASS")
    print("by intent:")
    for k in bykind:
        print(f"  {k:<10} {okkind[k]:>3}/{bykind[k]}")

    os.makedirs(os.path.dirname(SHEET), exist_ok=True)
    with open(SHEET, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["#", "question", "kind", "route", "result", "want", "got", "secs", "answer"])
        for i, r in enumerate(rows, 1):
            w.writerow([i, *r])
    print(f"\nSheet: {os.path.abspath(SHEET)}")


if __name__ == "__main__":
    main()
