"""Offline routing harness — no server, no Ollama, no extra installs.

Replays both client test sessions (the 8-question routing sweep and the 10-question
concept/analytics sweep) plus regression checks through Penny's deterministic ladder
(intelligence -> concept -> analytics -> factual), with fastapi/uvicorn/numpy/sklearn
stubbed in sys.modules and a fixture GBP ledger seeded into a temp DB. Every check
asserts on the final answer text, so a routing regression fails loudly.

    python scripts/test_offline_routing.py     -> "N passed, 0 failed", exit 0
"""
import os
import sys
import types
import sqlite3
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


# ---------------------------------------------------------------- dependency stubs
def _mod(name, **attrs):
    m = types.ModuleType(name)
    for k, v in attrs.items():
        setattr(m, k, v)
    sys.modules[name] = m
    return m


class _Dummy:
    def __init__(self, *a, **k):
        pass

    def __call__(self, *a, **k):
        return self

    def __getattr__(self, k):
        return _Dummy()


_mod("uvicorn", run=lambda *a, **k: None)


class FastAPI:
    def __init__(self, *a, **k):
        pass

    def include_router(self, *a, **k):
        pass

    def _deco(self, *a, **k):
        def d(fn):
            return fn
        return d

    get = post = delete = put = _deco


fapi = _mod("fastapi", FastAPI=FastAPI, Request=object, APIRouter=_Dummy, Depends=lambda *a, **k: _Dummy(), HTTPException=_Dummy, status=_Dummy())
_mod("fastapi.security", HTTPBearer=_Dummy, HTTPAuthorizationCredentials=_Dummy)


class _Resp:
    def __init__(self, *a, **k):
        pass


resp = _mod("fastapi.responses", HTMLResponse=_Resp, JSONResponse=_Resp,
            StreamingResponse=_Resp)
fapi.responses = resp

_mod("numpy")
_mod("sklearn")
_mod("sklearn.ensemble", IsolationForest=_Dummy)
_mod("sklearn.preprocessing", StandardScaler=_Dummy, LabelEncoder=_Dummy)
_mod("sklearn.linear_model", LinearRegression=_Dummy, LogisticRegression=_Dummy)
_mod("sklearn.cluster", DBSCAN=_Dummy)
_mod("sklearn.feature_extraction")
_mod("sklearn.feature_extraction.text", TfidfVectorizer=_Dummy)
_mod("sklearn.pipeline", make_pipeline=lambda *a, **k: _Dummy())
_mod("sklearn.model_selection", cross_val_score=lambda *a, **k: [0])

# ---------------------------------------------------------------- temp DB + import
dbfile = tempfile.mktemp(suffix=".db")
open(dbfile, "w").close()
os.environ["FINQ_DB"] = dbfile

sys.path.insert(0, os.path.join(ROOT, "backend"))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "scripts"))

import test_server as tsrv  # noqa: E402

ts = tsrv.ts

