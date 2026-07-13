# Low Level Design (LLD)
## Offline Multi-Bank Statement Parser & Natural Language Query System

**Version:** 1.0
**Companion to:** Offline_Bank_Statement_Parser_HLD.md
**Purpose:** Implementation-ready detail — module structure, data contracts, algorithms, schemas.

---

## 1. Repository / Module Structure

```
statement_parser/
├── ingestion/
│   ├── file_normalizer.py         # Stage 1
│   ├── pdf_reader.py               # digital PDF text+coords extraction
│   ├── ocr_reader.py               # Tesseract wrapper for scanned PDFs
│   └── spreadsheet_reader.py       # xlsx/csv grid loader
├── classification/
│   └── page_classifier.py          # Stage 2
├── extraction/
│   ├── table_extractor.py          # Stage 3
│   └── table_stitcher.py           # cross-page table continuity
├── profiles/
│   ├── profile_registry.py         # Stage 4 - load/match/save profiles
│   ├── heuristic_mapper.py         # Stage 4a - fallback auto-mapping
│   └── bank_profiles/              # *.json profile files, one per bank
│       ├── hdfc.json
│       ├── icici.json
│       └── sbi.json
├── normalization/
│   └── schema_normalizer.py        # Stage 5
├── categorization/
│   ├── rule_categorizer.py
│   └── embedding_categorizer.py    # Stage 6
├── storage/
│   ├── db.py                       # DuckDB/SQLite connection + migrations
│   └── models.py                   # table schemas
├── query_engine/
│   ├── nl_to_intent.py             # Stage 8 - local LLM call
│   ├── intent_schema.py            # pydantic schema for structured intent
│   ├── intent_to_sql.py            # deterministic intent -> SQL
│   └── rule_based_intents.py       # fallback pattern matchers
├── answer/
│   └── answer_generator.py         # Stage 9
├── confidence/
│   └── confidence_scorer.py        # cross-cutting: used by stages 3-6
├── pipeline.py                     # orchestrator, wires all stages
└── config.py                       # global config (model paths, thresholds)
```

---

## 2. Data Contracts Between Stages

Every stage communicates via well-defined objects (use `pydantic` models — gives you runtime validation for free, which matters a lot given how messy the input data is).

### 2.1 Stage 1 Output — `RawDocument`

```python
class RawBlock(BaseModel):
    text: str
    x0: float; y0: float; x1: float; y1: float   # bounding box
    page_num: int

class RawPage(BaseModel):
    page_num: int
    blocks: List[RawBlock]
    is_ocr: bool                # was this page OCR'd or native text?
    ocr_confidence: Optional[float]  # avg OCR confidence, if applicable
    raw_table_candidates: List[List[List[str]]]  # library-detected tables, if any

class RawDocument(BaseModel):
    source_file: str
    file_type: Literal["pdf", "xlsx", "csv"]
    pages: List[RawPage]
    password_used: Optional[str]
```

### 2.2 Stage 2 Output — `ClassifiedPage`

```python
class PageLabel(str, Enum):
    TRANSACTION_TABLE = "transaction_table"
    BANNER = "banner"
    ACCOUNT_SUMMARY = "account_summary"
    DISCLAIMER = "disclaimer"
    HEADER = "header"
    UNKNOWN = "unknown"

class ClassifiedPage(BaseModel):
    page_num: int
    label: PageLabel
    label_confidence: float          # 0-1
    label_signals: Dict[str, float]  # e.g. {"date_pattern_density": 0.8, "has_header_row": 1.0}
```

**Classification signal scoring (rule-based, weighted sum → confidence):**

| Signal | How computed | Weight |
|---|---|---|
| `date_pattern_density` | % of text blocks matching common date regexes | 0.25 |
| `numeric_density` | % of blocks that are pure numbers/amounts | 0.20 |
| `has_column_header_row` | keyword match: Date/Amount/Balance/Debit/Credit/Description/Narration (any language variant list) found aligned in one row | 0.30 |
| `row_repetition` | number of rows with similar column count/structure | 0.15 |
| `text_block_count` | very low block count → likely banner/cover | 0.10 (inverse) |

