#!/usr/bin/env python3
"""
Generate the AX-style contextual QA dataset for Penny MLX from the Paytm statement.

SOURCE OF TRUTH: data/paytm_document.json  (canonical, reconciled extraction of paytm.pdf)
Every answer here is COMPUTED from that JSON — nothing is invented. This guarantees that
each factual answer is traceable to the PDF (via the parsed document) or to a calculation
derived directly from it.

Outputs (data/paytm_qa/):
  single_turn.jsonl        reference_resolution.jsonl   long_context.jsonl
  multi_turn.jsonl         temporal_reasoning.jsonl     hard_cases.jsonl
  context_resolution.jsonl numerical_reasoning.jsonl    policy_reasoning.jsonl
  transaction_reasoning.jsonl  rewards_reasoning.jsonl (empty: N/A for Paytm)
  penny_100k_context.jsonl (combined)   penny_100k_context_qa.md (sample)
  train.jsonl / validation.jsonl / test.jsonl   dataset_stats.json / README.md
"""
import json, os, re, hashlib, itertools
from datetime import date, timedelta
from collections import defaultdict, Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOC = os.path.join(ROOT, "data", "paytm_document.json")
OUTDIR = os.path.join(ROOT, "data", "paytm_qa")
os.makedirs(OUTDIR, exist_ok=True)

D = json.load(open(DOC))
TX = D["transactions"]
SUMM = D["account_summary"]
ACC = D["account"]
FD = D["fixed_deposits"]

# ---------------------------------------------------------------- helpers
def inr(x):
    """Indian-grouped currency, 2 decimals, e.g. ₹1,06,951.48"""
    neg = x < 0
    x = abs(round(float(x) + 0.0, 2))
    s = f"{x:.2f}"; intp, dec = s.split(".")
    if len(intp) > 3:
        last3 = intp[-3:]; rest = intp[:-3]; groups = []
        while len(rest) > 2:
            groups.insert(0, rest[-2:]); rest = rest[:-2]
        if rest: groups.insert(0, rest)
        intp = ",".join(groups) + "," + last3
    return ("-" if neg else "") + "₹" + intp + "." + dec

def isod(s):  # "2023-01-06" -> date
    y, m, d = map(int, s.split("-")); return date(y, m, d)

ORD = {1:"first",2:"second",3:"third",4:"fourth",5:"fifth",6:"sixth",7:"seventh",
       8:"eighth",9:"ninth",10:"tenth",11:"eleventh",12:"twelfth"}
def ordinal(n):
    if n in ORD: return ORD[n]
    suf = "th" if 10 <= n % 100 <= 20 else {1:"st",2:"nd",3:"rd"}.get(n % 10, "th")
    return f"{n}{suf}"

def verb(t):
    d = t["direction"]
    if t["type"].startswith("Paid using"): return "paid"
    if d == "credit": return "received"
    return "sent"
def prep(t):
    return "from" if t["direction"] == "credit" else ("at" if t["type"].startswith("Paid using") else "to")
def party(t):
    return t.get("counterparty") or ("the sender" if t["direction"] == "credit" else "the payee")

def one_line(t):
    """A natural one-sentence description of a transaction."""
    cp = t.get("counterparty")
    base = f"{verb(t)} {inr(t['amount'])}"
    if cp: base += f" {prep(t)} {cp}"
    base += f" on {t['date_raw']}"
    if t.get("time"): base += f" at {t['time']}"
    rail = t["type"]
    return f"You {base} ({rail}). Balance afterwards: {inr(t['available_balance'])}."

# ---------------------------------------------------------------- indices
N = len(TX)
by_date = defaultdict(list)
by_cp = defaultdict(list)
by_type = defaultdict(list)
for t in TX:
    by_date[t["date"]].append(t)
    if t.get("counterparty"): by_cp[t["counterparty"]].append(t)
    by_type[t["type"]].append(t)
dates_sorted = sorted(by_date)
credits = [t for t in TX if t["direction"] == "credit"]
debits = [t for t in TX if t["direction"] == "debit"]

def by_amt(seq): return sorted(seq, key=lambda t: t["amount"])
largest_debit = by_amt(debits)[-1]; smallest_debit = by_amt(debits)[0]
largest_credit = by_amt(credits)[-1]; smallest_credit = by_amt(credits)[0]
largest_overall = by_amt(TX)[-1]

TOT_CREDIT = round(sum(t["amount"] for t in credits), 2)
TOT_DEBIT = round(sum(t["amount"] for t in debits), 2)

# unique descriptor: guarantee a question points at exactly ONE txn -----------
def _sig(t, fields):
    return tuple(t.get(f) for f in fields)
def _build_sig_maps():
    maps = {}
    combos = [("date","time"),("counterparty","date","time"),("amount","date","time"),
              ("counterparty","amount","date"),("counterparty","amount","date","time")]
    for c in combos:
        m = defaultdict(list)
        for t in TX: m[_sig(t,c)].append(t)
        maps[c] = m
    return maps
SIGMAPS = _build_sig_maps()

def descriptor(t, exclude=()):
    """Unique natural handle for a txn, omitting `exclude` fields (so we never leak the answer)."""
    ex = set(exclude)
    parts, used = [], []
    if "counterparty" not in ex and t.get("counterparty"):
        parts.append(f"{prep(t)} {t['counterparty']}"); used.append("counterparty")
    if "amount" not in ex:
        parts.append(inr(t["amount"])); used.append("amount")
    if "date" not in ex:
        parts.append(f"on {t['date_raw']}"); used.append("date")
    if "time" not in ex and t.get("time"):
        parts.append(f"at {t['time']}"); used.append("time")
    handle = "the " + (f"{inr(t['amount'])} " if "amount" in used else "") + "transaction"
    # rebuild more naturally
    seg = []
    if "counterparty" in used: seg.append(f"{prep(t)} {t['counterparty']}")
    if "date" in used: seg.append(f"on {t['date_raw']}")
    if "time" in used: seg.append(f"at {t['time']}")
    handle = "the " + (inr(t["amount"]) + " " if "amount" in used else "") + "transaction"
    if seg: handle += " " + " ".join(seg)
    # uniqueness check
    key = tuple(sorted(used))
    combo = tuple(f for f in ("counterparty","amount","date","time") if f in used)
    uniq = True
    if combo in SIGMAPS:
        uniq = len(SIGMAPS[combo][_sig(t, combo)]) == 1
    else:
        grp = [x for x in TX if all(x.get(f) == t.get(f) for f in used)]
        uniq = len(grp) == 1
    if not uniq:
        handle += f" (transaction {t['transaction_id']})"
    return handle

