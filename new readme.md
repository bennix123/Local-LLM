# Detailed Technical Summary — Local LLM Bank RAG

## Overview

An offline, Electron-packaged desktop application that runs a local LLM
in-process for querying personal bank statements. No cloud, no Ollama, no
external server — the LLM engine (`node-llama-cpp`, a llama.cpp binding)
runs embedded in Node.js. Bank data never leaves the machine.

**Stack:** Node.js (ES modules) · Express · Electron · node-llama-cpp ·
node:sqlite (built-in, no native compilation) · PapaParse · SheetJS ·
pdf-parse

## Architecture

```
┌──────────────────────────────────────────────┐
│  Electron main process (electron/main.js)    │
│  Spawns server.js as child process, polls    │
│  /api/state until ready, opens BrowserWindow │
├──────────────────────────────────────────────┤
│  Express HTTP server (server.js :3000)       │
│  Serves static frontend from public/         │
│  ┌──────────┐ ┌────────┐ ┌───────────────┐  │
│  │API routes│ │Multer  │ │SSE + streamed │  │
│  │(/api/*)  │ │uploads │ │chat responses │  │
│  └────┬─────┘ └────────┘ └───────────────┘  │
│       │                                       │
│  ┌────┴──────────────────────────────────┐   │
│  │  Core modules (src/)                   │   │
│  │  ┌─────────┐ ┌──────────┐ ┌────────┐  │   │
│  │  │ llm.js  │ │  rag.js  │ │stats.js│  │   │
│  │  │(infer)  │ │(prompts) │ │(math)  │  │   │
│  │  ├─────────┤ ├──────────┤ ├────────┤  │   │
│  │  │  db.js  │ │ingest.js │ │models  │  │   │
│  │  │(SQLite) │ │(parsers) │ │.js     │  │   │
│  │  └─────────┘ └──────────┘ └────────┘  │   │
│  └────────────────────────────────────────┘   │
├──────────────────────────────────────────────┤
│  Frontend: public/index.html + app.js        │
│  Three-step SPA: model → upload → chat       │
└──────────────────────────────────────────────┘
```

## Module-by-module Breakdown

### `src/models.js` — Model catalog

Static array of 6 quantized GGUF models available for download. Each has an
`id`, human-readable `name`, `uri` (HuggingFace scheme: `hf:<user>/<repo>:Q4_K_M`),
`approxSize`, and `blurb`. All use Q4_K_M quantization for small footprint.

| ID | Model | Size |
|---|---|---|
| `llama-3.2-1b` | Llama 3.2 1B Instruct | ~0.8 GB |
| `lfm2-1.2b` | Liquid AI LFM2 1.2B | ~0.8 GB |
| `lfm2-2.6b` | Liquid AI LFM2 2.6B | ~1.7 GB |
| `qwen2.5-1.5b` | Qwen2.5 1.5B Instruct | ~1.0 GB |
| `llama-3.2-3b` | Llama 3.2 3B Instruct | ~2.0 GB |
| `qwen2.5-0.5b` | Qwen2.5 0.5B Instruct | ~0.4 GB |

### `src/llm.js` — Embedded LLM engine (211 lines)

Core inference module using `node-llama-cpp`. Key behaviors:

- **Model storage:** Models download to `%LOCALAPPDATA%/LocalLLMBankRAG/models/`
  (Windows) or `~/.local/share/LocalLLMBankRAG/models/` (macOS/Linux). A
  `manifest.json` tracks downloaded model paths.
- **Download:** Uses `createModelDownloader` with `onProgress` callback for
  SSE-based progress reporting to the UI.
- **Loading:** Creates a llama context with **8192 token** context size
  (~4 chars/token ≈ 32K characters). This fits a full bank statement plus
  system prompt and answer.
- **GPU/CPU fallback:** First attempts GPU (Vulkan/CUDA/Metal via
  `getLlama({})`). On out-of-memory failure, retries once with `{ gpu: false }`
  forcing CPU fallback.
- **Warm-up:** After loading, fires a single-token `"Hi"` prompt then clears
  history. This pays the one-time buffer allocation / graph build cost before
  the user asks their first real question.
- **Chat session:** Creates `LlamaChatSession` per turn with:
  - `temperature: 0.2` (low — we want faithful numbers, not creativity)
  - `maxTokens: 500`
  - Repeat penalty: `penalty=1.3`, `frequencyPenalty=0.3`, `presencePenalty=0.3`
  - DRY penalty: `strength=0.8` (targets repeated multi-token sequences that
    cause degeneration loops)
- **Concurrency safety:** Chat calls are chained through a serial promise queue
  to prevent concurrent generations from corrupting the single context sequence.

### `src/db.js` — SQLite persistence (118 lines)

Uses Node's built-in `node:sqlite` (`DatabaseSync`). Database lives at
`data/bank.db`. WAL journal mode for concurrent read performance.

**Schema:**
- `meta` — key-value table for fileName, columns (JSON), rowCount, summary
- `chunks` — FTS5 virtual table with `content` (full-text searchable) and
  `row_index UNINDEXED` (preserves sort order)

