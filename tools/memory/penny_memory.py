#!/usr/bin/env python3
"""
Penny MLX — conversation-aware retriever + entity memory (brief §20-22).

Pipeline per user turn:
    user text
      -> ReferenceResolver     (resolve pronouns / relational refs using EntityMemory)
      -> Retriever             (fetch grounded facts: resolved txn, or conversation-aware search,
                                or computed aggregate / account facts)
      -> PennyAgent.generate   (LLM answers ONLY from the grounded context)
      -> EntityMemory.update   (validated: only real document entities are stored)

The resolver is deterministic and grounded so pronoun/relational references ("it", "that",
"the previous one", "the largest", "go back to the first one") map to concrete transactions
without a blind text search — the exact failure the naive retriever had on follow-up turns.

Importable without MLX (resolution/retrieval only); the LLM is lazy-loaded in PennyAgent.
"""
import json, os, re
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DOC_PATH = os.path.join(ROOT, "data", "paytm_document.json")
BASE_MODEL = "mlx-community/Llama-3.2-3B-Instruct-4bit"
# The context-trained LoRA (skills in the weights); combine with memory (facts at inference).
CTX_ADAPTER = os.path.join(ROOT, "data", "paytm_mlx_ctx", "adapters", "best_ctx")


def inr(x):
    neg = x < 0; x = abs(round(float(x), 2)); s = f"{x:.2f}"; ip, dec = s.split(".")
    if len(ip) > 3:
        last3 = ip[-3:]; rest = ip[:-3]; g = []
        while len(rest) > 2: g.insert(0, rest[-2:]); rest = rest[:-2]
        if rest: g.insert(0, rest)
        ip = ",".join(g) + "," + last3
    return ("-" if neg else "") + "₹" + ip + "." + dec

def norm_money(s): return s.replace(" ", "").replace("₹", "").replace("Rs.", "").replace("Rs", "")


