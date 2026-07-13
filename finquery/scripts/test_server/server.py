import sys, os
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "backend")))
import json, os, re, sys, threading, urllib.request, html as _htmlmod
from datetime import datetime, timedelta
from fastapi import FastAPI, Request, Depends, Response
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from starlette.concurrency import run_in_threadpool
from src.services import txn_store as ts
from src.services import ml_insights as ml

from .prompts import ADVICE_SYSTEM, GROUNDED_ADVICE_SYSTEM, ROUTER_SYSTEM
from .ui import PAGE, _DOC_SHELL, LOGIN_PAGE
from .auth import get_current_user, get_user_db_path, router as auth_router, login, signup, _Creds
from .router import (
    _reset_vocab, UPLOAD_DIR, CONVO_RE, _log_conv, HELP_RE, _sub_clarify, _REASON_RE, _PROJ_RE, _FCAST_RE, _clarify_choice, _capabilities, _fmt_date, _FIN_RE, _ANOM_RE, _ADVICE_RE, _WHY_RE,
    _resolve_conversation, ConversationState, _resolve_factual,
    _extract_slots, _save_ctx, _special_factual,
    # Regexes and guards needed by server
    _SPECIAL_INTENTS, _FUP_ATTR, _REFS_RE, _CONT_RE,
    _GUARD_STOP, _log_lock, _SAVINGS_RE, _TABLE_RE, _INCOME_RE, _COUNTQ_RE, _ML_CACHE, CHAT_LOG, _parse_period, _FACTUAL, _DOCS_DIR
)
from .analytics import (
    _ml, months_which_answer,
    analytics_answer, concept_answer, intelligence_answer, ml_answer,
    followup_sql_answer, followup_response, grounded_advice, _llm_complete
)

OLLAMA_URL = os.getenv("OLLAMA_URL", "http://127.0.0.1:11434")
PORT = int(os.getenv("PORT", "5667"))

def _detect_ollama_model():
    import urllib.request
    try:
        req = urllib.request.Request(f"{OLLAMA_URL}/api/tags")
        with urllib.request.urlopen(req, timeout=3) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            models = data.get("models", [])
            if models:
                name = models[0]["name"]
                print(f"[ollama] Detected installed model: {name}")
                return name
    except Exception as e:
        print(f"[ollama] Failed to auto-detect model: {e}")
    return "llama3.1:8b"

LLM_MODEL = os.getenv("LLM_MODEL") or _detect_ollama_model()
os.environ["LLM_MODEL"] = LLM_MODEL
USER = "local"


def active_model():
    """The live model every LLM call should use. Reads os.environ so /models/select can
    switch it at runtime without a server restart (parsers.py already reads it this way)."""
    return os.environ.get("LLM_MODEL") or LLM_MODEL


# Curated models the user can pick + download from the model page. Sizes are approximate.
RECOMMENDED_MODELS = [
    {"id": "llama3.1:8b",       "name": "Llama 3.1 8B",   "size": "4.7 GB", "note": "Best reasoning · recommended"},
    {"id": "qwen2.5:3b",        "name": "Qwen 2.5 3B",    "size": "1.9 GB", "note": "Fast · low memory"},
    {"id": "gemma2:2b",         "name": "Gemma 2 2B",     "size": "1.6 GB", "note": "Lightest · quickest"},
    {"id": "qwen2.5:7b",        "name": "Qwen 2.5 7B",    "size": "4.7 GB", "note": "Strong all-rounder"},
    {"id": "phi3:latest",       "name": "Phi-3 Mini",     "size": "2.2 GB", "note": "Compact · capable"},
    {"id": "llama3.2:3b",       "name": "Llama 3.2 3B",   "size": "2.0 GB", "note": "Balanced small model"},
]

GREETING = ("Hi! I'm **Penny**, your offline statement assistant. "
            "Ask me about totals, categories, merchants, time periods, or for saving advice. "
            "_Type \"help\" to see examples._")

CONTEXT_RESET_MSG = ("Okay — starting fresh. I've cleared the conversation context. "
                     "What would you like to know about your statement?")

DIDNT_CATCH = ("I didn't quite catch that. Ask about totals, categories, merchants, or a time "
                "period — or type help to see examples.")

THREADS = {}
LOG_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "logs")
os.makedirs(LOG_DIR, exist_ok=True)
LOG_FILE = os.path.join(LOG_DIR, "chat_sessions.jsonl")

app = FastAPI(title="Penny Local Server")

# CORS: allow the hosted dashboard front-end to call this API (with the Bearer token).
# Extra origins can be added via the CORS_ORIGINS env var (comma-separated).
_CORS_ORIGINS = [
    "https://workerdashboard1.thescript.design",
    "http://workerdashboard1.thescript.design",
]
_CORS_ORIGINS += [o.strip() for o in os.getenv("CORS_ORIGINS", "").split(",") if o.strip()]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth_router)

from typing import Optional
from pydantic import BaseModel

class _CompatCreds(BaseModel):
    username: Optional[str] = None
    email: Optional[str] = None
    password: str

@app.post("/login")
def login_compat(body: _CompatCreds):
    uname = body.username or body.email or ""
    return login(_Creds(username=uname, password=body.password))

@app.post("/register")
def register_compat(body: _CompatCreds):
    uname = body.username or body.email or ""
    return signup(_Creds(username=uname, password=body.password))

@app.get("/me")
def me_compat(user: str = Depends(get_current_user)):
    return {"username": user}



_DATA_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "data"))
_PINNED_DB = os.path.join(_DATA_DIR, "live_txn.db")
_env_db = os.environ.get("FINQ_DB")
ts.DB_PATH = _env_db if (_env_db and os.path.exists(_env_db)) else _PINNED_DB
print(f"[db] using {ts.DB_PATH}" + ("" if os.path.exists(ts.DB_PATH) else "  (WARNING: not found!)"), flush=True)
ts.init_db()

def _switch_db(user: str):
    """Switch txn_store to this user's personal DB (creates it if needed)."""
    db = get_user_db_path(user)
    ts.DB_PATH = db
    ts.USER = user
    # ts.USER is exposed via a ModuleType-subclass property that proxies dispatcher.USER, BUT the
    # package also bound a module-level name `USER` (`from .dispatcher import ... USER`) whose stale
    # value 'local' shadows the property getter -> ts.USER can read 'local' even after the setter ran.
    # Advice/analytics read ts.USER (the SQL path passes `user` explicitly and is unaffected), so a
    # wrong ts.USER made them query user 'local' -> 0 rows -> "no data". Keep the module-dict copy in
    # sync so every reader of ts.USER agrees with the request's user.
    ts.__dict__["USER"] = user
    from . import router
    router.USER = user
    ts.init_db()

def _thread(tid):
    # Rehydrate from the persisted log on a cold thread so context (slot memory +
    # recent history) survives a server restart, not just an in-process session.
    if tid not in THREADS:
        THREADS[tid] = _rehydrate(tid)
    return THREADS[tid]

def _now():
    return datetime.now().isoformat(timespec="seconds")