# ---------------------------------------------------------------- fixture ledger
ROWS = [
    # 2025 (for the carried-year regression check)
    ("2025-05-20", "Aldi", "Aldi", "Groceries", 10.00, 0),
    # 2026 salary
    ("2026-05-01", "Acme Payroll", "Acme Payroll", "Income", 0, 2000.00),
    ("2026-06-01", "Acme Payroll", "Acme Payroll", "Income", 0, 2000.00),
    ("2026-07-01", "Acme Payroll", "Acme Payroll", "Income", 0, 2000.00),
    # UniBet: 7 x 141 = 987
    ("2026-05-03", "UniBet", "UniBet", "Entertainment", 141.00, 0),
    ("2026-05-17", "UniBet", "UniBet", "Entertainment", 141.00, 0),
    ("2026-06-02", "UniBet", "UniBet", "Entertainment", 141.00, 0),
    ("2026-06-14", "UniBet", "UniBet", "Entertainment", 141.00, 0),
    ("2026-06-28", "UniBet", "UniBet", "Entertainment", 141.00, 0),
    ("2026-07-01", "UniBet", "UniBet", "Entertainment", 141.00, 0),
    ("2026-07-02", "UniBet", "UniBet", "Entertainment", 141.00, 0),
    # Sky monthly bill
    ("2026-05-10", "Sky", "Sky", "Utilities", 40.00, 0),
    ("2026-06-10", "Sky", "Sky", "Utilities", 40.00, 0),
    ("2026-07-10", "Sky", "Sky", "Utilities", 40.00, 0),
    # Aldi + a merchant literally named "Shop" (reproduces the Aldi+Shop hijack)
    ("2026-06-05", "Aldi", "Aldi", "Groceries", 20.00, 0),
    ("2026-07-02", "Aldi", "Aldi", "Groceries", 343.00, 0),
    ("2026-07-03", "Shop", "Shop", "Shopping", 26.97, 0),
    # IKEA on 1 July
    ("2026-07-01", "IKEA", "IKEA", "Shopping", 64.00, 0),
    # Bupa in May + June (NOT on 1 July)
    ("2026-05-15", "Bupa", "Bupa", "Healthcare", 55.50, 0),
    ("2026-06-15", "Bupa", "Bupa", "Healthcare", 55.50, 0),
    # loans + fees (concept-layer targets)
    ("2026-05-06", "Loans 2 Go", "Loans 2 Go", "Investment & Insurance", 280.00, 0),
    ("2026-06-06", "Loans 2 Go", "Loans 2 Go", "Investment & Insurance", 280.00, 0),
    ("2026-07-06", "Loans 2 Go", "Loans 2 Go", "Investment & Insurance", 280.00, 0),
    ("2026-05-20", "YouLend", "YouLend", "Investment & Insurance", 1237.00, 0),
    ("2026-06-20", "YouLend", "YouLend", "Investment & Insurance", 1237.00, 0),
    ("2026-05-04", "Account Fee", "Account Fee", "Investment & Insurance", 5.00, 0),
    ("2026-06-04", "Account Fee", "Account Fee", "Investment & Insurance", 5.00, 0),
    ("2026-07-04", "Account Fee", "Account Fee", "Investment & Insurance", 5.00, 0),
    # flights / coffee (concept aliases) + an ambiguous merchant pair (clarification)
    ("2026-05-22", "Ryanair", "Ryanair", "Transport", 120.00, 0),
    ("2026-06-22", "Ryanair", "Ryanair", "Transport", 80.00, 0),
    ("2026-07-02", "EasyJet", "EasyJet", "Transport", 95.00, 0),
    ("2026-05-12", "Costa Coffee", "Costa Coffee", "Food & Dining", 7.80, 0),
    ("2026-06-09", "Costa Coffee", "Costa Coffee", "Food & Dining", 6.40, 0),
    ("2026-06-10", "Apple Store", "Apple Store", "Shopping", 999.00, 0),
    ("2026-06-11", "Apple Pay", "Apple Pay", "Shopping", 50.00, 0),
]

con = sqlite3.connect(ts.DB_PATH)
for i, (d, descr, m, c, deb, cr) in enumerate(ROWS, 1):
    con.execute(
        "INSERT INTO transactions(user_id,doc_name,txn_date,month,year,month_no,day,"
        "descr,merchant,category,debit,credit,balance,currency,seq)"
        " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        ("local", "statement.pdf", d, d[:7], int(d[:4]), int(d[5:7]), int(d[8:10]),
         descr, m, c, deb, cr, None, "GBP", i))
con.commit()
con.close()
ts.set_currency(ts.detect_currency("local"))

# recurring auto-detector needs sklearn on the real box; stub its output here
tsrv.ml.recurring = lambda user: {
    "items": [{"merchant": "Sky", "cadence": "monthly", "amount": 40.0,
               "count": 3, "confidence": 0.92}],
    "newly_found": []}