# ---------------------------------------------------------------- record utils
RECORDS = []
_SEEN = set()
def add(cat, reasoning, turns, t=None, pages=None, entities=None, group=None):
    """turns: list of (role, content). Stored as conversation[]. Exact-duplicate guarded."""
    sig = hashlib.sha1(("|".join(f"{r}:{c}" for r, c in turns)).encode()).hexdigest()
    if sig in _SEEN:
        return
    _SEEN.add(sig)
    conv = [{"role": r, "content": c} for r, c in turns]
    pg = pages if pages is not None else ([t["page"]] if t else [])
    ent = entities if entities is not None else ([t["transaction_id"]] if t else [])
    grp = group or (f"txn_{t['index']}" if t else "misc")
    RECORDS.append({"source": "paytm.pdf", "category": cat, "reasoning_type": reasoning,
                    "conversation": conv, "source_pages": sorted(set(pg)),
                    "entities": ent, "group_id": grp})

def P(*variants):  # pick-all phrasings; returns the list
    return list(variants)

# position of a txn within its day (1-based)
DAY_POS = {}
for _d, _day in by_date.items():
    for _j, _t in enumerate(_day, 1):
        DAY_POS[_t["transaction_id"]] = (_j, len(_day))
# uniqueness maps for alternate identification handles
REF_UNIQUE = Counter(t["reference_number"] for t in TX if t.get("reference_number"))
BAL_UNIQUE = Counter(t["available_balance"] for t in TX)

def entries(t):
    """Distinct natural ways to open a conversation about txn t (each: 2-msg opener)."""
    ol = one_line(t)
    outs = [[("user", f"Tell me about {descriptor(t)}."), ("assistant", ol)],
            [("user", f"Give me the details of transaction {t['transaction_id']}."), ("assistant", ol)]]
    if t.get("time"):
        outs.append([("user", f"What was the transaction on {t['date_raw']} at {t['time']}?"), ("assistant", ol)])
    pos, tot = DAY_POS[t["transaction_id"]]
    if tot > 1:
        outs.append([("user", f"What was the {ordinal(pos)} transaction on {t['date_raw']}?"), ("assistant", ol)])
    if t.get("counterparty"):
        outs.append([("user", f"Look up the {inr(t['amount'])} transaction {prep(t)} {t['counterparty']}."), ("assistant", ol)])
    # identify by reference number (genuinely distinct handle)
    if t.get("reference_number") and REF_UNIQUE.get(t["reference_number"], 0) == 1:
        outs.append([("user", f"Which transaction has {t.get('reference_type','reference')} {t['reference_number']}?"), ("assistant", ol)])
    # identify by resulting balance (only when that balance is unique in the statement)
    if BAL_UNIQUE.get(t["available_balance"], 0) == 1:
        outs.append([("user", f"Which transaction left the running balance at exactly {inr(t['available_balance'])}?"), ("assistant", ol)])
    return outs

