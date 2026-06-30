"""
1000+ battery. Three parts:
  PART 1  STANDALONE  — bulk SQL-verified coverage (merchant×month, category×month,
                        days, ordinal dates, count-at-merchant, Hinglish/typos/slang)
  PART 2  CONTEXT     — deep multi-turn chains (thread model) testing context holding
  PART 3  PROBES      — adversarial / creative questions to see what passes, what the
                        LLM handles, and what's (correctly) unsupported

Reuses rag_400 + rag_500 cases/helpers. Sheet -> data/rag_1000_sheet.csv
"""
import os, sys, time, csv

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(__file__))
import rag_400_test as R
import rag_500_test as R5

SHEET = os.path.join(os.path.dirname(__file__), "..", "data", "rag_1000_sheet.csv")
C, MON, plabel = R.C, R.MON, R.plabel
MERCH = ["Swiggy", "Zomato", "Amazon", "Flipkart", "Netflix", "Spotify",
         "Zerodha", "Uber", "BigBasket", "Jio", "Ola", "Myntra"]
CATS = ["Groceries", "Food & Dining", "Transport", "Shopping", "Utilities",
        "Entertainment", "Healthcare", "Investment & Insurance"]


def extra_standalone():
    cases = []
    months = [f"2024-{m:02d}" for m in range(1, 13)] + [f"2025-{m:02d}" for m in range(1, 13)]
    # merchant x every month
    for mch in MERCH:
        for P in months:
            cases.append((f"how much did I spend at {mch} in {plabel(P)}?", "merchant", P, mch))
    # category x every month
    for cat in CATS:
        for P in months:
            cases.append((f"how much did I spend on {cat} in {plabel(P)}?", "category", P, cat))
    # ordinal-date merchant queries (the day-first ordinal edge)
    for mch, P in [("Swiggy", "2024-06-15"), ("Zomato", "2024-09-27"), ("Amazon", "2025-01-03"),
                   ("Flipkart", "2024-11-22"), ("Uber", "2025-03-01"), ("Zerodha", "2024-05-31"),
                   ("Netflix", "2024-12-12"), ("Jio", "2025-07-18"), ("BigBasket", "2024-08-08"),
                   ("Ola", "2025-05-05"), ("Myntra", "2024-03-14"), ("Spotify", "2025-02-07")]:
        y, m, d = P.split("-")
        cases.append((f"what did I spend at {mch} on {int(d)}th {MON[int(m)]} {y}?", "merchant", P, mch))
    # count-at-merchant
    for mch in MERCH[:8]:
        for P in [None, "2024", "2025"]:
            sfx = f" in {plabel(P)}" if P else ""
            cases.append((f"how many transactions at {mch}{sfx}?", "count", P, mch))
    # count-in-category
    for cat in CATS:
        for P in ["2024", "2025"]:
            cases.append((f"how many {cat} transactions in {plabel(P)}?", "count", P, cat))
    return cases


def extra_chains():
    walks = []
    # merchant month-walks (carry merchant + year, change month)
    for mch, y, m0, m1 in [("Amazon", 2024, 1, 5), ("Swiggy", 2025, 6, 10), ("Zerodha", 2024, 7, 11)]:
        turns = [(f"how much did I spend at {mch} in {MON[m0]} {y}?", [C("merchant", f"{y}-{m0:02d}", mch)], False)]
        for m in range(m0 + 1, m1 + 1):
            turns.append((f"and {MON[m]}?", [C("merchant", f"{y}-{m:02d}", mch)], True))
        walks.append(turns)
    # count-at-merchant carry
    walks.append([
        ("how many transactions at Netflix in 2024?", [C("count", "2024", "Netflix")], False),
        ("and in 2025?", [C("count", "2025", "Netflix")], True),
        ("how much did I spend there?", [C("merchant", "2025", "Netflix")], True),
    ])
    # day -> ordinal carry
    walks.append([
        ("what did I spend at Zomato on 27th September 2024?", [C("merchant", "2024-09-27", "Zomato")], False),
        ("and the 28th?", [C("merchant", "2024-09-28", "Zomato")], True),
        ("what about all of September?", [C("merchant", "2024-09", "Zomato")], True),
    ])
    return walks


def probe(q, accepts, note):
    return (q, accepts, note)