`label = argmax(weighted_score per label)`; if `top_score - second_score < 0.15` → mark `label_confidence` low and flag for manual review in confidence log.

### 2.3 Stage 3 Output — `ExtractedTable`

```python
class ExtractedRow(BaseModel):
    row_index: int
    page_num: int
    cells: List[str]              # raw cell values, positional order preserved
    cell_bboxes: List[Tuple[float,float,float,float]]

class ExtractedTable(BaseModel):
    header_row: Optional[List[str]]
    rows: List[ExtractedRow]
    spans_multiple_pages: bool
    stitched_from_pages: List[int]
```

**Table stitching rule:** if page N's last row and page N+1's first row have the same `len(cells)` and no repeated header row detected on page N+1 → treat as continuation, concatenate.

### 2.4 Stage 4/4a Output — `ColumnMapping`

```python
class ColumnRole(str, Enum):
    DATE = "date"; DESCRIPTION = "description"; DEBIT = "debit"
    CREDIT = "credit"; AMOUNT = "amount"; TYPE = "type"     # Amount+Type combo case
    BALANCE = "balance"; CATEGORY = "category"; IGNORE = "ignore"

class ColumnMapping(BaseModel):
    bank_profile_used: Optional[str]     # profile name, or None if heuristic
    mapping: Dict[int, ColumnRole]       # column_index -> role
    date_format: str                     # e.g. "%d/%m/%y"
    number_format: Literal["indian", "international"]
    mapping_confidence: float
    reconciliation_passed: Optional[bool]  # balance check result, if balance col present
```

**Heuristic auto-mapper algorithm (Stage 4a), per column:**

```
for each column c in table:
    date_score = % values matching date regex set
    numeric_score = % values matching number regex (handle commas, brackets, currency symbols)
    text_length_score = avg string length (proxy for description column)

    if date_score > 0.85: candidate_role[c] = DATE
    elif numeric_score > 0.85:
        if column contains both +ve and -ve values, or Dr/Cr suffixes -> candidate AMOUNT
        elif monotonic-ish trend + reconciles via balance formula -> candidate BALANCE
        else -> candidate DEBIT or CREDIT (disambiguate using header keyword proximity if any, else position heuristic: leftmost of the two numeric-only columns = debit, by common convention)
    elif text_length_score is max among remaining columns: candidate_role[c] = DESCRIPTION
    else: candidate_role[c] = IGNORE

# Balance reconciliation validation (critical self-check):
for i in range(1, len(rows)):
    expected_balance = balance[i-1] + credit[i] - debit[i]
    if abs(expected_balance - balance[i]) > TOLERANCE:  # TOLERANCE = 0.01
        reconciliation_failures += 1

reconciliation_passed = (reconciliation_failures / len(rows)) < 0.05   # allow <5% noise
mapping_confidence = 1.0 - (reconciliation_failures / len(rows))
```

This reconciliation check is the single highest-value piece of validation logic in the entire system — implement it first.

### 2.5 Bank Profile Schema (`bank_profiles/*.json`)

```json
{
  "bank_name": "HDFC",
  "version": 1,
  "identifiers": {
    "text_contains_any": ["HDFC BANK", "HDFC0"],
    "header_row_contains_any": ["Narration", "Withdrawal Amt", "Deposit Amt"]
  },
  "column_map": {
    "date": {"header_aliases": ["Date", "Txn Date", "Value Date"]},
    "description": {"header_aliases": ["Narration", "Particulars"]},
    "debit": {"header_aliases": ["Withdrawal Amt", "Debit Amount"]},
    "credit": {"header_aliases": ["Deposit Amt", "Credit Amount"]},
    "balance": {"header_aliases": ["Closing Balance"]}
  },
  "date_format": "%d/%m/%y",
  "number_format": "indian",
  "known_banner_page_indices": [1],
  "created_from": "manual",
  "last_validated": "2026-07-11",
  "success_rate": 0.97
}
```

