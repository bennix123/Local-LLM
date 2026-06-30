# Penny — Low-Level Design (LLD)

**Scope:** implementation-level design of the offline statement engine (`finquery/`).
Companion to `Penny_HLD_Technical.md` (architecture) — this document is the
function/module/contract reference. Anchored to the code in
`scripts/test_server.py` and `backend/src/services/{txn_store,ml_insights}.py`.

---

## 1. Module map

| Module | Key responsibility |
|---|---|
| `scripts/test_server.py` | FastAPI app, routing cascade, LLM calls, streaming, doc rendering |
| `backend/src/services/txn_store.py` | deterministic SQL layer ("Penny") — every figure |
| `backend/src/services/ml_insights.py` | sklearn models — anomalies, forecast, recurring, categorise |

Global config (env-overridable):

| Name | Default | Use |
|---|---|---|
| `LLM_MODEL` | `llama3.1:8b` | Ollama model id |
| `OLLAMA_URL` | `http://127.0.0.1:11434` | Ollama base |
| `FINQ_DB` | `data/live_txn.db` | SQLite path (`ts.DB_PATH`) |
| `USER` (const) | `"local"` | single-user id |

---

## 2. Data model & access

### 2.1 `transactions` table
| Column | Type | Notes |
|---|---|---|
| `user_id` | TEXT | scoping |
| `doc_name` | TEXT | statement file id (multi-doc) |
| `txn_date` | TEXT | `YYYY-MM-DD` |
| `year`,`month`,`day` | INT/TEXT | `month` = `YYYY-MM`; date decomposed for fast filters |
| `descr` | TEXT | raw line (multi-word merchants stored underscored: `Axis_Bank_Car_Loan`) |
| `merchant` | TEXT | canonical merchant |
| `category` | TEXT | classified (8 categories) |
| `debit`,`credit`,`balance` | REAL | signed money; `balance` running |
| `seq` | INT | original order (latest-balance) |

### 2.2 Scope builder — `_scope(user_id, doc_name, period) -> (where_sql, params)`
Single source of WHERE construction. `period` polymorphism:
- `"YYYY"` → `txn_date LIKE '2024%'` (prefix)
- `"YYYY-MM"` / `"YYYY-MM-DD"` → prefix match
- `"MD-MM-DD"` → `substr(txn_date,6,5)=?` — a calendar day **across all years** (a yearless
  date like "15 august" sums every 15-Aug; "overall" no longer drops the date). `_resolve_factual`
  combines a bare `pmonth`+`pday` into a full `YYYY-MM-DD` when a year is carried, else `MD-MM-DD`;
  `_extract_slots` detects the day even without an ordinal ("15 august", not just "15th").
- `(start, end)` tuple → `txn_date BETWEEN ? AND ?` (dates padded by `_norm_period`)
- `None` → no date predicate

### 2.3 Formatting helpers
- `inr(n)` → `₹` + Indian digit grouping, 2 decimals (`₹12,19,322.34`)
- `grp(n)` → Indian grouping for integers (`1,05,000`)
- `_table(headers, rows)` → GitHub-flavoured Markdown table
- `_mlabel("2024-03") → "Mar 2024"`, `_plabel`/`_dlabel` for period/day labels

---

## 3. `txn_store` API (deterministic; every figure from SQL)

