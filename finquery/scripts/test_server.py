"""
Self-contained local test server for the deterministic SQL layer.

    python scripts/test_server.py      ->  http://localhost:5667  (set PORT to override)

Mounts ONLY txn_store (no Together/Camelot/Chroma/auth), so it boots with zero
extra installs. Upload a statement PDF, then ask questions in the chat box and
see exact comma-formatted tables. Advice/narrative questions report that they'd
need the LLM (not loaded here). UI uses the Penny palette.
"""
import json
import os
import re
import sys
import threading
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime

import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse

OLLAMA_URL = os.getenv("OLLAMA_URL", "http://127.0.0.1:11434")
LLM_MODEL = os.getenv("LLM_MODEL", "llama3.1:8b")  # local Llama 3.1 8B via Ollama

ADVICE_SYSTEM = (
    "You are Penny, an offline personal-finance assistant. Detailed insights with exact figures "
    "are already shown to the user in tables above your reply. Your ONLY job is to write a single, "
    "warm, plain-English sentence that summarises their situation and gives one concrete next step.\n"
    "RULES:\n"
    "- Exactly ONE sentence. No lists, no headings, no preamble.\n"
    "- NEVER state any number, amount, percentage or currency — those are in the tables.\n"
    "- Be specific to this user using the headline findings provided.\n"
    "- Do not restate the question or write 'Answer:'."
)

# Grounded advisory: the LLM gives a REAL reasoned answer, but using ONLY figures we
# pre-computed in SQL (see ts.advice_facts). It phrases; it never calculates. Every
# number in its reply is then checked against the facts before it reaches the user.
GROUNDED_ADVICE_SYSTEM = (
    "You are Penny, a warm, plain-English offline personal-finance assistant. Answer the "
    "user's question directly and give specific, practical guidance — using ONLY the numbers "
    "in the FINANCIAL FACTS below.\n"
    "ABSOLUTE RULES (a wrong number is far worse than a vague one):\n"
    "- NEVER invent, guess, round, or CALCULATE a number. Do not add, subtract, multiply, "
    "divide, or derive any figure. Every amount or percentage you write MUST already appear, "
    "exactly, in the FINANCIAL FACTS. If a number you want isn't listed, describe it in words "
    "instead of inventing one.\n"
    "- Write amounts exactly as shown in the facts (e.g. ₹52,00,217.25). Do NOT rewrite them "
    "as '52 lakh' or '₹52L' or rounded forms.\n"
    "- Answer THIS question specifically: cite the 2-4 most relevant figures, then give a clear "
    "recommendation or verdict. 3-6 sentences, conversational. No tables, no bullet lists, no "
    "headings, no 'Answer:'.\n"
    "- You are not a licensed advisor: for 'which stock / where exactly to put money' questions, "
    "give sensible general principles grounded in their figures — never name specific securities.\n"
    "- When the user asks what to cut, cap, limit or reduce, the realistic targets are the "
    "categories the facts mark 'discretionary/flexible'; mention 'fixed/committed' ones only briefly.\n"
    "- Speak naturally. NEVER mention 'FINANCIAL FACTS', 'PROJECTION', 'run-rate', 'fact sheet', or "
    "say a figure 'comes from' / 'is listed in' the data — just state the numbers as if you know them.\n\n"
    "FINANCIAL FACTS (computed from the user's real statement — the only numbers you may use):\n"
)

# LLM-as-router: the model only CLASSIFIES the question into a structured intent
# (fixing typos, languages, ranges, "no of" phrasings). SQL still produces every
# number, so this cannot introduce hallucinated figures.
ROUTER_SYSTEM = """You convert a user's message about their bank statement into a JSON intent.
Output ONLY a JSON object, nothing else. Never compute or answer the question.

Fields:
- "type": one of "spend","income","count","summary","balance","category","merchant",
  "top_expenses","largest_expense","smallest_expense","largest_income","breakdown",
  "coverage","subscriptions","advice","smalltalk","help","followup","unknown"
- "category": one of "Groceries","Transport","Food & Dining","Shopping","Utilities",
  "Entertainment","Healthcare","Investment & Insurance" or ""
- "merchant": a merchant/person name if mentioned, else ""
- "n": integer for "top N", else 0
- "start": a month "YYYY-MM" or year "YYYY" if a time (or range start) is mentioned, else ""
- "end": a month "YYYY-MM" or year "YYYY" only if a date RANGE end is mentioned, else ""
- "table": true if the user asks for a table/breakdown, else false

Meaning of the key types (choose the most specific):
- "spend": the single TOTAL amount spent. ("total spending", "how much did I spend")
- "income": total money received. ("total income", "how much did I earn")
- "count": number of transactions. ("how many", "no of transactions", "number of")
- "category": spending split BY CATEGORY, or spend in one category. ("spending by category",
  "where does my money go", "how much on groceries")
- "breakdown": spending split BY MONTH over time. ("month-wise", "per month", "monthly", "each month")
- "summary": the overall account summary. ONLY for "summary", "overview", "snapshot", "net position"
- "balance": current/closing balance
- "merchant": spend with one merchant/person ("how much on swiggy")
- "top_expenses": the top N biggest expenses (set n)
- "subscriptions": recurring bills/subscriptions
- "help": the user asks what you can do or how to use this ("what can you do",
  "what can I ask","how do I use this","commands","help")
- "advice": the user wants guidance/insights about their finances ("how can I save",
  "am I spending too much","how am I doing","give me advice")
- "unknown": gibberish or anything you genuinely cannot classify ("wewe","asdf")

Dates ("start"/"end"):
- A specific day -> "YYYY-MM-DD" (e.g. "1 jan 2024" -> "2024-01-01", "15/03/2025" -> "2025-03-15").
- A month -> "YYYY-MM". A year -> "YYYY".
- Fix misspelled months: aparil->04, septmber->09, etc.

Rules:
- "no of transactions","how many","count","number of" -> "count".
- "X to Y","from X to Y","between X and Y" -> set BOTH start and end (a range).
- Greetings/small talk in ANY language (hi, hello, how are you, kaise ho, namaste, kya haal) -> "smalltalk".
- "how am I doing","advice","save money","insights","where can I cut" -> "advice".
- "what can you do","what can I ask","how do I use this","commands" -> "help".
- Random letters / gibberish you cannot read -> "unknown" (NOT "advice").
- "which months/years of data" -> "coverage".
- Do NOT use "summary" just because the word "spending" appears — "total spending" is "spend".
- "by category" is "category"; "by month/monthly" is "breakdown". Never mix them up.
- IMPORTANT — a NAMED category or merchant OVERRIDES plain spend, even when the sentence
  says "how much did I spend":
    * "...spend on <CATEGORY>" (Groceries, Shopping, Healthcare, Utilities, Transport,
      Entertainment, Food & Dining, Investment & Insurance) -> "category" (set "category").
    * "...spend at/on/to/with <MERCHANT or brand>" (Amazon, Swiggy, Netflix, Zerodha,
      Uber, Jio, a person's name…) -> "merchant" (set "merchant").
    * Use "spend" ONLY for the grand total when NO category and NO merchant is named.
  The leading "how much did I spend" does NOT make it "spend" if a category/merchant follows.
- CONTEXT: a previous question/answer may be provided. If the new message is an elliptical
  follow-up ("and may?","what about 2025","same for groceries"), REUSE the type of the
  MOST RECENT question shown (the LAST Q/A in the context) and just change the new detail
  (period/category/merchant). e.g. if the last question was a SPEND, "what about 2025" is spend.
- If the message asks ABOUT the previous answer or a number in it ("what is that","4395 is what",
  "why","explain that","what does that mean") -> "followup".
- If unclear -> "unknown".

Examples:
"what is my total spending?" -> {"type":"spend","category":"","merchant":"","n":0,"start":"","end":"","table":false}
"how much did I earn in 2024" -> {"type":"income","category":"","merchant":"","n":0,"start":"2024","end":"","table":false}
"show me spending by category" -> {"type":"category","category":"","merchant":"","n":0,"start":"","end":"","table":true}
"how much on groceries" -> {"type":"category","category":"Groceries","merchant":"","n":0,"start":"","end":"","table":false}
"give me a month-wise breakdown" -> {"type":"breakdown","category":"","merchant":"","n":0,"start":"","end":"","table":true}
"give me an account summary" -> {"type":"summary","category":"","merchant":"","n":0,"start":"","end":"","table":false}
"no of transaction done in aparil 2024?" -> {"type":"count","category":"","merchant":"","n":0,"start":"2024-04","end":"","table":false}
"how much did I spend on 1 jan 2024" -> {"type":"spend","category":"","merchant":"","n":0,"start":"2024-01-01","end":"","table":false}
"may month 2024 to july 2024 give table" -> {"type":"count","category":"","merchant":"","n":0,"start":"2024-05","end":"2024-07","table":true}
"4395 is what?" (after a count answer) -> {"type":"followup","category":"","merchant":"","n":0,"start":"","end":"","table":false}
"and in may?" (when the previous question was a COUNT for april) -> {"type":"count","category":"","merchant":"","n":0,"start":"2024-05","end":"","table":false}
"what about groceries?" (when the previous question asked SPEND) -> {"type":"category","category":"Groceries","merchant":"","n":0,"start":"","end":"","table":false}
"how much on swiggy in 2025" -> {"type":"merchant","category":"","merchant":"swiggy","n":0,"start":"2025","end":"","table":false}
"how much did I spend on Shopping in March 2025" -> {"type":"category","category":"Shopping","merchant":"","n":0,"start":"2025-03","end":"","table":false}
"how much did I spend on Healthcare in December 2024" -> {"type":"category","category":"Healthcare","merchant":"","n":0,"start":"2024-12","end":"","table":false}
"how much did I spend at Amazon in 2024" -> {"type":"merchant","category":"","merchant":"amazon","n":0,"start":"2024","end":"","table":false}
"how much did I spend at Zerodha" -> {"type":"merchant","category":"","merchant":"zerodha","n":0,"start":"","end":"","table":false}
"how many transactions on 15 October 2024" -> {"type":"count","category":"","merchant":"","n":0,"start":"2024-10-15","end":"","table":false}
"top 3 expenses" -> {"type":"top_expenses","category":"","merchant":"","n":3,"start":"","end":"","table":false}
"kaise ho" -> {"type":"smalltalk","category":"","merchant":"","n":0,"start":"","end":"","table":false}
"what can you do?" -> {"type":"help","category":"","merchant":"","n":0,"start":"","end":"","table":false}
"wewe" -> {"type":"unknown","category":"","merchant":"","n":0,"start":"","end":"","table":false}
"how can I save money" -> {"type":"advice","category":"","merchant":"","n":0,"start":"","end":"","table":false}
"paisa kaha ja raha hai" (where is my money going) -> {"type":"category","category":"","merchant":"","n":0,"start":"","end":"","table":true}
"paise ka kya scene hai" (what's my money situation) -> {"type":"summary","category":"","merchant":"","n":0,"start":"","end":"","table":false}
"kitna bacha mere paas" (how much is left) -> {"type":"balance","category":"","merchant":"","n":0,"start":"","end":"","table":false}
"kitna kharcha hua" (how much did I spend) -> {"type":"spend","category":"","merchant":"","n":0,"start":"","end":"","table":false}
"sabse bada kharcha kya tha" (what was the biggest expense) -> {"type":"largest_expense","category":"","merchant":"","n":0,"start":"","end":"","table":false}
"month over month" / "month on month" (monthly trend) -> {"type":"breakdown","category":"","merchant":"","n":0,"start":"","end":"","table":true}"""

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend"))
from src.services import txn_store as ts  # noqa: E402
from src.services import ml_insights as ml  # noqa: E402


# last few (question, answer) exchanges so follow-ups ("4395 is what?", "and in may?")
# have context. Single-user test server, so a module-global list is fine.
# ---- per-thread conversation state (chat-thread model) ----------------------
# Each chat thread keeps its OWN context + history, so a fresh thread = a fresh
# query (markerless questions resolve all-time), while within a thread an
# elliptical follow-up carries the thread's period/intent/category/merchant.
THREADS = {}


def _thread(tid):
    # Rehydrate from the persisted log on a cold thread so context (slot memory +
    # recent history) survives a server restart, not just an in-process session.
    if tid not in THREADS:
        THREADS[tid] = _rehydrate(tid)
    return THREADS[tid]


# ---- persist every chat turn to a JSON file (keyed by thread) ----------------
CHAT_LOG = os.path.join(os.path.dirname(__file__), "..", "data", "chats.json")
_log_lock = threading.Lock()


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
    real = [h for h in history if not h["a"].startswith("(")][-2:]
    if real:
        ctx = "\n".join(f"Q: {h['q']}\nA: {h['a']}" for h in real)
        user = f"[Recent conversation:\n{ctx}]\n\nNew message: {question}"
    payload = json.dumps({
        "model": LLM_MODEL, "stream": False, "keep_alive": "10m", "format": "json",
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

UPLOAD_DIR = os.path.join(os.path.dirname(__file__), "..", "data", "uploads")
os.makedirs(UPLOAD_DIR, exist_ok=True)
# --- pinned data source ------------------------------------------------------
# Always load the repo's data/live_txn.db, resolved to an ABSOLUTE path so it does
# not depend on the working directory the server was launched from. FINQ_DB can
# still override it, but ONLY if that env points to a file that actually exists —
# a stale or bogus FINQ_DB silently falls back to the pinned DB instead of breaking.
_PINNED_DB = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "data", "live_txn.db"))
_env_db = os.environ.get("FINQ_DB")
ts.DB_PATH = _env_db if (_env_db and os.path.exists(_env_db)) else _PINNED_DB
print(f"[db] using {ts.DB_PATH}" + ("" if os.path.exists(ts.DB_PATH) else "  (WARNING: not found!)"),
      flush=True)
ts.init_db()  # ensure schema (incl. the new insights table) exists on the active DB
USER = "local"

# Insight Engine: pre-compute for whatever data is already loaded, so health/risk/
# pattern questions work immediately without needing a fresh upload this session.
try:
    if ts.overview(USER)["count"]:
        ts.save_insights(USER, ts.compute_insights(USER))
        print("[insights] pre-computed for loaded data", flush=True)
except Exception as _e:  # never block startup on insights
    print("[insights] startup pre-compute skipped:", _e, flush=True)

app = FastAPI(title="Penny — SQL layer test")


@app.get("/", response_class=HTMLResponse)
async def index():
    return PAGE.replace("__MODEL__", LLM_MODEL)


@app.get("/status")
async def status():
    """Lets the page detect data already in the DB on load (so the input works
    without re-uploading after a refresh/restart)."""
    o = ts.overview(USER)
    return JSONResponse({"rows": o["count"], "spend": ts.inr(o["debit"]),
                         "income": ts.inr(o["credit"])})


def _fmt_date(d):
    """'YYYY-MM-DD' -> '15 Jan 24' for the Penny UI."""
    if not d or len(d) < 10:
        return d or ""
    y, m, day = d[:4], d[5:7], d[8:10]
    return f"{int(day)} {ts.MONTHS.get(m, m)} {y[2:]}"


@app.get("/dashboard")
async def dashboard():
    """Structured figures for the Penny Today / Patterns / Bills views.
    Amounts are signed: spend negative, income positive (the UI styles by sign).
    Every number is straight from SQL."""
    o = ts.overview(USER)
    if o["count"] == 0:
        return JSONResponse({"ready": False})
    con = ts.connect()
    cats = [{"name": r[0], "amount": r[1], "count": r[2]} for r in con.execute(
        "SELECT category,SUM(debit),COUNT(*) FROM transactions "
        "WHERE user_id=? AND debit>0 GROUP BY category ORDER BY 2 DESC", (USER,))]
    months = [{"ym": r[0], "spending": r[1], "income": r[2]} for r in con.execute(
        "SELECT month,SUM(debit),SUM(credit) FROM transactions "
        "WHERE user_id=? GROUP BY month ORDER BY month", (USER,))]
    recent = [{"date": _fmt_date(r[0]), "payee": r[1], "category": r[2],
               "amount": (r[4] - r[3])} for r in con.execute(
        "SELECT txn_date,merchant,category,debit,credit FROM transactions "
        "WHERE user_id=? ORDER BY seq DESC LIMIT 12", (USER,))]
    lg = con.execute("SELECT txn_date,merchant,debit FROM transactions "
                     "WHERE user_id=? AND debit>0 ORDER BY debit DESC LIMIT 1", (USER,)).fetchone()
    largest = {"date": _fmt_date(lg[0]), "payee": lg[1], "amount": lg[2]} if lg else None
    payees = [{"name": r[0], "amount": r[1]} for r in con.execute(
        "SELECT merchant,SUM(debit) FROM transactions WHERE user_id=? AND debit>0 "
        "GROUP BY merchant ORDER BY 2 DESC LIMIT 6", (USER,))]
    subs = []
    subset = sorted(ts.SUBSCRIPTION_MERCHANTS)
    if subset:
        qs = ",".join("?" * len(subset))
        for r in con.execute(
            f"SELECT merchant,COUNT(*),SUM(debit),MAX(txn_date) FROM transactions "
            f"WHERE user_id=? AND debit>0 AND merchant IN ({qs}) "
            f"GROUP BY merchant ORDER BY 3 DESC", (USER, *subset)):
            subs.append({"name": r[0], "count": r[1], "total": r[2], "last": _fmt_date(r[3])})
    con.close()
    return JSONResponse({
        "ready": True, "currency": "₹",
        "totals": {"spending": o["debit"], "income": o["credit"],
                   "net": o["credit"] - o["debit"], "count": o["count"]},
        "balance": ts.latest_balance(USER),
        "categories": cats, "months": months, "recent": recent,
        "largest": largest, "topPayees": payees, "subscriptions": subs,
    })


