# Penny — Roadmap & Implementation Status

**Transitioning from a Query Engine to a Financial Intelligence Engine.**

Status of every roadmap priority: what is **built and live**, what is **deferred**, and what is
**not yet started** — plus the extra work done beyond the original roadmap.

> Core design paradigm (preserved throughout): **every raw financial figure originates from the
> deterministic SQL layer (`txn_store`), never from the LLM.** New intelligence answers are rendered
> deterministically; the LLM is not in their path, so they cannot hallucinate a number.

---

## Legend
- ✅ **Done** — built, wired into chat, verified
- 🟡 **Partial** — some of it exists; rest pending
- ⛔ **Deferred** — intentionally not done now (with reason)
- ⬜ **Not started**

---

## Scorecard

| # | Priority | Status | Where it lives |
|---|----------|:------:|----------------|
| 1 | Insight Engine (pre-compute pipeline) | ✅ | `compute_insights()`, `/insights`, "what patterns" digest |
| 2 | Financial Health Engine | ✅ | `health_score()` → `health_answer()` |
| 3 | Risk Engine | ✅ | `risk_assessment()` → `risk_answer()` |
| 4 | Behavioural Analytics | ✅ | `behavior_metrics()` → `behavior_answer()` |
| 5 | Recurring detection → chat | ✅ | `ml.recurring()` → `recurring_answer()` (+ fallback) |
| 6 | Correlation Engine | ⛔ | deferred — genuinely new modelling |
| 7 | Transaction Impact Scoring | ✅ | `transaction_impact()` → `impact_answer()` |
| 8 | Category Trend Engine (3/6/12-mo) | ✅ | `category_trend()` → `cattrend_answer()` |
| 9 | Hybrid (embedding) Intent Routing | ⛔ | deferred — current router scores 41/41 + 1000/1000 |
| 10 | Insights Table | ✅ | `insights` table + `save/get/compute_insights` |

**Phase 1 (Insight + Health + Risk + Recurring): ✅ complete.**
**Phase 2 (Behavioural + Impact + Category Trend): ✅ complete** (Correlation deferred).
**Phase 3 (What-if / Budget / Goal): 🟡 What-if partial; Budget & Goal not started.**

---

## ✅ Done — in detail

### 1. Insight Engine  *(highest ROI)*
Proactive, pre-computed pipeline instead of pure reactive query.

- `compute_insights(user)` runs the engines once and emits insight rows
  `{type, title, explanation, score, evidence}`.
- Runs **on upload** (in `/upload`) **and on server startup** for already-loaded data.
- Persisted to the `insights` table; surfaced by:
  - `GET /insights` (JSON: insights + health + risk)
  - chat: *"what patterns do you see?"* → `insights_answer()` digest (reads stored, falls back to live compute).
- **Flow now:** `Upload → Insight Engine → insights table → Question → Answer`.

### 2. Financial Health Engine
`health_score()` — composite **0–100** from four 0–25 pillars:

| Pillar | Formula (as implemented) |
|--------|--------------------------|
| Savings | `savings_rate / 30 × 25` (capped) |
| Spending discipline | `25 × (1 − overspent_months / months)` |
| Income stability | `25 × (1 − min(CV/0.5, 1))`, CV = std/mean of monthly income |
| Diversification | `25 − penalty(income_dependence>50%) − penalty(merchant_conc>50%)` |

Rating bands: **≥85 Excellent · ≥70 Good · ≥55 Fair · ≥40 Needs work · else Poor.**
Live on current data: **76/100 Good**.
Chat: *"how financially healthy am I?", "rate my finances", "financial report card"*.

### 3. Risk Engine
`risk_assessment()` — structural risk (distinct from one-off anomaly detection).
`risk_score` = sum of triggered-flag severities (capped 100):

| Flag | Severity |
|------|:--------:|
| Negative savings (rate < 0) | +35 |
| Low savings rate (rate < 10%) | +22 |
| Overspending months | +15 / +22 |
| Rising discretionary spend (>30% half-over-half) | +15 |
| Single income source (≥80%) / concentration (≥60%) | +20 / +12 |
| Spending concentration (top-5 ≥60%) | +10 |
| Thin cash buffer (< 1 month) | +10 |

Bands: **≥66 High · ≥35 Medium · ≥15 Low · else Minimal.**
Live: **30/100 Low** (single income 87% +20; spend concentration 77% +10).
Chat: *"what risks do you see?", "am I overspending?", "what should I worry about?"*.

### 4. Behavioural Analytics
`behavior_metrics()` — *how* you spend, not *how much*:
- **Weekend ratio** — per-day weekend vs weekday spend (`strftime('%w')`).
- **End-of-month ratio** — day ≥21 vs day ≤10.
- **Impulse score** — share of debits under ₹500.
- **Merchant dependency** — top merchant / total spend.

Chat: *"what spending habits do I have?", "do I overspend on weekends?", "am I an impulsive spender?"*.

### 5. Recurring detection → chat
`ml.recurring()` (DBSCAN — no preset list) wired via `recurring_answer()`. Renders cadence /
amount / confidence; **gracefully falls back** to the known-subscription view when no stable cadence
is found, and **defers** "which increased?" to the subscription-trend handler.
Chat: *"what subscriptions do I have?", "what recurring bills exist?"*.