| Function | Returns | Query summary |
|---|---|---|
| `overview(u,doc,period)` | `{count,debit,credit,net}` | `COUNT(*),SUM(debit),SUM(credit)` |
| `by_category(u,doc,period)` | `[(cat,Σdebit,n)]` desc | `GROUP BY category WHERE debit>0` |
| `by_month(u,doc,period)` | `[(month,Σdebit,Σcredit,n)]` | `GROUP BY month` |
| `merchant_spend(u,kw,doc,period)` | `{debit,credit,count,dcount}` | `WHERE LOWER(merchant)=? OR LOWER(descr) LIKE ?` |
| `income_by_source(u,doc,period)` | `[(merchant,Σcredit,n)]` desc | `WHERE credit>0 GROUP BY merchant` |
| `top_merchants(u,n,doc,period)` | `[(merchant,Σdebit,n)]` | `… ORDER BY Σdebit DESC LIMIT n` |
| `top_expenses(u,n,doc,period)` | `[(txn_date,merchant,debit)]` | `WHERE debit>0 ORDER BY debit DESC LIMIT n` |
| `extreme(u,kind,doc,period,merchant)` | `(txn_date,merchant,col)` | largest/smallest expense, largest income; optional merchant filter |
| `txn_count(u,kind,doc,period)` | `int` | `kind∈{debit,credit,upi}`; upi = `descr LIKE '%upi%'` |
| `amount_filter(u,op,amt,doc,period,merchant,category)` | `{count,total,max}` | `op∈{over,under}` on `debit`; optional merchant/category scope |
| `filtered_summary(u,merchant,category,period,doc,weekend,txn_type)` | `{count,debit,credit,total}` | scoped count+total; `weekend` (Sat/Sun), `txn_type∈{debit,credit}` — powers "only weekends" / "only debit" follow-ups |
| `latest_balance(u,doc,period)` | `float\|None` | `ORDER BY seq DESC LIMIT 1` |
| `coverage(u,doc)` | `(min_month,max_month,[years])` | available range |
| `months_list(u,doc,period)` | `[month]` | distinct months |
| `subscription_costs(u,doc,period)` | `[(m,months,total,count)]` | over `SUBSCRIPTION_MERCHANTS` |
| `subscription_trends(u,doc,period)` | `[(m,avg_h1,avg_h2,pct)]` | first-half vs second-half ₹/month |
| `category_movers(u,doc,period)` | `(prev_m,cur_m,[(c,cur,prev,Δ)])` | last two months |
| `advice_facts(u,doc,period)` | `str` | the pre-computed fact sheet (§7) |
| `dispatch_intent(intent,u)` | `str\|None` | runs the SQL for a structured intent |
| `health_score(u,doc,period)` | `dict\|None` | 4-pillar 0–100 composite (§3.1) |
| `risk_assessment(u,doc,period)` | `dict\|None` | rule-based `risk_score` + flags (§3.1) |
| `behavior_metrics(u,doc,period)` | `dict\|None` | weekend/EOM/impulse/dependency (§3.1) |
| `transaction_impact(u,n,doc,period)` | `[dict]` | signed per-direction-normalised impact, deduped (§3.1) |
| `category_trend(u,window,doc,period)` | `dict\|None` | recent-`k`-mo vs prior-`k`-mo per category (§3.1) |
| `compute_insights(u,doc,period)` | `[dict]` | runs the engines → ranked insight rows |
| `save_insights(u,items,doc)` / `get_insights(u,doc,type)` | `int` / `[dict]` | `insights` table I/O |

Constant sets: `DISCRETIONARY={Shopping,Food & Dining,Entertainment}`,
`FIXED_CATS={Utilities,Healthcare,Investment & Insurance}`,
`SUBSCRIPTION_MERCHANTS={Netflix,Spotify,Jio,Airtel,LIC Premium,Axis Bank Car Loan}`.

### 3.1 Intelligence engines (deterministic; every figure from SQL)

| Function | Returns | Computation |
|---|---|---|
| `health_score` | `{score,rating,components,…}` | 4 pillars ×0–25: savings `rate/30×25`; discipline `25×(1−overspent/months)`; stability `25×(1−min(CV/0.5,1))` (CV of monthly income); diversification `25−penalty(dep>50%)−penalty(top5>50%)`. Rating ≥85/70/55/40 |
| `risk_assessment` | `{risk_score,risk_level,flags[]}` | Σ flag severities (cap 100): neg-savings +35, rate<10% +22, overspend-months +15/22, rising discretionary >30% +15, single-income ≥80% +20 (≥60% +12), top-5 ≥60% +10, buffer <1 mo +10. Level ≥66/35/15 |
| `behavior_metrics` | dict | weekend vs weekday per-day (`strftime('%w')`), EOM (day≥21) vs SOM (day≤10), impulse share (debits<₹500), top-merchant dependency |
| `transaction_impact` | `[{date,merchant,amount,direction,impact}]` | top debits & credits queried **separately**; `impact = ±amount/max(that direction)×100 (+8 committed/income)`, deduped to heaviest per merchant |
| `category_trend` | `{window,recent,prior,movers[]}` | per-category recent-`k`-mo avg vs prior-`k`-mo avg, % change; `window∈{3,6,12}` |
| `compute_insights` | `[{type,title,explanation,score,evidence}]` | runs the engines → ranked insight rows |

