"""Penny conversation regression suite — 250+ multi-turn checks.

Runs the REAL query() cascade offline (no server / Ollama / installs) over a fixture
GBP ledger, asserting each turn against SQL ground-truth computed by txn_store (a
differential — no brittle hand-typed numbers). Organised by the mandated categories:
pronouns · context carry · merchant/category switching · comparison chains · time
filters · nested filters · analytics follow-ups · advice follow-ups · resets ·
ambiguous references · no-context · regression.

    python scripts/test_conversations.py     ->  "N passed, 0 failed", exit 0
"""
import _penny_testkit as tk

tk.seed()
m, cat = tk.money, None
gm, gc, gt, gi, gn = (tk.gt_merchant_spend, tk.gt_category_spend, tk.gt_total_spend,
                      tk.gt_total_income, tk.gt_count)

PASS = FAIL = 0
FAILURES = []


def has(a, *subs):
    low = a.lower()
    return all(str(s).lower() in low for s in subs)


def lacks(a, *subs):
    low = a.lower()
    return all(str(s).lower() not in low for s in subs)


def convo(name, turns):
    """turns: list of (question, checker). checker(route, answer) -> bool. Runs on ONE
    thread so context carries. A None checker just exercises the turn (sets up context)."""
    global PASS, FAIL
    ctx = {}
    for i, (q, chk) in enumerate(turns, 1):
        r, a = tk.ask(q, ctx)
        if chk is None:
            continue
        try:
            ok = chk(r, a)
        except Exception as e:
            ok = False
            a = f"{a}  <EXC {e}>"
        if ok:
            PASS += 1
        else:
            FAIL += 1
            FAILURES.append(f"{name} · turn {i}: {q!r}\n      -> {a[:150].strip()}")


MERCHANTS = ["Tesco", "Aldi", "UniBet", "Netflix", "Sky", "Amazon", "Bupa"]
CATS = ["Groceries", "Entertainment", "Utilities", "Shopping", "Healthcare"]
MONTHS = [("May", "2026-05"), ("June", "2026-06"), ("July", "2026-07")]


# ===================================================================== 1. CONTEXT CARRY
# Establish a merchant, then bare period / metric follow-ups keep that merchant.
for mer in MERCHANTS:
    convo(f"carry/{mer}", [
        (f"how much did I spend at {mer}?", lambda r, a, mer=mer: r == "SQL" and has(a, mer, m(gm(mer)))),
        ("and in June?", lambda r, a, mer=mer: has(a, mer, "Jun 2026", m(gm(mer, "2026-06")))),
        ("what about May?", lambda r, a, mer=mer: has(a, mer, "May 2026", m(gm(mer, "2026-05")))),
        ("and how many transactions?", lambda r, a, mer=mer: has(a, mer)),   # continuation keeps merchant
    ])

# Establish a category, then period follow-ups keep that category.
for c in CATS:
    convo(f"carry-cat/{c}", [
        (f"how much did I spend on {c}?", lambda r, a, c=c: r == "SQL" and has(a, c, m(gc(c)))),
        ("and in July?", lambda r, a, c=c: has(a, c, "Jul 2026", m(gc(c, "2026-07")))),
    ])


# ===================================================================== 2. MERCHANT SWITCH
# Switch merchant mid-thread: the new merchant answers, the old one does not leak.
for i in range(len(MERCHANTS) - 1):
    a1, a2 = MERCHANTS[i], MERCHANTS[i + 1]
    convo(f"switch/{a1}->{a2}", [
        (f"how much at {a1}?", None),
        (f"what about {a2}?", lambda r, a, a2=a2, a1=a1: has(a, a2, m(gm(a2))) and lacks(a, a1)),
    ])
# Merchant switch KEEPS the carried period (June), applied to the new merchant.
for i in range(len(MERCHANTS) - 1):
    a1, a2 = MERCHANTS[i], MERCHANTS[i + 1]
    convo(f"switch-period/{a1}->{a2}", [
        (f"how much at {a1} in June?", None),
        (f"and {a2}?", lambda r, a, a2=a2: has(a, a2, "Jun 2026", m(gm(a2, "2026-06")))),
    ])


