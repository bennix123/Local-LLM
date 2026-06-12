# 🏦 Local Bank Statement Assistant (Offline LLM)

Upload a bank statement (CSV / Excel / PDF), store it locally in SQLite, and ask
questions about it in plain language. The language model runs **fully on your
machine** via [`node-llama-cpp`](https://node-llama-cpp.withcat.ai) — there is
**no Ollama, no external server, and no cloud**. After you download a model once,
the app works **completely offline** and your bank data never leaves your device.

Works on **macOS** and **Windows** (and Linux). No C/C++ compiler required —
both the LLM engine (prebuilt llama.cpp binaries) and SQLite (Node's built-in
`node:sqlite`) ship ready to run.

## Requirements

- **Node.js ≥ 22.5** (uses the built-in `node:sqlite`).
  Check with `node --version`. Download from <https://nodejs.org>.

## Install & run

```bash
npm install
npm start
```

Then open <http://localhost:3000> in your browser.

## How to use

1. **Download a model** — on first launch, pick a small model and click
   *Download*. It downloads once from Hugging Face. After that you'll see the
   **"This app is now offline"** notice and never need the internet again.
   - *Llama 3.2 1B* (default) — good balance, ~0.8 GB.
   - *[Liquid AI](https://www.liquid.ai/) LFM2 1.2B* — fast edge model, ~0.8 GB.
   - *[Liquid AI](https://www.liquid.ai/) LFM2 2.6B* — better reasoning, ~1.7 GB.
   - *Qwen2.5 1.5B* — strong small model, ~1 GB.
   - *Llama 3.2 3B* — best for number reasoning, ~2 GB.
   - *Qwen2.5 0.5B* — tiniest/fastest, weakest at math.
2. **Upload your bank statement** — CSV, `.xlsx`/`.xls`, or a text-based PDF.
   It's parsed and stored in a local SQLite database (`data/bank.db`).
3. **Ask anything** — e.g. *"How much did I spend in total?"*,
   *"What was my biggest debit?"*, *"List all grocery transactions."*

> **Tip:** for accurate totals and arithmetic, use the **1B or 3B** model.
> The 0.5B model is fast but unreliable with numbers.

## How it works

| Concern        | Implementation                                                        |
| -------------- | --------------------------------------------------------------------- |
| LLM inference  | `node-llama-cpp` (embedded llama.cpp), streamed token-by-token        |
| Model download | `node-llama-cpp` model downloader, from Hugging Face, into `models/`  |
| Storage        | Built-in `node:sqlite` with FTS5 (`data/bank.db`)                     |
| File parsing   | `papaparse` (CSV), `xlsx` (Excel), `pdf-parse` (PDF)                  |
| Retrieval      | Whole statement fed to the model when it fits; FTS5 keyword search otherwise |
| UI             | Express server + a single static HTML/JS page                         |

## Notes

- Models and your data are stored under `models/` and `data/` and are
  git-ignored — they never get committed.
- This replaces the previous Python/Streamlit + Ollama prototype (`app.py`),
  which required a separately-installed Ollama server.

## Project layout

```
server.js          Express server + API routes
src/
  models.js        Catalog of downloadable models
  llm.js           node-llama-cpp: download, load, streamed chat
  db.js            node:sqlite storage + FTS5 search
  ingest.js        CSV / XLSX / PDF parsing
  rag.js           Builds the context/prompt from the stored statement
public/            Frontend (index.html, app.js, style.css)
```
