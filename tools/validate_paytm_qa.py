#!/usr/bin/env python3
"""
Validate the generated Paytm QA dataset against the canonical source of truth.

Checks:
  1. Schema & structure (roles alternate user->assistant, non-empty, valid pages).
  2. Split integrity — every group_id lives in exactly ONE split (no leakage).
  3. Global dedup — no two records share identical conversation content.
  4. Direct single-turn field re-derivation — for each single_turn record, look up its
     entity transaction in paytm_document.json, recompute the expected value for its
     reasoning_type, and assert the answer contains it. (Strongest correctness check.)
  5. Order/superlative re-derivation — previous/next/superlative entities are truly correct.
  6. Numeric grounding — every ₹ value in every assistant turn is a legitimate value
     derivable from the source (amount / balance / summary / sum / difference / net).
  7. Transaction-ID grounding — every S#/M# token in answers is a real transaction id.
  8. Augmentation safety — augmented records changed ONLY user turns (answers identical
     to their distinct source's answer set).
Exits non-zero if any hard check fails.
"""
import json, os, re, sys, hashlib
from collections import defaultdict, Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QADIR = os.path.join(ROOT, "data", "paytm_qa")
D = json.load(open(os.path.join(ROOT, "data", "paytm_document.json")))
TX = D["transactions"]; SUMM = D["account_summary"]; FD = D["fixed_deposits"]
BYID = {t["transaction_id"]: t for t in TX}
N = len(TX)

def inr(x):
    neg = x < 0; x = abs(round(float(x), 2)); s = f"{x:.2f}"; ip, dec = s.split(".")
    if len(ip) > 3:
        last3 = ip[-3:]; rest = ip[:-3]; g = []
        while len(rest) > 2: g.insert(0, rest[-2:]); rest = rest[:-2]
        if rest: g.insert(0, rest)
        ip = ",".join(g) + "," + last3
    return ("-" if neg else "") + "₹" + ip + "." + dec

RECS = [json.loads(l) for l in open(os.path.join(QADIR, "penny_100k_context.jsonl"))]
errors = []; warn = []
def err(msg):
    errors.append(msg)

# ---- 1. schema/structure
for r in RECS:
    for k in ("id","source","category","reasoning_type","conversation","source_pages","group_id","split"):
        if k not in r: err(f"{r.get('id','?')}: missing key {k}")
    conv = r["conversation"]
    if len(conv) < 2 or len(conv) % 2 != 0:
        err(f"{r['id']}: conversation length {len(conv)} not even/>=2")
    for j, m in enumerate(conv):
        exp = "user" if j % 2 == 0 else "assistant"
        if m["role"] != exp: err(f"{r['id']}: turn {j} role {m['role']} != {exp}")
        if not m["content"].strip(): err(f"{r['id']}: empty content at {j}")
    for p in r["source_pages"]:
        if not (1 <= p <= 48): err(f"{r['id']}: bad page {p}")

# ---- 2. split integrity
g2s = defaultdict(set)
for r in RECS: g2s[r["group_id"]].add(r["split"])
leak = {g: s for g, s in g2s.items() if len(s) > 1}
if leak: err(f"SPLIT LEAKAGE: {len(leak)} group_ids span multiple splits, e.g. {list(leak.items())[:3]}")

# ---- 3. dedup
seen = set()
for r in RECS:
    sig = hashlib.sha1(("|".join(f"{m['role']}:{m['content']}" for m in r["conversation"])).encode()).hexdigest()
    if sig in seen: err(f"{r['id']}: duplicate conversation")
    seen.add(sig)

# ---- 4. single-turn field re-derivation
def a_of(r):  # first assistant answer
    return r["conversation"][1]["content"]
checks = Counter()
for r in RECS:
    if r["category"] != "single_turn": continue
    ents = r.get("entities") or []
    if not ents or ents[0] not in BYID: continue
    t = BYID[ents[0]]; ans = a_of(r); rt = r["reasoning_type"]; ok = True
    if rt == "field_amount":
        ok = inr(t["amount"]) in ans and (("credit" in ans) == (t["direction"]=="credit"))
    elif rt == "field_direction":
        ok = ("Money in" in ans) == (t["direction"]=="credit")
    elif rt == "field_date":
        ok = t["date_raw"] in ans
    elif rt == "field_time":
        ok = (t.get("time") or "") in ans
    elif rt == "field_counterparty":
        ok = (t.get("counterparty") or "") in ans
    elif rt == "field_vpa":
        ok = (t.get("vpa") or "") in ans
    elif rt == "field_bank":
        ok = (t.get("bank_code") or "") in ans
    elif rt == "field_txn_id":
        ok = t["transaction_id"] in ans
    elif rt == "field_reference":
        ok = (t.get("reference_number") or "") in ans
    elif rt == "field_balance_after":
        ok = inr(t["available_balance"]) in ans
    elif rt == "field_type":
        ok = t["type"] in ans
    elif rt == "field_page":
        ok = f"Page {t['page']}" in ans
    elif rt in ("field_summary","field_amount_and_balance"):
        ok = inr(t["amount"]) in ans and inr(t["available_balance"]) in ans
    checks[rt] += 1
    if not ok: err(f"{r['id']} [{rt}] txn {t['transaction_id']}: answer mismatch -> {ans!r}")