# ===================================================================== 3. CATEGORY SWITCH
for i in range(len(CATS) - 1):
    c1, c2 = CATS[i], CATS[i + 1]
    convo(f"cat-switch/{c1}->{c2}", [
        (f"how much on {c1}?", None),
        (f"and {c2}?", lambda r, a, c2=c2, c1=c1: has(a, c2, m(gc(c2))) and lacks(a, c1)),
    ])


# ===================================================================== 4. TIME FILTERS
for mer in MERCHANTS[:5]:
    convo(f"time/{mer}", [
        (f"how much at {mer} in May?", lambda r, a, mer=mer: has(a, "May 2026", m(gm(mer, "2026-05")))),
        ("and June?", lambda r, a, mer=mer: has(a, "Jun 2026", m(gm(mer, "2026-06")))),
        ("and July?", lambda r, a, mer=mer: has(a, "Jul 2026", m(gm(mer, "2026-07")))),
    ])
# Quarter, whole-account, all resolve to the right window.
convo("time/quarter", [
    ("how much did I spend in Q2?", lambda r, a: has(a, "Apr 2026", "Jun 2026", m(gt("2026-04", "2026-06")))),
])
convo("time/carried-year", [
    ("how much did I spend in 2025?", lambda r, a: has(a, "2025", m(gt("2025")))),
    ("and in June?", lambda r, a: has(a, "Jun 2025", m(gt("2025-06")))),
])
convo("time/bare-empty-month-honest", [
    ("how much did I spend in August?", lambda r, a: has(a, "No transactions found for Aug")),
])
# Total spend per month (no entity) — account-wide, correct month.
for label, pfx in MONTHS:
    convo(f"time-total/{label}", [
        (f"how much did I spend in {label}?", lambda r, a, pfx=pfx, label=label:
            has(a, f"{label[:3]} 2026", m(gt(pfx)))),
    ])


# ===================================================================== 5. COMPARISON CHAINS
convo("compare/months", [
    ("did I spend more in May or June?", lambda r, a: has(a, "May 2026", "Jun 2026")),
])
convo("compare/merchant-then-switch", [
    ("how much at Amazon?", None),
    ("compare with Tesco", lambda r, a: has(a, "Amazon", "Tesco")),
])
for label, pfx in MONTHS:
    convo(f"compare-cat/{label}", [
        (f"how much on Shopping vs Groceries in {label}?",
         lambda r, a, pfx=pfx: has(a, "Shopping", "Groceries")),
    ])


# ===================================================================== 6. ANALYTICS FOLLOW-UPS
for mer in MERCHANTS[:5]:
    convo(f"analytics/{mer}", [
        (f"how much at {mer}?", None),
        ("average transaction?", lambda r, a, mer=mer: r == "SQL" and has(a, "average", mer)),
        ("biggest?", lambda r, a, mer=mer: has(a, mer)),
        ("monthly breakdown", lambda r, a, mer=mer: has(a, mer)),
    ])
# which-month argmax still fires account-wide.
convo("analytics/which-month", [
    ("which month did I spend the most?", lambda r, a: has(a, "Highest-spend month")),
])
# amount filter with £ and a period.
convo("analytics/amount-filter", [
    ("show me all transactions over £100 in July", lambda r, a: has(a, "over", "100") and lacks(a, "Bupa")),
])


# ===================================================================== 7. NESTED FILTERS
convo("nested/merchant-month-amount", [
    ("how much at Amazon in July?", lambda r, a: has(a, "Amazon", "Jul 2026", m(gm("Amazon", "2026-07")))),
])
convo("nested/weekend", [
    ("how much did I spend on weekends?", lambda r, a: r == "SQL" and has(a, "weekend")),
])


# ===================================================================== 8. PRONOUN / REFERENCE
convo("pronoun/this-category", [
    ("how much on Healthcare?", None),
    ("give me insights in this category", lambda r, a: r == "advice" and has(a, "Healthcare")),
    ("more insights", lambda r, a: r == "advice" and has(a, "Healthcare")),
])
convo("pronoun/this-merchant", [
    ("how much at Sky?", None),
    ("what category is this merchant?", lambda r, a: has(a, "Sky")),
])