@app.get("/transactions")
async def transactions(offset: int = 0, limit: int = 40, q: str = ""):
    """Paged + searchable raw transactions for the Penny Data view."""
    con = ts.connect()
    where, params = "user_id=?", [USER]
    if q:
        where += " AND (LOWER(merchant) LIKE ? OR LOWER(descr) LIKE ? OR LOWER(category) LIKE ?)"
        like = f"%{q.lower()}%"; params += [like, like, like]
    total = con.execute(f"SELECT COUNT(*) FROM transactions WHERE {where}", params).fetchone()[0]
    rows = [{"date": _fmt_date(r[0]), "payee": r[1], "category": r[2],
             "amount": (r[4] - r[3])} for r in con.execute(
        f"SELECT txn_date,merchant,category,debit,credit FROM transactions WHERE {where} "
        f"ORDER BY seq DESC LIMIT ? OFFSET ?", params + [limit, offset])]
    con.close()
    return JSONResponse({"rows": rows, "total": total})


# ---- scikit-learn ML insights (cached by row-count so re-fits are cheap) -----
_ML_CACHE = {}


def _ml(kind, fn):
    key = (kind, ts.overview(USER)["count"])
    if key not in _ML_CACHE:
        _ML_CACHE.clear()
        _ML_CACHE[key] = fn()
    return _ML_CACHE[key]


@app.get("/ml/anomalies")
async def ml_anomalies():
    return JSONResponse(_ml("anom", lambda: ml.anomalies(USER)))


@app.get("/ml/forecast")
async def ml_forecast():
    return JSONResponse(_ml("fc", lambda: ml.forecast(USER)))


@app.get("/ml/recurring")
async def ml_recurring():
    return JSONResponse(_ml("rec", lambda: ml.recurring(USER)))


@app.get("/ml/categorize")
async def ml_categorize():
    return JSONResponse(_ml("cat", lambda: ml.categorizer_report(USER)))


@app.get("/insights")
async def insights_endpoint():
    """Pre-computed Insight Engine output (stored on upload; live-computed if absent)."""
    items = ts.get_insights(USER) or ts.compute_insights(USER)
    return JSONResponse({
        "insights": items,
        "health": ts.health_score(USER),
        "risk": ts.risk_assessment(USER),
    })


@app.post("/upload")
async def upload(request: Request):
    name = request.query_params.get("name", "statement.pdf")
    data = await request.body()
    path = os.path.join(UPLOAD_DIR, os.path.basename(name))
    with open(path, "wb") as f:
        f.write(data)
    import time
    t0 = time.time()
    rows = ts.ingest_pdf(path, name, USER)
    dt = time.time() - t0
    ov = ts.overview(USER, name)
    # Insight Engine: pre-compute health/risk/pattern/behaviour/impact once on upload
    # so synthesis questions are an instant table read, not a re-derivation. Never let
    # an insights hiccup fail the upload itself.
    try:
        ts.save_insights(USER, ts.compute_insights(USER))
    except Exception as e:
        print("[insights] compute on upload failed:", e, flush=True)
    return JSONResponse({
        "filename": name, "rows": rows, "seconds": round(dt, 2),
        "spend": ts.inr(ov["debit"]), "income": ts.inr(ov["credit"]),
    })


CONVO_RE = re.compile(
    r"^(hi+|hii+|hey+|hy+|hello+|h(e)?l+o+|yo|hola|namaste|sup|heya|good (morning|afternoon|evening)|"
    r"how are you|how's it going|who are you|what are you|thanks|"
    r"thank you|thx|bye|goodbye)\b", re.I)
HELP_RE = re.compile(r"^(help|\?|what can (you|u) (do|help)|how (do i|to) use|commands?)\b", re.I)
def _capabilities():
    return ("I answer questions about your statement with exact figures. Try:\n\n"
            "- **Totals** — \"total spending\", \"total income\", \"net position\"\n"
            "- **By period** — \"how much did I spend in 2024\", \"march 2025 summary\"\n"
            "- **By category** — \"spending by category\", \"how much on groceries\"\n"
            "- **By merchant** — \"how much on swiggy / amazon / zerodha\"\n"
            "- **Extremes** — \"biggest expense\", \"top 5 expenses\"\n"
            "- **Coverage** — \"which months do you have\"\n"
            "- **Balance** — \"current balance\"\n"
            "- **Health score** — \"how financially healthy am I?\", \"rate my finances\"\n"
            "- **Risk** — \"what risks do you see?\", \"am I overspending?\"\n"
            "- **Patterns & habits** — \"what patterns do you see?\", \"what spending habits do I have?\"\n"
            "- **Subscriptions** — \"what subscriptions do I have?\", \"recurring bills\"\n"
            "- **Impact & trends** — \"which transactions had the biggest impact?\", \"which categories are growing fastest?\"\n"
            f"- **Advice** — \"how can I save money?\" (uses local {LLM_MODEL})")


GREETING = ("Hi! I'm **Penny**, your offline statement assistant. "
            "Ask me about totals, categories, merchants, time periods, or for saving advice. "
            "_Type \"help\" to see examples._")

DIDNT_CATCH = ("I didn't quite catch that. Ask about totals, categories, merchants, or a time "
               "period — or type **help** to see examples.")


# ---- deterministic guards: the 8B router is unreliable at PERIOD parsing and at
# a few unambiguous intents, so we parse those with regex and override the LLM. ---
_MON_RE = (r"jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?"
           r"|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?")


def _mon_num(s):
    return {"jan": "01", "feb": "02", "mar": "03", "apr": "04", "may": "05", "jun": "06",
            "jul": "07", "aug": "08", "sep": "09", "oct": "10", "nov": "11", "dec": "12"}[s[:3].lower()]


def _norm_one(s):
    """Normalise a single date expression to YYYY | YYYY-MM | YYYY-MM-DD, or None."""
    s = s.strip().lower().rstrip(".,")
    m = re.fullmatch(rf"(\d{{1,2}})(?:st|nd|rd|th)?\s+(?:of\s+)?({_MON_RE})\.?\s+(\d{{4}})", s)  # 27th (of) sep 2024
    if m:
        return f"{m.group(3)}-{_mon_num(m.group(2))}-{int(m.group(1)):02d}"
    m = re.fullmatch(rf"({_MON_RE})\.?\s+(\d{{1,2}})(?:st|nd|rd|th)?\s+(\d{{4}})", s)  # oct 15 2024
    if m:
        return f"{m.group(3)}-{_mon_num(m.group(1))}-{int(m.group(2)):02d}"
    m = re.fullmatch(r"(\d{1,2})[/-](\d{1,2})[/-](\d{4})", s)               # 15/10/2024 (DD/MM)
    if m:
        return f"{m.group(3)}-{int(m.group(2)):02d}-{int(m.group(1)):02d}"
    m = re.fullmatch(rf"({_MON_RE})\.?\s+(\d{{4}})", s)                     # oct 2024
    if m:
        return f"{m.group(2)}-{_mon_num(m.group(1))}"
    m = re.fullmatch(r"(20\d\d)", s)                                        # 2024
    if m:
        return m.group(1)
    return None


_DATE_EXPR = (rf"(?:\d{{1,2}}(?:st|nd|rd|th)?\s+(?:of\s+)?(?:{_MON_RE})\.?,?\s+\d{{4}}"
              rf"|(?:{_MON_RE})\.?\s+\d{{1,2}}(?:st|nd|rd|th)?,?\s+\d{{4}}"
              rf"|\d{{1,2}}[/-]\d{{1,2}}[/-]\d{{4}}"
              rf"|(?:{_MON_RE})\.?,?\s+\d{{4}}"
              rf"|20\d\d)")
_RANGE_RE = re.compile(rf"({_DATE_EXPR})\s*(?:to|till|until|through|thru|[-–—]|and)\s*({_DATE_EXPR})", re.I)
_SINGLE_RE = re.compile(_DATE_EXPR, re.I)
_INCOME_RE = re.compile(r"\b(income|earn(?:ed|ings|t)?|salary|salaries|inflow|received|receive)\b", re.I)
_COUNTQ_RE = re.compile(r"\bhow many\b|\bnumber of\b|\bno\.? of\b|\bcount\b", re.I)


_WORDNUM = {"twenty": 20, "thirty": 30, "twenty one": 21, "twenty two": 22, "twenty three": 23,
            "twenty four": 24, "twenty five": 25, "twenty six": 26, "twenty seven": 27,
            "twenty eight": 28, "twenty nine": 29}


def _sub_word_years(q):
    """'twenty twenty four' -> '2024'."""
    def repl(m):
        return "20" + f"{_WORDNUM.get(m.group(1).lower(), 0):02d}"
    return re.sub(r"\btwenty[- ]twenty[- ](one|two|three|four|five|six|seven|eight|nine)\b",
                  lambda m: "20" + f"{_WORDNUM['twenty ' + m.group(1).lower()] % 100:02d}", q, flags=re.I)


def _anchor_month():
    """Latest YYYY-MM that has data (relative dates resolve against the statement)."""
    cov = ts.coverage(USER)
    return cov[1] if cov else None


def _shift_month(ym, delta):
    y, m = int(ym[:4]), int(ym[5:7])
    i = (y * 12 + (m - 1)) + delta
    return f"{i // 12:04d}-{i % 12 + 1:02d}"


def _relative_period(q):
    """Resolve 'this/last month|year', 'last N months', 'last quarter', YTD against
    the statement's latest month. Returns (start, end) or None."""
    low = q.lower()
    a = _anchor_month()
    if not a:
        return None
    ay = a[:4]
    if re.search(r"\b(this|current) month\b", low):
        return a, ""
    if re.search(r"\b(last|previous|prev) month\b", low):
        return _shift_month(a, -1), ""
    if re.search(r"\b(this|current) year\b|\byear[- ]to[- ]date\b|\bytd\b", low):
        return ay, ""
    if re.search(r"\b(last|previous|prev) year\b", low):
        return f"{int(ay)-1}", ""
    m = re.search(r"\b(?:last|past|previous|recent)\s+(\d{1,2})\s+months?\b", low)
    if m:
        n = int(m.group(1))
        return _shift_month(a, -(n - 1)), a
    if re.search(r"\b(last|past|previous) quarter\b", low):
        return _shift_month(a, -2), a
    return None


_AMT_CMP_RE = re.compile(
    r"\b(?:over|above|under|below|more than|less than|greater than|bigger than|smaller than|"
    r"exceed\w*|cheaper than|higher than|lower than|at\s?least|atleast|min(?:imum)?|max(?:imum)?)"
    r"\s+(?:₹|rs\.?|inr|rupees?|rupess)?\s*\d[\d,]*(?:\.\d+)?", re.I)


def _strip_cmp_amounts(q):
    """Blank out 'under 2000' / 'over 2024' style amounts so a year-range number used in an
    amount comparison is never misread as a YEAR by the period parser."""
    return _AMT_CMP_RE.sub(" ", q)


def _parse_period(q):
    """Deterministic period from the question text: (start, end) or None.
    Handles explicit dates, word-years, and relative dates (this/last month/year)."""
    q = _strip_cmp_amounts(_sub_word_years(q))
    rel = _relative_period(q)
    if rel:
        return rel
    m = _RANGE_RE.search(q)
    if m:
        a, b = _norm_one(m.group(1)), _norm_one(m.group(2))
        if a and b:
            return a, b
    m = _SINGLE_RE.search(q)
    if m:
        one = _norm_one(m.group(0))
        if one:
            return one, ""
    return None


_FACTUAL = ("spend", "summary", "income", "count", "category", "merchant", "balance", "breakdown")


_TABLE_RE = re.compile(r"\b(table|breakdown|month[- ]?wise|each month|monthly|by month|per month)\b", re.I)


def _apply_guards(intent, q):
    """Override the LLM where regex is more reliable: period parsing, the
    income/count keywords it flubs, and whether a table was actually asked for.
    Category / merchant / extremes are left to the (now-fixed) LLM."""
    det = _parse_period(q)
    if det:
        intent["start"], intent["end"] = det
    low = q.lower()
    # single biggest/smallest expense — the keyword decides direction (the LLM flips
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
            t = "spend"                       # clear "how much did I spend" — not count/breakdown
        elif t == "breakdown" and not wants_table:
            t = "spend"                       # a range/period TOTAL, not a monthly table
    intent["type"] = t
    if t in ("count", "spend", "income"):
        intent["table"] = wants_table         # per-month table only when explicitly asked
    return intent


# ---- ndjson word-by-word streaming -----------------------------------------
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


def _llm_words(system, user):
    """Stream the LLM reply from Ollama, buffered into whole words."""
    payload = json.dumps({
        "model": LLM_MODEL, "stream": True, "keep_alive": "10m",
        "options": {"temperature": 0.3, "num_predict": 80, "top_p": 0.9, "num_ctx": 2048},
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
    }).encode()
    buf = ""
    try:
        req = urllib.request.Request(f"{OLLAMA_URL}/api/chat", data=payload,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=300) as resp:
            for line in resp:
                line = line.strip()
                if not line:
                    continue
                d = json.loads(line)
                buf += d.get("message", {}).get("content", "")
                while " " in buf:
                    word, buf = buf.split(" ", 1)
                    yield _nd({"type": "chunk", "content": word + " "})
                if d.get("done"):
                    break
        if buf:
            yield _nd({"type": "chunk", "content": buf})
    except Exception as e:
        yield _nd({"type": "chunk", "content": f"\n_({LLM_MODEL} unavailable: {e}.)_"})


FOLLOWUP_SYSTEM = (
    "You are Penny, a finance assistant. Below is the recent conversation, including the exact "
    "answers already given. Answer the user's follow-up in ONE short sentence using ONLY the "
    "facts and figures already shown in that conversation. NEVER invent a number. If the answer "
    "isn't in the conversation, say you can look it up if they ask the question directly."
)


def followup_response(q, history, thread="default"):
    """Answer a question ABOUT the recent conversation (e.g. 'what is that number?')."""
    convo = "\n".join(f"User: {h['q']}\nPenny: {h['a']}" for h in history[-4:])

    def gen():
        parts = []
        yield _nd({"type": "meta", "path": "chat"})
        for nd in _llm_words(FOLLOWUP_SYSTEM + "\n\nConversation so far:\n" + convo, q):
            parts.append(_txt(nd)); yield nd
        yield _nd({"type": "done"})
        _append_log(thread, q, "".join(parts), "chat")
    return StreamingResponse(gen(), media_type="application/x-ndjson")


def advice_response(q, thread="default"):
    """Deterministic insights (exact SQL figures) + one grounded LLM sentence."""
    report, grounding = ts.build_insights(USER)
    snapshot, _ = ts.advice_context(USER)

    def gen():
        parts = []
        yield _nd({"type": "meta", "path": "advice"})
        for nd in stream_markdown(snapshot + "\n\n" + report):
            parts.append(_txt(nd)); yield nd
        yield _nd({"type": "chunk", "content": "\n\n"}); parts.append("\n\n")
        for nd in _llm_words(ADVICE_SYSTEM + "\n\n" + grounding, q):
            parts.append(_txt(nd)); yield nd
        yield _nd({"type": "done"})
        _append_log(thread, q, "".join(parts), "advice")
    return StreamingResponse(gen(), media_type="application/x-ndjson")


# ---- grounded advisory answers: the LLM reasons, SQL supplies every number -----
# Open-ended advisory questions ("how am I doing?", "where should I cut?", "how much
# can I invest?", "what trends do you see?") deserve a real, reasoned answer — not a
# generic table dump. We hand the model a fully pre-computed fact sheet (every figure
# from SQL) and let it PHRASE the advice. As a safety net we then verify that every
# amount/percentage in its reply actually appears in the facts; if it strayed (invented
# or computed a number) we discard it and return a concise deterministic answer. So the
# core guarantee holds: no number reaches the user unless SQL produced it.

def _llm_complete(system, user, num_predict=512, temperature=0.2):
    """One-shot (non-streaming) LLM call -> full text, or None. Retries once so a cold
    model load doesn't surface as a failure."""
    payload = json.dumps({
        "model": LLM_MODEL, "stream": False, "keep_alive": "30m",
        "options": {"temperature": temperature, "num_predict": num_predict,
                    "top_p": 0.9, "num_ctx": 4096},
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": user}],
    }).encode()
    for attempt in (1, 2):
        try:
            req = urllib.request.Request(f"{OLLAMA_URL}/api/chat", data=payload,
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=150) as resp:
                txt = json.loads(resp.read()).get("message", {}).get("content", "")
            return (txt or "").strip() or None
        except Exception as e:
            print(f"[advice] LLM attempt {attempt}/2 failed: {type(e).__name__}: {e}")
    return None