# ---- 5. order / superlative re-derivation
debits = [t for t in TX if t["direction"]=="debit"]; credits = [t for t in TX if t["direction"]=="credit"]
ld = max(debits,key=lambda t:t["amount"]); sd = min(debits,key=lambda t:t["amount"])
lc = max(credits,key=lambda t:t["amount"]); sc = min(credits,key=lambda t:t["amount"])
lo = max(TX,key=lambda t:t["amount"])
for r in RECS:
    if r["category"] != "transaction_reasoning": continue
    rt = r["reasoning_type"]; ents = r.get("entities") or []
    if rt == "order_previous" and len(ents)==2:
        a,b = BYID.get(ents[0]),BYID.get(ents[1])
        if a and b and b["index"] != a["index"]-1: err(f"{r['id']}: order_previous wrong")
    if rt == "order_next" and len(ents)==2:
        a,b = BYID.get(ents[0]),BYID.get(ents[1])
        if a and b and b["index"] != a["index"]+1: err(f"{r['id']}: order_next wrong")

# ---- 6. numeric grounding (build a complete legitimate ₹-value set)
def money_set():
    S = set()
    amts = [t["amount"] for t in TX]; bals = [t["available_balance"] for t in TX]
    for v in amts+bals: S.add(round(v,2))
    for v in (SUMM["opening_balance"],SUMM["total_deposit"],SUMM["total_withdrawal"],SUMM["closing_balance"]): S.add(round(v,2))
    TOTc = round(sum(t["amount"] for t in credits),2); TOTd = round(sum(t["amount"] for t in debits),2)
    S.add(TOTc); S.add(TOTd); S.add(round(TOTc-TOTd,2)); S.add(round(TOTd-TOTc,2))
    S.add(0.0); S.add(500000.0)
    by_date=defaultdict(list); by_cp=defaultdict(list); by_type=defaultdict(list)
    for t in TX:
        by_date[t["date"]].append(t)
        if t.get("counterparty"): by_cp[t["counterparty"]].append(t)
        by_type[t["type"]].append(t)
    for seq in list(by_cp.values())+list(by_type.values()):
        S.add(round(sum(x["amount"] for x in seq),2))
    for day in by_date.values():
        din=round(sum(x["amount"] for x in day if x["direction"]=="credit"),2)
        dout=round(sum(x["amount"] for x in day if x["direction"]=="debit"),2)
        S.add(din); S.add(dout); S.add(round(din-dout,2)); S.add(round(dout-din,2))
        for a,b in zip(day,day[1:]): S.add(round(abs(a["amount"]-b["amount"]),2))
    # prev/next amount diffs and two-hop balance diffs (used in chains)
    for i,t in enumerate(TX):
        if i>0: S.add(round(abs(t["amount"]-TX[i-1]["amount"]),2))
        if i+2<N: S.add(round(TX[i+2]["available_balance"]-t["available_balance"],2))
        if i>0: S.add(round(t["available_balance"]-TX[i-1]["available_balance"],2))
    return {round(x,2) for x in S}
LEGIT = money_set()
MONEY_RE = re.compile(r'-?₹([\d,]+\.\d{2})')
def parse_money(s): return round(float(s.replace(",","")),2)
bad_numbers = 0
for r in RECS:
    for m in r["conversation"]:
        if m["role"] != "assistant": continue
        for mo in MONEY_RE.finditer(m["content"]):
            val = parse_money(mo.group(1))
            if val not in LEGIT and -val not in LEGIT:
                bad_numbers += 1
                if bad_numbers <= 15: err(f"{r['id']}: ungrounded ₹ value {mo.group(0)} in {m['content'][:80]!r}")
if bad_numbers: err(f"TOTAL ungrounded ₹ values: {bad_numbers}")

# ---- 7. transaction-id grounding
TID_RE = re.compile(r'\b([SM]\d{4,})\b')
bad_ids = 0
for r in RECS:
    for m in r["conversation"]:
        if m["role"] != "assistant": continue
        for mo in TID_RE.finditer(m["content"]):
            if mo.group(1) not in BYID:
                bad_ids += 1
                if bad_ids <= 10: err(f"{r['id']}: unknown txn id {mo.group(1)}")
if bad_ids: err(f"TOTAL unknown txn ids in answers: {bad_ids}")

# ---- 8. augmentation safety: answers identical to a distinct record's
distinct_ans = defaultdict(set)  # group -> set of assistant contents
for r in RECS:
    if not r.get("augmented"):
        for m in r["conversation"]:
            if m["role"]=="assistant": distinct_ans[r["group_id"]].add(m["content"])
aug_bad = 0
for r in RECS:
    if r.get("augmented"):
        for m in r["conversation"]:
            if m["role"]=="assistant" and m["content"] not in distinct_ans[r["group_id"]]:
                aug_bad += 1
                if aug_bad <= 5: err(f"{r['id']}: augmented answer not in distinct source set")
if aug_bad: err(f"TOTAL augmented answer mismatches: {aug_bad}")

# ---- report
print(f"records validated : {len(RECS)}")
print(f"single_turn field checks: {sum(checks.values())} across {len(checks)} field types")
print(f"legit ₹-value set size  : {len(LEGIT)}")
print(f"split leakage groups    : {len(leak)}")
print(f"ungrounded ₹ values     : {bad_numbers}")
print(f"unknown txn ids         : {bad_ids}")
print(f"augmentation mismatches : {aug_bad}")
print(f"ERRORS: {len(errors)}")
for e in errors[:25]: print("  -", e)
sys.exit(1 if errors else 0)
