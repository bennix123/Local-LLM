"""
400+ question battery: standalone correctness (easy -> hard, incl. Hinglish/
typos/slang) + deep multi-turn conversation chains testing CONTEXT HOLDING.

Every expected value is computed from SQL. Reports standalone correctness and
context-holding (easy vs hard follow-ups). Sheet -> data/rag_400_sheet.csv
"""
import os, sys, json, time, re, csv, urllib.request

sys.stdout.reconfigure(encoding="utf-8")
BASE = "http://127.0.0.1:8000"
SHEET = os.path.join(os.path.dirname(__file__), "..", "data", "rag_400_sheet.csv")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend", "src"))
from services import txn_store as ts
ts.DB_PATH = os.environ.get("FINQ_DB", os.path.join(os.path.dirname(__file__), "..", "data", "live_txn.db"))
USER = "local"
MON = ["", "January", "February", "March", "April", "May", "June", "July",
       "August", "September", "October", "November", "December"]


def plabel(p):
    if isinstance(p, tuple):
        return f"{plabel(p[0])} to {plabel(p[1])}"
    if len(p) == 4:
        return p
    if len(p) == 7:
        return f"{MON[int(p[5:7])]} {p[:4]}"
    return f"{int(p[8:10])} {MON[int(p[5:7])]} {p[:4]}"


def ask(q, timeout=300, thread=None, reset=False):
    body = {"question": q}
    if thread:
        body["thread"] = thread
    if reset:
        body["reset"] = True
    data = json.dumps(body).encode()
    req = urllib.request.Request(BASE + "/query", data=data, headers={"Content-Type": "application/json"})
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


def money(s):
    m = re.search(r"₹\s*([\d,]+(?:\.\d+)?)", s)
    return float(m.group(1).replace(",", "")) if m else None


def last_int(s):
    nums = re.findall(r"[\d][\d,]*", s.split(":")[-1])
    return int(nums[-1].replace(",", "")) if nums else None


_CATSET = {"Groceries", "Food & Dining", "Transport", "Shopping", "Utilities",
           "Entertainment", "Healthcare", "Investment & Insurance"}


def expected(kind, P, arg):
    if kind == "count":
        if arg:                                    # count scoped to a category or merchant
            if arg in _CATSET:
                for c, a, cnt in ts.by_category(USER, None, P):
                    if c == arg:
                        return cnt
                return 0
            return ts.merchant_spend(USER, arg, None, P)["count"]
        return ts.overview(USER, None, P)["count"]
    if kind == "spend":
        return ts.overview(USER, None, P)["debit"]
    if kind == "income":
        return ts.overview(USER, None, P)["credit"]
    if kind == "category":
        for c, a, _ in ts.by_category(USER, None, P):
            if c == arg:
                return a
        return 0.0
    if kind == "merchant":
        return ts.merchant_spend(USER, arg, None, P)["debit"]
    if kind in ("biggest", "topmax", "smallest"):
        w, pr = ts._scope(USER, None, P)
        con = ts.connect()
        fn = "MIN" if kind == "smallest" else "MAX"
        r = con.execute(f"SELECT {fn}(debit) FROM transactions WHERE {w} AND debit>0", pr).fetchone()
        con.close()
        return r[0]
    if kind == "balance":
        return ts.latest_balance(USER)
    return None


def check_one(kind, P, arg, ans):
    want = expected(kind, P, arg)
    if kind == "count":
        return (last_int(ans) == int(want)), last_int(ans), want
    got = money(ans)
    if want in (0, 0.0) and got is None:
        return True, 0, 0
    return (got is not None and abs(got - want) < 1.0), got, want


def verify(accepts, ans):
    last_got = None
    for a in accepts:
        if a[0] == "contains":
            if a[1].lower() in ans.lower():
                return True, f"contains '{a[1]}'", "ok"
            continue
        ok, got, want = check_one(a[0], a[1], a[2], ans)
        last_got = got
        if ok:
            return True, got, want
    return False, last_got, None


