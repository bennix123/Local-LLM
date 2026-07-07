import json, os, re, sys, threading, urllib.request
from datetime import datetime, timedelta
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from src.services import txn_store as ts
from src.services import ml_insights as ml

from .prompts import ADVICE_SYSTEM, GROUNDED_ADVICE_SYSTEM, ROUTER_SYSTEM
from .ui import PAGE, _DOC_SHELL
from .router import (
    _GUARD_STOP, _log_lock, _SAVINGS_RE, _TABLE_RE, _INCOME_RE, _COUNTQ_RE, _ML_CACHE, CHAT_LOG, _parse_period, _FACTUAL, _DOCS_DIR,
    _resolve_conversation, ConversationState, _resolve_factual,
    _extract_slots, _save_ctx, _special_factual,
    # Regexes and guards needed by server
    _SPECIAL_INTENTS, _FUP_ATTR, _REFS_RE, _CONT_RE
)
from .analytics import (
    _llm_complete,
    analytics_answer, concept_answer, intelligence_answer, ml_answer,
    followup_sql_answer, followup_response, grounded_advice
)

OLLAMA_URL = os.getenv("OLLAMA_URL", "http://127.0.0.1:11434")
LLM_MODEL = os.getenv("LLM_MODEL", "llama3.1:8b")
PORT = int(os.getenv("PORT", "5667"))
USER = "local"

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

_PINNED_DB = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "data", "live_txn.db"))
_env_db = os.environ.get("FINQ_DB")
ts.DB_PATH = _env_db if (_env_db and os.path.exists(_env_db)) else _PINNED_DB
print(f"[db] using {ts.DB_PATH}" + ("" if os.path.exists(ts.DB_PATH) else "  (WARNING: not found!)"), flush=True)
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
    # total — the LLM sometimes flips "total savings" to "spend". Savings RATE/target are the
    # intelligence gate's job and are handled before this point, so they never reach here.
    if _SAVINGS_RE.search(low):
        intent["type"] = "summary"
        return intent
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

def _warmup():
    """Pre-load the model so the first advisory answer isn't a cold start (which is what
    made earlier replies show '(... unavailable)')."""
    if _llm_complete("Reply with the single word: ok.", "ok", num_predict=5):
        print(f"[warmup] {LLM_MODEL} ready")
    else:
        print(f"[warmup] {LLM_MODEL} not reachable yet — will retry on first question")