def _append_log(thread, question, answer, route):
    """Append one Q&A turn to data/chats.json (atomic rewrite, thread-keyed)."""
    if not (question or "").strip():
        return
    ts_now = _now()
    with _log_lock:
        try:
            with open(CHAT_LOG, encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            data = {}
        conv = data.setdefault(thread, {"created": ts_now, "messages": []})
        conv["messages"].append({"ts": ts_now, "question": question,
                                 "answer": " ".join((answer or "").split()), "route": route})
        conv["updated"] = ts_now
        # Snapshot the live in-memory state (slot ctx + recent history) so a restart
        # can rehydrate it. This is what keeps follow-up context across restarts.
        st = THREADS.get(thread)
        if st is not None:
            c = st.setdefault("ctx", {})
            c["prev_route"] = route
            c["prev_answer"] = " ".join((answer or "").split())[:200]
            conv["state"] = {"ctx": c, "history": st.get("history", [])}
        try:
            os.makedirs(os.path.dirname(CHAT_LOG), exist_ok=True)
            tmp = CHAT_LOG + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
            os.replace(tmp, CHAT_LOG)
        except Exception as e:
            print(f"[chatlog] write failed: {e}")

def _rehydrate(tid):
    """Rebuild a thread's in-memory state from the persisted chat log so context
    (slot ctx + recent history) survives a server restart. Empty on any miss/error."""
    try:
        with open(CHAT_LOG, encoding="utf-8") as f:
            st = json.load(f).get(tid, {}).get("state")
        if isinstance(st, dict):
            return {"ctx": dict(st.get("ctx") or {}),
                    "history": list(st.get("history") or [])[-6:]}
    except Exception:
        pass
    return {"ctx": {}, "history": []}

def _txt(nd_line):
    """Extract the text content from one ndjson stream line ('' if not a chunk)."""
    try:
        o = json.loads(nd_line)
        return o.get("content", "") if o.get("type") == "chunk" else ""
    except Exception:
        return ""

def remember(history, q, a):
    history.append({"q": q, "a": " ".join(a.split())[:300]})
    del history[:-6]

def llm_route(question, history=None):
    """Ask the local LLM to classify the question into a structured intent (JSON).
    Recent thread history is supplied so elliptical follow-ups resolve.
    Returns a dict, or None if the LLM is unavailable / output unparseable."""
    user = question
    history = history or []
    # context = the last couple of REAL exchanges (skip placeholder answers like
    # "(answered from conversation)") so elliptical follow-ups reuse the right intent.
    real = [h for h in history if not h["a"].startswith("(")][-5:]
    if real:
        ctx = "\n".join(f"Q: {h['q']}\nA: {h['a']}" for h in real)
        user = f"[Recent conversation:\n{ctx}]\n\nNew message: {question}"
    payload = json.dumps({
        "model": active_model(), "stream": False, "keep_alive": "10m", "format": "json",
        "options": {"temperature": 0, "num_ctx": 2048, "num_predict": 160},
        "messages": [
            {"role": "system", "content": ROUTER_SYSTEM},
            {"role": "user", "content": user},
        ],
    }).encode()
    try:
        req = urllib.request.Request(f"{OLLAMA_URL}/api/chat", data=payload,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            content = json.loads(resp.read()).get("message", {}).get("content", "")
        return json.loads(content)
    except Exception as e:
        print(f"[router] LLM unavailable: {e}")
        return None

@app.get("/favicon.ico", include_in_schema=False)
async def favicon():
    return Response(status_code=204)

FRONTEND_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "frontend", "dist"))
ASSETS_DIR = os.path.join(FRONTEND_DIR, "assets")

if os.path.exists(ASSETS_DIR):
    app.mount("/assets", StaticFiles(directory=ASSETS_DIR), name="assets")

def serve_index():
    index_path = os.path.join(FRONTEND_DIR, "index.html")
    if os.path.exists(index_path):
        try:
            with open(index_path, "r", encoding="utf-8") as f:
                return HTMLResponse(f.read())
        except Exception as e:
            print(f"[server] Error reading index.html: {e}")
    return HTMLResponse(PAGE.replace("__MODEL__", LLM_MODEL))

@app.get("/", response_class=HTMLResponse)
async def index():
    return serve_index()

@app.get("/app", response_class=HTMLResponse)
async def app_page():
    return serve_index()

@app.get("/login", response_class=HTMLResponse)
async def login_page_route():
    return serve_index()

@app.get("/register", response_class=HTMLResponse)
async def register_page_route():
    return serve_index()

@app.get("/models", response_class=HTMLResponse)
async def models_page_route():
    return serve_index()          # the React model-picker SPA route (API lives at /api/models)

@app.get("/classic", response_class=HTMLResponse)
async def classic_page():
    """The original single-file Penny parser UI (drag-drop parse + transaction
    table + chat) from ui.py. Kept reachable here even when the React build is
    served at /. Talks to this same server's API."""
    return HTMLResponse(PAGE.replace("__MODEL__", LLM_MODEL))


def _get_active_doc(thread: str = "default"):
    st = THREADS.get(thread)
    if st:
        return st["ctx"].get("default_doc_name")
    return None

@app.get("/status")
async def status(request: Request, user: str = Depends(get_current_user)):
    """Lets the page detect data already in the DB on load (so the input works
    without re-uploading after a refresh/restart)."""
    _switch_db(user)
    tid = request.query_params.get("thread", "default")
    doc_name = _get_active_doc(tid)
    o = ts.overview(user, doc_name)
    return JSONResponse({"rows": o["count"], "spend": ts.inr(o["debit"]),
                         "income": ts.inr(o["credit"]), "model": active_model(),
                         "currency": ts.CURRENCY})


def _installed_models():
    """Names of models already pulled into the local Ollama."""
    try:
        req = urllib.request.Request(f"{OLLAMA_URL}/api/tags")
        with urllib.request.urlopen(req, timeout=4) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return [m["name"] for m in data.get("models", [])]
    except Exception as e:
        print(f"[models] Ollama tags failed: {e}")
        return []


@app.get("/api/models")
async def list_models(user: str = Depends(get_current_user)):
    """Model picker data: which model is active, which are already downloaded, and the
    curated list a user can download to power the assistant."""
    installed = _installed_models()
    inst_set = {n.split(":")[0]: n for n in installed}  # base-name -> full tag, loose match
    recs = []
    for m in RECOMMENDED_MODELS:
        is_inst = m["id"] in installed or m["id"].split(":")[0] in inst_set
        recs.append({**m, "installed": is_inst})
    return JSONResponse({"active": active_model(), "installed": installed, "recommended": recs})


@app.post("/api/models/select")
async def select_model(request: Request, user: str = Depends(get_current_user)):
    """Switch the live model. Must already be downloaded (see /models/pull)."""
    body = await request.json()
    name = (body.get("name") or "").strip()
    if not name:
        return JSONResponse({"error": "No model name given."}, status_code=400)
    if name not in _installed_models():
        return JSONResponse({"error": f"'{name}' isn't downloaded yet. Download it first."},
                            status_code=409)
    os.environ["LLM_MODEL"] = name           # every LLM call reads this (active_model / os.getenv)
    print(f"[models] active model -> {name}", flush=True)
    return JSONResponse({"active": name})