# ----------------------------- STANDALONE -----------------------------
def build_standalone():
    cases = []
    years = ["2024", "2025"]
    months = [f"2024-{m:02d}" for m in range(1, 13)] + [f"2025-{m:02d}" for m in range(1, 13)]
    for P in years + months:
        L = plabel(P)
        cases += [(f"how many transactions in {L}?", "count", P, None),
                  (f"how much did I spend in {L}?", "spend", P, None),
                  (f"how much income did I receive in {L}?", "income", P, None)]
    for m in range(1, 13):
        cases += [(f"how many transactions on {plabel(f'2024-{m:02d}-15')}?", "count", f"2024-{m:02d}-15", None),
                  (f"how much did I spend on {plabel(f'2024-{m:02d}-15')}?", "spend", f"2024-{m:02d}-15", None)]
    for m in range(1, 13):
        cases += [(f"how many transactions on {plabel(f'2025-{m:02d}-10')}?", "count", f"2025-{m:02d}-10", None),
                  (f"how much did I spend on {plabel(f'2025-{m:02d}-10')}?", "spend", f"2025-{m:02d}-10", None)]
    for a, b in [("2024-01", "2024-03"), ("2024-04", "2024-06"), ("2024-07", "2024-09"),
                 ("2024-10", "2024-12"), ("2025-01", "2025-06"), ("2025-07", "2025-12"),
                 ("2024-06", "2025-06"), ("2024-01", "2024-12")]:
        L = f"{plabel(a)} to {plabel(b)}"
        cases += [(f"how many transactions from {L}?", "count", (a, b), None),
                  (f"how much did I spend from {L}?", "spend", (a, b), None)]
    cats = ["Groceries", "Food & Dining", "Transport", "Shopping", "Utilities",
            "Entertainment", "Healthcare", "Investment & Insurance"]
    for cat in cats:
        for P in ["2024", "2025", "2024-06", "2025-03", "2024-12", "2025-09", "2024-09", "2025-12"]:
            cases.append((f"how much did I spend on {cat} in {plabel(P)}?", "category", P, cat))
    for mch in ["Swiggy", "Zomato", "Amazon", "Flipkart", "Netflix", "Spotify",
                "Zerodha", "Uber", "BigBasket", "Jio", "Ola", "Myntra"]:
        cases += [(f"how much did I spend at {mch}?", "merchant", None, mch),
                  (f"how much did I spend at {mch} in 2024?", "merchant", "2024", mch),
                  (f"how much did I spend at {mch} in 2025?", "merchant", "2025", mch)]
    for P in [None, "2024", "2025", "2024-06"]:
        sfx = f" in {plabel(P)}" if P else ""
        cases += [(f"what was my biggest expense{sfx}?", "biggest", P, None),
                  (f"what was my smallest expense{sfx}?", "smallest", P, None)]
    cases += [("show me my top 5 expenses", "topmax", None, None),
              ("top 10 expenses in 2024", "topmax", "2024", None),
              ("top 5 expenses in 2025", "topmax", "2025", None),
              ("top 3 expenses in June 2024", "topmax", "2024-06", None),
              ("what is my current balance?", "balance", None, None)]
    # ---- HARD: Hinglish / typos / slang (same SQL truth) ----
    cases += [
        ("kitna kharcha hua 2024 me", "spend", "2024", None),
        ("kitna kharcha hua 2025 me", "spend", "2025", None),
        ("kitni income hui 2025 me", "income", "2025", None),
        ("2025 me kitni income hui", "income", "2025", None),
        ("2024 me kitne transaction the", "count", "2024", None),
        ("march 2024 me kitna kharcha", "spend", "2024-03", None),
        ("kitne transaction hue may 2024 me", "count", "2024-05", None),
        ("amazon pe kitna kharcha 2024", "merchant", "2024", "Amazon"),
        ("netflix pe kitna gaya", "merchant", None, "Netflix"),
        ("zerodha pe total kitna 2025", "merchant", "2025", "Zerodha"),
        ("kitna bacha mere paas", "balance", None, None),
        ("sabse bada kharcha 2024", "biggest", "2024", None),
        ("sabse bada kharcha kya tha", "biggest", None, None),
        ("hw mch did i spnd on groceries in 2024", "category", "2024", "Groceries"),
        ("amt spent at amazon in 2025", "merchant", "2025", "Amazon"),
        ("ttl spend march 2025", "spend", "2025-03", None),
        ("no of txns in june 2024", "count", "2024-06", None),
        ("spnding on shopping 2024", "category", "2024", "Shopping"),
        ("biggst expense 2025", "biggest", "2025", None),
        ("smalest expense in 2024", "smallest", "2024", None),
        ("incom in 2024", "income", "2024", None),
        ("blance", "balance", None, None),
        ("transactins in april 2024", "count", "2024-04", None),
        ("grocery spnd 2024", "category", "2024", "Groceries"),
        ("how much i earn in 2024", "income", "2024", None),
        ("transactions on 15 oct 2024", "count", "2024-10-15", None),
        ("how much did i spend at uber in 2024", "merchant", "2024", "Uber"),
        ("food and dining spend in 2024", "category", "2024", "Food & Dining"),
        ("how much on utilities in december 2024", "category", "2024-12", "Utilities"),
        ("how many purchases in 2024", "count", "2024", None),
        ("what's my closing balance", "balance", None, None),
        ("how much cash did I burn in 2025", "spend", "2025", None),
        ("what did I drop at flipkart in 2024", "merchant", "2024", "Flipkart"),
        ("largest transaction in 2024", "biggest", "2024", None),
        ("how much on entertainment in 2025", "category", "2025", "Entertainment"),
        ("how much at zomato in 2025", "merchant", "2025", "Zomato"),
    ]
    return cases