# --------------------------------------------------------------------------- Document
class Document:
    def __init__(self, path=DOC_PATH):
        d = json.load(open(path))
        self._build(d["transactions"], d["account_summary"], d["account"],
                    d.get("fixed_deposits", {}), source="paytm.pdf", symbol="₹")

    # ---- generic loader: build a Document from the app's uploaded records ----
    @classmethod
    def from_records(cls, records, source="uploaded statement", symbol="₹", account=None):
        obj = cls.__new__(cls)
        tx = cls._normalize(records)
        credits = [t for t in tx if t["direction"] == "credit"]
        debits = [t for t in tx if t["direction"] == "debit"]
        bals = [t["available_balance"] for t in tx if t["available_balance"] is not None]
        opening = None
        if tx and tx[0]["available_balance"] is not None:
            signed = tx[0]["amount"] if tx[0]["direction"] == "credit" else -tx[0]["amount"]
            opening = round(tx[0]["available_balance"] - signed, 2)
        summ = {"opening_balance": opening, "closing_balance": (bals[-1] if bals else None),
                "total_deposit": round(sum(t["amount"] for t in credits), 2),
                "total_withdrawal": round(sum(t["amount"] for t in debits), 2)}
        acc = account or {"account_holder": "—", "account_number": "—", "account_type": "Statement",
                          "ifsc": "—", "micr": "—", "interest_rate": "—", "nominee": "—", "opened_on": "—",
                          "statement_period": {"from": (tx[0]["date_raw"] if tx else "—"),
                                               "to": (tx[-1]["date_raw"] if tx else "—")}, "bank": source}
        obj._build(tx, summ, acc, {}, source, symbol)
        return obj

    @staticmethod
    def _normalize(records):
        import datetime as _dt
        def pdate(s):
            s = str(s or "").strip()
            for f in ("%Y-%m-%d", "%d %b %Y", "%d/%m/%Y", "%d-%m-%Y", "%m/%d/%Y", "%d %B %Y", "%Y/%m/%d"):
                try:
                    d = _dt.datetime.strptime(s, f); return d.date().isoformat(), d.strftime("%d %b %Y")
                except Exception: pass
            return s, s
        def num(v):
            try: return float(str(v).replace(",", "")) if v not in (None, "") else None
            except Exception: return None
        rows = []
        for r in records:
            rows.append({"date": r.get("date") or r.get("Date"),
                         "desc": (r.get("description") or r.get("Description") or "").strip(),
                         "payee": (r.get("payee") or r.get("counterparty") or "").strip(),
                         "amt": num(r.get("amount", r.get("Amount"))),
                         "bal": num(r.get("balance", r.get("Balance"))),
                         "cat": r.get("category") or r.get("Category")})
        opening_bal = None; kept = []
        for x in rows:
            if "opening balance" in (x["desc"] or "").lower():
                opening_bal = x["bal"] if x["bal"] is not None else x["amt"]   # seed running balance
                continue
            kept.append(x)
        rows = kept
        tx = []; prev_bal = opening_bal
        for i, x in enumerate(rows, 1):
            iso, raw = pdate(x["date"])
            amount = abs(x["amt"]) if x["amt"] is not None else None
            if x["bal"] is not None and prev_bal is not None:            # running balance = ground truth
                delta = round(x["bal"] - prev_bal, 2)
                direction = "credit" if delta > 0 else "debit"
                if amount is None or abs(abs(delta) - amount) > 0.01: amount = abs(delta)
            elif x["amt"] is not None:
                direction = "debit" if x["amt"] < 0 else "credit"; amount = abs(x["amt"])
            else:
                direction = "debit"; amount = 0.0
            if x["bal"] is not None: prev_bal = x["bal"]
            tx.append({"index": i, "date": iso, "date_raw": raw, "time": None,
                       "type": x["cat"] or ("Credit" if direction == "credit" else "Debit"),
                       "direction": direction, "amount": round(amount, 2),
                       "available_balance": (round(x["bal"], 2) if x["bal"] is not None else None),
                       "counterparty": (x["payee"] or x["desc"] or None), "vpa": None, "account_ref": None,
                       "bank_code": None, "transaction_id": f"T{i:05d}", "reference_number": None,
                       "reference_type": None, "payer_mobile": None, "remarks": None,
                       "description": x["desc"], "page": None})
        return tx

    def _build(self, tx, summary, acc, fd, source, symbol="₹"):
        self.tx = tx; self.summary = summary; self.acc = acc; self.fd = fd or {}
        self.source = source; self.symbol = symbol
        self.by_id = {t["transaction_id"]: t for t in self.tx}
        self.by_date = defaultdict(list); self.by_cp = defaultdict(list); self.by_type = defaultdict(list)
        for t in self.tx:
            self.by_date[t["date"]].append(t)
            if t.get("counterparty"): self.by_cp[t["counterparty"]].append(t)
            self.by_type[t["type"]].append(t)
        self.dates = sorted(self.by_date)
        self.credits = [t for t in self.tx if t["direction"] == "credit"]
        self.debits = [t for t in self.tx if t["direction"] == "debit"]
        self.tot_credit = round(sum(t["amount"] for t in self.credits), 2)
        self.tot_debit = round(sum(t["amount"] for t in self.debits), 2)
        self._tok = [(t, self._tokens(t)) for t in self.tx]

    def money(self, v):
        """Currency-aware, None-safe formatter (₹ default; app may pass its own symbol)."""
        if v is None: return "n/a"
        s = inr(v)
        return s if self.symbol == "₹" else s.replace("₹", self.symbol)

    # relational helpers
    def at(self, index):  # 1-based
        return self.tx[index-1] if 1 <= index <= len(self.tx) else None
    def neighbour(self, t, delta):
        return self.at(t["index"] + delta)
    def largest(self, direction=None):
        pool = self.tx if direction is None else [x for x in self.tx if x["direction"] == direction]
        return max(pool, key=lambda x: x["amount"]) if pool else None
    def smallest(self, direction=None):
        pool = self.tx if direction is None else [x for x in self.tx if x["direction"] == direction]
        return min(pool, key=lambda x: x["amount"]) if pool else None

    def _tokens(self, t):
        toks = set()
        if t.get("counterparty"): toks |= {w.lower() for w in t["counterparty"].split()}
        toks |= {norm_money(inr(t["amount"])), norm_money(inr(t["available_balance"]))}
        toks |= {w.lower() for w in t["date_raw"].split()}
        if t.get("time"): toks.add(t["time"].lower().replace(" ", ""))
        toks.add(t["transaction_id"].lower())
        return toks

    def search(self, query, k=1):
        qn = query.lower(); qm = norm_money(qn)
        scored = []
        for t, toks in self._tok:
            s = sum(1 for tk in toks if tk and (tk in qn or tk in qm))
            if s: scored.append((s, t["index"], t))
        scored.sort(key=lambda z: (-z[0], z[1]))
        return [t for _, _, t in scored[:k]]

    # rendering
    def render_txn(self, t):
        return ("Statement entry:\n"
                f"- Date/time: {t['date_raw']} {t.get('time','')}\n"
                f"- Type/rail: {t['type']} ({t['direction']})\n"
                f"- Counterparty: {t.get('counterparty','-')}"
                + (f" (VPA {t['vpa']})" if t.get('vpa') else "") + "\n"
                f"- Amount: {self.money(t['amount'])}\n"
                f"- Balance after: {self.money(t.get('available_balance'))}\n"
                f"- Transaction ID: {t['transaction_id']}"
                + (f"\n- Reference: {t['reference_number']}" if t.get('reference_number') else "")
                + (f"\n- Bank: {t['bank_code']}" if t.get('bank_code') else ""))

    def one_line(self, t):
        cp = t.get("counterparty")
        verb = "paid" if t["type"].startswith("Paid using") else ("received" if t["direction"] == "credit" else "sent")
        prep = "at" if verb == "paid" else ("from" if t["direction"] == "credit" else "to")
        s = f"You {verb} {self.money(t['amount'])}"
        if cp: s += f" {prep} {cp}"
        s += f" on {t['date_raw']}"
        if t.get("time"): s += f" at {t['time']}"
        s += f" ({t['type']})."
        if t.get("available_balance") is not None:
            s += f" Balance afterwards: {self.money(t['available_balance'])}."
        return s

    def day_summary(self, day):
        dr = day[0]["date_raw"]
        parts = []
        for t in day[:8]:
            v = "received" if t["direction"] == "credit" else ("paid" if t["type"].startswith("Paid using") else "sent")
            who = (f" {'from' if t['direction']=='credit' else 'to'} {t['counterparty']}") if t.get("counterparty") else ""
            tm = (t.get("time") + " ") if t.get("time") else ""
            parts.append(f"{tm}{v} {self.money(t['amount'])}{who}")
        more = f" …and {len(day)-8} more." if len(day) > 8 else ""
        return f"On {dr} there were {len(day)} transactions: " + "; ".join(parts) + "." + more

    def account_facts(self):
        a = self.acc; s = self.summary
        return ("Account facts: "
                f"holder {a.get('account_holder','—')}; number {a.get('account_number','—')}; "
                f"type {a.get('account_type','—')}; IFSC {a.get('ifsc','—')}; "
                f"interest {a.get('interest_rate','—')} p.a.; "
                f"period {a['statement_period']['from']} to {a['statement_period']['to']}; "
                f"opening {self.money(s.get('opening_balance'))}; closing {self.money(s.get('closing_balance'))}; "
                f"total received {self.money(self.tot_credit)}; total paid out {self.money(self.tot_debit)}; "
                f"{len(self.tx)} transactions.")