_NUM_MULT = {"crore": 1e7, "crores": 1e7, "cr": 1e7, "lakh": 1e5, "lakhs": 1e5,
             "lac": 1e5, "lacs": 1e5, "thousand": 1e3, "k": 1e3, "million": 1e6, "mn": 1e6}
_AMT_RE = re.compile(
    r"₹\s*([\d,]+(?:\.\d+)?)|\b(\d[\d,]*(?:\.\d+)?)\s*(crores?|cr|lakhs?|lacs?|lac|thousand|million|mn|k)\b",
    re.I)
_PCT_RE = re.compile(r"(\d+(?:\.\d+)?)\s*%")


def _amounts_in(s):
    out = []
    for m in _AMT_RE.finditer(s):
        if m.group(1) is not None:
            out.append(float(m.group(1).replace(",", "")))
        else:
            out.append(float(m.group(2).replace(",", "")) * _NUM_MULT.get(m.group(3).lower(), 1))
    return out


def _advice_grounded(reply, facts):
    """True iff every ₹-amount and percentage in `reply` matches one in `facts`
    (amounts within 0.5% or ₹1; percentages within 0.5 pt). Catches the model
    inventing or computing a figure."""
    fa = _amounts_in(facts)
    fp = [float(x) for x in _PCT_RE.findall(facts)]
    for v in _amounts_in(reply):
        if not any(abs(v - f) <= max(1.0, 0.005 * max(v, f)) for f in fa):
            return False, f"amount {v:,.2f} not in facts"
    for v in (float(x) for x in _PCT_RE.findall(reply)):
        if not any(abs(v - f) <= 0.5 for f in fp):
            return False, f"percentage {v}% not in facts"
    return True, ""


def _advice_fallback(q):
    """Concise, fully-deterministic advisory answer (no LLM) — used when the model is
    unavailable or its reply failed the number check. On-topic and short, never a dump."""
    o = ts.overview(USER)
    if o["count"] == 0:
        return "_Upload a statement first._"
    low = q.lower()
    inr, grp = ts.inr, ts.grp
    nmon = max(len(ts.months_list(USER)), 1)
    inc, sp, net = o["credit"], o["debit"], o["net"]
    rate = (net / inc * 100) if inc else 0
    cats = ts.by_category(USER)
    disc = [(c, a) for c, a, _n in cats if c in ts.DISCRETIONARY][:3]

    if re.search(r"\btransactions?\b|biggest impact|impact on (?:my )?(?:financial|finances|health)", low):
        tx = ts.top_expenses(USER, 5)
        if tx:
            body = "; ".join(f"{inr(amt)} to {mer}" for _dt, mer, amt in tx)
            return (f"**Your 5 largest single transactions** — the individual debits with the biggest "
                    f"impact on your balance: {body}. Together with your top merchants (which make up "
                    f"the bulk of spending), these are what most move your financial health.")

    if re.search(r"\b(invest|afford|save (?:more|each|every|per)|how much (?:can|should))\b", low):
        return (f"**You can safely invest around {inr(net / nmon)} a month.** That's your average "
                f"monthly surplus — the income left after all spending — and you already save "
                f"{rate:.1f}% of income ({inr(net)} of {inr(inc)}). A common floor is 20% of income "
                f"({inr(inc / nmon * 0.20)}/month), which you clear comfortably, so directing most of "
                f"that surplus to investments while keeping an emergency buffer is reasonable.")
    if re.search(r"depend|relian|income source|concentrat|diversif", low):
        src = [r for r in ts.income_by_source(USER) if r[1] > 0]
        if src and inc:
            top, amt = src[0][0], src[0][1]
            dep = amt / inc * 100
            v = ("heavily dependent on one source" if dep >= 70 else
                 "fairly concentrated" if dep >= 50 else "reasonably diversified")
            return (f"**{dep:.1f}% of your income comes from {top}** ({inr(amt)} of {inr(inc)}), so "
                    f"you're {v}. Building a second income stream would cushion you if that source paused.")
    if re.search(r"limit|cut|reduce|control|trim|budget|overspend|too much|where can i save", low):
        if disc:
            body = ", ".join(f"{c} ({inr(a)})" for c, a in disc)
            return (f"**Cap your flexible spending first:** {body} — these are the most discretionary "
                    f"categories and the easiest to limit. You spend {inr(sp)} against {inr(inc)} income "
                    f"(a {rate:.1f}% savings rate), so trimming these lifts what you keep.")
    if re.search(r"trend|pattern|observe|notice|insight|how am i|doing|healthy", low):
        bm = ts.by_month(USER)
        extra = ""
        if len(bm) >= 2:
            half = len(bm) // 2
            n1, n2 = half or 1, (len(bm) - half) or 1
            s1, s2 = sum(r[1] for r in bm[:half]) / n1, sum(r[1] for r in bm[half:]) / n2
            extra = f" Average monthly spend moved from {inr(s1)} (first half) to {inr(s2)} (second half)."
        topc = f" Your biggest category is {cats[0][0]} at {inr(cats[0][1])}." if cats else ""
        return (f"**You keep {rate:.1f}% of your income** — saving {inr(net)} of {inr(inc)} over "
                f"{nmon} months.{extra}{topc}")
    line = (f"**At a glance:** income {inr(inc)}, spending {inr(sp)}, net saved {inr(net)} — a "
            f"{rate:.1f}% savings rate over {nmon} months. On average you keep {inr(net / nmon)} a "
            f"month to put toward savings or investment.")
    if disc:
        line += " Your most flexible spending is " + ", ".join(f"{c} ({inr(a)})" for c, a in disc) + "."
    return line


def grounded_advice(q, thread="default"):
    """Advisory answer: the LLM reasons over a SQL-computed fact sheet, and every number
    is verified against those facts before going out, else a deterministic fallback."""
    facts = ts.advice_facts(USER)
    reply = _llm_complete(GROUNDED_ADVICE_SYSTEM + facts, q)
    if reply:
        reply = re.sub(r"^(?:answer|penny)\s*[:\-]\s*", "", reply, flags=re.I).strip()
        ok, why = _advice_grounded(reply, facts)
        if ok:
            _append_log(thread, q, reply, "advice")
            return stream_text("advice", reply)
        print(f"[advice] reply rejected ({why}); using deterministic fallback")
    fb = _advice_fallback(q)
    _append_log(thread, q, fb, "advice")
    return stream_text("advice", fb)


# ---- conversation state (slot memory) — deterministic context holding ---------
# The LLM is poor at carrying period/intent across turns (and raw-history context
# poisons even explicit questions). So we keep a small structured state of the last
# resolved factual query and fill an elliptical follow-up's missing slots from it.
CTX = {}        # {"type","start","end","category","merchant","n"}

_CAT_SYN = {
    "groceries": "Groceries", "grocery": "Groceries",
    "food": "Food & Dining", "dining": "Food & Dining", "restaurant": "Food & Dining",
    "transport": "Transport", "travel": "Transport", "commute": "Transport",
    "shopping": "Shopping",
    "utilities": "Utilities", "utility": "Utilities",
    "entertainment": "Entertainment",
    "healthcare": "Healthcare", "health": "Healthcare", "medical": "Healthcare",
    "investment": "Investment & Insurance", "investments": "Investment & Insurance",
    "insurance": "Investment & Insurance",
}
_BIG_RE = re.compile(r"\b(big+e?st|larg+e?st|highest|maximum|priciest|most expensive|dearest|sabse bada|sabse zyada)\b", re.I)
_SMALL_RE = re.compile(r"\b(smal{1,2}e?st|low+e?st|cheap+e?st|minimum|least expensive|sabse chota|sabse kam|sabse sasta)\b", re.I)
_ALLTIME_RE = re.compile(r"\ball[- ]?time\b|\boverall\b|\blifetime\b|\bever\b|\bin total\b", re.I)
_COUNT_X = re.compile(r"\bhow many\b|\bnumber of\b|\bno\.? of\b|\bcount\b|\bkitne\b|\btransactions?\b|\btxns?\b|\bpurchases?\b", re.I)
_TOP_RE = re.compile(r"\btop\s+(\d+)\b", re.I)
_BAL_RE = re.compile(r"\b(balance|left in (?:the )?(?:bank|account)|bacha)\b", re.I)
_SPEND_RE = re.compile(r"\b(spend|spent|spending|kharcha|kharch|blew|burn)\b", re.I)
_INCOME_RE2 = re.compile(r"\b(incom(?:e|ings)?|earn(?:ed|ings|t)?|salary|salaries|inflow|received|receive)\b", re.I)
_EXP_CTXT = ("expense", "spend", "purchase", "transaction", "charge", "buy", "kharcha", "kharch")
_CONT_RE = re.compile(r"^\s*(and\b|also\b|plus\b|then\b|now\b|just\b|ok\b|okay\b|&|aur\b|phir\b|what about|how about|what'?s about)", re.I)
_REFS_RE = re.compile(r"\b(that|then|those|same|it)\b", re.I)
_KM = None


def _known_merchants():
    global _KM
    if _KM is None:
        con = ts.connect()
        _KM = sorted((r[0] for r in con.execute(
            "SELECT DISTINCT merchant FROM transactions WHERE merchant<>''") if r[0]),
            key=len, reverse=True)   # longest first so "Apollo Pharmacy" beats "Apollo"
        con.close()
    return _KM


def _extract_slots(q):
    low = q.lower()
    merch = ""
    for m in _known_merchants():
        if re.search(r"\b" + re.escape(m.lower()) + r"\b", low):
            merch = m
            break
    cat = ""
    if not merch:
        for kw, c in _CAT_SYN.items():
            if re.search(r"\b" + kw + r"\b", low):
                cat = c
                break
    # honesty guard: an explicit "at/from <Name>" that is NOT a known merchant or
    # category -> treat as that (unknown) merchant, so dispatch answers an honest
    # "no transactions found for X" instead of silently returning the grand total.
    if not merch and not cat:
        um = re.search(r"\b(?:at|from)\s+([a-z][a-z0-9&'.\-]*(?:\s+[a-z0-9&'.\-]+){0,2}?)"
                       r"(?:\s+(?:in|on|during|for|last|this|the|over|between|per|by)\b|[?.!,]|$)", low)
        if um:
            cand = um.group(1).strip()
            if cand and cand not in _CAT_SYN and cand not in (
                    "the", "a", "an", "all", "home", "work", "least", "most", "that", "it",
                    "the moment", "saving", "saving more", "savings", "spending", "paying",
                    "more", "now", "today", "anything", "something") \
                    and not cand.endswith((" more", " less")):
                merch = cand
    pf = _parse_period(q)
    pmonth = pday = ""
    prange = None
    if not pf:
        # bare "July to December" (no year) — carry the year to both bounds later
        mr = re.search(rf"\b({_MON_RE})\b\s*(?:to|till|until|through|thru|[-–]|and)\s*\b({_MON_RE})\b", low)
        if mr:
            prange = (_mon_num(mr.group(1)), _mon_num(mr.group(2)))
        else:
            mm = re.search(rf"\b({_MON_RE})\b", low)
            if mm:
                pmonth = _mon_num(mm.group(1))
                # a day number adjacent to the month, even WITHOUT an ordinal ("15 august")
                dm = re.search(rf"\b(\d{{1,2}})\s+{re.escape(mm.group(1))}\b|"
                               rf"\b{re.escape(mm.group(1))}\s+(\d{{1,2}})\b", low)
                if dm:
                    pday = f"{int(dm.group(1) or dm.group(2)):02d}"
            dd = re.search(r"\b(\d{1,2})(?:st|nd|rd|th)\b", low)
            if dd:
                pday = f"{int(dd.group(1)):02d}"
    topm = _TOP_RE.search(q)
    has_exp = any(w in low for w in _EXP_CTXT)
    has_cr = any(w in low for w in ("deposit", "credit", "received", "income", "inflow"))
    t = None
    if _BIG_RE.search(q) and has_cr and not has_exp:    # "largest deposit/credit"
        t = "largest_income"
    elif _BIG_RE.search(q) and has_exp:        # "largest transaction" before count
        t = "largest_expense"
    elif _SMALL_RE.search(q) and has_exp:
        t = "smallest_expense"
    elif _COUNT_X.search(q):
        t = "count"
    elif _INCOME_RE2.search(q):
        t = "income"
    elif _BAL_RE.search(q):
        t = "balance"
    elif topm:
        t = "top_expenses"
    elif merch:
        t = "merchant"
    elif cat:
        t = "category"
    elif _SPEND_RE.search(q):
        t = "spend"
    elif _BIG_RE.search(q):           # bare "and the biggest?" continuation
        t = "largest_expense"
    elif _SMALL_RE.search(q):
        t = "smallest_expense"
    ckind = ""
    if t == "count":
        if re.search(r"\bupi\b", low):
            ckind = "upi"
        elif re.search(r"\bcredit\b|\bdeposit", low):
            ckind = "credit"
        elif re.search(r"\bdebit\b", low):
            ckind = "debit"
    return {"type": t, "period_full": pf, "pmonth": pmonth, "pday": pday, "prange": prange,
            "category": cat, "merchant": merch, "n": int(topm.group(1)) if topm else 0,
            "count_kind": ckind}


def _resolve_factual(q, ctx):
    """Deterministically resolve a factual money query, carrying missing slots from
    the THREAD's ctx for elliptical follow-ups. Returns an intent dict, or None
    (let the LLM handle smalltalk / help / advice / summary / coverage / etc.).

    Thread model: within a live thread (ctx non-empty) a question that omits the
    period inherits the thread's period — so a bare "how many transactions?" after
    "spend in August 2024" carries August. A FRESH thread has empty ctx, so the
    same bare question resolves all-time. The client decides what's one thread."""
    s = _extract_slots(q)
    cont = bool(_CONT_RE.search(q))
    refs = bool(_REFS_RE.search(q)) and not s["period_full"]
    low = q.lower()
    alltime = bool(_ALLTIME_RE.search(low)) and not s["period_full"] \
        and not (s["pmonth"] or s["pday"] or s["prange"])   # don't let "overall" drop a date
    # "and the whole year?" / "the entire year" -> widen the thread's period to its full
    # year while KEEPING the carried category/merchant (don't fall through to the LLM).
    whole_year = bool(re.search(r"\b(?:whole|entire|full|complete|rest of the)\s+year\b"
                                r"|\bfor the (?:whole |entire |full )?year\b|\ball year\b", low)) \
        and not s["period_full"]
    has_new = any([s["type"], s["category"], s["merchant"], s["period_full"],
                   s["pmonth"], s["pday"], s["prange"], alltime, whole_year])
    if not has_new:
        return None

    t = s["type"]
    if not t and ctx:
        t = ctx.get("type")
    # a named merchant/category sets the metric to merchant/category — UNLESS the
    # question is an explicit count ("how many at Amazon" stays a count-of-Amazon).
    if s["merchant"] and t not in ("count", "income", "largest_expense", "smallest_expense", "largest_income"):
        t = "merchant"
    elif s["category"] and t not in ("count", "income", "largest_expense", "smallest_expense", "largest_income"):
        t = "category"
    if not t:
        return None

    _cs = ctx.get("start", "") if ctx else ""
    cy = _cs[:4] if _cs[:4].isdigit() else ""        # carried year (guards MD-/empty markers)
    cym = _cs[:7] if (len(_cs) >= 7 and cy) else (cy + "-01" if cy else "")
    if s["period_full"]:
        start, end = s["period_full"]
    elif whole_year and cy:
        start, end = cy, ""               # widen the thread's period to its full year
    elif alltime:
        start, end = "", ""               # explicit "all time" / "overall" reset
    elif s["prange"] and cy:
        start, end = f"{cy}-{s['prange'][0]}", f"{cy}-{s['prange'][1]}"
    elif s["pmonth"] and s["pday"]:       # explicit day-and-month -> a full calendar date
        start, end = (f"{cy}-{s['pmonth']}-{s['pday']}" if cy
                      else f"MD-{s['pmonth']}-{s['pday']}"), ""   # no year -> that day, all years
    elif s["pmonth"] and cy:
        start, end = f"{cy}-{s['pmonth']}", ""
    elif s["pday"] and cym:
        start, end = f"{cym}-{s['pday']}", ""
    else:
        # No period in THIS question -> inherit the thread's period (all-time if the
        # thread has none). This is the markerless context-carry, made safe by the
        # thread model: a fresh thread has no period to carry.
        start, end = ctx.get("start", ""), ctx.get("end", "")

    cat, mer = s["category"], s["merchant"]
    if t == "category" and not cat and ctx:
        cat = ctx.get("category", "")
    if t == "merchant" and not mer and ctx:
        mer = ctx.get("merchant", "")
    # a bare "how many transactions?" inside a merchant/category thread (nothing new
    # but the count itself) stays scoped to that merchant/category.
    own_period = bool(s["period_full"] or s["pmonth"] or s["pday"] or s["prange"] or whole_year)
    # topic stickiness: a bare metric (spend/count) inside a merchant/category thread
    # inherits that scope — on a continuation, a back-reference, or a markerless turn.
    if t in ("spend", "count") and not mer and not cat and ctx and (cont or refs or not own_period):
        if ctx.get("merchant"):
            mer = ctx["merchant"]
            if t == "spend":
                t = "merchant"
        elif ctx.get("category"):
            cat = ctx["category"]
            if t == "spend":
                t = "category"
    n = s["n"] or (ctx.get("n", 0) if (cont and t == "top_expenses") else 0)
    return {"type": t, "category": cat, "merchant": mer, "n": n,
            "start": start, "end": end, "table": bool(_TABLE_RE.search(q)),
            "count_kind": s.get("count_kind", "")}


