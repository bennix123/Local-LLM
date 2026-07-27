# Architecture Amendment 01 — Calendar dates & the parsed/enriched boundary

**Status:** Approved · pre-implementation of Task 0.4
**Supersedes:** the date fields and the `Transaction`/`Enrichment` field split defined in
`PHASE-0.md` Tasks 0.2/0.3 (as implemented). Everything else in the migration contract stands.
**Motivation:** the Task 0.3 architecture review surfaced structural decisions that are cheap to make
now and breaking to make after the parser adapter, persistence, and query engine are written.

This amendment is **structural only** — value-type shapes and documentation. No parsing, analytics, or
business logic is added.

---

## Decision 1 — Timezone-free calendar dates

Statement and transaction dates are **calendar dates**, not instants. `Foundation.Date` forced a
timezone choice and risked "which day / which month" drift. We introduce:

- **`CalendarDate`** — `{ year, month, day }`, `Comparable`, `Codable` as an ISO `"YYYY-MM-DD"` string.
- **`CalendarDateRange`** — an inclusive `start...end` of `CalendarDate`, with `contains(_:)`.

**Shape changes:**

| Field | Before | After |
|---|---|---|
| `Transaction.date` | `Date` | `CalendarDate` |
| `Transaction.processDate` | `Date?` | `CalendarDate?` |
| `Statement.statementDate` | `Date?` | `CalendarDate?` |
| `Statement.period` | `DateInterval?` | `CalendarDateRange?` |

`ComparableRange<Decimal>` remains the shape for **amount** filters; `CalendarDateRange` is for **date**
filters. `PennyModel` no longer depends on `Foundation.Date`/`DateInterval` in these entities.

## Decision 2 — Strict parsed-vs-enriched boundary

A transaction's **parsed facts** stay on `Transaction`; everything **derived** moves into `Enrichment`.

**Parsed → stays on `Transaction`:** `amount`, `currency`, `rawDescription`, `date`/`processDate`,
`balance`, `fx` (see Decision 3), plus identity (`id`/`accountID`/`statementID`).

**Derived → lives in `Enrichment`:** `categoryID`, `tags`, `recurringID`, `transferPairID`,
`confidence`, and now also **`merchantID`** and **`cleanDescription`** (both moved off `Transaction`).

**Shape changes:**

| Field | Before | After |
|---|---|---|
| `Transaction.merchantID` | on `Transaction` | **moved to** `Enrichment.merchantID` |
| `Transaction.cleanDescription` | on `Transaction` | **moved to** `Enrichment.cleanDescription` |

Rationale: one place for detector output means raw provenance is never overwritten, re-running the
pipeline is idempotent, and there is no ambiguity about which fields are model-guessed.

## Decision 3 — FX is parsed at ingestion

`Transaction.fx: FXInfo?` is a **parsed** field, populated by the Task 0.5 metadata parser from the FX
block the statement prints. Phase 2's `ForeignDetector` only **classifies** a transaction as `.foreign`
(a tag) and reads `fx`; it never reconstructs FX data. (`FXInfo` itself is unchanged.)

## Decision 4 — Codable evolution rules (standing discipline)

1. **New fields must be `Optional`** (or a custom `Decodable` supplies a default) — synthesized
   `Decodable` rejects missing non-optional keys, so old persisted data must still decode.
2. **Enum cases are add-only** (`Tag`, `Signal`, `Account.Kind`, `Direction`) — never renamed/removed.
3. **`Money`'s string encoding is frozen** — a single-value `"12.34"` string; never changed.
4. **Persistence always wraps the graph in a versioned envelope** (Task 0.6); a raw `FinancialGraph`
   is never written un-versioned.
5. **Task 0.6 pins a `dateEncodingStrategy`** — moot for `CalendarDate` (its own ISO-string form), but
   fixed for any residual `Date`.

## Decision 5 — Single balance convention (by `Account.Kind`)

`Money` stays a **neutral** value object — it encodes no asset/liability meaning. Balances are stored
**exactly as the statement prints them** (the natural positive magnitude, or negative when overdrawn).
**`Account.Kind` determines interpretation:**

- `.current` / `.savings` → a closing balance is an **asset** (funds held).
- `.credit` → a closing balance is a **liability** (amount **owed**).

Consumers apply sign by kind — e.g. net position `= Σ(asset balances) − Σ(credit balances)`. No
negation happens at storage. (Note: `Transaction.amount` keeps its own signed convention — negative =
money out — which is independent of how a balance is stored.)

---

## Scope of this amendment

**Files created:** `CalendarDate.swift` (`CalendarDate` + `CalendarDateRange`).
**Files modified:** `Transaction.swift`, `Statement.swift`, `Enrichment.swift` (shape), `FXInfo.swift`
(doc only), and `PennyModelTests` (updated to the new shapes; `CalendarDate` tests added).
**Out of scope:** anything in Task 0.4+. No parser, adapter, or persistence code.

**Success criteria:** package builds; all `PennyModelTests` pass (including new `CalendarDate` +
lossless round-trips of the amended entities); parser conformance stays 22/22; the app still builds.