def _inr(n):
    import re as _re
    return ts.inr(n)


def CONTAINS(s):
    return [("contains", s)]


def build_probes():
    ts2 = R.ts  # txn_store
    U = R.USER
    inr = ts2.inr
    # --- compute expected figures from SQL for the analytics probes ---
    o24 = ts2.overview(U, None, "2024"); o25 = ts2.overview(U, None, "2025")
    inv24 = next((a for c, a, _ in ts2.by_category(U, None, "2024") if c == "Investment & Insurance"), 0.0)
    excl = o24["debit"] - inv24
    avgm = o24["debit"] / 12
    avgt = o24["debit"] / o24["count"]
    sw = ts2.merchant_spend(U, "Swiggy", None, "2024")["debit"]
    zo = ts2.merchant_spend(U, "Zomato", None, "2024")["debit"]
    diff = o25["debit"] - o24["debit"]
    over = ts2.amount_filter(U, "over", 100000, None, "2024")
    return [
        # --- lookups / phrasing (verifiable) ---
        probe("can you please tell me exactly how much money I spent at Zomato during September 2024?",
              [C("merchant", "2024-09", "Zomato")], "verbose"),
        probe("what did I spend at Swiggy on the 3rd of March 2025?",
              [C("merchant", "2025-03-03", "Swiggy")], "ordinal 'the 3rd of'"),
        probe("how many times did I order from Swiggy in 2024?",
              [C("count", "2024", "Swiggy")], "count-at-merchant"),
        probe("total of all my Netflix payments", [C("merchant", None, "Netflix")], "all-time"),
        probe("biggest expense ever", [C("biggest", None)], "'ever'"),
        probe("spend?", [C("spend", None)], "one word"),
        probe("how much did I spend on food delivery in 2024?",
              [C("category", "2024", "Food & Dining")], "fuzzy category"),
        probe("how much did I spend at zerodha in 2024", [C("merchant", "2024", "Zerodha")], "lowercase"),
        # --- ANALYTICS (now verifiable against SQL figures) ---
        probe("what percent of my 2024 spending was Investment & Insurance?", CONTAINS("69.1%"), "ratio"),
        probe("how much did I spend excluding Investment in 2024?", CONTAINS(inr(excl)), "exclusion"),
        probe("what's my average monthly spend in 2024?", CONTAINS(inr(avgm)), "avg/month"),
        probe("how much do I spend on average per transaction in 2024?", CONTAINS(inr(avgt)), "avg/txn"),
        probe("which month did I spend the most in 2024?", CONTAINS("Mar 2024"), "argmax month"),
        probe("which month did I spend the least in 2024?", CONTAINS("May 2024"), "argmin month"),
        probe("what's my biggest spending category in 2024?", CONTAINS("Investment"), "category argmax"),
        probe("who is my top merchant in 2024?", CONTAINS("Zerodha"), "merchant argmax"),
        probe("show me my top 3 merchants in 2024", CONTAINS("Zerodha"), "top-N merchants"),
        probe("how many transactions over 1 lakh in 2024?", CONTAINS(str(over["count"])), "amount filter"),
        probe("how much did I spend on Swiggy and Zomato together in 2024?", CONTAINS(inr(sw + zo)), "multi-merchant"),
        probe("did I spend more on Groceries or Shopping in 2024?", CONTAINS("Shopping"), "compare categories"),
        probe("how much more did I spend in 2025 than 2024?", CONTAINS(inr(abs(diff))), "difference"),
        probe("compare my 2024 and 2025 spending", CONTAINS(inr(o25["debit"])), "compare periods"),
        probe("how much did I spend in twenty twenty four?", CONTAINS(inr(o24["debit"])), "word-year"),
        probe("how much did I spend last month?", CONTAINS("Nov 2025"), "relative last-month"),
        # --- honesty guards ---
        probe("how much did I spend at Starbucks?", CONTAINS("No transactions"), "unknown merchant -> not found"),
        probe("roast my spending habits", CONTAINS("snapshot"), "judgment -> advice"),
        probe("am I saving enough money?", CONTAINS("snapshot"), "judgment -> advice"),
        probe("what should I cut back on?", CONTAINS("snapshot"), "advice"),
        # --- still genuinely open / unsupported (record only) ---
        probe("how much did I spend in the first quarter of 2024?", None, "quarter parsing"),
        probe("how much did I spend this year?", None, "relative 'this year'"),
        probe("did I spend more in the first half or second half of 2024?", None, "half comparison"),
        probe("how much did I spend on Diwali 2024?", None, "festival date"),
        probe("tell me a joke about my finances", None, "off-topic"),
        probe("what's the most I've ever spent in a single day?", None, "max-day argmax"),
    ]


