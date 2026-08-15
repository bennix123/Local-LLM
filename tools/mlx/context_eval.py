#!/usr/bin/env python3
"""
Scaffold-OFF context eval: feed the raw dialogue history (facts live in earlier assistant
turns) and let the model answer the final follow-up. NO resolver / retriever / memory — this
isolates the model's NATIVE coreference/relational ability. Compares base vs context-LoRA.

  context_eval.py --tag base
  context_eval.py --tag ctx --adapter data/paytm_mlx_ctx/adapters
"""
import json, os, re, time, argparse
from collections import defaultdict
from mlx_lm import load, generate

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CTX = os.path.join(ROOT, "data", "paytm_mlx_ctx")
BASE = "mlx-community/Llama-3.2-3B-Instruct-4bit"

def matched(field, key, out):
    o = out.strip(); ol = o.lower()
    if field == "currency":
        return key in re.sub(r"[^0-9.]", "", out.replace(",", ""))
    if field == "txn_id":
        return key.lower() in ol
    if field == "name":
        return key.lower() in ol or key.split()[0].lower() in ol
    return key.lower() in ol

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True)
    ap.add_argument("--adapter", default=None)
    ap.add_argument("--max-tokens", type=int, default=40)
    args = ap.parse_args()

    items = [json.loads(l) for l in open(os.path.join(CTX, "context_holdout.jsonl"))]
    print(f"[{args.tag}] loading{' + '+args.adapter if args.adapter else ''}")
    model, tok = load(BASE, adapter_path=args.adapter) if args.adapter else load(BASE)

    res = []; gt = 0.0; gtok = 0
    for i, h in enumerate(items):
        prompt = tok.apply_chat_template(h["messages"], add_generation_prompt=True)
        t0 = time.time(); out = generate(model, tok, prompt=prompt, max_tokens=args.max_tokens, verbose=False)
        gt += time.time() - t0; gtok += len(tok.encode(out))
        ok = matched(h["field"], h["key"], out)
        res.append({"category": h["category"], "field": h["field"], "ok": ok,
                    "gold": h["gold"], "pred": out.strip()[:80]})
        if (i+1) % 60 == 0:
            print(f"  {i+1}/{len(items)} acc={sum(r['ok'] for r in res)/len(res):.3f}")

    def acc(rows): return round(sum(r["ok"] for r in rows)/len(rows), 4) if rows else None
    report = {"tag": args.tag, "adapter": args.adapter, "n": len(res),
              "overall_accuracy": acc(res),
              "by_category": {c: {"n": len([r for r in res if r["category"]==c]),
                                  "acc": acc([r for r in res if r["category"]==c])}
                              for c in sorted({r["category"] for r in res})},
              "by_field": {f: acc([r for r in res if r["field"]==f]) for f in sorted({r["field"] for r in res})},
              "tokens_per_sec": round(gtok/gt, 2), "avg_latency_s": round(gt/len(res), 3)}
    print(json.dumps(report, indent=2, ensure_ascii=False))
    out = os.path.join(CTX, f"ctxeval_{args.tag}.json")
    json.dump({"report": report, "results": res}, open(out, "w"), indent=2, ensure_ascii=False)
    print("wrote", out)

if __name__ == "__main__":
    main()