`insights` table (the pre-compute store):
```sql
CREATE TABLE insights (
  id INTEGER PRIMARY KEY, user_id TEXT, doc_name TEXT,
  type TEXT,            -- health | risk | pattern | behavior | impact
  title TEXT, explanation TEXT, score REAL,
  evidence TEXT,        -- JSON of supporting numbers
  created TEXT DEFAULT CURRENT_TIMESTAMP);
```
Populated in `/upload` and on startup. Server-side, `intelligence_answer(q)` dispatches to
`health_answer` / `risk_answer` / `behavior_answer` / `impact_answer` / `cattrend_answer` /
`recurring_answer` / `insights_answer`, each rendering **deterministically** (no LLM).

---

## 4. Request routing — `query(request)` cascade

`POST /query` body: `{question:str, thread:str?, reset:bool?}`. The handler is an
ordered cascade; first matching stage returns. `tid` selects per-thread state.

```
g0   q == ""                                  -> GREETING                       [chat]
g0   overview.count == 0                       -> "upload a statement"           [chat]
g0   no [A-Za-z0-9 Devanagari]                 -> DIDNT_CATCH                     [chat]
gRES _resolve_conversation(q, state)           -> rq (standalone query)          ◀ NEW (§4a)
        reset signal -> clear thread + ack; persists the merged scope to ctx every turn;
        ALL gates below route on rq (logging/_append_log keep the original q)
g1   ctx and _FUP_ATTR and _REFS_RE and        -> followup_response  (original q) [chat]
        not _resolve_factual and not analytics_answer
gML  _ANOM_RE | _FCAST_RE | _PROJ_RE  (rq)     -> ml_answer(rq)   (if non-None)   [ML]
gINT _HEALTH_RE|_RISK_RE|_RECUR_RE|_IMPACT_RE| -> intelligence_answer(rq)         [SQL]
        _CATTREND_RE|_BEHAVE_RE|_PATTERN_RE (rq)   deterministic scores; non-None wins
g2   _ADVICE_RE | _REASON_RE  (rq)              -> grounded_advice(rq)            [advice]
g3   analytics_answer(rq) is not None          -> that markdown                  [SQL]
g4   _resolve_factual(rq, ctx).type            -> dispatch_intent                [SQL]
g5   llm_route(rq, history)  -> intent:
        smalltalk->GREETING | help->caps | followup(&history)->followup
        | unknown->DIDNT_CATCH
        | advice (& (_FIN_RE|_ADVICE_RE|_REASON_RE)) -> grounded_advice
        | else -> dispatch_intent ; if None -> DIDNT_CATCH
g6   regex fallback (LLM down): HELP_RE | CONVO_RE | ts.answer | DIDNT_CATCH
```

Design rules encoded here:
- **Deterministic before model:** self-contained money questions resolve at g3/g4 and never touch the LLM.
- **ML before advice:** anomaly/forecast/projection (gML) take the models, not narrative.
- **Intelligence before advice (gINT):** health/risk/behaviour/impact/trend/recurring/patterns get the deterministic scored answer, not an LLM narrative — every figure from SQL. Guarded so "which months were risky" defers to the per-month analytics handler and "which subscription increased" defers to the subscription-trend handler.
- **Finance-gate on router advice (g5):** `type=="advice"` is honoured only with a finance signal — stops "should i text my ex" getting a savings lecture.
- **No parroting:** unmatched/known-no-answer → `DIDNT_CATCH`, never a recycled advice dump.