# --------------------------------------------------------------------------- Entity memory (state)
class EntityMemory:
    def __init__(self):
        self.active = None           # current transaction in focus
        self.previous = None         # the one before it in the dialogue
        self.history = []            # txns discussed, in first-mention order (deduped)
        self.current_date = None
        self.current_merchant = None
        self.important_facts = []
        self.summary = ""

    def focus(self, t):
        """Set active entity (validated: caller passes a real Document txn)."""
        if t is None: return
        if self.active and (not self.history or self.history[-1] is not self.active):
            pass
        self.previous = self.active
        self.active = t
        if not self.history or self.history[-1] is not t:
            # keep unique by id but preserve order
            if all(h["transaction_id"] != t["transaction_id"] for h in self.history):
                self.history.append(t)
        self.current_date = t.get("date_raw")
        self.current_merchant = t.get("counterparty")

    def reset(self):
        self.active = None; self.previous = None; self.current_date = None; self.current_merchant = None

    def state(self):
        return {"active": self.active["transaction_id"] if self.active else None,
                "previous": self.previous["transaction_id"] if self.previous else None,
                "history": [h["transaction_id"] for h in self.history],
                "current_date": self.current_date, "current_merchant": self.current_merchant}


# --------------------------------------------------------------------------- Reference resolver
ORD_WORDS = {"first":1,"second":2,"third":3,"fourth":4,"fifth":5,"sixth":6,"seventh":7,
             "eighth":8,"ninth":9,"tenth":10,"last":-1}