@app.post("/api/models/pull")
async def pull_model(request: Request, user: str = Depends(get_current_user)):
    """Download a model into the local Ollama, streaming progress (one JSON object per line)
    straight from Ollama's /api/pull so the UI can show a progress bar."""
    body = await request.json()
    name = (body.get("name") or "").strip()
    if not name:
        return JSONResponse({"error": "No model name given."}, status_code=400)

    def stream():
        payload = json.dumps({"name": name, "stream": True}).encode()
        try:
            req = urllib.request.Request(f"{OLLAMA_URL}/api/pull", data=payload,
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=3600) as resp:
                for raw in resp:
                    line = raw.decode("utf-8", "replace").strip()
                    if line:
                        yield line + "\n"
        except Exception as e:
            yield json.dumps({"status": "error", "error": str(e)}) + "\n"

    return StreamingResponse(stream(), media_type="application/x-ndjson")


@app.get("/dashboard")
async def dashboard(request: Request, user: str = Depends(get_current_user)):
    """Structured figures for the Penny Today / Patterns / Bills views.
    Amounts are signed: spend negative, income positive (the UI styles by sign).
    Every number is straight from SQL."""
    _switch_db(user)
    tid = request.query_params.get("thread", "default")
    doc_name = _get_active_doc(tid)
    o = ts.overview(user, doc_name)
    if o["count"] == 0:
        return JSONResponse({"ready": False})
    con = ts.connect()
    from src.services.txn_store.queries import _scope
    w, params = _scope(user, doc_name)
    cats = [{"name": r[0], "amount": r[1], "count": r[2]} for r in con.execute(
        f"SELECT category,SUM(debit),COUNT(*) FROM transactions "
        f"WHERE {w} AND debit>0 GROUP BY category ORDER BY 2 DESC", params)]
    months = [{"ym": r[0], "spending": r[1], "income": r[2]} for r in con.execute(
        f"SELECT month,SUM(debit),SUM(credit) FROM transactions "
        f"WHERE {w} GROUP BY month ORDER BY month", params)]
    recent = [{"date": _fmt_date(r[0]), "payee": r[1], "category": r[2],
               "amount": (r[4] - r[3])} for r in con.execute(
        f"SELECT txn_date,merchant,category,debit,credit FROM transactions "
        f"WHERE {w} ORDER BY seq DESC LIMIT 12", params)]
    lg = con.execute(f"SELECT txn_date,merchant,debit FROM transactions "
                     f"WHERE {w} AND debit>0 ORDER BY debit DESC LIMIT 1", params).fetchone()
    largest = {"date": _fmt_date(lg[0]), "payee": lg[1], "amount": lg[2]} if lg else None
    payees = [{"name": r[0], "amount": r[1]} for r in con.execute(
        f"SELECT merchant,SUM(debit) FROM transactions WHERE {w} AND debit>0 "
        f"GROUP BY merchant ORDER BY 2 DESC LIMIT 6", params)]
    subs = []
    subset = sorted(ts.SUBSCRIPTION_MERCHANTS)
    if subset:
        qs = ",".join("?" * len(subset))
        for r in con.execute(
            f"SELECT merchant,COUNT(*),SUM(debit),MAX(txn_date) FROM transactions "
            f"WHERE {w} AND debit>0 AND merchant IN ({qs}) "
            f"GROUP BY merchant ORDER BY 3 DESC", (*params, *subset)):
            subs.append({"name": r[0], "count": r[1], "total": r[2], "last": _fmt_date(r[3])})
    con.close()
    return JSONResponse({
        "ready": True, "currency": ts.CURRENCY,
        "totals": {"spending": o["debit"], "income": o["credit"],
                   "net": o["credit"] - o["debit"], "count": o["count"]},
        "balance": ts.latest_balance(user, doc_name),
        "categories": cats, "months": months, "recent": recent,
        "largest": largest, "topPayees": payees, "subscriptions": subs,
    })

@app.get("/transactions")
async def transactions(request: Request, offset: int = 0, limit: int = 50, q: str = "",
                       start: str = "", end: str = "", minamt: float = 0.0,
                       maxamt: float = 0.0, dir: str = "",
                       user: str = Depends(get_current_user)):
    """Paged + filtered raw transactions for the search-table view: keyword (q),
    date range (start/end as YYYY-MM-DD), amount band (minamt/maxamt on the txn size),
    and direction (dir = 'in' | 'out')."""
    _switch_db(user)
    con = ts.connect()
    tid = request.query_params.get("thread", "default")
    doc_name = _get_active_doc(tid)
    from src.services.txn_store.queries import _scope
    # FIX: Jab koi active doc nahi (thread naya hai ya server restart hua),
    # toh currency filter bypass karo aur sab user ki transactions dikhao.
    # doc_name=None hone par _scope currency filter lagata tha jo multi-bank users
    # ke liye sirf ek currency ka data dikha raha tha.
    if doc_name is None:
        where = "user_id=?"
        params = [user]
    else:
        where, params = _scope(user, doc_name)
    if q:
        where += " AND (LOWER(merchant) LIKE ? OR LOWER(descr) LIKE ? OR LOWER(category) LIKE ?)"
        like = f"%{q.lower()}%"; params += [like, like, like]
    if start:
        where += " AND txn_date >= ?"; params.append(start)
    if end:
        where += " AND txn_date <= ?"; params.append(end)
    amt = "(CASE WHEN debit>0 THEN debit ELSE credit END)"
    if minamt:
        where += f" AND {amt} >= ?"; params.append(minamt)
    if maxamt:
        where += f" AND {amt} <= ?"; params.append(maxamt)
    if dir == "out":
        where += " AND debit>0"
    elif dir == "in":
        where += " AND credit>0"
    total = con.execute(f"SELECT COUNT(*) FROM transactions WHERE {where}", params).fetchone()[0]
    s = con.execute(f"SELECT COALESCE(SUM(debit),0),COALESCE(SUM(credit),0) FROM transactions WHERE {where}",
                    params).fetchone()
    rows = [{"date": _fmt_date(r[0]), "payee": r[1], "category": r[2],
             "out": ts.inr(r[3]) if r[3] else "", "in": ts.inr(r[4]) if r[4] else "",
             "balance": ts.inr(r[5]) if r[5] is not None else "", "descr": r[6],
             "description": ts.clean_description(r[6], r[1]), "bank": r[7] or ""} for r in con.execute(
        f"SELECT txn_date,merchant,category,debit,credit,balance,descr,bank_name FROM transactions WHERE {where} "
        f"ORDER BY txn_date DESC, seq DESC LIMIT ? OFFSET ?", params + [limit, offset])]
    con.close()
    return JSONResponse({"rows": rows, "total": total,
                         "out_total": ts.inr(s[0]), "in_total": ts.inr(s[1])})

@app.get("/ml/anomalies")
async def ml_anomalies(user: str = Depends(get_current_user)):
    _switch_db(user)
    return JSONResponse(_ml("anom", lambda: ml.anomalies(user)))

@app.get("/ml/forecast")
async def ml_forecast(user: str = Depends(get_current_user)):
    _switch_db(user)
    return JSONResponse(_ml("fc", lambda: ml.forecast(user)))

@app.get("/ml/recurring")
async def ml_recurring(user: str = Depends(get_current_user)):
    _switch_db(user)
    return JSONResponse(_ml("rec", lambda: ml.recurring(user)))

