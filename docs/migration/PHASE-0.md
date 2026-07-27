# Phase 0 — Canonical Model & Module Boundary

**Goal.** Introduce `PennyModel` as the single source of truth: rich, immutable, `Decimal`-money value
types where every transaction knows its account and statement, and all header metadata is parsed **once**
into structure. Adapt the existing parser to emit it and persist it. No behaviour changes for the user.

**Why first.** The account-blind, metadata-poor `TxnRow` is the root cause of the per-document handlers,
the account-blind router, and the query-time text re-scraping. Everything downstream depends on this.

**Risk level:** Low. The parser logic is unchanged; this is re-modelling + a persistence migration.

---

## Task 0.1 — Scaffold `PennyModel` module

**Objective.** Add an empty `PennyModel` library target/product and wire it into the SPM package and the
Xcode app, building green before any types land.

**Scope.** In: `Package.swift` product+target, one placeholder file, Xcode app dependency. Out: any model
types (0.2/0.3).

**Files to create.**
- `PennyMac/PennyCore/Sources/PennyModel/PennyModel.swift` (placeholder `public enum PennyModel {}`).

**Files to modify.**
- `PennyMac/PennyCore/Package.swift` — add `.library(name:"PennyModel",targets:["PennyModel"])` and a
  `.target(name:"PennyModel")` with no dependencies.
- `PennyMac/Penny.xcodeproj/project.pbxproj` — add `PennyModel` to the app target's package product deps.

**Public APIs.** None yet (placeholder).

**Dependencies.** None.

**Risks.** SPM/pbxproj wiring breakage (INV-2). Mitigated by keeping this task logic-free.

**Testing strategy.** `swift build` + `swift test` green; app builds and launches.

**Definition of Done.**
- [ ] `PennyModel` product resolves and imports from `PennyTxnStore`, `PennyApp` targets.
- [ ] INV-1, INV-2, INV-3 hold.

**Rollback strategy.** Revert the single commit; the product is additive and unused, so removal is safe.

---

## Task 0.2 — Core value types (`Money`, `Currency`, IDs, `Direction`)

**Objective.** Define the primitive value types that all entities compose from, with `Decimal`-backed money.

**Scope.** In: money, currency, typed IDs, direction, comparable ranges. Out: entities (0.3).

**Files to create.**
- `PennyMac/PennyCore/Sources/PennyModel/Money.swift`
- `PennyMac/PennyCore/Sources/PennyModel/Currency.swift`
- `PennyMac/PennyCore/Sources/PennyModel/Ids.swift`
- `PennyMac/PennyCore/Sources/PennyModel/Ranges.swift`

**Files to modify.** None.

**Public APIs.**
```swift
public struct Money: Hashable, Comparable, Codable, Sendable {
    public let amount: Decimal          // signed; negative = money out
    public init(_ amount: Decimal)
    public static func + (…) -> Money; public static prefix func - (…) -> Money
    public var isDebit: Bool { amount < 0 }
    public var magnitude: Decimal { abs(amount) }
}
public struct Currency: Hashable, Codable, Sendable { public let code: String /* ISO-4217 */ }
public enum Direction: String, Codable, Sendable { case debit, credit }
public struct AccountID: Hashable, Codable, Sendable { public let raw: String }
public struct StatementID: Hashable, Codable, Sendable { public let raw: String }
public struct TransactionID: Hashable, Codable, Sendable { public let raw: String }
public struct MerchantID: Hashable, Codable, Sendable { public let raw: String }
public struct CategoryID: Hashable, Codable, Sendable { public let raw: String }
public struct ComparableRange<Bound: Comparable>: Codable, Sendable { /* min/max, open/closed */ }
```

**Dependencies.** 0.1.

**Risks.** `Decimal` parsing/rounding edge cases (locale, thousands separators). Mitigate with explicit
`Decimal(string:locale:)` helpers and unit tests on the sample amounts.

**Testing strategy.** New `PennyModelTests`: money arithmetic, sign semantics, `Decimal` no-precision-loss
round-trip, ID equality/Codable, range containment.

