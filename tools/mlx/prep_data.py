#!/usr/bin/env python3
"""
Prepare MLX fine-tuning data from data/paytm_document.json.

Objective = DOCUMENT MEMORIZATION: teach the model every transaction's facts, then test
recall with QUESTION PHRASINGS THE MODEL NEVER SAW. Phrasing templates are partitioned
into disjoint train / valid / holdout pools per field, so the eval facts appear in
training (via other wordings) but the exact eval questions do not — a fair memorization test.

Outputs (data/paytm_mlx/):
  train.jsonl        mlx-lm chat format: {"messages":[{role,content}...]}
  valid.jsonl        small monitoring set (held-out phrasings)
  holdout_eval.jsonl scoring set: {"messages":[...user...], "gold", "key", "field", "id"}
  meta.json
"""
import json, os, random
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
D = json.load(open(os.path.join(ROOT, "data", "paytm_document.json")))
TX = D["transactions"]; SUMM = D["account_summary"]; ACC = D["account"]
OUT = os.path.join(ROOT, "data", "paytm_mlx"); os.makedirs(OUT, exist_ok=True)
rng = random.Random(20230101)

def inr(x):
    neg = x < 0; x = abs(round(float(x), 2)); s = f"{x:.2f}"; ip, dec = s.split(".")
    if len(ip) > 3:
        last3 = ip[-3:]; rest = ip[:-3]; g = []
        while len(rest) > 2: g.insert(0, rest[-2:]); rest = rest[:-2]
        if rest: g.insert(0, rest)
        ip = ",".join(g) + "," + last3
    return ("-" if neg else "") + "₹" + ip + "." + dec

def prep_(t): return "from" if t["direction"] == "credit" else ("at" if t["type"].startswith("Paid using") else "to")
def verb_(t):
    if t["type"].startswith("Paid using"): return "paid"
    return "received" if t["direction"] == "credit" else "sent"
def party(t): return t.get("counterparty") or ("the sender" if t["direction"]=="credit" else "the payee")

def handle(t, exclude):
    """Natural id for a txn, omitting the asked field."""
    seg = []
    if "counterparty" not in exclude and t.get("counterparty"): seg.append(f"{prep_(t)} {t['counterparty']}")
    if "amount" not in exclude: seg.append(inr(t["amount"]))
    if "date" not in exclude: seg.append(f"on {t['date_raw']}")
    if "time" not in exclude and t.get("time"): seg.append(f"at {t['time']}")
    return "the transaction " + " ".join(seg) if seg else f"transaction {t['transaction_id']}"