@app.get("/ml/categorize")
async def ml_categorize(user: str = Depends(get_current_user)):
    _switch_db(user)
    return JSONResponse(_ml("cat", lambda: ml.categorizer_report(user)))

@app.get("/documents")
async def get_documents(request: Request, user: str = Depends(get_current_user)):
    _switch_db(user)
    tid = (request.query_params.get("thread") or "default")
    from src.services.txn_store.queries import list_user_documents
    docs = list_user_documents(user)
    st = _thread(tid)
    active_doc = st["ctx"].get("default_doc_name")
    return JSONResponse({
        "documents": docs,
        "active_doc_name": active_doc
    })

@app.post("/chat/select_bank")
async def select_bank(request: Request, user: str = Depends(get_current_user)):
    _switch_db(user)
    body = await request.json()
    tid = (body.get("thread") or "default")
    doc_name = body.get("doc_name")
    st = _thread(tid)
    ctx = st["ctx"]
    
    current_docs = ctx.get("default_doc_name")
    if isinstance(current_docs, list):
        docs_list = list(current_docs)
    elif isinstance(current_docs, str):
        docs_list = [current_docs]
    else:
        docs_list = []

    if doc_name:
        if doc_name in docs_list:
            docs_list.remove(doc_name)
        else:
            docs_list.append(doc_name)

    if docs_list:
        ctx["default_doc_name"] = docs_list
        ctx["pinned_doc_name"] = docs_list
    else:
        ctx["default_doc_name"] = None
        ctx.pop("pinned_doc_name", None)
        
    return JSONResponse({"status": "ok", "active_doc_name": ctx["default_doc_name"]})

@app.delete("/document")
async def delete_document(request: Request, user: str = Depends(get_current_user)):
    """Delete a specific statement (doc_name) from the database.
    Removes all transactions + metadata for that document.
    Also removes it from the active session context if it was selected."""
    _switch_db(user)
    body = await request.json()
    doc_name = (body.get("doc_name") or "").strip()
    tid = (body.get("thread") or "default")

    if not doc_name:
        return JSONResponse({"error": "doc_name required"}, status_code=400)

    con = ts.connect()
    # DB se transactions aur metadata dono delete karo
    txn_count = con.execute(
        "SELECT COUNT(*) FROM transactions WHERE user_id=? AND doc_name=?",
        (user, doc_name)
    ).fetchone()[0]
    con.execute("DELETE FROM transactions WHERE user_id=? AND doc_name=?", (user, doc_name))
    con.execute("DELETE FROM document_metadata WHERE user_id=? AND doc_name=?", (user, doc_name))
    con.commit()
    con.close()

    # Session context se bhi remove karo agar active tha
    if tid in THREADS:
        ctx = THREADS[tid]["ctx"]
        current = ctx.get("default_doc_name")
        if isinstance(current, list) and doc_name in current:
            current.remove(doc_name)
            ctx["default_doc_name"] = current if current else None
            ctx["pinned_doc_name"] = ctx["default_doc_name"]
        elif current == doc_name:
            ctx["default_doc_name"] = None
            ctx.pop("pinned_doc_name", None)

    print(f"[delete] Deleted '{doc_name}' for user '{user}' ({txn_count} transactions removed)", flush=True)
    return JSONResponse({
        "status": "ok",
        "deleted": doc_name,
        "txns_removed": txn_count
    })



@app.get("/insights")
async def insights_endpoint(user: str = Depends(get_current_user)):
    """Pre-computed Insight Engine output (stored on upload; live-computed if absent)."""
    _switch_db(user)
    items = ts.get_insights(user) or ts.compute_insights(user)
    return JSONResponse({
        "insights": items,
        "health": ts.health_score(user),
        "risk": ts.risk_assessment(user),
    })

_UPLOAD_LOCK = threading.Lock()


def _upload_worker(user, name, data, is_zip):
    """Blocking upload pipeline (unzip -> statement-detect -> parse/ingest -> insights). Runs in a
    worker THREAD (via run_in_threadpool) so a slow parse -- especially the LLM parser cascade,
    which makes 60-90s blocking calls per chunk on a big/unknown PDF -- never blocks the event loop.
    Before this, a single large upload froze the whole server (even /app). Serialized by _UPLOAD_LOCK
    so overlapping uploads can't clobber the shared txn_store globals mid-parse.
    Returns (status_code, payload_dict)."""
    import time, zipfile, tempfile, shutil
    with _UPLOAD_LOCK:
        _switch_db(user)                 # pin this user's DB right before ingest opens its connection
        t0 = time.time()
        pdfs, workdir = [], None         # (path, label) candidates
        try:
            if is_zip:
                workdir = tempfile.mkdtemp(prefix="penny_zip_")
                zpath = os.path.join(workdir, "u.zip")
                with open(zpath, "wb") as f:
                    f.write(data)
                try:
                    with zipfile.ZipFile(zpath) as z:
                        for info in z.infolist():
                            fn = info.filename
                            if info.is_dir() or fn.startswith("__MACOSX") or not fn.lower().endswith(".pdf"):
                                continue
                            out = os.path.join(workdir, f"{len(pdfs):02d}_{os.path.basename(fn)}")
                            with z.open(info) as src, open(out, "wb") as dst:
                                dst.write(src.read())
                            pdfs.append((out, os.path.basename(fn)))
                except zipfile.BadZipFile:
                    return 400, {"error": "That file isn't a valid ZIP archive."}
                if not pdfs:
                    return 422, {"error": "No PDF files were found inside the ZIP."}
            else:
                out = os.path.join(UPLOAD_DIR, os.path.basename(name) or "statement.pdf")
                with open(out, "wb") as f:
                    f.write(data)
                pdfs.append((out, os.path.basename(name) or "statement.pdf"))

            # keep only the PDFs that actually look like bank statements
            statements = [(p, lbl) for p, lbl in pdfs if ts.is_statement_pdf(p)]
            if not statements:
                msg = (f"No bank statement found in the ZIP (scanned {len(pdfs)} PDF"
                       f"{'s' if len(pdfs) != 1 else ''})." if is_zip
                       else "That PDF doesn't look like a bank statement.")
                return 422, {"error": msg, "scanned": len(pdfs)}

            # multi-document support: do not delete prior transactions globally.
            # ingest_pdf deletes only rows matching the same document name. Clear this user's threads.
            for k in list(THREADS.keys()):
                if k.startswith(user + ":"):
                    del THREADS[k]
            _switch_db(user)             # re-pin: statement-detection above doesn't touch the DB, but a
                                         # concurrent query could have flipped the global db path meanwhile
            total, parsed = 0, []
            rec_pass = rec_check = 0
            for p, lbl in statements:
                n = ts.ingest_file(p, lbl, user)
                rr = ts.reconciliation_rate(user, lbl)           # parse quality: % of rows that tie out
                rec_pass += rr["checked"] - rr["breaks"]; rec_check += rr["checked"]
                total += n
                parsed.append({"file": lbl, "rows": n, "parse_percent": rr["percent"]})
        finally:
            if workdir:
                shutil.rmtree(workdir, ignore_errors=True)

        dt = time.time() - t0
        ts.set_currency(ts.detect_currency(user))    # display currency follows the data
        _reset_vocab()                               # merchant/category vocab follows it too
        ov = ts.overview(user)
        try:
            ts.save_insights(user, ts.compute_insights(user))
        except Exception as e:
            print("[insights] compute on upload failed:", e, flush=True)
        return 200, {
            "filename": (parsed[0]["file"] if len(parsed) == 1
                         else f"{len(parsed)} statements from {name}"),
            "parsed": parsed, "rows": total, "seconds": round(dt, 2), "currency": ts.CURRENCY,
            "spend": ts.inr(ov["debit"]), "income": ts.inr(ov["credit"]),
            "parse_percent": round(100.0 * rec_pass / rec_check, 1) if rec_check else None,
        }


