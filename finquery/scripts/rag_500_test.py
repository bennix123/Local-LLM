"""
500+ battery. Reuses the 400 harness (standalone + chains) and adds:
  - merchant x month combos, more ranges/extremes, more Hinglish/typos/slang
  - programmatically generated deep month-walk conversation chains
  - new mixed-dimension / cross-year / Hinglish / back-reference chains

Verifies every answer against SQL; reports standalone + context (easy/hard).
Sheet -> data/rag_500_sheet.csv
"""
import os, sys, time, csv

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(__file__))
import rag_400_test as R   # reuse ask/expected/check_one/verify/plabel/C/MON/build_standalone/CHAINS

SHEET = os.path.join(os.path.dirname(__file__), "..", "data", "rag_500_sheet.csv")
C, MON = R.C, R.MON


# -------- extra standalone --------
def extra_standalone():
    cases = []
    for mch in ["Swiggy", "Amazon", "Zerodha", "Netflix", "Uber", "Flipkart", "Jio", "BigBasket"]:
        for P in ["2024-03", "2024-09", "2025-07"]:
            cases.append((f"how much did I spend at {mch} in {R.plabel(P)}?", "merchant", P, mch))
    for a, b in [("2024-02", "2024-05"), ("2024-08", "2024-11"),
                 ("2025-02", "2025-08"), ("2025-04", "2025-10")]:
        L = f"{R.plabel(a)} to {R.plabel(b)}"
        cases += [(f"how many transactions from {L}?", "count", (a, b), None),
                  (f"how much did I spend from {L}?", "spend", (a, b), None)]
    for P in ["2024-09", "2025-12"]:
        cases += [(f"what was my biggest expense in {R.plabel(P)}?", "biggest", P, None),
                  (f"what was my smallest expense in {R.plabel(P)}?", "smallest", P, None)]
    cases += [
        ("2025 me kitna kharcha hua", "spend", "2025", None),
        ("december 2024 me kitna kharcha", "spend", "2024-12", None),
        ("flipkart pe kitna kharcha 2025", "merchant", "2025", "Flipkart"),
        ("uber pe kitna gaya 2024", "merchant", "2024", "Uber"),
        ("kitne transaction hue july 2025 me", "count", "2025-07", None),
        ("sabse chota kharcha 2024", "smallest", "2024", None),
        ("sabse bada kharcha 2025 me", "biggest", "2025", None),
        ("2024 me kitni income aayi", "income", "2024", None),
        ("how much did i blow on shopping in 2025", "category", "2025", "Shopping"),
        ("cheapest expense in 2025", "smallest", "2025", None),
        ("priciest purchase in 2024", "biggest", "2024", None),
        ("how much on healthcare sept 2025", "category", "2025-09", "Healthcare"),
        ("spend at spotify in 2025", "merchant", "2025", "Spotify"),
        ("number of transactions in feb 2025", "count", "2025-02", None),
    ]
    return cases


# -------- generated deep month-walk chains --------
def walk(kind, year, m0, m1, anchor_fmt, arg=None):
    turns = [(anchor_fmt.format(M=MON[m0], Y=year), [C(kind, f"{year}-{m0:02d}", arg)], False)]
    for m in range(m0 + 1, m1 + 1):
        turns.append((f"and {MON[m]}?", [C(kind, f"{year}-{m:02d}", arg)], True))
    return turns