# ---- per-field question templates, partitioned by pool -----------------------
# each field: dict pool -> list of (question_fn). train uses 'tr', valid 'va', holdout 'ho'
def T(fn): return fn
FIELDS = {
 "balance_after": {
   "gold": lambda t: inr(t["available_balance"]),
   "key":  lambda t: inr(t["available_balance"]),
   "tr": [lambda t: f"What was the account balance right after {handle(t,['amount'] if False else [])}?",
          lambda t: f"After {handle(t,[])}, what did the balance become?",
          lambda t: f"What was the available balance following {handle(t,[])}?"],
   "va": [lambda t: f"Following {handle(t,[])}, what was the running balance?"],
   "ho": [lambda t: f"State the running balance immediately after {handle(t,[])}."],
 },
 "amount": {
   "gold": lambda t: inr(t["amount"]),
   "key":  lambda t: inr(t["amount"]),
   "tr": [lambda t: f"How much was {handle(t,['amount'])}?",
          lambda t: f"What was the amount of {handle(t,['amount'])}?",
          lambda t: f"What sum was {handle(t,['amount'])}?"],
   "va": [lambda t: f"What value did {handle(t,['amount'])} carry?"],
   "ho": [lambda t: f"Give the exact amount of {handle(t,['amount'])}."],
 },
 "counterparty": {
   "gold": lambda t: t.get("counterparty") or "",
   "key":  lambda t: (t.get("counterparty") or "").split()[0] if t.get("counterparty") else "",
   "tr": [lambda t: f"Who was {handle(t,['counterparty'])} {'from' if t['direction']=='credit' else 'to'}?",
          lambda t: f"Name the {'sender' if t['direction']=='credit' else 'recipient'} of {handle(t,['counterparty'])}.",
          lambda t: f"Which party was on {handle(t,['counterparty'])}?"],
   "va": [lambda t: f"Who did {handle(t,['counterparty'])} involve?"],
   "ho": [lambda t: f"Identify the {'payer' if t['direction']=='credit' else 'payee'} of {handle(t,['counterparty'])}."],
 },
 "time": {
   "gold": lambda t: t.get("time") or "",
   "key":  lambda t: (t.get("time") or "").replace(" ", ""),
   "tr": [lambda t: f"At what time did {handle(t,['time'])} happen?",
          lambda t: f"What time was {handle(t,['time'])}?",
          lambda t: f"When during the day did {handle(t,['time'])} occur?"],
   "va": [lambda t: f"What clock time is on {handle(t,['time'])}?"],
   "ho": [lambda t: f"Give the time of day for {handle(t,['time'])}."],
 },
 "txn_id": {
   "gold": lambda t: t["transaction_id"],
   "key":  lambda t: t["transaction_id"],
   "tr": [lambda t: f"What is the transaction ID of {handle(t,[])}?",
          lambda t: f"Give the transaction ID for {handle(t,[])}.",
          lambda t: f"Which transaction ID belongs to {handle(t,[])}?"],
   "va": [lambda t: f"State the txn ID of {handle(t,[])}."],
   "ho": [lambda t: f"What transaction identifier was assigned to {handle(t,[])}?"],
 },
}

def msg(u, a): return {"messages": [{"role":"user","content":u},{"role":"assistant","content":a}]}

def answer(field, t):
    if field == "balance_after": return f"{inr(t['available_balance'])}."
    if field == "amount": return f"{inr(t['amount'])} ({'credit' if t['direction']=='credit' else 'debit'})."
    if field == "counterparty": return f"{t['counterparty']}."
    if field == "time": return f"{t['time']} on {t['date_raw']}."
    if field == "txn_id": return f"{t['transaction_id']}."

train, valid, holdout = [], [], []

# choose a random subset of txns for holdout questions (facts still trained via other wordings)
ho_txns = set(rng.sample([t["transaction_id"] for t in TX], k=180))

for t in TX:
    for field, spec in FIELDS.items():
        gold = spec["gold"](t)
        if not gold:  # field absent for this txn
            continue
        a = answer(field, t)
        # TRAIN: all train templates
        for qfn in spec["tr"]:
            train.append(msg(qfn(t), a))
        # VALID: a slice
        if rng.random() < 0.12:
            valid.append(msg(spec["va"][0](t), a))
        # HOLDOUT: only for selected txns, only balance/amount/counterparty/txn_id/time
        if t["transaction_id"] in ho_txns and field in ("balance_after","amount","counterparty","txn_id"):
            holdout.append({"messages":[{"role":"user","content":spec["ho"][0](t)}],
                            "gold": a, "key": spec["key"](t), "field": field,
                            "id": t["transaction_id"], "kind":"atomic"})

# ---- context/multi-turn teaching examples (prev/next, pronoun) ----------------
N = len(TX)
def one_line(t):
    cp = t.get("counterparty"); base=f"{verb_(t)} {inr(t['amount'])}"
    if cp: base += f" {prep_(t)} {cp}"
    base += f" on {t['date_raw']}"
    if t.get("time"): base += f" at {t['time']}"
    return f"You {base} ({t['type']}). Balance afterwards: {inr(t['available_balance'])}."
for i, t in enumerate(TX):
    prevt = TX[i-1] if i>0 else None
    nextt = TX[i+1] if i+1<N else None
    # pronoun follow-up teaching
    conv = [{"role":"user","content":f"Tell me about {handle(t,[])}."},
            {"role":"assistant","content":one_line(t)},
            {"role":"user","content":"What was the balance after it?"},
            {"role":"assistant","content":f"{inr(t['available_balance'])}."}]
    if t.get("counterparty"):
        conv += [{"role":"user","content":"Who was it "+("from" if t['direction']=='credit' else "to")+"?"},
                 {"role":"assistant","content":f"{t['counterparty']}."}]
    train.append({"messages":conv})
    if prevt:
        train.append(msg(f"What transaction came immediately before {handle(t,[])}?", one_line(prevt)))
    if nextt:
        train.append(msg(f"What transaction came immediately after {handle(t,[])}?", one_line(nextt)))