@app.post("/upload")
async def upload(request: Request, user: str = Depends(get_current_user)):
    """Accept a statement PDF **or a ZIP**. The heavy parse/ingest runs in a worker thread so a
    large or LLM-parsed document can't freeze the event loop (the server stays responsive)."""
    name = request.query_params.get("name", "upload")
    data = await request.body()
    is_zip = data[:2] == b"PK" or name.lower().endswith(".zip")
    status, payload = await run_in_threadpool(_upload_worker, user, name, data, is_zip)
    return JSONResponse(payload, status_code=status)

def _apply_guards(intent, q):
    """Override the LLM where regex is more reliable: period parsing, the
    income/count keywords it flubs, and whether a table was actually asked for.
    Category / merchant / extremes are left to the (now-fixed) LLM."""
    low = q.lower()
    # Clean up the merchant name if the LLM flubbed it and extracted a stopword or prepositional phrase
    mer = intent.get("merchant", "")
    if mer:
        mer_low = mer.lower().strip()
        first_tok = mer_low.split()[0] if mer_low else ""
        if first_tok in _GUARD_STOP or mer_low in _GUARD_STOP:
            intent["merchant"] = ""
            if intent.get("type") == "merchant":
                if _COUNTQ_RE.search(q) or re.search(r"\bhow much time\b", low):
                    intent["type"] = "count"
                elif _INCOME_RE.search(q):
                    intent["type"] = "income"
                else:
                    intent["type"] = "spend"

    det = _parse_period(q)
    if det:
        intent["start"], intent["end"] = det
    # savings / net-position phrasings are the account summary (the Net row), never a spend
    # total  -  the LLM sometimes flips "total savings" to "spend". Savings RATE/target are the
    # intelligence gate's job and are handled before this point, so they never reach here.
    if _SAVINGS_RE.search(low):
        intent["type"] = "summary"
        return intent
    # single biggest/smallest expense  -  the keyword decides direction (the LLM flips
    # "smallest in 2024" to largest). Skip when it's a top-N list.
    if "expense" in low and "top" not in low:
        if re.search(r"\b(smallest|lowest|cheapest|minimum)\b", low):
            intent["type"] = "smallest_expense"
        elif re.search(r"\b(biggest|largest|highest|maximum)\b", low):
            intent["type"] = "largest_expense"
    t = (intent.get("type") or "").lower()
    # an explicit date in the text means it's NOT an elliptical follow-up
    if t in ("followup", "unknown") and det:
        if _COUNTQ_RE.search(q):
            t = "count"
        elif _INCOME_RE.search(q):
            t = "income"
        elif re.search(r"\b(spend|spent|spending)\b|how much", low):
            t = "spend"
        intent["type"] = t
    if t not in _FACTUAL:
        return intent

    wants_table = bool(_TABLE_RE.search(q))
    has_cat = bool(re.search(r"\b(groceries|grocery|food|dining|transport|shopping|"
                             r"utilit|entertainment|health|investment|insurance)\b", low))
    has_merch = bool(re.search(r"\bat\s+[a-z0-9]", low))   # "spend at <merchant>"
    # only re-derive the metric for the total-style intents; leave category/merchant/balance
    if t in ("spend", "summary", "income", "count", "breakdown"):
        if _INCOME_RE.search(q) and not _COUNTQ_RE.search(q):
            t = "income"
        elif _COUNTQ_RE.search(q):
            t = "count"
        elif re.search(r"how much.*(spend|spent|spending)|total spend", low) and not has_cat and not has_merch:
            t = "spend"                       # clear "how much did I spend"  -  not count/breakdown
        elif t == "breakdown" and not wants_table:
            t = "spend"                       # a range/period TOTAL, not a monthly table
    intent["type"] = t
    if t in ("count", "spend", "income"):
        intent["table"] = wants_table         # per-month table only when explicitly asked
    return intent

def _nd(obj):
    return json.dumps(obj) + "\n"

def stream_markdown(text):
    """Yield ndjson chunks: prose word-by-word, but each markdown table as ONE
    whole block (so it never renders half-built)."""
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        if lines[i].lstrip().startswith("|"):
            j = i
            while j < len(lines) and lines[j].lstrip().startswith("|"):
                j += 1
            yield _nd({"type": "chunk", "content": "\n".join(lines[i:j]) + "\n"})
            i = j
        else:
            for w in lines[i].split(" "):
                yield _nd({"type": "chunk", "content": w + " "})
            yield _nd({"type": "chunk", "content": "\n"})
            i += 1

def stream_text(path, text):
    def gen():
        yield _nd({"type": "meta", "path": path})
        yield from stream_markdown(text)
        yield _nd({"type": "done"})
    return StreamingResponse(gen(), media_type="application/x-ndjson")

@app.get("/chats")
async def chats():
    """Return all saved chat threads from data/chats.json."""
    try:
        with open(CHAT_LOG, encoding="utf-8") as f:
            return JSONResponse(json.load(f))
    except Exception:
        return JSONResponse({})

def is_followup_query(q):
    low = q.lower().strip()
    if len(low.split()) <= 3:
        return True
    if any(low.startswith(w) for w in ("show", "give", "list", "why", "what about", "and ", "how about", "explain", "detail", "tell")):
        return True
    if any(re.search(rf"\b{w}\b", low) for w in ("it", "them", "that", "this", "those", "list", "category", "details", "name", "names", "merchant", "merchants", "categories")):
        return True
    return False

# Generic bank / entity / ultra-common words that must NOT, on their own, pin a query to a
# specific bank. Without this filter the old `bank[:4] in low` prefix-substring wrongly fired:
# "State Bank of India"[:4]="stat" matched the word "statement"; "Bank of Baroda"[:4]="bank"
# matched any query that merely mentioned a bank.
_BANK_STOPWORDS = {
    "bank", "banking", "of", "the", "and", "co", "ltd", "limited", "pvt", "private",
    "corporation", "corp", "company", "account", "statement", "india", "national",
    "plc", "group", "financial", "finance", "inc", "credit", "cooperative",
    "yes", "no", "new", "all", "for", "how", "what", "show", "my",
}

def _bank_tokens(name):
    """Distinctive whole-word tokens of a bank/document name, for matching it inside a query:
    alphanumeric words >= 3 chars that aren't generic banking or ultra-common English words.
    'State Bank of India' -> {'state'}, 'Bank of Baroda' -> {'baroda'}, 'HDFC Bank' -> {'hdfc'}."""
    return {w for w in re.findall(r"[a-z0-9]+", (name or "").lower())
            if w not in _BANK_STOPWORDS and len(w) >= 3}