def chains(t, prevt, nextt):
    """Distinct follow-up chains (each a list of (u,a) turns) exercising context/pronoun/temporal."""
    cs = []
    amt = f"{inr(t['amount'])}."
    bal = f"{inr(t['available_balance'])}."
    # 1 amount -> balance
    cs.append([("How much was it?", amt), ("What was the balance right after it?", bal)])
    # 2 time -> counterparty
    if t.get("time"):
        c = [("What time did it happen?", f"{t['time']} on {t['date_raw']}.")]
        if t.get("counterparty"):
            c.append(("And who was it " + ("from" if t["direction"]=="credit" else "to") + "?", f"{t['counterparty']}."))
        cs.append(c)
    # 3 identifiers
    c = [("What's its transaction ID?", f"{t['transaction_id']}.")]
    if t.get("reference_number"):
        c.append((f"And the {t.get('reference_type','reference')}?", f"{t['reference_number']}."))
    if t.get("vpa"):
        c.append(("Which UPI ID was involved?", f"{t['vpa']}."))
    cs.append(c)
    # 4 previous drill
    if prevt:
        cs.append([("What was the transaction before it?", one_line(prevt)),
                   ("How much was that one?", f"{inr(prevt['amount'])}."),
                   ("Was it more than the one we started with?",
                    ("Yes — " if prevt["amount"] > t["amount"] else ("No — " if prevt["amount"] < t["amount"] else "They were equal — "))
                    + f"{inr(prevt['amount'])} vs {inr(t['amount'])}.")])
    # 5 next drill
    if nextt:
        cs.append([("What came right after it?", one_line(nextt)),
                   ("How much was that?", f"{inr(nextt['amount'])}."),
                   ("What was the balance after that one?", f"{inr(nextt['available_balance'])}.")])
    # 6 rail + page + method
    cs.append([("Which rail/method was used?", f"{t['type']}."),
               ("What page of the statement is it on?", f"Page {t['page']}.")])
    # 7 direction reasoning
    cs.append([("Was that money in or out?",
                ("Money in (credit)." if t["direction"]=="credit" else "Money out (debit).")),
               ("By how much did it change the balance?",
                f"{'+' if t['direction']=='credit' else '-'}{inr(t['amount'])}, to {inr(t['available_balance'])}.")])
    # 8 balance-focused with previous balance and net
    if prevt:
        cs.append([("What was the balance after it?", bal),
                   ("And what was the balance just before it?", f"{inr(prevt['available_balance'])}."),
                   ("So what was the net movement?",
                    f"{'+' if t['direction']=='credit' else '-'}{inr(t['amount'])}.")])
    # 9 same-day superlative
    day = by_date[t["date"]]
    if len(day) > 1:
        big = by_amt(day)[-1]
        if big["transaction_id"] == t["transaction_id"]:
            ans = "Yes — it was the largest transaction that day."
        else:
            ans = f"No. The largest that day was {inr(big['amount'])} ({descriptor(big)})."
        cs.append([("Was it the biggest transaction of that day?", ans),
                   ("How many transactions were there that day in total?",
                    f"{len(day)} on {t['date_raw']}.")])
    # 10 earlier / later same day (temporal within a topic)
    pos, tot = DAY_POS[t["transaction_id"]]
    if pos > 1:
        earlier = day[pos-2]
        cs.append([("What happened earlier that same day, just before it?", one_line(earlier)),
                   ("How much was that?", f"{inr(earlier['amount'])}.")])
    if pos < tot:
        later = day[pos]
        cs.append([("What was the next thing that day?", one_line(later)),
                   ("And its balance after?", f"{inr(later['available_balance'])}.")])
    # 11 counterparty aggregate within conversation
    cp = t.get("counterparty")
    if cp and len(by_cp[cp]) > 1:
        seq = by_cp[cp]; s = round(sum(x["amount"] for x in seq), 2)
        cs.append([(f"How many times in total did you transact with {cp}?",
                    f"{len(seq)} times, totalling {inr(s)}."),
                   ("Was this the largest of those?",
                    ("Yes." if by_amt(seq)[-1]["transaction_id"] == t["transaction_id"]
                     else f"No — the largest was {inr(by_amt(seq)[-1]['amount'])}."))])
    # 12 reference + bank identifiers together
    if t.get("reference_number"):
        c = [(f"What was its {t.get('reference_type','reference')}?", f"{t['reference_number']}.")]
        if t.get("bank_code"):
            c.append(("And which bank was on the other side?", f"{t['bank_code']}."))
        elif t.get("account_ref"):
            c.append(("Which account was it linked to?", f"{t['account_ref']}."))
        cs.append(c)
    # 13 two-ahead balance (multi-hop numeric memory)
    i = t["index"]
    if i + 1 < N:
        n2 = TX[i+1]
        cs.append([("What was the balance after it?", bal),
                   ("And two transactions later, what was the balance?", f"{inr(n2['available_balance'])}."),
                   ("What was the net change across those two?",
                    f"{inr(round(n2['available_balance']-t['available_balance'],2))}.")])
    # 14 time-of-day reasoning
    if t.get("time"):
        ampm = "morning/afternoon" if "AM" in t["time"] or t["time"].startswith(("12:","1:","2:","3:","4:","5:")) else "evening/night"
        cs.append([("Was that in the morning or later in the day?",
                    f"It was logged at {t['time']}."),
                   ("What was the date again?", f"{t['date_raw']}.")])
    # 15 position within day
    pos2, tot2 = DAY_POS[t["transaction_id"]]
    if tot2 > 2:
        where = "the first" if pos2 == 1 else ("the last" if pos2 == tot2 else f"number {pos2}")
        cs.append([("Where in that day's activity did it fall?",
                    f"It was {where} of {tot2} transactions on {t['date_raw']}."),
                   ("What was the last transaction that day?", one_line(day[-1]))])
    # 16 global position in the statement
    cs.append([("How many transactions came before this one in the whole statement?", f"{i-1}."),
               ("And how many came after it?", f"{N-i}.")])
    # 17 rail classification / explanation
    rail = t["type"]
    if "UPI" in rail: expl = "It was a UPI transfer (instant, VPA-addressed)."
    elif "IMPS" in rail: expl = "It was an IMPS transfer (immediate interbank, mobile/account addressed)."
    elif "Bank Account" in rail: expl = "It was paid directly from the linked bank account."
    elif "Failed Payment" in rail: expl = "It was a reversal — money restored to the account after a failed payment."
    else: expl = f"It was recorded as: {rail}."
    cs.append([("What kind of transaction was it?", expl),
               ("Was it money in or out?",
                "Money in (credit)." if t["direction"]=="credit" else "Money out (debit).")])
    # 18 previous transaction's direction (cross-entity memory)
    if prevt:
        cs.append([("Was the transaction before it a credit or a debit?",
                    ("A credit of " if prevt["direction"]=="credit" else "A debit of ") + inr(prevt["amount"]) + "."),
                   ("And this one?",
                    ("A credit." if t["direction"]=="credit" else "A debit."))])
    return cs

