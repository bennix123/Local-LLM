#!/usr/bin/env python3
"""
Compare the NAIVE retriever (keys only off the last user turn, no memory) against the
CONVERSATION-AWARE memory system, on grounded multi-turn conversations that require pronoun /
relational / superlative / ordinal / switch / reset resolution.

Metrics:
  - resolution accuracy (memory): did the resolver pin the correct transaction on the final turn?
  - answer accuracy (both): does the generated answer contain the gold value?
Both use the SAME base model; only the retrieval/memory layer differs.
"""
import json, os, re, time, random
from collections import defaultdict
from penny_memory import PennyAgent, Document, inr, norm_money, BASE_MODEL

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "data", "paytm_mlx", "eval_memory.json")

# ---- scoring (same tolerance as the MLX eval) ----
def matched(field, gold, key, out):
    o = out.strip(); ol = o.lower()
    if field in ("amount", "balance"):
        raw = norm_money(o); plain = re.sub(r"[^0-9.]", "", key)
        return norm_money(key) in raw or (plain and plain in re.sub(r"[^0-9.,]", "", raw))
    if field == "counterparty":
        name = gold.rstrip(".").lower(); return name in ol or (name.split() and name.split()[0] in ol)
    if field == "txn_id":
        return key.lower() in ol
    return key.lower() in ol

def desc(t):  # a natural, resolvable descriptor for the opening turn
    s = f"the {inr(t['amount'])} transaction"
    if t.get("counterparty"): s += f" {'from' if t['direction']=='credit' else 'to'} {t['counterparty']}"
    s += f" on {t['date_raw']}"
    if t.get("time"): s += f" at {t['time']}"
    return s

# ---- build grounded multi-turn eval conversations ----
def build(doc, per_kind=18):
    rng = random.Random(3)
    tx = doc.tx; N = len(tx)
    multi_day_dates = [d for d in doc.dates if len(doc.by_date[d]) >= 4]
    convos = []
    def add(kind, turns, gold, key, field, gold_txn):
        convos.append({"kind": kind, "turns": turns, "gold": gold, "key": key,
                       "field": field, "gold_txn": gold_txn})

    pool = [t for t in tx if t["index"] > 2 and t["index"] < N-1 and t.get("counterparty")]
    for t in rng.sample(pool, min(per_kind, len(pool))):
        prev = doc.at(t["index"]-1); nxt = doc.at(t["index"]+1)
        # 1 pronoun -> balance after it
        add("pronoun", [f"Tell me about {desc(t)}.", "What was the balance after it?"],
            inr(t["available_balance"]), inr(t["available_balance"]), "balance", t["transaction_id"])
        # 2 previous
        add("previous", [f"Tell me about {desc(t)}.", "What was the transaction before it?", "How much was that one?"],
            inr(prev["amount"]), inr(prev["amount"]), "amount", prev["transaction_id"])
        # 3 next
        add("next", [f"Tell me about {desc(t)}.", "And the one after it?", "What was its balance after?"],
            inr(nxt["available_balance"]), inr(nxt["available_balance"]), "balance", nxt["transaction_id"])
        # 4 switch back to first discussed (through a second entity)
        t2 = doc.at(t["index"]+2)
        add("switch", [f"Tell me about {desc(t)}.", f"Now tell me about {desc(t2)}.",
                       "Go back to the first transaction we discussed. What was its balance after?"],
            inr(t["available_balance"]), inr(t["available_balance"]), "balance", t["transaction_id"])
        # 5 context-switch to policy then return
        add("switch_policy", [f"Tell me about {desc(t)}.", "By the way, what's the interest rate?",
                              "Back to that transaction — what was its transaction ID?"],
            t["transaction_id"], t["transaction_id"], "txn_id", t["transaction_id"])
        # 6 reset -> ambiguous (expect clarification)
        add("reset_ambiguous", [f"How much was {desc(t)}?", "Forget that.", "What was the amount of that transaction?"],
            "CLARIFY", "CLARIFY", "clarify", None)

    ld = doc.largest("debit"); lc = doc.largest("credit")
    for _ in range(per_kind):
        add("largest", ["What was the largest debit?", "What was the balance after it?"],
            inr(ld["available_balance"]), inr(ld["available_balance"]), "balance", ld["transaction_id"])
        add("largest", ["What was the largest credit received?", "Who was it from?"],
            lc.get("counterparty",""), lc.get("counterparty","") or "x", "counterparty", lc["transaction_id"])
    for d in rng.sample(multi_day_dates, min(per_kind, len(multi_day_dates))):
        day = doc.by_date[d]; dr = day[0]["date_raw"]
        add("ordinal_day", [f"What happened on {dr}?", f"What was the third transaction on {dr}?", "How much was it?"],
            inr(day[2]["amount"]), inr(day[2]["amount"]), "amount", day[2]["transaction_id"])
    return convos

