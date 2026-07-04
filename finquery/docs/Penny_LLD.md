# Penny — Low-Level Design (LLD)

**Scope:** implementation-level design of the offline statement engine (`finquery/`).
Companion to `Penny_HLD_Technical.md` (architecture) — this document is the
function/module/contract reference. Anchored to the code in
`scripts/test_server.py` and `backend/src/services/{txn_store,ml_insights}.py`.

---

## 1. Module map

| Module | Key responsibility |
|---|---|
| `scripts/conversation.py` | **CanonicalQuery** (the single resolved query object every engine consumes) + **DialogueState** (full dialogue memory, superset of the legacy `ConversationState`). Pure typed data + serialisation; no DB. See §4c and `docs/Penny_Conversation_Redesign.md`. |
| `scripts/test_server.py` | FastAPI app, routing cascade (incl. concept grounding §4b, canonical pipeline §4c), LLM calls, streaming, doc rendering |
| `backend/src/services/txn_store.py` | deterministic SQL layer ("Penny") — every figure |
| `backend/src/services/ml_insights.py` | sklearn models — anomalies, forecast, recurring, categorise |
| `plaid_integration/` (`plaid_service` · `plaid_ingest` · `plaid_routes`) | Plaid **Sandbox** bank link + `/transactions/sync` pull, mapped onto the `transactions` schema; a sync **replaces** the ledger like `/upload` and runs the same post-ingest refresh (currency detect, insights, ML-cache + **vocab-cache reset**) |

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
| `currency` | TEXT | per-document (`INR`/`GBP`/…); drives display formatting |
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
- `inr(n)` → active-currency symbol + locale digit grouping, 2 decimals — `₹12,19,322.34`
  (INR: lakh/crore) or `£1,219,322.34` (GBP/USD/EUR: western thousands)
- `grp(n)` → same locale grouping for plain integers/counts (`1,05,000` vs `105,000`)
- `set_currency(cur)` / `detect_currency(u,doc)` — write / read the module-global `CURRENCY`
  (`_CUR_SYM`: INR→₹, GBP→£, USD→$, EUR→€); `_grouped` selects Indian vs western grouping. The
  server calls `set_currency(detect_currency(USER))` at boot and after every upload.
- `_table(headers, rows)` → GitHub-flavoured Markdown table
- `_mlabel("2024-03") → "Mar 2024"`, `_plabel`/`_dlabel` for period/day labels

---

## 2.4 Statement ingestion (multi-format · ZIP · per-document currency)

`ingest_pdf(path, doc_name, user)` auto-detects the layout and streams rows into SQLite:
- **DR/CR row format** — `parse_pdf` + `ROW_RE` (one line = `DD-MM-YYYY … DR|CR amount balance`);
  the synthetic/Indian and SBI-style statements (₹).
- **Barclays columnar** — `parse_barclays` (selected by `is_barclays`): groups PyMuPDF *words* into
  rows by y-position and buckets them into Date / Description / Money-out / Money-in / Balance
  columns by x-threshold. `DD MMM` dates take their **year from the statement-period header**
  (Dec→Jan rollover handled); **same-day rows inherit the date**; multi-line descriptions are
  stitched; Start/End-balance rows bound the table; UK merchant/category extraction; currency `GBP`.
- **`is_statement_pdf(path)`** = `is_barclays(head) or is_transaction_statement(head)` — picks
  statement PDFs out of an uploaded **ZIP** (non-statement files ignored) and rejects non-statements.

**Per-document currency.** Each row stores `currency`; the module global `CURRENCY`
(`set_currency` / `detect_currency`) drives symbol + digit grouping in `inr()`/`grp()` — ₹ uses
Indian lakh/crore grouping, £/$/€ use western thousands. The server sets it from the loaded/uploaded
statement. Mixed-currency accounts use the dominant currency (a known limitation), so `/upload`
**replaces** prior data by default — each analysis stays single-currency.

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
| `latest_balance(u,doc,period)` | `float\|None` | `ORDER BY seq DESC LIMIT 1` (closing balance) |
| `balance_extreme(u,kind,doc,period)` | `(date,balance)\|None` | min/max **running** balance — `ORDER BY balance ASC\|DESC LIMIT 1` |
| `merchant_category(u,kw,doc,period)` | `[(cat,n)]` | which category(ies) a merchant sits in — `GROUP BY category` |
| `merchant_dates(u,kw,doc,period)` | `[(date,debit,credit,bal)]` | the dates a merchant appears (excludes year-0000 rows) |
| `payment_interval(u,kw,doc,period)` | `{count,avg_days,min_days,max_days,first,last}` | mean #days between a payee's consecutive dated transactions |
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
gCON concept_answer(rq) is not None            -> that markdown                  [SQL]  ◀ NEW (§4b)
        semantic concepts (gambling / loans / bank fees) grounded to REAL ledger
        merchants, or an honest "couldn't find any" — never a widened total
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
- **Ground or refuse (gCON, §4b):** a concept token that can't be grounded to ledger data must
  never silently widen the query ("how many *gambling* transactions in June" must not become
  the count of ALL June transactions).