# ================================================================ 1. SINGLE-TURN (fields)
def gen_single_fields():
    for t in TX:
        cp = t.get("counterparty")
        # amount
        for q in P(f"How much was {descriptor(t, ['amount'])}?",
                   f"What was the amount of {descriptor(t, ['amount'])}?",
                   f"What was the value of {descriptor(t, ['amount'])}?"):
            a = f"{inr(t['amount'])} ({'credit' if t['direction']=='credit' else 'debit'})."
            add("single_turn","field_amount",[("user",q),("assistant",a)],t)
        # direction
        for q in P(f"Was {descriptor(t,['amount'])} money in or out?",
                   f"Was {descriptor(t)} a credit or a debit?"):
            a = ("Money in — it was a credit of " if t["direction"]=="credit"
                 else "Money out — it was a debit of ") + inr(t["amount"]) + "."
            add("single_turn","field_direction",[("user",q),("assistant",a)],t)
        # date
        for q in P(f"On what date did {descriptor(t,['date'])} happen?",
                   f"When did {descriptor(t,['date'])} take place?"):
            a = f"On {t['date_raw']}" + (f", at {t['time']}." if t.get('time') else ".")
            add("single_turn","field_date",[("user",q),("assistant",a)],t)
        # time
        if t.get("time"):
            for q in P(f"At what time did {descriptor(t,['time'])} occur?",
                       f"What time was {descriptor(t,['time'])}?"):
                a = f"At {t['time']} on {t['date_raw']}."
                add("single_turn","field_time",[("user",q),("assistant",a)],t)
        # counterparty
        if cp:
            noun = "did you receive that money from" if t["direction"]=="credit" else "did you pay"
            for q in P(f"Who {noun} in {descriptor(t,['counterparty'])}?",
                       f"Who was the {'sender' if t['direction']=='credit' else 'recipient'} of {descriptor(t,['counterparty'])}?"):
                a = f"{cp}" + (f" (VPA {t['vpa']})" if t.get("vpa") else "") + "."
                add("single_turn","field_counterparty",[("user",q),("assistant",a)],t)
        # vpa
        if t.get("vpa"):
            q = f"What UPI ID (VPA) was used for {descriptor(t)}?"
            add("single_turn","field_vpa",[("user",q),("assistant",f"{t['vpa']}.")],t)
        # bank code
        if t.get("bank_code"):
            q = f"Which bank/IFSC was on the other side of {descriptor(t)}?"
            add("single_turn","field_bank",[("user",q),("assistant",f"{t['bank_code']}.")],t)
        # transaction id
        for q in P(f"What is the transaction ID for {descriptor(t,['amount'])}?",):
            add("single_turn","field_txn_id",[("user",q),("assistant",f"{t['transaction_id']}.")],t)
        # reference number
        if t.get("reference_number"):
            q = f"What is the {t.get('reference_type','reference')} for {descriptor(t)}?"
            add("single_turn","field_reference",[("user",q),("assistant",f"{t['reference_number']}.")],t)
        # balance after
        for q in P(f"What was the account balance right after {descriptor(t)}?",
                   f"What was the available balance following {descriptor(t)}?",
                   f"After {descriptor(t)}, what did the balance stand at?"):
            a = f"{inr(t['available_balance'])}."
            add("single_turn","field_balance_after",[("user",q),("assistant",a)],t)
        # combined: amount + counterparty + balance in one answer (distinct QA)
        who = (f" {prep(t)} {t['counterparty']}" if t.get("counterparty") else "")
        add("single_turn","field_summary",
            [("user",f"Summarise {descriptor(t)} in one line."),("assistant",one_line(t))],t)
        add("single_turn","field_amount_and_balance",
            [("user",f"For {descriptor(t)}, what was the amount and the balance after?"),
             ("assistant",f"Amount {inr(t['amount'])}{who}; balance after {inr(t['available_balance'])}.")],t)
        # rail / type
        q = f"Which payment method / rail was used for {descriptor(t,['amount'])}?"
        add("single_turn","field_type",[("user",q),("assistant",f"{t['type']}.")],t)
        # page
        q = f"On which page of the statement does {descriptor(t)} appear?"
        add("single_turn","field_page",[("user",q),("assistant",f"Page {t['page']}.")],t)

# ================================================================ 2. TRANSACTION REASONING (order/superlative)
def gen_transaction_reasoning():
    for t in TX:
        i = t["index"]
        if i > 1:
            p = TX[i-2]
            for q in P(f"What was the transaction immediately before {descriptor(t)}?",
                       f"Which transaction came just before {descriptor(t)}?"):
                add("transaction_reasoning","order_previous",
                    [("user",q),("assistant",one_line(p))],t,
                    pages=[t["page"],p["page"]],entities=[t["transaction_id"],p["transaction_id"]])
        if i < N:
            nx = TX[i]
            for q in P(f"What was the transaction immediately after {descriptor(t)}?",
                       f"Which transaction came right after {descriptor(t)}?"):
                add("transaction_reasoning","order_next",
                    [("user",q),("assistant",one_line(nx))],t,
                    pages=[t["page"],nx["page"]],entities=[t["transaction_id"],nx["transaction_id"]])
        # k-step neighbours
        for k in (2, 3):
            if i-1-k >= 0:
                pk = TX[i-1-k]
                add("transaction_reasoning",f"order_prev_{k}",
                    [("user",f"What was the transaction {k} before {descriptor(t)}?"),
                     ("assistant",one_line(pk))],t,pages=[t["page"],pk["page"]],
                    entities=[t["transaction_id"],pk["transaction_id"]])
            if i-1+k < N:
                nk = TX[i-1+k]
                add("transaction_reasoning",f"order_next_{k}",
                    [("user",f"What was the transaction {k} after {descriptor(t)}?"),
                     ("assistant",one_line(nk))],t,pages=[t["page"],nk["page"]],
                    entities=[t["transaction_id"],nk["transaction_id"]])
        # nth on its day
        pos, tot = DAY_POS[t["transaction_id"]]
        if tot > 1:
            add("transaction_reasoning","nth_on_day",
                [("user",f"On {t['date_raw']}, what was the {ordinal(pos)} transaction of the day?"),
                 ("assistant",one_line(t))],t,group=f"date_{t['date']}")
    # hop through counterparty: "transaction before/after the one to X"
    for cp, seq in by_cp.items():
        if len(seq) != 1:  # only unambiguous single-occurrence counterparties
            continue
        t = seq[0]; i = t["index"]
        if i > 1:
            p = TX[i-2]
            add("transaction_reasoning","hop_before_cp",
                [("user",f"What was the transaction right before the one {prep(t)} {cp}?"),
                 ("assistant",one_line(p))],t,pages=[t["page"],p["page"]],
                entities=[t["transaction_id"],p["transaction_id"]],group=f"cp_{cp}")
        if i < N:
            nx = TX[i]
            add("transaction_reasoning","hop_after_cp",
                [("user",f"What was the transaction right after the one {prep(t)} {cp}?"),
                 ("assistant",one_line(nx))],t,pages=[t["page"],nx["page"]],
                entities=[t["transaction_id"],nx["transaction_id"]],group=f"cp_{cp}")
    # globals
    glob = {
      "the very first transaction on the statement": TX[0],
      "the very last transaction on the statement": TX[-1],
      "the largest debit (money out)": largest_debit,
      "the smallest debit (money out)": smallest_debit,
      "the largest credit (money in)": largest_credit,
      "the smallest credit (money in)": smallest_credit,
      "the single largest transaction by amount": largest_overall,
    }
    for label, t in glob.items():
        for q in P(f"What was {label}?", f"Tell me about {label}."):
            add("transaction_reasoning","superlative",
                [("user",q),("assistant",one_line(t))],t, group=f"glob_{label[:20]}")
    # per-date first / last / count / largest
    for d in dates_sorted:
        day = by_date[d]; dr = day[0]["date_raw"]
        add("transaction_reasoning","day_count",
            [("user",f"How many transactions were there on {dr}?"),
             ("assistant",f"{len(day)} transaction{'s' if len(day)!=1 else ''} on {dr}.")],
            day[0], pages=[x["page"] for x in day], group=f"date_{d}")
        add("transaction_reasoning","day_first",
            [("user",f"What was the first transaction on {dr}?"),
             ("assistant",one_line(day[0]))], day[0], group=f"date_{d}")
        add("transaction_reasoning","day_last",
            [("user",f"What was the last transaction on {dr}?"),
             ("assistant",one_line(day[-1]))], day[-1], group=f"date_{d}")
        big = by_amt(day)[-1]
        add("transaction_reasoning","day_largest",
            [("user",f"What was the biggest transaction on {dr}?"),
             ("assistant",one_line(big))], big, group=f"date_{d}")