# ---------------------------------------------------------------- pipeline replay
def ask(q, ctx):
    """Mimic query()'s deterministic ladder for one turn on one thread."""
    state = tsrv.ConversationState.from_ctx(ctx)
    rinfo = tsrv._resolve_conversation(q, state)
    if rinfo["reset"]:
        ctx.clear()
        return "chat", "(reset)"
    rq = rinfo["resolved"]
    sc = rinfo["scope"]
    state.merchant, state.category = sc.get("merchant", ""), sc.get("category", "")
    state.start, state.end = sc.get("start", ""), sc.get("end", "")
    if sc.get("metric"):
        state.metric = sc["metric"]
    if sc.get("txn_type"):
        state.txn_type = sc["txn_type"]
    if sc.get("comparison"):
        state.comparison = sc["comparison"]
    state.prev_query = q
    state.to_ctx(ctx)

    ians = tsrv.intelligence_answer(rq)
    if ians is not None:
        return "SQL", ians
    if tsrv._ADVICE_RE.search(rq) or tsrv._REASON_RE.search(rq) or tsrv._WHY_RE.search(rq):
        return "advice", "(grounded advice) " + rq
    ca = tsrv.concept_answer(rq)
    if ca is not None:
        return "SQL", ca
    aa = tsrv.analytics_answer(rq)
    if aa is not None:
        return "SQL", aa
    det = tsrv._resolve_factual(rq, ctx)
    if det and det.get("type") == "clarify":
        opts = det.get("options") or []
        return "chat", ("I found %d merchants matching '%s': %s. Which one did you mean?"
                        % (len(opts), det.get("phrase", ""), ", ".join(opts)))
    if det and det.get("type"):
        ans = ts.dispatch_intent(det, "local")
        if ans is not None:
            tsrv._save_ctx(ctx, det)
            return "SQL", ans
    return "chat", "(fell through to LLM router)"


PASS, FAIL = 0, 0


def check(name, got, must=(), must_not=()):
    global PASS, FAIL
    low = got.lower()
    ok = all(s.lower() in low for s in must) and all(s.lower() not in low for s in must_not)
    print(("PASS  " if ok else "FAIL  ") + name)
    print("      -> " + got.replace("\n", " | ")[:180])
    if ok:
        PASS += 1
    else:
        FAIL += 1
        if must:
            print("      must contain: " + repr(must))
        if must_not:
            print("      must NOT contain: " + repr(must_not))


print("\n=== client session (one thread) ===")
ctx = {}
_, a = ask("what is my total spending?", ctx)
check("Q1 total spending", a, must=["Total spending"], must_not=["No transactions"])
_, a = ask("how much did i spent on UniBet", ctx)
check("Q2 UniBet spend", a, must=["UniBet", "987"], must_not=["No transactions"])
_, a = ask("When did I last shop at Aldi?", ctx)
check("Q3 last Aldi visit is a DATE", a, must=["Aldi", "last appears on", "Jul 2026"],
      must_not=["+ Shop"])
_, a = ask("What date did my Sky bill go out?", ctx)
check("Q4 Sky bill dates", a, must=["Sky", "appears on 3 dates"])
_, a = ask("What did I spend at IKEA on 1 July?", ctx)
check("Q5 IKEA on 1 July", a, must=["IKEA", "64"])
_, a = ask("How much was my Bupa payment?", ctx)
check("Q6 Bupa not zeroed by carried day", a, must=["Bupa", "111"],
      must_not=["No transactions"])
_, a = ask("List all my direct debits this month.", ctx)
check("Q7 direct debits -> recurring", a, must=["Recurring", "Sky"], must_not=["Bupa"])
_, a = ask("What bank fees have I been charged this month?", ctx)
check("Q8 bank fees grounded", a, must=["Bank fees in Jul 2026", "5.00"],
      must_not=["Highest-spend month", "Total spending"])

print("\n=== concept / analytics session (one thread, client's 2nd test) ===")
ctx = {}
_, a = ask("How many gambling transactions do I have in June?", ctx)
check("C1 gambling count", a, must=["Gambling transactions in Jun 2026", "3", "UniBet"],
      must_not=["113"])
_, a = ask("What loans am I repaying each month?", ctx)
check("C2 loans list", a, must=["Loan repayments", "Loans 2 Go", "YouLend", "/month"],
      must_not=["Highest-spend month"])