# ----------------------------- CONTEXT CHAINS -----------------------------
def C(k, P=None, a=None):
    return (k, P, a)


CHAINS = [
    [("how many transactions in 2024?", [C("count", "2024")], False),
     ("and in 2025?", [C("count", "2025")], False),
     ("what about March 2025?", [C("count", "2025-03")], False),
     ("and February?", [C("count", "2025-02")], True),
     ("and January?", [C("count", "2025-01")], True)],
    [("how much did I spend in 2024?", [C("spend", "2024")], False),
     ("what about 2025?", [C("spend", "2025")], False),
     ("and in June 2025?", [C("spend", "2025-06")], False),
     ("how many transactions then?", [C("count", "2025-06")], True),
     ("and how much did I spend there?", [C("spend", "2025-06")], True)],
    [("how much did I spend on Groceries in 2024?", [C("category", "2024", "Groceries")], False),
     ("what about Shopping?", [C("category", "2024", "Shopping")], True),
     ("and in 2025?", [C("category", "2025", "Shopping")], True),
     ("and Transport?", [C("category", "2025", "Transport")], True)],
    [("how much did I spend at Amazon in 2024?", [C("merchant", "2024", "Amazon")], False),
     ("what about Flipkart?", [C("merchant", "2024", "Flipkart")], True),
     ("and Swiggy in 2025?", [C("merchant", "2025", "Swiggy")], False),
     ("and Zomato?", [C("merchant", "2025", "Zomato")], True)],
    [("what was my biggest expense in 2024?", [C("biggest", "2024")], False),
     ("which merchant was that?", [("contains", "Zerodha")], True),
     ("what date was it?", [("contains", "May")], True),
     ("and the smallest?", [C("smallest", "2024")], True)],
    [("what's my current balance?", [C("balance")], False),
     ("how much did I earn in 2024?", [C("income", "2024")], False),
     ("and in 2025?", [C("income", "2025")], False)],
    [("how much did I spend in January 2024?", [C("spend", "2024-01")], False),
     ("and February?", [C("spend", "2024-02")], True),
     ("and March?", [C("spend", "2024-03")], True),
     ("April?", [C("spend", "2024-04")], True),
     ("and May?", [C("spend", "2024-05")], True),
     ("June?", [C("spend", "2024-06")], True)],
    [("how many transactions in December 2024?", [C("count", "2024-12")], False),
     ("how much did I spend that month?", [C("spend", "2024-12")], True)],
    [("how much did I spend from January 2024 to June 2024?", [C("spend", ("2024-01", "2024-06"))], False),
     ("what about July to December?", [C("spend", ("2024-07", "2024-12"))], True),
     ("how many transactions in that range?", [C("count", ("2024-07", "2024-12"))], True)],
    [("top 5 expenses in 2024", [C("topmax", "2024")], False),
     ("what about 2025?", [C("topmax", "2025")], False)],
    [("how much income did I receive in March 2024?", [C("income", "2024-03")], False),
     ("and April?", [C("income", "2024-04")], True),
     ("and May?", [C("income", "2024-05")], True),
     ("and June?", [C("income", "2024-06")], True)],
    [("how much on Food & Dining in June 2024?", [C("category", "2024-06", "Food & Dining")], False),
     ("and July?", [C("category", "2024-07", "Food & Dining")], True),
     ("what about Transport in July 2024?", [C("category", "2024-07", "Transport")], False),
     ("and August?", [C("category", "2024-08", "Transport")], True)],
    [("how much did I spend at Zerodha?", [C("merchant", None, "Zerodha")], False),
     ("just in 2024?", [C("merchant", "2024", "Zerodha")], True),
     ("and 2025?", [C("merchant", "2025", "Zerodha")], True)],
    [("how many transactions on 15 March 2024?", [C("count", "2024-03-15")], False),
     ("what about the 16th?", [C("count", "2024-03-16")], True),
     ("and the 17th?", [C("count", "2024-03-17")], True)],
    [("how much did I spend on Healthcare in 2024?", [C("category", "2024", "Healthcare")], False),
     ("and Utilities?", [C("category", "2024", "Utilities")], True),
     ("and Entertainment?", [C("category", "2024", "Entertainment")], True)],
    [("how much did I spend on Entertainment in 2025?", [C("category", "2025", "Entertainment")], False),
     ("what about 2024?", [C("category", "2024", "Entertainment")], True)],
    [("how many transactions in April 2025?", [C("count", "2025-04")], False),
     ("and May?", [C("count", "2025-05")], True),
     ("and June?", [C("count", "2025-06")], True),
     ("and July?", [C("count", "2025-07")], True)],
    [("how much at Netflix in 2024?", [C("merchant", "2024", "Netflix")], False),
     ("and Spotify?", [C("merchant", "2024", "Spotify")], True),
     ("and in 2025?", [C("merchant", "2025", "Spotify")], True)],
    [("biggest expense in 2025?", [C("biggest", "2025")], False),
     ("and the smallest?", [C("smallest", "2025")], True),
     ("what about 2024?", [C("smallest", "2024")], True)],
    [("how much on groceries in March 2025?", [C("category", "2025-03", "Groceries")], False),
     ("and in March 2024?", [C("category", "2024-03", "Groceries")], False)],
    [("how many transactions in 2024?", [C("count", "2024")], False),
     ("how much did I spend?", [C("spend", "2024"), C("spend", None)], True),
     ("and how much did I earn?", [C("income", "2024"), C("income", None)], True)],
    [("how much did I spend from March 2025 to May 2025?", [C("spend", ("2025-03", "2025-05"))], False),
     ("how many transactions in that period?", [C("count", ("2025-03", "2025-05"))], True)],
    # Hinglish-driven chain
    [("2024 me kitna kharcha hua?", [C("spend", "2024")], False),
     ("aur 2025 me?", [C("spend", "2025"), C("spend", None)], True),
     ("groceries pe kitna 2024 me?", [C("category", "2024", "Groceries")], False),
     ("aur shopping pe?", [C("category", "2024", "Shopping")], True)],
    # deep month walk (memory depth)
    [("how much did I spend in July 2025?", [C("spend", "2025-07")], False),
     ("and August?", [C("spend", "2025-08")], True),
     ("and September?", [C("spend", "2025-09")], True),
     ("and October?", [C("spend", "2025-10")], True),
     ("and November?", [C("spend", "2025-11")], True),
     ("and December?", [C("spend", "2025-12")], True)],
    # merchant -> period -> back to all-time merchant
    [("how much did I spend at Uber in 2024?", [C("merchant", "2024", "Uber")], False),
     ("and Ola?", [C("merchant", "2024", "Ola")], True),
     ("what about all time?", [C("merchant", None, "Ola")], True)],
    # category total then per-period
    [("how much did I spend on Shopping in December 2024?", [C("category", "2024-12", "Shopping")], False),
     ("and November?", [C("category", "2024-11", "Shopping")], True),
     ("and October?", [C("category", "2024-10", "Shopping")], True)],
    # income walk 2025
    [("how much income in January 2025?", [C("income", "2025-01")], False),
     ("and February?", [C("income", "2025-02")], True),
     ("and March?", [C("income", "2025-03")], True)],
    # count -> spend on same explicit period (no carry needed, but intent switch)
    [("how many transactions in March 2025?", [C("count", "2025-03")], False),
     ("how much did I spend in March 2025?", [C("spend", "2025-03")], False),
     ("and how much income in March 2025?", [C("income", "2025-03")], False)],
    # follow-up about a number
    [("how much did I spend on Groceries in 2024?", [C("category", "2024", "Groceries")], False),
     ("is that a lot?", [("contains", "")], False),
     ("what about 2025?", [C("category", "2025", "Groceries")], True)],
    # long count walk across year boundary
    [("how many transactions in October 2024?", [C("count", "2024-10")], False),
     ("and November?", [C("count", "2024-11")], True),
     ("and December?", [C("count", "2024-12")], True),
     ("and January 2025?", [C("count", "2025-01")], False),
     ("and February?", [C("count", "2025-02")], True)],
    # merchant carry with intent stays merchant across many years/months
    [("how much did I spend at Amazon?", [C("merchant", None, "Amazon")], False),
     ("in 2024?", [C("merchant", "2024", "Amazon")], True),
     ("and 2025?", [C("merchant", "2025", "Amazon")], True),
     ("just March 2025?", [C("merchant", "2025-03", "Amazon")], True)],
    # category deep walk
    [("how much on Transport in January 2024?", [C("category", "2024-01", "Transport")], False),
     ("and February?", [C("category", "2024-02", "Transport")], True),
     ("and March?", [C("category", "2024-03", "Transport")], True),
     ("and April?", [C("category", "2024-04", "Transport")], True)],
]


