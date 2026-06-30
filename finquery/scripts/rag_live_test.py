"""
End-to-end RAG test against the LIVE test_server (/query).

For each question it:
  - POSTs to /query, reads the ndjson stream, records the ROUTE (meta.path:
    SQL / chat / advice) and the reassembled answer text.
  - Marks PASS/FAIL on whether the route matches what we expect for that
    class of question (does the LLM router send it to the right place?).

It then runs a CONSISTENCY block that calls the deterministic SQL layer
directly on the same DB and checks the live answers agree with it (numbers
must come from SQL, never drift).

Writes data/rag_live_sheet.csv for eyeballing.
"""
import sys, os, io, json, time, urllib.request

sys.stdout.reconfigure(encoding="utf-8")

BASE = "http://127.0.0.1:8000"
SHEET = os.path.join(os.path.dirname(__file__), "..", "data", "rag_live_sheet.csv")

# Pull in the deterministic layer to cross-check numbers.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend", "src"))
from services import txn_store as ts
ts.DB_PATH = os.path.join(os.path.dirname(__file__), "..", "data", "live_txn.db")
USER = "local"


def ask(q, timeout=320):
    """POST /query, drain the ndjson stream, return (path, full_text)."""
    data = json.dumps({"question": q}).encode()
    req = urllib.request.Request(BASE + "/query", data=data,
                                 headers={"Content-Type": "application/json"})
    path, parts = "?", []
    t0 = time.time()
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
    return path, "".join(parts).strip(), round(time.time() - t0, 1)


# (question, expected_route)  expected_route in {SQL, chat, advice}
CASES = [
    # -- smalltalk / greetings (LLM should NOT dump insights) --
    ("hi",                                   "chat"),
    ("kaise ho",                             "chat"),
    ("good morning",                         "chat"),
    ("wewe",                                 "chat"),   # gibberish -> smalltalk-ish
    # -- help --
    ("what can you do?",                     "chat"),
    ("help",                                 "chat"),
    # -- counts --
    ("how many transactions in 2024?",       "SQL"),
    ("no of transaction done in april 2024?", "SQL"),
    ("transection count 2024",               "SQL"),   # typo
    # -- spend --
    ("how much did I spend in 2024?",        "SQL"),
    ("total spending in march 2025",         "SQL"),
    ("hw mch did i spnd in 2025",            "SQL"),    # typo
    ("how much i spend on 1 jan 2024",       "SQL"),    # day granularity
    # -- income / balance --
    ("total income in 2024",                 "SQL"),
    ("what's my latest balance?",            "SQL"),
    # -- breakdown / category / merchant --
    ("spending by category",                 "SQL"),
    ("how much did I spend on Food?",        "SQL"),
    ("how much did I spend at Netflix?",     "SQL"),
    # -- extremes / top --
    ("what was my biggest expense?",         "SQL"),
    ("top 5 expenses",                       "SQL"),
    # -- coverage / subscriptions --
    ("what period does my data cover?",      "SQL"),
    ("what subscriptions am I paying for?",  "SQL"),
    # -- range --
    ("spending from may to july 2024",       "SQL"),
    # -- elliptical follow-up (reuse intent from prior) --
    ("how many transactions in 2025?",       "SQL"),    # set context
    ("and in 2024?",                         "SQL"),    # should reuse COUNT
    # -- follow-up ABOUT the last answer --
    ("what does that number mean?",          "chat"),
    # -- advice / vague --
    ("how can I save money?",                "advice"),
    ("am I spending too much?",              "advice"),
    ("give me some advice",                  "advice"),
]


def first_num(s):
    """First rupee figure in a string, as a float, or None."""
    import re
    m = re.search(r"[₹]\s*([\d,]+(?:\.\d+)?)", s)
    return float(m.group(1).replace(",", "")) if m else None


def main():
    print(f"Testing {len(CASES)} questions against {BASE}/query\n")
    rows = []
    npass = 0
    for i, (q, exp) in enumerate(CASES, 1):
        try:
            path, ans, dt = ask(q)
        except Exception as e:
            path, ans, dt = "ERROR", f"{type(e).__name__}: {e}", 0.0
        ok = (path == exp)
        npass += ok
        flat = " ".join(ans.split())
        snippet = flat[:90] + ("…" if len(flat) > 90 else "")
        print(f"{i:>2} [{'PASS' if ok else 'FAIL'}] route={path:<6}(exp {exp:<6}) {dt:>4}s  {q}")
        if not ok or path == "ERROR":
            print(f"      -> {snippet}")
        rows.append((q, exp, path, "PASS" if ok else "FAIL", dt, flat))

    print(f"\nROUTING: {npass}/{len(CASES)} routed as expected")

    # ---- consistency: live SQL answers must match the deterministic layer ----
    print("\nCONSISTENCY CHECKS (live answer vs direct SQL):")
    checks = []

    # total spend 2024  (spend == debit)
    p, a, _ = ask("how much did I spend in 2024?")
    want = ts.overview(USER, None, "2024")["debit"]
    live = first_num(a)
    checks.append(("spend 2024", want, live,
                   live is not None and abs(live - want) < 0.5))

    # count 2024
    p, a, _ = ask("how many transactions in 2024?")
    import re
    m = re.search(r"([\d,]+)", a.replace("2024", ""))
    want_c = ts.overview(USER, None, "2024")["count"]
    live_c = int(m.group(1).replace(",", "")) if m else None
    checks.append(("count 2024", want_c, live_c, live_c == want_c))

    # latest balance
    p, a, _ = ask("what's my latest balance?")
    want_b = ts.latest_balance(USER)
    live_b = first_num(a)
    checks.append(("latest balance", want_b, live_b,
                   live_b is not None and abs(live_b - want_b) < 0.5))

    cpass = 0
    for name, want, live, ok in checks:
        cpass += ok
        print(f"  [{'OK ' if ok else 'BAD'}] {name:<16} want={want}  live={live}")
    print(f"\nCONSISTENCY: {cpass}/{len(checks)} match")

    # write sheet
    import csv
    os.makedirs(os.path.dirname(SHEET), exist_ok=True)
    with open(SHEET, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["#", "question", "expected_route", "actual_route",
                    "route_result", "seconds", "answer"])
        for i, r in enumerate(rows, 1):
            w.writerow([i, *r])
    print(f"\nSheet written: {os.path.abspath(SHEET)}")


if __name__ == "__main__":
    main()
