# Penny MLX — Context-Training Report (brief §5–19, §34 training half)

Answers the question "did you train the model *for context*?" — now yes, as a dedicated pass,
measured honestly with the memory scaffold OFF.

## Setup
- **Data:** `data/paytm_mlx_ctx/` — 10,000 training conversations sampled from the 100K dataset's
  TRAIN split, categories multi_turn / reference_resolution / temporal_reasoning /
  context_resolution (distinct only, ≤16 messages). Valid 300. The facts live in earlier
  *assistant* turns, so this trains coreference/relational skill, not fact memorization.
- **Held-out (TEST split, no transaction overlap with train):** 240 conversations whose final
  answer is atomic (currency/name/txn_id) so it scores cleanly.
- **Eval = scaffold OFF:** raw dialogue history fed to the model; NO resolver / retriever / memory.
  Isolates the model's NATIVE ability to answer follow-ups from context.
- **Train:** LoRA rank 16, 16 layers, batch 4, lr 1e-4, `--mask-prompt`, 200 iters.
  Val loss 5.62 → train loss 0.45. Best = iter200 (`adapters/best_ctx`).

## Result — native context-following, base vs context-LoRA
| Category | base | **context-LoRA** | Δ |
|---|--:|--:|--:|
| context_resolution (switch / reset) | 0.125 | **0.984** | **+0.859** |
| reference_resolution (pronouns "it/that") | 0.397 | **0.794** | +0.397 |
| multi_turn (drill-down chains) | 0.276 | **0.655** | +0.379 |
| temporal_reasoning | 1.000 | 1.000 | +0.000 |
| **Overall** | **0.433** | **0.858** | **+0.425** |

By answer type: currency **0.44 → 0.91**, names **0.57 → 0.89**, txn_id **0.00 → 0.00**.

## Reading of the result
- **Context-training works.** It ~doubled native context-following (43% → 86%) and almost solved
  context-switch/return (0.125 → 0.984) — the model learned to track "it / that / the previous one /
  go back to the first one" from dialogue alone, no scaffold.
- **It does NOT fix opaque-ID recall (txn_id stays 0.00).** Copying a random `S…/M…` id out of
  history is a transcription/retrieval problem, not a reasoning one — parametric training can't buy it.

## How this fits with the earlier phases (the clean architectural conclusion)
| Ability | best via | evidence |
|---|---|---|
| Exact FACTS (balances, ids, amounts) | **retrieval / memory** | memorization-LoRA 0.05 vs retrieval 0.88 |
| Context SKILL (coreference, switch, temporal) | **training** *or* **memory rules** | context-LoRA 0.43→0.86; memory system 1.00 |

So: **train the skills into the weights, retrieve the facts at inference.** The two are
complementary, exactly as brief §34 asks. The inference-time memory system still leads on
multi-turn (1.00, and it also injects the correct facts), but the context-LoRA makes the *bare*
model far more capable when the scaffold is off or a phrasing slips past the rules — the robust
production stack is **context-LoRA + retrieval/memory** together.

## Files
```
tools/mlx/prep_context_data.py   build train/valid/context_holdout from the 100K splits
tools/mlx/context_eval.py        scaffold-OFF eval (base or --adapter)
data/paytm_mlx_ctx/              train/valid, context_holdout, adapters/best_ctx, ctxeval_*.json
```
```bash
./.venv-mlx/bin/python tools/mlx/prep_context_data.py
./.venv-mlx/bin/python tools/mlx/context_eval.py --tag base
./.venv-mlx/bin/python -m mlx_lm lora --model mlx-community/Llama-3.2-3B-Instruct-4bit \
  --train --data data/paytm_mlx_ctx --num-layers 16 --batch-size 4 --iters 200 \
  --learning-rate 1e-4 --mask-prompt --max-seq-length 448 \
  --adapter-path data/paytm_mlx_ctx/adapters --save-every 50 -c tools/mlx/lora_config.yaml
./.venv-mlx/bin/python tools/mlx/context_eval.py --tag ctx200 --adapter data/paytm_mlx_ctx/adapters
```