**Definition of Done.**
- [ ] Money/Currency/IDs Codable round-trip losslessly.
- [ ] `Money` never uses `Double` internally.
- [ ] INV-1, INV-3 hold.

**Rollback strategy.** Additive; revert the commit.

---

## Task 0.3 — Entity types (`Account`, `Statement`, `Transaction`, `Enrichment`, `Merchant`, `Category`, `FinancialGraph`)

**Objective.** Define the canonical entities per the domain model (§2 of the blueprint), each immutable and
Codable, with `Enrichment` as an attached bag (empty until Phase 2).

**Scope.** In: entity structs + `FinancialGraph` root. Out: parsing/adapter (0.4), enrichment logic (Phase 2).

**Files to create.**
- `PennyMac/PennyCore/Sources/PennyModel/Account.swift`
- `.../Statement.swift`, `.../Transaction.swift`, `.../Enrichment.swift`
- `.../Merchant.swift`, `.../Category.swift`, `.../FXInfo.swift`
- `.../FinancialGraph.swift`

**Files to modify.** None.

**Public APIs.** (abridged — full field tables in the blueprint §2)
```swift
public struct Account: Identifiable, Codable, Sendable {
    public let id: AccountID
    public let institution: String
    public enum Kind: String, Codable, Sendable { case current, credit, savings, unknown }
    public let kind: Kind
    public let number: String?; public let sortCode: String?; public let holder: String?
    public let currency: Currency
}
public struct Statement: Identifiable, Codable, Sendable {
    public let id: StatementID; public let accountID: AccountID
    public let period: DateInterval?; public let statementDate: Date?
    public let openingBalance: Money?; public let closingBalance: Money?
    public let availableBalance: Money?; public let creditLimit: Money?
    public let sourceName: String            // original file name (provenance)
}
public struct Transaction: Identifiable, Codable, Sendable {
    public let id: TransactionID
    public let accountID: AccountID; public let statementID: StatementID
    public let date: Date; public let processDate: Date?
    public let rawDescription: String; public var cleanDescription: String
    public var merchantID: MerchantID?
    public let amount: Money; public let balance: Money?; public let currency: Currency
    public var fx: FXInfo?
    public var enrichment: Enrichment
    public var direction: Direction { amount.isDebit ? .debit : .credit }
}
public struct Enrichment: Codable, Sendable {
    public var categoryID: CategoryID?
    public var tags: Set<Tag>; public var recurringID: RecurringID?
    public var transferPairID: TransactionID?; public var confidence: [Signal: Double]
    public static var empty: Enrichment { … }
}
public enum Tag: String, Codable, Sendable { case salary, refund, subscription, transfer,
    internalTransfer, atm, foreign, fee, recurring, possibleDuplicate }
public struct FinancialGraph: Codable, Sendable {
    public var accounts: [Account]; public var statements: [Statement]
    public var transactions: [Transaction]; public var merchants: [Merchant]
    public var categories: [Category]
}
```

**Dependencies.** 0.2.

**Risks.** Over-modelling early. Mitigate: fields limited to what Phases 0–2 consume; add later via
additive Codable (optionals).

**Testing strategy.** Codable round-trip for each entity + `FinancialGraph`; `direction` derivation from
signed amount; relationship integrity helpers (`graph.transactions(in: statementID)`).

**Definition of Done.**
- [ ] All entities Codable round-trip; `FinancialGraph` composes them.
- [ ] `Transaction` carries `accountID` + `statementID`.
- [ ] INV-1, INV-3 hold.

**Rollback strategy.** Additive; revert commit.

---

## Task 0.4 — Parser → Model adapter

**Objective.** Map the existing parser output (`IngestOutput` / `[TxnRow]`) into `FinancialGraph`,
assigning account/statement/transaction identity. The parser's row logic is untouched.

**Scope.** In: a `ModelAssembler` in `PennyTxnStore` (or a new `PennyModelAdapter` file) that produces one
`Account` + one `Statement` + `[Transaction]` per ingested file. Out: header-metadata parsing (0.5),
persistence (0.6).