# ================================================================ 3. NUMERICAL REASONING
def gen_numerical():
    g = "agg_global"
    facts = [
      ("What was the total money received (all credits) in this statement?",
       f"{inr(TOT_CREDIT)} across {len(credits)} credit transactions. This matches the statement's Total Deposit of {inr(SUMM['total_deposit'])}."),
      ("What was the total money paid out (all debits) in this statement?",
       f"{inr(TOT_DEBIT)} across {len(debits)} debit transactions. This matches the statement's Total Withdrawal of {inr(SUMM['total_withdrawal'])}."),
      ("What was the net change in balance over the statement period?",
       f"{inr(round(TOT_CREDIT-TOT_DEBIT,2))} (opening {inr(SUMM['opening_balance'])} → closing {inr(SUMM['closing_balance'])})."),
      ("How many transactions are in this statement in total?",
       f"{N} transactions ({len(debits)} debits and {len(credits)} credits)."),
      ("What was the opening balance?", f"{inr(SUMM['opening_balance'])}."),
      ("What was the closing balance?", f"{inr(SUMM['closing_balance'])}."),
      ("How many debit (money-out) transactions were there?", f"{len(debits)}."),
      ("How many credit (money-in) transactions were there?", f"{len(credits)}."),
    ]
    for q, a in facts:
        for qq in P(q, q.replace("What was","Can you tell me").replace("How many","Roughly how many")):
            add("numerical_reasoning","aggregate_global",[("user",qq),("assistant",a)],
                group=g, pages=[1])
    # per type
    for typ, seq in by_type.items():
        s = round(sum(x["amount"] for x in seq), 2)
        add("numerical_reasoning","aggregate_type",
            [("user",f"How many '{typ}' transactions were there, and what did they total?"),
             ("assistant",f"{len(seq)} transactions totalling {inr(s)}.")],
            group=f"type_{typ}", pages=[1])
    # per counterparty (>=2)
    for cp, seq in by_cp.items():
        if len(seq) < 2: continue
        s = round(sum(x["amount"] for x in seq), 2)
        big = by_amt(seq)[-1]
        for q, a in [
            (f"How many times did you transact with {cp}?",
             f"{len(seq)} times, totalling {inr(s)}."),
            (f"What was the total transacted with {cp}?",
             f"{inr(s)} across {len(seq)} transactions."),
            (f"What was your largest single transaction with {cp}?",
             one_line(big)),
        ]:
            add("numerical_reasoning","aggregate_counterparty",
                [("user",q),("assistant",a)], group=f"cp_{cp}",
                pages=sorted({x['page'] for x in seq}))
    # single-occurrence counterparty facts
    for cp, seq in by_cp.items():
        if len(seq) != 1: continue
        t = seq[0]
        add("numerical_reasoning","cp_single",
            [("user",f"When did you transact with {cp}, and how much?"),
             ("assistant",f"Once — {one_line(t)}")],t,group=f"cp_{cp}")
    # per-date totals
    for d in dates_sorted:
        day = by_date[d]; dr = day[0]["date_raw"]
        din = round(sum(x["amount"] for x in day if x["direction"]=="credit"),2)
        dout = round(sum(x["amount"] for x in day if x["direction"]=="debit"),2)
        add("numerical_reasoning","aggregate_day",
            [("user",f"On {dr}, how much went out and how much came in?"),
             ("assistant",f"Out: {inr(dout)}. In: {inr(din)}. Net: {inr(round(din-dout,2))}.")],
            group=f"date_{d}", pages=[x["page"] for x in day])
    # pairwise difference (sample: consecutive same-day pairs, capped)
    cnt = 0
    for d in dates_sorted:
        day = by_date[d]
        for a1, a2 in zip(day, day[1:]):
            if cnt > 1500: break
            diff = round(abs(a1["amount"]-a2["amount"]),2)
            bigger = a1 if a1["amount"]>=a2["amount"] else a2
            q = (f"What was the difference in amount between {descriptor(a1)} and {descriptor(a2)}?")
            a = (f"{inr(diff)}. The larger was {descriptor(bigger)} at {inr(bigger['amount'])}.")
            add("numerical_reasoning","difference",[("user",q),("assistant",a)],
                a1, pages=[a1["page"],a2["page"]],
                entities=[a1["transaction_id"],a2["transaction_id"]],
                group=f"txn_{a1['index']}")
            cnt += 1

# ================================================================ 4. TEMPORAL REASONING
def gen_temporal():
    for d in dates_sorted:
        day = by_date[d]; dr = day[0]["date_raw"]
        # what happened on date
        summ = f"{len(day)} transaction(s) on {dr}. First: {one_line(day[0])}"
        if len(day) > 1: summ += f" Last: {one_line(day[-1])}"
        add("temporal_reasoning","on_date",
            [("user",f"What happened on {dr}?"),("assistant",summ)],
            day[0], pages=[x["page"] for x in day], group=f"date_{d}")
        # next calendar day
        nd = isod(d) + timedelta(days=1); nds = nd.isoformat()
        ndr = nd.strftime("%d %b %Y")
        if nds in by_date:
            nday = by_date[nds]
            a = f"On {ndr} there were {len(nday)} transaction(s). First: {one_line(nday[0])}"
        else:
            a = f"There were no transactions on {ndr}."
        add("temporal_reasoning","next_day",
            [("user",f"And the day after {dr}?"),("assistant",a)],
            day[0], pages=[x["page"] for x in day], group=f"date_{d}")
        # previous calendar day
        pd = isod(d) - timedelta(days=1); pds = pd.isoformat()
        pdr = pd.strftime("%d %b %Y")
        if pds in by_date:
            pday = by_date[pds]
            a = f"On {pdr} there were {len(pday)} transaction(s). Last: {one_line(pday[-1])}"
        else:
            a = f"There were no transactions on {pdr}."
        add("temporal_reasoning","previous_day",
            [("user",f"What about the day before {dr}?"),("assistant",a)],
            day[0], pages=[x["page"] for x in day], group=f"date_{d}")
    # per-transaction conversational before/after ("that happened … what was before that?")
    for t in TX:
        i = t["index"]
        prevt = TX[i-2] if i > 1 else None
        nextt = TX[i] if i < N else None
        if not (prevt or nextt): continue
        turns = [("user", f"Something happened {('at ' + t['time'] + ' ') if t.get('time') else ''}on {t['date_raw']} — {descriptor(t)}. What was it?"),
                 ("assistant", one_line(t))]
        if prevt:
            turns += [("user", "What happened just before that?"), ("assistant", one_line(prevt))]
        if nextt:
            turns += [("user", "And what happened right after?"), ("assistant", one_line(nextt))]
        turns += [("user", "Going back — how much was the one I first asked about?"),
                  ("assistant", f"{inr(t['amount'])}.")]
        add("temporal_reasoning","before_after_chain", turns, t,
            pages=sorted({x["page"] for x in [t, prevt, nextt] if x}),
            entities=[x["transaction_id"] for x in [t, prevt, nextt] if x])