def main():
    standalone = R.build_standalone() + R5.extra_standalone() + extra_standalone()
    chains = R.CHAINS + R5.extra_chains() + extra_chains()
    probes = build_probes()
    rows, t_all = [], time.time()

    print(f"PART 1 — STANDALONE: {len(standalone)} (fresh thread each)")
    sp = 0
    for i, (q, kind, P, arg) in enumerate(standalone, 1):
        try:
            _, ans = R.ask(q, thread=f"s{i}")
        except Exception as e:
            ans = str(e)
        ok, got, want = R.check_one(kind, P, arg, ans)
        sp += ok
        rows.append(("standalone", q, kind, "PASS" if ok else "FAIL", want, got, ans[:90]))
        if not ok:
            print(f"  FAIL [{kind}] {q[:60]}  want={want} got={got}")
        if i % 150 == 0:
            print(f"   …{i}/{len(standalone)} ({sp} pass)")
    print(f"STANDALONE: {sp}/{len(standalone)} ({100*sp/len(standalone):.1f}%)")

    nt = sum(len(c) for c in chains)
    print(f"\nPART 2 — CONTEXT: {nt} turns / {len(chains)} chains")
    ce_p = ce_t = ch_p = ch_t = 0
    for ci, chain in enumerate(chains, 1):
        for ti, (q, accepts, hard) in enumerate(chain):
            try:
                _, ans = R.ask(q, thread=f"chain{ci}", reset=(ti == 0))
            except Exception as e:
                ans = str(e)
            ok, got, want = R.verify(accepts, ans)
            if hard:
                ch_t += 1; ch_p += ok
            else:
                ce_t += 1; ce_p += ok
            rows.append((f"ctx-{'HARD' if hard else 'easy'}", q, "", "PASS" if ok else "FAIL", want, got, ans[:90]))
            if not ok:
                print(f"  [BAD|{'HARD' if hard else 'easy'}] c{ci} {q[:40]} -> {ans[:42]}")

    print(f"\nPART 3 — PROBES ({len(probes)}):  [verifiable get PASS/FAIL; open get a route]")
    pv_p = pv_t = 0
    for q, accepts, note in probes:
        try:
            path, ans = R.ask(q, thread="probe", reset=True)
        except Exception as e:
            path, ans = "ERR", str(e)
        flat = " ".join(ans.split())
        if accepts:
            ok, got, want = R.verify(accepts, ans)
            pv_t += 1; pv_p += ok
            verdict = "PASS" if ok else "FAIL"
        else:
            verdict = f"OPEN/{path}"
        rows.append(("probe", q, note, verdict, "", "", flat[:120]))
        print(f"  [{verdict:9}] {q[:52]:52} -> {flat[:54]}")

    n = len(standalone)
    print("\n================= RESULTS =================")
    print(f"STANDALONE correctness : {sp}/{n}  ({100*sp/n:.1f}%)")
    print(f"CONTEXT easy           : {ce_p}/{ce_t}  ({100*ce_p/max(ce_t,1):.0f}%)")
    print(f"CONTEXT hard           : {ch_p}/{ch_t}  ({100*ch_p/max(ch_t,1):.0f}%)")
    print(f"PROBES (verifiable)    : {pv_p}/{pv_t}")
    core = n + ce_t + ch_t
    core_pass = sp + ce_p + ch_p
    print(f"CORE TOTAL             : {core_pass}/{core}  ({100*core_pass/core:.1f}%)")
    print(f"GRAND TOTAL questions  : {core + len(probes)}   (in {time.time()-t_all:.0f}s)")

    os.makedirs(os.path.dirname(SHEET), exist_ok=True)
    with open(SHEET, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["section", "question", "kind/note", "result", "want", "got", "answer"])
        w.writerows(rows)
    print(f"\nSheet: {os.path.abspath(SHEET)}")


if __name__ == "__main__":
    main()