**Exported functions:**
- `initDb()` — creates data directory, opens DB, creates tables
- `replaceDocument()` — wraps DELETE+INSERT in a manual `BEGIN/COMMIT` transaction
- `getAllChunks()` — returns all rows ordered by row_index
- `getTotalContentLength()` — SUM(LENGTH(content)) for context budget check
- `searchChunks(query, limit)` — Unicode-aware tokenization (extracts
  `[\p{L}\p{N}]+` tokens > 1 char), constructs FTS5 MATCH query with OR'd
  double-quoted terms, sorted by rank
- `hasDocument()` — returns true if any rows exist

### `src/ingest.js` — File parsing (90 lines)

Dispatches on file extension to three parsers:

- **CSV/TXT:** PapaParse with `header: true`, `skipEmptyLines: "greedy"`.
  Filters out fully empty rows.
- **XLSX/XLS:** SheetJS (`XLSX.read` → `sheet_to_json` with `defval: ""`,
  `raw: false` for stringified cell values). Filters empty rows.
- **PDF:** `pdf-parse` extracts text, splits on newlines, filters blank lines.
  Columns array is empty (unstructured).

Each row is formatted as: `Row N | col: val; col: val; ...` for human/LLM
readability and FTS5 search quality. Capped at 20,000 rows.

### `src/stats.js` — Deterministic aggregation (154 lines)

Because small LLMs are unreliable at arithmetic over many rows, all totals and
aggregates are pre-computed here and injected as authoritative "facts" into the
system prompt.

- **`toNumber(raw)`** — Robust string-to-number parser handling:
  - Negative accounting notation: `(123.45)` → `-123.45`
  - Currency symbols, thousands separators stripped
  - Date detection (rejects strings matching `\d[-/:]\d`)
  - Leading minus sign handling

- **`computeStatsSummary(columns, records)`** — Column classification:
  - Iterates each column; if ≥60% of non-empty values parse as numbers →
    classified as numeric
  - Otherwise classified as text

  Computes per numeric column: count, sum, min (with row reference), max (with
  row reference), average.

  Identifies a "description column" (text column with longest average content
  length) and a "spend column" (heuristic: matches
  `/debit|withdraw|amount|spent|charge|paid|expense/i`, falls back to first
  numeric column not matching `/balance|credit|deposit|income|date|time/i`).

  Generates a **per-payee breakdown** (top 20 by total) so the model can answer
  filtered queries like "how much did I spend at Amazon" without doing
  multi-row math.

### `src/rag.js` — Prompt builder (64 lines)

Builds the system prompt for each chat turn. Strategy:

- **Full mode:** If total content length ≤ 18,000 chars (fits within ~4500
  tokens, leaving room for facts + question + answer in the 8192 context),
  feeds **all statement rows** to the model. This enables accurate per-row
  reasoning.
- **Search mode:** For large statements, uses FTS5 keyword retrieval (top 30
  rows) and instructs the model to rely on the pre-computed facts for totals.

The prompt includes explicit rules: use pre-computed facts for math, don't
invent data, keep currency formatting, be concise. In search mode, it adds a
disclaimer that only relevant rows are shown.

### `server.js` — Express server (158 lines)

All routes return JSON except chat (streamed `text/plain`) and download
(SSE `text/event-stream`).

| Endpoint | Method | Description |
|---|---|---|
| `/api/state` | GET | Full app state: models catalog, downloaded list, loaded model, readiness, document meta |
| `/api/download?id=X` | GET | SSE stream: download progress → load model → done signal |
| `/api/load` | POST | Load an already-downloaded model by `{ id }` |
| `/api/upload` | POST | Multer file upload (25 MB limit) → parse → compute stats → store in SQLite |
| `/api/reset` | POST | Clears document from SQLite |
| `/api/chat` | POST | Streamed chat: builds system prompt, calls LLM, streams tokens as `text/plain` |

Static files served from `public/`. Server starts on port 3000 (configurable
via `PORT` env var).

### `electron/main.js` — Electron wrapper (57 lines)

- Spawns `server.js` as a child process using the same Node.js executable
- Polls `http://localhost:3000/api/state` up to 60 seconds (1-second intervals)
- Opens a 1400×900 `BrowserWindow` pointing at localhost:3000
- Kills the backend child process on `window-all-closed`
- Menu bar auto-hidden

### `public/index.html` — Frontend structure (88 lines)

Three sequential cards:
1. **Setup** — Model selection radio list + download button + progress bar
2. **Upload** — File input + animated multi-step processing indicator
   (Upload → Parse → Index → Ready)
3. **Chat** — Message history scroll + input form

Client-side logic in public/app.js.

### `public/app.js` — Frontend logic (299 lines)

- **Init flow:** Fetches `/api/state` on load. If model is already loaded →
  skips to app. Otherwise shows model selection UI.
- **Model selection:** Radio buttons with "downloaded" badges. Pre-selects
  recommended model or first downloaded one.
