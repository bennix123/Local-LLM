# PennyMac — native Swift + MLX vertical slice

The App-Store-viable rewrite of Penny (see `../SWIFT_APPSTORE_PATH.md`).
Reference implementation: `../finquery/` (Python FastAPI + MLX — logic source of truth).

## What the app does
Full SwiftUI UI mirroring the FinQuery React frontend, on top of the on-device MLX
engine: **onboarding → model picker (mandatory) → dashboard** (sidebar · chat · Today
panel). Pick a model, import statement PDFs, ask questions → on-device MLX answers,
streamed. Sandboxed, no llama.cpp, no server, no cloud.

> The whole doc is still stuffed into context (no RAG yet), and the Today panel's
> financial figures show the "upload to begin" state until the deterministic SQL
> analytics layer is ported — exactly like the React panel before `/dashboard`.

## Layout
- `PennyCore/` — Swift package (unchanged core)
  - `Sources/PennyCore/PennyLLM.swift` — the LLM engine (port of `llm_provider.py`)
  - `Sources/PennyCore/StatementText.swift` — PDFKit text extraction
  - `Sources/penny-cli/` — terminal proof: `swift run penny-cli --pdf <file> "question"`
- `PennyCore/Sources/PennyTxnStore/` — statement ingestion (port of
  `finquery/backend/src/services/txn_store`): MuPDF-parity PDF text extraction
  on CGPDFScanner (`PDFTextExtractor.swift` — PDFKit is not faithful enough for
  the coordinate-clustering parsers), bank parsers (Barclays positional, PNB,
  Wrenfield, DR/CR rows, generic cascade), deterministic categorization from
  `finquery/contract/categories.json`, bank-profile registry, SQLite store.
  No MLX dependency — builds and runs with plain `swift build`.
- `PennyCore/Sources/penny-conformance/` — contract conformance runner:
  ```bash
  swift build --product penny-conformance
  .build/debug/penny-conformance run          # parses finquery/contract/fixtures/*.pdf,
                                              # exact-matches *_expected.json (15/15)
  .build/debug/penny-conformance dump-words <pdf>   # debug: pymupdf-style word tuples
  .build/debug/penny-conformance dump-text  <pdf>   # debug: get_text("text") parity
  ```
  The contract is deterministic: the Python reference passes it only with the
  LLM layers disabled, so the Swift port needs no model for parsing parity.
  (The LLM "Other"-category mop-up is an app-layer nicety on both sides.)
- `PennyApp/` — SwiftUI app, mirroring `finquery/frontend/src`:
  - `Theme.swift` — palette + money/category formatting (port of `Dashboard.css` + `format.js`)
  - `PennyAvatar.swift` — coin mascot + `penny.` wordmark
  - `AppModel.swift` — app state/routing/chat (port of `Dashboard.jsx` state + `AuthContext`)
  - `OnboardingView` · `ModelPickerView` · `DashboardView` (+ `SidebarView`, `ChatView`, `ContextPanelView`)
  - `PennyRootView.swift` — onboarding→picker→dashboard router (port of `App.jsx` routes)
- `project.yml` — XcodeGen spec → generates `Penny.xcodeproj`

## Build
```bash
# App / CLI — build through Xcode's build system (NOT plain `swift build`, see gotchas):
xcodegen generate          # in PennyMac/ (regenerates Penny.xcodeproj from project.yml)
xcodebuild -project Penny.xcodeproj -scheme penny-cli -configuration Debug \
  -derivedDataPath .dd -skipMacroValidation -skipPackagePluginValidation build
.dd/Build/Products/Debug/penny-cli --pdf ../TEST-1000.pdf "What is the largest expense?"

xcodebuild -project Penny.xcodeproj -scheme Penny -configuration Debug \
  -derivedDataPath .dd -skipMacroValidation -skipPackagePluginValidation build
open .dd/Build/Products/Debug/Penny.app
# …or just `open Penny.xcodeproj` and press Run (trust the package macros when prompted).
```

## Build gotchas (learned the hard way)
1. **`swift build` compiles but `swift run` dies with "Failed to load the default metallib"** —
   plain SwiftPM cannot compile mlx-swift's Metal shaders. Always build via Xcode/xcodebuild.
2. **Xcode 26 doesn't include the Metal compiler by default** — one-time:
   `xcodebuild -downloadComponent MetalToolchain`.
3. **mlx-swift-lm uses Swift macros** — headless builds need `-skipMacroValidation`
   (in the Xcode GUI you instead click "Trust & Enable" once).
4. **MLXLLM/MLXLMCommon moved** from `mlx-swift-examples` to `ml-explore/mlx-swift-lm`,
   and its `#huggingFaceLoadModelContainer` macro expands *into our module* — so PennyCore
   must directly depend on `swift-huggingface` (HubClient) and `swift-transformers` (Tokenizers).

## Models (mlx-community, HuggingFace)
Slice default: `Llama-3.2-3B-Instruct-4bit` (1.8 GB). Swap to `Llama-3.1-8B-Instruct-4bit`
(4.5 GB, needs 16 GB RAM) in `PennyLLM.sliceModelID` once the slice works.
First run downloads weights; they're cached afterwards.

## Signing
Local dev: ad-hoc (`CODE_SIGN_IDENTITY: "-"`), sandbox ON.
TestFlight: switch to Apple Distribution + `build/embedded.provisionprofile` (Team P4ANR778GY).
