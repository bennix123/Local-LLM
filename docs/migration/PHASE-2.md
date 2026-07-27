# Phase 2 — Enrichment Pipeline

**Goal.** Add the enrichment layer (L2): an ordered set of `Enricher`s that tag the canonical model once at
ingest and persist the result (decision D3). Detectors are reusable and never hardcoded to a question.

**Depends on:** Phase 0 (model). Phase 1 (query engine) makes tag-based filters usable but is not required
to land detectors.
**Risk level:** Medium — detector precision and false positives.

**Cross-cutting rules for every detector:**
- Writes only to `Transaction.enrichment` (tags, flags, confidence, links) — never mutates parsed fields.
- Attaches a `confidence[Signal]` in 0…1; low-confidence tags are surfaced honestly downstream.
- Is a pure function of the `FinancialGraph`; deterministic and independently testable.
- Fixtures use the 6 real statements (`SampleGroundTruth`), with per-detector precision/recall gates.

---

## Task 2.1 — `Enricher` protocol + `EnrichmentPipeline` + eager wiring

**Objective.** Define the enricher contract, a topologically-ordered pipeline, and run it once at ingest,
persisting enrichment with a pipeline version.

**Scope.** In: protocol, ordering, invocation at ingest, versioned persistence. Out: the detectors (2.2+).

**Files to create.**
- `PennyMac/PennyCore/Sources/PennyFinance/Enrichment/Enricher.swift`
- `.../Enrichment/EnrichmentPipeline.swift`

**Files to modify.**
- `PennyMac/PennyApp/AppModel.swift` / `DeterministicIngest.swift` — run the pipeline after assembly.
- `PennyMac/PennyApp/StatementStore*.swift` — persist enrichment + `enrichmentVersion`; re-run when the
  stored version is older than the current pipeline version.

**Public APIs.**
```swift
public protocol Enricher: Sendable {
    var id: EnricherID { get }
    var dependsOn: [EnricherID] { get }
    func enrich(_ graph: inout FinancialGraph)
}
public struct EnrichmentPipeline {
    public init(_ enrichers: [Enricher])       // ordered by topological sort of dependsOn
    public static let version: Int
    public func run(_ graph: inout FinancialGraph)
}
```

**Dependencies.** 0.3, 0.6.

**Risks.** Cyclic/ambiguous dependencies. Mitigate: topological sort asserts acyclicity in tests; stable
tie-break by registration order.

**Testing strategy.** Ordering unit tests (declared `dependsOn` respected); a no-op enricher round-trips;
persisted enrichment reloads without re-running when versions match; version bump forces re-run.

**Definition of Done.**
- [ ] Pipeline runs once at ingest; enrichment persists with a version; stale versions re-run.
- [ ] INV-1..3 hold.

**Rollback strategy.** Feature-flag the pipeline off (enrichment becomes `.empty`); the app falls back to
Phase-0 behaviour.

---

## Task 2.2 — Merchant Normalizer (+ merchant index)

**Objective.** First and foundational enricher: map `rawDescription` to a canonical `Merchant`
(`merchantID`) and produce a `cleanDescription`. Build the merchant/alias index.

**Scope.** In: normalization rules (strip `STORES 2481`, `.CO.UK`, sort codes, POS/BGC prefixes), alias
table seed, fuzzy match. Out: category assignment (2.3).

**Files to create.**
- `PennyMac/PennyCore/Sources/PennyFinance/Enrichment/MerchantNormalizer.swift`
- `PennyMac/PennyCore/Sources/PennyFinance/Enrichment/MerchantIndex.swift`
- `PennyMac/Resources/merchants.json` (seed aliases: Amazon, Tesco, Apple, Shell, …).

**Files to modify.**
- `MerchantIndex` merged into `FinancialGraph.merchants` during enrichment.

**Public APIs.**
```swift
public struct MerchantNormalizer: Enricher { public init(index: MerchantIndex) }
public struct MerchantIndex: Sendable {
    public init(seed: [MerchantSeed])
    public func resolve(_ rawDescription: String) -> (MerchantID, canonical: String, clean: String)?
}
```

**Dependencies.** 2.1.

**Risks.** Over-/under-merging (e.g. "Amazon" vs "Amazon Prime"). Mitigate: alias table is data
(`merchants.json`), tunable without code; keep `Amazon Prime` as its own subscription merchant per the
validation data.

**Testing strategy.** Fixture: the 5 Tesco variants normalize to one `Merchant`; Amazon purchases (excl.
Prime) group correctly; `cleanDescription` strips ref/sort codes. Assert "most-frequent merchant" is now
computable and stable.

