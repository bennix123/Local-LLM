#!/usr/bin/env python3
"""
Build CONTEXT-TRAINING data from the 100K dataset (brief §5-19, §34 training half).

Trains the model's NATIVE ability to answer follow-ups from dialogue history — the facts live
in earlier assistant turns, so this tests coreference/relational reasoning, NOT memorization.

Splits come from the 100K dataset's own group_id split (no transaction leakage):
  train_ctx.jsonl / valid_ctx.jsonl  -> mlx chat format {"messages":[...]}
  context_holdout.jsonl              -> {"messages": history-ending-in-user, gold, key, field, category}
                                        (TEST split; final answer is atomic so it scores cleanly)
"""
import json, os, re, random
from collections import defaultdict, Counter

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "data", "paytm_qa", "penny_100k_context.jsonl")
OUT = os.path.join(ROOT, "data", "paytm_mlx_ctx"); os.makedirs(OUT, exist_ok=True)
rng = random.Random(2023)

CTX_CATS = {"multi_turn", "reference_resolution", "temporal_reasoning", "context_resolution"}
MAX_MSGS = 16                      # cap dialogue length to bound sequence length
CUR = re.compile(r"-?₹[\d,]+\.\d{2}")
TID = re.compile(r"\b([SM]\d{4,})\b")

def gold_key(ans):
    """Extract an atomic, cleanly-scorable target from a gold assistant answer."""
    m = CUR.search(ans)
    if m: return ("currency", re.sub(r"[^0-9.]", "", m.group(0)))
    m = TID.search(ans)
    if m: return ("txn_id", m.group(1))
    s = ans.strip().rstrip(".")
    if 0 < len(s) <= 24 and s.isupper():        # a short ALL-CAPS name
        return ("name", s)
    return (None, None)

train, valid = [], []
holdout = []
seen_ctx = Counter()

for line in open(SRC):
    r = json.loads(line)
    if r["category"] not in CTX_CATS:
        continue
    conv = r["conversation"]
    if len(conv) < 4 or len(conv) > MAX_MSGS:    # need >=2 turns; cap length
        continue
    if conv[-1]["role"] != "assistant":
        continue
    split = r["split"]
    if split in ("train", "validation") and not r.get("augmented"):
        row = {"messages": conv}
        (train if split == "train" else valid).append(row)
    elif split == "test" and not r.get("augmented"):
        field, key = gold_key(conv[-1]["content"])
        if field is None:
            continue
        # history ends with the final USER turn; model must produce the final assistant answer
        holdout.append({"messages": conv[:-1], "gold": conv[-1]["content"],
                        "key": key, "field": field, "category": r["category"]})

rng.shuffle(train); rng.shuffle(valid); rng.shuffle(holdout)
train = train[:10000]
valid = valid[:300]
# balance holdout across categories, ~220 total
by_cat = defaultdict(list)
for h in holdout: by_cat[h["category"]].append(h)
bal = []
for c, rows in by_cat.items(): bal += rows[:70]
rng.shuffle(bal); holdout = bal[:240]

def w(p, rows):
    with open(p, "w") as f:
        for r in rows: f.write(json.dumps(r, ensure_ascii=False) + "\n")
w(os.path.join(OUT, "train.jsonl"), train)
w(os.path.join(OUT, "valid.jsonl"), valid)
w(os.path.join(OUT, "context_holdout.jsonl"), holdout)

meta = {"train": len(train), "valid": len(valid), "holdout": len(holdout),
        "avg_turns_train": round(sum(len(r["messages"]) for r in train)/len(train)/2, 1),
        "holdout_by_category": dict(Counter(h["category"] for h in holdout)),
        "holdout_by_field": dict(Counter(h["field"] for h in holdout))}
print(json.dumps(meta, indent=2))