**Files to create.**
- `PennyMac/PennyCore/Sources/PennyTxnStore/ModelAssembler.swift`

**Files to modify.**
- `PennyMac/PennyCore/Package.swift` — `PennyTxnStore` target depends on `PennyModel`.
- `PennyMac/PennyApp/DeterministicIngest.swift` — `Result` also surfaces the assembled `FinancialGraph`
  slice (keep legacy `rows`/`transactions` for now — additive).

**Public APIs.**
```swift
public enum ModelAssembler {
    /// Build one account + statement + transactions from a parsed file.
    public static func assemble(_ out: IngestOutput, sourceName: String) -> (Account, Statement, [Transaction])
}
```
- Signed `amount` = `credit - debit` mapped to `Money`. Balance carried through. IDs derived
  deterministically (e.g. hash of `sourceName` for account/statement; `sourceName+seq` for transaction).

**Dependencies.** 0.2, 0.3.

**Risks.** Sign convention mistakes (debit/credit → signed). Mitigate: property test that
`sum(assembled.amount)` matches `income - spend` from the legacy computation on the 6 statements.

**Testing strategy.** For each of the 6 sample statements: assembled transaction count == legacy row count;
signed-amount sums reconcile with the ground-truth totals; identity is stable across two runs.

**Definition of Done.**
- [ ] `DeterministicIngest` produces both legacy rows and the new model.
- [ ] Assembled counts + signed sums match `SampleGroundTruth` for all 6 statements.
- [ ] INV-1, INV-2, INV-3 hold.

**Rollback strategy.** Adapter is additive and unused by the UI; revert commit without affecting the app.

---

## Task 0.5 — Statement header metadata into the parser

**Objective.** Parse opening/closing/available balance, credit limit, statement period, statement date,
sort code, account number, and holder **once at ingest** into `Statement`/`Account` — relocating the
ad-hoc `moneyAfterLabel` / `creditSummary` logic out of `AppModel`.

**Scope.** In: a `StatementMetadataParser` in `PennyTxnStore` populating `Statement`/`Account` fields; move
(not duplicate) the balance/credit-summary extraction. Out: consuming these in chat (Phase 1).

**Files to create.**
- `PennyMac/PennyCore/Sources/PennyTxnStore/StatementMetadataParser.swift`

**Files to modify.**
- `PennyMac/PennyCore/Sources/PennyTxnStore/ModelAssembler.swift` — call the metadata parser.
- `PennyMac/PennyApp/AppModel.swift` — mark `moneyAfterLabel`, `creditSummary`, `openingBalance` as
  deprecated shims that delegate to the parser (removed in Phase 1); no behaviour change yet.

**Public APIs.**
```swift
public enum StatementMetadataParser {
    public static func parse(headerText: String, currency: Currency)
        -> (opening: Money?, closing: Money?, available: Money?, creditLimit: Money?,
            period: DateInterval?, statementDate: Date?, sortCode: String?,
            accountNumber: String?, holder: String?)
}
```

**Dependencies.** 0.3, 0.4.

**Risks.** Regression in credit-limit/opening-balance extraction that already works in the app. Mitigate:
port the existing regexes verbatim; assert equality with current values on the 6 statements before
removing the shims.

**Testing strategy.** Golden values on the 6 real statements: Amex creditLimit £16,100 / available
£15,470.46; Barclays opening £42.20; closing balances (Monzo £12,955.90, etc.). Parity test vs the current
`AppModel` extraction output.

**Definition of Done.**
- [ ] `Statement` carries all header fields for the 6 statements, matching current app answers.
- [ ] `AppModel` no longer parses header text itself (delegates via shim).
- [ ] INV-1..3 hold.

**Rollback strategy.** Shims still delegate to old code path; revert the parser commit to restore inline
extraction.

---

## Task 0.6 — `StatementStore` v2 (persist the enriched model + migrate v1)

**Objective.** Persist `FinancialGraph` slices (account + statement + transactions) with a schema version,
and migrate existing v1 (`StoredDoc`) files without data loss.

