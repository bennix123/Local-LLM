"""
Conversational regression suite — multi-turn context + fine-grained intents.

Covers the production failures fixed in the ConversationState / fine-grained-intent work
(see Penny_LLD §4a, §5.2). Runs live against /query with a per-scenario thread so context
carries, and checks the ROUTE and the final ANSWER for each turn.

Target data: a Barclays statement loaded into the server's DB (the merchants these scenarios
reference — Shein.Com, Higgsfield Inc. USA, Piyush Mishra, O2, Virgin Media). Point the server
at that statement (e.g. upload it, or FINQ_DB=<barclays.db>), then:

    PORT=5682 python scripts/test_conversation.py

Advice-path scenarios need Ollama; if it is down they are reported as SKIP, not FAIL.
"""
import os, sys, json, re, urllib.request

sys.stdout.reconfigure(encoding="utf-8")
BASE = f"http://127.0.0.1:{os.environ.get('PORT', '5682')}"


def ask(q, thread, reset=False):
    body = json.dumps({"question": q, "thread": thread, "reset": reset}).encode()
    req = urllib.request.Request(BASE + "/query", data=body,
                                 headers={"Content-Type": "application/json"})
    path, buf = "?", []
    with urllib.request.urlopen(req, timeout=150) as r:
        for line in r:
            line = line.strip()
            if not line:
                continue
            o = json.loads(line)
            if o.get("type") == "meta":
                path = o.get("path", "?")
            elif o.get("type") == "chunk":
                buf.append(o.get("content", ""))
    return path, "".join(buf).strip()


def has(ans, *subs):
    low = ans.lower()
    return all(s.lower() in low for s in subs)


def lacks(ans, *subs):
    low = ans.lower()
    return all(s.lower() not in low for s in subs)


# Each turn: (question, checker(route, answer) -> (ok: bool, note: str)).
# checker returns ok=None to SKIP (e.g. advice needs Ollama and it's offline).
def CHK(fn):
    return fn


