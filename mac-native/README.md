# Penny — native macOS (SwiftUI + MLX) sketch

Skeleton for the Swift/MLX rewrite. **Not compiled** — written on a Windows box with no Xcode,
so treat the MLX call sites as "verify against the version you pin" (flagged inline).

## Files
| File | What |
|---|---|
| `Penny/AI/AiProvider.swift` | The backend-agnostic protocol + `ModelSpec` / `GenParams` / errors |
| `Penny/AI/ModelCatalog.swift` | RAM-aware model list; default = **Llama 3.1 8B (4-bit)** |
| `Penny/AI/MLXProvider.swift` | MLX implementation: download → load → stream tokens |
| `Penny/AI/AiEngine.swift` | Façade: capability-based provider choice + the only 2 model calls Penny makes |

## Dependencies (SPM)
```
https://github.com/ml-explore/mlx-swift-examples   → products: MLXLLM, MLXLMCommon
```
(pulls in `mlx-swift` and `swift-transformers`/`Hub` transitively)

## Why this is App-Store-legal
MLX runs on **Metal**, an Apple system framework:
- no JIT of *our* code, no `allow-unsigned-executable-memory`
- no spawned helper process (unlike Ollama)
- model weights are **data**, not executable code — downloading them is allowed

This is why the rewrite unblocks the Store, where Electron + Ollama/llama.cpp never could.

## Build variants — the one rule that matters
| Target | Providers compiled in | Notes |
|---|---|---|
| **App Store (`mas`)** | MLX (+ FoundationModels, + Cloud) | sandboxed. **No llama.cpp.** |
| **DMG** | the above **+ LlamaCppProvider** | hardened runtime; covers Intel Macs |

Gate the local-llama backend behind `-D ALLOW_LOCAL_LLAMACPP`, set **only** on the DMG target.
Shipping llama.cpp inside the App Store binary re-breaks review.

## Model sizing
MLX is a *framework*, not a model — **you keep 8B**.
(Apple Intelligence / Foundation Models is the fixed ~3B one; that's a different thing.)

| Model | Download | Needs |
|---|---|---|
| **Llama 3.1 8B (4-bit)** ← default | ~4.5 GB | 16 GB comfortable, 8 GB tight |
| Qwen 2.5 7B (4-bit) | ~4.3 GB | 16 GB |
| Llama 3.2 3B (4-bit) | ~1.8 GB | 8 GB |
| Qwen 2.5 3B (4-bit) | ~1.7 GB | 8 GB |

`ModelCatalog.recommended` preselects the best one this Mac's RAM can hold.

## Two things to get right
1. **Never write inside the app bundle.** Models go to
   `~/Library/Application Support/Penny/Models` (`ModelCatalog.modelsDirectory`); the DB goes to
   the same Application Support dir. Writing into the bundle breaks signing/notarization —
   this is the existing Electron bug, don't carry it over.
2. **Keep the model off the hot path.** Totals, category/merchant/time breakdowns, top expenses,
   balances and counts are answered by the **deterministic SQL layer** (zero hallucination, verified
   15/15 against ground truth). The model is only for *advice* and mopping up genuinely ambiguous
   merchant names — see the two methods on `AiEngine`. That also means you can drop the
   embeddings + vector store entirely.

## Next
- [ ] **PDFKit positional-extraction spike** ← do this FIRST; it's the go/no-go risk.
      The bank parsers cluster words by x/y; PDFKit's coordinate model differs from PyMuPDF's.
- [ ] Port the pure logic (analytics / periods / stats / currency / categoriser) + GRDB
- [ ] Port the bank parsers (biggest chunk)
- [ ] SwiftUI: onboarding, dashboard, chat, model picker
- [ ] Sign / notarize / submit
