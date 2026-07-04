"""Shared offline test scaffolding for Penny's conversation pipeline.

Stubs the heavy deps (fastapi/uvicorn/numpy/sklearn) so test_server imports with
zero installs, seeds a fixture GBP ledger into a temp DB, replays the real
query() cascade for one turn (`ask`), and exposes SQL ground-truth helpers so
tests assert against numbers computed by txn_store itself (a differential, not
brittle hand-typed values).

Used by test_conversations.py (250+ multi-turn tests). The older
test_offline_routing.py stays self-contained.
"""
import os
import sys
import types
import sqlite3
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def _mod(name, **attrs):
    m = types.ModuleType(name)
    for k, v in attrs.items():
        setattr(m, k, v)
    sys.modules[name] = m
    return m


class _Dummy:
    def __init__(self, *a, **k): pass
    def __call__(self, *a, **k): return self
    def __getattr__(self, k): return _Dummy()


_mod("uvicorn", run=lambda *a, **k: None)


class _FastAPI:
    def __init__(self, *a, **k): pass
    def include_router(self, *a, **k): pass
    def _deco(self, *a, **k):
        def d(fn): return fn
        return d
    get = post = delete = put = _deco


_fapi = _mod("fastapi", FastAPI=_FastAPI, Request=object, APIRouter=_Dummy)


class _Resp:
    def __init__(self, *a, **k): pass


_fapi.responses = _mod("fastapi.responses", HTMLResponse=_Resp, JSONResponse=_Resp, StreamingResponse=_Resp)
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

_dbfile = tempfile.mktemp(suffix=".db")
open(_dbfile, "w").close()
os.environ["FINQ_DB"] = _dbfile

sys.path.insert(0, os.path.join(ROOT, "backend"))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "scripts"))

import test_server as tsrv  # noqa: E402
ts = tsrv.ts
USER = "local"

