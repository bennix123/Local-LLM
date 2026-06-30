# Penny — High-Level Design (Technical)

**Status:** living document · **Scope:** the offline statement-intelligence engine
(`finquery/`) · **Audience:** engineers and technical reviewers.

> Companion to `Penny_HLD.md` (the plain-English overview). This document describes
> the system **as built**: components, data model, the request-routing pipeline, and the
> mechanism that guarantees no financial figure is ever produced by the language model.

---

## 1. Purpose & core principle

Penny answers natural-language questions about a user's bank statement — totals,
breakdowns, comparisons, and *advice* — over statements as large as a lakh-plus rows,
fully offline.

The architecture is built on one invariant:

> **The deterministic SQL layer produces every number. The language model only
> classifies intent and phrases prose. The model is never trusted to emit a figure.**

This eliminates the failure mode that blocks AI from finance use — a confidently wrong
number — while still allowing a natural, conversational interface.

---

## 2. Design goals & constraints

| Goal | Consequence in the design |
|---|---|
| **No numeric hallucination** | All amounts/counts/percentages come from SQL; LLM output is number-validated against SQL facts before it reaches the user. |
| **Scale to 1,00,000+ transactions** | Aggregates run as indexed SQL, not LLM context; bulk data never enters a prompt. |
| **Fully offline / on-device** | Local SQLite + local LLM (Ollama); no cloud APIs, no network dependency on the query path. |
| **Low latency** | Common money questions resolve deterministically *before* the model is consulted. |
| **Auditability** | Every answer maps to a concrete SQL query (or a validated, fact-grounded sentence). |

Target deployment envelope: a 4 GB-class device (phone), single user, read-only.

---

## 3. System architecture

```
                     ┌──────────────────────────────────────────────┐
   Browser / React   │                 FastAPI app                   │
   ───────────────►  │             (scripts/test_server.py)          │
   POST /query       │                                               │
   (ndjson stream)   │   ┌───────────────────────────────────────┐  │
                     │   │        Query routing pipeline         │  │
                     │   │  guards → advice gate → analytics →   │  │
                     │   │  factual resolve → LLM router → fall  │  │
                     │   └───────┬───────────────────┬───────────┘  │
                     │           │                   │              │
                     │           ▼                   ▼              │
                     │  ┌─────────────────┐  ┌──────────────────┐   │
                     │  │ Deterministic   │  │  LLM subsystem   │   │
                     │  │ SQL layer       │  │  (Ollama, local) │   │
                     │  │ txn_store.py    │  │  router /        │   │
                     │  │ ("Penny")       │  │  grounded advice │   │
                     │  └────────┬────────┘  └────────┬─────────┘   │
                     │           │                    │             │
                     │           ▼                    │             │
                     │     ┌───────────┐              │             │
                     │     │  SQLite   │◄─────────────┘ (facts only)│
                     │     │ live_txn  │   ML insights (sklearn),   │
                     │     │   .db     │   hybrid search (BM25+vec) │
                     │     └───────────┘                            │
                     └──────────────────────────────────────────────┘
```

> The routing strip above is condensed; the live cascade also runs an **ML gate** and an
> **Intelligence-engine gate** ahead of the advice gate (full order in §5; engines in §10A).

**Component summary**

| Component | File / tech | Responsibility |
|---|---|---|
| API layer | `scripts/test_server.py` · FastAPI + uvicorn | HTTP, ndjson streaming, routing, upload, chat log |
| Deterministic SQL layer ("Penny") | `backend/src/services/txn_store.py` · stdlib `sqlite3` | every figure: totals, by-category/merchant/month, extremes, fact sheet |
| LLM subsystem | Ollama `llama3.1:8b` | intent classification (router) + advisory prose (grounded) |
| Intelligence engines | `backend/src/services/txn_store.py` (engines) | health score, risk, behavioural, impact, category-trend — **every figure from SQL** (§10A) |
| Insight store | `insights` table (SQLite) | pre-computed insight rows; written on upload + startup |
| ML insights | `backend/src/services/ml_insights.py` · scikit-learn | anomalies, forecast, recurring detection, auto-categorise |
| Storage | SQLite (`data/live_txn.db`) | transactions table; date split into year/month/day |
| Frontend | React/Vite (Penny UI) | chat + dashboards (consumes `/query`, `/dashboard`, `/ml/*`) |

