# Penny AI — Migration Roadmap

**Status:** Implementation contract · v1 · pre-implementation
**Scope:** Migrate Penny from ad-hoc chat handlers to the approved layered Financial Intelligence architecture.
**Companion:** the [Architecture Blueprint](https://claude.ai/code/artifact/d6a80951-f0eb-4df3-a066-757abc9700e3) is the design; this folder is the build contract.

> These documents are the implementation contract. Once reviewed and approved, each phase is
> implemented in **separate PRs**, one task (or a small, related group) per PR, with the existing
> parser conformance suite green at every step. No production code is written until this contract is
> approved.

---

## 1. Approved architecture decisions (locked)

These are settled and every task below assumes them:

| # | Decision | Consequence |
|---|----------|-------------|
| D1 | **Money is `Decimal`** everywhere — never `Double`. | New `Money` value type; persistence migration; parser emits `Decimal`. |
| D2 | **Single signed `amount`** — no separate `debit`/`credit` fields. | `Transaction.amount: Money` (negative = money out); `direction` derived. |
| D3 | **Enrichment runs eagerly at ingest and is persisted.** | Pipeline runs once per import; enriched model saved; versioned for re-runs. |
| D4 | **Wrap `FinanceRouter` behind the Query Engine first, then delete** after parity. | Phase 1 wraps; Phase 3 removes. No hard cut. |

---

## 2. Target module topology

New Swift library targets live in the existing `PennyMac/PennyCore/Package.swift` (one package, several
targets — minimal Xcode churn). Dependency edges point **down only**.

```
PennyModel     (L1 · pure value types · Decimal money · zero deps)
   ▲
   ├── PennyTxnStore   (L0 · existing parser · refactored to EMIT PennyModel)
   ├── PennyFinance    (L2–L4 · enrichment, query, knowledge · no SwiftUI, no MLX)
   │       ▲
   │       └── PennyIntel   (L5 · intent→query · depends on PennyFinance + PennyCore/LLM)
   └── PennyApp        (L6 · SwiftUI · depends on all products)

PennyCore (existing · MLX/PennyLLM) stays an isolated leaf used only by PennyIntel + download UI.
```

New products to add to `Package.swift`: `PennyModel`, `PennyFinance`, `PennyIntel`.

---

## 3. Phases & dependencies

```
Phase 0  Canonical Model ─────────────┐  (foundation — everything depends on it)
                                       ▼
Phase 1  Query Engine ─────────────────┬───────────────┐
                                       ▼               ▼
Phase 2  Enrichment Pipeline ──────────┤          Phase 5  Sources
                                       ▼          (needs only Phase 0; schedule anytime after)
Phase 3  Intent → Query ───────────────┤
                                       ▼
Phase 4  Knowledge & Insights ─────────┘  (needs Phases 1–2)
```

| Phase | Depends on | Can start when |
|-------|-----------|----------------|
| 0 · Canonical Model | — | now |
| 1 · Query Engine | 0 | Phase 0 merged |
| 2 · Enrichment | 0 (query engine helpful, not required) | Phase 0 merged |
| 3 · Intent → Query | 1, 2 | Phases 1–2 merged |
| 4 · Knowledge & Insights | 1, 2 | Phases 1–2 merged |
| 5 · Sources | 0 | Phase 0 merged (parallelizable) |

---

## 4. Indicative timeline

Sizing is relative (S ≈ ½–1 day, M ≈ 1–3 days, L ≈ 3–5 days) — not committed dates. Maps to the
blueprint's Q1–Q4 roadmap.

| Quarter | Phases | Outcome |
|---------|--------|---------|
| **Q1** | 0, 1 | Canonical model is the source of truth; every current question re-served by composed queries. |
| **Q2** | 2, 3 | Full detector suite; LLM intent→query with confidence + citations; regex routing retired. |
| **Q3** | 5, 4 (start) | CSV/OCR/more banks; KPI/knowledge cache + dashboard. |
| **Q4** | 4 (finish) | Insights (budgeting, forecasting) as labelled estimates; new domains (investments, loans). |

---

## 5. Global invariants (apply to EVERY task's Definition of Done)

Every PR must satisfy all of these before merge:

- **INV-1 · Parser conformance green.** The 15/15 exact-match conformance suite (`penny-conformance`)
  passes unchanged. This is the immovable anchor.
- **INV-2 · App stays functional.** The macOS app builds, launches, imports a statement, and answers a
  question end-to-end after the PR.
- **INV-3 · All existing tests green.** `swift test` (PennyCore package) and the `PennyTests` /
  `PennyCoreTests` Xcode suites pass.
- **INV-4 · Single phase per PR.** A PR touches exactly one phase. No mixing.
- **INV-5 · No orphaned behaviour.** A feature is only removed once its replacement passes a parity test.
- **INV-6 · Deterministic layer computes; LLM never does arithmetic.** Enforced from Phase 3 on.
- **INV-7 · `Decimal` for money.** No `Double` enters a monetary field (lint/review gate).

---

## 6. Branch, PR & review conventions

- **Branch:** `feat/migration/<phase>-<task>` — e.g. `feat/migration/p0-model-value-types`.
- **PR title:** `[Phase N · Task N.M] <objective>`.
- **PR body must include:** the task's Objective, a checklist of its Definition of Done, evidence the
  global invariants hold (test output), and the task's Rollback strategy.
- **Size guard:** if a task's diff exceeds ~400 lines of non-test code, split it. Tasks here are sized
  to stay under that.
- **Merge order:** respects the dependency graph in §3. A task's `Dependencies` list names the tasks
  that must be merged first.

---

## 7. Success criteria (definition of "migration complete")

The migration is done when all of the following hold:

1. **No per-question handlers remain.** `crossDocumentAnswer`, `documentContentAnswer`,
   `documentMetadataAnswer`, and `FinanceRouter` are deleted; every deterministic answer flows through
   the Query Engine.
2. **Zero model-generated numbers.** A test proves every figure in a chat answer originates from a
   `QueryResult`, never from LLM free-text.
3. **Golden-answer parity.** Both validation documents (the 173-transaction sample suite) pass through
   the new pipeline, with divergences from the old answers reviewed and signed off.
4. **Citations everywhere.** Every deterministic answer can name the exact transactions behind it.
5. **Facts vs estimates separated.** Insights are labelled `estimated` with confidence + evidence;
   deterministic facts never carry hedging.
6. **Extensible by data, not code.** A new bank is a profile; a new source is a `StatementSource`; a new
   question is a query composition; a new detector is a pipeline manifest entry.
7. **Conformance never broke.** INV-1 held on every merged PR (verifiable from CI history).

---

## 8. Task index

| Phase | Tasks | Doc |
|-------|-------|-----|
| 0 · Canonical Model | 0.1–0.7 | [PHASE-0.md](PHASE-0.md) |
| 1 · Query Engine | 1.1–1.5 | [PHASE-1.md](PHASE-1.md) |
| 2 · Enrichment | 2.1–2.8 | [PHASE-2.md](PHASE-2.md) |
| 3 · Intent → Query | 3.1–3.5 | [PHASE-3.md](PHASE-3.md) |
| 4 · Knowledge & Insights | 4.1–4.3 | [PHASE-4.md](PHASE-4.md) |
| 5 · Sources | 5.1–5.4 | [PHASE-5.md](PHASE-5.md) |

---

## 9. Risk register (cross-phase)

| Risk | Phase | Mitigation |
|------|-------|------------|
| Persistence migration corrupts saved statements | 0 | v1→v2 migration behind a version tag; keep v1 decoder; re-parse fallback from persisted text. |
| Behavioural drift when handlers are replaced | 1, 3 | Golden-answer parity suite; wrap-then-delete (D4). |
| Detector false positives (e.g. salary over-count) | 2 | Confidence thresholds; labelled fixtures on the 6 real statements; precision gates. |
| LLM emits invalid/unfaithful queries | 3 | Strict schema validation + bounded re-ask; deterministic fast-path; explain-only-from-results. |
| Cache staleness | 4 | `(scope, dataVersion)` key; dataVersion bumps on any ingest. |
| pbxproj / SPM wiring breakage | all | Each module scaffolded in its own task (0.1, 1.1, 3.1) with a build-only DoD before logic lands. |
