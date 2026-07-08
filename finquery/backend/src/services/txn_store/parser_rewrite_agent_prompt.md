# Task: Rewrite `parser.py` with a Layered Fallback Chain (Rule-Based → LLM Schema-Inference → LLM Full-Extraction)

## Context

`parser.py` is part of a bank-statement ingestion pipeline (`backend/src/services/txn_store/`). It currently
supports a fixed set of banks via hardcoded parsers (`parse_pdf` for HDFC-style DR/CR rows, `parse_barclays`,
`parse_pnb`, `parse_wrenfield`) plus a generic fallback (`_parse_generic_columnar` / `_parse_generic_dateinherited`)
that works for a limited set of layouts using regex + pixel-coordinate heuristics.

**Goal:** Extend this into a 4-layer cascading parser so that *any* bank statement format — including ones never
seen before — can be ingested with a best-effort, self-validating pipeline, with an offline LLM (Ollama, local)
used only where rule-based parsing genuinely cannot cope. Do NOT regress any currently-working parser (Barclays,
PNB, Wrenfield, HDFC-style, existing generic fallback) — all existing behavior must remain intact and be tried
first, since it is faster and more accurate than LLM-based extraction.

Preserve all existing function signatures used elsewhere in the codebase: `ingest_pdf`, `is_statement_pdf`,
`detect_currency`, `parse_generic_statement`. Other internal functions can be refactored/renamed as needed, but
keep the module importable from the same places (`from .db import ...`, `from .formatters import ...`).

---

## Required Architecture: 4-Layer Cascade

Each layer must be tried in order. A layer is accepted only if it passes an **objective validation check**
(never accept silently on "looks plausible"). If a layer fails validation, fall through to the next layer.
Never let a document silently insert zero rows without trying every layer.

### Layer 0 — Known bank detection (existing, keep as-is)
`is_barclays`, `is_pnb`, `is_wrenfield`, `is_transaction_statement` → route to the matching hardcoded parser.
No changes needed here except the table-start-page fix described below (Layer 1 also benefits from it).

### Layer 1 — Generic rule-based fallback (existing, extend)
Keep `_parse_generic_columnar` and `_parse_generic_dateinherited`, but fix this bug first:

**Bug to fix:** `is_transaction_statement()` only scans `text[:20000]` of extracted text, which can be entirely
banner/ad/cover-page content for statements where the transaction table starts on page 2, 3, or mid-page.
Implement a `_find_table_start(doc) -> int` function that:
- Iterates over every page of the PDF (via PyMuPDF)
- For each page, counts lines whose first ~15 characters match a date-like regex (`\d{1,2}[-/][A-Za-z]{3}[-/]\d{2,4}`,
  `\d{2}[-/]\d{2}[-/]\d{2,4}`, `\d{4}-\d{2}-\d{2}`, etc. — reuse/extend the existing `DATE_PATTERNS`)
- Returns the index of the first page where date-line count ≥ 4 (tune threshold empirically, expose as a constant
  `TABLE_START_MIN_DATE_LINES = 4`)
- Falls back to page 0 if no page crosses the threshold (so behavior degrades to current behavior, never crashes)

Use this to scope text extraction for `is_transaction_statement`, `_parse_generic_columnar`, and
`_parse_generic_dateinherited` — they should extract from `_find_table_start(doc)` onward, not from page 0
unconditionally. Cover/banner/ad pages before that point must be excluded from line-scanning so they don't
introduce noise or false negatives.

Keep the existing `_generic_breaks(rows)` balance-reconciliation validator unchanged — it is the core trust
mechanism for every layer below too.

**Acceptance threshold for Layer 1** (already implicit in current code, make explicit as a constant):
```python
RULE_BASED_MAX_VIOLATION_RATIO = 0.10  # accept if violations <= 10% of row count (min 1)
```

### Layer 2 — LLM Schema-Inference (NEW)

This is the primary new capability. Instead of asking the LLM to extract every transaction (slow, error-prone
on numbers), ask it to infer the **structural pattern** of the table from a small sample, then apply that
pattern with Python regex across the *entire* document (fast, numbers extracted by regex not the LLM).

Implement:

```python
def detect_schema(sample_lines: list[str]) -> dict | None:
    """Send ~10-15 lines from the table-start page to Ollama, asking it to describe the
    row STRUCTURE (not extract transactions). Returns a dict or None on failure."""
```

- Prompt Ollama (see prompt spec below) with the first 10-15 non-empty lines starting from `_find_table_start(doc)`.
- Require strict JSON-only output with these keys:
  - `date_format`: human description (e.g. "DD-MM-YYYY")
  - `column_order`: list, e.g. `["date", "description", "debit", "credit", "balance"]`
  - `debit_credit_style`: one of `"separate_columns"`, `"dr_cr_suffix"`, `"sign"`
  - `sample_regex`: a Python regex string with **named groups**: `(?P<date>...)`, `(?P<desc>...)`,
    `(?P<amount>...)`, `(?P<balance>...)` (and `(?P<amount2>...)` if debit/credit are separate columns)
