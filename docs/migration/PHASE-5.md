# Phase 5 — Sources & Extensibility

**Goal.** Make ingestion pluggable: a `StatementSource` protocol so PDF, CSV, OCR, and Open Banking all emit
the same canonical model, plus a clean path to add banks by data (profiles) not code.

**Depends on:** Phase 0 (model). Parallelizable with Phases 1–4 once Phase 0 lands.
**Risk level:** Low — additive.

---

## Task 5.1 — `StatementSource` protocol; refactor PDF ingest behind it

**Objective.** Introduce a source abstraction and move the existing PDF pipeline behind it, emitting
`Account` + `Statement` + `[Transaction]` with zero behaviour change.

**Scope.** In: protocol + PDF adapter. Out: new sources (5.2–5.4).

**Files to create.**
- `PennyMac/PennyCore/Sources/PennyTxnStore/Sources/StatementSource.swift`
- `.../Sources/PdfStatementSource.swift`

**Files to modify.**
- `PennyMac/PennyApp/DeterministicIngest.swift` — dispatch through a `StatementSource` registry.

**Public APIs.**
```swift
public protocol StatementSource: Sendable {
    static func canHandle(_ url: URL) -> Bool
    func ingest(_ url: URL) throws -> (Account, Statement, [Transaction])
}
public enum StatementSourceRegistry {
    public static func source(for url: URL) -> StatementSource?
}
```

**Dependencies.** 0.4, 0.5.

**Risks.** Regression in the primary path. Mitigate: PDF adapter wraps the existing pipeline verbatim;
conformance + ground-truth unchanged.

**Testing strategy.** All 6 statements ingest via `PdfStatementSource` with identical model output;
conformance green.

**Definition of Done.**
- [ ] PDF ingest flows through `StatementSource`; output byte-for-model identical.
- [ ] INV-1..3 hold.

**Rollback strategy.** Bypass the registry, call the PDF path directly.

---

## Task 5.2 — CSV source

**Objective.** First-class CSV import producing the identical model shape as PDF (the current
`ingest(csvAt:)` becomes a `StatementSource`).

**Scope.** In: `CsvStatementSource` + header/column mapping + currency detection. Out: bank-specific CSV
dialects beyond a sensible default (add as profiles later).

**Files to create.** `.../Sources/CsvStatementSource.swift`.

**Files to modify.** `PennyMac/PennyApp/DeterministicIngest.swift` — register CSV.

**Public APIs.** `struct CsvStatementSource: StatementSource`.

**Dependencies.** 5.1.

**Risks.** Column-mapping ambiguity across banks. Mitigate: a mapping config (date/desc/amount/balance
columns) with heuristics + explicit overrides; unit-tested per dialect.

**Testing strategy.** A CSV export of a known statement yields the same counts/sums as its PDF; malformed
CSV fails gracefully with a clear error.

**Definition of Done.**
- [ ] CSV import produces a model identical in shape to PDF; graceful failures.
- [ ] INV-1..3 hold.

**Rollback strategy.** Disable CSV registration; PDF path unaffected.

---

## Task 5.3 — Additional bank profiles & the "new bank" playbook

**Objective.** Formalize adding banks/countries as data: a profile schema + a documented playbook so a new
bank needs only a profile + fixtures, no engine changes.

**Scope.** In: profile schema extension, ≥2 new bank profiles as worked examples, a `docs` playbook. Out:
OCR/Open Banking (5.4).

**Files to create.**
- `PennyMac/Resources/bank_profiles/<newbank>.json` (≥2).
- `docs/migration/ADDING-A-BANK.md` (playbook).

**Files to modify.** `PennyMac/PennyCore/Sources/PennyTxnStore/BankProfiles.swift` — schema additions if
needed.

**Dependencies.** 5.1.

**Risks.** Profile schema too rigid for new layouts. Mitigate: keep heuristic parsing as the fallback when
no profile matches (current behaviour).

**Testing strategy.** Each new profile has a fixture + a conformance-style exact-match test; heuristic
fallback still works for unprofiled banks.

**Definition of Done.**
- [ ] ≥2 new banks added via profile only; playbook documented; fixtures pass.
- [ ] INV-1..3 hold.

**Rollback strategy.** Remove the profile files; heuristic parsing resumes.

---

## Task 5.4 — OCR & Open Banking adapters

**Objective.** Add a Vision-based OCR source for scanned/image statements and an Open Banking adapter — both
as `StatementSource`s emitting the canonical model.

**Scope.** In: `OcrStatementSource` (Apple Vision text recognition → existing text pipeline) and an
`OpenBankingSource` adapter mapping API transactions → model. Out: provider-specific auth flows (tracked
separately; adapter is transport-agnostic).

**Files to create.**
- `.../Sources/OcrStatementSource.swift`, `.../Sources/OpenBankingSource.swift`.

**Files to modify.** `PennyMac/PennyApp/DeterministicIngest.swift` — register both.

**Public APIs.** two `StatementSource` conformances; `OpenBankingSource` takes a decoded transaction DTO,
not a network client (I/O injected).

**Dependencies.** 5.1.

**Risks.** OCR accuracy on poor scans; Open Banking data-shape variance. Mitigate: OCR routes into the same
text→parser path (reusing bank profiles); Open Banking maps to the model with per-provider field mapping +
confidence; both are additive and off by default until validated.

**Testing strategy.** OCR: a rasterized sample statement recovers counts within tolerance; failures are
graceful. Open Banking: a sample provider payload maps to the correct model; sums reconcile.

**Definition of Done.**
- [ ] OCR and Open Banking sources emit the canonical model; both additive and behind availability checks.
- [ ] INV-1..3 hold.

**Rollback strategy.** Unregister the sources; PDF/CSV paths unaffected.

---

## Phase 5 exit criteria

- Ingestion is a set of interchangeable `StatementSource`s all emitting the canonical model.
- A new bank is a profile + fixtures; a new source is a protocol conformance — neither touches the engine,
  enrichment, or intent layers.
