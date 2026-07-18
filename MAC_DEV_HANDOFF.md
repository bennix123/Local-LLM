# Penny — Mac Dev Handoff

**One line:** The web/backend team built the *whole working product* in Python + React + Electron.
That runs everywhere (incl. Windows) but **crashes in / can't pass the Mac App Store sandbox**.
The Mac dev's job is to port that proven logic into the **native Swift + MLX app** (`PennyMac/`)
so Penny actually ships on TestFlight / the App Store.

- Reference / source-of-truth logic: `finquery/` (Python FastAPI + React, uses MLX, works locally)
- The thing we ship: `PennyMac/` (SwiftUI + `mlx-swift`, sandbox-safe)
- Dead end (do NOT revive): Electron root (`server.js`, `electron/`, `src/`) — `node-llama-cpp` JIT is forbidden in the sandbox.

---

## 📋 Progress log (newest first)

> Live status so the web/backend team can see what the Mac side has landed and what's next.

### 2026-07-18 — P5 prepped: TestFlight/App Store signing pipeline 🚀
Everything the signing pipeline needs is verified in place (Team `P4ANR778GY`, bundle
`com.localbankrag.app`, Apple Distribution + 3rd Party Mac Developer Installer certs in the
keychain, profile "Penny Mac App Store" valid to **2027-07-14**, sandbox on, no hardened runtime).
- **`project.yml`:** signing is now **per-config** — Debug = Automatic dev; **Release = Manual**
  Apple Distribution + "Penny Mac App Store" profile + `Penny-dist.entitlements`. Uses the
  keychain cert/profile, so **no Apple-ID login needed to archive**.
- **New:** `PennyMac/ExportOptions.plist` (App Store `.pkg` export) + `PennyMac/TESTFLIGHT.md`
  (full checklist, GUI + CLI paths, gotchas).
- **Validated the hard part:** installed the profile into Xcode's search path and the **Release
  config now compiles and code-signs** with the manual Apple Distribution identity — the step that
  usually breaks. Archive → upload follows from there.
- **User-run only:** the actual **Archive → Distribute → upload to TestFlight** needs your machine
  + Apple ID / app-specific password; it can't run headless here. Steps are in `TESTFLIGHT.md`.

### 2026-07-18 — P4 DONE: RAM-aware model picker ✅
The picker showed static `≥N GB RAM` tags but never checked *this Mac's* RAM — a user on 8 GB
could pick the 8 B model and OOM (the exact crash class the native rewrite exists to avoid).
- `AppModel.deviceRAMGB` (from `ProcessInfo.physicalMemory`) + `modelFits(_)`. Models that need
  more RAM than the device has now show a red **"⚠️ Needs ≥16 GB — this Mac has N GB"** warning.
- **Downloaded-state indicator:** `refreshDownloadedModels()` (via `DownloadMeter`, off-main on
  `.onAppear`) flags models already on disk as **"downloaded ✓"** vs "downloads once on first use".
- Existing disk-based download progress (smooth %, byte counts, elapsed clock) was already solid.
- App build **SUCCEEDED**.

P4 remaining niceties (optional): a "delete downloaded model" action to reclaim disk, and
auto-defaulting the selection to the largest model that fits the device.

### 2026-07-18 — P3 (part 2) DONE: table extraction verified, conformance 15 → 22 ✅
Rather than build a speculative `camelot`-style lattice extractor with no failing case, I
**diagnosed first**: dumped every parsed row for the 7 previously-unverified statements
(NatWest, Revolut, Santander, Coutts, BNP Paribas, Credit Suisse, Standard Chartered) and ran a
**field-level Swift-vs-Python parity diff** (Python `ingest_pdf`, LLM stubbed = the reference).
- **Result: all 7 are byte-identical to the Python reference** — date, description, debit,
  credit, balance, category all match. The Swift coordinate-clustering already handles these
  table layouts at full parity; **no lattice extractor is needed** for any available sample.
- **Locked it in:** promoted the 7 into the contract fixtures with reference-generated
  `_expected.json`. `penny-conformance run` now covers **22 banks (22/22)**, up from 15 — a
  permanent regression guard for table parsing.