---

## 4. Data model

A single `transactions` table is the system of record. Each parsed statement row is
normalised; the transaction date is **decomposed into separate `year` / `month` / `day`
columns** (plus a `month` = `YYYY-MM` string), which is what makes date-scoped queries
both exact and index-friendly.

| Column | Notes |
|---|---|
| `user_id`, `doc_name` | multi-statement scoping (e.g. `statement_1lakh.pdf`, `statement_5k.pdf`) |
| `txn_date`, `year`, `month`, `day` | date decomposition for fast period filters |
| `descr`, `merchant`, `category` | raw text; canonical merchant; classified category |
| `debit`, `credit`, `balance` | signed money columns; `balance` is running balance |
| `seq` | original ordering (used for "latest balance") |

**Scoping.** Every aggregation goes through `_scope(user_id, doc_name, period)`, which
builds the `WHERE` clause. `period` accepts `YYYY`, `YYYY-MM`, `YYYY-MM-DD`, or a
`(start, end)` tuple → `txn_date BETWEEN ? AND ?`.

**Note on merchant matching.** Descriptions store multi-word merchants underscored
(`NEFT/Axis_Bank_Car_Loan/REF...`). Lookups therefore match the canonical `merchant`
column **or** a `descr LIKE`, so "Axis Bank Car Loan" resolves correctly.

---

## 5. Query routing pipeline

`POST /query` is the single entry point. It is an **ordered cascade** — the cheapest,
most deterministic handler that can answer, does. Routing order:

```
0.   empty            → greeting
0.   no data uploaded → "upload a statement"
0.   no letters/digits ("???", "...") → didn't-catch nudge
0-RES. CONVERSATIONAL RESOLUTION (_resolve_conversation)           → resolved query `rq`  ◀ NEW
        rewrites an elliptical follow-up to STANDALONE form (inject carried scope); a "reset"
        signal clears the thread; the merged scope is persisted every turn. EVERY gate below
        routes on `rq`, so analytics/ML/advice are no longer context-blind. (§8, LLD §4a)
0a.  follow-up ABOUT the last answer  (ctx + _FUP_ATTR + _REFS_RE)  → followup_response
0a-ML.  ML gate    (_ANOM_RE | _FCAST_RE | _PROJ_RE)               → ml_answer (anomaly/forecast/projection)  ◀ ML
0a-INT. INTELLIGENCE gate (health/risk/recurring/impact/cat-trend/ → SQL (intelligence_answer) — deterministic  ◀ NEW
        behaviour/patterns regexes)                                  scores, every figure from SQL (§10A)
0b.  ADVICE gate  (_ADVICE_RE | _REASON_RE, finance-anchored)       → grounded_advice  ◀ LLM
0c.  ANALYTICS    (compare / avg / % / argmax / filter / multi)     → SQL  (analytics_answer)
1.   FACTUAL      (_resolve_factual → ts.dispatch_intent)           → SQL
2.   LLM ROUTER   (llm_route → structured intent)                   → see below
3.   FALLBACK     (HELP_RE / CONVO_RE / ts.answer)  else nudge
```

**Step 2 — LLM router outcomes.** The model returns a structured intent `{type,
category, merchant, n, start, end, table}`. `type` is dispatched:

| `type` | Action |
|---|---|
| `smalltalk` | greeting |
| `help` | capabilities text |
| `followup` | `followup_response` (only if thread history exists) |
| `unknown` / `""` | didn't-catch nudge |
| `advice` | **`grounded_advice`** — *only if* the question carries a finance signal (`_FIN_RE`) or matched the advice regexes; otherwise → nudge |
| anything else | `ts.dispatch_intent` → SQL; if no data, nudge |