`profile_registry.py` responsibilities:
- `match(document_text, header_row) -> Optional[Profile]` — score against all stored profiles, return best match above threshold (e.g. 0.7).
- `save_new_profile(mapping, source="auto")` — persist a successful heuristic mapping as a new learned profile for future fast-path matching.
- `update_success_rate(profile_name, success: bool)` — running accuracy tracking per profile, surfaced in a debug dashboard/log.

### 2.6 Canonical Schema — `Transaction` (Stage 5 output / DB table)

```sql
CREATE TABLE transactions (
    transaction_id      TEXT PRIMARY KEY,       -- uuid
    account_id          TEXT NOT NULL,
    date                DATE NOT NULL,
    description         TEXT,
    debit                DECIMAL(18,2) DEFAULT 0,
    credit               DECIMAL(18,2) DEFAULT 0,
    balance              DECIMAL(18,2),
    category             TEXT,                  -- nullable, filled by Stage 6
    category_confidence  FLOAT,
    source_bank          TEXT,
    source_file          TEXT,
    source_page          INTEGER,
    extraction_confidence FLOAT,                -- from Stage 4/4a mapping_confidence
    is_manually_corrected BOOLEAN DEFAULT FALSE,
    created_at            TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE statements_meta (
    statement_id     TEXT PRIMARY KEY,
    account_id       TEXT,
    source_file      TEXT,
    bank_profile_used TEXT,
    period_start     DATE,
    period_end       DATE,
    overall_confidence FLOAT,
    reconciliation_passed BOOLEAN,
    processed_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_txn_date ON transactions(date);
CREATE INDEX idx_txn_category ON transactions(category);
CREATE INDEX idx_txn_account ON transactions(account_id);
```

### 2.7 Categorization (Stage 6)

```python
class CategoryRule(BaseModel):
    category: str
    keywords: List[str]      # regex patterns, e.g. r"SWIGGY|ZOMATO|DOMINOS"
    priority: int             # lower = checked first

# rule_categorizer.py
def categorize_rule_based(description: str, rules: List[CategoryRule]) -> Optional[Tuple[str, float]]:
    for rule in sorted(rules, key=lambda r: r.priority):
        if any(re.search(pattern, description, re.I) for pattern in rule.keywords):
            return rule.category, 1.0   # rule match = full confidence
    return None

# embedding_categorizer.py — fallback when no rule matches
def categorize_embedding(description: str, category_vectors: Dict[str, np.ndarray], model) -> Tuple[str, float]:
    desc_vec = model.encode(description)
    scores = {cat: cosine_similarity(desc_vec, vec) for cat, vec in category_vectors.items()}
    best_cat = max(scores, key=scores.get)
    return best_cat, scores[best_cat]   # confidence = similarity score

# threshold: if confidence < 0.55 -> category = "Uncategorized"
```

**Recurring transaction detector** (for salary/EMI/rent identification):

```python
def detect_recurring(transactions: List[Transaction]) -> List[RecurringPattern]:
    # group by (rounded_amount, description_fingerprint)
    # description_fingerprint = normalized description with numbers/refs stripped
    groups = group_by(transactions, key=lambda t: (round(t.credit or t.debit, -2), fingerprint(t.description)))
    recurring = []
    for key, group in groups.items():
        if len(group) >= 3:
            day_variance = stdev([t.date.day for t in group])
            if day_variance < 5:   # occurs around the same day each month
                recurring.append(RecurringPattern(pattern=key, transactions=group,
                                                    label=infer_label(group)))  # e.g. "SALARY" if credit + large + recurring
    return recurring
```

---

## 3. Query Engine — Detailed Design (Stage 8)

### 3.1 Intermediate Structured Intent Schema