def _save_ctx(ctx, intent):
    for k in ("type", "start", "end", "category", "merchant"):
        ctx[k] = intent.get(k, "")
    ctx["n"] = intent.get("n", 0)


# ============================================================ conversational context
# A typed view over the per-thread `ctx` dict. It serialises BACK into the same dict
# (legacy keys: type/start/end/category/merchant/n) so `_resolve_factual`, `_save_ctx`
# and existing chats.json keep working unchanged; new fields are added additively, so
# older chat files (without them) still load. Nothing here invents a number — it only
# tracks WHAT the conversation is about and rewrites elliptical follow-ups so the SQL
# engines always receive a fully-resolved, standalone question.
@dataclass
class ConversationState:
    topic: str = ""            # legacy `type`: merchant|category|count|spend|...
    merchant: str = ""
    category: str = ""
    txn_type: str = ""         # debit|credit|income
    payment_mode: str = ""     # upi (cash/card are not separable in statement data)
    account: str = ""          # doc_name scope (multi-statement)
    start: str = ""            # period start  (YYYY | YYYY-MM | YYYY-MM-DD)
    end: str = ""              # period end
    metric: str = ""           # spend|count|average|extreme|trend|breakdown|top|compare
    filters: dict = field(default_factory=dict)      # {"weekend":True, "txn_type":"debit"}
    comparison: list = field(default_factory=list)   # entities last compared
    sort: str = ""
    limit: int = 0             # legacy `n`
    prev_route: str = ""
    prev_query: str = ""
    prev_entities: list = field(default_factory=list)
    prev_answer: str = ""

    @classmethod
    def from_ctx(cls, ctx):
        c = ctx or {}
        return cls(
            topic=c.get("type", "") or "", merchant=c.get("merchant", "") or "",
            category=c.get("category", "") or "", txn_type=c.get("txn_type", "") or "",
            payment_mode=c.get("payment_mode", "") or "", account=c.get("account", "") or "",
            start=c.get("start", "") or "", end=c.get("end", "") or "",
            metric=c.get("metric", "") or "", filters=dict(c.get("filters") or {}),
            comparison=list(c.get("comparison") or []), sort=c.get("sort", "") or "",
            limit=int(c.get("n") or c.get("limit") or 0),
            prev_route=c.get("prev_route", "") or "", prev_query=c.get("prev_query", "") or "",
            prev_entities=list(c.get("prev_entities") or []), prev_answer=c.get("prev_answer", "") or "")

    def to_ctx(self, ctx):
        """Mutate `ctx` in place — keep legacy keys for backward compat, add new ones."""
        ctx["type"] = self.topic; ctx["merchant"] = self.merchant
        ctx["category"] = self.category; ctx["start"] = self.start; ctx["end"] = self.end
        ctx["n"] = self.limit
        ctx["txn_type"] = self.txn_type; ctx["payment_mode"] = self.payment_mode
        ctx["account"] = self.account; ctx["metric"] = self.metric
        ctx["filters"] = self.filters; ctx["comparison"] = self.comparison
        ctx["sort"] = self.sort; ctx["limit"] = self.limit
        ctx["prev_route"] = self.prev_route; ctx["prev_query"] = self.prev_query
        ctx["prev_entities"] = self.prev_entities; ctx["prev_answer"] = self.prev_answer
        return ctx

    @property
    def entity(self):
        return self.merchant or self.category


def _period_phrase(start, end=""):
    """Human period text for query rewriting: 'in 2024' / 'in May 2024' / 'on YYYY-MM-DD'
    / 'between A and B' — re-parseable by `_parse_period`."""
    if not start:
        return ""
    if end:
        return f"between {ts._plabel(start)} and {ts._plabel(end)}"
    n = len(start)
    if n == 7:
        return f"in {ts._mlabel(start)}"
    if n == 10:
        return f"on {start}"
    return f"in {start}"


# follow-up signals
_METRIC_RE = re.compile(
    r"\b(average|avg|mean|highest|biggest|largest|max(?:imum)?|priciest|lowest|smallest|min(?:imum)?|"
    r"cheapest|monthly|month[- ]?wise|breakdown|by month|trend|trending|top\s*\d*|total|sum|count|"
    r"how many|compare|comparison|versus|\bvs\b|percentage|share|proportion)\b", re.I)
_FILTER_RE = re.compile(
    r"\b(weekend|weekends|weekday|weekdays|only (?:on )?(?:debit|credit)|(?:debit|credit) only|"
    r"just (?:debit|credit))\b", re.I)
_CMP_WORD_RE = re.compile(r"\b(compare|comparison|versus|\bvs\b|against)\b", re.I)
_RESET_RE = re.compile(
    r"\b(reset(?:\s+context)?|start over|starting over|new (?:chat|conversation|topic)|"
    r"forget (?:that|it|this|context|everything|all that)|never ?mind|"
    r"clear (?:the )?(?:context|chat|conversation)|fresh start|change (?:the )?topic)\b", re.I)
_SCOPE_CLEAR_RE = re.compile(
    r"\b(overall|in total|all[- ]time|everything|across (?:all|everything|the account)|"
    r"entire account|whole account|all merchants|all categories|for all|account[- ]wide)\b", re.I)
_NO_ENTITY_INJECT_RE = re.compile(
    r"\b(income|salary|salaries|earn\w*|\bcredit\b|deposit\w*|balance|net worth|inflow|received|"
    r"savings? rate|runway|health|risk|net position)\b", re.I)

# bare-metric follow-ups -> a canonical stem the SQL engines parse
_CANON = [
    (re.compile(r"^\s*(?:what'?s|what is|show|give me|tell me)?\s*(?:the|my)?\s*(?:average|avg|mean)"
                r"(?:\s+(?:amount|value|transaction|spend(?:ing)?|txn|per (?:transaction|txn|order)))?\s*\??$", re.I),
     "average transaction"),
    (re.compile(r"^\s*(?:and|what about|the)?\s*(?:highest|biggest|largest|max(?:imum)?|priciest|"
                r"most expensive|dearest)(?:\s+(?:one|expense|transaction|txn|amount|spend))?\s*\??$", re.I),
     "biggest expense"),
    (re.compile(r"^\s*(?:and|what about|the)?\s*(?:lowest|smallest|min(?:imum)?|cheapest|"
                r"least expensive)(?:\s+(?:one|expense|transaction|txn|amount))?\s*\??$", re.I),
     "smallest expense"),
    (re.compile(r"^\s*(?:and|the)?\s*(?:monthly|month[- ]?wise|by month|per month|breakdown|"
                r"monthly breakdown|month[- ]wise breakdown)\s*\??$", re.I), "monthly breakdown"),
    (re.compile(r"^\s*(?:and|the)?\s*(?:trend|trends|trending|how(?:'s| is) it trending)\s*\??$", re.I),
     "spending trend"),
    (re.compile(r"^\s*(?:and|the)?\s*total\s*\??$", re.I), "total spending"),
    (re.compile(r"^\s*(?:and|the)?\s*(?:count|how many|number of (?:them|transactions)?)\s*\??$", re.I),
     "how many transactions"),
]
_CANON_TOPN = re.compile(r"^\s*(?:and|the)?\s*top\s*(\d+)\s*\??$", re.I)


def _detect_metric(low):
    """The kind of question (for state tracking) — never a number, just intent."""
    if _CMP_WORD_RE.search(low):                                  return "compare"
    if re.search(r"\baverage|avg|mean\b", low):                   return "average"
    if re.search(r"\b(trend|trending)\b", low):                   return "trend"
    if re.search(r"\b(monthly|month[- ]?wise|breakdown|by month)\b", low): return "breakdown"
    if re.search(r"\btop\s*\d", low):                             return "top"
    if re.search(r"\b(how many|count|number of)\b", low):         return "count"
    if re.search(r"\b(biggest|largest|highest|max|smallest|lowest|min|priciest|cheapest)\b", low): return "extreme"
    if re.search(r"\b(total|sum|spend|spent|spending)\b", low):   return "spend"
    return ""


def _resolve_conversation(q, state):
    """Rewrite an elliptical analytics/filter/comparison follow-up into a STANDALONE query
    by injecting the thread's carried scope (merchant/category/period). Returns a dict:
      resolved : the standalone query string to route on
      reset    : the user asked to start over
      changed  : a rewrite happened
      scope    : the merged scope to persist into state (entities of THIS turn)
      signals  : what was injected (for logging)
    Conservative — a fresh thread (no carried scope) is always a passthrough, so single-turn
    suites (golden, 1000-factual) are unaffected; only multi-turn behaviour changes."""
    low = q.lower().strip()
    out = {"resolved": q, "reset": False, "changed": False, "scope": {}, "signals": []}
    if _RESET_RE.search(low):
        out["reset"] = True; out["signals"] = ["reset"]
        return out

    s = _extract_slots(q)
    own_merch, own_cat = s["merchant"], s["category"]
    own_entity = bool(own_merch or own_cat)
    own_period = bool(s["period_full"] or s["pmonth"] or s["pday"] or s["prange"])
    q_ents = _find_merchants(low) + _find_categories(low)
    n_ents = len(set(q_ents))
    scope_clear = bool(_SCOPE_CLEAR_RE.search(low))
    income_ctx = bool(_NO_ENTITY_INJECT_RE.search(low))

    carry_merch, carry_cat = state.merchant, state.category
    carry_entity = carry_merch or carry_cat
    carry_start, carry_end = state.start, state.end

    # ---- merged scope for THIS turn (new overrides carried; persists otherwise) ----
    metric = _detect_metric(low)
    txn_type = ("credit" if re.search(r"\b(credit|deposit|income|received|inflow)\b", low)
                else "debit" if re.search(r"\bdebit\b", low) else "")
    new_merch = own_merch or ("" if (scope_clear or income_ctx) else carry_merch)
    new_cat = own_cat or ("" if (scope_clear or income_ctx or own_merch) else carry_cat)
    # period: mirror _resolve_factual so a bare month/day/range combines with the carried
    # YEAR instead of clearing it ("february?" after "...january 2024" -> 2024-02).
    cy = (carry_start or "")[:4] if (carry_start or "")[:4].isdigit() else ""
    cym = (carry_start or "")[:7] if (len(carry_start or "") >= 7 and cy) else (cy + "-01" if cy else "")
    if s["period_full"]:
        new_start, new_end = s["period_full"]
    elif s["prange"] and cy:
        new_start, new_end = f"{cy}-{s['prange'][0]}", f"{cy}-{s['prange'][1]}"
    elif s["pmonth"] and s["pday"]:
        new_start, new_end = (f"{cy}-{s['pmonth']}-{s['pday']}" if cy
                              else f"MD-{s['pmonth']}-{s['pday']}"), ""
    elif s["pmonth"] and cy:
        new_start, new_end = f"{cy}-{s['pmonth']}", ""
    elif s["pday"] and cym:
        new_start, new_end = f"{cym}-{s['pday']}", ""
    elif scope_clear:
        new_start, new_end = "", ""
    else:
        new_start, new_end = carry_start, carry_end
    out["scope"] = {"merchant": new_merch, "category": new_cat, "start": new_start,
                    "end": new_end, "metric": metric, "txn_type": txn_type}

    # nothing carried -> passthrough (single-turn suites unaffected)
    if not carry_entity and not carry_start:
        return out

    # ---- comparison follow-up: "compare with swiggy" / "vs amazon" ----
    if _CMP_WORD_RE.search(low) and carry_entity and n_ents == 1:
        other = q_ents[0]
        if other.lower() != carry_entity.lower():
            ph = "" if own_period else _period_phrase(carry_start, carry_end)
            out["resolved"] = (f"compare {carry_entity} vs {other}" + (f" {ph}" if ph else "")).strip()
            out["changed"] = True; out["signals"] = [f"compare:{carry_entity}|{other}"]
            out["scope"]["comparison"] = [carry_entity, other]
            return out
    # full comparison (>=2 entities) -> standalone, fall through to passthrough

    # ---- entity/period injection for elliptical metric/filter follow-ups ----
    has_metric = bool(_METRIC_RE.search(low) or _FILTER_RE.search(low))
    has_period_word = bool(re.search(r"\b(year|month|quarter|week|day|annual|monthly|ytd|half)\b", low))
    is_followup = bool(has_metric or _CONT_RE.search(q) or (_REFS_RE.search(q) and not own_entity))
    needs_entity = bool(carry_entity and not own_entity and not scope_clear and not income_ctx)
    # inject a PERIOD phrase only for analytics-metric follow-ups; pure period/factual
    # follow-ups ("february?", "the whole year") keep being carried by _resolve_factual.
    needs_period = bool(carry_start and not own_period and not scope_clear
                        and has_metric and not has_period_word)
    if not is_followup or (not needs_entity and not needs_period):
        return out

    stem = None
    for rx, canon in _CANON:
        if rx.match(low):
            stem = canon; break
    mtop = _CANON_TOPN.match(low)
    if mtop:
        stem = f"top {mtop.group(1)} expenses"
    resolved = stem if stem else q.strip().rstrip("?.! ")

    if needs_entity:
        ent = carry_merch or carry_cat
        resolved = f"{resolved} {'at' if carry_merch else 'on'} {ent}"
        out["signals"].append(f"+entity:{ent}")
        out["scope"]["merchant"] = carry_merch
        out["scope"]["category"] = "" if carry_merch else carry_cat
    if needs_period:
        ph = _period_phrase(carry_start, carry_end)
        if ph:
            resolved = f"{resolved} {ph}"
            out["signals"].append(f"+period:{carry_start}{('..'+carry_end) if carry_end else ''}")
            out["scope"]["start"], out["scope"]["end"] = carry_start, carry_end
    out["resolved"] = resolved
    out["changed"] = resolved.lower() != low
    return out


CONTEXT_RESET_MSG = ("Okay — starting fresh. I've cleared the conversation context. "
                     "What would you like to know about your statement?")


def _log_conv(tid, original, resolved, rinfo, state, before):
    """Structured one-line trace of a context rewrite (only when something was injected)."""
    if not rinfo.get("signals") and original.strip() == (resolved or "").strip():
        return
    try:
        print("[conv] " + json.dumps({
            "tid": tid, "original": original, "resolved": resolved,
            "signals": rinfo.get("signals", []),
            "before": {k: before.get(k, "") for k in ("merchant", "category", "start", "end")},
            "after": {"merchant": state.merchant, "category": state.category,
                      "start": state.start, "end": state.end, "metric": state.metric},
        }, ensure_ascii=False), flush=True)
    except Exception:
        pass


# ---- ANALYTICS layer: ops beyond lookup (compare / average / % / argmax / filter /
#      multi-entity / exclusion). All numbers from SQL — never invented. -----------
_ADVICE_RE = re.compile(
    r"\broast\b|how am i doing|am i doing (?:ok|well|good|bad|fine|alright|great)|"
    r"should i (?:cut|save|spend|reduce|budget)|cut back|cut down|save money|saving enough|"
    r"spending too much|am i (?:broke|rich|overspending|spending)|give me (?:advice|tips)|"
    r"financial advice|help me save|improve my (?:finance|spending|budget|habit)|"
    r"where can i (?:save|cut)|tips to save|how (?:can|do) i save", re.I)

