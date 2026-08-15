#!/usr/bin/env python3
"""
Evaluate a model (base or LoRA-adapted) on the held-out memorization set.

Scoring is format-tolerant: currency matches on the numeric core (ignores ₹/Rs/commas),
names match case-insensitively, ids/codes exact. Baseline and post-train runs use the SAME
deterministically-sampled items (seed) so the comparison is apples-to-apples.

Usage:
  evaluate.py --tag base
  evaluate.py --tag lora --adapter data/paytm_mlx/adapters
"""
import json, os, re, time, argparse, random
from collections import defaultdict
from mlx_lm import load, generate

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MLXDIR = os.path.join(ROOT, "data", "paytm_mlx")
BASE = "mlx-community/Llama-3.2-3B-Instruct-4bit"

CURRENCY_FIELDS = {"balance_after","amount","balance_after_pronoun","policy_closing","agg_credit"}

def norm_money(s):
    return s.replace(" ","").replace("₹","").replace("Rs.","").replace("Rs","")

def matched(field, gold, key, out):
    o = out.strip()
    ol = o.lower()
    if field in CURRENCY_FIELDS:
        raw = norm_money(o)
        plain = re.sub(r"[^0-9.]", "", key)           # 2986.48
        grouped = norm_money(key)                       # 2,986.48
        return grouped in raw or (plain and plain in re.sub(r"[^0-9.,]","",raw))
    if field == "counterparty":
        name = gold.rstrip(".").lower()
        return name in ol or (name.split() and name.split()[0] in ol)
    if field == "txn_id":
        return key.lower() in ol
    if field == "time":
        return key.lower() in ol.replace(" ", "")
    if field == "policy_interest":
        return "2.5%" in o
    return key.lower() in ol

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True)
    ap.add_argument("--adapter", default=None)
    ap.add_argument("--per-field", type=int, default=70, help="max atomic items per field")
    ap.add_argument("--max-tokens", type=int, default=48)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    holdout = [json.loads(l) for l in open(os.path.join(MLXDIR, "holdout_eval.jsonl"))]
    # deterministic stratified sample: same items every run (seeded shuffle per field)
    byf = defaultdict(list)
    for h in holdout: byf[h["field"]].append(h)
    items = []
    for f, rows in byf.items():
        rows = sorted(rows, key=lambda r: r["id"])
        random.Random(1000 + len(f)).shuffle(rows)
        items += rows[:args.per_field]
    items.sort(key=lambda r: (r["field"], r["id"]))

    print(f"[{args.tag}] loading model{' + adapter '+args.adapter if args.adapter else ''} ...")
    t0 = time.time()
    model, tok = load(BASE, adapter_path=args.adapter) if args.adapter else load(BASE)
    load_s = time.time() - t0

    results = []
    gen_tokens = 0; gen_time = 0.0
    for i, h in enumerate(items):
        prompt = tok.apply_chat_template(h["messages"], add_generation_prompt=True)
        t0 = time.time()
        out = generate(model, tok, prompt=prompt, max_tokens=args.max_tokens, verbose=False)
        dt = time.time() - t0
        ntok = len(tok.encode(out))
        gen_tokens += ntok; gen_time += dt
        ok = matched(h["field"], h["gold"], h["key"], out)
        results.append({"field": h["field"], "kind": h["kind"], "id": h["id"],
                        "gold": h["gold"], "pred": out.strip()[:120], "ok": ok})
        if (i+1) % 40 == 0:
            print(f"  {i+1}/{len(items)}  running acc={sum(r['ok'] for r in results)/len(results):.3f}")

    # aggregate
    def acc(rows): return round(sum(r["ok"] for r in rows)/len(rows), 4) if rows else None
    by_field = {}
    for f in sorted({r["field"] for r in results}):
        rows = [r for r in results if r["field"]==f]; by_field[f] = {"n":len(rows), "acc":acc(rows)}
    by_kind = {}
    for k in sorted({r["kind"] for r in results}):
        rows = [r for r in results if r["kind"]==k]; by_kind[k] = {"n":len(rows), "acc":acc(rows)}
    report = {
        "tag": args.tag, "adapter": args.adapter, "n": len(results),
        "overall_accuracy": acc(results),
        "by_field": by_field, "by_kind": by_kind,
        "tokens_per_sec": round(gen_tokens/gen_time, 2) if gen_time else None,
        "avg_latency_s": round(gen_time/len(results), 3),
        "load_s": round(load_s, 2),
    }
    print(json.dumps(report, indent=2, ensure_ascii=False))
    outp = args.out or os.path.join(MLXDIR, f"eval_{args.tag}.json")
    json.dump({"report": report, "results": results}, open(outp, "w"), indent=2, ensure_ascii=False)
    print("wrote", outp)

if __name__ == "__main__":
    main()