- Strip markdown code fences from the LLM response before `json.loads`. Locate the JSON object via
  `text.find("{")` / `text.rfind("}")` as a safety net against preamble/postamble text the model might add
  despite instructions.
- Wrap `re.compile(schema["sample_regex"])` in `try/except re.error` — invalid regex from a small model is
  expected and must fail this layer cleanly, not crash the pipeline.

Then implement:

```python
def _apply_schema_regex(pattern: re.Pattern, all_lines: list[str]) -> tuple[list[dict], float]:
    """Applies the compiled regex across every line of the document (from table-start page
    onward). Returns (matched_row_groupdicts, match_rate) where match_rate =
    len(matched) / len(candidate_lines_with_length>5). This match_rate is the primary
    trust signal for this layer — a wrong regex will match near-zero lines."""
```

**Acceptance thresholds for Layer 2** (expose as constants):
```python
SCHEMA_MIN_MATCH_RATE = 0.15      # reject if <15% of candidate lines matched
SCHEMA_MIN_ROW_COUNT = 3          # reject if fewer than 3 rows matched
SCHEMA_MAX_VIOLATION_RATIO = 0.20 # reject if >20% of converted rows fail balance reconciliation
```

Then implement row conversion + validation:

```python
def _validate_and_convert_schema_rows(matched_rows: list[dict], schema: dict) -> list[dict]:
    """Converts raw regex groupdicts into the standard row-dict shape used elsewhere in this
    file (txn_date, month, year, month_no, day, descr, merchant, category, debit, credit,
    balance, currency, seq). Must handle:
    - date parsing via existing parse_date()
    - amount/balance cleanup (strip currency symbols, commas, CR/DR suffixes) via existing _money()
    - debit_credit_style dispatch: separate_columns / dr_cr_suffix / sign
    Individual rows that fail to parse (bad date, non-numeric amount) are skipped, NOT treated
    as a reason to reject the whole batch — only match_rate and violation_ratio (computed on the
    successfully-converted rows) gate the whole layer."""
```

Then:

```python
def try_schema_inference(pdf_path: str) -> list[dict] | None:
    """Orchestrates: find table start -> detect_schema -> compile regex -> apply across
    document -> convert+validate -> check match_rate and _generic_breaks() violation ratio
    against the constants above. Returns None (not partial/silent data) if any gate fails,
    so the caller falls through to Layer 3. Returns the row list, with seq assigned in
    chronological order, if all gates pass."""
```

### Layer 3 — LLM Full Chunk Extraction (NEW, last resort)

Only reached if Layer 2 returns `None`. This is the slow path: split the statement text into overlapping
chunks and ask the LLM to extract transactions directly from each chunk.

```python
def _chunk_text(lines: list[str], chunk_size: int = 18, overlap: int = 2) -> list[str]:
    """Overlapping line-chunks so a transaction description split across a chunk boundary
    isn't lost. Overlap causes duplicate extractions across adjacent chunks — dedupe later."""

def parse_with_llm_fallback(pdf_path: str) -> Iterator[dict]:
    """From _find_table_start(doc) onward: chunk the lines, call Ollama per chunk with a
    strict JSON-array extraction prompt (see prompt spec below), parse+validate each row,
    dedupe via a (date, description, debit, credit) key across chunk overlaps, sort by date,
    assign seq, yield standard row dicts. currency='' (let ingest_pdf's header-based
    detection fill it in, same as other generic parsers)."""
```

**Acceptance for Layer 3:** No hard threshold to reject entirely (it's the last resort — something is better
than nothing), but it MUST still run through `_generic_breaks()` after the fact so the resulting confidence
level can be reported to the caller (see Confidence Reporting below).

### Master dispatcher

Rewrite `parse_generic_statement(pdf_path)` to implement the cascade:
1. Layer 1 columnar/date-inherited — accept if `_generic_breaks() == 0`, else keep best of the two if
   `violation_ratio <= RULE_BASED_MAX_VIOLATION_RATIO`
2. Else Layer 2 `try_schema_inference()` — accept if non-None
3. Else Layer 3 `parse_with_llm_fallback()` — always accept (last resort), but compare against best Layer 1
   result if one existed (with violations > threshold) and keep whichever has fewer `_generic_breaks()`
   violations
4. If literally nothing yields any rows, return empty (existing behavior — `is_statement_pdf` already handles
   this by returning False)

