"""
300+ question battery: standalone correctness (easy → hard, incl. Hinglish/typos)
PLUS multi-turn conversation chains that test CONTEXT HOLDING (elliptical
follow-ups that must carry period / intent / category / merchant across turns).

Every expected value is computed from SQL. Reports:
  - standalone correctness
  - context-holding (split easy vs hard follow-ups)

Sheet -> data/rag_300_sheet.csv
"""
import os, sys, json, time, re, csv, urllib.request

sys.stdout.reconfigure(encoding="utf-8")
BASE = "http://127.0.0.1:8000"
SHEET = os.path.join(os.path.dirname(__file__), "..", "data", "rag_300_sheet.csv")
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


def ask(q, timeout=300):
    data = json.dumps({"question": q}).encode()
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


def expected(kind, P, arg):
    if kind == "count":
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
        got = last_int(ans)
        return (got == int(want)), got, want
    got = money(ans)
    if want in (0, 0.0) and got is None:
        return True, 0, 0
    return (got is not None and abs(got - want) < 1.0), got, want


def verify(accepts, ans):
    """accepts: list of (kind,P,arg) OR ('contains', substr). Pass if ANY matches."""
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
    cases = []  # (q, kind, P, arg)
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
        cases.append((f"how many transactions on {plabel(f'2025-{m:02d}-10')}?", "count", f"2025-{m:02d}-10", None))
    for a, b in [("2024-01", "2024-03"), ("2024-04", "2024-06"), ("2024-07", "2024-09"),
                 ("2024-10", "2024-12"), ("2025-01", "2025-06"), ("2024-06", "2025-06")]:
        L = f"{plabel(a)} to {plabel(b)}"
        cases += [(f"how many transactions from {L}?", "count", (a, b), None),
                  (f"how much did I spend from {L}?", "spend", (a, b), None)]
    cats = ["Groceries", "Food & Dining", "Transport", "Shopping", "Utilities",
            "Entertainment", "Healthcare", "Investment & Insurance"]
    for cat in cats:
        for P in ["2024", "2025", "2024-06", "2025-03", "2024-12"]:
            cases.append((f"how much did I spend on {cat} in {plabel(P)}?", "category", P, cat))
    for mch in ["Swiggy", "Zomato", "Amazon", "Flipkart", "Netflix", "Spotify", "Zerodha", "Uber", "BigBasket", "Jio"]:
        cases += [(f"how much did I spend at {mch}?", "merchant", None, mch),
                  (f"how much did I spend at {mch} in 2024?", "merchant", "2024", mch),
                  (f"how much did I spend at {mch} in 2025?", "merchant", "2025", mch)]
    for P in [None, "2024", "2025"]:
        sfx = f" in {plabel(P)}" if P else ""
        cases += [(f"what was my biggest expense{sfx}?", "biggest", P, None),
                  (f"what was my smallest expense{sfx}?", "smallest", P, None)]
    cases += [("show me my top 5 expenses", "topmax", None, None),
              ("top 10 expenses in 2024", "topmax", "2024", None),
              ("top 5 expenses in 2025", "topmax", "2025", None),
              ("what is my current balance?", "balance", None, None)]
    # ---- HARD: Hinglish / typos / slang (same SQL truth) ----
    cases += [
        ("kitna kharcha hua 2024 me", "spend", "2024", None),
        ("kitni income hui 2025 me", "income", "2025", None),
        ("2024 me kitne transaction the", "count", "2024", None),
        ("hw mch did i spnd on groceries in 2024", "category", "2024", "Groceries"),
        ("amt spent at amazon in 2025", "merchant", "2025", "Amazon"),
        ("ttl spend march 2025", "spend", "2025-03", None),
        ("no of txns in june 2024", "count", "2024-06", None),
        ("spnding on shopping 2024", "category", "2024", "Shopping"),
        ("biggst expense 2025", "biggest", "2025", None),
        ("how much on netflix", "merchant", None, "Netflix"),
        ("zerodha total spend", "merchant", None, "Zerodha"),
        ("how much i earn in 2024", "income", "2024", None),
        ("transactions on 15 oct 2024", "count", "2024-10-15", None),
        ("how much did i spend at uber in 2024", "merchant", "2024", "Uber"),
        ("food and dining spend in 2024", "category", "2024", "Food & Dining"),
        ("smallest expense in 2025", "smallest", "2025", None),
    ]
    return cases


# ----------------------------- CONTEXT CHAINS -----------------------------
# turn = (question, accepts, hard?)   accepts = [(kind,P,arg), ...] or [("contains",s)]
def C(k, P=None, a=None):
    return (k, P, a)


