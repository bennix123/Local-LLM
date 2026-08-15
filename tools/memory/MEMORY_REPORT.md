# Penny MLX — Conversation-Aware Retriever + Entity Memory (brief §20–22)

Built to fix the exact failure the training phase exposed: retrieval works (atomic 0.88) but a
retriever keyed only on the *last* user turn collapses on follow-ups ("what was the balance after
**it**?" → 0.025) because pronouns/relations carry no searchable tokens. This system tracks entities
across the dialogue and resolves references to concrete transactions *before* retrieving.

## Architecture
```
user turn
  → ReferenceResolver   resolve pronouns / relational / superlative / ordinal / switch / reset
                        against EntityMemory  → a concrete transaction (or policy/aggregate/temporal intent)
  → Retriever           assemble grounded context: the resolved FOCUS entry + account facts
                        (or computed aggregates / a day's entries)
  → PennyAgent.generate LLM answers ONLY from context; identify-questions describe the focus;
                        a GROUNDING GUARD replaces any wrong exact field with the resolved value
  → EntityMemory.update store active/previous/history/current_date/current_merchant (validated:
                        only real document entities are ever stored — brief §21)
```

## Components (`tools/memory/penny_memory.py`)
- **Document** — loads `paytm_document.json`; lookup by id/date/counterparty/type; superlatives;
  neighbours; token retriever; renders grounded context blocks.
- **EntityMemory** — `active`, `previous`, `history` (first-mention order), `current_date`,
  `current_merchant`, summary. Supports "the first one we discussed", context switch/return.
- **ReferenceResolver** (deterministic, grounded) resolves, in priority order:
  reset → switch-back → explicit descriptor → superlative → previous/next → ordinal-of-day →
  policy → aggregate → temporal(day) → pronoun/implicit-follow-up→active → ambiguity → fallback search.
  A date alone is **not** a unique descriptor; pronouns with no active entity → ask to clarify.
- **Retriever** — focus-only context (no competing neighbour balances), or day list / aggregates.
- **PennyAgent** — orchestrates; question-rewriting (drops navigational preamble; describes focus
  for identify-questions) + grounding guard for exact fields.

## Eval — naive retriever vs conversation-aware memory
162 grounded multi-turn conversations across 8 resolution types; same base model
(`Llama-3.2-3B-Instruct-4bit`), only the memory/retrieval layer differs.
- **resolution accuracy** — did the resolver pin the correct transaction on the final turn?
- **answer accuracy** — does the generated answer contain the gold value?

| Resolution type | naive answer | **memory answer** | memory resolution |
|---|--:|--:|--:|
| pronoun ("…after **it**?") | 0.00 | **1.00** | 1.00 |
| previous | 0.00 | **1.00** | 1.00 |
| next | 0.00 | **1.00** | 1.00 |
| largest (debit/credit) | 0.00 | **1.00** | 1.00 |
| ordinal-of-day | 0.11 | **1.00** | 1.00 |
| context switch (back to first) | 0.00 | **1.00** | 1.00 |
| switch through policy & return | 0.00 | **1.00** | 1.00 |
| reset → ambiguous (must clarify) | 0.00 | **1.00** | — |
| **overall** | **0.012** | **1.000** | **1.000** |

The naive retriever's 1.2% is the same pathology measured earlier (holdout pronoun 0.025).

## The full arc (same task, three approaches)
| Approach | atomic fact recall | multi-turn / pronoun |
|---|--:|--:|
| Base model, no context | 0.00 (refuses) | 0.70* |
| LoRA fine-tune (parametric) | 0.05 (hallucinates values) | 0.40 |
| Retrieval (last-turn only) | 0.88 | 0.02 |
| **Conversation-aware memory** | **~0.88 (retrieval ceiling)** | **1.00** |

\*base pronoun is high only because the fact sat in the prompt already.

## Demo (real, `chat.py --demo`)
```
You:   What was the largest transaction?           Penny: …IMPS credit from Razorpay Composite 2 for ₹14,758.00 … balance ₹14,986.48
You:   Who was it from?                             Penny: Razorpay Composite 2
You:   What was the balance right after it?         Penny: ₹14,986.48
You:   What was the transaction before it?          Penny: …UPI debit ₹50.00 to NANCY SINGH … balance ₹228.48
You:   How much was that one?                       Penny: ₹50.00
You:   Go back to the first transaction we          Penny: Its transaction ID is M1899192   ← grounding guard fixed an LLM typo
       discussed — what was its transaction ID?
You:   By the way, what's the interest rate?        Penny: 2.5% per annum
You:   And the closing balance?                     Penny: ₹157.65                 ← focus preserved across the policy detour
You:   Forget all that. What was the amount of      Penny: Which transaction do you mean? … (asks to clarify)
       that transaction?
```
Every pronoun/relational reference resolved to the correct entity; the policy detour didn't lose
focus; and after a reset the model correctly refuses to guess.

## Files & how to run
```
tools/memory/penny_memory.py   the system (importable; LLM lazy-loaded)
tools/memory/eval_memory.py    naive vs memory comparison  -> data/paytm_mlx/eval_memory.json
tools/memory/chat.py           interactive REPL  (--demo scripted, --trace shows resolver+state)
```
```bash
../../.venv-mlx/bin/python eval_memory.py     # reproduce the table
../../.venv-mlx/bin/python chat.py --trace     # chat; /state, /reset, /quit
```

## Full stack — context-LoRA + memory (combined)
`PennyAgent(adapter_path=…)` / `chat.py` now load the **context-LoRA** on top of the memory
system (default; `--base` for the plain model). Design after honest tuning:
- **Deterministic templating** for what memory already knows exactly — *describe* (focus one-liner)
  and *temporal* (day summary). The context-LoRA is terse and flubs these open-ended answers
  (e.g. "When did it happen?" → "₹14,758.00"), so they must not depend on the LLM.
- **LLM (context-LoRA) + grounding guard** for exact-field questions; **LLM** for policy/aggregate/
  fallback — where the context-LoRA's trained context skill helps when the rules fall back to raw text.

Combined-stack eval (162 conversations): **answer 1.00, resolution 1.00** — identical to memory+base,
i.e. no regression. On this scaffolded eval the memory layer already saturates accuracy; the
context-LoRA's measured, distinct benefit is **scaffold-OFF robustness** (native context 0.43 → 0.86,
see `tools/mlx/CONTEXT_TRAINING_REPORT.md`) for phrasings the deterministic rules miss.

Net: **skills in the weights (context-LoRA) + facts at inference (memory/retrieval)** — run together
in `chat.py`. Demo: `../../.venv-mlx/bin/python chat.py --demo` (or `--trace`, `--base`).

## Honest limitations
- **Retriever is keyword/token-based.** It nails these questions (descriptors carry merchant/amount/
  date tokens) but a semantic/embedding retriever would help paraphrased or fuzzy queries.
- **Temporal "what happened on <date>"** returns an LLM summary that may not enumerate every entry;
  the full day is in context — template it if exhaustive listing is required.
- **Resolver is rule-based** (fast, deterministic, debuggable). Rare phrasings fall back to search;
  extend the rule sets as needed. Comparisons of two entities are minimal (single-focus model).
- **The grounding guard** only corrects exact fields it can identify (amount/balance/id/time/
  counterparty/reference/vpa/bank); free-form answers rely on the focus-only context.