### 4.1 Routing regexes (intent detection)
| Regex | Routes to | Catches (examples) |
|---|---|---|
| `_ADVICE_RE` | grounded_advice | roast, "should I cut", "save money", "am I overspending" |
| `_REASON_RE` | grounded_advice | "how am I doing", "how dependent", "what trends", "which categories need limits", "key takeaways", concept-comparison (cash vs digital) — **finance-anchored** |
| `_FIN_RE` | gate (not a router) | any money signal; gates g5 router-advice |
| `_ANOM_RE` | ml_answer | unusual, anomal, suspicious, "far larger than normal", flag, fraud, outlier |
| `_FCAST_RE` | ml_answer | forecast, predict, "next month", "what will I spend" |
| `_PROJ_RE` | ml_answer | annual, yearly, run-rate, "at this rate/pace", "save this year" |
| `_HEALTH_RE` | intelligence→health | "how healthy", "rate my finances", "financial report card" |
| `_RISK_RE` | intelligence→risk | "what risks", "am I overspending", "what should I worry" (defers "which months") |
| `_RECUR_RE` | intelligence→recurring | "subscriptions", "recurring bills" (defers "which increased" → subscription-trend) |
| `_IMPACT_RE` | intelligence→impact | "which transactions had the biggest impact" (checked before `_HEALTH_RE`) |
| `_CATTREND_RE` | intelligence→cat-trend | "which categories are growing fastest", "getting out of control" |
| `_BEHAVE_RE` | intelligence→behaviour | "spending habits", "weekends", "impulsive spender" |
| `_PATTERN_RE` | intelligence→insights | "what patterns do you see", "what stands out" |
| `_FUP_ATTR`/`_REFS_RE` | followup | "which/why/when…" referencing the previous answer |
| `HELP_RE`/`CONVO_RE` | caps/greeting | regex fallback when the router is down |

---

## 4a. Conversational resolution layer (`ConversationState` + `_resolve_conversation`)

The cascade's analytics/ML/advice stages re-parse the *raw* question and are context-blind;
only `_resolve_factual` reads `ctx`. So a bare analytics follow-up ("Average transaction"
after "Transactions at Zomato in 2024") was answered account-wide. The resolution layer fixes
this **once, before routing**, so every engine receives a fully-resolved standalone query.

- **`ConversationState`** (dataclass) is a typed view over the per-thread `ctx` dict.
  `from_ctx` / `to_ctx` keep the **legacy keys** (`type/start/end/category/merchant/n`) so
  `_resolve_factual`, `_save_ctx` and old `chats.json` keep working; new fields
  (`metric`, `filters`, `comparison`, `txn_type`, `prev_route`, `prev_answer`, …) are additive.
- **`_resolve_conversation(q, state)`** rewrites an elliptical follow-up into a standalone
  query by injecting the carried scope, and returns the merged `scope` (persisted to `ctx`
  every turn — so context flows no matter which engine answers, not just the factual path):
  - bare metric → canonical stem + scope: `"average"` → `average transaction at Zomato in 2024`
  - comparison: `"compare with swiggy"` → `compare Zomato vs Swiggy in 2024`
  - filter: `"only weekends"` → `… at Zomato in 2024 on weekends` (→ `filtered_summary`)
  - **conservative:** a fresh thread (no carried scope) is always a passthrough, so single-turn
    suites (golden, 1000-factual) are unaffected; only multi-turn behaviour changes.
  - period uses the same combine-with-carried-year logic as `_resolve_factual` (so
    `"february?"` after `"…january 2024"` → 2024-02, never cleared); period phrases are only
    *injected* for analytics-metric follow-ups (pure period follow-ups stay with `_resolve_factual`).
- **Reset:** `_RESET_RE` ("start over", "forget that", "new chat") clears the thread;
  `_SCOPE_CLEAR_RE` ("overall", "everything") drops the entity for one query.
- **Logging:** `_log_conv` emits a structured `[conv] {original, resolved, signals, before, after}`
  line whenever a rewrite happens (route + response are in `chats.json` via `_append_log`).

Integration: `query()` builds `state`, calls `_resolve_conversation`, persists the scope, then
routes **every** gate (gML/gINT/advice/analytics/factual/router) on the resolved `rq` while
logging the original `q`.

---

## 5. Intent resolution (deterministic, pre-LLM)

- `_extract_slots(q)` → reads intent / period(full|month|day|range) / category / merchant
  / `count_kind` deterministically. Merchants from a DISTINCT-merchant lookup (longest
  match first). Biggest/smallest checked **before** count; honesty-guard stopwords stop
  verb phrases ("saving more") becoming a "merchant".
- `_resolve_factual(q, ctx)` → standalone slots, filling missing slots from thread `ctx`
  on elliptical follow-ups (continuation/reference markers). Primary factual path. A
  period-widening follow-up ("and the whole year?") widens the thread's period to its full
  year while KEEPING the carried category/merchant (instead of falling through to the LLM).