- Added `dump-rows` / `rows-json` debug subcommands to `penny-conformance` for future parity work.

**P3 status:** the two real risks are handled — unreadable **Type0 fonts** (part 1, fixed) and
**table-structure correctness** (part 2, verified at parity + guarded by 22 fixtures). Dedicated
Indian-bank parsers (SBI/ICICI/Axis) remain unverifiable until we have sample PDFs; their profiles
exist and the generic cascade + Type0 support should cover them — add fixtures when samples arrive.

### 2026-07-18 — P3 (part 1) DONE: Type0/CID font support ✅
Swept all 22 `test-data/` statements through the Swift parser: one hard failure —
**Wrenfield extracted 0 rows**. Root cause: the PDF uses **Type0/CID fonts** (`Identity-H`,
subsetted Poppins/Liberation TrueType), which the MuPDF-parity extractor explicitly didn't
handle (`PDFFont` assumed single-byte fonts) — so text came out as shifted gibberish and no
parser could read it. pymupdf decodes it fine via the font's ToUnicode CMap; the Swift port
just wasn't applying it for composite fonts.
- **Fix (`PDFFont.swift` + `PDFTextExtractor.swift`):** detect `Subtype == Type0` → read the
  content stream in **2-byte Identity codes**, pull per-CID widths from the descendant font's
  `W`/`DW`, and let the existing ToUnicode parser map each 2-byte code to text. Strictly gated
  on Type0 so simple single-byte fonts (all 15 fixtures) take the unchanged path.
- **Result:** Wrenfield **0 → 1,000 rows**, text byte-identical to pymupdf; balance/router/RAG
  all correct. **No regression** — conformance **15/15**, and all 21 other statements parse
  identically. App build **SUCCEEDED**.
- **Why it matters:** Type0 subsetted fonts are extremely common in modern statements, so this
  unlocks far more than one bank — any Identity-H statement now extracts.

**P3 remaining:** dedicated parsers/verification for Indian banks with *visual table* layouts
(SBI/ICICI/Axis — profiles exist, correctness unverified without expected fixtures) and the
`camelot`-style table extraction for grid-ruled statements. The Type0 fix removes the biggest
*silent* failure mode (unreadable text); table-structure parsing is the remaining risk.

### 2026-07-18 — P2 DONE: on-device hybrid RAG ✅
Open-ended chat questions now ground on the *relevant* transactions instead of the whole
statement (which blows the context window on big statements). New
`PennyTxnStore/Retriever.swift` (`TxnRetriever`), **zero external ML deps**:
- **Dense** — Apple `NLEmbedding` (NaturalLanguage framework): on-device sentence vectors,
  sandbox-safe, no PyTorch, no bundled model, no ChromaDB. Replaces sentence-transformers.
- **Sparse** — BM25 (Okapi, pure Swift). **Fusion** — reciprocal rank fusion (k₀=60).
- Degrades to BM25-only if the embedding model is unavailable.
- **Wiring:** `AppModel.send()` — after `FinanceRouter` returns nil, retrieve top-14 rows and
  pass just those to the model (`retrievalContext`), not `scopedText()`. Index is cached per
  selected-doc set (rebuilt only when the selection changes; built off the main thread).
- **Verified** via `penny-conformance retrieve <pdf> "<q>"` on the 1000-row HDFC statement:
  "eating out / food delivery" → Zomato/Swiggy rows; "salary deposits" → Infosys credits;
  "cash withdrawals" → SBI ATM rows. Conformance **15/15**; app build **SUCCEEDED**.

**Note vs the Python reference:** this covers dense+BM25+RRF retrieval over transactions.
Page-level citations and chunk-level retrieval over *non-transaction* statement text (the
`finquery` rag/ layer) are not ported yet — the deterministic router + txn-RAG cover the
common cases; revisit if users ask questions about statement prose (addresses, T&Cs).