```python
class AggregationType(str, Enum):
    SUM = "sum"; COUNT = "count"; AVG = "avg"; MAX = "max"; MIN = "min"; LIST = "list"

class QueryIntent(BaseModel):
    metric: AggregationType
    target_field: Literal["debit", "credit", "balance", "amount"]
    date_range: Optional[Tuple[date, date]]
    category_filter: Optional[List[str]]
    group_by: Optional[Literal["category", "month", "week", "description"]]
    top_n: Optional[int]
    sort_direction: Optional[Literal["asc", "desc"]]
    description_keyword: Optional[str]     # for "transactions containing X"
    account_filter: Optional[str]
    raw_query: str                         # original NL query, kept for logging/debugging
```

### 3.2 Local LLM Prompt Contract (`nl_to_intent.py`)

```
SYSTEM PROMPT (fixed, not user-editable):
"You convert a user's financial question into a JSON object matching this exact schema: {schema}.
Only output valid JSON. No explanation. If a field is not applicable, omit it or set null.
Today's date is {current_date}, use it to resolve relative date ranges like 'last 3 months'."

USER: "{raw_query}"
```

- Call local model (`llama.cpp`/`Ollama`) with low temperature (0.1) for deterministic structured output.
- **Validate output against `QueryIntent` pydantic schema immediately** — if it fails validation (malformed JSON, invalid enum value, etc.), do NOT retry blindly; fall back to `rule_based_intents.py`.

### 3.3 Rule-Based Fallback Intent Matcher

Maintain a table of regex/keyword → `QueryIntent` template for the ~15-20 most common query shapes, e.g.:

| Pattern (Hinglish/English) | Resolved Intent |
|---|---|
| "total (spend\|kharcha).*(last\|pichle) (\d+) month" | `SUM debit, date_range=last N months` |
| "salary kab aata hai" | Special intent → run `detect_recurring`, filter credit+large, return dates |
| "top (\d+) transactions" | `LIST amount, sort_direction=desc, top_n=N` |
| "kis category (mein\|me) sabse zyada" | `SUM debit, group_by=category, sort desc, top_n=1` |

This fallback should cover the client's actual real-world query set (get this list directly from the client — the top 20 questions they actually ask cover 90% of usage).

### 3.4 Intent → SQL Compiler (`intent_to_sql.py`)