- `_apply_guards(intent, q)` (after `llm_route`) → deterministic overrides for period
  parsing, income/count keywords, table-only-when-asked, extreme direction, explicit-
  date-isn't-a-followup, spend-forcing — fixes the 8B router's weak spots.
- `_save_ctx(ctx, intent)` → persists resolved slots for the next turn.
- `CTX` slot keys: `{type,start,end,category,merchant,n}`.

### 5.1 `analytics_answer(q)` (g3) — deterministic analytics
Order of internal branches: **what-if** → **financial-reasoning(0)** → **count-above-threshold/avg**
→ percent → exclusion → average → which-month(argmax/argmin) → top-category → top-merchant →
amount-filter → multi-entity → compare/difference. Notable:
- **what-if:** `(?:cut|reduce|trim…)\b.*?\bby\s+(\d+)\s*%` + a known category/merchant →
  `saved = pct × spend`; returns saving + per-month + per-year (exact).
- **amount-filter:** `_parse_amount` accepts any amount (3-digit, decimals, "₹/rs/rupees"),
  optionally scoped to a merchant/category via `amount_filter(...,merchant,category)` —
  "transactions on Zomato above 500" → count + total for Zomato over ₹500.
- **count-above-threshold/avg:** "how many transactions above the average on X" → computes the
  scoped average (or an explicit threshold), then counts above/below it.
- **year-as-amount guard:** `_strip_cmp_amounts` blanks "under 2000" / "over 2024" before the
  period parser, so an amount in the year range is never misread as a YEAR.
- **financial-reasoning:** savings rate, savings target (20%), runway, risky months,
  consistency (CV), income trend (H1 vs H2), income sources, spending profile, habits,
  subscriptions trend/list (triggers also on "recurring"), online-shopping freq.
- Returns Markdown or `None` (not an analytics question → cascade continues).

---

## 6. LLM subsystem

### 6.1 Router — `llm_route(question, history) -> dict|None`
- Ollama `/api/chat`, `format:"json"`, `temperature 0`, `num_ctx 2048`, `keep_alive 10m`.
- System = `ROUTER_SYSTEM` (intent schema + examples). Feeds the last **2 real** exchanges
  (advice placeholders filtered). Output JSON: `{type,category,merchant,n,start,end,table}`.
- The model **classifies only** — never emits a figure.

### 6.2 Grounded advice — `grounded_advice(q, thread)`
```
facts  = ts.advice_facts(USER)
reply  = _llm_complete(GROUNDED_ADVICE_SYSTEM + facts, q)      # non-stream, retry x1
reply  = strip leading "answer:"/"penny:"
ok,why = _advice_grounded(reply, facts)
return ok ? stream(reply) : stream(_advice_fallback(q))        # number guard
```
- `_llm_complete(system,user,num_predict=512,temperature=0.2)` — `num_ctx 4096`,
  `keep_alive 30m`, `urlopen` timeout 150 s, retries once (cold-start tolerance).
- `GROUNDED_ADVICE_SYSTEM` contract: use ONLY the fact-sheet numbers; never compute /
  round / sum; write amounts verbatim; 3–6 sentences; no tables; never name a specific
  security; never leak the words "FINANCIAL FACTS"/"PROJECTION"/"run-rate"/"fact sheet".

### 6.3 Number-validation — `_advice_grounded(reply, facts) -> (bool, reason)`
The guarantee enforcer. Extraction + tolerance:
```
amounts: _AMT_RE matches  "₹<grouped>"  OR  "<n> (lakh|crore|cr|k|thousand|million|mn)"
         word-amounts multiplied via _NUM_MULT
percents: _PCT_RE matches "<n>%"
PASS iff: every reply-amount within max(₹1, 0.5%) of some facts-amount
      AND every reply-percent within 0.5 pt of some facts-percent
```
Only ₹-amounts and %-values are policed (the hallucination-critical quantities); bare
counts are not. Fail → deterministic `_advice_fallback(q)` (question-aware: invest /
dependence / limits / trend / transactions / glance branches).