def needs_bank_clarification(user_id, q, ctx):
    low = q.lower()
    from src.services.txn_store.queries import list_user_documents, overall_balance, latest_balance

    docs = list_user_documents(user_id)
    if len(docs) <= 1:
        return None, None

    # Check if query names a bank explicitly: a full bank-name mention, or any DISTINCTIVE
    # token (from the bank name or the file name) matched as a WHOLE WORD. Whole-word matching
    # is what stops "statement" from selecting "State Bank of India".
    matched_doc = None
    for d in docs:
        bank = d["bank_name"].lower()
        doc_base = os.path.splitext(d["doc_name"].lower())[0]
        tokens = _bank_tokens(bank) | _bank_tokens(doc_base)
        if (bank and bank in low) or any(re.search(rf"\b{re.escape(t)}\b", low) for t in tokens):
            matched_doc = d["doc_name"]
            break
            
    if matched_doc:
        return matched_doc, None
        
    # Check for combine-keywords with word boundaries
    if any(re.search(rf"\b{w}\b", low) for w in ("overall", "combined", "all accounts", "all banks", "everything", "across all", "sum of all")):
        return None, None
        
    # Check for smalltalk / help / system keywords with word boundaries
    if any(re.search(rf"\b{w}\b", low) for w in ("help", "hi", "hello", "hey", "who are you", "what can you do", "reset", "clear", "logout", "sign out")):
        return None, None
        
    # Check in-session default
    active = ctx.get("default_doc_name")
    if active:
        if isinstance(active, list):
            doc_names = {d["doc_name"] for d in docs}
            if all(name in doc_names for name in active):
                return active, None
        else:
            if any(d["doc_name"] == active for d in docs):
                return active, None
            
    # Ambiguous! Build clarification payload
    options = []
    for d in docs:
        bal = latest_balance(user_id, d["doc_name"])
        curr = d["currency"]
        bal_str = f"{curr} {bal:,.2f}" if bal is not None else "no transactions"
        date_range = f"{d['from_date']} to {d['to_date']}" if d["from_date"] else "empty"
        
        options.append({
            "id": f"doc:{d['doc_name']}",
            "label": d["bank_name"],
            "sublabel": f"{date_range} · balance: {bal_str}",
            "doc_name": d["doc_name"]
        })
        
    ob = overall_balance(user_id)
    overall_sub = "Total across every bank"
    if ob["mixed_currency"]:
        overall_sub = "Note: accounts use different currencies — shown separately"
        
    options.append({
        "id": "overall",
        "label": "All accounts combined",
        "sublabel": overall_sub,
        "doc_name": None
    })
    
    payload = {
        "type": "clarification_needed",
        "clarification_kind": "bank_selection",
        "question": "You have statements from multiple banks. Which one would you like?",
        "options": options,
        "original_query": q
    }
    return None, payload