# FINANCE-ANCHORED advisory / judgment / diagnostic phrasing -> grounded LLM reasoning
# over the SQL fact sheet. Deliberately NOT matching (a) precise metric questions ("what
# is my savings rate", "how much did I spend on X"), which stay deterministic, nor (b)
# off-topic/random questions ("recommend a movie") — those go to the router and end up as
# an honest "didn't catch that", never a parroted advice dump. Every alternative below is
# tied to money/spending/income/saving so it can't swallow a random question.
_REASON_RE = re.compile(
    # money recommendations
    r"how (?:can|should|do) i (?:save|invest|budget|cut|reduce|spend less|afford|"
    r"manage (?:my )?(?:money|finances?|budget|spend)|improve (?:my )?(?:finances?|saving|budget))|"
    r"how much (?:can|should) i (?:save|invest|afford|spend|put aside|set aside)|"
    r"where (?:should|can) i (?:cut|save|reduce|invest)|"
    r"can i (?:safely|comfortably) (?:invest|save|afford|spend)|can i afford|"
    r"safe to (?:invest|spend)|safely invest|should i (?:cut|save|spend|reduce|budget|invest)|"
    r"give me (?:financial )?(?:advice|tips)|financial advice|any (?:saving|budget|money|spending) tips|"
    # judgment about THEIR finances
    r"how am i doing(?: financially| with (?:money|saving|spending|my finances?))?|"
    r"am i (?:doing (?:ok|okay|well|good|bad|fine|alright)|on track|overspending|"
    r"saving enough|spending too much|broke|rich|financially)|"
    r"roast my (?:spending|finances?|budget|money)|"
    r"rate my (?:spending|finances?|financial|budget|money|saving)|"
    r"review my (?:spending|finances?|budget|money)|assess my (?:finances?|spending|budget|money)|"
    r"how (?:healthy|risky) (?:is|are) my (?:finances?|spending|money|saving)|"
    r"financially (?:healthy|fit|stable|secure|sound)|how financially|"
    # diagnostic about income / concentration
    r"how (?:dependent|reliant) am i|over[- ]?reliant|too reliant|"
    r"is my income (?:reliable|dependable|stable|secure|safe)|(?:reliable|dependable) income|"
    r"income (?:concentrat|diversif)|"
    # what to limit / what's draining savings
    r"(?:which|what) (?:categor|spending|expense|area)\w*.{0,30}(?:limit|cut|reduce|control|cap|trim|watch)|"
    r"need (?:strict|tighter|some)? ?(?:limits?|to cut|to control|capping)|strict limits?|"
    r"what.?s eating (?:my|into).{0,12}(?:saving|money)|eat\w* into my (?:saving|money)|"
    r"drain\w* my (?:saving|money|account)|what.?s (?:preventing|stopping|keeping) me from saving|"
    # trends / insights / habits / worries (finance-scoped)
    r"what (?:financial )?(?:trends?|patterns?|insights?)|"
    r"\btrends?\b.{0,20}\bobserve|observe.{0,20}\btrends?\b|"
    r"what should i (?:do|change|cut|reduce|prioriti|focus)|what habits|habits.{0,20}(?:reconsider|change)|"
    r"should i (?:worry|be worried|be concerned) about (?:my )?(?:money|spend|finances?|saving)|"
    r"red flags?|anything (?:concerning|worrying|wrong) (?:about )?(?:my )?(?:spend|money|finances?)|"
    # risk analysis
    r"future (?:financial )?risk|financial risk|at risk|risks? to (?:my )?(?:financ|money|saving)|"
    r"(?:suggest|indicate|signal)\w*.{0,25}risk|transactions?.{0,30}\brisk|"
    # financial health / impact
    r"financial(?:ly)? (?:health|wellbeing|fitness|stability)|"
    r"impact on (?:my )?(?:financial health|finances?|savings|money)|biggest impact|"
    # insights / takeaways / hidden patterns
    r"key takeaways?|takeaways?|key (?:points|findings|insights?)|"
    r"most surprising|surprising (?:insight|thing|fact|finding)|\binsights?\b|"
    r"hidden (?:spending )?pattern|spending pattern|pattern.{0,15}i (?:may|might|don.?t|wouldn|never)|"
    r"things? i (?:may|might|don.?t) notice|"
    # monitor / recommend what to watch
    r"what should i (?:monitor|watch|track|look out for|keep an eye)|what to (?:monitor|watch|track)|"
    r"monitor (?:every|each|my|monthly)|keep an eye|watch out for|look out for|"
    # summarise the statement
    r"summar(?:y|ise|ize) (?:of |my )?(?:statement|account|spending|finances?)|"
    r"key takeaways? from my (?:statement|account)|"
    # concept comparisons the deterministic layer can't resolve to known entities
    r"cash (?:withdrawal|vs|versus)|withdrawals?.{0,15}(?:vs|versus|compared)|digital payment|"
    r"online (?:payment|spend|transaction)s?.{0,15}(?:vs|versus)|cash vs|"
    # concentration / diversification
    r"\bconcentrat|diversif|too reliant on (?:a few|one|my)|spread (?:too )?thin|all my eggs|"
    # anomaly detection
    r"unusual|anomal|suspicious|out[- ]of[- ]pattern|larger than (?:normal|usual)|far larger|"
    r"stands? out|\boutlier|abnormal|strange (?:transaction|spend|charge|payment)|anything (?:odd|weird)|"
    # forecasting / projection (narrative; the deterministic what-if is in analytics_answer)
    r"project(?:ed|ion)?|run[- ]?rate|at this (?:rate|pace)|annual (?:spend|spending|saving)|"
    r"next month|how much will i (?:spend|save)|going to (?:spend|save)|on track to|"
    r"this year.{0,15}(?:save|spend)|forecast",
    re.I)

# Any finance signal at all — used to gate the LLM router's "advice" verdict. The 8B
# router sometimes tags a bare "should i <do non-finance thing>" as advice; if the
# question contains NOTHING about money, we refuse to give financial advice and nudge
# instead (so "should i text my ex" doesn't get a savings lecture).
_FIN_RE = re.compile(
    r"money|cash|spen[dt]|saving|\bsave\b|\bsaved\b|invest|budget|income|salary|earn|afford|"
    r"expense|\bcost|financ|categor|merchant|transaction|\btxn|rupee|₹|debt|loan|\bemi\b|"
    r"subscription|\bbill|balance|net worth|\brich\b|broke|overspend|\bpay\b|paying|purchase|"
    r"shopping|grocer|deposit|withdraw|\baccount|statement|cut back|cut down|fund|wealth|"
    r"portfolio|retire|\btax|afford|spend less|monthly|per month", re.I)


def _find_categories(low):
    out = []
    for kw, c in _CAT_SYN.items():
        if re.search(r"\b" + kw + r"\b", low) and c not in out:
            out.append(c)
    return out


def _find_merchants(low):
    out = []
    for m in _known_merchants():
        if re.search(r"\b" + re.escape(m.lower()) + r"\b", low) and m not in out:
            out.append(m)
    return out


def _find_periods(q):
    q = _strip_cmp_amounts(_sub_word_years(q))
    out = []
    for m in _SINGLE_RE.finditer(q):
        one = _norm_one(m.group(0))
        if one and one not in out:
            out.append(one)
    return out


def _parse_amount(low):
    m = re.search(r"(\d[\d,]*(?:\.\d+)?)\s*(lakhs?|lac|crores?|cr|k|thousand|million|mn|m)\b", low)
    if m:
        v = float(m.group(1).replace(",", ""))
        mult = {"lakh": 1e5, "lakhs": 1e5, "lac": 1e5, "crore": 1e7, "crores": 1e7, "cr": 1e7,
                "k": 1e3, "thousand": 1e3, "million": 1e6, "mn": 1e6, "m": 1e6}[m.group(2)]
        return v * mult
    # "<dir> [₹|rs|rupees] <number>[.dd]" — any amount (incl. 3-digit + decimals), but NOT
    # a time span ("over 3 months"), a percentage, or a transaction/order count.
    m = re.search(
        r"(?:over|above|under|below|more than|less than|greater than|bigger than|smaller than|"
        r"exceed\w*|cheaper than|higher than|lower than|at\s?least|atleast|min(?:imum)?|max(?:imum)?)"
        r"\s+(?:₹|rs\.?|inr|rupees?|rupess)?\s*(\d[\d,]*(?:\.\d+)?)"
        r"(?!\s*(?:months?|days?|years?|yrs?|weeks?|wks?|hours?|%|percent|transactions?|txns?|times|orders?))",
        low)
    if m:
        return float(m.group(1).replace(",", ""))
    return None


