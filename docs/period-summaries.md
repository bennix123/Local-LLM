# Hierarchical period summaries (scaling a small LLM to large statements)

A 2.6B model (LFM2) on a 4 GB iPhone cannot read lakhs of transaction rows. So
instead of feeding raw rows, we **pre-aggregate** the statement into a small set
of period summaries and answer trend/overview questions from those.

## What gets built

For every month present in the data (the *anchor*), we build rolling windows of
**1, 3, 6, 9 and 12 months** ending at that anchor:

```
anchor   window  period                summary
2024-08  1mo     Aug 2024              metrics + LLM narrative
2024-08  3mo     Jun – Aug 2024        metrics + LLM narrative
2024-08  6mo     Mar – Aug 2024        metrics + LLM narrative
2024-08  9mo     Dec 2023 – Aug 2024   metrics + LLM narrative
2024-08  12mo    Sep 2023 – Aug 2024   metrics + LLM narrative
```

Each record holds:
- **Deterministic metrics** (exact): income, spending, net, count, top
  categories, top payees, largest transaction.
- **An LLM narrative** (LFM2 2.6B) grounded on those metrics — natural prose for
  retrieval and readable answers.
- **An embedding** (all-MiniLM-L6-v2, 384-dim) for semantic retrieval.

So ~30 months → ~120 summary records compress tens of thousands (→ lakhs) of
rows into something the small model can read in full.

## Offline / iPhone-first design

Everything works **in-process, no servers** (the iPhone target has no Redis or
ChromaDB):

| Concern        | On-device implementation                                  |
|----------------|-----------------------------------------------------------|
| Storage        | SQLite (`period_summaries` table; embeddings as JSON)     |
| Vector search  | In-process **brute-force cosine** (`src/embed.js`)        |
| Embeddings     | `@chroma-core/default-embed` (all-MiniLM ONNX), no server |
| Prompt cache   | Redis if present, **SQLite fallback** (`prompt_cache`)    |
| LLM            | LFM2 2.6B Q4 (~1.7 GB) via node-llama-cpp                 |

Redis and ChromaDB remain optional **dev accelerators** with graceful fallback.

## Pipeline

1. `gen-data.js` — synthetic Indian-style history (≈22k txns / 24 months).
2. `build-periods.js`:
   - combine synthetic history + the real HDFC tail → one ~30-month dataset,
   - store it (records + facts) in SQLite,
   - build rolling period records with metrics (`src/periods.js`),
   - generate one narrative per period via LFM2 (Redis/SQLite **prompt-cached**,
     so rebuilds skip unchanged periods),
   - embed each summary in-process and store in SQLite.

Run (server stopped, it shares the model):

```bash
CHROMA_PORT=8001 node build-periods.js
```

## How answers are routed

`src/rag.js → buildSystemPrompt`:
- **Trend / period questions** ("spending over the last 6 months", "yearly
  overview", "Q2", "rolling 12 months") → embed the query, cosine-match the top
  ~6 period summaries from SQLite, feed only those to the LLM.
- **Exact single-figure questions** ("total spent on CRED", "salary credited")
  → the precise deterministic aggregation layer (`src/aggregate.js`) computes
  the exact value and injects it as authoritative grounding.
- Everything else → existing full-context / FTS retrieval.

This keeps exact answers exact while letting big-picture questions scale to very
large statements.