Deterministic, parameterized (never string-concatenate raw values — use bound parameters even though it's local, to avoid a whole class of bugs):

```python
def compile_to_sql(intent: QueryIntent) -> Tuple[str, dict]:
    select_clause = build_select(intent.metric, intent.target_field, intent.group_by)
    where_clauses = []
    params = {}
    if intent.date_range:
        where_clauses.append("date BETWEEN :start AND :end")
        params["start"], params["end"] = intent.date_range
    if intent.category_filter:
        where_clauses.append("category IN :categories")
        params["categories"] = intent.category_filter
    ...
    sql = f"SELECT {select_clause} FROM transactions WHERE {' AND '.join(where_clauses)} ..."
    return sql, params
```

### 3.5 End-to-End Query Sequence

```
User query (NL)
   -> nl_to_intent.py (local LLM) -> QueryIntent (draft)
   -> pydantic validation
        -> PASS -> intent_to_sql.py -> DuckDB execute -> results
        -> FAIL -> rule_based_intents.py -> QueryIntent (fallback)
                        -> matched -> intent_to_sql.py -> execute
                        -> no match -> return "couldn't understand confidently" + log query for review
   -> answer_generator.py -> NL response (optionally via local LLM for phrasing only)
```

---

## 4. Confidence Scoring — Cross-Cutting Design

Every record in the DB carries confidence at two levels:

- **`statements_meta.overall_confidence`** = weighted avg of: page classification confidence, column mapping confidence, reconciliation pass rate.
- **`transactions.extraction_confidence`** = per-row (usually inherited from statement-level mapping confidence, but can be lowered per-row if OCR confidence for that specific row was poor).

**Surfacing rule:**
- `confidence >= 0.9` → answer normally.
- `0.6 <= confidence < 0.9` → answer, but append a soft caveat ("Note: kuch transactions is statement mein kam confidence ke saath extract hue hain").
- `< 0.6` → do not answer numerically from this statement; prompt user to review/correct column mapping via a simple confirmation UI.

---

## 5. Orchestration (`pipeline.py`)

```python
def process_statement(file_path: str, account_id: str) -> ProcessingResult:
    raw_doc = file_normalizer.normalize(file_path)                          # Stage 1
    classified_pages = [page_classifier.classify(p) for p in raw_doc.pages] # Stage 2
    txn_pages = [p for p in classified_pages if p.label == PageLabel.TRANSACTION_TABLE]
    table = table_extractor.extract(raw_doc, txn_pages)                    # Stage 3
    table = table_stitcher.stitch_if_needed(table)

    profile = profile_registry.match(raw_doc, table.header_row)            # Stage 4
    if profile:
        mapping = profile_registry.apply(profile, table)
    else:
        mapping = heuristic_mapper.infer(table)                            # Stage 4a
        if mapping.mapping_confidence > 0.85:
            profile_registry.save_new_profile(mapping, source="auto")

    transactions = schema_normalizer.normalize(table, mapping, account_id)  # Stage 5
    transactions = categorizer.categorize_batch(transactions)               # Stage 6
    db.bulk_insert(transactions)                                            # Stage 7

    meta = build_statement_meta(mapping, transactions)
    db.insert_meta(meta)
    return ProcessingResult(transactions=transactions, meta=meta)


def answer_query(raw_query: str, account_id: str) -> str:
    intent = nl_to_intent.resolve(raw_query)                                # Stage 8
    sql, params = intent_to_sql.compile_to_sql(intent, account_id)
    results = db.execute(sql, params)
    return answer_generator.generate(intent, results)                      # Stage 9
```

---

## 6. Config (`config.py`)

```python
CONFIG = {
    "ocr": {"engine": "tesseract", "lang": "eng"},
    "local_llm": {"backend": "ollama", "model": "llama3.1:8b-instruct-q4_K_M", "temperature": 0.1},
    "embedding_model": {"name": "all-MiniLM-L6-v2", "device": "cpu"},
    "thresholds": {
        "profile_match_min_score": 0.7,
        "auto_save_profile_min_confidence": 0.85,
        "category_min_confidence": 0.55,
        "reconciliation_tolerance": 0.01,
        "page_label_confidence_min_gap": 0.15,
        "answer_confidence_high": 0.9,
        "answer_confidence_low": 0.6
    },
    "db": {"engine": "duckdb", "path": "./data/statements.duckdb"}
}
```

---

## 7. Testing Strategy (per module)

| Module | Test type |
|---|---|
| `page_classifier` | Golden-labeled pages from 10+ real bank statement samples (banner/summary/table/disclaimer) |
| `heuristic_mapper` | Synthetic tables with shuffled column orders + known ground truth mapping |
| Balance reconciliation | Inject known-good and known-bad debit/credit assignments, assert detection |
| `nl_to_intent` | Fixed set of ~50 NL queries (including Hinglish phrasing) with expected `QueryIntent` output, run on every model/prompt change |
| End-to-end | Full statement → query → answer, for each bank profile, run as regression suite before every release |

Build the golden test set from your **actual failing client statements first** — that's your highest-value regression suite since it directly targets the bugs the client has already hit.

---

## 8. Notes on Local LLM Sizing

- 3B–8B quantized (Q4_K_M GGUF) models via `llama.cpp`/`Ollama` are generally sufficient for the **intent-extraction** task (structured JSON output from a financial NL query) — this is a narrower, more constrained task than open-ended generation, so smaller models perform reasonably.
- If client hardware is very constrained (no GPU, low RAM), lean more heavily on `rule_based_intents.py` as primary and use the local LLM only for queries the rules don't cover — keeps the system fast and reliable on modest hardware.
- Keep the LLM strictly out of the "what are the numbers" path (Stage 7 DB is ground truth) — LLM only ever translates language ↔ structure, never computes or fabricates financial figures itself.
