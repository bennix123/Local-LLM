# Phase 4 — Knowledge Layer & Insights

**Goal.** Add L4 (materialized KPIs/knowledge over the query engine, cached with a data-version key) and a
separate L7 Insights layer that produces AI interpretations — always labelled `estimated`, always
evidence-linked, and never containing a model-generated number.

**Depends on:** Phases 1 (engine) and 2 (enrichment).
**Risk level:** Low–medium — mainly cache invalidation.

---

## Task 4.1 — Knowledge/KPI store (cache over the engine)

**Objective.** Precompute reusable knowledge — merchant profiles, per-month statistics, cash flow, KPI set,
recurring register — as a cache keyed by `(scope, dataVersion)`, always re-derivable from L3.

**Scope.** In: knowledge views + cache + invalidation. Out: AI insights (4.3).

**Files to create.**
- `PennyMac/PennyCore/Sources/PennyFinance/Knowledge/KPIStore.swift`
- `.../Knowledge/MerchantProfile.swift`, `.../Knowledge/MonthlyStats.swift`, `.../Knowledge/CashFlow.swift`

**Files to modify.**
- `PennyMac/PennyApp/AppModel.swift` — the Today panel / dashboard reads KPIs from the store instead of
  ad-hoc sums (`recomputeSummary` becomes a thin adapter over the store).

**Public APIs.**
```swift
public struct KPIStore {
    public init(graph: FinancialGraph)
    public func kpi(_ id: KPIID, scope: Scope) -> KPI            // cached; recomputes if dataVersion changed
    public func merchantProfile(_ id: MerchantID) -> MerchantProfile
    public func monthlyStats(scope: Scope) -> [MonthlyStats]
    public func cashFlow(scope: Scope) -> CashFlowSeries         // excludes internal transfers
}
public struct KPI: Sendable { public let id: KPIID; public let value: ScalarValue
    public let asOf: Date; public let sourceQuery: Query }       // re-runnable provenance
```
- KPI set: total income, total spend, net, savings rate, avg daily/weekly/monthly spend, largest
  expense/income, highest/lowest/average balance, transaction/debit/credit counts, foreign spend, ATM
  total, subscription count, refund count, salary count, recurring count.
- Cache key `(scope, dataVersion)`; `dataVersion` bumps on any ingest/enrichment change → staleness
  impossible.

**Dependencies.** 1.4, 2.8.

**Risks.** Cache/live divergence. Mitigate: every KPI stores its `sourceQuery`; a test asserts cached value
== live `QueryEngine.execute(sourceQuery)`.

**Testing strategy.** Cache==live parity for every KPI on the fixture; invalidation on a simulated ingest;
cash flow excludes internal transfers; dashboard values unchanged vs current Today panel.

**Definition of Done.**
- [ ] KPIs/profiles/cash flow served from cache; each equals its live query; invalidation correct.
- [ ] Dashboard reads from the store with no value change.
- [ ] INV-1..3 hold.

**Rollback strategy.** Dashboard reverts to `recomputeSummary`; store bypassed (still re-derivable).

---

## Task 4.2 — KPI parity & invalidation hardening

**Objective.** Lock the "L4 is never a second source of truth" guarantee with exhaustive parity +
invalidation tests, and wire the dashboard fully onto the store.

**Scope.** In: parity test matrix, invalidation edge cases, dashboard cutover. Out: insights (4.3).

**Files to modify.**
- `PennyMac/PennyTests/…` — KPI parity matrix; `PennyMac/PennyApp/*` dashboard views read the store.

**Public APIs.** None new.

**Dependencies.** 4.1.

**Risks.** Missed invalidation paths (e.g. statement removal, doc deselection). Mitigate: enumerate all
mutation entry points; each bumps `dataVersion`.

**Testing strategy.** Add/remove/deselect a statement → KPIs update; every KPI matches its live query across
scopes (per-account, combined, per-currency).

**Definition of Done.**
- [ ] All KPIs pass cache==live across all scopes; every mutation path invalidates correctly.
- [ ] Dashboard fully on the store.
- [ ] INV-1..3 hold; app verified end-to-end.

**Rollback strategy.** Re-point dashboard at `recomputeSummary`.

---

## Task 4.3 — Insights layer (estimated, evidence-linked)

**Objective.** Produce AI insights (saving opportunities, spending habits, forecasts, budget suggestions,
"unusual" spend) that reason over KPIs/query results, are always flagged `estimated`, carry a confidence
and transaction-level evidence, and contain no model-generated numbers.

**Scope.** In: `Insight` production + the hard fact/estimate boundary + UI marking. Out: deterministic KPIs
(4.1).

**Files to create.**
- `PennyMac/PennyCore/Sources/PennyIntel/Insights/InsightService.swift`
- `PennyMac/PennyCore/Sources/PennyModel/Insight.swift`

**Files to modify.**
- `PennyMac/PennyApp/*` — render insights with a visible "estimate" treatment + tap-through evidence.

**Public APIs.**
```swift
public struct Insight: Identifiable, Sendable {
    public let id: InsightID; public let kind: Kind; public let title: String; public let body: String
    public let confidence: Confidence      // high/medium/low
    public let evidence: [TransactionID]
    public let estimated: Bool             // always true for this layer
    public let figures: [ScalarValue]      // only engine-computed numbers referenced
}
public struct InsightService {
    public init(kpis: KPIStore, llm: PennyLLM)
    public func insights(scope: Scope) async -> [Insight]
}
```
- Forecast pattern: a *fact* ("last 3 salaries averaged £X, engine-computed") + a labelled *estimate*
  ("so next month is likely ~£X").

**Dependencies.** 4.1; Phase 3 (LLM adapter).

**Risks.** Blurring facts and estimates; hedged numbers. Mitigate: insights receive only engine figures; a
test asserts every number in an insight came from `figures`; UI marks estimates distinctly.

**Testing strategy.** Numeric-fidelity test (no invented figures); every insight carries `estimated:true` +
evidence; low-confidence insights explain why.

**Definition of Done.**
- [ ] Insights are always `estimated`, evidence-linked, confidence-scored; numbers are engine-sourced.
- [ ] UI visibly separates facts from estimates.
- [ ] INV-1..3, INV-6 hold.

**Rollback strategy.** Disable the Insights surface; deterministic KPIs/answers are unaffected.

---

## Phase 4 exit criteria

- A KPI/knowledge cache serves dashboards fast and is provably equal to live queries.
- AI insights exist as a clearly-separated, labelled-estimate layer with evidence and no invented numbers.
- The "facts ≠ opinions" principle is enforced by tests and visible in the UI.