**Definition of Done.**
- [ ] Tesco/Amazon/Apple/Shell variants map to single merchants; `merchantID` + `cleanDescription` set.
- [ ] `merchant(.name)` query filter now resolves via the index (upgrades Task 1.3's fallback).
- [ ] INV-1..3 hold.

**Rollback strategy.** Disable the enricher; `merchantID` stays nil; queries fall back to `text` matching.

---

## Task 2.3 — Categorizer

**Objective.** Move category assignment into an enricher: merchant default → description keyword →
`Unknown`, sourced from `categories.json`. Preserve current categorization results.

**Scope.** In: categorizer enricher + confidence. Out: parser-time categorization (retire the inline path
once parity is proven).

**Files to create.**
- `PennyMac/PennyCore/Sources/PennyFinance/Enrichment/Categorizer.swift`

**Files to modify.**
- `PennyMac/PennyCore/Sources/PennyTxnStore/Categories.swift` — expose the ruleset to the enricher (shared
  source of truth); keep the parser path until parity.

**Public APIs.** `public struct Categorizer: Enricher { public init(categories: Categories) }`.

**Dependencies.** 2.1, 2.2.

**Risks.** Category drift vs the current parser (~1% "Other" today). Mitigate: parity test —
category-per-transaction must match the current output on all 173 rows before removing the parser path.

**Testing strategy.** Per-transaction category parity on the 6 statements; top category == Rent (£4,129.50);
"Other" rate unchanged.

**Definition of Done.**
- [ ] Category assignment matches current output on all 173 rows.
- [ ] `Enrichment.categoryID` populated with confidence.
- [ ] INV-1..3 hold.

**Rollback strategy.** Fall back to parser-time category; enricher disabled.

---

## Task 2.4 — Foreign · ATM · Fee detectors

**Objective.** Tag `.foreign` (+ `FXInfo`), `.atm`, and `.fee` transactions.

**Scope.** In: three independent detectors. Out: refund/recurring (later tasks).

**Files to create.**
- `.../Enrichment/ForeignDetector.swift`, `.../Enrichment/AtmDetector.swift`, `.../Enrichment/FeeDetector.swift`

**Public APIs.** three `Enricher` structs.

**Dependencies.** 2.1, 2.2.

**Risks.** Foreign detection without FX lines (some statements omit them). Signals: non-home currency,
country token, FX-fee sibling. Confidence-graded.

**Testing strategy.** Fixture: "LE PETIT BISTRO PARIS FR" → `.foreign`; expected foreign count (validation
doc says 4 — reconcile against the parsed data and record the definition used); ATM/cash rows tagged;
bank/card fees tagged.

**Definition of Done.**
- [ ] `.foreign`/`.atm`/`.fee` tags + `FXInfo` where available, with confidence.
- [ ] Foreign count reconciled to the real data with a documented rule.
- [ ] INV-1..3 hold.

**Rollback strategy.** Disable individually; tags absent, queries return empty for those filters.

---

## Task 2.5 — Refund detector

**Objective.** Tag `.refund` (refund/return/reversal/chargeback/cashback/benefit credits) and back-link the
original purchase when found.

**Scope.** In: refund detection + origin linking. Out: duplicate detection (2.8).

**Files to create.** `.../Enrichment/RefundDetector.swift`.

**Public APIs.** `public struct RefundDetector: Enricher {}` — sets `.refund` and
`Enrichment.originPurchaseID` (add field to `Enrichment`).

**Dependencies.** 2.1, 2.2, 2.3.

**Risks.** Over-tagging generic credits (e.g. salary). Guard: credit-only, keyword/merchant-driven,
excludes `.salary`. Confidence-graded; validation doc's "6 refunds" reconciled to real data with a recorded
definition.

**Testing strategy.** Fixture: "ASOS Refund", "Refund Clothes store", "Cashback", "Dining Benefit",
"Direct Debit returned" tagged; salary/employer credits NOT tagged; count reconciled.

**Definition of Done.**
- [ ] `.refund` tags with origin back-links where available; salary excluded.
- [ ] Refund count reconciled with a documented rule.
- [ ] INV-1..3 hold.

**Rollback strategy.** Disable; `.refund` absent.

---

## Task 2.6 — Recurring detector (+ `RecurringPayment`)

**Objective.** Detect recurring series (same merchant, regular cadence, stable amount) and produce
`RecurringPayment` records; tag member transactions `.recurring`.

**Scope.** In: recurrence detection over the whole graph. Out: salary/subscription specialization (2.7).

**Files to create.** `.../Enrichment/RecurringDetector.swift`; `PennyModel/RecurringPayment.swift`.

**Public APIs.**
```swift
public struct RecurringPayment: Identifiable, Codable, Sendable {
    public let id: RecurringID; public let merchantID: MerchantID
    public let cadence: Cadence; public let typicalAmount: Money
    public let lastSeen: Date; public let expectedNext: Date?; public let confidence: Double
}
```

**Dependencies.** 2.1, 2.2.

**Risks.** Single-statement inputs (~1 month) yield too few points — current detector needs ≥3 months.
Document the limitation; cadence confidence reflects sample size. Cross-statement history improves it.

**Testing strategy.** Multi-month fixture (existing `quarter` fixture) → Netflix recurring; Spotify (2
months) NOT; variable-amount café NOT. Cadence/expected-next correctness.

**Definition of Done.**
- [ ] `RecurringPayment` series produced; `.recurring` tags set with confidence; single-statement limits
      documented.
- [ ] INV-1..3 hold.

**Rollback strategy.** Disable; no recurring register (subscriptions/salary fall back to per-txn heuristics).

---

## Task 2.7 — Salary + Subscription detectors

**Objective.** Specialize recurring credits into `.salary` (payroll signal ∧ largest monthly inflow) and
recurring small fixed debits into `.subscription`.

**Scope.** In: two detectors depending on recurring. Out: internal-transfer/duplicate (2.8).

**Files to create.** `.../Enrichment/SalaryDetector.swift`, `.../Enrichment/SubscriptionDetector.swift`.

**Public APIs.** two `Enricher` structs.

**Dependencies.** 2.1, 2.2, 2.6.

**Risks.** Salary over-count (the exact bug found earlier). Rule: one primary salary per account = the
largest payroll-qualifying credit; reconcile to count 5 / total £18,413.30 on the samples (spec's
£18,603.17 is a known ChatGPT error — record this). Subscriptions: reconcile to the intended list with a
documented definition.

**Testing strategy.** Fixture: salary count == 5, per-account primary salary, highest = Monzo £7,881.82;
subscriptions list matches the documented rule; Amex (card, dining benefit) excluded from salary.

**Definition of Done.**
- [ ] `.salary` = one primary per account (count 5, total £18,413.30 on samples); `.subscription` per rule.
- [ ] INV-1..3 hold.

**Rollback strategy.** Disable; fall back to the Phase-0 `salaryAmount` shim.

---

## Task 2.8 — Internal Transfer + Duplicate detectors

**Objective.** Graph-wide: match a debit in account A to a credit in account B (same holder, close date,
equal magnitude) as `.internalTransfer` (+ `transferPairID`); flag same-merchant/amount/date collisions as
`.possibleDuplicate`. Exclude internal transfers from cash-flow sums by default.

**Scope.** In: two graph-wide detectors + a default query convention. Out: KPI cash-flow view (Phase 4).

**Files to create.** `.../Enrichment/InternalTransferDetector.swift`, `.../Enrichment/DuplicateDetector.swift`.

**Files to modify.**
- `.../Query/QueryEngine.swift` — income/spend/cash-flow aggregations exclude `.internalTransfer` unless a
  filter explicitly includes it.

**Public APIs.** two `Enricher` structs.

**Dependencies.** 2.1, 2.2; needs the whole graph (all accounts loaded).

**Risks.** False transfer matches inflating/deflating cash flow. Guard: require same holder + magnitude +
date window; confidence-graded; the exclusion is a *default*, overridable by an explicit filter.

**Testing strategy.** Multi-account fixture with a Barclays→Monzo transfer: both legs tagged + linked;
"total income" excludes it; a near-duplicate pair flagged; no false positives on unrelated equal amounts.

**Definition of Done.**
- [ ] Internal transfers matched + linked; excluded from cash-flow by default; duplicates flagged.
- [ ] INV-1..3 hold.

**Rollback strategy.** Disable; cash-flow reverts to counting transfers (documented interim).

---

## Phase 2 exit criteria

- Every transaction carries category, merchant link, and applicable tags with confidence — computed once,
  persisted, versioned.
- Tag-based query filters (`tag(.salary)`, `tag(.refund)`, `tag(.foreign)`, …) return correct, reconciled
  results on the 6 real statements.
- Cash-flow excludes internal transfers by default.