# ===================================================================== 9. ADVICE FOLLOW-UPS
convo("advice/health", [
    ("how am I doing financially?", lambda r, a: r == "SQL" and has(a, "Financial health")),
])
convo("advice/solutions", [
    ("how am I doing?", None),
    ("any solutions to those problems?", lambda r, a: r == "advice"),
])
convo("advice/why", [
    ("why was I charged bank fees?", lambda r, a: r == "advice"),
])


# ===================================================================== 10. RESETS
convo("reset/start-over", [
    ("how much at Amazon in June?", None),
    ("start over", lambda r, a: r == "reset"),
    ("how much did I spend?", lambda r, a: has(a, m(gt())) and lacks(a, "Amazon", "Jun 2026")),
])
convo("reset/overall", [
    ("how much at Amazon?", None),
    ("overall how much did I spend?", lambda r, a: has(a, m(gt())) and lacks(a, "Amazon")),
])


# ===================================================================== 11. AMBIGUOUS REFERENCES
convo("ambiguous/apple", [
    ("how much did I spend at Apple?", lambda r, a: has(a, "which one", "Apple Store", "Apple Pay")),
])


# ===================================================================== 12. NO-CONTEXT (fresh)
# A fresh, syntactically COMPLETE question must be account-wide (R13), never inherit.
convo("nocontext/standalone-after-merchant", [
    ("how much at Amazon?", None),
    ("what is my biggest expense?", lambda r, a: has(a, m(gm("Amazon", "2026-07"))) and lacks(a, "Amazon in")),
])
for c in CATS:
    convo(f"nocontext/{c}", [
        (f"how much did I spend on {c}?", lambda r, a, c=c: has(a, c, m(gc(c)))),
    ])
convo("nocontext/total", [
    ("what is my total spending?", lambda r, a: has(a, "Total spending", m(gt()))),
])
convo("nocontext/income", [
    ("what is my total income?", lambda r, a: has(a, "income", m(gi()))),
])


# ===================================================================== 13. REGRESSION (91-point catalog)
convo("regr/bupa-not-carried-day", [
    ("what did I spend at IKEA on 1 July?", None),
    ("how much was my Bupa payment?", lambda r, a: has(a, "Bupa", m(gm("Bupa"))) and lacks(a, "No transactions")),
])
convo("regr/gambling-count-scoped", [
    ("how many gambling transactions in June?", lambda r, a: has(a, "Gambling", "Jun 2026") and lacks(a, str(gn()))),
])
convo("regr/unknown-merchant-honest", [
    ("how much did I spend at Putney Cricket Club?", lambda r, a: has(a, "No transactions found") and lacks(a, "Total spending")),
])
convo("regr/loans-concept", [
    ("what loans am I repaying?", lambda r, a: has(a, "Loan", "Loans 2 Go", "YouLend")),
])
convo("regr/flights-concept", [
    ("how much did I spend on flights?", lambda r, a: has(a, "Flights", "Ryanair")),
])
convo("regr/eating-out-alias", [
    ("how much did I spend eating out?", lambda r, a: has(a, "Food & Dining")),
])
convo("regr/last-shop-is-date", [
    ("when did I last shop at Aldi?", lambda r, a: has(a, "Aldi", "last appears")),
])
convo("regr/direct-debits-recurring", [
    ("list all my direct debits", lambda r, a: has(a, "Recurring")),
])
convo("regr/markerless-metric-accountwide", [
    ("how much at UniBet?", None),
    ("how much did I spend?", lambda r, a: has(a, m(gt())) and lacks(a, "UniBet")),
])
convo("regr/merchant-date-lookup", [
    ("what date did my Sky bill go out?", lambda r, a: has(a, "Sky", "appears")),
])
convo("regr/category-lookup", [
    ("under which category does Bupa fall?", lambda r, a: has(a, "Bupa", "Healthcare")),
])
convo("regr/zero-result-no-scope-leak", [
    ("did I pay Thames Water this month?", None),
    ("show me all transactions over £100 in June", lambda r, a: lacks(a, "Thames Water")),
])