_, a = ask("How much did I spend in total in June?", ctx)
check("C3 total in June", a, must=["Total spending in Jun 2026"])
_, a = ask("How much did I spend on groceries in June?", ctx)
check("C4 groceries in June", a, must=["Groceries in Jun 2026", "20.00"])
_, a = ask("How much have I paid in bank fees over the last three months?", ctx)
check("C5 fees last three months", a, must=["Bank fees", "May 2026", "Jul 2026", "15.00"])
_, a = ask("Did I spend more in May or June?", ctx)
check("C6 May vs June compare", a, must=["May 2026", "Jun 2026", "vs"])
_, a = ask("What percentage of my income goes on loan repayments?", ctx)
check("C7 % of income on loans", a, must=["% of your income", "55.2"],
      must_not=["Total income in May"])
_, a = ask("What recurring payments happen around payday?", ctx)
check("C8 recurring near payday", a, must=["Recurring"])
_, a = ask("Did I pay Bupa this month?", ctx)
check("C9 known biller, empty month, honest", a, must=["No transactions found", "Bupa", "Jul 2026"],
      must_not=["Total spending"])
_, a = ask("Show me all transactions over £100 in June.", ctx)
check("C10 amount filter with £, no zero-result scope leak", a, must=["6 transactions", "100"],
      must_not=["Transactions in Jun 2026: ", "Bupa"])
ctx = {}
_, a = ask("Did I pay Thames Water this month?", ctx)
check("C11 unknown biller honest", a, must=["No transactions found for 'thames water'"],
      must_not=["Total spending"])

print("\n=== regression checks (fresh threads) ===")
ctx = {}
_, a = ask("which month did I spend the most?", ctx)
check("R1 which-month argmax still fires", a, must=["Highest-spend month"])

ctx = {}
_, a = ask("how much did I spend at UniBet?", ctx)
check("R2a UniBet thread", a, must=["UniBet"])
_, a = ask("what about june?", ctx)
check("R2b month follow-up keeps merchant", a, must=["UniBet", "Jun 2026"])

ctx = {}
_, a = ask("how much did I spend in 2025?", ctx)
check("R3a year scope", a, must=["2025"])
_, a = ask("and in may?", ctx)
check("R3b bare month keeps carried YEAR", a, must=["May 2025"], must_not=["May 2026"])

ctx = {}
_, a = ask("how much did i spent on Putney Cricket Club", ctx)
check("R4 unknown merchant is honest", a,
      must=["No transactions found for 'putney cricket club'"],
      must_not=["Total spending"])

ctx = {}
_, a = ask("what dates does Sky appear in june?", ctx)
check("R5 special intent + bare month", a, must=["Sky", "Jun 2026"])

ctx = {}
_, a = ask("how much did I spend at UniBet?", ctx)
_, a = ask("what is my biggest expense?", ctx)
check("R6 standalone question not merchant-pinned (c011bdc)", a, must=["1,237"],
      must_not=["UniBet"])

print("\n=== production-spec additions (aliases / dates / clarify / why) ===")
ctx = {}
_, a = ask("How much did I spend on flights?", ctx)
check("N1 flights concept grounded to airlines", a, must=["Flights", "295.00", "Ryanair"],
      must_not=["No transactions"])
ctx = {}
_, a = ask("How much did I spend eating out?", ctx)
check("N2 eating-out alias -> Food & Dining", a, must=["Food & Dining", "14.20"])
ctx = {}
_, a = ask("How much did I spend on coffee?", ctx)
check("N3 coffee concept", a, must=["Coffee", "14.20", "Costa"])
ctx = {}
_, a = ask("How much did I spend in Q2?", ctx)
check("N4 quarter resolution", a, must=["Apr 2026", "Jun 2026", "5,223.20"])
ctx = {}
_, a = ask("What did I spend today?", ctx)
check("N5 'today' anchored to statement", a, must=["40.00"])
ctx = {}
_, a = ask("How much did I spend yesterday?", ctx)
check("N6 'yesterday' empty is honest", a, must=["No transactions found"])
ctx = {}
_, a = ask("How much did I spend this week?", ctx)
check("N7 'this week' range", a, must=["320.00"])
ctx = {}
_, a = ask("How much did I spend on Apple?", ctx)
check("N8 ambiguous merchant asks clarification", a,
      must=["Which one did you mean", "Apple Store", "Apple Pay"])