def main():
    standalone = build_standalone()
    rows, t_all = [], time.time()
    print(f"PART 1 — STANDALONE: {len(standalone)} questions")
    spass = 0
    for i, (q, kind, P, arg) in enumerate(standalone, 1):
        try:
            path, ans = ask(q)
        except Exception as e:
            path, ans = "ERR", str(e)
        ok, got, want = check_one(kind, P, arg, ans)
        spass += ok
        rows.append(("standalone", q, kind, "PASS" if ok else "FAIL", want, got, ans[:90]))
        if not ok:
            print(f"  FAIL [{kind}] {q}  want={want} got={got} :: {ans[:55]}")
        if i % 60 == 0:
            print(f"   …{i}/{len(standalone)} ({spass} pass)")
    print(f"STANDALONE: {spass}/{len(standalone)} ({100*spass/len(standalone):.1f}%)")

    nturns = sum(len(c) for c in CHAINS)
    print(f"\nPART 2 — CONTEXT: {nturns} turns / {len(CHAINS)} chains")
    ce_p = ce_t = ch_p = ch_t = 0
    for ci, chain in enumerate(CHAINS, 1):
        for (q, accepts, hard) in chain:
            try:
                path, ans = ask(q)
            except Exception as e:
                ans = str(e)
            ok, got, want = verify(accepts, ans)
            if hard:
                ch_t += 1; ch_p += ok
            else:
                ce_t += 1; ce_p += ok
            tag = "HARD" if hard else "easy"
            rows.append((f"ctx-{tag}", q, "", "PASS" if ok else "FAIL", want, got, ans[:90]))
            if not ok:
                print(f"  [BAD|{tag}] c{ci} {q[:44]:44} -> {ans[:46]}")

    n = len(standalone)
    print("\n================= RESULTS =================")
    print(f"STANDALONE correctness : {spass}/{n}  ({100*spass/n:.1f}%)")
    print(f"CONTEXT easy follow-ups: {ce_p}/{ce_t}  ({100*ce_p/max(ce_t,1):.0f}%)")
    print(f"CONTEXT hard follow-ups: {ch_p}/{ch_t}  ({100*ch_p/max(ch_t,1):.0f}%)")
    total = n + ce_t + ch_t
    tp = spass + ce_p + ch_p
    print(f"TOTAL                  : {tp}/{total}  ({100*tp/total:.1f}%)   in {time.time()-t_all:.0f}s")

    os.makedirs(os.path.dirname(SHEET), exist_ok=True)
    with open(SHEET, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["section", "question", "kind", "result", "want", "got", "answer"])
        w.writerows(rows)
    print(f"\nSheet: {os.path.abspath(SHEET)}")


if __name__ == "__main__":
    main()