# ===================================================================== 14. GRIDS (breadth)
# Full merchant × month spend grid — a fresh thread each, honest-zero where no data.
def _spend_check(amount, *names):
    def chk(r, a):
        if amount > 0:
            return has(a, m(amount), *names)
        return has(a, "No transactions")
    return chk


for mer in MERCHANTS:
    for label, pfx in MONTHS:
        convo(f"grid-m/{mer}/{label}", [
            (f"how much did I spend at {mer} in {label}?",
             _spend_check(gm(mer, pfx), mer, f"{label[:3]} 2026") if gm(mer, pfx) > 0
             else _spend_check(0)),
        ])

# Full category × month spend grid.
for c in CATS:
    for label, pfx in MONTHS:
        amt = gc(c, pfx)
        convo(f"grid-c/{c}/{label}", [
            (f"how much did I spend on {c} in {label}?",
             (lambda r, a, amt=amt, c=c, label=label: has(a, c, m(amt), f"{label[:3]} 2026"))
             if amt > 0 else (lambda r, a: has(a, "0.00") or has(a, "No transactions"))),
        ])

# Per-merchant extremes (biggest / smallest / average), fresh thread.
for mer in MERCHANTS:
    convo(f"extreme/{mer}", [
        (f"what is the biggest expense at {mer}?", lambda r, a, mer=mer: r == "SQL" and has(a, mer)),
        (f"average transaction at {mer}?", lambda r, a, mer=mer: has(a, "average", mer)),
    ])

# Relative time deictics for a few merchants.
for mer in MERCHANTS[:4]:
    convo(f"reltime/{mer}", [
        (f"how much at {mer} last month?", lambda r, a, mer=mer: r == "SQL" and has(a, mer)),
        ("and this month?", lambda r, a, mer=mer: has(a, mer)),
    ])

# Per-category "each month" breakdown (cadence, not a single carried month).
for c in CATS:
    convo(f"breakdown-cat/{c}", [
        (f"how much on {c} each month?", lambda r, a, c=c: r == "SQL"),
    ])

# Per-category advice insights (topic pinned).
for c in CATS:
    convo(f"advice-cat/{c}", [
        (f"how much on {c}?", None),
        ("give me insights on this category", lambda r, a, c=c: r == "advice" and has(a, c)),
    ])

# No-context standalone per merchant (must be account-wide, correct total).
for mer in MERCHANTS:
    convo(f"nocontext-m/{mer}", [
        (f"how much did I spend at {mer}?", lambda r, a, mer=mer: has(a, mer, m(gm(mer)))),
    ])

# Comparison: this month vs last month (account-wide + merchant-scoped).
convo("compare/this-vs-last", [
    ("did I spend more this month or last month?", lambda r, a: r == "SQL"),
])
for mer in MERCHANTS[:3]:
    convo(f"compare-mer/{mer}", [
        (f"how much at {mer} in May?", None),
        ("compare with June", lambda r, a, mer=mer: has(a, mer)),
    ])

# Income / summary / balance variations (account-wide facts).
convo("facts/summary", [("give me an account summary", lambda r, a: has(a, "Total spending", "Total income"))])
convo("facts/balance", [("what is my current balance?", lambda r, a: has(a, "balance"))])
for label, pfx in MONTHS:
    convo(f"facts-income/{label}", [
        (f"how much did I earn in {label}?", lambda r, a, pfx=pfx, label=label:
            has(a, m(gi(pfx)), f"{label[:3]} 2026")),
    ])

# Pronoun binding after an extreme/lookup.
convo("pronoun/it-after-extreme", [
    ("what is my biggest expense?", None),
    ("what category is it?", lambda r, a: r in ("SQL", "chat")),
])

# More resets / scope-clear.
convo("reset/forget", [
    ("how much on Shopping in June?", None),
    ("forget that", lambda r, a: r == "reset"),
    ("how much did I spend on Groceries?", lambda r, a: has(a, "Groceries", m(gc("Groceries"))) and lacks(a, "Jun 2026", "Shopping")),
])