PRONOUNS = re.compile(r"\b(it|its|it's|that|this|the one|them|they|their|the same)\b", re.I)

class Resolution:
    def __init__(self, kind, target=None, targets=None, intent=None, message=None, note=None):
        self.kind = kind          # 'txn' | 'aggregate' | 'policy' | 'temporal' | 'ambiguous' | 'reset' | 'general'
        self.target = target      # a resolved transaction (dict)
        self.targets = targets or []
        self.intent = intent
        self.message = message    # for 'ambiguous' -> clarification text
        self.note = note          # how it was resolved (debug/trace)

class ReferenceResolver:
    def __init__(self, doc): self.doc = doc

    def _find_date(self, text):
        m = re.search(r"\b(\d{1,2})\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s*(\d{4})?", text, re.I)
        if not m: return None
        dd = int(m.group(1)); mon = m.group(2).title()[:3]; yyyy = m.group(3) or "2023"
        months = {m2:i for i,m2 in enumerate(["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"],1)}
        iso = f"{yyyy}-{months[mon]:02d}-{dd:02d}"
        return iso if iso in self.doc.by_date else None

    def _explicit_descriptor(self, text):
        """A concrete transaction named by counterparty/amount/time/id in THIS turn.
        A DATE alone is NOT a descriptor (many txns share a date) — it only adds specificity."""
        m = re.search(r"\b([SM]\d{4,})\b", text)
        if m and m.group(1) in self.doc.by_id:
            return self.doc.by_id[m.group(1)]
        low = text.lower(); qm = norm_money(low); nsp = low.replace(" ", "")
        date_iso = self._find_date(low)
        best = None; best_score = 0; tied = False; best_key = None
        for t in self.doc.tx:
            cp = t.get("counterparty")
            cp_hit = bool(cp) and cp.lower() in low
            amt_hit = norm_money(inr(t["amount"])) in qm
            time_hit = bool(t.get("time")) and t["time"].lower().replace(" ", "") in nsp
            date_hit = date_iso == t["date"]
            if not (cp_hit or amt_hit or time_hit):      # must have a NON-date identifier
                continue
            score = (2 if cp_hit else 0) + (1 if amt_hit else 0) + (1 if time_hit else 0) + (1 if date_hit else 0)
            key = (cp_hit, amt_hit, time_hit, date_hit)
            if score > best_score:
                best_score = score; best = t; best_key = key; tied = False
            elif score == best_score and t is not best:
                tied = True
        if best is None or best_score < 2:
            return None
        # ambiguity: identified only by a counterparty that recurs, with no other signal -> not unique
        cp_only = best_key == (True, False, False, False)
        if cp_only and len(self.doc.by_cp.get(best["counterparty"], [])) > 1:
            return None
        if tied:
            return None
        return best

    def resolve(self, text, mem: EntityMemory):
        t = text.strip(); low = t.lower()

        # 0. reset / new topic  (strip the reset clause, then re-resolve the remainder with cleared memory)
        reset_pat = r"(?i)\b(forget (that|it|all(?: that| of that| of this)?|everything|what[^.?!]*|the previous[^.?!]*)|ignore what[^.?!]*|start over|new topic|let'?s start (fresh|over)|reset|clear (that|the) context)\b[.,]?"
        if re.search(reset_pat, low):
            mem.reset()
            remainder = re.sub(reset_pat, "", t).strip(" .,-")
            if len(remainder.split()) >= 2:
                return self.resolve(remainder, mem)
            return Resolution("reset", message="Okay — starting fresh. What would you like to know?")

        # 1. explicit switch-back to something discussed
        if re.search(r"\b(go back to|back to|return to|earlier you mentioned|the .* we (discussed|talked about)|first (one|transaction) we)\b", low):
            if re.search(r"\bfirst\b", low) and mem.history:
                return Resolution("txn", target=mem.history[0], note="switch:first-discussed")
            if re.search(r"\blast\b", low) and mem.history:
                return Resolution("txn", target=mem.history[-1], note="switch:last-discussed")
            d = self._explicit_descriptor(t)
            if d: return Resolution("txn", target=d, note="switch:descriptor")
            if mem.history: return Resolution("txn", target=mem.history[0], note="switch:default-first")

        # 2. explicit descriptor in this turn (new entity)
        d = self._explicit_descriptor(t)
        if d and not PRONOUNS.search(low):
            return Resolution("txn", target=d, note="explicit-descriptor")

        # 3. superlatives
        if re.search(r"\b(largest|biggest|highest|max(imum)?)\b", low):
            direction = "credit" if re.search(r"\b(credit|received|money in|deposit)\b", low) else ("debit" if re.search(r"\b(debit|spent|sent|paid|money out|withdraw)\b", low) else None)
            return Resolution("txn", target=self.doc.largest(direction), note=f"superlative:largest:{direction}")
        if re.search(r"\b(smallest|lowest|min(imum)?)\b", low):
            direction = "credit" if re.search(r"\b(credit|received|money in|deposit)\b", low) else ("debit" if re.search(r"\b(debit|spent|sent|paid|money out|withdraw)\b", low) else None)
            return Resolution("txn", target=self.doc.smallest(direction), note=f"superlative:smallest:{direction}")

        # 4. relational to active — ONLY when the reference is to a transaction, not phrases like
        #    "balance after it" (which must resolve to the active entity, not the next txn).
        if mem.active:
            PREV = r"\b(previous(?: transaction| one| payment)?|the one before|one before|transaction before|payment before|before that|preceding(?: transaction| one)?|prior transaction)\b"
            NEXT = r"\b(next(?: transaction| one| payment)?|the one after|one after|after that|following(?: transaction| one)?|subsequent (?:transaction|one))\b"
            if re.search(PREV, low):
                nb = self.doc.neighbour(mem.active, -1)
                if nb: return Resolution("txn", target=nb, note="relative:previous")
            if re.search(NEXT, low):
                nb = self.doc.neighbour(mem.active, +1)
                if nb: return Resolution("txn", target=nb, note="relative:next")

        # 5. ordinal within a day / first-last of statement
        iso = self._find_date(low)
        m = re.search(r"\b(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|last)\b", low)
        if m:
            n = ORD_WORDS[m.group(1)]
            day_iso = iso
            if not day_iso and mem.active and re.search(r"\b(of|that|the)\s+day\b|that day\b", low):
                day_iso = mem.active["date"]        # "the second transaction of the day" -> active's day
            if day_iso:
                day = self.doc.by_date[day_iso]
                tgt = day[-1] if n == -1 else (day[n-1] if 1 <= n <= len(day) else None)
                if tgt: return Resolution("txn", target=tgt, note=f"ordinal-of-day:{n}")
            if re.search(r"\b(transaction|one)\b", low) and not iso:
                if mem.history and re.search(r"\b(we|you|discuss|talked|asked|mentioned)\b", low):
                    return Resolution("txn", target=(mem.history[-1] if n==-1 else mem.history[min(n-1,len(mem.history)-1)]), note="ordinal-discussed")
                tgt = self.doc.tx[-1] if n == -1 else self.doc.at(n)
                if tgt: return Resolution("txn", target=tgt, note=f"ordinal-of-statement:{n}")

        # 6. policy / account questions
        if re.search(r"\b(interest rate|ifsc|micr|account number|nominee|opened|holder|who holds|insured|dicgc|closing balance|opening balance|statement period|account type)\b", low):
            return Resolution("policy", intent="policy", note="policy")

        # 7. aggregate questions
        if re.search(r"\b(total|how many|sum|altogether|in total|overall|average|net (change|movement))\b", low):
            return Resolution("aggregate", intent="aggregate", note="aggregate")

        # 8. temporal 'what happened on <date>'
        if iso and re.search(r"\b(what happened|activity|transactions?)\b", low):
            return Resolution("temporal", intent="temporal", targets=self.doc.by_date[iso], note="temporal-day")
        if iso and not mem.active:
            return Resolution("temporal", intent="temporal", targets=self.doc.by_date[iso], note="temporal-day2")

        # 9. pronoun / implicit follow-up about the active entity
        field_followup = re.search(r"\b(how much|amount|when|what time|balance|who|which bank|reference|txn id|transaction id|rail|method|credit or debit|money in or out)\b", low)
        if PRONOUNS.search(low) or field_followup:
            if mem.active:
                return Resolution("txn", target=mem.active, note="pronoun->active")
            return Resolution("ambiguous",
                              message="Which transaction do you mean? We haven't focused on one yet — "
                                      "name a merchant, amount, date, or say e.g. 'the largest debit'.",
                              note="pronoun-no-active")

        # 10. fallback: conversation-aware search using this turn + active context
        ctxq = t
        if mem.active:
            ctxq += " " + mem.active.get("counterparty","") + " " + mem.active.get("date_raw","")
        hits = self.doc.search(ctxq, k=1)
        if hits: return Resolution("txn", target=hits[0], note="fallback-search")
        return Resolution("general", note="general")