def extra_chains():
    walks = [
        walk("count", 2024, 1, 6, "how many transactions in {M} {Y}?"),
        walk("count", 2025, 7, 11, "how many transactions in {M} {Y}?"),
        walk("income", 2024, 7, 12, "how much income did I receive in {M} {Y}?"),
        walk("category", 2025, 1, 5, "how much did I spend on Groceries in {M} {Y}?", "Groceries"),
        walk("merchant", 2024, 1, 5, "how much did I spend at Amazon in {M} {Y}?", "Amazon"),
        walk("spend", 2025, 1, 6, "how much did I spend in {M} {Y}?"),
    ]
    hand = [
        # cross-year count
        [("how many transactions in November 2024?", [C("count", "2024-11")], False),
         ("and December?", [C("count", "2024-12")], True),
         ("and January 2025?", [C("count", "2025-01")], False),
         ("and February?", [C("count", "2025-02")], True),
         ("and March?", [C("count", "2025-03")], True)],
        # category -> switch to merchant, carry period
        [("how much did I spend on Shopping in 2024?", [C("category", "2024", "Shopping")], False),
         ("what about at Amazon?", [C("merchant", "2024", "Amazon")], True),
         ("and Flipkart?", [C("merchant", "2024", "Flipkart")], True),
         ("in 2025?", [C("merchant", "2025", "Flipkart")], True)],
        # all-time -> narrow -> month
        [("how much did I spend at Zerodha all time?", [C("merchant", None, "Zerodha")], False),
         ("just 2024?", [C("merchant", "2024", "Zerodha")], True),
         ("and just March 2024?", [C("merchant", "2024-03", "Zerodha")], True)],
        # Hinglish mixed
        [("2025 me kitna kharcha?", [C("spend", "2025")], False),
         ("groceries pe kitna?", [C("category", "2025", "Groceries")], True),
         ("aur 2024 me?", [C("category", "2024", "Groceries")], True),
         ("aur shopping pe?", [C("category", "2024", "Shopping")], True)],
        # extreme walk
        [("biggest expense in 2024?", [C("biggest", "2024")], False),
         ("and 2025?", [C("biggest", "2025")], True),
         ("and the smallest?", [C("smallest", "2025")], True),
         ("in 2024?", [C("smallest", "2024")], True)],
        # back-ref + continue
        [("how much did I spend on Healthcare in 2024?", [C("category", "2024", "Healthcare")], False),
         ("is that high?", [("contains", "")], False),
         ("what about 2025?", [C("category", "2025", "Healthcare")], True),
         ("and Utilities?", [C("category", "2025", "Utilities")], True)],
        # spend -> count -> income on a carried month
        [("how much did I spend in August 2024?", [C("spend", "2024-08")], False),
         ("how many transactions?", [C("count", "2024-08")], True),
         ("and how much income?", [C("income", "2024-08")], True)],
    ]
    return walks + hand


def main():
    standalone = R.build_standalone() + extra_standalone()
    chains = R.CHAINS + extra_chains()
    rows, t_all = [], time.time()

    print(f"PART 1 — STANDALONE: {len(standalone)}  (each in its OWN thread = fresh context)")
    sp = 0
    for i, (q, kind, P, arg) in enumerate(standalone, 1):
        try:
            _, ans = R.ask(q, thread=f"s{i}")   # fresh thread per question -> all-time stays correct
        except Exception as e:
            ans = str(e)
        ok, got, want = R.check_one(kind, P, arg, ans)
        sp += ok
        rows.append(("standalone", q, kind, "PASS" if ok else "FAIL", want, got, ans[:90]))
        if not ok:
            print(f"  FAIL [{kind}] {q}  want={want} got={got} :: {ans[:55]}")
        if i % 80 == 0:
            print(f"   …{i}/{len(standalone)} ({sp} pass)")
    print(f"STANDALONE: {sp}/{len(standalone)} ({100*sp/len(standalone):.1f}%)")

    nt = sum(len(c) for c in chains)
    print(f"\nPART 2 — CONTEXT: {nt} turns / {len(chains)} chains")
    ce_p = ce_t = ch_p = ch_t = 0
    for ci, chain in enumerate(chains, 1):
        for ti, (q, accepts, hard) in enumerate(chain):
            try:
                # one thread per chain; reset on the first turn so context carries within it
                _, ans = R.ask(q, thread=f"chain{ci}", reset=(ti == 0))
            except Exception as e:
                ans = str(e)
            ok, got, want = R.verify(accepts, ans)
            if hard:
                ch_t += 1; ch_p += ok
            else:
                ce_t += 1; ce_p += ok
            tag = "HARD" if hard else "easy"
            rows.append((f"ctx-{tag}", q, "", "PASS" if ok else "FAIL", want, got, ans[:90]))
            if not ok:
                print(f"  [BAD|{tag}] c{ci} {q[:42]:42} -> {ans[:46]}")

    n = len(standalone)
    print("\n================= RESULTS =================")
    print(f"STANDALONE correctness : {sp}/{n}  ({100*sp/n:.1f}%)")
    print(f"CONTEXT easy follow-ups: {ce_p}/{ce_t}  ({100*ce_p/max(ce_t,1):.0f}%)")
    print(f"CONTEXT hard follow-ups: {ch_p}/{ch_t}  ({100*ch_p/max(ch_t,1):.0f}%)")
    total = n + ce_t + ch_t
    tp = sp + ce_p + ch_p
    print(f"TOTAL                  : {tp}/{total}  ({100*tp/total:.1f}%)   in {time.time()-t_all:.0f}s")

    os.makedirs(os.path.dirname(SHEET), exist_ok=True)
    with open(SHEET, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["section", "question", "kind", "result", "want", "got", "answer"])
        w.writerows(rows)
    print(f"\nSheet: {os.path.abspath(SHEET)}")


if __name__ == "__main__":
    main()