def analytics_answer(q):
    """Deterministic analytics (compare, average, %, argmax, amount filter, multi-entity,
    exclusion). Returns markdown or None (not an analytics question)."""
    low = q.lower()
    pp = _parse_period(q)
    period, plabel = (ts._norm_period(pp[0], pp[1]) if pp else (None, None))
    sfx = f" in {plabel}" if plabel else ""
    inr, grp = ts.inr, ts.grp
    cats, merchs = _find_categories(low), _find_merchants(low)

    def empty():
        return bool(period) and ts.overview(USER, None, period)["count"] == 0

    def nodata():
        cov = ts.coverage(USER)
        span = f" Your data covers {ts._mlabel(cov[0])}–{ts._mlabel(cov[1])}." if cov else ""
        return f"**No transactions found for {plabel}.**{span}"

    # ---- WHAT-IF (deterministic): "if I cut Shopping by 20%, how much would I save?"
    wif = re.search(r"\b(?:cut|reduce|trim|lower|slash|decreas\w*|drop)\b.*?\bby\s+(\d+(?:\.\d+)?)\s*%", low)
    if wif and (cats or merchs):
        pct = float(wif.group(1)) / 100.0
        nmw = len([1 for _m, d, c, _n in ts.by_month(USER, None, period) if d or c]) or 1
        if cats:
            amt = next((a for c, a, _ in ts.by_category(USER, None, period) if c == cats[0]), 0.0)
            name = cats[0]
        else:
            amt = ts.merchant_spend(USER, merchs[0], None, period)["debit"]; name = merchs[0]
        saved = amt * pct
        return (f"**Cutting {name} by {wif.group(1)}% would save {inr(saved)}{sfx}** — about "
                f"{inr(saved / nmw)}/month, {inr(saved / nmw * 12)}/year. "
                f"({name} is currently {inr(amt)} over {nmw} months.)")

    # ---- FILTERED transactions (weekend / weekday / debit-only / credit-only), scoped
    #      to a merchant/category/period. Powers follow-ups like "only weekends".
    we = re.search(r"\bweekend", low); wd = re.search(r"\bweekday", low)
    deb_only = re.search(r"\b(only (?:on )?debit|debit only|just debit)\b", low)
    cred_only = re.search(r"\b(only (?:on )?credit|credit only|just credit)\b", low)
    if we or wd or deb_only or cred_only:
        if empty():
            return nodata()
        mname = merchs[0] if merchs else None
        cname = cats[0] if cats else None
        weekend = True if we else (False if wd else None)
        ttype = "debit" if deb_only else ("credit" if cred_only else None)
        r = ts.filtered_summary(USER, merchant=mname, category=cname, period=period,
                                weekend=weekend, txn_type=ttype)
        flt = []
        if weekend is True:    flt.append("on weekends")
        elif weekend is False: flt.append("on weekdays")
        if ttype:              flt.append(f"{ttype} only")
        scope = f" at {mname}" if mname else (f" on {cname}" if cname else "")
        return (f"**{grp(r['count'])} transactions{scope}{sfx} ({' · '.join(flt)})** "
                f"— totaling {inr(r['total'])}")

    # ---- 0) FINANCIAL-REASONING questions (savings rate/target, runway, risky
    #         months, consistency, income trend/sources/timing, period compare,
    #         spending profile, habits). Every figure is computed from SQL; the
    #         "advisory" ones are grounded in the user's real numbers, not invented.
    if re.search(r"\bsav|runway|survive|income stop|risky|financially|consisten|stable|steady|"
                 r"volatil|erratic|fluctuat|predictab|\bvary\b|variab|earning|\bincome\b|salary|"
                 r"subscription|recurring|recurr|repeat\w*|lifestyle|personality|\bhabit|shop(?:ping)? online|how often|"
                 r"prevent|stopping me|last\s+\d+\s+months|\btrend\b|spending profile|spending style", low):
        bm = ts.by_month(USER, None, period)            # [(month, debit, credit, count)]
        o0 = ts.overview(USER, None, period)
        mset = [r for r in bm if (r[1] or r[2])]
        nmon0 = len(mset) or 1

        # period-vs-period: "last 6 months vs the previous 6 months"
        mcmp = re.search(r"last\s+(\d+)\s+months?\s+(?:with|to|and|vs\.?|versus|against|compared?\s+(?:to|with))\s+"
                         r"(?:the\s+)?(?:previous|prior|preceding|last|earlier)\s*(\d+)?\s*months?", low)
        if mcmp:
            allm = ts.by_month(USER)
            n1 = int(mcmp.group(1)); n2 = int(mcmp.group(2)) if mcmp.group(2) else n1
            if len(allm) >= n1 + n2:
                rec, prev = allm[-n1:], allm[-(n1 + n2):-n1]
                rd, rc = sum(r[1] for r in rec), sum(r[2] for r in rec)
                pd, pc = sum(r[1] for r in prev), sum(r[2] for r in prev)
                rl = f"{ts._mlabel(rec[0][0])}–{ts._mlabel(rec[-1][0])}"
                pl = f"{ts._mlabel(prev[0][0])}–{ts._mlabel(prev[-1][0])}"
                def pct(a, b):
                    return f"{'+' if a - b >= 0 else ''}{((a - b) / b * 100) if b else 0:.1f}%"
                body = [("Spending", inr(pd), inr(rd), pct(rd, pd)),
                        ("Income", inr(pc), inr(rc), pct(rc, pc)),
                        ("Net savings", inr(pc - pd), inr(rc - rd), pct(rc - rd, pc - pd))]
                return (f"**Last {n1} months ({rl}) vs previous {n2} ({pl})**\n\n"
                        + ts._table(["Metric", "Previous", "Recent", "Change"], body))

        # savings rate
        if re.search(r"\bsav(?:e|ed|es|ing|ings)\b", low) and \
           re.search(r"\b(rate|percent|percentage|%|ratio|proportion)\b", low) and \
           not re.search(r"\b(target|goal|should)\b", low):
            inc, sp = o0["credit"], o0["debit"]
            if inc <= 0:
                return f"**Savings rate{sfx}:** no income recorded."
            saved = inc - sp
            return (f"**Savings rate{sfx}:** {saved / inc * 100:.1f}% — saved {inr(saved)} of "
                    f"{inr(inc)} income (spent {inr(sp)}).")

        # savings target (20% guideline, grounded in their figures)
        if re.search(r"sav(?:ing|ings)?\s+(?:target|goal)|how much should i save|monthly savings target|"
                     r"how much.*should.*save", low):
            inc, sp = o0["credit"], o0["debit"]
            minc, cur = inc / nmon0, (inc - sp) / nmon0
            return (f"**Suggested monthly savings target{sfx}:** {inr(minc * 0.20)} — 20% of your "
                    f"average monthly income ({inr(minc)}). You already save about {inr(cur)}/month "
                    f"({(inc - sp) / inc * 100 if inc else 0:.1f}% of income).")

        # survival runway
        if re.search(r"how (?:long|many months).*(survive|last|go|cover)|\b(runway|emergency fund)\b|"
                     r"if (?:my )?income (?:stop|stopped|stops|dried)|without (?:any )?income|no income", low):
            bal = ts.latest_balance(USER, None, period)
            avg_sp = o0["debit"] / nmon0
            if bal is not None and avg_sp > 0:
                return (f"**Survival runway{sfx}:** about {bal / avg_sp:.1f} months — closing balance "
                        f"{inr(bal)} ÷ average monthly spend {inr(avg_sp)}.")

        # financially risky months (spending > income)
        if re.search(r"\b(risky|risk|overspent|over[-\s]?spent|deficit|in the red)\b", low) and \
           re.search(r"\bmonths?\b", low):
            neg = [(m, c - d_) for m, d_, c, _n in bm if (c - d_) < 0]
            if neg:
                body = ", ".join(f"{ts._mlabel(m)} ({inr(net)})" for m, net in neg)
                return f"**Financially risky months{sfx}** (spending beat income): {body}"
            tight = sorted(((m, c - d_) for m, d_, c, _n in bm), key=lambda r: r[1])[:3]
            body = ", ".join(f"{ts._mlabel(m)} (net {inr(net)})" for m, net in tight)
            return (f"**No risky months{sfx}** — income exceeded spending every month. "
                    f"Tightest: {body}.")

        # spending consistency (coefficient of variation of monthly spend)
        if re.search(r"\b(consisten|stable|steady|volatil|erratic|predictab|fluctuat|regular|vary|variab)\w*", low) \
           and re.search(r"spend|spending|expense", low):
            vals = [d_ for _m, d_, _c, _n in mset]
            if vals:
                mean = sum(vals) / len(vals)
                std = (sum((v - mean) ** 2 for v in vals) / len(vals)) ** 0.5
                cv = (std / mean * 100) if mean else 0
                verdict = ("very consistent" if cv < 10 else "fairly consistent" if cv < 20
                           else "somewhat variable" if cv < 35 else "highly variable")
                return (f"**Spending consistency{sfx}:** {verdict} — averages {inr(mean)}/month, "
                        f"ranging {inr(min(vals))}–{inr(max(vals))} (variation ±{cv:.0f}%).")

        # income trend / growth
        if re.search(r"\b(earning|earnings|income|salary)\b", low) and \
           re.search(r"\b(grow|growing|grew|increas\w*|rising|risen|trend|over time|going up|improv\w*|declin\w*|drop\w*)\b", low):
            creds = [c for _m, _d, c, _n in bm]
            if len(creds) >= 2:
                half = len(creds) // 2
                h1, h2 = sum(creds[:half]), sum(creds[half:])
                if h1 > 0:
                    chg = (h2 - h1) / h1 * 100
                    dirw = "growing" if chg > 2 else "declining" if chg < -2 else "broadly flat"
                    return (f"**Income trend{sfx}:** {dirw} — earlier half {inr(h1)} vs later half "
                            f"{inr(h2)} ({'+' if chg >= 0 else ''}{chg:.1f}%).")

        # income sources / reliability
        if re.search(r"income source|sources? of (?:my )?income|where (?:does|do)\s+(?:my\s+)?(?:income|earnings)\s+come from|"
                     r"\bincome\b.*\b(reliable|sources?|breakdown)\b|\b(reliable|main|primary|biggest)\b.*\bincome\b", low):
            rows = [r for r in ts.income_by_source(USER, None, period) if r[1] > 0]
            if rows:
                body = [(m, inr(c), grp(n)) for m, c, n in rows]
                return f"**Income sources{sfx}**\n\n" + ts._table(["Source", "Received", "Txns"], body)

        # income timing
        if re.search(r"when (?:does|do|is|am i|will).*(income|salary|earn|paid|money|credit|deposit)", low):
            creds = sorted(((m, c) for m, _d, c, _n in bm if c > 0), key=lambda r: r[1], reverse=True)
            if creds:
                body = ", ".join(f"{ts._mlabel(m)} ({inr(c)})" for m, c in creds[:3])
                return f"**When income arrives{sfx}:** biggest income months are {body}."

        # spending profile / personality / lifestyle
        if re.search(r"spending personality|describe my spend|what does my spending say|lifestyle|"
                     r"spending profile|spending style|kind of spender|type of spender", low):
            rows = ts.by_category(USER, None, period)
            tot = sum(a for _c, a, _n in rows) or 1
            if rows:
                parts = ", ".join(f"{c} ({a / tot * 100:.0f}%)" for c, a, _n in rows[:3])
                return (f"**Your spending profile{sfx}:** dominated by {parts}. Top category is "
                        f"{rows[0][0]} at {inr(rows[0][1])} of {inr(tot)} total spending.")

        # what's preventing me from saving -> biggest outflows
        if re.search(r"prevent.*sav|stop\w*.*sav|why can.?t i save|what.?s stopping|keeping me from saving|"
                     r"hard(?:er)? to save", low):
            rows = ts.by_category(USER, None, period)
            if rows:
                body = ", ".join(f"{c} ({inr(a)})" for c, a, _n in rows[:3])
                return (f"**What's eating your savings{sfx}:** biggest outflows are {body}. Total "
                        f"spending {inr(o0['debit'])} against {inr(o0['credit'])} income.")

        # habits to reconsider / change first -> biggest flexible categories
        if re.search(r"\bhabit", low) or re.search(r"(reconsider|change first|cut down|trim)", low):
            rows = ts.by_category(USER, None, period)
            disc = sorted([(c, a) for c, a, _n in rows
                           if c in ("Shopping", "Food & Dining", "Entertainment", "Transport")],
                          key=lambda r: r[1], reverse=True)
            if disc:
                body = ", ".join(f"{c} ({inr(a)})" for c, a in disc[:3])
                return (f"**Spending habits worth reviewing{sfx}:** your largest flexible categories "
                        f"are {body} — usually the easiest to trim.")

        # subscriptions: cost-trend ("which increased?") vs plain recurring-bill list
        if re.search(r"\bsubscription|recurring|recurr|repeat\w*", low):
            if re.search(r"increas|rose|risen|rising|went up|gone up|grew|growing|more expensive|"
                         r"cost.*chang|chang.*cost|decreas|dropp|fell|cheaper|\btrend\b|over time", low):
                tr = ts.subscription_trends(USER, None, period)
                up = [(m, a1, a2, c) for m, a1, a2, c in tr if c > 1]
                if up:
                    body = [(m, inr(a1), inr(a2), f"+{c:.0f}%") for m, a1, a2, c in up]
                    return ("**Subscriptions that increased in cost** (avg ₹/month: first half → second half)\n\n"
                            + ts._table(["Subscription", "Was", "Now", "Change"], body))
                if tr:
                    body = [(m, inr(a1), inr(a2), f"{'+' if c >= 0 else ''}{c:.0f}%") for m, a1, a2, c in tr]
                    return ("**No subscription rose meaningfully** — monthly cost is stable across the "
                            "period. Full trend (avg ₹/month: first half → second half):\n\n"
                            + ts._table(["Subscription", "Was", "Now", "Change"], body))
            det = ts.dispatch_intent({"type": "subscriptions", "start": "", "end": ""}, USER)
            if det:
                return det

        # online shopping frequency
        if re.search(r"shop(?:ping)? online|online shop|how often.*shop", low):
            for c, a, n in ts.by_category(USER, None, period):
                if c == "Shopping":
                    return (f"**Online shopping{sfx}:** {grp(n)} Shopping transactions totalling "
                            f"{inr(a)} (about {n // nmon0} a month).")

    # 1) PERCENT / share of total
    if re.search(r"percent|percentage|%|\bshare\b|fraction|proportion", low) and (cats or merchs):
        if empty():
            return nodata()
        tot = ts.overview(USER, None, period)["debit"] or 1
        if cats:
            amt = next((a for c, a, _ in ts.by_category(USER, None, period) if c == cats[0]), 0.0)
            name = cats[0]
        else:
            amt = ts.merchant_spend(USER, merchs[0], None, period)["debit"]
            name = merchs[0]
        return f"**{name}{sfx}:** {inr(amt)} — **{amt/tot*100:.1f}%** of total spending ({inr(tot)})"

    # 2) EXCLUSION
    if re.search(r"\b(excluding|except|other than|without|besides|apart from|minus|not counting)\b", low) and cats:
        if empty():
            return nodata()
        tot = ts.overview(USER, None, period)["debit"]
        amt = next((a for c, a, _ in ts.by_category(USER, None, period) if c == cats[0]), 0.0)
        return (f"**Spending{sfx} excluding {cats[0]}:** {inr(tot - amt)}  "
                f"(total {inr(tot)} − {cats[0]} {inr(amt)})")

    # 2b) COUNT of transactions above/below a THRESHOLD or the (scoped) AVERAGE.
    #     "how many transactions over 500", "no. of transactions above the average on zomato".
    #     Must precede the AVERAGE branch (which also matches "average").
    _dir_over = re.search(r"\b(above|over|greater than|more than|bigger than|exceed\w*|higher than|at\s?least|atleast)\b", low)
    _dir_under = re.search(r"\b(below|under|less than|smaller than|cheaper than|lower than)\b", low)
    _is_count = bool(re.search(r"\b(how many|number of|no\.?\s*of|count(?:\s+of)?|num\b)\b", low)
                     or re.search(r"\btransactions?\b.{0,40}\b(above|over|below|under|greater|more|less|exceed)", low))
    _wants_avg = re.search(r"\b(average|avg|mean)\b", low)
    _thr = _parse_amount(low)
    if _is_count and (_dir_over or _dir_under) and (_thr is not None or _wants_avg):
        if empty():
            return nodata()
        op = "under" if (_dir_under and not _dir_over) else "over"
        mname = merchs[0] if merchs else None
        cname = cats[0] if cats else None
        if _thr is not None:
            threshold, tlabel = _thr, inr(_thr)
        else:                                            # threshold = the scoped average
            if mname:
                r0 = ts.merchant_spend(USER, mname, None, period)
                threshold = (r0["debit"] / r0["dcount"]) if r0["dcount"] else 0.0
            elif cname:
                amt0 = cnt0 = 0
                for c, a, n in ts.by_category(USER, None, period):
                    if c == cname:
                        amt0, cnt0 = a, n
                        break
                threshold = (amt0 / cnt0) if cnt0 else 0.0
            else:
                o0 = ts.overview(USER, None, period)
                dc0 = ts.txn_count(USER, "debit", None, period)
                threshold = (o0["debit"] / dc0) if dc0 else 0.0
            tlabel = f"the average {inr(threshold)}"
        if threshold <= 0:
            return nodata()
        r = ts.amount_filter(USER, op, threshold, None, period, merchant=mname, category=cname)
        scope = f" at {mname}" if mname else (f" on {cname}" if cname else "")
        return (f"**{grp(r['count'])} transactions{scope}{sfx} {op} {tlabel}** "
                f"— totaling {inr(r['total'])}")

    # 3) AVERAGE (per month / per transaction) — scoped to a named merchant/category
    #    if one is present, else the whole account.
    if re.search(r"\b(average|avg|mean)\b", low):
        if empty():
            return nodata()
        per_txn = bool(re.search(r"per (?:transaction|txn|purchase|order|swipe|payment)|each (?:transaction|order|purchase)|a transaction|per[- ]txn", low)
                       or (re.search(r"transaction|txn|purchase|order", low) and not re.search(r"month", low)))
        nmon = len([1 for _m, d, c, _n in ts.by_month(USER, None, period) if d or c]) or 1
        if merchs:                                   # "average transaction at Zomato" / monthly at X
            r = ts.merchant_spend(USER, merchs[0], None, period)
            if r["count"] == 0:
                return f"**No transactions found for '{merchs[0]}'{sfx}.**"
            if per_txn:
                return (f"**Average transaction at {merchs[0]}{sfx}:** {inr(r['debit']/r['count'])}  "
                        f"(over {grp(r['count'])} transactions)")
            return (f"**Average monthly spend at {merchs[0]}{sfx}:** {inr(r['debit']/nmon)}  "
                    f"(over {nmon} months)")
        if cats:                                     # "average monthly spend on Groceries"
            amt = cnt = 0
            for c, a, n in ts.by_category(USER, None, period):
                if c == cats[0]:
                    amt, cnt = a, n
                    break
            if per_txn:
                return (f"**Average {cats[0]} transaction{sfx}:** {inr(amt/cnt) if cnt else inr(0)}  "
                        f"(over {grp(cnt)} transactions)")
            return (f"**Average monthly spend on {cats[0]}{sfx}:** {inr(amt/nmon)}  "
                    f"(over {nmon} months)")
        o = ts.overview(USER, None, period)          # whole-account average
        if per_txn:
            dc = ts.txn_count(USER, "debit", None, period)   # average over DEBIT txns, not all rows
            if dc == 0:
                return nodata()
            return f"**Average transaction{sfx}:** {inr(o['debit']/dc)}  (over {grp(dc)} expenses)"
        return f"**Average monthly spend{sfx}:** {inr(o['debit']/nmon)}  (over {nmon} months)"

    # 4) WHICH MONTH (argmax / argmin)
    if re.search(r"\b(which|what)\b.*\bmonth\b", low) or \
       (re.search(r"\bmonth\b", low) and re.search(r"\b(most|least|highest|lowest|max|min|biggest|smallest)\b", low)):
        if empty():
            return nodata()
        bm = ts.by_month(USER, None, period)
        if bm:
            least = bool(re.search(r"\b(least|lowest|min|smallest|fewest)\b", low))
            if re.search(r"\b(transactions?|txns?|count|purchases?|busiest|active)\b", low):
                rows = [(m, n) for m, _d, _c, n in bm]
                m, v = (min if least else max)(rows, key=lambda r: r[1])
                return (f"**{'Fewest' if least else 'Most'}-transaction month{sfx}:** "
                        f"{ts._mlabel(m)} — {grp(v)} transactions")
            if re.search(r"\b(receiv\w*|credit\w*|income|deposit\w*|earn\w*|inflow|salary)\b", low):
                rows = [(m, c) for m, _d, c, _n in bm]
                m, v = (min if least else max)(rows, key=lambda r: r[1])
                return f"**{'Lowest' if least else 'Highest'}-income month{sfx}:** {ts._mlabel(m)} — {inr(v)}"
            rows = [(m, d) for m, d, _c, _n in bm]
            m, v = (min if least else max)(rows, key=lambda r: r[1])
            return f"**{'Lowest' if least else 'Highest'}-spend month{sfx}:** {ts._mlabel(m)} — {inr(v)}"

    # 5) TOP / BIGGEST CATEGORY
    if re.search(r"\b(top|biggest|largest|highest|main|number one|#1|least|lowest|smallest|fewest)\b[^?]*\bcategor", low) or \
       re.search(r"\bcategor[^?]*\b(most|biggest|largest|highest|least|lowest|smallest|fewest)\b", low) or \
       re.search(r"what do i spend (?:the )?most on|where (?:does|do) (?:most of )?my money go", low):
        if empty():
            return nodata()
        rows = ts.by_category(USER, None, period)
        if rows:
            tot = sum(a for _, a, _ in rows) or 1
            least = bool(re.search(r"\b(least|lowest|smallest)\b", low))
            c, a, n = rows[-1] if least else rows[0]
            return (f"**{'Smallest' if least else 'Top'} spending category{sfx}:** "
                    f"{c} — {inr(a)} ({a/tot*100:.0f}%, {grp(n)} txns)")

    # 6) TOP MERCHANT(S)
    if re.search(r"\btop\s+\d*\s*merchant|biggest merchant|favou?rite merchant|"
                 r"most[^?]*\bmerchant|merchant[^?]*\bmost\b|who do i spend the most", low):
        if empty():
            return nodata()
        nm = re.search(r"top\s+(\d+)", low)
        n = int(nm.group(1)) if nm else 5
        rows = ts.top_merchants(USER, n, None, period)
        if rows:
            if not nm or n == 1:
                c, a, cnt = rows[0]
                return f"**Top merchant{sfx}:** {c} — {inr(a)} across {grp(cnt)} transactions"
            body = [(i + 1, c, inr(a), grp(cnt)) for i, (c, a, cnt) in enumerate(rows)]
            return f"**Top {len(rows)} merchants{sfx}**\n\n" + ts._table(["#", "Merchant", "Spent", "Txns"], body)

    # 7) AMOUNT FILTER (optionally scoped to a merchant / category)
    amt = _parse_amount(low)
    if amt and re.search(r"\b(over|above|more than|greater than|bigger than|exceed\w*|higher than|"
                         r"under|below|less than|smaller than|cheaper than|lower than)\b", low):
        if empty():
            return nodata()
        op = "under" if re.search(r"\b(under|below|less than|smaller than|cheaper than|lower than)\b", low) else "over"
        mname = merchs[0] if merchs else None
        cname = cats[0] if cats else None
        r = ts.amount_filter(USER, op, amt, None, period, merchant=mname, category=cname)
        scope = f" at {mname}" if mname else (f" on {cname}" if cname else "")
        return (f"**{grp(r['count'])} transactions{scope}{sfx} {op} {inr(amt)}** — totaling {inr(r['total'])}")

    # 8) MULTI-ENTITY (two+ merchants/categories combined)
    combine = re.search(r"\b(together|combined|total of|both|sum of|plus|altogether)\b", low)
    if len(merchs) >= 2 and (combine or not re.search(r"\bor\b|more|less|vs\b|versus|compare|than", low)):
        if empty():
            return nodata()
        parts = [(m, ts.merchant_spend(USER, m, None, period)["debit"]) for m in merchs[:4]]
        tot = sum(a for _, a in parts)
        return (f"**{' + '.join(m for m, _ in parts)}{sfx}:** {inr(tot)}  ("
                + ", ".join(f"{m} {inr(a)}" for m, a in parts) + ")")
    if len(cats) >= 2 and combine and not re.search(r"\bor\b|more|less|vs\b|versus|compare|than", low):
        if empty():
            return nodata()
        cmap = {c: a for c, a, _ in ts.by_category(USER, None, period)}
        parts = [(c, cmap.get(c, 0.0)) for c in cats[:4]]
        tot = sum(a for _, a in parts)
        return (f"**{' + '.join(c for c, _ in parts)}{sfx}:** {inr(tot)}  ("
                + ", ".join(f"{c} {inr(a)}" for c, a in parts) + ")")

    # 9) COMPARE / DIFFERENCE (two periods, or two categories/merchants)
    if re.search(r"\b(more|less|higher|lower|difference|compare|versus|vs|than)\b|\bor\b", low):
        periods = _find_periods(q)
        if len(periods) >= 2:
            a, b = periods[0], periods[1]
            sa = ts.overview(USER, None, a)["debit"]
            sb = ts.overview(USER, None, b)["debit"]
            diff = sa - sb
            rel = "more" if diff >= 0 else "less"
            pct = abs(diff) / (sb or 1) * 100
            return (f"**{ts._plabel(a)}:** {inr(sa)}  vs  **{ts._plabel(b)}:** {inr(sb)}\n\n"
                    f"You spent **{inr(abs(diff))} {rel}** in {ts._plabel(a)} ({pct:.0f}% {rel}).")
        if len(cats) >= 2:
            if empty():
                return nodata()
            cmap = {c: a for c, a, _ in ts.by_category(USER, None, period)}
            va, vb = cmap.get(cats[0], 0.0), cmap.get(cats[1], 0.0)
            hi = cats[0] if va >= vb else cats[1]
            return (f"**{cats[0]}{sfx}:** {inr(va)}  vs  **{cats[1]}:** {inr(vb)}\n\n"
                    f"You spent more on **{hi}** (by {inr(abs(va - vb))}).")
        if len(merchs) >= 2:
            if empty():
                return nodata()
            va = ts.merchant_spend(USER, merchs[0], None, period)["debit"]
            vb = ts.merchant_spend(USER, merchs[1], None, period)["debit"]
            hi = merchs[0] if va >= vb else merchs[1]
            return (f"**{merchs[0]}{sfx}:** {inr(va)}  vs  **{merchs[1]}:** {inr(vb)}\n\n"
                    f"You spent more at **{hi}** (by {inr(abs(va - vb))}).")
    return None


