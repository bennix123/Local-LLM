# Phase 1 — Query Engine

**Goal.** Build the composable, deterministic Query Engine (L3) in `PennyFinance` and re-express every
current deterministic chat answer as a `Query`. Wrap `FinanceRouter` behind the engine (decision D4).
No question keeps its own code path.

**Depends on:** Phase 0 (canonical model).
**Risk level:** Medium — behavioural parity across dozens of question shapes.

---

## Task 1.1 — Scaffold `PennyFinance` + Query DSL types

**Objective.** Add the `PennyFinance` library and define the query value types (`Query`, `Filter`,
`Aggregation`, `Grouping`, `SortKey`, `Page`, `QueryResult`) with no execution yet.

**Scope.** In: module wiring + pure value types. Out: execution (1.2), filters logic (1.3).

**Files to create.**
- `PennyMac/PennyCore/Sources/PennyFinance/Query/Query.swift`
- `.../Query/Filter.swift`, `.../Query/Aggregation.swift`, `.../Query/QueryResult.swift`
- `.../PennyFinance.swift` (module marker).

**Files to modify.**
- `PennyMac/PennyCore/Package.swift` — add `PennyFinance` product/target depending on `PennyModel`.
- `PennyMac/Penny.xcodeproj/project.pbxproj` — app depends on `PennyFinance`.

**Public APIs.** (per blueprint §3)
```swift
public struct Query: Codable, Sendable {
    public var filters: [Filter]; public var aggregate: Aggregation
    public var groupBy: Grouping?; public var sort: [SortKey]; public var page: Page?
}
public indirect enum Filter: Codable, Sendable {
    case account(AccountID), statement(StatementID)
    case merchant(MerchantRef), category(CategoryID), tag(Tag)
    case dateRange(DateInterval), amount(ComparableRange<Decimal>), direction(Direction)
    case currency(Currency), confidence(Signal, min: Double), text(String)
    case not(Filter), any([Filter]), all([Filter])
}
public enum MerchantRef: Codable, Sendable { case id(MerchantID); case name(String) }
public enum Aggregation: Codable, Sendable { case list, count, sum, average, min, max
                                             case topN(Int), distinctCount(GroupField) }
public enum Grouping: String, Codable, Sendable { case category, merchant, account, statement, month, day, tag }
public struct SortKey: Codable, Sendable { public enum Field { case amount, date, count }; … }
public struct Page: Codable, Sendable { public let limit: Int; public let offset: Int }
public struct QueryResult: Sendable {
    public var scalar: ScalarValue?          // sum/avg/count/min/max
    public var rows: [Transaction]           // list/topN
    public var groups: [GroupKey: QueryResult]?
    public var citations: [TransactionID]    // every contributing row
    public var currency: Currency?           // nil ⇒ multi-currency (never summed)
}
```

**Dependencies.** 0.3.

**Risks.** Module wiring (INV-2). Keep this task logic-free.

**Testing strategy.** `swift build`/`swift test` green; Codable round-trip of a `Query`.

**Definition of Done.**
- [ ] `PennyFinance` resolves; query types Codable round-trip.
- [ ] INV-1..3 hold.

**Rollback strategy.** Additive product; revert commit.

---

## Task 1.2 — Query Engine core (list · count · sum over `FinancialGraph`)

**Objective.** Implement `QueryEngine.execute(_:in:)` for the base aggregations with an initial filter set,
returning citations.

**Scope.** In: engine executing `list/count/sum` with `account/direction/dateRange/amount` filters. Out:
remaining filters (1.3), grouping/sort/paging (1.4).

**Files to create.**
- `PennyMac/PennyCore/Sources/PennyFinance/Query/QueryEngine.swift`

**Files to modify.** None.

**Public APIs.**
```swift
public enum QueryEngine {
    public static func execute(_ query: Query, in graph: FinancialGraph) -> QueryResult
}
```
- Multi-currency rule: a `sum`/`average` over mixed currencies returns `currency == nil` and a per-currency
  `groups` breakdown, never a blended total.

**Dependencies.** 1.1.

**Risks.** Sign/currency handling. Mitigate with property tests on signed sums per currency.

**Testing strategy.** `QueryEngineTests` over `SampleGroundTruth`: count == 173; `sum(direction:.debit)`
== total spend; NatWest `account` count == 33; per-currency isolation.

**Definition of Done.**
- [ ] list/count/sum correct on the 173-row fixture; citations populated.
- [ ] Mixed-currency sums never collapse.
- [ ] INV-1..3 hold.

**Rollback strategy.** Additive; revert commit.

---

## Task 1.3 — Full filter set + name resolution

**Objective.** Implement all `Filter` cases: `merchant` (by id/name), `category`, `tag`, `currency`,
`confidence`, `text`, and the `not/any/all` combinators. Resolve `merchant`/`category` names against the
graph's indexes (no hardcoded merchant strings in engine code).

