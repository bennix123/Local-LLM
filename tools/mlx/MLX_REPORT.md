# Penny MLX — Training & Eval Report (Paytm statement)

**Source of truth:** `paytm.pdf` → `data/paytm_document.json` (417 txns, reconciled).
**Base model:** `mlx-community/Llama-3.2-3B-Instruct-4bit` (QLoRA). **Hardware:** Apple M4, 17 GB.
**Env:** `.venv-mlx` (mlx 0.32.0, mlx-lm 0.31.3). Reproduce with the commands at the bottom.

## Objective
Document **memorization**: teach the model every transaction's facts, then test recall with
**question phrasings the model never saw** (train/valid/holdout template pools are disjoint per
field, so the *facts* appear in training but the *exact eval questions* do not — a fair test).

## Data (`data/paytm_mlx/`)
- `train.jsonl` — 7,522 chat examples covering all 417 txns' fields + prev/next + pronoun + policy
- `valid.jsonl` — 243 (held-out phrasings, loss monitoring)
- `holdout_eval.jsonl` — 763 scoring items (719 atomic, 40 pronoun/context, 4 policy/aggregate)
- 0 holdout questions leak into train (verified).

## Training
LoRA rank 16, 16 layers, batch 8, lr 1e-4, `--mask-prompt`, max-seq 384, 400 iters.
Trainable params: 13.9M (0.43%). **Val loss 8.87 → 0.96**, train loss → 0.79. ~0.13 it/s on M4.
Checkpoints every 100 iters; eval loop keeps the best (`adapters/best`).

## Results — same held-out items (per-field 45)
Scoring is format-tolerant (currency matched on numeric core; names case-insensitive; ids exact).

| Approach | **atomic** (memorization) | amount | balance | counterparty | txn_id | pronoun (in-context) | overall | latency |
|---|---|---|---|---|---|---|---|---|
| Base, no context | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 | 0.70 | 0.125 | 1.03 s |
| **LoRA fine-tune** (iter400) | 0.05 | 0.13 | 0.00 | 0.07 | 0.00 | 0.40 | 0.112 | 0.84 s |
| **Retrieval** (base + fetched row) | **0.88** | 1.00 | 0.62 | 0.89 | 1.00 | 0.03¹ | 0.728 | 1.32 s |

LoRA fine-tune trajectory (overall / atomic): iter100 0.040/0.033 → 200 0.080/0.022 →
300 0.089/0.028 → **400 0.112/0.050** (best kept).
Retrieval recall@1 = **0.80** (caps its accuracy; a better retriever lifts the ceiling).

¹ The naive retriever keys only off the *last* user turn; pronoun follow-ups ("what was the
balance after **it**?") carry no identifying tokens there, so the wrong row is fetched.
Fix: conversation-aware retrieval (use the whole dialogue). This is the one clear retriever bug.

## Qualitative (real statement questions)
| Question | Gold | Base | LoRA | Retrieval |
|---|---|---|---|---|
| Balance after ₹2,000 to RAM BABU, 06 Jan 1:43 PM | ₹2,986.48 | *"I can't provide…"* (refuses) | ₹3,767.46 ✗ | ₹2,986.48 ✓ |
| Amount paid to DEVENDRA KUMAR PANDIT, 06 Jan | ₹10,000.00 | refuses | ₹10.00 ✗ | ₹10,000.00 ✓ |
| Annual interest rate | 2.5% | "no info" | 3.76% ✗ | 2.5% ✓ |

## Conclusion (honest)
1. **LoRA taught style + domain, not facts.** The base model *refuses* statement questions; after
   fine-tuning it answers in the right format and memorized a few high-frequency facts
   (atomic 0→5%, amount 0→13%) but **confidently hallucinates** exact balances/IDs. On the same
   items the base model's overall (0.125) even edges the tuned model (0.112) because in-context
   reading regressed (pronoun 0.70→0.40) — classic style-shift/forgetting.
2. **Retrieval wins decisively** — atomic **0.05 → 0.88** (~17×) just by placing the right row in
   context. Exact-value fields the LoRA never learned (amount, txn_id) hit **1.00**.
3. **Therefore the production path is retrieval-augmented** (the brief's §20–22 memory architecture),
   optionally with a light LoRA only to fix answer *style/format*. This is now backed by numbers,
   not assertion.

## Best checkpoint
`data/paytm_mlx/adapters/best/` (iter400) — best by the memorization objective. Note it does **not**
beat the base model on the blended `overall` metric; keep it for answer-style, not for fact recall.

## Files
```
tools/mlx/prep_data.py        build train/valid/holdout (disjoint phrasings)
tools/mlx/evaluate.py         held-out eval (accuracy + tok/s + latency), optional --adapter
tools/mlx/run_loop.py         eval every checkpoint, keep best, write summary
tools/mlx/retrieval_eval.py   retrieval-augmented eval (the recommended path)
tools/mlx/lora_config.yaml    LoRA rank/scale
data/paytm_mlx/               train/valid/holdout, adapters/, eval_*.json, eval_loop_summary.json
```

## Reproduce
```bash
uv venv --python 3.13 .venv-mlx && VIRTUAL_ENV=.venv-mlx uv pip install "mlx-lm>=0.20"
./.venv-mlx/bin/python tools/mlx/prep_data.py
./.venv-mlx/bin/python tools/mlx/evaluate.py --tag base
./.venv-mlx/bin/python -m mlx_lm lora --model mlx-community/Llama-3.2-3B-Instruct-4bit \
  --train --data data/paytm_mlx --num-layers 16 --batch-size 8 --iters 400 \
  --learning-rate 1e-4 --mask-prompt --max-seq-length 384 \
  --adapter-path data/paytm_mlx/adapters --save-every 100 -c tools/mlx/lora_config.yaml
./.venv-mlx/bin/python tools/mlx/run_loop.py          # eval checkpoints, keep best
./.venv-mlx/bin/python tools/mlx/retrieval_eval.py    # retrieval ceiling
```

## To push memorization higher (if staying parametric)
More iters (loss had plateaued, so expect small gains), higher LoRA rank, or a smaller model
trained to convergence. But the evidence says invest in **retrieval** instead.