- **Download flow:** SSE `EventSource` to `/api/download` — renders progress
  bar (bytes + percentage). On `done` event, transitions to app.
- **Upload flow:** File input change handler → four-step visual feedback
  (staggered with `setTimeout` for visual effect) → calls `/api/upload` →
  shows document info → enables chat.
- **Chat flow:** POSTs to `/api/chat`, reads `ReadableStream` response via
  `getReader()`, renders tokens as they arrive, auto-scrolls.

## Data Flow (End-to-End)

```
User uploads bank.csv
    │
    ▼
POST /api/upload → Multer in-memory buffer
    │
    ▼
ingest.js: parseFile() → PapaParse
    │  returns { columns, rowCount, chunks, records }
    │
    ▼
stats.js: computeStatsSummary(columns, records)
    │  returns deterministic math summary string
    │
    ▼
db.js: replaceDocument() → SQLite (chunks FTS5 + meta)
    │
    ▼
User asks "How much did I spend in total?"
    │
    ▼
POST /api/chat → rag.js: buildSystemPrompt()
    ├─ getTotalContentLength() ≤ 18K? → getAllChunks() (full mode)
    └─ else → searchChunks(question, 30) (search mode + pre-computed facts)
    │
    ▼
llm.js: chat(systemPrompt, question, onChunk)
    │  queues prompt on serial promise chain
    │  LlamaChatSession.prompt() with temp=0.2, repeat/dry penalties
    │  onTextChunk → res.write → streamed to client
    │
    ▼
Client renders token-by-token in chat UI
```

## Key Design Decisions

1. **Pre-computed facts over LLM arithmetic:** Small models (0.5B–3B) cannot
   reliably sum 500+ rows. `stats.js` does the math deterministically and the
   model only needs to *report* numbers.

2. **Full-statement feeding when possible:** Instead of always using top-K
   retrieval, the code checks total content length against the context budget
   (18K chars ≈ 4500 tokens). If it fits, every transaction row is fed to the
   model for maximum accuracy on row-specific questions.

3. **FTS5 with Unicode tokenization:** Custom tokenizer extracts
   `[\p{L}\p{N}]+` tokens, filters short ones, builds OR'd FTS5 MATCH queries.
   This handles non-ASCII payee names, invoice numbers, etc.

4. **GPU→CPU automatic fallback:** On OOM (common on integrated GPUs with
   <4GB VRAM), the loader retries with `{ gpu: false }`. The flag `useCpu`
   persists so subsequent model loads don't reattempt GPU.

5. **Warm-up inference:** The one-time cost of buffer allocation, graph
   compilation, and cache initialization is paid during model loading. Without
   it, the first user question would incur a 5–30 second stall.

6. **Serialized prompt queue:** A single promise chain ensures only one
   generation at a time uses the context sequence, preventing token corruption
   from concurrent calls.

## File Listing

```
.
├── .claude/            # Claude config (ignored)
├── .git/               # Git repo
├── .github/            # GitHub workflows
├── .gitignore
├── data/               # SQLite DB files (git-ignored)
│   └── bank.db
├── electron/
│   └── main.js         # Electron entry point
├── models/             # Downloaded GGUF model files (git-ignored)
│   └── manifest.json
├── node_modules/       # Dependencies
├── public/
│   ├── index.html      # Frontend HTML shell
│   ├── app.js          # Frontend SPA logic
│   └── style.css       # Styles
├── src/
│   ├── models.js       # Model catalog
│   ├── llm.js          # LLM: download, load, streamed chat
│   ├── db.js           # SQLite + FTS5 persistence
│   ├── ingest.js       # CSV / XLSX / PDF parsers
│   ├── rag.js          # System prompt / context builder
│   └── stats.js        # Deterministic math aggregation
├── server.js           # Express server + API routes
├── iphone-sim.js       # Mobile simulation helper
├── package.json        # Node.js manifest
├── package-lock.json
├── server.log          # Runtime log
└── README.md           # Original README
```

## Dependencies

| Package | Purpose |
|---|---|
| `node-llama-cpp` ^3.6.0 | In-process LLM inference via llama.cpp |
| `express` ^4.21.2 | HTTP server & API routing |
| `multer` ^2.1.1 | Multipart file upload handling |
| `papaparse` ^5.4.1 | CSV parsing |
| `xlsx` ^0.18.5 | Excel (.xlsx/.xls) parsing |
| `pdf-parse` ^1.1.1 | PDF text extraction |
| `electron` ^42.4.0 | Desktop app shell |
| `electron-builder` ^26.15.2 | Packaging for Windows/macOS/Linux |
| `concurrently` ^10.0.3 | Dev helper for parallel processes |
| `wait-on` ^9.0.10 | Dev helper for readiness checks |

## Build & Distribution

Build targets via electron-builder:
- **Windows:** NSIS installer (x64, oneClick=false, customizable install path)
- **macOS:** DMG (arm64 + x64 universal)
- **Linux:** AppImage + deb

Output goes to `dist/`. ASAR packaging enabled, with `*.node` native modules
unpacked.