### 6.4 Follow-up — `followup_response(q, history, thread)`
`_llm_words` (streaming, `num_predict 80`, temp 0.3) over the last 4 turns, answering in
one sentence from facts already shown. (Note: **not** number-validated — a known gap.)

---

## 7. Fact sheet — `advice_facts(user_id)` spec

Plain-text, one fact per line; every figure pre-computed so the LLM only phrases:
`PERIOD`, `INCOME`(total+avg/mo), `SPENDING`(total+avg/mo), `NET SAVED`(total+avg/mo+rate%),
`INVESTABLE SURPLUS`, `SAVINGS-TARGET BENCHMARK`(20%), `EMERGENCY RUNWAY`(balance÷avg spend),
`SPENDING BY CATEGORY`(each: ₹, % of spend, n, discretionary/fixed flag),
`MOST FLEXIBLE CATEGORIES`, `INCOME SOURCES`(each: ₹, % of income, n) + `INCOME DEPENDENCE`
(largest-source %), `TOP MERCHANTS` + `MERCHANT CONCENTRATION`(top-5 %), `RECURRING BILLS`,
`LARGEST SINGLE TRANSACTIONS`(top-5), `DIGITAL FOOTPRINT`(UPI count/%),
`SPENDING/INCOME TREND`(H1 vs H2 ±%), extreme months, `PROJECTION (run-rate)`.

---

## 8. ML layer

### 8.1 Chat routing — `ml_answer(q) -> str|None`
Caching wrapper `_ml(kind, fn)` memoises by `(kind, overview.count)` (clears on row-count
change). Branches:
- `_ANOM_RE` → `ml.anomalies(USER)` → Markdown table `[Date, Merchant, Amount, Why flagged]`,
  largest first; empty → "No standout anomalies".
- `_FCAST_RE` → `ml.forecast(USER)` → "Forecast for <month>" + total (± band) +
  `[Category, Predicted next month, Trend]`.
- `_PROJ_RE` → **deterministic** run-rate: `annual ≈ avg_monthly_spend × 12`,
  `annual savings ≈ avg_monthly_net × 12` (no LLM, no model — pure arithmetic from SQL).

### 8.2 `anomalies(user_id, n=12, contamination=0.004)`
- Rows: `txn_date,merchant,category,debit,day WHERE debit>0` (skip if <50).
- Features (per row): `[log1p(amount), z_cat, log1p(merchant_freq), day, cat_code]` where
  `z_cat` = robust deviation from per-category **median/MAD** (`/(1.4826·MAD)`).
- `StandardScaler` → `IsolationForest(n_estimators=200, contamination, random_state=RNG)`.
- Candidates = `(iso==-1) OR (z_cat>3) OR (rare_merchant & amt>2×cat_median)` **AND z_cat>0**
  (upper-tail only) → sorted by amount desc, top `n`.
- Reason per item: "rare merchant, large charge" | "N× your usual <m>" | "well above your
  <cat> norm" | "unusual for your pattern".

### 8.3 `forecast(user_id)`
- Per category: monthly series → `LinearRegression` on month index → predict next index
  (clamped ≥0); `band = resid.std()`; `trend` from slope vs 2% of recent mean.
- Total = Σ predictions; total band = `sqrt(Σ band²)`; `next_month` via `_next_month_label`.
- `<3 months` → `next_month=None` (caller returns None → cascade continues).

### 8.4 Recurring detection — now chat-wired
`recurring(user_id, min_occurrences=3)` (DBSCAN on per-merchant amount cluster + interval
regularity) is **wired into chat** via `recurring_answer()` (Intelligence gate, §3.1): it
renders cadence / amount / confidence and **falls back** to `subscription_costs()` (the
known-merchant view) when no stable cadence is found. Still HTTP-only:
`categorizer_report(user_id)` (TF-IDF char n-grams + LogisticRegression).

---

## 9. Streaming protocol

`stream_text(path, text)` → `StreamingResponse(media_type="application/x-ndjson")` emitting:
```
{"type":"meta","path":"<SQL|ML|advice|chat>"}
{"type":"chunk","content":"…"}   (repeated)
{"type":"done"}
```
`stream_markdown(text)` chunking rule: a Markdown **table** block is emitted whole (so it
never renders half-built); **prose** is emitted word-by-word. `_llm_words` buffers Ollama
tokens into whole words. Client-side, a **"Penny is thinking" indicator** (animated dots)
shows the instant the user hits Enter and is removed when the first `meta`/`chunk` arrives —
covering the latency of LLM-backed answers.