_, a = ask("Apple Store", ctx)
check("N8b clarify follow-up resolves", a, must=["Apple Store", "999.00"])
r, a = ask("Why was I charged overdraft fees?", ctx)
check("N9 why-question routes to reasoning", r + " " + a, must=["advice"],
      must_not=["across"])
ctx = {}
_, a = ask("How much did I spend on taxis?", ctx)
check("N10 ungrounded concept honest", a, must=["couldn't find any taxis"])
ctx = {}
_, a = ask("Why do I spend so much in Healthcare?", ctx)
r2, a = ask("Tell me some insights in this category", ctx)
check("H1 'this category' resolves to carried topic", a, must=["Healthcare"])
r3, a = ask("Any solutions to above problems?", ctx)
check("H2 solutions follow-up is advice, not a lookup", r3 + " " + a,
      must=["advice"], must_not=["No transactions"])
sf = tsrv._scoped_facts({"category": "Healthcare", "merchant": ""})
check("H3 scoped advice facts pin the topic", sf,
      must=["CURRENT TOPIC", "Healthcare", "111.00"])
ctx = {}
_, a = ask("How much did I pay to Bupa?", ctx)
check("H4 'pay to <merchant>' still resolves", a, must=["Bupa", "111.00"])
ctx = {}
_, a = ask("Did my utility bills increase?", ctx)
check("N12 named-category trend", a, must=["Utilities increased"])
ctx = {}
_, a = ask("how much did I spend at UniBet?", ctx)
_, a = ask("How much did I spend?", ctx)
check("N11 markerless bare metric is account-wide", a, must=["Total spending"],
      must_not=["UniBet"])
ctx = {}
_, a = ask("how much did I spend at UniBet?", ctx)
_, a = ask("and how much did I spend?", ctx)
check("N11b continuation still inherits scope", a, must=["UniBet"])

print("\n=== broader phrasing sweep (fresh threads) ===")
ctx = {}
_, a = ask("how much did I spend on groceries?", ctx)
check("S1 category via 'on'", a, must=["Groceries", "373"])
ctx = {}
_, a = ask("spending by category", ctx)
check("S2 category table", a, must=["Spending by category", "Entertainment"])
ctx = {}
_, a = ask("top 3 expenses", ctx)
check("S3 top N", a, must=["Top 3 expenses", "999"])
ctx = {}
_, a = ask("how many transactions do I have?", ctx)
check("S4 count", a, must=["Transactions", "35"])
ctx = {}
_, a = ask("how much did I spend on Sky and Aldi together?", ctx)
check("S5 explicit combine still works", a, must=["Aldi + Sky", "493"])
ctx = {}
_, a = ask("compare May and June", ctx)
check("S6 period compare", a, must=["May 2026", "Jun 2026"])
ctx = {}
_, a = ask("biggest expense in June?", ctx)
check("S7 extreme in month", a, must=["Largest expense", "Jun 2026", "1,237"])
ctx = {}
_, a = ask("what did I spend at Aldi in June?", ctx)
check("S8 merchant + month", a, must=["Aldi", "Jun 2026", "20"])
ctx = {}
_, a = ask("when did I visit IKEA?", ctx)
check("S9 date lookup verb", a, must=["IKEA", "01 Jul 2026"])
ctx = {}
_, a = ask("what is my total income?", ctx)
check("S10 income", a, must=["income", "6,000"])
ctx = {}
_, a = ask("under which category does Bupa fall?", ctx)
check("S11 category lookup (c011bdc)", a, must=["Bupa", "Healthcare"])
ctx = {}
_, a = ask("total spending in May 2026", ctx)
check("S12 explicit month-year", a, must=["May 2026", "2,027.30"])
ctx = {}
_, a = ask("how much did I spend in august?", ctx)
check("S13 bare empty month honest (Plaid-commit fix kept)", a,
      must=["No transactions found for Aug"])

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
