#!/usr/bin/env python3
"""
Retrieval-augmented eval on the SAME held-out set — quantifies the accuracy ceiling when
the relevant statement row is placed in context (the brief's §20-22 memory/retrieval path),
versus parametric LoRA memorization. Uses the BASE model (no adapter); a simple keyword
retriever selects the top-1 transaction, and account-level facts are always injected.

Reports: retrieval recall@1 (did we fetch the right row) and answer accuracy.
"""
import json, os, re, time, random
from collections import defaultdict
from mlx_lm import load, generate

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MLXDIR = os.path.join(ROOT, "data", "paytm_mlx")
D = json.load(open(os.path.join(ROOT, "data", "paytm_document.json")))
TX = D["transactions"]; SUMM = D["account_summary"]; ACC = D["account"]
BASE = "mlx-community/Llama-3.2-3B-Instruct-4bit"

def inr(x):
    neg=x<0; x=abs(round(float(x),2)); s=f"{x:.2f}"; ip,dec=s.split(".")
    if len(ip)>3:
        last3=ip[-3:]; rest=ip[:-3]; g=[]
        while len(rest)>2: g.insert(0,rest[-2:]); rest=rest[:-2]
        if rest: g.insert(0,rest)
        ip=",".join(g)+","+last3
    return ("-" if neg else "")+"₹"+ip+"."+dec

CURRENCY_FIELDS={"balance_after","amount","balance_after_pronoun","policy_closing","agg_credit"}
def norm_money(s): return s.replace(" ","").replace("₹","").replace("Rs.","").replace("Rs","")
def matched(field,gold,key,out):
    o=out.strip(); ol=o.lower()
    if field in CURRENCY_FIELDS:
        raw=norm_money(o); plain=re.sub(r"[^0-9.]","",key); grouped=norm_money(key)
        return grouped in raw or (plain and plain in re.sub(r"[^0-9.,]","",raw))
    if field=="counterparty":
        name=gold.rstrip(".").lower(); return name in ol or (name.split() and name.split()[0] in ol)
    if field=="txn_id": return key.lower() in ol
    if field=="time": return key.lower() in ol.replace(" ","")
    if field=="policy_interest": return "2.5%" in o
    return key.lower() in ol

# ---- retriever: token overlap on identifying fields ----
def tx_tokens(t):
    toks=set()
    if t.get("counterparty"): toks|={w.lower() for w in t["counterparty"].split()}
    toks|={norm_money(inr(t["amount"])), norm_money(inr(t["available_balance"]))}
    toks|={w.lower() for w in t["date_raw"].split()}
    if t.get("time"): toks.add(t["time"].lower().replace(" ",""))
    toks.add(t["transaction_id"].lower())
    return toks
TXTOK=[(t, tx_tokens(t)) for t in TX]
def retrieve(q):
    qn=q.lower(); qm=norm_money(qn)
    best=None; bs=-1
    for t,toks in TXTOK:
        s=sum(1 for tk in toks if tk in qn or tk in qm)
        if s>bs: bs=s; best=t
    return best

credits=[t for t in TX if t["direction"]=="credit"]; debits=[t for t in TX if t["direction"]=="debit"]
TOTc=round(sum(t["amount"] for t in credits),2); TOTd=round(sum(t["amount"] for t in debits),2)
def acct_block():
    return (f"Account facts: holder {ACC['account_holder']}; IFSC {ACC['ifsc']}; interest {ACC['interest_rate']} p.a.; "
            f"period {ACC['statement_period']['from']} to {ACC['statement_period']['to']}; "
            f"opening {inr(SUMM['opening_balance'])}; closing {inr(SUMM['closing_balance'])}; "
            f"total received {inr(TOTc)}; total paid out {inr(TOTd)}; {len(TX)} transactions.")
def tx_block(t):
    return ("Relevant statement entry:\n"
            f"- Date/time: {t['date_raw']} {t.get('time','')}\n- Type: {t['type']}\n"
            f"- Counterparty: {t.get('counterparty','-')}\n- Amount: {inr(t['amount'])} ({t['direction']})\n"
            f"- Balance after: {inr(t['available_balance'])}\n- Transaction ID: {t['transaction_id']}")

def main():
    holdout=[json.loads(l) for l in open(os.path.join(MLXDIR,"holdout_eval.jsonl"))]
    byf=defaultdict(list)
    for h in holdout: byf[h["field"]].append(h)
    items=[]
    for f,rows in byf.items():
        rows=sorted(rows,key=lambda r:r["id"]); random.Random(1000+len(f)).shuffle(rows); items+=rows[:45]
    model,tok=load(BASE)
    results=[]; rec_hits=0; rec_n=0; gt=0.0; gtok=0
    for i,h in enumerate(items):
        uq=[m["content"] for m in h["messages"] if m["role"]=="user"][-1]
        t=retrieve(uq)
        if h["id"] in {x["transaction_id"] for x in TX}:
            rec_n+=1; rec_hits+= (t and t["transaction_id"]==h["id"])
        ctx=acct_block()+"\n"+(tx_block(t) if t else "")
        msgs=[{"role":"system","content":"Answer ONLY from the statement facts provided. Be exact and concise."},
              {"role":"user","content":ctx+"\n\nQuestion: "+uq}]
        prompt=tok.apply_chat_template(msgs,add_generation_prompt=True)
        t0=time.time(); out=generate(model,tok,prompt=prompt,max_tokens=48,verbose=False); gt+=time.time()-t0
        gtok+=len(tok.encode(out))
        ok=matched(h["field"],h["gold"],h["key"],out)
        results.append({"field":h["field"],"kind":h["kind"],"ok":ok})
        if (i+1)%40==0: print(f"  {i+1}/{len(items)} acc={sum(r['ok'] for r in results)/len(results):.3f}")
    def acc(rows): return round(sum(r["ok"] for r in rows)/len(rows),4) if rows else None
    rep={"tag":"retrieval","n":len(results),"overall_accuracy":acc(results),
         "retrieval_recall_at_1":round(rec_hits/rec_n,4) if rec_n else None,
         "by_field":{f:acc([r for r in results if r["field"]==f]) for f in sorted({r["field"] for r in results})},
         "by_kind":{k:acc([r for r in results if r["kind"]==k]) for k in sorted({r["kind"] for r in results})},
         "tokens_per_sec":round(gtok/gt,2),"avg_latency_s":round(gt/len(results),3)}
    print(json.dumps(rep,indent=2,ensure_ascii=False))
    json.dump(rep,open(os.path.join(MLXDIR,"eval_retrieval.json"),"w"),indent=2,ensure_ascii=False)

if __name__=="__main__": main()