@app.post("/query")
@app.post("/query/stream")
async def query(request: Request, user: str = Depends(get_current_user)):
    _switch_db(user)
    body = await request.json()
    q = (body.get("question") or "").strip()
    # Chat-thread model: state is scoped to a thread id from the client. "reset"
    # (New chat) starts the thread fresh. No thread id -> a single default thread.
    tid = (body.get("thread") or "default")
    if body.get("reset"):
        THREADS[tid] = {"ctx": {}, "history": []}
    st = _thread(tid)
    ctx, history = st["ctx"], st["history"]

    if not q:
        return stream_text("chat", GREETING)
    if ts.overview(user)["count"] == 0:
        return stream_text("chat", "_Upload a statement first._")

    # ---- AMBIGUITY / CLARIFICATION RESOLUTION ----
    from src.services.txn_store import queries
    resolved_doc_name = None
    if "document_names" in body:
        doc_names = body.get("document_names")
        if isinstance(doc_names, list):
            flat = []
            for item in doc_names:
                if isinstance(item, list):
                    flat.extend(item)
                else:
                    flat.append(item)
            resolved_doc_name = [d for d in flat if d]
            if len(resolved_doc_name) == 0:
                resolved_doc_name = None
        else:
            resolved_doc_name = doc_names
    elif body.get("clarification_response"):
        selected_ids = body.get("selected_ids") or []
        if "overall" in selected_ids:
            resolved_doc_name = None
        else:
            resolved_doc_name = [sid[4:] for sid in selected_ids if sid.startswith("doc:")]
            if len(resolved_doc_name) == 1:
                resolved_doc_name = resolved_doc_name[0]
            elif len(resolved_doc_name) == 0:
                resolved_doc_name = None
        if ctx.get("default_doc_name") != resolved_doc_name:
            for k in ("start", "end", "merchant", "category", "metric", "txn_type", "comparison"):
                ctx.pop(k, None)
        ctx["default_doc_name"] = resolved_doc_name
    else:
        # Clear filters and transient defaults for new standalone questions to prevent context pollution
        if not is_followup_query(q):
            for k in ("start", "end", "merchant", "category", "metric", "txn_type", "comparison"):
                ctx.pop(k, None)
            if not ctx.get("pinned_doc_name"):
                ctx.pop("default_doc_name", None)
        # Check if query needs a clarification prompt
        resolved_doc_name, payload = needs_bank_clarification(user, q, ctx)
        if payload:
            # Yield the clarification NDJSON stream immediately
            def gen_clarify():
                yield json.dumps({"type": "clarification", "payload": payload}) + "\n"
            return StreamingResponse(gen_clarify(), media_type="application/x-ndjson")

    # Bind the resolved doc name context globally for this query execution thread
    queries.ACTIVE_DOC_NAME = resolved_doc_name
    from src.services.txn_store.parsers import detect_currency
    target_for_cur = resolved_doc_name[0] if isinstance(resolved_doc_name, list) and len(resolved_doc_name) > 0 else (resolved_doc_name if not isinstance(resolved_doc_name, list) else None)
    ts.set_currency(detect_currency(user, target_for_cur))

    # Punctuation-only / no-letters input ("...", "???", "!!!") can never be a real
    # question -> short nudge, never the insights dump. (αñÇ-αÑ┐ = Devanagari,
    # so Hindi-script input still passes through to the router.)
    if not re.search(r"[A-Za-z0-9αñÇ-αÑ┐]", q):
        _append_log(tid, q, DIDNT_CATCH, "chat")
        queries.ACTIVE_DOC_NAME = None # Reset
        return stream_text("chat", DIDNT_CATCH)

    # ---- resolve a PENDING clarification --------------------------------------------
    # Last turn we asked "which X did you mean?". If THIS turn is a pick (a name, "the
    # first", "2"), rewrite it back into the ORIGINAL question with the chosen entity and
    # let the normal pipeline answer it. If it isn't a pick, drop the pending state and
    # treat this as a fresh question.
    _pend = ctx.pop("pending_clarify", None)
    if _pend:
        _choice = _clarify_choice(q, _pend.get("options") or [])
        if _choice:
            q = _sub_clarify(_pend.get("orig", q), _pend.get("phrase", ""), _choice)

    # ---- CONVERSATIONAL RESOLUTION ---------------------------------------------------
    # Rewrite an elliptical follow-up ("average transaction", "compare with swiggy") into a
    # fully-resolved STANDALONE query by injecting the thread's carried scope, so EVERY
    # downstream engine (analytics / factual / ML / advice) receives an unambiguous
    # question. No-op on a fresh thread, so single-turn suites are unaffected.
    before = dict(ctx)
    state = ConversationState.from_ctx(ctx)
    rinfo = _resolve_conversation(q, state)
    if rinfo["reset"]:
        THREADS[tid] = {"ctx": {}, "history": []}
        _append_log(tid, q, CONTEXT_RESET_MSG, "chat")
        return stream_text("chat", CONTEXT_RESET_MSG)
    rq = rinfo["resolved"]
    # Persist the merged scope NOW so context carries regardless of which engine answers
    # (analytics/ML/advice never call _save_ctx).
    sc = rinfo["scope"]
    state.merchant, state.category = sc.get("merchant", ""), sc.get("category", "")
    state.start, state.end = sc.get("start", ""), sc.get("end", "")
    if sc.get("metric"):     state.metric = sc["metric"]
    if sc.get("txn_type"):   state.txn_type = sc["txn_type"]
    if sc.get("comparison"): state.comparison = sc["comparison"]
    state.prev_query = q
    state.to_ctx(ctx)
    _log_conv(tid, q, rq, rinfo, state, before)

    # 0-mon) "which months?" enumeration of the carried merchant/category (deterministic).
    #        Runs before the generic follow-up gate so it lists the months, not an LLM guess.
    mwa = months_which_answer(q, ctx)
    if mwa is not None:
        remember(history, q, mwa)
        _append_log(tid, q, mwa, "SQL")
        return stream_text("SQL", mwa)

    # 0) follow-up ABOUT the previous answer ("which merchant was that?", "why?")
    #    -> SQL-first: try to ground the referential follow-up in the carried scope and show
    #    the real data; only a genuinely narrative ask ("why?") falls to the LLM.
    if ctx and _FUP_ATTR.search(q) and _REFS_RE.search(q) and not _resolve_factual(q, ctx) \
            and not analytics_answer(q):
        fsa = followup_sql_answer(q, ctx)
        if fsa is not None:
            remember(history, q, fsa)
            _append_log(tid, q, fsa, "SQL")
            return stream_text("SQL", fsa)
        remember(history, q, "(answered from conversation)")
        return followup_response(q, history, tid)

    # 0a-ML) anomaly / forecast -> the sklearn models (deterministic figures from the
    #        data). Runs before the advice gate so these get the model, not a narrative.
    if _ANOM_RE.search(rq) or _FCAST_RE.search(rq) or _PROJ_RE.search(rq):
        mlans = ml_answer(rq)
        if mlans is not None:
            remember(history, q, mlans)
            _append_log(tid, q, mlans, "ML")
            return stream_text("ML", mlans)

    # 0a-INT) financial-intelligence engines (health / risk / recurring / impact /
    #         category-trend / behaviour / pattern digest)  -  deterministic, every
    #         number from SQL. Runs before the advice gate so these get the precise
    #         scored answer, not an LLM narrative.
    intans = intelligence_answer(rq)
    if intans is not None:
        remember(history, q, intans)
        _append_log(tid, q, intans, "SQL")
        return stream_text("SQL", intans)

    # 0b) advice / judgment / open-ended reasoning ("roast my spending", "should I cut
    #     back", "how dependent am I on one income source", "why was I charged overdraft
    #     fees") -> a real LLM answer reasoned over the SQL fact sheet (numbers verified).
    if _ADVICE_RE.search(rq) or _REASON_RE.search(rq) or _WHY_RE.search(rq):
        remember(history, q, "(financial advice given)")
        return grounded_advice(rq, tid, ctx)

    # 0c-CONCEPT) semantic spend concepts (gambling / loans / bank fees) grounded to
    #     real ledger merchants  -  deterministic, honest "not found" when nothing matches.
    ca = concept_answer(rq)
    if ca is not None:
        remember(history, q, ca)
        _append_log(tid, q, ca, "SQL")
        return stream_text("SQL", ca)

    # 0c) ANALYTICS (compare / average / % / argmax / amount filter / multi-entity /
    #     exclusion)  -  deterministic, numbers from SQL.
    aa = analytics_answer(rq)
    if aa is not None:
        remember(history, q, aa)
        _append_log(tid, q, aa, "SQL")
        return stream_text("SQL", aa)

    # 1) DETERMINISTIC factual resolution (standalone + thread context carry).
    det = _resolve_factual(rq, ctx)
    if det and det.get("type") == "clarify":
        # low-confidence entity: several stored merchants match  -  ask which, and REMEMBER the
        # question so next turn's reply ("the first" / "2" / a name) resolves and answers it.
        opts = det.get("options") or []
        ctx["pending_clarify"] = {"options": opts, "phrase": det.get("phrase", ""), "orig": rq}
        numbered = ", ".join(f"**{i + 1}. {o}**" for i, o in enumerate(opts))
        msg = (f"I found {len(opts)} matches for **{det.get('phrase', '')}**: {numbered}. "
               f"Which did you mean? (reply with a name or a number)")
        _append_log(tid, q, msg, "chat")
        return stream_text("chat", msg)
    if det and det.get("type"):
        print(f"[router] Factual resolved: {det}", flush=True)
        ans = ts.dispatch_intent(det, user, doc_name=resolved_doc_name)
        if ans is not None:
            if ans.lstrip("* ").lower().startswith("no transactions found"):
                # a name with ZERO transactions is not a usable thread scope — carrying
                # it pins later questions to a merchant that provably has no data.
                det = {**det, "merchant": "", "category": ""}
            _save_ctx(ctx, det)
            remember(history, q, ans)
            _append_log(tid, q, ans, "SQL")
            return stream_text("SQL", ans)

    # 2) LLM router for everything else: smalltalk / help / advice / summary /
    #    coverage / subscriptions / breakdown / genuine follow-ups.
    intent = llm_route(rq, history)
    if intent:
        print(f"[router] LLM intent: {intent}", flush=True)
        intent = _apply_guards(intent, rq)
        t = (intent.get("type") or "").lower()
        if t == "smalltalk":
            # Safety override: if the LLM wrongly classified a referential follow-up as smalltalk,
            # force it to "followup".
            if any(w in q.lower() for w in ("name", "bank", "which", "who", "whom", "it", "that", "then")):
                t = "followup"
            else:
                _append_log(tid, q, GREETING, "chat")
                return stream_text("chat", GREETING)
        if t == "help":
            cap = _capabilities()
            _append_log(tid, q, cap, "chat")
            return stream_text("chat", cap)
        if t == "followup" and history:
            fsa = followup_sql_answer(rq, ctx)     # SQL-first: real data before the LLM narrates
            if fsa is not None:
                remember(history, q, fsa)
                _append_log(tid, q, fsa, "SQL")
                return stream_text("SQL", fsa)
            remember(history, q, "(answered from conversation)")
            return followup_response(q, history, tid)
        if t in ("unknown", ""):
            _append_log(tid, q, DIDNT_CATCH, "chat")
            return stream_text("chat", DIDNT_CATCH)
        if t == "advice" and (_FIN_RE.search(rq) or _ADVICE_RE.search(rq) or _REASON_RE.search(rq)):
            remember(history, q, "(financial advice given)")
            return grounded_advice(rq, tid, ctx)
        # router said "advice" but the question has zero finance content (e.g. "should i
        # text my ex") -> don't lecture about money; fall through to a clean nudge below.
        ans = ts.dispatch_intent(intent, user, doc_name=resolved_doc_name)            # SQL produces every number
        if ans is not None:
            if ans.lstrip("* ").lower().startswith("no transactions found"):
                intent = {**intent, "merchant": "", "category": ""}  # zero-result → scope
            _save_ctx(ctx, intent)
            remember(history, q, ans)
            _append_log(tid, q, ans, "SQL")
            return stream_text("SQL", ans)
        # known type but no data, or off-topic -> honest nudge, never a parroted advice dump
        _append_log(tid, q, DIDNT_CATCH, "chat")
        return stream_text("chat", DIDNT_CATCH)

    # 3) Fallback when the LLM router is unavailable: regex path.
    if HELP_RE.match(q):
        cap = _capabilities()
        _append_log(tid, q, cap, "chat")
        return stream_text("chat", cap)
    if CONVO_RE.match(q):
        _append_log(tid, q, GREETING, "chat")
        return stream_text("chat", GREETING)
    ans = ts.answer(q, user, doc_name=resolved_doc_name)
    if ans is not None:
        remember(history, q, ans)
        _append_log(tid, q, ans, "SQL")
        return stream_text("SQL", ans)
    # last resort: an honest nudge  -  NOT a recycled advice dump (avoids parroting)
    _append_log(tid, q, DIDNT_CATCH, "chat")
    return stream_text("chat", DIDNT_CATCH)