CHAINS = [
    # A: count year->year->month->month(no year)
    [("how many transactions in 2024?", [C("count", "2024")], False),
     ("and in 2025?", [C("count", "2025")], False),
     ("what about March 2025?", [C("count", "2025-03")], False),
     ("and February?", [C("count", "2025-02")], True)],
    # B: spend reuse + intent switch carrying period
    [("how much did I spend in 2024?", [C("spend", "2024")], False),
     ("what about 2025?", [C("spend", "2025")], False),
     ("and in June 2025?", [C("spend", "2025-06")], False),
     ("how many transactions then?", [C("count", "2025-06")], True)],
    # C: category carry period / carry category
    [("how much did I spend on Groceries in 2024?", [C("category", "2024", "Groceries")], False),
     ("what about Shopping?", [C("category", "2024", "Shopping")], True),
     ("and in 2025?", [C("category", "2025", "Shopping")], True)],
    # D: merchant carry
    [("how much did I spend at Amazon in 2024?", [C("merchant", "2024", "Amazon")], False),
     ("what about Flipkart?", [C("merchant", "2024", "Flipkart")], True),
     ("and Swiggy in 2025?", [C("merchant", "2025", "Swiggy")], False)],
    # E: follow-up ABOUT the prior answer (chat)
    [("what was my biggest expense in 2024?", [C("biggest", "2024")], False),
     ("which merchant was that?", [("contains", "Zerodha")], True),
     ("what date was it?", [("contains", "May")], True)],
    # F: balance then income carry
    [("what's my current balance?", [C("balance")], False),
     ("how much did I earn in 2024?", [C("income", "2024")], False),
     ("and in 2025?", [C("income", "2025")], False)],
    # G: month walk carrying year+intent
    [("how much did I spend in January 2024?", [C("spend", "2024-01")], False),
     ("and February?", [C("spend", "2024-02")], True),
     ("and March?", [C("spend", "2024-03")], True),
     ("April?", [C("spend", "2024-04")], True)],
    # H: count -> "that month" spend
    [("how many transactions in December 2024?", [C("count", "2024-12")], False),
     ("how much did I spend that month?", [C("spend", "2024-12")], True)],
    # I: range carry
    [("how much did I spend from January 2024 to June 2024?", [C("spend", ("2024-01", "2024-06"))], False),
     ("what about July to December?", [C("spend", ("2024-07", "2024-12"))], True)],
    # J: top-N carry
    [("top 5 expenses in 2024", [C("topmax", "2024")], False),
     ("what about 2025?", [C("topmax", "2025")], False)],
    # K: income months carry
    [("how much income did I receive in March 2024?", [C("income", "2024-03")], False),
     ("and April?", [C("income", "2024-04")], True),
     ("and May?", [C("income", "2024-05")], True)],
    # L: category months carry + switch category
    [("how much on Food & Dining in June 2024?", [C("category", "2024-06", "Food & Dining")], False),
     ("and July?", [C("category", "2024-07", "Food & Dining")], True),
     ("what about Transport in July 2024?", [C("category", "2024-07", "Transport")], False)],
    # M: merchant all-time -> year carry
    [("how much did I spend at Zerodha?", [C("merchant", None, "Zerodha")], False),
     ("just in 2024?", [C("merchant", "2024", "Zerodha")], True),
     ("and 2025?", [C("merchant", "2025", "Zerodha")], True)],
    # N: count day carry
    [("how many transactions on 15 March 2024?", [C("count", "2024-03-15")], False),
     ("what about the 16th?", [C("count", "2024-03-16")], True)],
    # P: category carry change
    [("how much did I spend on Healthcare in 2024?", [C("category", "2024", "Healthcare")], False),
     ("and Utilities?", [C("category", "2024", "Utilities")], True)],
    # Q: category year switch
    [("how much did I spend on Entertainment in 2025?", [C("category", "2025", "Entertainment")], False),
     ("what about 2024?", [C("category", "2024", "Entertainment")], True)],
    # R: count month walk 2025
    [("how many transactions in April 2025?", [C("count", "2025-04")], False),
     ("and May?", [C("count", "2025-05")], True),
     ("and June?", [C("count", "2025-06")], True)],
    # S: merchant switch carry year
    [("how much at Netflix in 2024?", [C("merchant", "2024", "Netflix")], False),
     ("and Spotify?", [C("merchant", "2024", "Spotify")], True)],
    # U: extreme direction flip carry year
    [("biggest expense in 2025?", [C("biggest", "2025")], False),
     ("and the smallest?", [C("smallest", "2025")], True)],
    # V: category same month both years
    [("how much on groceries in March 2025?", [C("category", "2025-03", "Groceries")], False),
     ("and in March 2024?", [C("category", "2024-03", "Groceries")], False)],
    # W: count->spend->income same year carry
    [("how many transactions in 2024?", [C("count", "2024")], False),
     ("how much did I spend?", [C("spend", "2024")], True),
     ("and how much did I earn?", [C("income", "2024")], True)],
    # Y: range + intent switch
    [("how much did I spend from March 2025 to May 2025?", [C("spend", ("2025-03", "2025-05"))], False),
     ("how many transactions in that period?", [C("count", ("2025-03", "2025-05"))], True)],
    # Z1: category carry + switch + year
    [("how much did I spend on Transport in 2024?", [C("category", "2024", "Transport")], False),
     ("and Healthcare?", [C("category", "2024", "Healthcare")], True),
     ("and in 2025?", [C("category", "2025", "Healthcare")], True)],
    # Z2: count month walk 2024
    [("how many transactions in February 2024?", [C("count", "2024-02")], False),
     ("and March?", [C("count", "2024-03")], True),
     ("and April?", [C("count", "2024-04")], True)],
    # Z3: merchant all-time -> year carry (Jio)
    [("how much did I spend at Jio?", [C("merchant", None, "Jio")], False),
     ("in 2024?", [C("merchant", "2024", "Jio")], True),
     ("and 2025?", [C("merchant", "2025", "Jio")], True)],
    # Z4: spend month carry -> explicit count
    [("how much did I spend in May 2025?", [C("spend", "2025-05")], False),
     ("and June?", [C("spend", "2025-06")], True),
     ("how many transactions in June 2025?", [C("count", "2025-06")], False)],
    # Z5: extreme flip carry year
    [("smallest expense in 2024?", [C("smallest", "2024")], False),
     ("and the biggest?", [C("biggest", "2024")], True)],
    # Z6: income carry year
    [("how much income in 2024?", [C("income", "2024")], False),
     ("and in 2025?", [C("income", "2025")], False)],
    # Z7: category month walk carry
    [("how much on Shopping in December 2024?", [C("category", "2024-12", "Shopping")], False),
     ("and November?", [C("category", "2024-11", "Shopping")], True)],
]


