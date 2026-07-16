# Kickoff Prompt — Rewrite Penny as a native Swift + MLX macOS app

> Copy everything in the code block below and paste it as your message to start the work.
> It's self-contained — a fresh session with zero prior context can pick it up.

---

```
You are helping me rewrite my macOS app "Penny" as a NATIVE Swift app using mlx-swift,
so it can ship on TestFlight / the Mac App Store. Read the reference docs and code in
this repo first, then start with the vertical slice defined at the bottom.

== BACKGROUND (why we're doing this) ==
Penny is an offline, on-device AI assistant for bank-statement Q&A (upload PDF/CSV bank
statements, ask questions, get grounded answers with a local LLM). Two earlier versions
exist in this repo:
  1. An Electron app (root: server.js, electron/, src/) using node-llama-cpp. It BUILDS
     and UPLOADS to TestFlight but CRASHES on launch — the App Store sandbox forbids
     node-llama-cpp's JIT/native-code execution. Proven dead end. Do NOT use this path.
  2. A Python FastAPI + React web app in finquery/ that ALREADY uses MLX (Apple Silicon,
     in-process, no llama.cpp) and WORKS locally. This is the REFERENCE IMPLEMENTATION /
     blueprint for the Swift app — but as a Python web app it cannot ship on TestFlight.

The goal: a native Swift/SwiftUI app that keeps FinQuery's on-device-MLX approach and
its logic, but is a real .app that passes the App Store sandbox.

== READ THESE FIRST (in the repo) ==
- SWIFT_APPSTORE_PATH.md   -> full plan: migration map, do/don'ts, gotchas, effort (sections 0-10)
- TESTFLIGHT.md            -> the signing/upload pipeline (already set up; carries over)
- finquery/README.md       -> what FinQuery does (hybrid RAG, RRF, page-level citations)
- finquery/backend/src/services/llm_provider.py  -> the MLX provider + MODEL_CATALOG
- finquery/backend/src/services/  -> txn_store, ml_insights, rag/retrieval, embed, etc.
- finquery/scripts/test_server/   -> server.py, prompts.py, router.py, analytics.py, ui.py, auth.py
- finquery/frontend/src/          -> React UI (Landing, ModelPicker, Login, Dashboard) to mirror in SwiftUI

== ARCHITECTURE TO PORT (from FinQuery) ==
- LLM: mlx-swift running MLX-format models from the `mlx-community` HuggingFace org.
  Catalog (already used by FinQuery): 
    mlx-community/Llama-3.1-8B-Instruct-4bit  (4.5GB, recommended, already downloaded on this Mac)
    mlx-community/Qwen2.5-7B-Instruct-4bit
    mlx-community/Llama-3.2-3B-Instruct-4bit  (1.8GB, low memory — use for the slice)
    mlx-community/Qwen2.5-3B-Instruct-4bit
- Embeddings: replace Python sentence-transformers (all-MiniLM-L6-v2) with an on-device
  Core ML or MLX embedding model. NO PyTorch.
- Vector store: replace ChromaDB with on-device SQLite (vectors + cosine similarity) or a
  Swift vector index. Keep hybrid search (dense vectors + BM25 + reciprocal rank fusion).
- PDF/CSV ingestion: PDFKit for text. NOTE: FinQuery uses `camelot` for TABLE extraction —
  there is NO clean Swift equivalent; treat native table-aware ingestion as the biggest risk.
- Deterministic SQL layer: FinQuery answers all numbers (totals, category/merchant/time
  breakdowns, balances, counts) with NO model, straight from SQL. Port this — it's pure logic.
- Prompts / router / analytics: port from scripts/test_server/{prompts,router,analytics}.py.
- Auth: simple local account (JWT-equivalent) — keep minimal for now.

== HARD CONSTRAINTS (App Store sandbox) ==
- Native macOS .app, SwiftUI. App Sandbox ENABLED.
- mlx-swift ONLY for inference (in-process, Metal). NO llama.cpp, NO GGUF, NO subprocess,
  NO bundled Python, NO PyTorch, NO local HTTP server.
- Do NOT request JIT entitlements (they don't exist for Mac App Store builds).
- The MLX model is DATA: bundle it or download it at runtime into the sandbox container (allowed).
- Reuse the existing Apple setup (carries over):
    Team ID:        P4ANR778GY
    Bundle ID:      com.localbankrag.app
    App Store app:  "Penny AI - Confidant" (App ID 6790839403)
    Certs installed: Apple Distribution + 3rd Party Mac Developer Installer (P4ANR778GY)
    Provisioning:   build/embedded.provisionprofile  (Mac App Store)

== HOW WE WORK TOGETHER ==
- You WRITE the Swift/Xcode project files and explain each step.
- I (the user) open it in Xcode and hit Run — you CANNOT build/run Xcode projects yourself.
- I report what I see / any errors; we iterate. Assume I'm a mobile/web dev, new to Swift.
- This Mac is Apple Silicon with 16 GB RAM (so the 8B model runs; use 3B for the fast slice).

== START HERE: THE VERTICAL SLICE (Phase 1, ~1 day) ==
Build the SMALLEST thing that proves the hard part works end-to-end. Deliver a minimal
macOS SwiftUI app that:
  1. Has a new Xcode project, bundle id com.localbankrag.app, App Sandbox on, arm64.
  2. Integrates mlx-swift (via Swift Package Manager) and loads an MLX model
     (start with mlx-community/Llama-3.2-3B-Instruct-4bit for speed).
  3. Lets me pick ONE PDF bank statement, extracts its text with PDFKit.
  4. Puts that text in the prompt context and lets me type ONE question.
  5. Runs inference with mlx-swift ON-DEVICE and streams the answer into the UI.
  6. No RAG/embeddings/vector-store yet — just stuff the doc text into context. That comes next.

Goal of the slice: I build it once in Xcode, ask one question about my statement, and SEE
an on-device MLX answer. That proves mlx-swift works on my Mac and de-risks the full rewrite.

Give me: the exact project setup steps (Xcode + SPM), all the Swift source files, and how
to add mlx-swift. Explain what I click. Then wait for me to build and report back.

Begin by reading SWIFT_APPSTORE_PATH.md and finquery/backend/src/services/llm_provider.py,
then give me Step 1.
```

---

## How to use this
1. Copy the whole block above (from `You are helping me…` to `…give me Step 1.`).
2. Paste it as a new message to me (this session or a fresh one).
3. I'll read the reference files and start with the vertical slice, one step at a time.

## Notes for you
- Keep the reference running when we work: FinQuery (`finquery/`) is our source of truth for
  logic/prompts. You can boot it again with the venv (`.venv/bin/python scripts/test_server.py`)
  if you want to compare behavior.
- The vertical slice uses the **3B** model for speed; we switch to **8B** once it works.
- Biggest risk to flag early: **table extraction** (no Swift `camelot`). We'll tackle it after the slice.
```