The **`_FIN_RE` finance-gate** is what stops the 8B router from giving a *savings
lecture* to a non-finance "should I…" question (e.g. "should I text my ex" → nudge, not
advice).

> **Why a cascade.** Self-contained money questions ("spend at Zerodha in 2024") match
> the deterministic stages and **skip the model entirely** — faster, and immune to
> misclassification. The model is reached only for genuinely fuzzy or advisory input.

---

## 6. The no-hallucination guarantee (end to end)

This is the heart of the design. Two distinct LLM paths exist, and **neither can put an
unverified number in front of the user**:

### 6.1 Factual / analytics path
The model (router) only *classifies*; `ts.dispatch_intent` / `analytics_answer` run the
SQL and format the result. The number literally cannot originate in the model.

### 6.2 Advisory path (`grounded_advice`)
Advisory questions ("how much can I safely invest?", "how dependent am I on one income
source?") need reasoning, so the model writes prose — but under a strict contract:

```
            ┌────────────────────────────────────────────────────────────┐
 question → │ 1. ts.advice_facts(user) → a number-RICH fact sheet,        │
            │    EVERY figure pre-computed in SQL (totals, monthly avgs,  │
            │    savings rate, surplus, per-category %/flags, income-     │
            │    source %/dependence, concentration, trends, runway…).    │
            ├────────────────────────────────────────────────────────────┤
            │ 2. _llm_complete(GROUNDED_ADVICE_SYSTEM + facts, question)  │
            │    System prompt: "use ONLY these figures; never compute."  │
            ├────────────────────────────────────────────────────────────┤
            │ 3. _advice_grounded(reply, facts):  VALIDATE                 │
            │    every ₹ amount (±0.5% / ₹1) and every % (±0.5pt) in the  │
            │    reply must appear in the fact sheet.                      │
            ├────────────────────────────────────────────────────────────┤
            │ 4a. valid   → stream the reply                              │
            │ 4b. invalid → discard, return _advice_fallback (concise     │
            │     deterministic answer)                                    │
            └────────────────────────────────────────────────────────────┘
```

Because the fact sheet pre-computes even derived figures (e.g. the investable surplus),
the model only has to *select and phrase*, never calculate. Step 3 is the backstop: if
the model invents or computes a number, validation fails and the deterministic fallback
answers instead. **No number reaches the user unless SQL produced it.**

> Observed before the validator existed: the model computed
> `52,00,217.25 − 48,12,184.98 = 4,88,032.27` — unauthorised *and* wrong (the surplus
> already excludes bills). The fact-sheet + validator approach removes that entire class
> of error.

---

## 7. LLM subsystem details

| Aspect | Setting |
|---|---|
| Runtime | Ollama, local HTTP `127.0.0.1:11434` |
| Model | `llama3.1:8b` (Q4_K_M) — `LLM_MODEL` env overridable |
| Router call | `format:"json"`, `temperature 0`, `num_ctx 2048` |
| Advice call | `temperature 0.2`, `num_predict 512`, `num_ctx 4096`, `keep_alive 30m` |
| Reliability | non-streaming `_llm_complete` retries once; a startup `_warmup()` thread pre-loads the model so the first answer is never a cold "(unavailable)" |
| Degraded mode | if Ollama is down, advisory questions still answer via `_advice_fallback` (deterministic); factual questions are unaffected |

Memory budget note: this class of hardware OOMs if Llama 3.1 defaults to 128K context,
so `num_ctx` is pinned small (2048/4096) — the prompts are tiny by design.

---

## 8. Conversation / thread model

State is **per chat thread**, supplied by the client as `thread` (with `reset` to start
fresh):

```
THREADS[tid] = { ctx: {type,start,end,category,merchant,n}, history: [last 6 Q&A] }
```

- `ctx` is deterministic **slot memory** — an elliptical follow-up ("…and in May?")
  inherits the thread's period/intent/category/merchant, resolved *before* the model.
- **Conversational resolution layer** (`ConversationState` + `_resolve_conversation`): a typed
  view over `ctx` plus a resolver that runs **once at the top of `query()`** and rewrites an
  elliptical follow-up into a fully-resolved **standalone** query by injecting the carried scope
  — so *every* engine (analytics / ML / advice), not just the factual path, sees an unambiguous
  question. "Average transaction" after "Transactions at Zomato in 2024" → *Average transaction
  at Zomato in 2024*. No-op on a fresh thread (single-turn suites unaffected). Backward-compatible:
  serialises back into the legacy `ctx` keys. See LLD §4a.
- `history` (last 6) feeds the router the last 2 *real* exchanges; advice-turn
  placeholders (`"(financial advice given)"`) are filtered out so prior advice can't
  bias later routing.
- Every turn is persisted to `data/chats.json` (`GET /chats`) — and each turn now **snapshots
  the live `{ctx, history}`** into the thread's `state`. On a cold thread, `_thread()`
  **rehydrates** from it, so follow-up context **survives a server restart**. The browser keeps
  a **stable thread id in `localStorage`**, so a page refresh reuses the same thread (context
  persists across reloads too). No Redis — single-process, file-backed (fits the offline target).

---

## 9. Request lifecycle (numeric vs advisory)

**Numeric question** — "how much did I spend at Zerodha in 2024?"
```
client → /query → analytics/factual stage → _scope+SQL (SUM(debit)) → format ₹ table
       → ndjson stream (table sent as one block, prose word-by-word) → done
```

**Advisory question** — "how much can I safely invest every month?"
```
client → /query → 0b advice gate → grounded_advice
       → advice_facts (SQL) → llm_complete → validate numbers vs facts
       → (valid) stream prose  |  (invalid) stream deterministic fallback → done
```

Streaming format: newline-delimited JSON; `{"type":"meta","path":...}`, then
`{"type":"chunk","content":...}` (markdown tables emitted whole, prose per word), then
`{"type":"done"}`.

---

## 10. ML insights layer (auxiliary)

`ml_insights.py` (scikit-learn) provides pattern detection — **exact ₹ still from SQL**,
ML only finds structure:

| Capability | Technique |
|---|---|
| Anomalies | IsolationForest over log-amount, category z-score, merchant rarity |
| Forecast | per-category LinearRegression on the monthly series |
| Recurring / subscriptions | DBSCAN on per-merchant amount + interval regularity |
| Auto-categorise | TF-IDF (char n-grams) + LogisticRegression, abstains on weak signal |

Exposed at `/ml/anomalies|forecast|recurring|categorize` (cached by row count). Anomaly,
forecast and projection are wired into chat via the ML gate (`ml_answer`); **recurring is
now also chat-wired** through the Intelligence layer (§10A), with a known-subscription
fallback when no stable cadence is detected.

---

## 10A. Intelligence Engine layer (pre-computed financial intelligence)

The shift from a reactive query engine toward a **Financial Intelligence Engine**: rather
than deriving everything at question time, the engines run **on upload** and their findings
are persisted, so synthesis questions become a table read.

**Flow:** `Upload → Insight Engine (compute_insights) → insights table → Question → Answer`.

| Engine | Produces | Live example |
|---|---|---|
| Financial Health | 0–100 from 4 pillars (savings, spending discipline, income stability, diversification) + rating | "76/100 Good" |
| Risk | rule-based `risk_score` 0–100 + level + flags (thin savings, overspend months, rising discretionary, income/merchant concentration, thin buffer) | "30/100 Low" |
| Behavioural | weekend ratio, end-of-month ratio, impulse share, merchant dependency | "impulse 22%" |
| Transaction Impact | signed per-transaction impact (size vs largest, ± by direction), deduped by merchant | "Salary +100 / Zerodha −100" |
| Category Trend | recent-vs-prior monthly average per category over 3/6/12-month windows | "Healthcare ▲7%" |
| Recurring | DBSCAN auto-detected subscriptions (no preset list), known-list fallback | "what subscriptions do I have?" |
| Insight digest | the above persisted as ranked rows; answers "what patterns do you see?" | top findings |

**No-hallucination preserved.** Every figure is computed in SQL inside `txn_store`; the
Intelligence gate (§5) renders answers **deterministically — the LLM is not on this path.**
The `insights` table stores `{type, title, explanation, score, evidence}` and is surfaced
via `GET /insights` and the chat Intelligence gate; it is pre-computed on upload and on
server startup for already-loaded data.

**Deferred by design:** a **Correlation Engine** (event→effect sequence analytics, e.g.
"what happens after a salary credit") — the one genuinely new modelling task — and an
**embedding-based intent router** (the current regex+LLM router scores 41/41 + 1000/1000,
so replacing it is risk without payoff). See §15.

---

## 11. Quality & verification

Correctness is measured, not asserted. Harnesses compare live `/query` answers to values
computed independently from SQL.

| Suite | Result |
|---|---|
| Factual battery — `scripts/test_qa_1000.py` (1,000 verified Q&A) | **1,000 / 1,000 (100%)**, all routed to SQL, 0 wrong numbers |
| Advisory grounding — 17 advisory questions | **17/17 grounded** (0 numbers outside the fact sheet) |
| Vague / parrot battery — `scripts/test_vague_1000.py` | **0 parrots across 664 vague questions**; non-finance "should I…" correctly nudged |

"Parrot" = a random/off-topic question echoing a previous answer; the routing fixes
(finance-anchored advice gate, finance-relevance gate on the router, nudge-instead-of-
advice on unmatched input) drove this to zero.

---

## 12. Tech stack

| Layer | Choice |
|---|---|
| Service | Python · FastAPI · uvicorn (port **5667**, env `PORT`) |
| Storage | SQLite (local) + hybrid search index (BM25 + vector RRF) |
| LLM | Llama 3.1 8B via Ollama (local, offline) |
| ML | scikit-learn (+ numpy, scipy) |
| PDF parse | PyMuPDF (`ROW_RE` row extraction; no Camelot/cloud) |
| Frontend | React / Vite (Penny UI) |

Nothing on the query path requires the network.

---

## 13. Security & privacy

- **Local-only:** statements live in on-device SQLite; the model runs on-device. No data
  leaves the machine on the query path.
- **Read-only:** the system answers questions; it never moves money or writes to a bank.
- **No credentials:** it ingests a statement file; it never asks for bank logins.
- **Honest boundaries:** unknown merchant → "no transactions found" (not a guessed
  total); investment-advice questions get general principles, not specific securities.

---

## 14. Scalability

- Aggregations are indexed SQL over decomposed date columns; verified at 1,05,000 rows
  with exact results and sub-second typical query latency on the deterministic path.
- LLM cost is bounded and constant — prompts are a small fact sheet (~1 KB), never the
  data — so scale is governed by SQLite, not the model.

---

## 15. Roadmap

**Done this cycle** (see §10A): Insight Engine + insights table · Financial Health score ·
Risk Engine · Behavioural analytics · Transaction Impact · Category-Trend (3/6/12-mo) ·
recurring-detection wired into chat.

**Next:**
1. **Correlation Engine** — event→effect sequence analytics ("what follows a salary credit");
   the only roadmap item that is genuinely new modelling, deferred to last.
2. **Hybrid intent routing** — embedding-similarity classification, only once the regex layer
   strains (today it scores 41/41 + 1000/1000 with 0 mis-routes).
3. **Phase 3** — full What-if simulator (a deterministic "cut X by Y%" already exists),
   Budget Optimizer, Goal Planner.
4. Bank-specific statement parsers (HDFC, SBI, ICICI) beyond the current layout.
5. Extend number-validation to the follow-up path (`followup_response`).
6. On-device packaging for the phone target.

---

## 16. Glossary

- **Penny / SQL layer** — the deterministic database layer that produces every figure.
- **Grounded advice** — LLM prose constrained to numbers from a SQL-computed fact sheet,
  validated before display.
- **Deterministic** — same input → same exact output.
- **Parrot** — an off-topic question wrongly echoing a previous answer (eliminated).
- **Offline / on-device** — runs locally with no network on the query path.

---

*Reflects the build and measurements as of this revision; scope is locked collaboratively
before each stage.*
