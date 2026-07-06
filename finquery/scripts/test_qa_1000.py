"""
Run the 1000 verified Q&A (data/qa_1000.json) against the LIVE server and report
pass/fail. Each question is sent in its OWN fresh thread so there is no context
carry-over (these are standalone questions).

A question PASSES when the figure the server returns matches the verified answer:
  - amount questions: the ₹ figure matches (±0.6 for rounding)
  - count questions : the integer count matches exactly
  - derived/percent : the headline number matches

Output: data/qa_1000_results.csv  +  printed summary (overall + by type + failures)
"""
import os, sys, json, re, csv, time, urllib.request

sys.stdout.reconfigure(encoding="utf-8")
BASE = f"http://127.0.0.1:{os.environ.get('PORT','5667')}"
HERE = os.path.dirname(__file__)
DATA = os.path.join(HERE, "..", "data")
QA = json.load(open(os.path.join(DATA, "qa_1000.json"), encoding="utf-8"))


def ask(q, thread, timeout=90):
    body = {"question": q, "thread": thread, "reset": True}
    data = json.dumps(body).encode()
    req = urllib.request.Request(BASE + "/query", data=data,
                                 headers={"Content-Type": "application/json"})
    path, parts = "?", []
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
    return path, " ".join("".join(parts).split())


def amounts(s):
    return [float(m.replace(",", "")) for m in re.findall(r"₹\s*([\d,]+(?:\.\d+)?)", s)]


def all_ints(s):
    return [int(m.replace(",", "")) for m in re.findall(r"(?<![\d.])([\d,]+)(?![\d.])", s)]


def first_num(s):
    m = re.search(r"[\d,]+(?:\.\d+)?", s)
    return float(m.group(0).replace(",", "")) if m else None


def verdict(expected, actual):
    """Return (passed, reason)."""
    if "₹" in expected:                       # amount-type
        exp = amounts(expected)[0]
        got = amounts(actual)
        if any(abs(exp - g) <= 0.6 for g in got):
            return True, ""
        # percent questions also carry a % headline; accept that too
        if "%" in expected:
            p = first_num(expected)
            if p is not None and re.search(rf"{re.escape(f'{p:.1f}')}\s*%", actual):
                return True, ""
        return False, f"expected ₹{exp:,.2f}; got amounts {got or 'none'}"
    # count-type
    m = re.search(r"([\d,]+)\s+transactions", expected)
    if m:
        exp = int(m.group(1).replace(",", ""))
        if exp in all_ints(actual):
            return True, ""
        return False, f"expected {exp} txns; got ints {all_ints(actual)[:6]}"
    # fallback: headline number present
    exp = first_num(expected)
    if exp is not None and (exp in [first_num(a) for a in [actual]] or
                            any(abs(exp - x) <= 0.6 for x in amounts(actual) + [float(i) for i in all_ints(actual)])):
        return True, ""
    return False, f"headline {exp} not found"


rows = []
t0 = time.time()
npass = 0
for i, r in enumerate(QA, 1):
    try:
        route, ans = ask(r["question"], thread=f"qa{r['id']}")
        ok, why = verdict(r["answer"], ans)
    except Exception as e:
        route, ans, ok, why = "ERR", f"<{type(e).__name__}: {e}>", False, "request failed"
    npass += ok
    rows.append({"id": r["id"], "type": r["type"], "pass": ok, "route": route,
                 "question": r["question"], "expected": r["answer"],
                 "actual": ans[:300], "why": why})
    if i % 100 == 0:
        print(f"  {i}/{len(QA)}  running pass-rate {npass}/{i} ({npass/i*100:.1f}%)  "
              f"[{time.time()-t0:.0f}s]")

# ---- write CSV ----
out = os.path.join(DATA, "qa_1000_results.csv")
with open(out, "w", newline="", encoding="utf-8-sig") as f:
    w = csv.DictWriter(f, fieldnames=["id", "type", "pass", "route", "question",
                                      "expected", "actual", "why"])
    w.writeheader()
    w.writerows(rows)

# ---- summary ----
tot = len(rows)
print(f"\n{'='*60}\nOVERALL: {npass}/{tot} passed ({npass/tot*100:.1f}%)  in {time.time()-t0:.0f}s")
print(f"Results sheet: {out}\n")

bytype = {}
for r in rows:
    d = bytype.setdefault(r["type"], [0, 0])
    d[0] += 1
    d[1] += r["pass"]
print("By question type:")
for t, (n, p) in sorted(bytype.items(), key=lambda kv: kv[1][1]/kv[1][0]):
    flag = "" if p == n else "  <-- check"
    print(f"  {p:>4}/{n:<4} ({p/n*100:5.1f}%)  {t}{flag}")

fails = [r for r in rows if not r["pass"]]
print(f"\nFailures: {len(fails)}")
for r in fails[:25]:
    print(f"\n  #{r['id']} [{r['type']}] route={r['route']}")
    print(f"    Q: {r['question']}")
    print(f"    expected: {r['expected'].replace(chr(8377),'Rs ')}")
    print(f"    got     : {r['actual'].replace(chr(8377),'Rs ')[:160]}")
    print(f"    why     : {r['why'].replace(chr(8377),'Rs ')}")
if len(fails) > 25:
    print(f"\n  ... and {len(fails)-25} more (see CSV)")