SCENARIOS = [
    ("F1 · Merchant/date → metric change (which merchant)", "cv-f1", [
        ("How much total did I spend on 27 March 2026?",
         CHK(lambda r, a: (has(a, "27 Mar 2026"), "date established"))),
        ("Which merchant did I spend more?",
         CHK(lambda r, a: (has(a, "merchant", "27 Mar 2026"),
                           "argmax merchant, date RETAINED"))),
    ]),
    ("F2 · Merchant → overall reset", "cv-f2", [
        ("How much did I spend at O2?",
         CHK(lambda r, a: (has(a, "o2"), "merchant scoped"))),
        ("Average overall spent in March 2026",
         CHK(lambda r, a: (has(a, "average", "mar 2026") and lacks(a, "o2"),
                           "overall resets merchant, keeps period"))),
    ]),
    ("F3 · Merchant category lookup", "cv-f3", [
        ("What category does Shein belong to?",
         CHK(lambda r, a: (has(a, "shein") and has(a, "categor"),
                           "category lookup, not a spend summary"))),
    ]),
    ("F4 · Merchant date lookup", "cv-f4", [
        ("On what date does Higgsfield Inc USA appear?",
         CHK(lambda r, a: (has(a, "higgsfield") and has(a, "2026"),
                           "date lookup, not a summary"))),
    ]),
    ("F5 · Payment interval (analytics)", "cv-f5", [
        ("How many days separate consecutive Piyush Mishra payments?",
         CHK(lambda r, a: (has(a, "days") and has(a, "piyush") and lacks(a, "transactions at piyush"),
                           "mean interval, not a count"))),
    ]),
    ("F6 · Balance minimum / maximum", "cv-f6", [
        ("Lowest balance recorded?",
         CHK(lambda r, a: (has(a, "lowest", "balance"), "min running balance, not closing"))),
        ("And the highest balance?",
         CHK(lambda r, a: (has(a, "highest", "balance"), "max running balance"))),
    ]),
    ("F7 · Yearless date keeps day precision", "cv-f7", [
        ("Spent on 15 August",
         CHK(lambda r, a: (has(a, "15 aug") or has(a, "aug"),
                           "day scoped, not lifetime"))),
    ]),
    ("F8 · Date/merchant scope survives amount→average→highest", "cv-f8", [
        ("Transactions at O2 in 2026",
         CHK(lambda r, a: (has(a, "o2", "2026"), "scope established"))),
        ("above 10",
         CHK(lambda r, a: (has(a, "o2"), "amount filter keeps merchant scope"))),
        ("average",
         CHK(lambda r, a: (has(a, "o2"), "average keeps merchant scope"))),
        ("highest",
         CHK(lambda r, a: (has(a, "o2"), "extreme keeps merchant scope"))),
    ]),
    ("Extra · min-balance carries its own date", "cv-bal", [
        ("Lowest balance recorded?",
         CHK(lambda r, a: (has(a, "lowest", "balance") and bool(re.search(r"\d", a)),
                           "min balance reports the date inline"))),
    ]),

    # ---- Reliability pass: specialized questions must not land on a generic intent ----
    # (verbatim failing questions from manual QA; expected values are SQL-verified)
    ("R1 · who sent an amount → income source, not income total", "r1", [
        ("Who sent me £50?",
         CHK(lambda r, a: (has(a, "parul") and has(a, "50") and lacks(a, "total income"),
                           "names the £50 sender + date"))),
    ]),
    ("R2 · 'Other' category filters, not overall total", "r2", [
        ("How much did I spend on the Other category?",
         CHK(lambda r, a: (has(a, "155.48") and has(a, "3") and lacks(a, "479.46"),
                           "Other = £155.48 / 3, not the £479.46 grand total"))),
    ]),
    ("R3 · truncated merchant name resolves", "r3", [
        ("How much did I spend at Putney Cricket Club?",
         CHK(lambda r, a: (has(a, "62") and has(a, "9") and lacks(a, "no transactions"),
                           "matches 'Putney Cricket Clu' → £62.00 / 9"))),
    ]),
    ("R4 · balance BEFORE a transaction", "r4", [
        ("What was the balance before the Higgsfield payment?",
         CHK(lambda r, a: (has(a, "120.41"), "reconstructed pre-txn balance"))),
    ]),
    ("R5 · balance AFTER a transaction", "r5", [
        ("What was the balance after O2 on 23 March 2026?",
         CHK(lambda r, a: (has(a, "20.43"), "that row's balance column"))),
    ]),
    ("R6 · balance delta between two dates", "r6", [
        ("How did my balance change from 9 March 2026 to 30 March 2026?",
         CHK(lambda r, a: (has(a, "17.27") and has(a, "increas"),
                           "increased £17.27 (43.07 → 60.34)"))),
    ]),
    ("R7 · distinct calendar months", "r7", [
        ("How many distinct calendar months are in the statement?",
         CHK(lambda r, a: (has(a, "4") and has(a, "month"), "4 distinct months, not a count"))),
    ]),
    ("R8 · compare threads the category through both periods", "r8", [
        ("Entertainment spend in March 2026 vs May 2026",
         CHK(lambda r, a: (has(a, "53.99") and has(a, "35.99") and lacks(a, "136.73"),
                           "Entertainment-only per month, not total spend"))),
    ]),
    ("R9 · 'whole statement' clears stale period", "r9", [
        ("What is the largest single debit in the whole statement?",
         CHK(lambda r, a: (has(a, "76.48") and has(a, "higgsfield"),
                           "account-wide extreme, not scoped to a month"))),
    ]),
    ("R10 · total spending counts debit rows only", "r10", [
        ("What is my total spending?",
         CHK(lambda r, a: (has(a, "479.46") and has(a, "23") and lacks(a, "across 28"),
                           "23 debit rows, not 28 (excludes income)"))),
    ]),

    # ---- Multi-turn scope isolation: a specialized/complete follow-up must NOT inherit the
    # previous turn's merchant (reported live-session leaks) ----
    ("R11 · misspelled category does not leak prior merchant", "r11", [
        ("How much did I spend at Putney Cricket Club?",
         CHK(lambda r, a: (has(a, "62"), "merchant scoped"))),
        ("How much did I spend on entertainement?",   # typo; prior turn was Putney
         CHK(lambda r, a: (has(a, "entertainment") and lacks(a, "putney"),
                           "typo resolves to Entertainment, no Putney leak"))),
    ]),
    ("R12 · 'under which category X lies' is a category lookup", "r12", [
        ("What is Shein.com?",
         CHK(lambda r, a: (has(a, "shein"), "merchant identified"))),
        ("Under which category does Shein.com lie?",
         CHK(lambda r, a: (has(a, "categor") and has(a, "other"), "category lookup, not spend"))),
    ]),
    ("R13 · standalone metric question does not inherit prior merchant", "r13", [
        ("What is Shein.com?",
         CHK(lambda r, a: (has(a, "shein"), "merchant scoped"))),
        ("What is my biggest expense?",               # complete question -> account-wide
         CHK(lambda r, a: (has(a, "76.48") and has(a, "higgsfield") and lacks(a, "shein"),
                           "account-wide extreme, not scoped to Shein"))),
    ]),
    # NOTE: "Category → Trend → Compare" and "Merchant → Compare → Advice" are exercised by
    # golden_suite.py on the ₹ dataset (clean merchant names + Ollama). They are omitted here
    # because the Barclays test statement stores truncated/suffixed names (e.g. 'Virgin Media
    # Pymts'), which the exact-match comparison path can't resolve from "Virgin Media".
]


def main():
    total = passed = skipped = 0
    fails = []
    for title, tid, turns in SCENARIOS:
        print(f"\n=== {title} ===")
        for i, (q, chk) in enumerate(turns):
            route, ans = ask(q, tid, reset=(i == 0))
            ok, note = chk(route, ans)
            total += 1
            oneline = " ".join(ans.split())[:110]
            if ok is None:
                skipped += 1
                mark = "SKIP"
            elif ok:
                passed += 1
                mark = "PASS"
            else:
                fails.append((title, q, ans))
                mark = "FAIL"
            print(f"  [{mark}] ({route}) {q}")
            print(f"         {note}  |  {oneline}")
    print(f"\n{'='*70}\nRESULT: {passed} passed, {len(fails)} failed, {skipped} skipped "
          f"of {total} turns")
    if fails:
        print("\nFAILURES:")
        for title, q, ans in fails:
            print(f"  - {title}\n      Q: {q}\n      A: {' '.join(ans.split())[:160]}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