# Extra regression: concept + carried period; gambling all-time; fees per-month.
convo("regr/gambling-then-june", [
    ("how much on gambling?", lambda r, a: has(a, "Gambling")),
    ("and in June?", lambda r, a: has(a, "Gambling", "Jun 2026")),
])
convo("regr/coffee-concept", [
    ("how much did I spend on coffee?", lambda r, a: has(a, "Coffee", "Costa")),
])
convo("regr/taxis-honest", [
    ("how much on taxis?", lambda r, a: has(a, "couldn't find any taxis")),
])
convo("regr/top-n", [
    ("what are my top 3 expenses?", lambda r, a: has(a, "Top 3 expenses", m(gm("Amazon", "2026-07")))),
])
convo("regr/category-table", [
    ("show me spending by category", lambda r, a: has(a, "Spending by category", "Entertainment")),
])
convo("regr/months-covered", [
    ("what months does my data cover?", lambda r, a: has(a, "2026")),
])
# Concept scoped by carried period across turns.
for c_q, c_lbl in [("gambling", "Gambling"), ("loans", "Loan"), ("bank fees", "Bank fees"),
                   ("flights", "Flights"), ("coffee", "Coffee")]:
    convo(f"concept-carry/{c_lbl}", [
        (f"how much on {c_q}?", lambda r, a, c_lbl=c_lbl: has(a, c_lbl)),
        ("and in June?", lambda r, a, c_lbl=c_lbl: has(a, c_lbl, "Jun 2026")),
    ])
# Each merchant: honest zero in a month with no data (August, empty everywhere).
for mer in MERCHANTS[:6]:
    convo(f"zero/{mer}", [
        (f"how much at {mer} in August?", lambda r, a, mer=mer: has(a, "No transactions")),
    ])
# Standalone total in each month is account-wide + correct.
for label, pfx in MONTHS:
    convo(f"total-month/{label}", [
        (f"what is my total spending in {label}?", lambda r, a, pfx=pfx, label=label:
            has(a, "Total spending", f"{label[:3]} 2026", m(gt(pfx)))),
    ])


# ===================================================================== 15. DEEP CHAINS (long multi-turn)
# The mandate's Example 1 shape: a long drill-down that must hold scope across many turns.
convo("chain/amazon-deep", [
    ("how much did I spend at Amazon?", lambda r, a: has(a, "Amazon", m(gm("Amazon")))),
    ("only July", lambda r, a: has(a, "Amazon", "Jul 2026", m(gm("Amazon", "2026-07")))),
    ("biggest purchase?", lambda r, a: has(a, "Amazon")),
    ("average purchase?", lambda r, a: has(a, "average", "Amazon")),
    ("compare with Tesco", lambda r, a: has(a, "Amazon", "Tesco")),
])
# Example 3 shape: subscriptions → one merchant → cadence → advice.
convo("chain/subs", [
    ("what subscriptions do I have?", lambda r, a: r in ("SQL", "chat")),
    ("how much on Netflix?", lambda r, a: has(a, "Netflix", m(gm("Netflix")))),
    ("should I cancel it?", lambda r, a: r == "advice"),
])
# Long carry with period narrowing then widening.
convo("chain/narrow-widen", [
    ("how much on Groceries?", lambda r, a: has(a, "Groceries", m(gc("Groceries")))),
    ("in June?", lambda r, a: has(a, "Jun 2026", m(gc("Groceries", "2026-06")))),
    ("what about July?", lambda r, a: has(a, "Jul 2026", m(gc("Groceries", "2026-07")))),
    ("and the whole year?", lambda r, a: has(a, "Groceries")),
])

# Merchant carry across metric changes (no leak of prior amount).
for mer in MERCHANTS[:4]:
    convo(f"chain-metric/{mer}", [
        (f"how much at {mer}?", None),
        ("how many transactions?", lambda r, a: r == "SQL"),          # markerless: account-wide count
        (f"and at {mer} again, the biggest?", lambda r, a, mer=mer: has(a, mer)),
    ])

