# Phase 3 — Intent → Query

**Goal.** Replace regex routing with an LLM that turns natural language into a validated, structured
`Query` (never a number), executes it via the engine, and narrates the exact results. Retire
`FinanceRouter` and the remaining handlers (decision D4, second half).

**Depends on:** Phases 1 (engine) and 2 (enrichment/tags).
**Risk level:** Higher — LLM reliability and schema adherence.

**Invariant introduced here:** INV-6 — the LLM performs no arithmetic; every figure in an answer
originates from a `QueryResult`.

---

## Task 3.1 — Scaffold `PennyIntel` + Query JSON schema + validator

**Objective.** Add the `PennyIntel` module, a Codable JSON representation of `Query`, and a strict validator
that rejects malformed/unfaithful queries before execution.

**Scope.** In: module wiring, `QuerySchema` (JSON ⇄ `Query`), validation. Out: LLM calls (3.2).

**Files to create.**
- `PennyMac/PennyCore/Sources/PennyIntel/PennyIntel.swift`
- `.../PennyIntel/QuerySchema.swift`, `.../PennyIntel/QueryValidator.swift`

**Files to modify.**
- `PennyMac/PennyCore/Package.swift` — `PennyIntel` product/target depending on `PennyFinance` + `PennyCore`
  (LLM).
- `PennyMac/Penny.xcodeproj/project.pbxproj` — app depends on `PennyIntel`.

**Public APIs.**
```swift
public enum QuerySchema {
    public static func decode(_ json: Data) throws -> [Query]        // multiple sub-queries per turn
    public static var jsonSchemaString: String                       // handed to the model as the grammar
}
public enum QueryValidator {
    public static func validate(_ q: Query, against graph: FinancialGraph) -> Result<Query, IntentError>
}
```
- Validation rejects: unknown merchant/category refs with no fallback, empty filter+aggregate combos,
  out-of-range pages, and any field the schema doesn't define.

**Dependencies.** 1.4, 2.2.

**Risks.** Schema drift vs the `Query` type. Mitigate: a single source-of-truth encoding + a round-trip test
(`Query → JSON → Query`).

**Testing strategy.** Encode/decode round-trip for representative queries; validator accepts valid,
rejects each malformed class.

**Definition of Done.**
- [ ] `Query ⇄ JSON` round-trips; validator enforces the schema; `PennyIntel` builds green.
- [ ] INV-1..3 hold.

**Rollback strategy.** Additive module; revert commit.

---

## Task 3.2 — Intent parser (LLM → validated Query)

**Objective.** Prompt the on-device model with the query grammar + the live merchant/category indexes to
emit query JSON; validate; bounded re-ask on failure.

**Scope.** In: prompt construction, model call via `PennyLLM`, index injection, one bounded re-ask. Out:
narration (3.4), fast-path (3.3).

**Files to create.** `.../PennyIntel/IntentParser.swift`.

**Files to modify.** `PennyMac/PennyCore/Sources/PennyCore/PennyLLM.swift` — add a constrained-JSON
generation entry point if needed (temperature 0).

**Public APIs.**
```swift
public struct IntentParser {
    public init(llm: PennyLLM)
    public func parse(_ question: String, context: ConversationContext, graph: FinancialGraph)
        async throws -> [Query]      // validated; throws IntentError.unparseable after re-ask
}
```
- Unknown merchant names → a `text` filter, never a fabricated `MerchantID`.

**Dependencies.** 3.1; Phase 2 (indexes).

**Risks.** Hallucinated or invalid queries. Mitigate: strict validation + one re-ask + graceful failure
("I couldn't turn that into a query"); the model is never the fallback calculator.

**Testing strategy.** Intent-eval corpus (NL → expected query JSON) with an accuracy gate; malformed model
output triggers exactly one re-ask then a clean error; deterministic model stub in CI.

**Definition of Done.**
- [ ] NL maps to validated `Query`s at/above the accuracy gate on the corpus.
- [ ] Invalid output never reaches execution; failure is graceful.
- [ ] INV-1..3 hold.

**Rollback strategy.** Feature-flag intent parsing off → fall back to Phase-1 `LegacyQueryBridge`.

---

## Task 3.3 — Deterministic fast-path