# --------------------------------------------------------------------------- Retriever (context assembly)
class Retriever:
    def __init__(self, doc): self.doc = doc

    def context_for(self, res: Resolution, mem: EntityMemory):
        parts = [self.doc.account_facts()]
        if res.kind == "txn" and res.target:
            # ONLY the resolved focus entry — pronouns/relations were already resolved by the
            # resolver, so we must not inject competing neighbour balances.
            parts.append("Focus transaction (the question is about THIS entry):\n" + self.doc.render_txn(res.target))
        elif res.kind == "temporal" and res.targets:
            day = res.targets
            lines = [f"{i+1}. {t['date_raw']} {t.get('time','')} — {t['type']} {self.doc.money(t['amount'])} ({t['direction']}) "
                     f"{t.get('counterparty','')} -> bal {self.doc.money(t.get('available_balance'))}" for i,t in enumerate(day)]
            parts.append(f"All {len(day)} transactions on {day[0]['date_raw']}:\n" + "\n".join(lines))
        elif res.kind == "aggregate":
            parts.append(self._aggregates())
        # policy uses account_facts already
        return "\n".join(parts)

    def _aggregates(self):
        d = self.doc
        by_type = "; ".join(f"{k}: {len(v)} txns, {d.money(sum(x['amount'] for x in v))}" for k,v in d.by_type.items())
        return (f"Aggregates: {len(d.credits)} credits totalling {d.money(d.tot_credit)}; "
                f"{len(d.debits)} debits totalling {d.money(d.tot_debit)}; "
                f"net {d.money(round(d.tot_credit-d.tot_debit,2))}. By type — {by_type}.")