**Scope.** In: all filters + resolution. Out: enrichment that populates tags/merchantID (Phase 2) — filters
tolerate absent enrichment (empty results, not crashes).

**Files to create.**
- `PennyMac/PennyCore/Sources/PennyFinance/Query/FilterResolver.swift`

**Files to modify.**
- `.../Query/QueryEngine.swift` — dispatch new filters.

**Public APIs.** (internal) `func matches(_ txn: Transaction, _ filter: Filter, in graph:) -> Bool`.

**Dependencies.** 1.2.

**Risks.** `merchant(.name)` matching before Phase 2 normalization exists → falls back to `text` over
`rawDescription`/`cleanDescription`. Document this interim behaviour.

**Testing strategy.** Filter unit tests incl. combinators; `merchant(.name:"Tesco")` over the fixture
returns the Tesco purchases; `text` fallback behaves when no `merchantID` yet.

**Definition of Done.**
- [ ] Every `Filter` case executes; combinators compose; name resolution works with graceful fallback.
- [ ] INV-1..3 hold.

**Rollback strategy.** Additive; revert commit.

---

## Task 1.4 — Aggregations, grouping, sort, pagination, citations

**Objective.** Complete `average/min/max/topN/distinctCount`, `groupBy`, multi-key `sort`, and `page`; make
citations exhaustive for every result shape.

**Scope.** In: remaining aggregations + result shaping. Out: KPI caching (Phase 4).

**Files to modify.**
- `.../Query/QueryEngine.swift`, `.../Query/QueryResult.swift`.

**Public APIs.** As declared in 1.1 (no new surface).

**Dependencies.** 1.3.

**Risks.** `distinctCount`/grouping correctness (e.g. "which statements contain salary" = distinct
statements). Mitigate with fixture assertions.

**Testing strategy.** Grouped `.sum` == category breakdown; `topN(5) groupBy:.merchant` ranks merchants;
`distinctCount(.statement)` over `tag(.salary)` == 5 (post-Phase-2, tested with a stubbed tag in Phase 1);
paging is stable and complete.

**Definition of Done.**
- [ ] All aggregations + grouping + sort + paging correct on the fixture; citations exhaustive.
- [ ] INV-1..3 hold.

**Rollback strategy.** Additive; revert commit.

---

## Task 1.5 — Legacy compatibility: route chat through the engine; wrap `FinanceRouter`

**Objective.** Replace the deterministic handler waterfall (`crossDocumentAnswer`,
`documentContentAnswer`, `documentMetadataAnswer`) and wrap `FinanceRouter` so current chat answers are
produced by composed `Query`s. Prove parity, then keep `FinanceRouter` only as a thin fallback (deleted in
Phase 3).

**Scope.** In: a `LegacyQueryBridge` mapping the currently-supported question shapes to `Query`s;
`AppModel.send` calls the engine first. Out: LLM intent parsing (Phase 3) — this task uses the existing
deterministic recognizers to build queries, not the model.

**Files to create.**
- `PennyMac/PennyCore/Sources/PennyFinance/Query/LegacyQueryBridge.swift`

**Files to modify.**
- `PennyMac/PennyApp/AppModel.swift` — `send()` routes deterministic questions through
  `QueryEngine`; delete the three `document*Answer`/`crossDocumentAnswer` handlers once parity passes;
  `FinanceRouter.answer` becomes the last-resort fallback behind the bridge.
- `PennyMac/PennyCore/Sources/PennyTxnStore/FinanceQuery.swift` — no logic change; called only via bridge.

**Public APIs.** (internal) `LegacyQueryBridge.query(for question: String, graph:) -> Query?`.

**Dependencies.** 1.4; Phase 0 complete.

**Risks.** Behavioural drift — the core risk of Phase 1. Mitigate with a **golden-answer parity suite**:
run both validation documents through old and new paths and diff; any divergence is reviewed and signed off
(some divergences are *fixes*, e.g. the salary total).

**Testing strategy.** Parity harness over the two validation docs + `SampleGroundTruth`; assert the new
engine reproduces (or intentionally corrects, with a recorded rationale) each answer. Keep
`EndToEndSpecTests` green by pointing them at the engine.

**Definition of Done.**
- [ ] The three bespoke handlers are deleted; their questions answered via `Query`.
- [ ] Parity suite passes; every intentional divergence is documented.
- [ ] `FinanceRouter` is reachable only as a wrapped fallback.
- [ ] INV-1..3, INV-5 hold; app verified end-to-end (INV-2).

**Rollback strategy.** Re-enable the handler waterfall (kept in git history) and bypass the bridge with a
feature flag until the divergence is resolved.

---

## Phase 1 exit criteria

- Every deterministic answer the app gives is produced by a composed `Query` with citations.
- The bespoke per-question handlers are gone; `FinanceRouter` survives only as a wrapped fallback.
- A golden-answer parity suite guards against drift and is green.