# holdout: a few multi-turn/pronoun items (context recall)
for tid in list(ho_txns)[:40]:
    t = next(x for x in TX if x["transaction_id"]==tid)
    holdout.append({"messages":[
        {"role":"user","content":f"Consider {handle(t,[])}."},
        {"role":"assistant","content":one_line(t)},
        {"role":"user","content":"Remind me — what was the balance right after it?"}],
        "gold": f"{inr(t['available_balance'])}.", "key": inr(t["available_balance"]),
        "field":"balance_after_pronoun","id":tid,"kind":"pronoun"})

# ---- account / policy / aggregate teaching + holdout -------------------------
credits=[t for t in TX if t["direction"]=="credit"]; debits=[t for t in TX if t["direction"]=="debit"]
TOTc=round(sum(t["amount"] for t in credits),2); TOTd=round(sum(t["amount"] for t in debits),2)
policy_pairs = [
 ("What is the interest rate on this savings account?", f"{ACC['interest_rate']} per annum."),
 ("What was the closing balance of the statement?", f"{inr(SUMM['closing_balance'])}."),
 ("What was the opening balance of the statement?", f"{inr(SUMM['opening_balance'])}."),
 ("What is the account's IFSC code?", f"{ACC['ifsc']}."),
 ("Who holds this account?", f"{ACC['account_holder']}."),
 ("What was the total money received (credits) in the statement?", f"{inr(TOTc)}."),
 ("What was the total money paid out (debits) in the statement?", f"{inr(TOTd)}."),
 ("How many transactions are in the statement in total?", f"{N} transactions."),
 ("What period does the statement cover?", f"{ACC['statement_period']['from']} to {ACC['statement_period']['to']}."),
]
for q,a in policy_pairs:
    for _ in range(3): train.append(msg(q,a))  # repeat salient facts
holdout += [
 {"messages":[{"role":"user","content":"State the annual interest rate applied to this account."}],
  "gold": f"{ACC['interest_rate']}.", "key": ACC['interest_rate'], "field":"policy_interest","id":"policy","kind":"policy"},
 {"messages":[{"role":"user","content":"What figure did the account close the period at?"}],
  "gold": f"{inr(SUMM['closing_balance'])}.", "key": inr(SUMM['closing_balance']), "field":"policy_closing","id":"policy","kind":"policy"},
 {"messages":[{"role":"user","content":"Across the whole statement, how much money came in?"}],
  "gold": f"{inr(TOTc)}.", "key": inr(TOTc), "field":"agg_credit","id":"agg","kind":"aggregate"},
 {"messages":[{"role":"user","content":"What is the account's IFSC?"}],
  "gold": f"{ACC['ifsc']}.", "key": ACC['ifsc'], "field":"policy_ifsc","id":"policy","kind":"policy"},
]

rng.shuffle(train)
def w(path, rows):
    with open(path,"w") as f:
        for r in rows: f.write(json.dumps(r, ensure_ascii=False)+"\n")
w(os.path.join(OUT,"train.jsonl"), train)
w(os.path.join(OUT,"valid.jsonl"), valid if valid else train[:200])
w(os.path.join(OUT,"holdout_eval.jsonl"), holdout)
meta = {"train":len(train), "valid":len(valid), "holdout":len(holdout),
        "holdout_txns":len(ho_txns), "note":"holdout phrasings are disjoint from train"}
json.dump(meta, open(os.path.join(OUT,"meta.json"),"w"), indent=2)
print(json.dumps(meta, indent=2))
from collections import Counter
print("holdout by kind:", dict(Counter(h["kind"] for h in holdout)))
print("holdout by field:", dict(Counter(h["field"] for h in holdout)))