_FUP_ATTR = re.compile(r"^\s*(which|who|whom|why|when|where|whose)\b", re.I)


@app.get("/chats")
async def chats():
    """Return all saved chat threads from data/chats.json."""
    try:
        with open(CHAT_LOG, encoding="utf-8") as f:
            return JSONResponse(json.load(f))
    except Exception:
        return JSONResponse({})


# ---- ML-backed chat answers: anomaly + spend forecast via the sklearn models --------
# These produce EXACT figures from the data (IsolationForest / LinearRegression over SQL
# rows) — no LLM, so no hallucination. Routed before the advice gate so "any unusual
# transactions?" / "forecast next month" hit the model, not a narrative fallback.
_ANOM_RE = re.compile(
    r"unusual|anomal|suspicious|out[- ]of[- ]pattern|larger than (?:normal|usual)|far larger|"
    r"stands? out|\boutlier|abnormal|strange (?:transaction|spend|charge|payment)|"
    r"anything (?:odd|weird)|\bflag\b|fraud|irregular", re.I)
_FCAST_RE = re.compile(
    r"\bforecast|\bpredict|next month|coming month|next few months|expected (?:to )?spend|"
    r"how much will i (?:likely )?spend (?:next|in the coming)|what will i spend", re.I)
# run-rate annual projection -> deterministic (avoids the LLM recomputing x12 / leaking)
_PROJ_RE = re.compile(
    r"\b(?:annual|yearly|per year|a year|run[- ]?rate)\b|at this (?:rate|pace)|"
    r"this year.{0,20}(?:save|saving|spend)|(?:save|spend)\w*.{0,20}this year", re.I)


def ml_answer(q):
    """Anomaly / forecast questions -> the sklearn models. Deterministic figures from the
    data. Returns markdown, or None if not applicable / not enough data."""
    low = q.lower()
    if _ANOM_RE.search(low):
        r = _ml("anom", lambda: ml.anomalies(USER))
        items = r.get("items", [])
        scanned = ts.grp(r.get("trained_on", 0))
        if not items:
            return (f"**No standout anomalies.** I ran an anomaly model over {scanned} expenses and "
                    f"nothing deviates strongly from your usual pattern.")
        body = [(it["date"], it["merchant"], ts.inr(it["amount"]), it["reason"]) for it in items]
        return (f"**Unusual transactions** — flagged by the anomaly model out of {scanned} expenses "
                f"(largest first):\n\n"
                + ts._table(["Date", "Merchant", "Amount", "Why flagged"], body))
    if _FCAST_RE.search(low):
        r = _ml("fc", lambda: ml.forecast(USER))
        t = r.get("total")
        if not t:
            return None
        rows = [(c["name"], ts.inr(c["predicted"]), c["trend"]) for c in r["per_category"][:8]]
        return (f"**Spend forecast for {r['next_month']}** — projected total **{ts.inr(t['predicted'])}** "
                f"(likely range {ts.inr(t['lo'])}–{ts.inr(t['hi'])}), from a per-category linear trend:\n\n"
                + ts._table(["Category", "Predicted next month", "Trend"], rows))
    if _PROJ_RE.search(low):
        o = ts.overview(USER); nm = max(len(ts.months_list(USER)), 1)
        msp, mnet = o["debit"] / nm, o["net"] / nm
        return (f"**Run-rate projection** (at your current pace): annual spending about "
                f"**{ts.inr(msp * 12)}** and annual net savings about **{ts.inr(mnet * 12)}** — "
                f"based on a {ts.inr(msp)} average monthly spend over {nm} months.")
    return None


# ===================================================== financial-intelligence layer
# Health Score, Risk Engine, Behavioural Analytics, Transaction Impact, Category
# Trend, auto-Recurring and the pre-computed Insight digest. Each handler renders a
# deterministic answer whose every figure came from txn_store SQL — the LLM is not
# in this path, so these can never hallucinate a number.

_HEALTH_RE = re.compile(
    r"financ\w* health|how healthy|health score|health check|rate my (?:money|finances?|spending|financial|budget)|"
    r"financial report card|report card|money management|how (?:am i|are my finances?) doing|"
    r"how good (?:are|is) my (?:finances?|money)|grade my (?:finances?|money|spending)|"
    r"score my (?:finances?|money|spending)", re.I)
_RISK_RE = re.compile(
    r"what (?:are |financial )?(?:my )?risks?|any risks?|risks? (?:do you see|in my|should i|am i)|"
    r"what should i worry|should i (?:be )?worr|am i overspending|am i at risk|red flags?|warning signs?|"
    r"what.{0,20}worry about|financial(?:ly)? (?:at )?risk|in danger|money (?:risks?|danger)", re.I)
_RECUR_RE = re.compile(
    r"subscription|recurring|recurr\w*|standing instruction|auto[- ]?debit|"
    r"repeat(?:ed|ing)? (?:payment|charge|bill)|regular (?:payment|bill|charge)s?|"
    r"what (?:do i pay|am i paying).{0,25}(?:every|each) month|monthly (?:bill|commitment)s?", re.I)
_BEHAVE_RE = re.compile(
    r"spending (?:habit|behaviou?r|personality|style|pattern of)|\bhabits?\b|behaviou?r|"
    r"weekend (?:spend|vs|versus)|do i overspend on weekend|impuls\w*|"
    r"end of (?:the )?month|month[- ]end|am i an? (?:impulsive|big|frequent) spender|how do i spend", re.I)
_IMPACT_RE = re.compile(
    r"(?:which|what)\b.{0,30}\btransactions?\b.{0,30}(?:impact|affect|hurt|hit|matter|biggest|most|moved|damage)|"
    r"biggest impact|most impact(?:ful)?|transaction impact|high[- ]impact|impact (?:on|to) my (?:finances?|health)|"
    r"which (?:expenses?|purchases?)\b.{0,25}(?:hurt|matter|biggest|impact)", re.I)
_CATTREND_RE = re.compile(
    r"categor\w+.{0,30}(?:grow|growing|rising|risen|fastest|out of control|increasing|spiral|trend)|"
    r"which (?:categor\w+|expenses?|spending).{0,25}(?:grow|growing|rising|fastest|out of control|getting|increas)|"
    r"fastest[- ]growing|getting out of (?:hand|control)|spiralling|spiraling|"
    r"what.{0,20}(?:expenses?|spending|categor\w+).{0,20}out of control", re.I)
_PATTERN_RE = re.compile(
    r"what patterns?|spending patterns?|patterns? (?:do you|in my|you see|emerge|here)|"
    r"what (?:do you )?(?:notice|observe|see)\b|any (?:insights?|patterns?)|key insights?|what insights?|"
    r"what stands out|anything (?:interesting|notable)|what can you tell me about my (?:spending|finances?|statement|money)", re.I)
# A recurring-style question that's really a cost-trend or advice ask -> let the
# existing subscription-trend / grounded-advice paths handle it, not the auto-detector.
_RECUR_DEFER = re.compile(
    r"increas|rose|went up|grew|gone up|climb|more expensive|trend|chang|cancel|"
    r"should i|\bcut\b|reduce|lower|trim|save money|get rid", re.I)


def health_answer(q):
    h = ts.health_score(USER)
    if not h:
        return None
    comp = h["components"]
    strongest = max(comp, key=comp.get)
    weakest = min(comp, key=comp.get)
    kept = h["months"] - h["overspent_months"]
    body = [(k, f"{v} / 25") for k, v in comp.items()]
    return (f"**Financial health: {h['rating']} — {h['score']}/100.**\n\n"
            f"You save **{h['savings_rate']:.0f}%** of income and kept spending within income in "
            f"**{kept} of {h['months']}** months. Your strongest pillar is **{strongest.lower()}**; "
            f"your weakest is **{weakest.lower()}** — your top income source is "
            f"**{h['income_dependence']:.0f}%** of earnings and your top 5 merchants are "
            f"**{h['merchant_concentration']:.0f}%** of spending.\n\n"
            + ts._table(["Pillar (max 25)", "Score"], body))


def risk_answer(q):
    r = ts.risk_assessment(USER)
    if not r:
        return None
    if not r["flags"]:
        return (f"**Risk level: {r['risk_level']} — {r['risk_score']}/100.** No major structural "
                "risks — your savings rate, income mix and month-to-month spending are all in a "
                "healthy range. The main thing to watch as your finances grow is concentration.")
    body = [(f["rule"], f["detail"]) for f in r["flags"]]
    return (f"**Risk level: {r['risk_level']} — {r['risk_score']}/100.** "
            f"I flagged **{len(r['flags'])}** structural risk factor(s), heaviest first:\n\n"
            + ts._table(["Risk factor", "What I see"], body))


def recurring_answer(q):
    # Cost-trend ("which increased?") or advice ("should I cancel?") -> not the
    # auto-detector; return None so the subscription-trend / advice paths run.
    if _RECUR_DEFER.search(q.lower()):
        return None
    r = _ml("recur", lambda: ml.recurring(USER))
    items = r.get("items", [])
    if items:
        body = [(it["merchant"], it["cadence"], ts.inr(it["amount"]), ts.grp(it["count"]),
                 f"{int(round(it['confidence'] * 100))}%") for it in items[:15]]
        newly = r.get("newly_found", [])
        note = (f"\n\n_Auto-detected from your transactions (no preset list); surfaced beyond the "
                f"obvious: {', '.join(newly[:6])}._" if newly
                else "\n\n_Auto-detected from your transactions — no preset merchant list used._")
        return ("**Recurring charges & subscriptions** — payments that repeat at a regular cadence "
                "and similar amount:\n\n"
                + ts._table(["Merchant", "Cadence", "Typical amount", "Times", "Confidence"], body)
                + note)
    # Auto-detector found no stable cadence (e.g. amounts vary too much) -> fall back to
    # the known-subscription view so the answer is still useful, never worse than before.
    rec = ts.subscription_costs(USER)
    rec = [(m, mo, t, c) for m, mo, t, c in rec if mo]
    if rec:
        per_month = sum(t / mo for _m, mo, t, _c in rec)
        body = [(m, ts.grp(mo), ts.inr(t), ts.inr(t / mo)) for m, mo, t, _c in rec]
        return (f"**Recurring bills & subscriptions** — about {ts.inr(per_month)} every month:\n\n"
                + ts._table(["Merchant", "Months", "Total", "Avg / month"], body)
                + "\n\n_No single fixed-cadence pattern stood out in the raw transactions, so this is "
                "your known-subscription view._")
    return ("**No recurring charges or subscriptions detected.** Nothing repeats at a steady cadence "
            "and stable amount, and no known subscription merchants appear in your statement.")


def behavior_answer(q):
    b = ts.behavior_metrics(USER)
    if not b:
        return None
    rows = [
        ("Weekend vs weekday",
         f"{ts.inr(b['weekend_per_day'])}/day on weekends vs {ts.inr(b['weekday_per_day'])}/day midweek "
         f"({b['weekend_ratio']:.1f}×)"),
        ("Month-end vs month-start",
         f"{ts.inr(b['eom_spend'])} in the last third of the month vs {ts.inr(b['som_spend'])} in the "
         f"first ({b['eom_ratio']:.1f}×)"),
        ("Small / impulse spends",
         f"{ts.grp(b['small_count'])} of {ts.grp(b['debit_count'])} debits ({b['impulse_share']:.0f}%) "
         f"are under {ts.inr(b['small_threshold'])}"),
    ]
    if b["top_merchant"]:
        rows.append(("Merchant dependency",
                     f"{b['top_merchant']} alone is {b['top_merchant_share']:.0f}% of your spending"))
    if b["weekend_ratio"] >= 1.3:
        v = "weekend-heavy"
    elif b["eom_ratio"] >= 1.3:
        v = "back-loaded toward month-end"
    elif b["impulse_share"] >= 50:
        v = "driven by lots of small, frequent spends"
    else:
        v = "fairly even — no strong weekend, month-end or impulse skew"
    return (f"**Your spending behaviour looks {v}.**\n\n"
            + ts._table(["Behaviour", "What the data shows"], rows))


def impact_answer(q):
    m = re.search(r"\b(\d{1,2})\b", q)
    n = max(1, min(int(m.group(1)), 10)) if m else 5
    items = ts.transaction_impact(USER, n)
    if not items:
        return None
    body = [(it["date"], it["merchant"], ts.inr(it["amount"]),
             ("+" if it["direction"] == "credit" else "−") + str(abs(it["impact"]))) for it in items]
    return ("**The transactions with the biggest impact on your finances** — impact scores each "
            "transaction's size against your largest, signed by direction (+ inflow, − outflow):\n\n"
            + ts._table(["Date", "Merchant", "Amount", "Impact"], body))


def cattrend_answer(q):
    low = q.lower()
    window = 6 if re.search(r"\b(?:6|six)\b", low) else \
        12 if re.search(r"\b(?:12|twelve|year|annual)\b", low) else 3
    ct = ts.category_trend(USER, window)
    if not ct or not ct["movers"]:
        return None
    body = [(mv["category"], ts.inr(mv["prior_avg"]), ts.inr(mv["recent_avg"]),
             ts._pct(mv["recent_avg"], mv["prior_avg"])) for mv in ct["movers"][:8]]
    wl = f"{ct['window']}-month"
    return (f"**Category trends — prior {wl} average → recent {wl} average per month** "
            "(fastest-growing first):\n\n"
            + ts._table(["Category", "Was / mo", "Now / mo", "Change"], body))


def insights_answer(q):
    """Pre-computed insight digest (the Insight Engine surface). Reads stored
    insights; falls back to a live compute when none have been persisted yet."""
    items = ts.get_insights(USER) or ts.compute_insights(USER)
    if not items:
        return None
    order = {"risk": 0, "pattern": 1, "behavior": 2, "impact": 3, "health": 4}
    items = sorted(items, key=lambda it: (order.get(it["type"], 9), -(it.get("score") or 0)))
    lines = ["**Here's what stands out in your statement:**", ""]
    for it in items[:8]:
        lines.append(f"- **{it['title']}** — {it['explanation']}")
    lines += ["", "_Drill in with \"how healthy am I?\", \"what risks do you see?\", "
              "\"what subscriptions do I have?\" or \"what spending habits do I have?\"._"]
    return "\n".join(lines)


def intelligence_answer(q):
    """Dispatch to the pre-computed intelligence engines. Returns markdown or None
    (None -> the question wasn't one of these, so the normal cascade continues)."""
    low = q.lower()
    # Impact is checked before Health: "which transactions hurt my financial health"
    # mentions 'health' but is really an impact question. Impact needs the word
    # "transaction(s)", so it never steals a genuine health question.
    if _IMPACT_RE.search(low):
        return impact_answer(q)
    if _HEALTH_RE.search(low):
        return health_answer(q)
    # "which/what months were risky" wants a per-month breakdown, not the overall
    # risk score -> let the analytics risky-months handler take it.
    if _RISK_RE.search(low) and not re.search(r"(?:which|what)\b.{0,25}month", low):
        return risk_answer(q)
    if _RECUR_RE.search(low):
        return recurring_answer(q)
    if _CATTREND_RE.search(low):
        return cattrend_answer(q)
    if _BEHAVE_RE.search(low):
        return behavior_answer(q)
    if _PATTERN_RE.search(low):
        return insights_answer(q)
    return None