### 2026-07-18 — QA bug-list triage + fix
A QA feedback doc (9 items) was reviewed. **Most of it targets the web/Electron app**, not the
native Swift app — those UI strings/features (`regenerate`, `logout`, `ML ENGINE`/`SQL ENGINE`
badges, the 101,071-row dataset, the `RAM in use`/`Context 32K` brain panel) **do not exist in
`PennyMac/`** (grep = 0 hits). Mapping:

| # | QA item | Where | Status |
|---|---------|-------|--------|
| 1 | Today panel blank | both | Mac: fixed by P0 (fills once a statement imports) — verify in GUI |
| 3 | Regenerate doesn't re-run LLM | **web only** | likely covered by teammate commit `3b26865` ("forced LLM regeneration") |
| 4 | Logout not working | **web only** | ✅ **FIXED (web)** — see below |
| 5 | LLM gives wrong answers | both | Mac: addressed by P1 (facts are deterministic now) |
| 6 | "PENNY'S BRAIN" data wrong (RAM/Context) | **web/old build** | Swift panel shows only real Statements/Transactions; no fake RAM/Context |
| 7 | **Ghosts/Patterns always show "3"** | **both** | ✅ **FIXED (Swift)** — Ghosts shows real recurring-subscription count; fake Patterns badge removed |
| 7b | Forecast returns absurd £4.7M | **web** (`ML ENGINE`) | **NOT a code bug** — `ml_insights.forecast()` already clamps negatives; the huge numbers come from the synthetic 1-lakh dataset. Needs realistic seed data. |
| 8 | Can't see bank statements | web/unclear | needs repro on current build |
| 9 | Only 100 of 101,071 rows shown | **web** (`SQL ENGINE`) | ✅ **FIXED (web)** — see below |

**Fixes applied this pass:**
- **#7 (Swift):** `FinanceRouter.recurringCharges()` made public; `AppModel.ghostCount` feeds the
  sidebar Ghosts badge (real count, 0 for a single-month statement); Patterns badge dropped.
  Build **SUCCEEDED**, conformance **15/15**.