# ------------------------------------------------------------------ fixture ledger
# Rich enough for comparisons / trends / filters: several merchants per category,
# each recurring across May–Jul 2026, a monthly salary, concept targets (gambling /
# loans / fees / flights), an ambiguous pair (Apple Store / Apple Pay), a couple of
# weekend-dated rows, and a 2025 row for carried-year tests.
# (date, descr, merchant, category, debit, credit)
ROWS = [
    ("2025-06-15", "Tesco", "Tesco", "Groceries", 30.00, 0),          # 2025 (carried-year)
    # salary
    ("2026-05-01", "Acme Payroll", "Acme Payroll", "Income", 0, 2400.00),
    ("2026-06-01", "Acme Payroll", "Acme Payroll", "Income", 0, 2400.00),
    ("2026-07-01", "Acme Payroll", "Acme Payroll", "Income", 0, 2400.00),
    # Tesco (Groceries) monthly
    ("2026-05-08", "Tesco", "Tesco", "Groceries", 52.40, 0),
    ("2026-06-08", "Tesco", "Tesco", "Groceries", 61.15, 0),
    ("2026-07-08", "Tesco", "Tesco", "Groceries", 48.90, 0),
    # Aldi (Groceries) monthly, incl. a weekend (2026-05-02 = Saturday) row
    ("2026-05-02", "Aldi", "Aldi", "Groceries", 25.00, 0),
    ("2026-06-06", "Aldi", "Aldi", "Groceries", 20.00, 0),
    ("2026-07-04", "Aldi", "Aldi", "Groceries", 33.00, 0),
    # UniBet (gambling / Entertainment) monthly
    ("2026-05-03", "UniBet", "UniBet", "Entertainment", 141.00, 0),   # 2026-05-03 = Sunday
    ("2026-06-14", "UniBet", "UniBet", "Entertainment", 141.00, 0),
    ("2026-07-02", "UniBet", "UniBet", "Entertainment", 141.00, 0),
    # Bet365 (gambling)
    ("2026-06-20", "Bet365", "Bet365", "Entertainment", 60.00, 0),
    # Netflix (Entertainment) monthly
    ("2026-05-05", "Netflix", "Netflix", "Entertainment", 9.99, 0),
    ("2026-06-05", "Netflix", "Netflix", "Entertainment", 9.99, 0),
    ("2026-07-05", "Netflix", "Netflix", "Entertainment", 9.99, 0),
    # Sky (Utilities) monthly
    ("2026-05-10", "Sky", "Sky", "Utilities", 40.00, 0),
    ("2026-06-10", "Sky", "Sky", "Utilities", 40.00, 0),
    ("2026-07-10", "Sky", "Sky", "Utilities", 45.00, 0),
    # Amazon (Shopping) — a big-ticket July item for extremes/amount-filter
    ("2026-05-18", "Amazon", "Amazon", "Shopping", 120.00, 0),
    ("2026-06-18", "Amazon", "Amazon", "Shopping", 240.00, 0),
    ("2026-07-18", "Amazon", "Amazon", "Shopping", 999.00, 0),
    # IKEA (Shopping) on 1 July (single-day lookups)
    ("2026-07-01", "IKEA", "IKEA", "Shopping", 64.00, 0),
    # Bupa (Healthcare) monthly
    ("2026-05-15", "Bupa", "Bupa", "Healthcare", 55.50, 0),
    ("2026-06-15", "Bupa", "Bupa", "Healthcare", 55.50, 0),
    # loans (Investment & Insurance)
    ("2026-05-06", "Loans 2 Go", "Loans 2 Go", "Investment & Insurance", 280.00, 0),
    ("2026-06-06", "Loans 2 Go", "Loans 2 Go", "Investment & Insurance", 280.00, 0),
    ("2026-07-06", "Loans 2 Go", "Loans 2 Go", "Investment & Insurance", 280.00, 0),
    ("2026-05-20", "YouLend", "YouLend", "Investment & Insurance", 500.00, 0),
    ("2026-06-20", "YouLend", "YouLend", "Investment & Insurance", 500.00, 0),
    # bank fees
    ("2026-05-04", "Account Fee", "Account Fee", "Investment & Insurance", 5.00, 0),
    ("2026-06-04", "Account Fee", "Account Fee", "Investment & Insurance", 5.00, 0),
    ("2026-07-04", "Account Fee", "Account Fee", "Investment & Insurance", 5.00, 0),
    # flights concept
    ("2026-05-22", "Ryanair", "Ryanair", "Transport", 120.00, 0),
    ("2026-06-22", "EasyJet", "EasyJet", "Transport", 95.00, 0),
    # coffee concept
    ("2026-05-12", "Costa Coffee", "Costa Coffee", "Food & Dining", 7.80, 0),
    ("2026-06-09", "Costa Coffee", "Costa Coffee", "Food & Dining", 6.40, 0),
    # ambiguous merchant pair
    ("2026-06-11", "Apple Store", "Apple Store", "Shopping", 799.00, 0),
    ("2026-06-12", "Apple Pay", "Apple Pay", "Shopping", 50.00, 0),
]


def seed():
    con = sqlite3.connect(ts.DB_PATH)
    con.execute("DELETE FROM transactions WHERE user_id=?", (USER,))
    bal = 8000.0
    for i, (d, descr, m, c, deb, cr) in enumerate(ROWS, 1):
        bal = round(bal + cr - deb, 2)
        con.execute(
            "INSERT INTO transactions(user_id,doc_name,txn_date,month,year,month_no,day,"
            "descr,merchant,category,debit,credit,balance,currency,seq)"
            " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (USER, "fixture.pdf", d, d[:7], int(d[:4]), int(d[5:7]), int(d[8:10]),
             descr, m, c, deb, cr, bal, "GBP", i))
    con.commit()
    con.close()
    ts.set_currency(ts.detect_currency(USER))
    tsrv._reset_vocab()
    # deterministic recurring stub (real detector needs sklearn)
    tsrv.ml.recurring = lambda user: {
        "items": [{"merchant": "Netflix", "cadence": "monthly", "amount": 9.99, "count": 3, "confidence": 0.95},
                  {"merchant": "Sky", "cadence": "monthly", "amount": 41.67, "count": 3, "confidence": 0.9}],
        "newly_found": []}