**Scope.** In: v2 Codable schema, writer/reader, v1→v2 migration, version tag. Out: enrichment persistence
fields (populated in Phase 2, but the schema reserves them).

**Files to create.**
- `PennyMac/PennyApp/StatementStoreV2.swift` (or extend `StatementStore.swift`).

**Files to modify.**
- `PennyMac/PennyApp/StatementStore.swift` — add versioned envelope; keep v1 decoder for migration.
- `PennyMac/PennyApp/AppModel.swift` — restore path loads v2 (falls back to v1 → migrate → re-save).

**Public APIs.**
```swift
enum StatementStore {
    static func save(_ account: Account, _ statement: Statement, _ txns: [Transaction])
    static func loadAllV2() -> FinancialGraph
    static func migrateV1IfNeeded()   // decode legacy StoredDoc, assemble via ModelAssembler, re-save v2
}
```
- On-disk envelope: `{ "schema": 2, "payload": … }`. v1 files (no `schema`) trigger migration.

**Dependencies.** 0.3, 0.4.

**Risks.** Corrupting saved statements (highest-risk task in Phase 0). Mitigate: never delete v1 files
until v2 write succeeds; migration is idempotent; keep persisted raw text so a broken migration can
re-parse from source.

**Testing strategy.** Round-trip a `FinancialGraph` through save/load; migrate a captured v1 fixture and
assert equality of counts/sums; app relaunch restores the same statements (manual + `PersistenceTests`).

**Definition of Done.**
- [ ] v2 save/load round-trips; v1 files migrate idempotently with zero data loss.
- [ ] App relaunch restores statements identically (INV-2).
- [ ] INV-1..3 hold.

**Rollback strategy.** v1 files are preserved during migration; reverting the reader to v1 restores prior
behaviour. Add a one-flag "force v1 read" for emergency rollback.

---

## Task 0.7 — Bridge `AppModel`/`LoadedDoc` onto the model; re-express `SampleGroundTruth`

**Objective.** Have `AppModel` hold the new `FinancialGraph` as the backing store (behind the existing
`LoadedDoc` façade), and re-express the `SampleGroundTruth` fixture on the new types — proving the app and
its tests run on the canonical model with no user-visible change.

**Scope.** In: `LoadedDoc` gains a `graph`/`account`/`statement` backing; `SampleGroundTruth` rebuilt on
`Transaction`. Out: replacing handlers (Phase 1).

**Files to modify.**
- `PennyMac/PennyApp/AppModel.swift` — `LoadedDoc` wraps `Account`+`Statement`+`[Transaction]`; existing
  computed props (`latestBalance`, `displayName`, `isCard`) read from the model.
- `PennyMac/PennyTests/AppModelLogicTests.swift` — `SampleGroundTruth` emits `Transaction`s; existing
  assertions adapted to read the model (values unchanged).

**Public APIs.** No new public API; internal refactor.

**Dependencies.** 0.4, 0.5, 0.6.

**Risks.** Broad but shallow churn across `AppModel`. Mitigate: keep `LoadedDoc`'s public surface identical;
change only its internals.

**Testing strategy.** Full `PennyTests` + `PennyCore` suites green; `EndToEndSpecTests` still pass reading
from the model; conformance untouched.

**Definition of Done.**
- [ ] `AppModel` computes summaries/answers from the canonical model, not `TxnRow` directly.
- [ ] `SampleGroundTruth` and all Phase-0-affected tests pass on the new types.
- [ ] INV-1..3 hold; app verified end-to-end (INV-2).

**Rollback strategy.** Revert to the `TxnRow`-backed `LoadedDoc`; the model remains available but unused.

---

## Phase 0 exit criteria

- Every statement is represented as `Account` + `Statement` + `[Transaction]` with identity and structured
  header metadata.
- Persistence is v2 with a working v1 migration.
- The app and all tests run on the canonical model with **zero** user-visible behaviour change.
- Conformance (INV-1) never broke across the phase.