# ================================================================ 5. REFERENCE / PRONOUN (2-turn)
def gen_reference():
    anchors = [("the largest debit", largest_debit), ("the largest credit", largest_credit),
               ("the first transaction", TX[0]), ("the last transaction", TX[-1]),
               ("the single biggest transaction", largest_overall)]
    for label, t in anchors:
        base = [("user",f"What was {label}?"),("assistant",one_line(t))]
        follow = [
            ("How much was it?", f"{inr(t['amount'])}."),
            ("When did it happen?", f"{t['date_raw']}" + (f" at {t['time']}." if t.get('time') else ".")),
            ("Who was it "+("from" if t['direction']=='credit' else "to")+"?", (party(t))+"."),
            ("What was its transaction ID?", f"{t['transaction_id']}."),
            ("What was the balance right after it?", f"{inr(t['available_balance'])}."),
            ("What page is it on?", f"Page {t['page']}."),
        ]
        for fq, fa in follow:
            add("reference_resolution","pronoun_it",
                base+[("user",fq),("assistant",fa)], t, group=f"ref_{label[:12]}_{t['index']}")
    # per-transaction: establish then pronoun follow-up (each hop as its own 2-turn+ record)
    for t in TX:
        base = [("user",f"Tell me about {descriptor(t)}."),("assistant",one_line(t))]
        fu = []
        if t.get("time"): fu.append(("What time was it?", f"{t['time']}."))
        fu.append(("How much was it exactly?", f"{inr(t['amount'])}."))
        fu.append(("What was the balance after it?", f"{inr(t['available_balance'])}."))
        fu.append(("Was it money in or out?",
                   "Money in (credit)." if t["direction"]=="credit" else "Money out (debit)."))
        fu.append(("What was its transaction ID?", f"{t['transaction_id']}."))
        if t.get("counterparty"):
            fu.append(("Remind me who that was "+("from" if t['direction']=='credit' else "to")+"?",
                       f"{t['counterparty']}."))
        for fq, fa in fu:
            add("reference_resolution","pronoun_followup",
                base+[("user",fq),("assistant",fa)], t)
        # one multi-hop chain stringing several pronoun references together
        turns = list(base)
        for fq, fa in fu:
            turns += [("user", fq), ("assistant", fa)]
        add("reference_resolution","pronoun_multi_hop", turns, t)

# ================================================================ 6. MULTI-TURN / CONTEXT (entry × chain engine)
def gen_multi_turn():
    for t in TX:
        i = t["index"]
        prevt = TX[i-2] if i > 1 else None
        nextt = TX[i] if i < N else None
        ents = [x["transaction_id"] for x in [t, prevt, nextt] if x]
        pages = sorted({x["page"] for x in [t, prevt, nextt] if x})
        ee = entries(t)
        cc = chains(t, prevt, nextt)
        for ei, e in enumerate(ee):
            for ci, chain in enumerate(cc):
                turns = list(e) + [(role, msg) for (uq, ua) in chain for role, msg in (("user", uq), ("assistant", ua))]
                add("multi_turn", f"e{ei}_c{ci}", turns, t, pages=pages, entities=ents)

# ================================================================ 7. CONTEXT SWITCH / RESET (context_resolution)
def gen_context_switch():
    # a few different "distractor" facts to switch to, then return to the transaction
    distractors = [
        ("Actually, what's the account's interest rate?", f"The savings account earns {ACC['interest_rate']} p.a."),
        ("Wait — what's the account's IFSC code?", f"{ACC['ifsc']}."),
        ("Hold on, what was the closing balance of the whole statement?", f"{inr(SUMM['closing_balance'])}."),
        ("By the way, who holds this account?", f"{ACC['account_holder']}."),
    ]
    for t in TX:
        dq, da = distractors[t["index"] % len(distractors)]
        # switch to account fact then return, asking a field that requires remembering the topic
        turns = [("user",f"Tell me about {descriptor(t)}."),("assistant",one_line(t))]
        turns += [("user",dq),("assistant",da)]
        turns += [("user","Ok, go back to that transaction — what was its transaction ID?"),
                  ("assistant",f"{t['transaction_id']}.")]
        turns += [("user","And the balance after it?"),("assistant",f"{inr(t['available_balance'])}.")]
        add("context_resolution","switch_and_return",turns,t,pages=[t["page"],1])
    # reset: talk about A, then reset to B
    for a, b in zip(TX[::7], TX[3::7]):
        turns = [("user",f"How much was {descriptor(a)}?"),("assistant",f"{inr(a['amount'])}.")]
        turns += [("user",f"Forget that. Now tell me about {descriptor(b)}."),
                  ("assistant",one_line(b))]
        turns += [("user","What was its balance afterwards?"),("assistant",f"{inr(b['available_balance'])}.")]
        add("context_resolution","reset",turns,b,
            pages=sorted({a['page'],b['page']}),
            entities=[a['transaction_id'],b['transaction_id']],group=f"txn_{b['index']}")

