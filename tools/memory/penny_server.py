#!/usr/bin/env python3
"""
Penny MLX web server (branch: feat/mlx-web-server).

Exposes the conversation-aware Penny (entity memory + retrieval + context-LoRA) over HTTP so
the app can get multi-turn, pronoun-resolving answers about the statement. No web-framework
dependency — stdlib http.server only.

Endpoints
  GET  /health              -> {ok, model, adapter, sessions, doc}
  POST /ask     {session, message}  -> {answer, resolved, target, note, state, latency_ms}
  POST /reset   {session}           -> {ok}

Run:  ../../.venv-mlx/bin/python penny_server.py            # :8765, context-LoRA + memory
      PENNY_MLX_PORT=8770 PENNY_BASE=1 ... penny_server.py   # plain base model
"""
import json, os, time, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from penny_memory import PennyAgent, Document, CTX_ADAPTER, BASE_MODEL

# NOTE: single-threaded server on purpose — MLX GPU streams are thread-local, so all model
# inference must run on the one serving thread. Requests are naturally serialized.

PORT = int(os.environ.get("PENNY_MLX_PORT", "8765"))
USE_BASE = os.environ.get("PENNY_BASE") == "1"
ADAPTER = None if USE_BASE else (CTX_ADAPTER if os.path.isdir(CTX_ADAPTER) else None)

print(f"[penny] loading model{' + context-LoRA' if ADAPTER else ' (base)'} …")
_DOC = Document()
_BOOT = PennyAgent(doc=_DOC, adapter_path=ADAPTER)
_BOOT._ensure_llm()                       # load once
_MODEL, _TOK = _BOOT._model, _BOOT._tok
_LOCK = threading.Lock()                   # serialize inference (MLX model is shared)
_SESSIONS = {}                             # session_id -> PennyAgent (shares _MODEL/_TOK)
print(f"[penny] ready on :{PORT}  (adapter={'context-LoRA' if ADAPTER else 'none'})")

def agent_for(session):
    ag = _SESSIONS.get(session)
    if ag is None:
        ag = PennyAgent(doc=_DOC, model=_MODEL, tok=_TOK)   # own memory, shared model
        _SESSIONS[session] = ag
    return ag

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)
    def _body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        try: return json.loads(self.rfile.read(n) or b"{}")
        except Exception: return {}
    def log_message(self, *a): pass          # quiet

    def do_GET(self):
        if self.path.split("?")[0] == "/health":
            return self._send(200, {"ok": True, "model": BASE_MODEL,
                                    "adapter": "context-LoRA" if ADAPTER else None,
                                    "sessions": len(_SESSIONS), "doc": _DOC.source,
                                    "transactions": len(_DOC.tx)})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?")[0]
        data = self._body()
        session = str(data.get("session") or "default")
        if path == "/reset":
            _SESSIONS.pop(session, None)
            return self._send(200, {"ok": True})
        if path == "/load":
            # Swap the active document to the app's uploaded statement. Clears all sessions.
            recs = data.get("records") or []
            if not recs: return self._send(400, {"error": "no records"})
            try:
                newdoc = Document.from_records(recs, source=str(data.get("source", "uploaded statement")),
                                               symbol=str(data.get("symbol", "₹")))
            except Exception as e:
                return self._send(500, {"error": f"{type(e).__name__}: {e}"})
            global _DOC
            _DOC = newdoc
            _SESSIONS.clear()
            return self._send(200, {"ok": True, "transactions": len(newdoc.tx), "source": newdoc.source})
        if path == "/ask":
            msg = str(data.get("message") or "").strip()
            if not msg: return self._send(400, {"error": "empty message"})
            ag = agent_for(session)
            t0 = time.time()
            try:
                with _LOCK:                      # one generation at a time
                    r = ag.ask(msg, max_tokens=int(data.get("max_tokens", 64)))
            except Exception as e:
                return self._send(500, {"error": f"{type(e).__name__}: {e}"})
            return self._send(200, {"answer": r["answer"], "resolved": r.get("resolved_kind"),
                                    "target": r.get("target"), "note": r.get("note"),
                                    "clarify": r.get("clarify", False), "reset": r.get("reset", False),
                                    "state": r.get("state_after", r.get("state_before")),
                                    "latency_ms": round((time.time()-t0)*1000)})
        return self._send(404, {"error": "not found"})

if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