# ------------------------------------------------------------------ pipeline replay
def ask(q, ctx):
    """Replay query()'s deterministic ladder for one turn on thread `ctx`. Returns
    (route, answer_text). Advice route is stubbed (no Ollama) but reports its scope."""
    state = tsrv.ConversationState.from_ctx(ctx)
    rinfo = tsrv._resolve_conversation(q, state)
    if rinfo["reset"]:
        ctx.clear()
        return "reset", tsrv.CONTEXT_RESET_MSG
    rq = rinfo["resolved"]
    sc = rinfo["scope"]
    state.merchant, state.category = sc.get("merchant", ""), sc.get("category", "")
    state.start, state.end = sc.get("start", ""), sc.get("end", "")
    if sc.get("metric"): state.metric = sc["metric"]
    if sc.get("txn_type"): state.txn_type = sc["txn_type"]
    if sc.get("comparison"): state.comparison = sc["comparison"]
    state.prev_query = q
    state.to_ctx(ctx)
    cq = tsrv.build_canonical_query(q, rq, sc, state)

    if ctx and tsrv._FUP_ATTR.search(q) and tsrv._REFS_RE.search(q) \
            and not tsrv._resolve_factual(q, ctx) and not tsrv.analytics_answer(q):
        return "chat", "(followup about previous answer)"
    if tsrv._ANOM_RE.search(rq) or tsrv._FCAST_RE.search(rq) or tsrv._PROJ_RE.search(rq):
        m = tsrv.ml_answer(cq)
        if m is not None: return "ML", m
    ians = tsrv.intelligence_answer(cq)
    if ians is not None: return "SQL", ians
    if tsrv._ADVICE_RE.search(rq) or tsrv._REASON_RE.search(rq) or tsrv._WHY_RE.search(rq):
        # reflect the REAL advice topic pinning (_scoped_facts uses the carried entity)
        return "advice", "(grounded advice) topic=%s|%s period=%s..%s :: %s" % (
            cq.merchant or cq.carried_merchant, cq.category or cq.carried_category,
            cq.start, cq.end, rq)
    ca = tsrv.concept_answer(cq)
    if ca is not None: return "SQL", ca
    aa = tsrv.analytics_answer(cq)
    if aa is not None: return "SQL", aa
    det = tsrv._resolve_factual(rq, ctx)
    if det and det.get("type") == "clarify":
        opts = det.get("options") or []
        return "chat", "I found %d merchants matching '%s': %s. Which one did you mean?" % (
            len(opts), det.get("phrase", ""), ", ".join(opts))
    if det and det.get("type"):
        ans = ts.dispatch_intent(det, USER, cq.doc_name or None)
        if ans is not None:
            tsrv._save_ctx(ctx, det)
            return "SQL", ans
    # gate-3: the deterministic regex fallback the real cascade uses when the LLM router is
    # unavailable (always, offline) — handles summary / coverage / months / balance phrasings.
    ans = ts.answer(rq, USER)
    if ans is not None:
        return "SQL", ans
    return "chat", "(fell through to LLM router)"


# ------------------------------------------------------------------ SQL ground truth
def _period(start="", end=""):
    p, _ = ts._norm_period(start, end)
    return p


def gt_merchant_spend(m, start="", end=""):
    return ts.merchant_spend(USER, m, None, _period(start, end))["debit"]


def gt_category_spend(cat, start="", end=""):
    for c, a, _n in ts.by_category(USER, None, _period(start, end)):
        if c == cat:
            return a
    return 0.0


def gt_total_spend(start="", end=""):
    return ts.overview(USER, None, _period(start, end))["debit"]


def gt_total_income(start="", end=""):
    return ts.overview(USER, None, _period(start, end))["credit"]


def gt_count(start="", end=""):
    return ts.overview(USER, None, _period(start, end))["count"]


def money(x):
    """Format a number the way the answers do, for substring assertions."""
    return ts.inr(x)