### 7. Transaction Impact Scoring
`transaction_impact()` — signed impact per transaction:
- Biggest debits and biggest credits pulled **separately** (so large expenses aren't crowded out by salary).
- Normalised **per direction** against that direction's largest, +8 bump for committed/income, **deduped by merchant**.
- Live: **Salary +100 / Zerodha −100**.
Chat: *"which 5 transactions had the biggest impact?"*.

### 8. Category Trend Engine
`category_trend(window)` — recent *k*-month average vs prior *k*-month average per category, % change,
fastest-growing first. **Windows: 3 / 6 / 12 months** (the old `category_movers()` was 2-month only).
Chat: *"which categories are growing fastest?", "what expenses are getting out of control?"*.

### 10. Insights Table
```sql
CREATE TABLE insights (
    id INTEGER PRIMARY KEY, user_id TEXT, doc_name TEXT,
    type TEXT,           -- health | risk | pattern | behavior | impact
    title TEXT, explanation TEXT, score REAL,
    evidence TEXT,       -- JSON blob of supporting numbers
    created TEXT DEFAULT CURRENT_TIMESTAMP
);
```
Storage layer: `save_insights()`, `get_insights()`, `compute_insights()`.

### Routing (how the engines plug in)
A new `intelligence_answer()` gate runs **after** the ML gate and **before** the advice gate:

```
guards → followup → ML(anomaly/forecast/projection)
       → INTELLIGENCE(health/risk/recurring/impact/cat-trend/behaviour/patterns)   ← NEW
       → advice(LLM, grounded) → analytics(SQL) → factual(SQL) → LLM-router → regex
```

Regexes: `_HEALTH_RE`, `_RISK_RE`, `_RECUR_RE`, `_BEHAVE_RE`, `_IMPACT_RE`, `_CATTREND_RE`, `_PATTERN_RE`
(with guards, e.g. "which months were risky" defers to the per-month analytics handler).

---

## ⛔ Deferred (intentional)

### 6. Correlation Engine
Causal/sequence analytics ("what happens 7 days after a salary credit?"). **Not built** — this is
genuinely new modelling (event-sequence windows), the only roadmap item that isn't synthesis over
existing SQL. Scheduled last.

### 9. Hybrid (embedding) Intent Routing
Replace `Regex → LLM router` with `Intent Catalog → Embedding Similarity → Fallback LLM`.
**Deferred** — the current router scores **41/41 golden** and **1000/1000 factual** with **0 mis-routes**;
replacing a working router is risk without payoff yet. Revisit once enough engines strain the regex layer.

---

## 🟡 / ⬜ Phase 3 (future)

| Item | Status | Note |
|------|:------:|------|
| What-if Simulator | 🟡 Partial | Deterministic "cut *X* by *Y*%" already in `analytics_answer` ("if I cut Shopping by 20%, how much would I save?"). A full multi-lever simulator is not built. |
| Budget Optimizer | ⬜ | Not started. |
| Goal Planner | ⬜ | Not started. |

---

## ➕ Extra work done (beyond the roadmap)

| Item | Status | Detail |
|------|:------:|--------|
| **Penny rebrand** | ✅ | App title, header, doc-shell nav now read "Penny" (HLD/LLD doc bodies still say FinQuery). |
| **Pinned DB path** | ✅ | Always loads `data/live_txn.db` via an absolute path; bogus `FINQ_DB` cleanly falls back; startup logs `[db] using …`. |
| **Permanent link + batch files** | ✅ | Fixed URL `https://penny-finance.loca.lt` via localtunnel; `start-penny.bat`, `stop-penny.bat`, `_penny_server.bat`, `_penny_tunnel.bat` (auto-restart loops). |
| **"Penny is thinking" indicator** | ✅ | Animated typing dots shown the instant you hit Enter, removed when the answer starts streaming. |
| **Discovery chips + help** | ✅ | Suggestion chips and capabilities text updated with health / risk / patterns / habits / subscriptions / category-growth. |

---

## Verification

| Test | Result |
|------|--------|
| Golden Test Suite (10 categories) | **41/41** (Must 22/22 · Important 11/11 · Advanced 8/8) |
| Focused regression (exact SQL-truth match + engines) | **20/20** |
| At-scale factual sweep (merchants/categories/periods/months) | **43/45**, **0 mis-routes** (2 misses = pre-existing bare-token merchant-synonym gap, unrelated) |

---

## What's left (summary)
1. **Correlation Engine (#6)** — event-sequence analytics (new modelling).
2. **Hybrid intent routing (#9)** — only once the regex layer strains.
3. **Phase 3** — full What-if simulator, Budget Optimizer, Goal Planner.
4. **Docs** — HLD & LLD still describe the pre-roadmap architecture and say "FinQuery"; they need the
   intelligence layer + insights table + new routing added, and the FinQuery→Penny rename.

*This document reflects the state of the codebase as built; the engines and figures above were
verified live against the loaded statement.*