def render_ctx(doc, t):
    return doc.account_facts() + "\n" + doc.render_txn(t)

def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--adapter", default=None, help="LoRA adapter dir (e.g. the context-LoRA) -> combined stack")
    args = ap.parse_args()
    doc = Document()
    convos = build(doc)
    print(f"built {len(convos)} eval conversations across "
          f"{len(set(c['kind'] for c in convos))} resolution types"
          + (f" | adapter={args.adapter}" if args.adapter else " | base model"))
    from mlx_lm import load, generate
    model, tok = load(BASE_MODEL, adapter_path=args.adapter) if args.adapter else load(BASE_MODEL)
    SYS = ("You are Penny, a precise assistant for a bank statement. Answer ONLY using the "
           "statement facts provided. Be concise and exact.")

    def llm(context, question, mt=40):
        msgs = [{"role":"system","content":SYS}, {"role":"user","content":context+"\n\nQuestion: "+question}]
        return generate(model, tok, prompt=tok.apply_chat_template(msgs, add_generation_prompt=True),
                        max_tokens=mt, verbose=False).strip()

    naive = defaultdict(lambda: [0,0]); mem = defaultdict(lambda: [0,0]); res_ok = defaultdict(lambda:[0,0])
    t0 = time.time()
    for i, c in enumerate(convos):
        last = c["turns"][-1]; clar = c["field"] == "clarify"
        # ---- NAIVE: last turn only, top-1 search, no memory ----
        if clar:
            # naive has no notion of ambiguity -> it will answer something (counts as wrong)
            hit = doc.search(last, k=1)
            ans_n = llm(render_ctx(doc, hit[0]) if hit else doc.account_facts(), last)
            ok_n = False
        else:
            hit = doc.search(last, k=1)
            ctx = render_ctx(doc, hit[0]) if hit else doc.account_facts()
            ans_n = llm(ctx, last)
            ok_n = matched(c["field"], c["gold"], c["key"], ans_n)
        naive[c["kind"]][0] += ok_n; naive[c["kind"]][1] += 1

        # ---- MEMORY: replay all turns (setup resolution-only, final with LLM) ----
        ag = PennyAgent(doc=doc, use_llm=False, model=model, tok=tok)
        for u in c["turns"][:-1]:
            ag.ask(u)
        ag.use_llm = True
        r = ag.ask(last, max_tokens=40)
        # resolution correctness
        if c["gold_txn"] is not None:
            res_ok[c["kind"]][0] += (r.get("target") == c["gold_txn"]); res_ok[c["kind"]][1] += 1
        if clar:
            ok_m = bool(r.get("clarify"))
        else:
            ok_m = matched(c["field"], c["gold"], c["key"], r["answer"])
        mem[c["kind"]][0] += ok_m; mem[c["kind"]][1] += 1
        if (i+1) % 30 == 0:
            print(f"  {i+1}/{len(convos)}  elapsed {time.time()-t0:.0f}s")

    def tot(d):
        a = sum(v[0] for v in d.values()); n = sum(v[1] for v in d.values()); return round(a/n,4), n
    report = {"n": len(convos),
              "naive_answer_acc": tot(naive)[0], "memory_answer_acc": tot(mem)[0],
              "memory_resolution_acc": tot(res_ok)[0],
              "by_kind": {k: {"naive": round(naive[k][0]/naive[k][1],3),
                              "memory": round(mem[k][0]/mem[k][1],3),
                              "resolution": (round(res_ok[k][0]/res_ok[k][1],3) if res_ok[k][1] else None),
                              "n": mem[k][1]} for k in sorted(mem)}}
    report["adapter"] = args.adapter
    print(json.dumps(report, indent=2, ensure_ascii=False))
    out = OUT.replace(".json", "_combined.json") if args.adapter else OUT
    json.dump(report, open(out, "w"), indent=2, ensure_ascii=False)
    print("wrote", out)

if __name__ == "__main__":
    main()