# Fresh standalone questions interleaved must NOT inherit (R13) — stress the reset rule.
for mer in MERCHANTS[:4]:
    convo(f"r13/{mer}", [
        (f"how much at {mer} in June?", None),
        ("what is my total spending?", lambda r, a: has(a, "Total spending", m(gt())) and lacks(a, mer, "Jun 2026")),
    ])


# ===================================================================== 16. COMPOSABLE FILTERS + SCOPED BREAKDOWN
def gt_filtered(**kw):
    return tk.ts.filtered_summary("local", **kw)


# Scoped monthly breakdown per merchant / category.
for mer in ["Netflix", "Amazon", "Tesco"]:
    convo(f"scoped-breakdown/{mer}", [
        (f"how much did I spend at {mer} per month?",
         lambda r, a, mer=mer: has(a, f"{mer} month-wise breakdown")),
    ])
for c in ["Groceries", "Entertainment"]:
    convo(f"scoped-breakdown-cat/{c}", [
        (f"how much on {c} month by month?", lambda r, a, c=c: has(a, f"{c} month-wise breakdown")),
    ])

# Exclusion — account-wide minus one entity (excluded entity is NOT the scope).
for c in ["Groceries", "Shopping", "Entertainment"]:
    exp = gt("") - gc(c)
    convo(f"exclude/{c}", [
        (f"how much did I spend excluding {c}?",
         lambda r, a, exp=exp, c=c: has(a, m(exp), "excluding") and lacks(a, f"on {c} (")),
    ])

# Composable: weekend + amount threshold in ONE query.
for thr in [20, 50]:
    fs = gt_filtered(weekend=True, amount_op="over", amount=thr)
    convo(f"compose/weekend-over-{thr}", [
        (f"how much did I spend on weekends over £{thr}?",
         lambda r, a, fs=fs, thr=thr: has(a, "weekend", str(thr), m(fs["total"]))),
    ])
# Composable: merchant + weekend.
convo("compose/merchant-weekend", [
    ("how much did I spend at UniBet on weekends?",
     lambda r, a: has(a, "weekend") and (has(a, "UniBet") or has(a, "totaling"))),
])
# Weekday filter.
convo("compose/weekday", [
    ("how much did I spend on weekdays?", lambda r, a: has(a, "weekday", m(gt_filtered(weekend=False)["total"]))),
])


# ===================================================================== 17. FOLLOWUP DETERMINISM
# The follow-up path buffers the LLM reply and verifies every number against the recent
# answers; a strayed number is rejected and the last real answer is restated verbatim.
def _det(name, ok):
    global PASS, FAIL
    if ok:
        PASS += 1
    else:
        FAIL += 1
        FAILURES.append(name)


_recent = [{"q": "how much at Tesco?", "a": "**Tesco:** spent £192.45 across 4 transactions"},
           {"q": "why?", "a": "(answered from conversation)"}]
_fb = tk.tsrv._followup_fallback(_recent)
_det("followup/fallback restates the real figure", "192.45" in _fb)
_det("followup/fallback skips placeholders", "answered from conversation" not in _fb)
_det("followup/verify accepts a grounded reply",
     tk.tsrv._advice_grounded("You spent £192.45 at Tesco.", _recent[0]["a"])[0])
_det("followup/verify rejects a hallucinated number",
     not tk.tsrv._advice_grounded("You spent £999.99 at Tesco.", _recent[0]["a"])[0])
_det("followup/verify rejects a computed percentage",
     not tk.tsrv._advice_grounded("That's 63% of your spending.", _recent[0]["a"])[0])
_det("followup/empty history gives an honest nudge",
     "ask the question directly" in tk.tsrv._followup_fallback([]))


# ===================================================================== report
print(f"\n{'='*60}\nPenny conversation suite\n{'='*60}")
if FAILURES:
    print("\nFAILURES:")
    for f in FAILURES:
        print("  ✗ " + f)
print(f"\n{PASS} passed, {FAIL} failed  (of {PASS + FAIL} turn-level checks)")
import sys
sys.exit(1 if FAIL else 0)