**Objective.** Recognize ultra-common shapes ("total spending", "balance", "how many transactions")
without an LLM round-trip, mapping straight to a canned `Query`.

**Scope.** In: a small, explicit recognizer → `Query`. Out: general NL (3.2 handles the rest).

**Files to create.** `.../PennyIntel/FastPath.swift`.

**Dependencies.** 1.4.

**Risks.** Fast-path diverging from LLM path. Mitigate: fast-path emits the *same* `Query` types; both go
through the same engine; parity test.

**Testing strategy.** Each fast-path shape yields the expected `Query` and matches the LLM path's result on
the fixture.

**Definition of Done.**
- [ ] Top-N common questions bypass the model with identical results.
- [ ] INV-1..3, INV-6 hold.

**Rollback strategy.** Disable the fast-path; all questions route through the LLM parser.

---

## Task 3.4 — Explain service + conversation context

**Objective.** Narrate a `QueryResult` in natural language using **only** the numbers the engine returned,
and resolve follow-ups ("how much did I spend there?") from the previous turn's query.

**Scope.** In: explanation prompt (results-only), `ConversationContext` (last query/entities), citation
surfacing. Out: insights/estimates (Phase 4).

**Files to create.** `.../PennyIntel/ExplainService.swift`, `.../PennyIntel/ConversationContext.swift`.

**Public APIs.**
```swift
public struct ExplainService { public func explain(_ results: [QueryResult], for question: String)
    async throws -> String }
public struct ConversationContext { public var lastQuery: Query?; public var lastEntities: [String] }
```

**Dependencies.** 3.2.

**Risks.** The model inventing figures during narration. Mitigate: the explain prompt receives only the
computed results + a hard instruction; a test scans the answer's numbers against the result set (INV-6).

**Testing strategy.** "spend at Tesco in June" then "was any refunded?" resolves context; a numeric-fidelity
test asserts every number in the narration appears in the `QueryResult`.

**Definition of Done.**
- [ ] Narration uses only engine numbers; follow-ups resolve; citations attached.
- [ ] INV-6 enforced by test.
- [ ] INV-1..3 hold.

**Rollback strategy.** Fall back to a deterministic template renderer of `QueryResult` (no LLM narration).

---

## Task 3.5 — `ChatOrchestrator` replaces the `send()` waterfall; retire `FinanceRouter`

**Objective.** Replace `AppModel.send()`'s handler waterfall with a clean orchestrator (fast-path → intent
parse → execute → explain) and delete `FinanceRouter` + any remaining bespoke handlers.

**Scope.** In: `ChatOrchestrator`; `AppModel` delegates to it; delete `FinanceQuery.swift`'s router and the
`LegacyQueryBridge` scaffolding once parity holds. Out: KPIs/insights (Phase 4).

**Files to create.** `PennyMac/PennyApp/ChatOrchestrator.swift`.

**Files to modify.**
- `PennyMac/PennyApp/AppModel.swift` — `send()` calls `ChatOrchestrator`; remove residual handlers.
- `PennyMac/PennyCore/Sources/PennyTxnStore/FinanceQuery.swift` — **deleted** once parity passes.

**Dependencies.** 3.2, 3.3, 3.4.

**Risks.** Regression on the full question surface. Mitigate: the golden-answer parity suite (from 1.5) must
pass entirely through the new orchestrator before `FinanceRouter` is deleted (INV-5).

**Testing strategy.** Full parity suite + `EndToEndSpecTests` via the orchestrator; conversation E2E tests;
end-to-end app verification.

**Definition of Done.**
- [ ] `FinanceRouter` and all bespoke handlers deleted; chat flows through `ChatOrchestrator`.
- [ ] Parity suite green through the new path; INV-6 test green.
- [ ] INV-1..3, INV-5 hold; app verified end-to-end (INV-2).

**Rollback strategy.** Re-introduce `FinanceRouter` from git history behind a flag; orchestrator falls back
to `LegacyQueryBridge` until the regression is fixed.

---

## Phase 3 exit criteria

- Natural language → validated `Query` → engine → narrated result, with citations and confidence.
- No regex routing, no `FinanceRouter`, no bespoke handlers remain.
- A test proves zero chat figures are model-generated.