@app.post("/query")
async def query(request: Request):
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
    if ts.overview(USER)["count"] == 0:
        return stream_text("chat", "_Upload a statement first._")

    # Punctuation-only / no-letters input ("...", "???", "!!!") can never be a real
    # question -> short nudge, never the insights dump. (ऀ-ॿ = Devanagari,
    # so Hindi-script input still passes through to the router.)
    if not re.search(r"[A-Za-z0-9ऀ-ॿ]", q):
        _append_log(tid, q, DIDNT_CATCH, "chat")
        return stream_text("chat", DIDNT_CATCH)

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

    # 0) follow-up ABOUT the previous answer ("which merchant was that?", "why?")
    #    -> answer from conversation, do NOT run a new query. (uses the ORIGINAL q.)
    if ctx and _FUP_ATTR.search(q) and _REFS_RE.search(q) and not _resolve_factual(q, ctx) \
            and not analytics_answer(q):
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
    #         category-trend / behaviour / pattern digest) — deterministic, every
    #         number from SQL. Runs before the advice gate so these get the precise
    #         scored answer, not an LLM narrative.
    intans = intelligence_answer(rq)
    if intans is not None:
        remember(history, q, intans)
        _append_log(tid, q, intans, "SQL")
        return stream_text("SQL", intans)

    # 0b) advice / judgment / open-ended reasoning ("roast my spending", "should I cut
    #     back", "how dependent am I on one income source", "what trends do you see")
    #     -> a real LLM answer reasoned over the SQL fact sheet (numbers verified).
    if _ADVICE_RE.search(rq) or _REASON_RE.search(rq):
        remember(history, q, "(financial advice given)")
        return grounded_advice(rq, tid)

    # 0c) ANALYTICS (compare / average / % / argmax / amount filter / multi-entity /
    #     exclusion) — deterministic, numbers from SQL.
    aa = analytics_answer(rq)
    if aa is not None:
        remember(history, q, aa)
        _append_log(tid, q, aa, "SQL")
        return stream_text("SQL", aa)

    # 1) DETERMINISTIC factual resolution (standalone + thread context carry).
    det = _resolve_factual(rq, ctx)
    if det and det.get("type"):
        ans = ts.dispatch_intent(det, USER)
        if ans is not None:
            _save_ctx(ctx, det)
            remember(history, q, ans)
            _append_log(tid, q, ans, "SQL")
            return stream_text("SQL", ans)

    # 2) LLM router for everything else: smalltalk / help / advice / summary /
    #    coverage / subscriptions / breakdown / genuine follow-ups.
    intent = llm_route(rq, history)
    if intent:
        intent = _apply_guards(intent, rq)
        t = (intent.get("type") or "").lower()
        if t == "smalltalk":
            _append_log(tid, q, GREETING, "chat")
            return stream_text("chat", GREETING)
        if t == "help":
            cap = _capabilities()
            _append_log(tid, q, cap, "chat")
            return stream_text("chat", cap)
        if t == "followup" and history:
            remember(history, q, "(answered from conversation)")
            return followup_response(q, history, tid)
        if t in ("unknown", ""):
            _append_log(tid, q, DIDNT_CATCH, "chat")
            return stream_text("chat", DIDNT_CATCH)
        if t == "advice" and (_FIN_RE.search(rq) or _ADVICE_RE.search(rq) or _REASON_RE.search(rq)):
            remember(history, q, "(financial advice given)")
            return grounded_advice(rq, tid)
        # router said "advice" but the question has zero finance content (e.g. "should i
        # text my ex") -> don't lecture about money; fall through to a clean nudge below.
        ans = ts.dispatch_intent(intent, USER)            # SQL produces every number
        if ans is not None:
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
    ans = ts.answer(q, USER)
    if ans is not None:
        remember(history, q, ans)
        _append_log(tid, q, ans, "SQL")
        return stream_text("SQL", ans)
    # last resort: an honest nudge — NOT a recycled advice dump (avoids parroting)
    _append_log(tid, q, DIDNT_CATCH, "chat")
    return stream_text("chat", DIDNT_CATCH)


PAGE = r"""<!doctype html><html><head><meta charset="utf-8">
<title>Penny · SQL layer test</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root{ --cream:#fff8eb; --cream2:#fdf6e9; --ink:#1a1a1a; --ink2:#2a2a2a;
         --lime:#84cc16; --orange:#ff9f56; --line:#eaddc4; }
  *{box-sizing:border-box} html,body{margin:0;height:100%}
  body{background:var(--cream);color:var(--ink);font:15px/1.5 'Poppins',system-ui,Arial}
  header{padding:16px 22px;border-bottom:1px solid var(--line);display:flex;align-items:center;gap:12px}
  header b{font-size:18px} .pill{background:var(--lime);color:#143;padding:2px 10px;border-radius:99px;font-size:12px;font-weight:600}
  .wrap{max-width:860px;margin:0 auto;padding:18px}
  .card{background:var(--cream2);border:1px solid var(--line);border-radius:14px;padding:16px;margin-bottom:16px}
  .drop{border:2px dashed var(--orange);border-radius:14px;padding:22px;text-align:center;cursor:pointer;background:#fffdf7}
  .drop:hover{background:#fff4dd} input[type=file]{display:none}
  .stat{display:inline-block;margin:6px 14px 0 0;font-size:13px;color:#6b5} .stat b{color:var(--ink)}
  #chat{min-height:120px}
  .msg{padding:12px 14px;border-radius:12px;margin:10px 0;max-width:90%}
  .me{background:var(--ink);color:#fff;margin-left:auto;border-bottom-right-radius:4px}
  .bot{background:#fff;border:1px solid var(--line);border-bottom-left-radius:4px}
  .bot .tag{font-size:11px;font-weight:700;letter-spacing:.04em;padding:1px 7px;border-radius:99px;margin-bottom:6px;display:inline-block}
  .tag.SQL{background:var(--lime);color:#143} .tag.RAG{background:#ffe9d0;color:#8a5a1f}
  .tag.chat{background:#eef;color:#446}
  .who{font-size:11px;color:#b08a4a;margin-left:6px}
  table{border-collapse:collapse;width:100%;margin:8px 0;font-size:13.5px}
  th,td{border:1px solid var(--line);padding:6px 9px;text-align:left} th{background:#f6fce0}
  td:nth-child(n+2){text-align:right;font-variant-numeric:tabular-nums}
  .row{display:flex;gap:10px;margin-top:8px}
  input[type=text]{flex:1;padding:12px 14px;border:1px solid var(--line);border-radius:10px;font-size:15px;background:#fff}
  button{background:var(--lime);border:0;color:#143;font-weight:700;padding:0 20px;border-radius:10px;cursor:pointer}
  button:disabled{opacity:.5;cursor:default}
  .chips{margin-top:6px} .chip{display:inline-block;background:#fff;border:1px solid var(--line);border-radius:99px;
         padding:5px 11px;margin:4px 6px 0 0;font-size:12.5px;cursor:pointer} .chip:hover{background:#f6fce0}
  .muted{color:#9a8} em{color:#8a5a1f}
  .thinking{display:flex;align-items:center;gap:8px}
  .typing{display:inline-flex;gap:5px;align-items:center}
  .typing i{width:7px;height:7px;border-radius:50%;background:var(--orange);display:inline-block;
            animation:penny-blink 1.2s infinite both}
  .typing i:nth-child(2){animation-delay:.18s} .typing i:nth-child(3){animation-delay:.36s}
  @keyframes penny-blink{0%,80%,100%{opacity:.25;transform:translateY(0)}
                         40%{opacity:1;transform:translateY(-4px)}}
</style></head><body>
<header><b>Penny</b><span class="pill">SQL layer · offline test</span>
  <span class="muted" style="margin-left:auto;font-size:12px">numbers come from SQL, never the LLM</span></header>
<div class="wrap">
  <div class="card">
    <label class="drop" id="drop">
      <input type="file" id="file" accept="application/pdf">
      <div><b>Click to upload a statement PDF</b></div>
      <div class="muted" id="dropsub">e.g. data/statement_1lakh.pdf (1,00,000 txns)</div>
    </label>
    <div id="stats"></div>
  </div>
  <div class="card">
    <div class="row" style="margin:0 0 8px 0;align-items:center">
      <b style="font-size:13px">Chat</b>
      <span class="muted" id="threadnote" style="font-size:11px;flex:1">context carries within this thread · tap New chat to reset</span>
      <button id="newchat" style="padding:7px 13px;font-size:12.5px;background:#fff;border:1px solid var(--line);color:var(--ink)">↻ New chat</button>
    </div>
    <div id="chat"><div class="muted">Upload a statement, then ask away.</div></div>
    <div class="row">
      <input type="text" id="q" placeholder="e.g. how much did I spend on swiggy?">
      <button id="send">Ask</button>
    </div>
    <div class="chips" id="chips"></div>
  </div>
</div>
<script>
const $=s=>document.querySelector(s);
const SUG=["what is my total spending?","give me an account summary","show me spending by category",
  "how much did I spend on swiggy?","what is my biggest expense?",
  "how financially healthy am I?","what risks do you see?","what patterns do you see?",
  "what spending habits do I have?","what subscriptions do I have?",
  "which categories are growing fastest?","how can I save money?"];
$("#chips").innerHTML=SUG.map(s=>`<span class="chip">${s}</span>`).join("");
document.querySelectorAll(".chip").forEach(c=>c.onclick=()=>{$("#q").value=c.textContent;ask();});

// detect data already loaded in the DB so the input works without re-uploading
(async()=>{ try{
  const s=await (await fetch("/status")).json();
  if(s.rows>0){
    $("#stats").innerHTML=`<span class="stat"><b>${s.rows.toLocaleString('en-IN')}</b> txns loaded</span>
      <span class="stat">spend <b>${s.spend}</b></span><span class="stat">income <b>${s.income}</b></span>`;
    $("#dropsub").textContent="A statement is already loaded — ask away, or upload to replace it.";
    $("#chat").innerHTML='<div class="muted">Ready. Ask a question or tap a suggestion.</div>';
    $("#q").focus();
  }
}catch(e){} })();

function mdToHtml(md){
  const lines=md.split("\n"); let html="",tbl=[];
  const flush=()=>{ if(!tbl.length)return;
    const rows=tbl.filter(r=>!/^\s*\|?\s*-{2,}/.test(r));
    html+="<table>"+rows.map((r,i)=>{const cells=r.split("|").filter(c=>c.trim()!=="");
      const tag=i==0?"th":"td";return "<tr>"+cells.map(c=>`<${tag}>${c.trim()}</${tag}>`).join("")+"</tr>";}).join("")+"</table>";
    tbl=[]; };
  for(const ln of lines){ if(ln.trim().startsWith("|")){tbl.push(ln);continue;} flush();
    let t=ln.replace(/\*\*(.+?)\*\*/g,"<b>$1</b>").replace(/_(.+?)_/g,"<em>$1</em>");
    if(t.trim())html+=`<div>${t}</div>`; }
  flush(); return html;
}
function add(cls,html,tag){ const d=document.createElement("div"); d.className="msg "+cls;
  d.innerHTML=(tag?`<span class="tag ${tag}">${tag}</span>`:"")+html;
  $("#chat").appendChild(d); d.scrollIntoView({behavior:"smooth",block:"end"}); }

$("#file").onchange=async e=>{
  const f=e.target.files[0]; if(!f)return;
  $("#dropsub").textContent="Uploading & parsing "+f.name+" …"; $("#stats").innerHTML="";
  const r=await fetch("/upload?name="+encodeURIComponent(f.name),{method:"POST",body:f});
  const j=await r.json();
  $("#dropsub").textContent=f.name+" loaded";
  $("#stats").innerHTML=`<span class="stat"><b>${j.rows.toLocaleString('en-IN')}</b> txns</span>
    <span class="stat">parsed in <b>${j.seconds}s</b></span>
    <span class="stat">spend <b>${j.spend}</b></span>
    <span class="stat">income <b>${j.income}</b></span>`;
  $("#q").disabled=false; $("#send").disabled=false; $("#q").focus();
};
const TAG={SQL:"SQL",chat:"chat",advice:"RAG"};
function newBubble(path){
  const d=document.createElement("div"); d.className="msg bot";
  const tag=TAG[path]||"chat";
  d.innerHTML=`<span class="tag ${tag}">${tag}</span>`
    +(path==="advice"?`<span class="who">Penny · __MODEL__</span>`:"")
    +`<div class="md"></div>`;
  $("#chat").appendChild(d); d.scrollIntoView({behavior:"smooth",block:"end"});
  return d.querySelector(".md");
}

// loading indicator shown the instant you hit Enter, until the answer starts
function thinkingBubble(){
  const d=document.createElement("div"); d.className="msg bot thinking";
  d.innerHTML=`<span class="muted" style="font-size:12.5px">Penny is thinking</span>`
    +`<span class="typing"><i></i><i></i><i></i></span>`;
  $("#chat").appendChild(d); d.scrollIntoView({behavior:"smooth",block:"end"});
  return d;
}

// chat-thread: a STABLE id (persisted in localStorage) so a page refresh keeps the
// same thread — context survives reloads (and, server-side, restarts). "New chat"
// rotates to a fresh id.
const newThreadId=()=>"t"+Math.random().toString(36).slice(2)+Date.now();
let THREAD = localStorage.getItem("penny_thread") || newThreadId();
localStorage.setItem("penny_thread", THREAD);
$("#newchat").onclick=()=>{
  THREAD=newThreadId(); localStorage.setItem("penny_thread", THREAD);
  $("#chat").innerHTML='<div class="muted">New chat — context cleared. Ask away.</div>';
  $("#q").focus();
};

async function ask(){
  const q=$("#q").value.trim(); if(!q)return;
  add("me",q); $("#q").value=""; $("#send").disabled=true;
  const think=thinkingBubble();                     // <- loader shows immediately
  let cleared=false; const clearThink=()=>{ if(!cleared){cleared=true; think.remove();} };
  try{
    const r=await fetch("/query",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({question:q,thread:THREAD})});
    const reader=r.body.getReader(), dec=new TextDecoder();
    let buf="", md=null, full="";
    const queue=[]; let streamDone=false, revealing=false;
    const reveal=()=>{ revealing=true;
      if(queue.length){
        full+=queue.shift();
        md.innerHTML=mdToHtml(full);
        md.parentElement.scrollIntoView({behavior:"smooth",block:"end"});
        setTimeout(reveal,18);                       // ~18ms per word -> typewriter
      } else if(streamDone){ revealing=false; $("#send").disabled=false; }
      else setTimeout(reveal,18);                     // wait for more network
    };
    while(true){ const {done,value}=await reader.read(); if(done)break;
      buf+=dec.decode(value,{stream:true}); const lines=buf.split("\n"); buf=lines.pop();
      for(const ln of lines){ if(!ln.trim())continue; const m=JSON.parse(ln);
        if(m.type==="meta"){ clearThink(); md=newBubble(m.path); }   // loader -> real answer
        else if(m.type==="chunk"){ queue.push(m.content); if(!revealing) reveal(); }
      }
    }
    streamDone=true; if(!revealing) $("#send").disabled=false;
  }catch(e){
    clearThink();
    const md=newBubble("chat");
    md.innerHTML="⚠️ Couldn't reach the server. Please try again.";
    $("#send").disabled=false;
  }
}
$("#send").onclick=ask; $("#q").addEventListener("keydown",e=>{if(e.key==="Enter")ask();});
</script></body></html>"""

# ---- docs: render a markdown HLD as a styled, self-contained HTML page ----------
import html as _htmlmod

_DOCS_DIR = os.path.join(os.path.dirname(__file__), "..", "docs")


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


_DOC_SHELL = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>
 :root{--cream:#fff8eb;--ink:#1f1b16;--mut:#6b6256;--lime:#84cc16;--line:#e8dcc2;--code:#1a1a1a;}
 *{box-sizing:border-box} body{margin:0;background:var(--cream);color:var(--ink);
   font:16px/1.65 'Poppins',-apple-system,Segoe UI,Arial}
 .wrap{max-width:880px;margin:0 auto;padding:40px 22px 80px}
 .top{font-size:13px;color:var(--mut);margin-bottom:8px}
 .top a{color:var(--lime);text-decoration:none;font-weight:600}
 h1{font-size:30px;line-height:1.2;margin:.2em 0 .4em;border-bottom:3px solid var(--lime);padding-bottom:.25em}
 h2{font-size:22px;margin:1.6em 0 .5em;border-bottom:1px solid var(--line);padding-bottom:.2em}
 h3{font-size:17px;margin:1.3em 0 .4em}
 p{margin:.7em 0} a{color:#1668c2}
 code{background:#f1e9d6;padding:.1em .4em;border-radius:5px;font:13.5px/1.5 'JetBrains Mono',Consolas,monospace}
 pre{background:var(--code);color:#eee;padding:14px 16px;border-radius:10px;overflow:auto;font-size:12.5px;line-height:1.45}
 pre code{background:none;color:#eee;padding:0}
 table{border-collapse:collapse;width:100%;margin:1em 0;font-size:14.5px}
 th,td{border:1px solid var(--line);padding:8px 11px;text-align:left;vertical-align:top}
 th{background:#f3ead6} tr:nth-child(even) td{background:#fffdf6}
 blockquote{margin:1em 0;padding:.4em 1em;border-left:4px solid var(--lime);background:#fffdf3;color:#3a352c}
 hr{border:0;border-top:1px solid var(--line);margin:2em 0}
 ul,ol{margin:.6em 0 .6em 1.2em} li{margin:.25em 0}
</style></head><body><div class="wrap">
<div class="top">Penny · <a href="/">app</a> · <a href="/roadmap">Roadmap</a> · <a href="/hld">HLD</a> · <a href="/lld">LLD</a> · <a href="__RAW__">raw</a></div>
__BODY__
</div></body></html>"""


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
    return _render_doc("Penny_HLD_Technical.md", "Penny — Technical HLD", "/hld.md")


@app.get("/lld")
async def lld_page():
    return _render_doc("Penny_LLD.md", "Penny — Low-Level Design", "/lld.md")


@app.get("/roadmap")
async def roadmap_page():
    return _render_doc("Penny_Roadmap_Status.md", "Penny — Roadmap & Status", "/roadmap.md")


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
    if _llm_complete("Reply with the single word: ok.", "ok", num_predict=5):
        print(f"[warmup] {LLM_MODEL} ready")
    else:
        print(f"[warmup] {LLM_MODEL} not reachable yet — will retry on first question")


if __name__ == "__main__":
    PORT = int(os.getenv("PORT", "5667"))
    print(f"Penny SQL-layer  ->  http://localhost:{PORT}")
    threading.Thread(target=_warmup, daemon=True).start()
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="warning")