# --------------------------------------------------------------------------- Agent
SYSTEM = ("You are Penny, a precise assistant for a bank statement. Answer ONLY using the "
          "statement facts provided. Be concise and exact; include the exact amount/date/name asked. "
          "Pronouns like 'it', 'that', 'this', 'its' refer to the FOCUS transaction shown. "
          "If the facts don't contain the answer, say you don't have it.")

class PennyAgent:
    def __init__(self, doc=None, use_llm=True, model=None, tok=None, adapter_path=None):
        self.doc = doc or Document()
        self.mem = EntityMemory()
        self.resolver = ReferenceResolver(self.doc)
        self.retriever = Retriever(self.doc)
        self.use_llm = use_llm
        self.adapter_path = adapter_path      # e.g. CTX_ADAPTER -> combined stack
        self._model = model; self._tok = tok

    def _ensure_llm(self):
        if self._model is None:
            from mlx_lm import load
            if self.adapter_path and os.path.isdir(self.adapter_path):
                self._model, self._tok = load(BASE_MODEL, adapter_path=self.adapter_path)
            else:
                self._model, self._tok = load(BASE_MODEL)

    @staticmethod
    def _operative(question):
        """The actual field question, dropping navigational preamble the stateless LLM can't
        interpret (e.g. 'Go back to the first transaction we discussed. What was its balance?')."""
        sents = [s.strip() for s in re.split(r"(?<=[.?!])\s+", question.strip()) if s.strip()]
        if len(sents) <= 1:
            return question.strip()
        qs = [s for s in sents if s.endswith("?")]
        return (qs[-1] if qs else sents[-1])

    # ---- field detection + grounded values (brief §21: never emit a hallucinated fact) ----
    @staticmethod
    def _field(question):
        q = question.lower()
        if re.search(r"\b(transaction id|txn id|transaction identifier|\bid\b)\b", q): return "txn_id"
        if re.search(r"\breference( number| no)?\b", q): return "reference"
        if re.search(r"\bbalance\b", q): return "balance"
        if re.search(r"\b(what time|at what time|time of day|which time|when (did|was)|on (what|which) (date|day)|what date)\b", q): return "time"
        if re.search(r"\b(who|whom|merchant|payee|sender|recipient|which party|from whom)\b", q): return "counterparty"
        if re.search(r"\b(how much|amount|what sum|value of|how many rupees)\b", q): return "amount"
        if re.search(r"\b(vpa|upi id)\b", q): return "vpa"
        if re.search(r"\b(which bank|bank code|ifsc of)\b", q): return "bank_code"
        return None

    def _expected(self, t, field):
        m = self.doc.money
        if field == "balance":
            if t.get("available_balance") is None: return None, None
            return m(t["available_balance"]), f"The balance right after that transaction was {m(t['available_balance'])}."
        if field == "amount": return m(t["amount"]), f"That transaction was {m(t['amount'])} ({t['direction']})."
        if field == "txn_id": return t["transaction_id"], f"Its transaction ID is {t['transaction_id']}."
        if field == "time" and t.get("time"): return t["time"], f"It happened at {t['time']} on {t['date_raw']}."
        if field == "counterparty" and t.get("counterparty"):
            return t["counterparty"], f"It was {'from' if t['direction']=='credit' else 'to'} {t['counterparty']}."
        if field == "reference" and t.get("reference_number"): return t["reference_number"], f"Its reference number is {t['reference_number']}."
        if field == "vpa" and t.get("vpa"): return t["vpa"], f"The UPI ID was {t['vpa']}."
        if field == "bank_code" and t.get("bank_code"): return t["bank_code"], f"The bank was {t['bank_code']}."
        return None, None

    @staticmethod
    def _contains(field, value, ans):
        a = ans.lower()
        if field in ("amount", "balance"):
            return re.sub(r"[^0-9.]", "", value) in re.sub(r"[^0-9.]", "", norm_money(ans))
        if field == "counterparty":
            v = value.lower(); return v in a or v.split()[0] in a
        return value.lower() in a

    def _answer(self, res, question, max_tokens):
        # Deterministic templating where the memory system already knows the exact answer —
        # keeps quality independent of LLM verbosity (the context-LoRA is terse and flubs these).
        if res.kind == "temporal" and res.targets:
            return self.doc.day_summary(res.targets)
        if res.kind == "txn" and res.target:
            field = self._field(question)
            if field is None:                       # identify / describe -> template one-liner
                return self.doc.one_line(res.target)
            if field in ("amount", "balance"):       # currency -> template (exact value + correct symbol;
                value, grounded = self._expected(res.target, field)   # avoids the LoRA's ₹ bias)
                if grounded: return grounded
            # other exact fields -> LLM (context-LoRA) generates, grounding guard corrects
            self._ensure_llm()
            from mlx_lm import generate
            msgs = [{"role":"system","content":SYSTEM},
                    {"role":"user","content":self._ctx + "\n\nQuestion: " + self._operative(question)}]
            ans = generate(self._model, self._tok,
                           prompt=self._tok.apply_chat_template(msgs, add_generation_prompt=True),
                           max_tokens=max_tokens, verbose=False).strip()
            value, grounded = self._expected(res.target, field)
            if value and not self._contains(field, value, ans):
                ans = grounded
            return ans
        # policy / aggregate / general -> LLM with grounded context
        self._ensure_llm()
        from mlx_lm import generate
        msgs = [{"role":"system","content":SYSTEM},
                {"role":"user","content":self._ctx + "\n\nQuestion: " + self._operative(question)}]
        return generate(self._model, self._tok,
                        prompt=self._tok.apply_chat_template(msgs, add_generation_prompt=True),
                        max_tokens=max_tokens, verbose=False).strip()

    def ask(self, question, max_tokens=64):
        """Full turn: resolve -> retrieve -> generate -> update memory. Returns a dict."""
        res = self.resolver.resolve(question, self.mem)
        trace = {"resolved_kind": res.kind, "note": res.note,
                 "target": res.target["transaction_id"] if res.target else None,
                 "state_before": self.mem.state()}
        if res.kind == "ambiguous":
            return {"answer": res.message, "clarify": True, **trace}
        if res.kind == "reset":
            return {"answer": res.message, "reset": True, **trace}
        context = self.retriever.context_for(res, self.mem)
        # update memory BEFORE answering so pronouns in the SAME answer resolve, and future turns see it
        if res.kind == "txn" and res.target:
            self.mem.focus(res.target)
        elif res.kind == "temporal" and res.targets:
            self.mem.focus(res.targets[0])
        if self.use_llm:
            self._ctx = context
            answer = self._answer(res, question, max_tokens=max_tokens)
        else:
            answer = context  # resolution-only mode (for testing without the model)
        return {"answer": answer, "context": context, "state_after": self.mem.state(), **trace}