# ================================================================ 8. LONG CONTEXT (10-50 turn walks)
def gen_long_context():
    def build(seq, k):
        turns = []
        for j, t in enumerate(seq):
            if j == 0:
                turns += [("user",f"Let's walk through some transactions. Start with {descriptor(t)}."),
                          ("assistant",one_line(t))]
            else:
                turns += [("user","What was the next one?"),("assistant",one_line(t))]
            turns += [("user","How much was that?"),("assistant",f"{inr(t['amount'])}.")]
        # back-reference to the first
        turns += [("user","Now go back to the very first transaction we discussed — how much was it and what was the balance after it?"),
                  ("assistant",f"{inr(seq[0]['amount'])}, balance afterwards {inr(seq[0]['available_balance'])}.")]
        # back-reference to a middle one
        mid = seq[len(seq)//2]
        turns += [("user",f"And the {ordinal(len(seq)//2+1)} one we discussed — who was it {'from' if mid['direction']=='credit' else 'to'}?"),
                  ("assistant",f"{party(mid)}.")]
        # back-reference to the last one and a superlative over the walked window
        big = by_amt(seq)[-1]
        turns += [("user","Of everything we just went through, which was the largest?"),
                  ("assistant",f"{one_line(big)}")]
        turns += [("user","And the last one we looked at — what was its balance after?"),
                  ("assistant",f"{inr(seq[-1]['available_balance'])}.")]
        add("long_context",f"walk_{k}_turns",turns,seq[0],
            pages=sorted({x['page'] for x in seq}),
            entities=[x['transaction_id'] for x in seq],
            group=f"long_{seq[0]['index']}_{k}")
    for depth in (3,5,8,10,15,20,30,40,50):
        step = max(1, N // 130)
        starts = range(0, max(1, N-depth), step)
        for s in starts:
            seq = TX[s:s+depth]
            if len(seq) == depth:
                build(seq, depth)

# ================================================================ 9. HARD CASES (ambiguity)
def gen_hard_cases():
    # ambiguity: a date with >=2 txns, underspecified reference
    for d in dates_sorted:
        day = by_date[d]
        if len(day) < 2: continue
        dr = day[0]["date_raw"]
        turns = [("user",f"There were several transactions on {dr}. What was the amount of that transaction?"),
                 ("assistant",f"There were {len(day)} transactions on {dr}, so I need you to be specific. "
                              f"For example, the first was {one_line(day[0])} Which one do you mean?")]
        add("hard_cases","ambiguous_reference",turns,day[0],
            pages=[x['page'] for x in day],group=f"amb_{d}")
    # ambiguity: two counterparties equally in play -> must ask
    for t in TX:
        if t["index"] % 11 != 0: continue
        i = t["index"]
        if i >= N: continue
        nx = TX[i]
        turns = [("user",f"Compare {descriptor(t)} and {descriptor(nx)}."),
                 ("assistant",f"{descriptor(t)}: {inr(t['amount'])}. {descriptor(nx)}: {inr(nx['amount'])}. "
                              f"The larger is {inr(max(t['amount'],nx['amount']))}.")]
        turns += [("user","What was its balance after?"),
                  ("assistant","Which of the two do you mean — the one "
                   f"{prep(t)} {party(t)} or the one {prep(nx)} {party(nx)}? "
                   "Let me know and I'll give the balance.")]
        add("hard_cases","ambiguous_pronoun_two_entities",turns,t,
            pages=sorted({t['page'],nx['page']}),
            entities=[t['transaction_id'],nx['transaction_id']])

# ================================================================ 10. POLICY / DOCUMENT META
def gen_policy():
    g = "policy"
    facts = [
      ("What is the interest rate on this savings account?", f"{ACC['interest_rate']} per annum."),
      ("What type of account is this?", f"A {ACC['account_type'].title()} account with Paytm Payments Bank."),
      ("What is the account's IFSC code?", f"{ACC['ifsc']}."),
      ("What is the MICR code?", f"{ACC['micr']}."),
      ("What period does this statement cover?",
       f"{ACC['statement_period']['from']} to {ACC['statement_period']['to']}."),
      ("When was the account opened?", f"{ACC['opened_on']}."),
      ("Is a nominee registered on the account?", f"No — the nominee status is '{ACC['nominee']}'."),
      ("Who holds this account?", f"{ACC['account_holder']}."),
      ("What is the account number?", f"{ACC['account_number']}."),
      ("Is the money in this account insured, and up to how much?",
       "Yes. Each depositor is insured by the Deposit Insurance and Credit Guarantee Corporation (DICGC) "
       "up to a maximum of ₹5,00,000 (INR 5 Lakh) for both principal and interest, in the same right and capacity."),
      ("Where can I see the terms & conditions for this account?",
       "At http://www.paytmbank.com/Terms&Conditions.html (per the statement footer)."),
      ("Does this statement need a signature?",
       "No — it states it is a computer-generated document that requires no signature and represents your record of transactions."),
      ("What should I never share with anyone, even someone claiming to be a bank employee?",
       "Your card number, CVV, PIN, OTP, Internet Banking User ID, Password or URN — sharing these can lead to unauthorised access."),
      ("Is there a partner bank for fixed deposits, and were any FDs active?",
       f"Fixed deposits are held with {FD['partner_bank']}. In this period there were no active fixed deposits "
       f"(available deposit {inr(FD['available_deposit_closing'])})."),
    ]
    for q, a in facts:
        for qq in P(q, "Quick question — " + q[0].lower() + q[1:]):
            add("policy_reasoning","document_meta",[("user",qq),("assistant",a)],
                group=g, pages=[1])

# ---------------------------------------------------------------- run all
gen_single_fields()
gen_transaction_reasoning()
gen_numerical()
gen_temporal()
gen_reference()
gen_multi_turn()
gen_context_switch()
gen_long_context()
gen_hard_cases()
gen_policy()

for r in RECORDS:
    r["augmented"] = False
DISTINCT_COUNT = len(RECORDS)

# ---------------------------------------------------------------- phrasing augmentation
# Reaches the brief's ~100K target. Augmented records are PARAPHRASES of the first user
# turn only (answers untouched, still fully grounded), flagged augmented=True, kept in the
# SAME split/group as their source, and dedup-guarded. Fully prunable via the flag.
TARGET = int(os.environ.get("PAYTM_TARGET", "100000"))
REWRITES = [
    ("How much was", "What amount was"),
    ("How much did", "What amount did"),
    ("Tell me about", "Give me the rundown on"),
    ("Give me the details of", "Walk me through"),
    ("What was the balance right after", "What did the balance become after"),
    ("What was the account balance right after", "What did the account balance become after"),
    ("What was the amount of", "What sum was"),
    ("Who was", "Which party was"),
    ("What time did", "At what point in the day did"),
    ("Which transaction came just before", "What immediately preceded"),
    ("Which transaction came right after", "What immediately followed"),
    ("What was the transaction immediately before", "What came just before"),
    ("What was the transaction immediately after", "What came just after"),
    ("On what date did", "On which day did"),
    ("What happened on", "What took place on"),
    ("Summarise", "Give me a one-line summary of"),
    ("What was", "Can you tell me what was"),
]
def paraphrase_first_user(conv):
    out = [dict(m) for m in conv]
    for m in out:
        if m["role"] == "user":
            c = m["content"]
            for a, b in REWRITES:
                if c.startswith(a):
                    m["content"] = b + c[len(a):]
                    return out, True
            return out, False
    return out, False

if TARGET > len(RECORDS):
    base_pool = list(RECORDS)  # snapshot of distinct records
    for r in base_pool:
        if len(RECORDS) >= TARGET:
            break
        newconv, changed = paraphrase_first_user(r["conversation"])
        if not changed:
            continue
        turns = [(m["role"], m["content"]) for m in newconv]
        sig = hashlib.sha1(("|".join(f"{ro}:{c}" for ro, c in turns)).encode()).hexdigest()
        if sig in _SEEN:
            continue
        _SEEN.add(sig)
        RECORDS.append({**{k: v for k, v in r.items() if k not in ("conversation",)},
                        "conversation": newconv, "augmented": True})

# assign ids
for k, r in enumerate(RECORDS, start=1):
    r["id"] = f"paytm_{k:06d}"

# ---------------------------------------------------------------- split (no leakage)
def bucket(group_id):
    h = int(hashlib.sha256(group_id.encode()).hexdigest(), 16) % 100
    return "train" if h < 70 else ("validation" if h < 85 else "test")
for r in RECORDS:
    r["split"] = bucket(r["group_id"])

# rewards: not applicable to a Paytm statement (no Membership Rewards section)
open(os.path.join(OUTDIR,"rewards_reasoning.jsonl"),"w").close()

# ---------------------------------------------------------------- write category files
def write_jsonl(path, recs):
    with open(path,"w") as f:
        for r in recs:
            f.write(json.dumps(r, ensure_ascii=False)+"\n")

by_cat = defaultdict(list)
for r in RECORDS: by_cat[r["category"]].append(r)
CATFILE = {
  "single_turn":"single_turn.jsonl","multi_turn":"multi_turn.jsonl",
  "context_resolution":"context_resolution.jsonl","reference_resolution":"reference_resolution.jsonl",
  "temporal_reasoning":"temporal_reasoning.jsonl","numerical_reasoning":"numerical_reasoning.jsonl",
  "transaction_reasoning":"transaction_reasoning.jsonl","long_context":"long_context.jsonl",
  "hard_cases":"hard_cases.jsonl","policy_reasoning":"policy_reasoning.jsonl",
}
for cat, fn in CATFILE.items():
    write_jsonl(os.path.join(OUTDIR, fn), by_cat.get(cat, []))

# combined + splits
write_jsonl(os.path.join(OUTDIR,"penny_100k_context.jsonl"), RECORDS)
for sp in ("train","validation","test"):
    write_jsonl(os.path.join(OUTDIR, ("validation.jsonl" if sp=="validation" else sp+".jsonl")),
                [r for r in RECORDS if r["split"]==sp])

# markdown sample (first 60 conversations, varied categories)
sample = []
seen_cat = Counter()
for r in RECORDS:
    if seen_cat[r["category"]] < 6:
        sample.append(r); seen_cat[r["category"]] += 1
    if len(sample) >= 60: break
with open(os.path.join(OUTDIR,"penny_100k_context_qa.md"),"w") as f:
    f.write("# Penny MLX — paytm.pdf Contextual QA Dataset (sample)\n\n")
    f.write("Every answer below is computed from `data/paytm_document.json` (the reconciled "
            "extraction of paytm.pdf). Source of truth: **paytm.pdf**.\n\n")
    for k, r in enumerate(sample, 1):
        f.write(f"## Conversation {k:05d}  ·  _{r['category']} / {r['reasoning_type']}_  ·  pages {r['source_pages']}\n\n")
        for m in r["conversation"]:
            f.write(f"### {m['role'].title()}\n{m['content']}\n\n")
        f.write("---\n\n")

# ---------------------------------------------------------------- stats
stats = {
  "total_examples": len(RECORDS),
  "distinct_examples": DISTINCT_COUNT,
  "augmented_examples": sum(1 for r in RECORDS if r.get("augmented")),
  "by_category": {c: len(v) for c, v in sorted(by_cat.items())},
  "by_split": dict(Counter(r["split"] for r in RECORDS)),
  "multi_turn_examples": sum(1 for r in RECORDS if len(r["conversation"]) > 2),
  "single_turn_examples": sum(1 for r in RECORDS if len(r["conversation"]) == 2),
  "avg_turns": round(sum(len(r["conversation"]) for r in RECORDS)/len(RECORDS), 2),
  "max_turns": max(len(r["conversation"]) for r in RECORDS),
  "unique_groups": len({r["group_id"] for r in RECORDS}),
  "source_document": "paytm.pdf",
  "canonical_json": "data/paytm_document.json",
  "note_rewards": "rewards_reasoning.jsonl intentionally empty — a Paytm savings statement has no Membership Rewards section.",
  "note_augmentation": "augmented=True records paraphrase only the first user turn (answers untouched, still grounded); prune them for a distinct-only set.",
}
json.dump(stats, open(os.path.join(OUTDIR,"dataset_stats.json"),"w"), indent=2, ensure_ascii=False)
print(json.dumps(stats, indent=2, ensure_ascii=False))
