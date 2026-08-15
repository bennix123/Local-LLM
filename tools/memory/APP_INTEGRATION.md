# Wiring Penny (memory + context-LoRA) into the app

The conversation-aware Penny now plugs into the existing web app (`server.js` + `public/`) as an
additive **"🧠 Memory"** chat mode. Nothing existing is changed behaviourally — the memory path is
only taken when the toggle is on, and it fails soft if the MLX server isn't running.

```
Browser (public/app.js)                Node app (server.js)              Penny MLX server (Python)
  Memory toggle ON  ──POST /api/chat──▶  penny branch ──fetch /ask──▶  PennyAgent (per session)
  {message, penny:true, session}          (guarded proxy)                entity memory + retrieval
  ◀── streamed answer, X-Answer: penny ──                               + context-LoRA
```

## Components
| Piece | File | What it does |
|---|---|---|
| MLX web server | `tools/memory/penny_server.py` | `/health`, `/ask`, `/reset`; loads context-LoRA + memory once; **per-session** `EntityMemory`; single-threaded (MLX GPU streams are thread-local) |
| Node proxy | `server.js` (`/api/chat` penny branch + `/api/penny/reset`) | forwards `{session, message}` to the MLX server; sets `X-Answer: penny`, `X-Penny-Resolved`; guarded (helpful note if server down) |
| UI toggle | `public/app.js` | "🧠 Memory" chip; persistent `session` id; sends `penny:true`; resets memory on enable |

## Run it
```bash
# 1) start the Penny MLX server (defaults to :8765, context-LoRA + memory)
tools/memory/run_penny_server.sh            # or: .venv-mlx/bin/python tools/memory/penny_server.py

# 2) start the app (installs deps first time)
npm install && node server.js               # http://localhost:3000

# 3) in the chat, click "🧠 Memory: off" -> "on", then converse:
#    "What was the largest transaction?" -> "when did it happen?" -> "and the one before it?"
```
Env: `PENNY_MLX_URL` (Node → server, default `http://127.0.0.1:8765`), `PENNY_MLX_PORT`,
`PENNY_BASE=1` (serve the plain base model instead of the context-LoRA).

## Verified
- MLX server multi-turn over HTTP (pronoun / previous / switch / reset) — correct, ~1–2 ms templated,
  ~1.9 s for LLM turns.
- Node→MLX proxy path (the exact `server.js` branch) — multi-turn memory across requests, correct
  `X-Answer`/`X-Penny-Resolved` headers, reset works.
- `node --check server.js` passes. (The full app needs `npm install` — `node_modules` isn't in this
  checkout; that's pre-existing and unrelated to the wiring.)

## Uploaded-document support (implemented)
Memory mode follows the **uploaded** statement, not just the Paytm demo:
- `Document.from_records(records, symbol)` normalises the app's rows (`date, description, payee,
  amount, balance`) — **direction is inferred from the running-balance delta** (robust to unsigned
  amounts), missing fields (time / txn-id) degrade gracefully, and the currency symbol is honoured.
- The server exposes `POST /load {records, source, symbol}` which swaps the active document and
  clears sessions. `server.js` calls it automatically after each upload (`pushToPenny`, best-effort).
- Verified on `bank.db` (37 txns, £): "largest debit" → STANDING ORDER £750, "balance after it" →
  £3,651.61, "the one before it" → AMAZON £27.99 — correct direction, currency, and multi-turn memory,
  through the real `/api/chat`.

Note: currency **field** answers (amount/balance) are templated deterministically so the ₹-biased
context-LoRA can't emit the wrong symbol; free-form answers use the LLM with the grounded context.