This function must also return/attach which layer succeeded and its violation ratio, since `ingest_pdf` needs
this for confidence reporting (see below) — either via a module-level side channel, a wrapping tuple return, or
an attribute on a small result object. **Do not break the existing generator/yield contract used by callers
that just iterate rows** — if you change the return shape, update all call sites (`is_statement_pdf`,
`ingest_pdf`) consistently within this file.

---

## Confidence Reporting (NEW requirement)

`ingest_pdf()` must record which layer was used for a given document as a `parse_confidence` value:
- `"high"`: known bank parser (Barclays/PNB/Wrenfield/HDFC-style) or Layer 1 with zero violations
- `"medium"`: Layer 1 with tolerated violations, or Layer 2 (schema-inference)
- `"low"`: Layer 3 (full LLM chunk extraction)

Store this alongside the ingested document (check `db.py` for the documents table/schema — add a
`parse_confidence` column via migration if one doesn't exist; if no documents-metadata table exists yet,
create a minimal one keyed by `(user_id, doc_name)`). Expose it so the API/UI layer can warn the user when
confidence is `medium` or `low` (e.g. "Some transactions were extracted automatically — please verify amounts").
Do not silently swallow this information.

---

## Ollama Integration Details

```python
OLLAMA_URL = "http://localhost:11434/api/generate"   # confirm/parametrize via env var OLLAMA_URL
OLLAMA_MODEL = "llama3.1:8b"                          # confirm/parametrize via env var OLLAMA_MODEL
```

- Use `requests.post` with `"stream": False`, `"options": {"temperature": 0.0}` (deterministic, no creativity
  needed for structured extraction).
- Wrap every call in try/except with a timeout (suggest 90s for schema detection, 60s per chunk for full
  extraction); on any exception, log and treat as a failed layer (return None / empty), never crash `ingest_pdf`.
- Both prompts (schema-detection and chunk-extraction) must instruct the model to output **ONLY valid JSON, no
  markdown fences, no explanation** — but code must still defensively strip ` ```json ... ``` ` fences and
  locate the JSON boundaries via `find`/`rfind`, since small local models don't always follow formatting
  instructions perfectly.

### Schema-detection prompt (Layer 2)
Must instruct the model to describe structure only (date_format, column_order, debit_credit_style,
sample_regex with named groups) — NOT to extract actual transactions. Include the sample lines verbatim.

### Chunk-extraction prompt (Layer 3)
Must instruct the model to return a JSON array where each object has exactly: `date` (YYYY-MM-DD string),
`description` (string), `debit` (number, 0 if not a debit), `credit` (number, 0 if not a credit), `balance`
(number or null). Must instruct it to ignore headers/footers/page numbers/summary lines (opening/closing
balance, totals) and to never invent transactions not present in the text.

---

## Non-negotiable Safety/Quality Constraints

1. **Never let LLM output be trusted without a numeric check.** Every LLM-derived row set (Layer 2 or 3) must
   pass through `_generic_breaks()` (or the per-row conversion validity check) before being accepted.
2. **Never crash the pipeline on LLM/network failure.** Ollama being down, timing out, or returning garbage
   must degrade gracefully to the next layer, not raise an unhandled exception out of `ingest_pdf`.
3. **Never silently reject rows without a reason.** Add log lines (or return a small diagnostics dict) stating
   why each layer was rejected (e.g. "Layer 2 rejected: match_rate=0.04 < 0.15") so this is debuggable in
   production, not a black box.
4. **Don't change currency-detection, merchant classification (`_classify`, `_barclays_merchant`,
   `MERCHANT_MAP`), or any of the existing hardcoded bank parsers' behavior.** Only extend the generic-fallback
   path and add the two new LLM layers.
5. **Keep everything offline-compatible** — no calls to any external API other than the local Ollama endpoint.
6. **Add unit-testable pure functions** wherever possible (`_chunk_text`, `_apply_schema_regex`,
   `_validate_and_convert_schema_rows`, `_find_table_start`) — i.e. don't bury all logic inside a single
   generator that's hard to test in isolation. Add a few inline docstring examples per function.

---

## Deliverables

1. Rewritten `parser.py` implementing the full 4-layer cascade described above, preserving all existing
   working parsers and their exact current behavior.
2. A short `CHANGELOG` comment block at the top of the file listing what was added/changed vs. the original.
3. If `db.py` needs a schema change for `parse_confidence`, include that migration/change as well, and note it
   explicitly in your response (don't silently modify another file without flagging it).
4. A brief test/demo script (can be a `if __name__ == "__main__":` block or a separate `test_parser.py`) that
   runs `parse_generic_statement()` against 2-3 sample PDFs (if available in the repo/test fixtures) and prints
   which layer succeeded and the violation ratio, so this can be manually sanity-checked before merging.

Do not remove or weaken any existing behavior for Barclays, PNB, Wrenfield, or HDFC-style (`parse_pdf`)
statements — those must continue to be tried first and take priority, exactly as today.