- **Zero-result ≠ scope (g4/g5):** when the answer is "No transactions found for 'X'", `X` is
  stripped from the intent before `_save_ctx` — a name with provably no data must not pin
  later questions ("show me all transactions over £100" after a failed "did I pay Thames
  Water?" was answered "0 transactions *at Thames Water*").

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
| `_RECUR_RE` | intelligence→recurring | "subscriptions", "recurring bills", **"direct debits", "standing orders"** (defers "which increased" → subscription-trend) |
| `_CONCEPTS` triggers | concept_answer (§4b) | "gambling/betting", "loans/repayments/mortgage/EMI", "bank fees/service charges/overdraft" |
| `_IMPACT_RE` | intelligence→impact | "which transactions had the biggest impact" (checked before `_HEALTH_RE`) |
| `_CATTREND_RE` | intelligence→cat-trend | "which categories are growing fastest", "getting out of control" |
| `_BEHAVE_RE` | intelligence→behaviour | "spending habits", "weekends", "impulsive spender" |
| `_PATTERN_RE` | intelligence→insights | "what patterns do you see", "what stands out" |
| `_FUP_ATTR`/`_REFS_RE` | followup | "which/why/when…" referencing the previous answer |
| `HELP_RE`/`CONVO_RE` | caps/greeting | regex fallback when the router is down |
| `_CATLOOKUP_RE` | merchant_category (§5.2) | "what category does Shein belong to" |
| `_DATELOOKUP_RE` | merchant_date (§5.2) | "on what date does X appear", "when did X pay me", "what date did my Sky bill go out", "when did I **last** shop at Aldi" (`date_dir` last/first) |
| `_INTERVAL_RE` | merchant_interval (§5.2) | "how many days between X payments", "how often do I pay X" |
| `_BAL_RE`+`_SMALL_RE`/`_BIG_RE` | balance_min/max (§5.2) | "lowest/highest balance recorded" |
| `_AMT_CMP_RE` | scope re-injection (§4a) | "above 500" as a *bare* follow-up keeps merchant+period; accepts `₹ £ $ € rs/inr/gbp/usd/eur/pounds/quid` (it was INR-only — "over £100" was invisible) |
| `_ARGMAX_ENT_RE` | scope re-injection (§4a) | "which merchant did I spend more" — inject period, not entity |

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
  - entity back-reference: `"this/that category"` → the carried NAME ("insights in this
    category" after a Healthcare turn → "insights in Healthcare"), same for "this
    merchant/shop/store" — so the ADVICE path sees the topic too, not just the factual path
    (the 8B model must never pick the topic itself from an account-wide fact sheet).
  - bare metric → canonical stem + scope: `"average"` → `average transaction at Zomato in 2024`
  - comparison: `"compare with swiggy"` → `compare Zomato vs Swiggy in 2024`
  - filter: `"only weekends"` → `… at Zomato in 2024 on weekends` (→ `filtered_summary`)
  - amount filter: `"above 500"` → `above 500 at Zomato in 2024` — merchant+period re-injected
    (`_AMT_CMP_RE`), so a threshold follow-up keeps its scope instead of going account-wide.
    **Only when bare:** an amount filter that names its OWN period ("show me all transactions
    over £100 in June") is a COMPLETE question, not an elliptical follow-up — nothing is
    injected (`has_amt and not own_period` in the elliptical test).
  - argmax entity: `"which merchant did I spend more"` → `… on 27 Mar 2026` — the carried
    **period** is injected but the merchant is **not** pinned (`_ARGMAX_ENT_RE`); the analytics
    top-merchant branch then answers the date-scoped argmax.
  - **re-parseable rendering:** `_period_phrase` emits forms the engines actually re-parse — a
    full date as `on 27 Mar 2026` (not ISO `2026-03-27`, which `_parse_period` would read as the
    bare year `2026`), and a yearless `MD-MM-DD` as `on 19 Dec` (which `_extract_slots` re-reads
    as that day across all years). This closes the old state↔string divergence where a carried
    date silently widened or dropped.
  - **conservative:** a fresh thread (no carried scope) is always a passthrough, so single-turn
    suites (golden, 1000-factual) are unaffected; only multi-turn behaviour changes.
  - period uses the same combine-with-carried-year logic as `_resolve_factual` (so
    `"february?"` after `"…january 2024"` → 2024-02, never cleared); period phrases are only
    *injected* for analytics-metric follow-ups (pure period follow-ups stay with `_resolve_factual`).
- **Reset:** `_RESET_RE` ("start over", "forget that", "new chat") clears the thread;
  `_SCOPE_CLEAR_RE` ("overall", "everything") drops the entity for one query.
- **Logging:** `_log_conv` emits a structured `[conv] {original, resolved, signals, before, after}`
  line whenever a rewrite happens (route + response are in `chats.json` via `_append_log`).

**Per-field transition policy.** Every turn produces a deterministic state transition; each field
has one explicit rule (centralised in `_resolve_conversation`, not scattered):

| Field | Policy |
|---|---|
| `merchant` | **replace** if this turn names one · **clear** on `_SCOPE_CLEAR_RE` ("overall") or income-context (`_NO_ENTITY_INJECT_RE`) · else **inherit** · **never pinned** on an "which merchant" argmax turn · a **"No transactions found" answer's name is never saved** as scope (§4 design rules) · a **markerless bare metric never adopts it** — inheritance into "how much did I spend?" needs a continuation/back-reference (§5) |
| `category` | **replace** if named · **clear** on scope-clear / income / an own-merchant turn · else **inherit** |
| `start`/`end` (period) | **replace** if this turn has one (a bare month/day **combines** with the carried year) · **clear** on scope-clear · else **inherit**; re-injected via `_period_phrase` in a re-parseable form · a carried **single-DAY** scope (`MD-…`/`YYYY-MM-DD`) never applies to a turn that names its OWN entity — "…IKEA on 1 July?" then "how much was my Bupa payment?" answers Bupa all-time, not "£0 on 1 Jul" (elliptical follow-ups still keep the day) |
| `metric` | **replace** — per-turn (average/highest/breakdown…); never accumulated |
| amount threshold | **per-turn** query modifier — applies to its own turn (re-injecting merchant+period); a later metric turn drops it |
| `txn_type` (debit/credit) | **merge** |
| `comparison` | **replace** — the two entities last compared |
| fresh thread | **passthrough** — no carried scope ⇒ no rewrite (single-turn suites unaffected) |

Integration: `query()` builds `state`, calls `_resolve_conversation`, persists the scope, then
routes **every** gate (gML/gINT/advice/analytics/factual/router) on the resolved `rq` while
logging the original `q`.

---

## 4b. Concept grounding layer — `_CONCEPTS` + `concept_answer(q)` (gCON)

Semantic concepts ("gambling", "loans", "bank fees") name no stored merchant or category, so
the keyword router used to **drop the token and answer the widened query** — "how many
gambling transactions in June" returned the count of ALL June transactions. The rule this
layer encodes: **ground a concept to data you can prove, or say you can't** — never silently
answer a broader question with confident numbers.

- **`_CONCEPTS`** — a list of `(label, trigger_regex, merchant_regex)`:

  | Concept | Trigger (question) | Grounds to (merchant names) |
  |---|---|---|
  | `gambling` | gambl\*/betting/casino/bookmaker/wager | `bet*`, unibet, casino, poker, bingo, lotter\*, ladbrokes, betfair, paddy power, william hill, betway, 888, sky bet, coral, bwin, betfred |
  | `loan repayments` | loans?/repay\*/mortgage/EMI/borrow\*/debt | loan, lend, mortgage, emi, klarna, finance/financing |
  | `bank fees` | bank fees?/fees?/service charges?/overdraft/penalt\* | `\bfees?\b`, `\bcharges?\b`, overdraft, penalt\* (word-bounded — "coffee" can't match "fee") |
  | `flights` | flights?/airfare/air travel/plane tickets/airlines/flying | ryanair, easyjet, jet2, wizz, tui, british airways, virgin atlantic, aer lingus, klm, lufthansa, emirates, …, airlines?/airways |
  | `coffee` | coffees?/lattes?/cappuccinos?/espressos? | costa, starbucks, caffè nero, nero, coffee |
  | `taxis & rides` | taxis?/cabs?/rideshare/ride-hail\*/minicabs? | uber (not uber eats), bolt, addison lee, free now, taxi, minicab |

- **Guards:** a `why …` question returns `None` (the advice path owns reasoning — "why was I
  charged overdraft fees?" gets a grounded explanation, not the total re-stated); and a
  **named stored merchant outranks a concept** ("how much on Uber?" is a merchant question
  even though "uber" triggers the taxis concept).

- **`concept_answer(q)`** iterates `_known_merchants()` against the concept's
  `merchant_regex`, then aggregates per matched merchant via `merchant_spend` (debit side
  only). Every number is SQL over merchants **that actually exist in the ledger**. Answer
  shapes, keyed off the question:
  - *count* ("how many …"): `**Gambling transactions in Jun 2026: 4**  (UniBet 2, Bet365 1, Pokerstars 1)`
  - *% of income* ("what percentage of my income goes on …"): concept debit ÷ `overview.credit`
    in the same scope, with the supporting figures listed.
  - *default*: total + txn count (+ `≈ £X/month` when the scope spans >1 month) and a
    per-merchant table when several merchants matched.
  - *nothing matched*: honest `**I couldn't find any <concept>-related transactions.**`
    (+ data coverage) — never a fallback to the account total.
- **Self-contained:** period comes from THIS question only (`_parse_period`, so "last three
  months" ranges work) — a concept question never inherits thread scope, which is what let a
  stale "May" leak into "what percentage of my income goes on loan repayments?".
- **Extending:** one `_CONCEPTS` entry (label + two regexes) adds a new concept; no other
  code changes. Concepts outside the lexicon fall through to the rest of the cascade
  (ultimately the LLM router when Ollama is up).

---

## 4c. Canonical query pipeline (`CanonicalQuery` + `build_canonical_query`)

The architecture review (`docs/Penny_Conversation_Redesign.md`, 91 context-loss points)
found one root cause: `_resolve_conversation` computed a fully-structured scope, then handed
downstream only a rewritten English string `rq`, and **every engine re-inferred** period /
merchant / category / amount from that text (17 call-site families; `_extract_slots` ran twice
per turn; two period-carry ladders had diverged). The redesign introduces a single typed
object consumed by all engines.

- **`CanonicalQuery`** (conversation.py) — the one resolved query. Fields: `intent_family`,
  `merchant/category/concept`, `start/end` (+ `period()` → the `_scope` period form),
  `metric/group_by/txn_type/count_kind`, composable `weekend/exclude/amount_op/amount`,
  `comparison`, `doc_name`, `date_dir`, `n`, clarify `options/phrase`, `carried_merchant/
  carried_category` (advice topic-pinning only). `to_intent()` returns the **exact**
  `dispatch_intent` dict (the factual path is byte-identical — guarded by the offline suites).
- **`build_canonical_query(q, rq, sc, state)`** assembles it ONCE. Critical distinction:
  - **Answer scope** (period/entity/concept/amount/filters) is read from `rq` — which already
    has the carried scope injected IFF this turn was an elliptical follow-up. It is NOT read
    from the persisted scope `sc`, because `sc` inherits the carried period/merchant
    unconditionally (correct for *persistence*, but would leak a stale scope into a reframing
    or standalone turn). This is why "what loans each month?" after "gambling in June" is
    all-time, and "what is my total spending?" after "Amazon in June" is account-wide (CLP-04).
  - `sc` supplies only the cross-turn extras (`txn_type/metric/comparison`), `doc_name`, and
    the `carried_*` topic for advice.
- **Cascade wiring** (`query()`): after `_resolve_conversation`, one `cq` is built and passed to
  every engine — `concept_answer(cq)`, `analytics_answer(cq)`, `intelligence_answer(cq)`,
  `ml_answer(cq)`, `grounded_advice(cq)`, and `dispatch_intent(det, USER, cq.doc_name)`. Each
  reads resolved fields; none re-parse. Engines also accept a raw string (via `_cq_from_text`)
  for the offline harness and the gate-0 guard, so those paths are behaviourally unchanged.
- **Determinism preserved:** every number still from `txn_store` SQL; `to_intent()` keeps the
  factual path identical; a fresh thread is a passthrough (single-turn suites unaffected). The
  two period-carry ladders are now unified (`_resolve_conversation` gained the bare-month/range
  fallbacks it was missing vs `_resolve_factual`).
- **DialogueState** (conversation.py) upgrades `ConversationState` with the fields the review
  found missing: `active_transaction`, structured `last_result`, `prev_spec`, composable
  `filters`, `group_by`, `amount_op/amount`, `comparison`, `presentation`, `confidence` —
  legacy ctx keys unchanged, so `_resolve_factual`/`_save_ctx`/`chats.json` keep working.

**Delivered on top of the foundation:** composable filter-stack (weekend + amount + exclude
in one `filtered_summary` query, CLP-6) and by-month/breakdown entity scoping ("Netflix per
month", CLP-3); the follow-up path is now number-verified (buffered reply checked against the
recent SQL answers; strayed number → deterministic restatement) and the number guard is
currency-aware (₹/£/$/€), closing the last hallucination hole.

**Staged (documented in the redesign doc):** ML/intelligence period+entity scoping (the
sklearn layer issues its own unscoped SQL; health/risk/patterns are account-wide by nature),
a prose response formatter (deferred — the current bold-headline + table format is already
structured; a rewrite is cosmetic and high-regression-risk), and the single-pass resolver
collapse — each behind the differential so `txn_store` behaviour stays frozen.

---

## 5. Intent resolution (deterministic, pre-LLM)

- `_extract_slots(q)` → reads intent / period(full|month|day|range) / category / merchant
  / `count_kind` deterministically. Merchants from a DISTINCT-merchant lookup (longest
  match first; cache `_KM`/`_KC`, dropped via `_reset_vocab()` whenever `/upload` or a Plaid
  sync replaces the ledger — the vocabulary always reflects the ACTIVE dataset). Biggest/
  smallest checked **before** count. The **honesty guard** covers `at/from/on/to/with/pay/
  paid <Name>`: an explicit name that resolves to no stored merchant becomes that merchant
  verbatim, so dispatch answers *"No transactions found for 'X'"* — **never the account-wide
  total** ("how much did I spend on Putney Cricket Club", "did I pay Thames Water").
  `_GUARD_STOP` (pronouns/temporal words/weekdays/month names) stops verb phrases ("saving
  more", "on weekends") becoming a "merchant". Fee phrases (`bank/account/service/overdraft/
  late/card + fee(s)/charge(s)`) map to a merchant-keyword search. "spending by category"
  with no named category maps to the full category table. Bare month names are kept as raw
  `pmonth` (`_parse_period(q, bare_month=False)`) so a thread's **carried year** scopes them
  ("in 2024 → and in May?" = May 2024); fresh threads resolve them to the statement's year.
- `_resolve_factual(q, ctx)` → standalone slots, filling missing slots from thread `ctx`
  on elliptical follow-ups (continuation/reference markers). Primary factual path. A
  period-widening follow-up ("and the whole year?") widens the thread's period to its full
  year while KEEPING the carried category/merchant (instead of falling through to the LLM).
  **Entity stickiness needs a marker:** a bare metric inherits the thread's merchant/category
  only on an explicit continuation ("and how much?") or back-reference — a markerless
  complete question ("how much did I spend?") is account-wide (R13 rule); the PERIOD still
  carries on markerless turns. **Ambiguity → ask:** when an explicit name matches ≥2 stored
  merchants (`_merchant_candidates`: "apple" → Apple Store, Apple Pay), the turn resolves to
  a `clarify` intent and Penny asks "Which one did you mean?" instead of guessing; nothing
  is saved to ctx, and the user's follow-up names the merchant.
- `_relative_period(q)` — the date resolver: this/last month·year, YTD, **today / yesterday /
  this·last week** (anchored on the statement's LATEST transaction date, not the wall
  clock — the data is historical), **quarters** ("Q2", "third quarter", optional year),
  "last N months" with digit or word numbers, last quarter. **No date in the question ⇒ the
  whole statement** — a period is never assumed (an inherited thread period is always shown
  in the answer's label).
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
- **amount-filter:** `_parse_amount` accepts any amount (3-digit, decimals, and the
  currency markers `₹ £ $ € rs/inr/gbp/usd/eur/pounds/quid` — it was INR-only, so
  "show me all transactions over £100 in June" fell through to a bare count), optionally
  scoped to a merchant/category via `amount_filter(...,merchant,category)` —
  "transactions on Zomato above 500" → count + total for Zomato over ₹500.
- **count-above-threshold/avg:** "how many transactions above the average on X" → computes the
  scoped average (or an explicit threshold), then counts above/below it.
- **year-as-amount guard:** `_strip_cmp_amounts` blanks "under 2000" / "over 2024" before the
  period parser, so an amount in the year range is never misread as a YEAR.
- **which-month gate guards:** a month NAME with no superlative ("what about June month"), a
  deictic *this/last/past month*, or a cadence *each/every/per month* is a **scope**, never a
  which-month argmax — "what bank fees have I been charged this month?" and "what loans am I
  repaying each month?" were both hijacked into "Highest-spend month".
- **multi-entity guard:** the *implicit* combine (two names, no compare word) skips
  date-lookup questions — "when did I last **shop** at **Aldi**?" names Aldi AND a stored
  merchant literally called "Shop", but is a `merchant_date` question, not "Aldi + Shop".
  An explicit "together/both/combined" still combines.
- **compare periods:** `_find_periods` resolves bare month names to the statement's year, so
  "did I spend more in May or June?" yields two periods and reaches the compare branch (it
  used to yield none and answer May's total only). `_relative_period` accepts word numbers —
  "over the last **three** months" → a 3-month range anchored on the latest data month.
- **financial-reasoning:** savings rate, savings target (20%), runway, risky months,
  consistency (CV), income trend (H1 vs H2), income sources, spending profile, habits,
  subscriptions trend/list (triggers also on "recurring"), online-shopping freq.
- Returns Markdown or `None` (not an analytics question → cascade continues).

### 5.2 Fine-grained lookup intents — `_special_intent(q)`
Checked **inside `_extract_slots`, before the generic count/spend/balance ladder**, so a
named-merchant/balance question isn't collapsed into a summary/count/closing-balance:

| Intent | Trigger (regex) | Dispatches to |
|---|---|---|
| `merchant_category` | `_CATLOOKUP_RE` — "what category does X belong to" | `merchant_category` |
| `merchant_date` | `_DATELOOKUP_RE` — "on what date does X appear", "when did X …"; when the sentence patterns miss ("what date did my Sky bill *go out*?"), falls back to the at/from/on entity, else any stored merchant named in the question (skipped for superlative questions, which stay largest/smallest lookups); `date_dir` last/first ("when did I **last** shop at Aldi" → the single latest date) | `merchant_dates` |
| `merchant_interval` | `_INTERVAL_RE` — "how many days between X payments", "how often do I pay X" | `payment_interval` |
| `balance_min` / `balance_max` | `_BAL_RE` + a low/high modifier (`_SMALL_RE`/`_BIG_RE`) | `balance_extreme` |

- **No-op safety.** The three merchant lookups return an intent **only when the extracted phrase
  resolves to a real merchant** (`_resolve_merchant`), so a non-merchant phrase leaves them
  dormant and the generic ladder still runs. `balance_min/max` fire only with an explicit
  min/max word (plain "balance" stays the closing-balance intent).
- **Robust matching.** `_lookup_entity` pulls the name from sentence structure; `_resolve_merchant`
  matches punctuation/suffix-tolerantly ("Shein"→`Shein.Com`, "Higgsfield Inc USA"→`Higgsfield
  Inc. USA`). The SQL helpers match via **token-wildcard** (`_merch_where`: `%tok1%tok2%`), so a
  phrase spans label variants (`Piyush Mishra` **and** `Piyush Mishra & PA`) — kept separate from
  `merchant_spend`'s exact match, which the aggregate paths rely on.
- These types are added to `_resolve_factual`'s `_KEEP_TYPE` so a present merchant doesn't
  rewrite them back to a plain `merchant` summary.

---

## 6. LLM subsystem

### 6.1 Router — `llm_route(question, history) -> dict|None`
- Ollama `/api/chat`, `format:"json"`, `temperature 0`, `num_ctx 2048`, `keep_alive 10m`.
- System = `ROUTER_SYSTEM` (intent schema + examples). Feeds the last **2 real** exchanges
  (advice placeholders filtered). Output JSON: `{type,category,merchant,n,start,end,table}`.
- The model **classifies only** — never emits a figure.

### 6.2 Grounded advice — `grounded_advice(q, thread)`
```
facts  = ts.advice_facts(USER) + _concept_facts()              # + debt/fee/gambling lines
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
- `_concept_facts()` appends an **OBLIGATIONS & HABITS** block — the loan/fee/gambling
  concept aggregates (per-merchant, whole statement, all from SQL) — so "what debt should
  I pay off first?" and "why was I charged overdraft fees?" reason over the user's REAL
  obligations. The number guard validates against the combined sheet. "Why …" questions
  route here via `_WHY_RE` (§4 g2) — they are reasoning, never a lookup; so are
  solution-seeking follow-ups ("any solutions/suggestions/ideas…", `_ADVICE_RE`).
- `_scoped_facts(ctx)` appends a **CURRENT TOPIC** block when the thread carries a
  merchant/category — that entity's own aggregates (total, share of spending,
  month-by-month) plus an instruction to answer about it specifically. This pins advice
  follow-ups ("tell me some insights in this category", "more insights") to the carried
  topic instead of whatever the account-wide sheet makes salient. Every number from SQL;
  validated by the same number guard.

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
| `/upload` | POST | parse a statement **PDF or ZIP** → SQLite (ZIP scanned for statement PDFs; non-statements ignored); **replaces** prior data; returns `{rows,parsed[],spend,income,currency}` or `{error}` (422 if no statement) |
| `/transactions` | GET | filtered/paged table. Filters: `q` (payee/descr/category `LIKE`), `start`/`end` (`YYYY-MM-DD`), `minamt`/`maxamt` (on `max(debit,credit)`), `dir`∈{in,out}, `offset`/`limit` (default 50). Returns `{rows:[{date,payee,category,out,in,balance,descr}], total, out_total, in_total}` — amounts pre-formatted in the active currency; ordered `txn_date DESC, seq DESC` |
| `/chats` | GET | JSON of `chats.json` |
| `/dashboard` | GET | JSON for the React UI |
| `/ml/anomalies\|forecast\|recurring\|categorize` | GET | JSON (`_ml`-cached) |
| `/insights` | GET | JSON: pre-computed `insights[]` + live `health` + `risk` |
| `/plaid/sandbox/status` | GET | `{linked, env, country}` — sandbox-only guard (`PLAID_ENV` must be `sandbox`) |
| `/plaid/sandbox/link` | POST | create + persist a sandbox Item (server-side, no Link widget); 409 if already linked; token in gitignored `data/plaid_token.json` |
| `/plaid/sandbox/sync` | POST | full `/transactions/sync` pull (polls while the sandbox generates) → **replaces** the ledger, then runs `/upload`'s post-ingest refresh (currency detect, insights, `_ML_CACHE.clear()` + `_reset_vocab()`); returns `{synced,rows,currency,spend,income,balance}` |
| `/hld`, `/lld`, `/roadmap` | GET | rendered HTML (this doc family) |
| `/hld.md`, `/lld.md`, `/roadmap.md` | GET | raw Markdown |
| `/` | GET | the chat UI (`PAGE`) |

**Runtime.** Serves on **port 5667** by default (`uvicorn`, host `0.0.0.0`); override with the
`PORT` env var. The batch files (`start-penny.bat` + helpers) launch the server and an
auto-reconnecting tunnel on this port; on macOS use `start-penny-mac.sh` (venv launcher that
also sets `SSL_CERT_FILE` to certifi's CA bundle — python.org builds don't trust system certs,
which breaks the Plaid client otherwise). Plaid credentials come from a gitignored `.env`
(`PLAID_CLIENT_ID`/`PLAID_SECRET`/`PLAID_ENV=sandbox`/`PLAID_COUNTRY`).

**Pinned DB.** `ts.DB_PATH` resolves to an **absolute** `data/live_txn.db` (independent of
CWD); `FINQ_DB` overrides it **only if** that path exists, else it falls back to the pinned
DB. Startup logs `[db] using …`. `init_db()` runs at boot to ensure the `insights` table
exists; `compute_insights` is run + persisted on startup for already-loaded data.

Doc rendering: `_md_to_html(md)` — stdlib Markdown→HTML (headings, GFM tables, fenced
code, lists, blockquotes, hr, inline bold/italic/code/links) wrapped in `_DOC_SHELL`
(Penny palette CSS). No CDN; fully offline.

---

## 11A. Single-page UI — parse-gate, upload, transactions table

The self-contained test UI (`PAGE` in `test_server.py`) is a three-card page (upload · chat ·
transactions) with two client-side behaviours added this revision:

**Parse-gate.** `gate()` / `reveal()` toggle the `.hidden` class on `#chatcard` and `#txncard`.
On load the page calls `/status`: `rows>0` → `reveal()` + `loadTxns()` (a statement is already in
the DB); otherwise both cards stay hidden. Chat is therefore never usable against an empty DB —
the only affordance before a parse is the uploader.

**Upload (PDF or ZIP).** `#file` accepts `.pdf`/`.zip`. On change the drop-zone enters a busy
state (`.drop.busy` pulsing glow) and the page stays **gated** while `/upload` runs, then:
- `{error}` (no statement found / bad ZIP) → the drop-zone shows the message and the page **stays
  locked**;
- success → shows `rows` (· N statements when a ZIP yielded several), `seconds`, `spend`, `income`,
  then `reveal()`s both cards and calls `loadTxns(true)`. A new upload replaces prior data
  (single-currency, §2.4).

**Transactions table.** `loadTxns(reset)` pulls `/transactions` (§11) with the filter controls —
keyword (`#tq`), direction (`#tdir` = all/out/in), date range (`#tstart`/`#tend`), amount band
(`#tmin`/`#tmax`) — and renders Date / Payee / Category / Out / In / Balance rows (amounts already
formatted in the active currency by SQL; payee cell carries the raw `descr` as a tooltip). A
summary line shows `total` matched + `out_total` / `in_total`; Prev/Next page 50 rows at a time
(`offset`/`limit`). Every figure is server-side SQL — the client only lays out strings.

---

## 12. Error handling & degraded modes

| Condition | Behaviour |
|---|---|
| Ollama down / cold | `_llm_complete` retries once; `_warmup()` thread pre-loads at boot; advisory falls back to `_advice_fallback` (deterministic) |
| LLM emits an off-fact number | `_advice_grounded` rejects → deterministic fallback |
| Router returns junk / off-topic | g5 `unknown`/non-finance → `DIDNT_CATCH` nudge (no parrot) |
| Unknown merchant | honest "No transactions found for X" (never a grand total) |
| `<50` rows (anomaly) / `<3` months (forecast) | model returns empty/None → graceful message |

**Known data-quality limitations (Barclays parser).**
- **Truncated/suffixed merchant names** (`Putney Cricket Clu`, `Virgin Media Pymts`) — the
  fine-grained lookups (§5.2) match token-wildcard so they still resolve from "Virgin Media";
  but the **exact-match** paths (`merchant_spend`, `compare`) can miss the second entity. Fix
  belongs in `parse_barclays` (widen the description column).
- **Year `0000`** — a sub-statement whose period header doesn't match `parse_barclays`'s regex
  stamps rows `0000-MM-DD` (unrecoverable from that statement's own text). `merchant_dates` and
  `payment_interval` exclude these rows so answers never show a broken date; `coverage()` can
  still show `0000`. Fix belongs in `parse_barclays` (year inference / header fallback).

---

## 13. Verification harnesses

| Script | What it checks |
|---|---|
| `scripts/test_qa_1000.py` | 1,000 SQL-verified factual Q&A → 1000/1000 |
| `scripts/golden_suite.py` | 41 questions × 10 categories → 41/41 (per-category + per-priority) |
| `scripts/test_vague_1000.py` | parrot/routing at scale (0 parrots across 664 vague) |
| `scripts/test_conversation.py` | multi-turn context + fine-grained intents (F1–F8): metric-change, overall-reset, category/date lookup, payment interval, min/max balance, scope survival across amount→average→highest. Runs on the Barclays test statement |
| `scripts/test_offline_routing.py` | **no server / no Ollama / no installs** — stubs fastapi/uvicorn/sklearn in `sys.modules`, seeds a fixture GBP ledger into a temp DB, and replays both client test sessions plus regressions through the deterministic ladder (intelligence → advice-route → concept → analytics → factual), asserting on answer text: date lookups, day-scope/zero-result leaks, concept grounding (gambling/loans/fees/flights/coffee/taxis, % of income), category aliases ("eating out"), `£` amount filters, bare-month compare, carried-year, today/yesterday/week/quarter resolution, ambiguous-merchant clarification, why-question routing, markerless-stickiness, honesty fallbacks — **58/58** |
| `scripts/test_conversations.py` (+ `_penny_testkit.py`) | **267 multi-turn checks** across the mandated categories (pronouns · context carry · merchant/category switching · comparison chains · time filters · nested filters · analytics/advice follow-ups · resets · ambiguous refs · no-context · regression · long drill-down chains). Expected values computed from `txn_store` SQL **ground-truth** (a differential, not hand-typed); the shared testkit stubs deps, seeds a rich fixture, and replays the real `query()` cascade per turn — **267/267** |

Verdict kinds: deterministic (amount/percent/count vs SQL truth) · advice (route=advice +
fully grounded + on-topic) · probe (capability + on-topic, accepts route ML/SQL/advice).

---

*LLD reflects the implementation at this revision. Update alongside the code; the routing
cascade (§4) and the number-validation contract (§6.3) are the two parts most worth
keeping in sync.*