- **#4 (web):** `finquery/frontend/.../Dashboard.jsx` — logout cleared the token but never left the
  page (the `/app` route isn't wrapped in the existing `ProtectedRoute`). Now `handleLogout` calls
  `navigate('/login')`. *(Defense-in-depth: web dev should also wrap `/app` in `ProtectedRoute` in
  `App.jsx` — left out here to avoid locking out sessions whose `user` isn't populated.)*
- **#9 (web):** `finquery/backend/.../dispatcher.py` — the "list" cap defaulted to 100; raised to
  200 and the truncation note is now actionable ("filter by merchant, category, or period").

> ⚠️ The web fixes (#4, #9) are in the **web/backend team's** codebase and were **not runtime-tested**
> (I can't run the React/Python app here) — please verify. They also touch files the teammate's
> in-flight commit `3b26865` edited, so watch for conflicts before merging.

**Files changed this session (branch `feat/mlx-only`):**
| File | What |
|---|---|
| `PennyMac/PennyApp/DeterministicIngest.swift` *(new)* | Runs `PennyTxnStore` on the picked PDF; maps `TxnRow → Transaction` |
| `PennyMac/PennyCore/Sources/PennyTxnStore/FinanceQuery.swift` *(new)* | `FinanceRouter` — deterministic NL→answer over `[TxnRow]` (port of `router.py`/`analytics.py`) |
| `PennyMac/Resources/` *(new)* | Bundled `categories.json` + `bank_profiles/` for the sandboxed app |
| `PennyMac/PennyApp/AppModel.swift` | Import parses deterministically; `send()` calls `FinanceRouter` before the LLM |
| `PennyMac/PennyCore/Sources/PennyCore/PennyLLM.swift` | `Transaction` gained optional `category` |
| `PennyMac/PennyCore/Sources/PennyTxnStore/Txn.swift` | `TxnRow` made `Equatable`+`Sendable` |
| `PennyMac/PennyCore/Sources/penny-conformance/main.swift` | New `query <pdf> "<q>"` test subcommand |
| `PennyMac/project.yml` | Links `PennyTxnStore`, copies the bundled resources |

**Net effect:** the Today panel and all factual money questions are now computed deterministically
(no LLM → no hallucinated numbers). The LLM is only used for open-ended/advisory chat. Behaviour
mirrors the Python `finquery/` reference, which stays the source of truth for the contract.

### 2026-07-18 — P1 (part 2) DONE: financial-reasoning handlers ✅
Extended `FinanceRouter` with the deterministic *reasoning* handlers from `analytics.py`
(all computed from `[TxnRow]`, no model):
- **Period-vs-period compare** — "last 3 months vs the previous 3": spending / income / net with % change.
- **Savings rate** · **savings target** (20% guideline) · **survival runway** (balance ÷ avg monthly spend).
- **Risky months** (spending > income) · **spending consistency** (coefficient of variation).
- **Income trend** (earlier vs later half) · **what-if** ("cut Shopping by 20% → saves £X/mo").
- **Recurring / subscriptions** — deterministic detector (same merchant, ≥3 months, amount CV ≤ 25%).
- **Fix:** financial-reasoning handlers are account-wide (period-only scope), so a stray word like
  "income" in "without income" no longer wrongly narrows to a category.
- **Verified** on `indian_bank_statement.pdf` (1000 rows, multi-month): period-compare net −60.0%,
  risky months Feb/Mar 2025, consistency ±22%, income trend −12.4%, savings rate 35.3% — all
  cross-checked by hand. Conformance still **15/15**.

**Still on the model (lower-priority tail of P1):** income sources/timing, spending
personality/profile, "habits to change", and multi-turn follow-up context ("the biggest one?"
carrying the previous scope). These are narration-heavy or stateful; fine to leave on MLX for now.

### 2026-07-18 — P1 (part 1) DONE: deterministic finance query router ✅
Chat now answers **factual money questions from the parsed data, not the model** —
so numbers can't be hallucinated. New `PennyTxnStore/FinanceQuery.swift` (`FinanceRouter`)
is a Swift port of the highest-frequency intents from `router.py`/`analytics.py`:
- **Intents:** balance · count · largest expense · top-N expenses · total spent ·
  income · net/savings · **category spend** · **merchant spend** · by-category
  breakdown · average — each with optional **category / merchant / month** scoping.
- **Boundary:** advisory/opinion/open-ended questions ("roast my spending", "should I…",
  "why did I…") return nil → fall back to the MLX model. So the router only ever answers
  what it can compute exactly.
- **Wiring:** `AppModel.send()` calls the router before the LLM; deterministic answers get
  an `ANALYTICS` badge. Rows are stored on `LoadedDoc` (`DeterministicIngest` now returns
  `[TxnRow]`); `TxnRow` is `Equatable`+`Sendable`.
- **Verified on real fixtures** via `penny-conformance query <pdf> "<question>"`:
  e.g. *"how much on groceries?"* → `£278.20 across 5 txns`; *"biggest expense?"* →
  `£750.00 STANDING ORDER - RENT`; *"net?"* → `£1550.19 (£3498.74 in − £1948.55 out)`.
  Conformance still **15/15**; full app build **SUCCEEDED**.

**Still deferring to the model (next in P1):** period-vs-period comparisons, savings-rate /
runway / risky-months, recurring-subscription detection, what-if ("cut Shopping by 20%"),
and the ML/insights handlers — these are the rest of the ~25 handlers in `analytics.py`.
The Today panel is now fully deterministic (P0) and the common chat questions are too.

**For the web/backend team:** the Swift router mirrors your `router.py` intent regexes.
If you add/rename an intent or change category names in `categories.json`, note it in this
doc so the Swift side stays in lockstep — both consume `finquery/contract/` as the contract.

### 2026-07-18 — P0 DONE (deterministic parser wired into the app) ✅
The app now produces every transaction/figure from the **deterministic `PennyTxnStore`
parser** (15/15 contract) instead of the LLM. Changes on `feat/mlx-only`:
- `PennyApp/DeterministicIngest.swift` (new) — runs `TxnIngester.ingestPDF` on the picked
  PDF, maps `TxnRow → PennyCore.Transaction`, carries the real category from `categories.json`.
- `PennyApp/AppModel.swift` — import flow now parses deterministically (no
  `llm.extractTransactions`); the LLM `analyze()` path was removed. `categorize()` now uses
  the parser's real categories; currency prefers the parser's detected value.
- `PennyCore/PennyLLM.swift` — `Transaction` gained an optional `category`.
- `Resources/categories.json` + `Resources/bank_profiles/` bundled into the app;
  `project.yml` links `PennyTxnStore` and copies those resources.
- Verified: `penny-conformance` still **15/15**; `xcodegen generate` clean; parser core builds.
- **Nothing needed from the web team for P0.**

**What this unblocks for the web/backend team:** the Swift app and the Python reference now
share the *same* deterministic contract (`finquery/contract/`). Keep expected fixtures and
`categories.json` as the single source of truth — any parser/category change should land there
first so both sides stay in lockstep.

---

## 1. What the web/backend team ("window dev") already delivered — the brain

This is the reference you port *from*. It is complete and working.

| Component | Reference file | LOC | What it does |
|---|---|---|---|
| **Query router** | `finquery/scripts/test_server/router.py` | 1704 | regex + LLM router, **25 SQL handlers** — decides which deterministic answer to run |
| **Analytics** | `finquery/scripts/test_server/analytics.py` | 1088 | deterministic totals, category/merchant/time breakdowns, balances, counts |
| **Statement parsers** | `finquery/backend/src/services/txn_store/parsers.py` | 2215 | PDF/CSV → transactions (Barclays, PNB, SBI, generic cascade) |
| **SQL queries** | `finquery/backend/src/services/txn_store/queries.py` | 873 | the query layer over the txn DB |
| **NL→SQL engine** | `finquery/backend/src/services/nl_sql_engine.py` | 757 | natural-language question → SQL |
| **Hybrid RAG** | `finquery/backend/src/services/` (rag/embed/retrieval) | — | dense vectors + BM25 + reciprocal-rank-fusion, page-level citations, Anthropic's 6 RAG strategies |
| **MLX LLM provider** | `finquery/backend/src/services/llm_provider.py` | — | MLX inference + `MODEL_CATALOG` |
| **UI** | `finquery/frontend/src/` (Landing, Dashboard, ModelPicker, Login, ChatArea, ContextPanel) | 2216 | the React app to mirror in SwiftUI |

---

## 2. What the Mac dev has ALREADY ported ✅

| Done | Swift location | Status |
|---|---|---|
| **Parser layer** | `PennyMac/PennyCore/Sources/PennyTxnStore/` | ✅ MuPDF-parity PDF extraction, bank parsers, categorization — **passes contract 15/15** |
| **On-device MLX engine** | `PennyMac/PennyCore/Sources/PennyCore/PennyLLM.swift` | ✅ loads MLX models, streams answers (`mlx-swift-lm`) |
| **PDF text extraction** | `.../PennyCore/StatementText.swift` | ✅ PDFKit |
| **Full SwiftUI UI** | `PennyMac/PennyApp/` (~1,750 LOC) | ✅ onboarding → model picker → dashboard (sidebar · chat · Today panel) |
| **Build pipeline** | `PennyMac/README.md` | ✅ XcodeGen + xcodebuild + Metal toolchain gotchas documented |

---

## 3. What the Mac dev STILL has to do 🔧 (the actual work list)

Ordered by leverage. "Port from" = the Python file that already implements it.

### ~~P0 — Wire the deterministic parser into the app~~  ✅ DONE (2026-07-18)
Was: the app extracted transactions with the **LLM** (`llm.extractTransactions`) —
slow and unreliable — while the 15/15 `PennyTxnStore` parser sat unconnected.
Now: import routes through `PennyTxnStore` via `PennyApp/DeterministicIngest.swift`;
every number is exact and model-free; real categories from `categories.json` feed the
Today panel. Full app build **SUCCEEDED**, conformance still **15/15**. See the Progress log above.

### P1 — Port the deterministic analytics + router  *(effort: L — ✅ mostly DONE)*
"The brain." Goal: **all numbers come from computed logic, no model.** Both parts live in
`PennyTxnStore/FinanceQuery.swift` (`FinanceRouter`), wired into `AppModel.send()`, tested via
`penny-conformance query`.
- ✅ **Part 1:** core numeric intents — balance, count, largest/top, total spent, income,
  net, category/merchant spend, by-category, average (category/merchant/month scope).
- ✅ **Part 2:** financial-reasoning — period compare, savings rate/target, runway, risky
  months, consistency, income trend, what-if, recurring/subscriptions.
- ⏳ **Tail (optional, still on MLX):** income sources/timing, spending personality/profile,
  "habits to change", multi-turn follow-up context. Narration-heavy or stateful — low priority.

### P2 — Port the hybrid RAG pipeline  *(effort: L)*
Today the whole doc is stuffed into context (fine for the slice, not for scale).
- On-device **embeddings** → Core ML or MLX model (NO PyTorch, NO sentence-transformers).
- On-device **vector store** → SQLite (vectors + cosine) or a Swift index (NO ChromaDB).
- **Hybrid search** → dense + BM25 + reciprocal rank fusion, page-level citations.
- Port from `finquery/backend/src/services/` rag/embed/retrieval.

### P3 — Broaden bank-parser coverage  *(effort: M — biggest technical risk)*
`parsers.py` handles more banks than the Swift port (e.g. SBI). **Table extraction is the
#1 risk**: Python uses `camelot`; there is **no clean Swift equivalent** — table-aware
ingestion must be reimplemented on the coordinate clustering already in `PDFTextExtractor.swift`.

### P4 — Model management UX  *(effort: M)*
Model picker exists; polish first-run download progress, cache location inside the sandbox
container, low-memory fallback (3B) vs 8B on 16 GB Macs.

### P5 — Signing + TestFlight  *(effort: M)*
Dev build is ad-hoc signed, sandbox ON. Switch to Apple Distribution +
`build/embedded.provisionprofile`. Reuse: Team `P4ANR778GY`, bundle `com.localbankrag.app`,
App Store app "Penny AI - Confidant" (App ID 6790839403).

---

## 4. Definition of "works smoothly"

- [ ] Every reported **number is deterministic** (SQL, never the model) → P0 + P1
- [ ] Q&A over large statements stays fast and grounded with **citations** → P2
- [ ] Common Indian + UK banks ingest cleanly, incl. **table-heavy PDFs** → P3
- [ ] Model downloads once, runs on-device, no network at query time → P4
- [ ] Builds signed, **passes App Store sandbox**, uploads to TestFlight → P5

---

## 5. Gotchas already learned (don't rediscover these)

1. **Build via Xcode/xcodebuild, never plain `swift run`** — SwiftPM can't compile mlx-swift's
   Metal shaders ("Failed to load the default metallib"). See `PennyMac/README.md`.
2. **Metal toolchain** is a one-time install: `xcodebuild -downloadComponent MetalToolchain`.
3. **mlx-swift-lm uses Swift macros** → headless builds need `-skipMacroValidation`
   (GUI: click "Trust & Enable" once).
4. **Conformance suite:** expected JSONs were generated with the LLM *disabled*. Run
   `penny-conformance` (Swift) for parity — the parser needs no model. If you run the Python
   `conformance.py` on a Mac where MLX works, the LLM "Other"-category mop-up fires and 7/15 "fail"
   on category-only diffs. Not a real regression.
5. **Missing docs referenced elsewhere:** `SWIFT_APPSTORE_PATH.md` and `TESTFLIGHT.md` are cited by
   the kickoff/README but are **not in this branch** — the phased plan lives in `SWIFT_KICKOFF_PROMPT.md`.

---

## 6. Where the newest reference logic lives (branches)

- `origin/manas` — newest hybrid RAG + 25 SQL handlers + SBI parser (best reference for P1/P2).
- `origin/feat/penny-canonical-pipeline` — composable filters + follow-up determinism.
- `origin/feat/mlx-only` (current) — the Swift/MLX app + entity-lookup / category-spend routing.

Port logic *from* `manas`/`canonical-pipeline`; ship it *in* `feat/mlx-only`.