def main():
    standalone = build_standalone()
    rows = []
    t_all = time.time()

    print(f"PART 1 — STANDALONE: {len(standalone)} questions\n")
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
            print(f"  FAIL [{kind}] {q}  want={want} got={got} :: {ans[:60]}")
        if i % 50 == 0:
            print(f"   …{i}/{len(standalone)} ({spass} pass)")

    print(f"\nSTANDALONE: {spass}/{len(standalone)} ({100*spass/len(standalone):.1f}%)")

    print(f"\nPART 2 — CONTEXT CHAINS: {sum(len(c) for c in CHAINS)} turns over {len(CHAINS)} chains\n")
    ce_p = ce_t = ch_p = ch_t = 0   # easy/hard pass/total
    for ci, chain in enumerate(CHAINS, 1):
        print(f"  chain {ci}:")
        for (q, accepts, hard) in chain:
            try:
                path, ans = ask(q)
            except Exception as e:
                path, ans = "ERR", str(e)
            ok, got, want = verify(accepts, ans)
            tag = "HARD" if hard else "easy"
            if hard:
                ch_t += 1; ch_p += ok
            else:
                ce_t += 1; ce_p += ok
            rows.append((f"ctx-{tag}", q, "", "PASS" if ok else "FAIL", want, got, ans[:90]))
            mark = "ok " if ok else "BAD"
            print(f"    [{mark}|{tag}] {q[:46]:46} -> {ans[:46]}")

    n = len(standalone)
    print("\n================= RESULTS =================")
    print(f"STANDALONE correctness : {spass}/{n}  ({100*spass/n:.1f}%)")
    print(f"CONTEXT easy follow-ups: {ce_p}/{ce_t}  ({100*ce_p/max(ce_t,1):.0f}%)")
    print(f"CONTEXT hard follow-ups: {ch_p}/{ch_t}  ({100*ch_p/max(ch_t,1):.0f}%)")
    total = n + ce_t + ch_t
    tot_pass = spass + ce_p + ch_p
    print(f"TOTAL                  : {tot_pass}/{total}  ({100*tot_pass/total:.1f}%)   in {time.time()-t_all:.0f}s")

    os.makedirs(os.path.dirname(SHEET), exist_ok=True)
    with open(SHEET, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["section", "question", "kind", "result", "want", "got", "answer"])
        w.writerows(rows)
    print(f"\nSheet: {os.path.abspath(SHEET)}")


if __name__ == "__main__":
    main()