---

## 10. Conversation state & persistence

- `THREADS[tid] = {"ctx":{}, "history":[]}`; `_thread(tid)` lazily creates; `reset` clears.
- `remember(history, q, a)` appends `{q, a[:300]}`, trimmed to last 6.
- `_append_log(thread, q, a, route)` → atomic rewrite of `data/chats.json`:
  `{ <tid>: {created, updated, messages:[{ts,question,answer,route}], state:{ctx,history}} }`;
  `GET /chats` reads it.
- **Survives restarts & refreshes (no Redis):** each turn snapshots the live `{ctx, history}` into
  the thread's `state`; `_thread(tid)` calls `_rehydrate(tid)` on a cold thread to restore it after a
  restart. The browser keeps a **stable thread id in `localStorage`**, so a page refresh reuses the
  same thread (context persists across reloads); "New chat" rotates the id. Single-process,
  file-backed — no external cache, consistent with the offline/on-device target.

---

## 11. HTTP API contracts

| Endpoint | Method | Response |
|---|---|---|
| `/query` | POST | ndjson stream (§9) |
| `/upload` | POST | parse statement PDF → SQLite |
| `/chats` | GET | JSON of `chats.json` |
| `/dashboard`, `/transactions` | GET | JSON for the React UI |
| `/ml/anomalies\|forecast\|recurring\|categorize` | GET | JSON (`_ml`-cached) |
| `/insights` | GET | JSON: pre-computed `insights[]` + live `health` + `risk` |
| `/hld`, `/lld`, `/roadmap` | GET | rendered HTML (this doc family) |
| `/hld.md`, `/lld.md`, `/roadmap.md` | GET | raw Markdown |
| `/` | GET | the chat UI (`PAGE`) |

**Runtime.** Serves on **port 5667** by default (`uvicorn`, host `0.0.0.0`); override with the
`PORT` env var. The batch files (`start-penny.bat` + helpers) launch the server and an
auto-reconnecting tunnel on this port.

**Pinned DB.** `ts.DB_PATH` resolves to an **absolute** `data/live_txn.db` (independent of
CWD); `FINQ_DB` overrides it **only if** that path exists, else it falls back to the pinned
DB. Startup logs `[db] using …`. `init_db()` runs at boot to ensure the `insights` table
exists; `compute_insights` is run + persisted on startup for already-loaded data.

Doc rendering: `_md_to_html(md)` — stdlib Markdown→HTML (headings, GFM tables, fenced
code, lists, blockquotes, hr, inline bold/italic/code/links) wrapped in `_DOC_SHELL`
(Penny palette CSS). No CDN; fully offline.

---

## 12. Error handling & degraded modes

| Condition | Behaviour |
|---|---|
| Ollama down / cold | `_llm_complete` retries once; `_warmup()` thread pre-loads at boot; advisory falls back to `_advice_fallback` (deterministic) |
| LLM emits an off-fact number | `_advice_grounded` rejects → deterministic fallback |
| Router returns junk / off-topic | g5 `unknown`/non-finance → `DIDNT_CATCH` nudge (no parrot) |
| Unknown merchant | honest "No transactions found for X" (never a grand total) |
| `<50` rows (anomaly) / `<3` months (forecast) | model returns empty/None → graceful message |

---

## 13. Verification harnesses

| Script | What it checks |
|---|---|
| `scripts/test_qa_1000.py` | 1,000 SQL-verified factual Q&A → 1000/1000 |
| `scripts/golden_suite.py` | 41 questions × 10 categories → 41/41 (per-category + per-priority) |
| `scripts/test_vague_1000.py` | parrot/routing at scale (0 parrots across 664 vague) |

Verdict kinds: deterministic (amount/percent/count vs SQL truth) · advice (route=advice +
fully grounded + on-topic) · probe (capability + on-topic, accepts route ML/SQL/advice).

---

*LLD reflects the implementation at this revision. Update alongside the code; the routing
cascade (§4) and the number-validation contract (§6.3) are the two parts most worth
keeping in sync.*