def _md_inline(t):
    t = _htmlmod.escape(t)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"(?<!\*)\*([^*\s][^*]*)\*(?!\*)", r"<em>\1</em>", t)
    t = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', t)
    return t

def _md_to_html(md):
    """Minimal but table-aware Markdown -> HTML (stdlib only, no CDN)."""
    lines = md.split("\n")
    out, i, n = [], 0, len(md.split("\n"))
    while i < n:
        line = lines[i]
        if line.strip().startswith("```"):                       # fenced code
            j = i + 1; buf = []
            while j < n and not lines[j].strip().startswith("```"):
                buf.append(lines[j]); j += 1
            out.append("<pre><code>" + _htmlmod.escape("\n".join(buf)) + "</code></pre>")
            i = j + 1; continue
        if ("|" in line and i + 1 < n and "-" in lines[i + 1]    # GFM table
                and re.match(r"^\s*\|?[\s:|-]+\|?\s*$", lines[i + 1])):
            hdr = [c.strip() for c in line.strip().strip("|").split("|")]
            j = i + 2; rows = []
            while j < n and lines[j].strip() and "|" in lines[j]:
                rows.append([c.strip() for c in lines[j].strip().strip("|").split("|")]); j += 1
            th = "".join(f"<th>{_md_inline(c)}</th>" for c in hdr)
            tb = "".join("<tr>" + "".join(f"<td>{_md_inline(c)}</td>" for c in r) + "</tr>" for r in rows)
            out.append(f"<table><thead><tr>{th}</tr></thead><tbody>{tb}</tbody></table>")
            i = j; continue
        m = re.match(r"^(#{1,6})\s+(.*)$", line)                  # heading
        if m:
            lv = len(m.group(1)); out.append(f"<h{lv}>{_md_inline(m.group(2))}</h{lv}>"); i += 1; continue
        if re.match(r"^\s*---+\s*$", line):                       # hr
            out.append("<hr>"); i += 1; continue
        if line.lstrip().startswith(">"):                         # blockquote
            buf = []
            while i < n and lines[i].lstrip().startswith(">"):
                buf.append(re.sub(r"^\s*>\s?", "", lines[i])); i += 1
            out.append("<blockquote>" + _md_inline(" ".join(buf)) + "</blockquote>"); continue
        if re.match(r"^\s*[-*]\s+", line):                        # ul
            buf = []
            while i < n and re.match(r"^\s*[-*]\s+", lines[i]):
                buf.append("<li>" + _md_inline(re.sub(r"^\s*[-*]\s+", "", lines[i])) + "</li>"); i += 1
            out.append("<ul>" + "".join(buf) + "</ul>"); continue
        if re.match(r"^\s*\d+\.\s+", line):                       # ol
            buf = []
            while i < n and re.match(r"^\s*\d+\.\s+", lines[i]):
                buf.append("<li>" + _md_inline(re.sub(r"^\s*\d+\.\s+", "", lines[i])) + "</li>"); i += 1
            out.append("<ol>" + "".join(buf) + "</ol>"); continue
        if not line.strip():                                      # blank
            i += 1; continue
        buf = [line]; i += 1                                      # paragraph
        while i < n and lines[i].strip() and "|" not in lines[i] \
                and not re.match(r"^(#{1,6}\s|```|\s*[-*]\s|\s*\d+\.\s|>|\s*---+\s*$)", lines[i]):
            buf.append(lines[i]); i += 1
        out.append("<p>" + _md_inline(" ".join(buf)) + "</p>")
    return "\n".join(out)

def _render_doc(filename, title, raw):
    path = os.path.join(_DOCS_DIR, filename)
    try:
        with open(path, encoding="utf-8") as f:
            md = f.read()
    except Exception as e:
        return HTMLResponse(f"<p>{title} not found: {e}</p>", status_code=404)
    return HTMLResponse(_DOC_SHELL.replace("__TITLE__", title)
                        .replace("__RAW__", raw).replace("__BODY__", _md_to_html(md)))

def _raw_md(filename):
    path = os.path.join(_DOCS_DIR, filename)
    try:
        with open(path, encoding="utf-8") as f:
            return HTMLResponse(f.read(), media_type="text/plain; charset=utf-8")
    except Exception as e:
        return HTMLResponse(f"not found: {e}", status_code=404)

@app.get("/hld")
async def hld_page():
    return _render_doc("Penny_HLD_Technical.md", "Penny  -  Technical HLD", "/hld.md")

@app.get("/lld")
async def lld_page():
    return _render_doc("Penny_LLD.md", "Penny  -  Low-Level Design", "/lld.md")

@app.get("/roadmap")
async def roadmap_page():
    return _render_doc("Penny_Roadmap_Status.md", "Penny  -  Roadmap & Status", "/roadmap.md")

@app.get("/roadmap.md")
async def roadmap_md():
    return _raw_md("Penny_Roadmap_Status.md")

@app.get("/hld.md")
async def hld_md():
    return _raw_md("Penny_HLD_Technical.md")

@app.get("/lld.md")
async def lld_md():
    return _raw_md("Penny_LLD.md")

def _warmup():
    """Pre-load the model so the first advisory answer isn't a cold start (which is what
    made earlier replies show '(... unavailable)')."""
    try:
        if _llm_complete("Reply with the single word: ok.", "ok", num_predict=5):
            print(f"[warmup] {LLM_MODEL} ready", flush=True)
        else:
            print(f"[warmup] {LLM_MODEL} not reachable yet - will retry on first question", flush=True)
    except Exception as e:
        print(f"[warmup] Failed: {e}", flush=True)

@app.on_event("startup")
async def startup_event():
    import threading
    threading.Thread(target=_warmup, daemon=True).start()
