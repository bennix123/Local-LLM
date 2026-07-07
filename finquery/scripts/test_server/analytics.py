import re, sqlite3, json, urllib.request
from src.services import txn_store as ts
from src.services.txn_store import (
    DISCRETIONARY, SUBSCRIPTION_MERCHANTS, advice_facts, inr, grp, USER
)
from src.services import ml_insights as ml
from .router import (
    _known_merchants,
    _ML_CACHE,
    _RISK_RE, _HEALTH_RE, _CATTREND_RE, _RECUR_RE, _NUM_MULT, _WHICH_MONTHS_RE, _PCT_RE, _BEHAVE_RE, _FCAST_RE, _ANOM_RE, _AMT_RE, _WHY_RE, _CONCEPTS, _MON_RE, _RECUR_DEFER, _PROJ_RE, _IMPACT_RE, _PATTERN_RE,
    _find_categories, _find_merchants, _find_periods, _parse_amount, _parse_period,
    _period_phrase, _list_entity, _resolve_merchant,
    # Regexes and globals exported from router
    _CMP_WORD_RE, _DATELOOKUP_RE, _METRIC_RE, _FILTER_RE, _AMT_CMP_RE, _ARGMAX_ENT_RE,
    _CANON, _CANON_TOPN, _CONT_RE, _REFS_RE, _EXP_CTXT, _TOP_RE, _BIG_RE, _SMALL_RE,
    _COUNT_X, _INCOME_RE2, _SPEND_RE, _LIST_RE, _WHICH_TXN_RE, _LIST_N_RE, _BAL_RE
)

def _llm_words(system, user):
    from .server import OLLAMA_URL, LLM_MODEL, _nd
    """Stream the LLM reply from Ollama, buffered into whole words."""
    payload = json.dumps({
        "model": LLM_MODEL, "stream": True, "keep_alive": "10m",
        "options": {"temperature": 0.3, "num_predict": 80, "top_p": 0.9, "num_ctx": 2048},
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
    }).encode()
    buf = ""
    try:
        req = urllib.request.Request(f"{OLLAMA_URL}/api/chat", data=payload,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=300) as resp:
            for line in resp:
                line = line.strip()
                if not line:
                    continue
                d = json.loads(line)
                buf += d.get("message", {}).get("content", "")
                while " " in buf:
                    word, buf = buf.split(" ", 1)
                    yield _nd({"type": "chunk", "content": word + " "})
                if d.get("done"):
                    break
        if buf:
            yield _nd({"type": "chunk", "content": buf})
    except Exception as e:
        yield _nd({"type": "chunk", "content": f"\n_({LLM_MODEL} unavailable: {e}.)_"})

def followup_sql_answer(q, ctx):
    """SQL-FIRST grounding for the follow-up path. A referential follow-up ('when were those?',
    'how many of them?', 'which merchant?', 'the biggest one?') is translated into a concrete
    intent scoped to the thread's carried merchant/category/period and answered deterministically
    from SQL — so the number/rows are real, never the LLM's guess. Returns grounded markdown, or
    None to let the LLM handle a genuinely narrative ask ('why…', 'should I…')."""
    if not ctx:
        return None
    low = q.lower()
    mer = (ctx.get("merchant") or "").strip()
    cat = (ctx.get("category") or "").strip()
    start, end = (ctx.get("start") or ""), (ctx.get("end") or "")
    if not (mer or cat or start):
        return None                               # nothing carried to ground on
    # genuinely narrative / judgemental -> let the LLM reason (grounded-advice covers 'why')
    if re.search(r"\bwhy\b|\bhow come\b|\bexplain\b|\bshould i\b|\bworth it\b|\bgood or bad\b|\bnormal\b", low):
        return None
    base = {"merchant": mer, "category": cat, "start": start, "end": end, "n": 0}
    intent = None
    if re.search(r"\bwhen\b|\bwhat date|\bwhich date|\bwhat day\b|\bon what day\b|\bdates?\b", low) and mer:
        dd = ("last" if re.search(r"\b(last|latest|most recent|recently)\b", low)
              else "first" if re.search(r"\b(first|earliest)\b", low) else "")
        intent = {**base, "type": "merchant_date", "date_dir": dd}
    elif re.search(r"\bhow many\b|\bnumber of\b|\bno\.? of\b|\bcount\b|\bhow often\b", low):
        intent = {**base, "type": "count"}
    elif re.search(r"\b(biggest|largest|highest|most expensive|priciest|dearest)\b", low):
        intent = {**base, "type": "largest_expense"}
    elif re.search(r"\b(smallest|lowest|cheapest|least expensive)\b", low):
        intent = {**base, "type": "smallest_expense"}
    elif re.search(r"\bwhich (?:merchant|shop|store|place|vendor|company|one)\b|\bwho\b", low):
        if mer:
            return f"That was **{ts._mname(mer)}**."
        intent = {**base, "type": "top_expenses", "n": 1}    # top merchant/expense of the scope
    elif re.search(r"\b(list|show|see|what were|which were|details?|report)\b.*\b(them|those|these|it|they|that|details?)\b|\bdetails?\b", low):
        intent = {**base, "type": "list"}
    elif re.search(r"\bhow much\b|\btotal\b|\baltogether\b|\bin all\b", low):
        intent = {**base, "type": "merchant" if mer else "category" if cat else "spend"}
    if not intent:
        return None
    return ts.dispatch_intent(intent, USER)          # SQL renders every figure; None -> LLM

def followup_response(q, history, thread="default"):
    """Answer a question ABOUT the recent conversation (e.g. 'what is that number?')."""
    convo = "\n".join(f"User: {h['q']}\nPenny: {h['a']}" for h in history[-4:])

    def gen():
        parts = []
        yield _nd({"type": "meta", "path": "chat"})
        for nd in _llm_words(FOLLOWUP_SYSTEM + "\n\nConversation so far:\n" + convo, q):
            parts.append(_txt(nd)); yield nd
        yield _nd({"type": "done"})
        _append_log(thread, q, "".join(parts), "chat")
    return StreamingResponse(gen(), media_type="application/x-ndjson")

def advice_response(q, thread="default"):
    from .server import _append_log, stream_markdown
    """Deterministic insights (exact SQL figures) + one grounded LLM sentence."""
    report, grounding = ts.build_insights(USER)
    snapshot, _ = ts.advice_context(USER)

    def gen():
        parts = []
        yield _nd({"type": "meta", "path": "advice"})
        for nd in stream_markdown(snapshot + "\n\n" + report):
            parts.append(_txt(nd)); yield nd
        yield _nd({"type": "chunk", "content": "\n\n"}); parts.append("\n\n")
        for nd in _llm_words(ADVICE_SYSTEM + "\n\n" + grounding, q):
            parts.append(_txt(nd)); yield nd
        yield _nd({"type": "done"})
        _append_log(thread, q, "".join(parts), "advice")
    return StreamingResponse(gen(), media_type="application/x-ndjson")

def _llm_complete(system, user, num_predict=512, temperature=0.2):
    from .server import OLLAMA_URL, LLM_MODEL
    """One-shot (non-streaming) LLM call -> full text, or None. Retries once so a cold
    model load doesn't surface as a failure."""
    payload = json.dumps({
        "model": LLM_MODEL, "stream": False, "keep_alive": "30m",
        "options": {"temperature": temperature, "num_predict": num_predict,
                    "top_p": 0.9, "num_ctx": 4096},
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": user}],
    }).encode()
    for attempt in (1, 2):
        try:
            req = urllib.request.Request(f"{OLLAMA_URL}/api/chat", data=payload,
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=150) as resp:
                txt = json.loads(resp.read()).get("message", {}).get("content", "")
            return (txt or "").strip() or None
        except Exception as e:
            print(f"[advice] LLM attempt {attempt}/2 failed: {type(e).__name__}: {e}")
    return None

def _amounts_in(s):
    out = []
    for m in _AMT_RE.finditer(s):
        if m.group(1) is not None:
            out.append(float(m.group(1).replace(",", "")))
        else:
            out.append(float(m.group(2).replace(",", "")) * _NUM_MULT.get(m.group(3).lower(), 1))
    return out

def _advice_grounded(reply, facts):
    """True iff every ₹-amount and percentage in `reply` matches one in `facts`
    (amounts within 0.5% or ₹1; percentages within 0.5 pt). Catches the model
    inventing or computing a figure."""
    fa = _amounts_in(facts)
    fp = [float(x) for x in _PCT_RE.findall(facts)]
    for v in _amounts_in(reply):
        if not any(abs(v - f) <= max(1.0, 0.005 * max(v, f)) for f in fa):
            return False, f"amount {v:,.2f} not in facts"
    for v in (float(x) for x in _PCT_RE.findall(reply)):
        if not any(abs(v - f) <= 0.5 for f in fp):
            return False, f"percentage {v}% not in facts"
    return True, ""

def _advice_fallback(q):
    """Concise, fully-deterministic advisory answer (no LLM) — used when the model is
    unavailable or its reply failed the number check. On-topic and short, never a dump."""
    o = ts.overview(USER)
    if o["count"] == 0:
        return "_Upload a statement first._"
    low = q.lower()
    inr, grp = ts.inr, ts.grp
    nmon = max(len(ts.months_list(USER)), 1)
    inc, sp, net = o["credit"], o["debit"], o["net"]
    rate = (net / inc * 100) if inc else 0
    cats = ts.by_category(USER)
    disc = [(c, a) for c, a, _n in cats if c in ts.DISCRETIONARY][:3]

    if re.search(r"\btransactions?\b|biggest impact|impact on (?:my )?(?:financial|finances|health)", low):
        tx = ts.top_expenses(USER, 5)
        if tx:
            body = "; ".join(f"{inr(amt)} to {mer}" for _dt, mer, amt in tx)
            return (f"**Your 5 largest single transactions** — the individual debits with the biggest "
                    f"impact on your balance: {body}. Together with your top merchants (which make up "
                    f"the bulk of spending), these are what most move your financial health.")

    if re.search(r"\b(invest|afford|save (?:more|each|every|per)|how much (?:can|should))\b", low):
        return (f"**You can safely invest around {inr(net / nmon)} a month.** That's your average "
                f"monthly surplus — the income left after all spending — and you already save "
                f"{rate:.1f}% of income ({inr(net)} of {inr(inc)}). A common floor is 20% of income "
                f"({inr(inc / nmon * 0.20)}/month), which you clear comfortably, so directing most of "
                f"that surplus to investments while keeping an emergency buffer is reasonable.")
    if re.search(r"depend|relian|income source|concentrat|diversif", low):
        src = [r for r in ts.income_by_source(USER) if r[1] > 0]
        if src and inc:
            top, amt = src[0][0], src[0][1]
            dep = amt / inc * 100
            v = ("heavily dependent on one source" if dep >= 70 else
                 "fairly concentrated" if dep >= 50 else "reasonably diversified")
            return (f"**{dep:.1f}% of your income comes from {top}** ({inr(amt)} of {inr(inc)}), so "
                    f"you're {v}. Building a second income stream would cushion you if that source paused.")
    if re.search(r"limit|cut|reduce|control|trim|budget|overspend|too much|where can i save", low):
        if disc:
            body = ", ".join(f"{c} ({inr(a)})" for c, a in disc)
            return (f"**Cap your flexible spending first:** {body} — these are the most discretionary "
                    f"categories and the easiest to limit. You spend {inr(sp)} against {inr(inc)} income "
                    f"(a {rate:.1f}% savings rate), so trimming these lifts what you keep.")
    if re.search(r"trend|pattern|observe|notice|insight|how am i|doing|healthy", low):
        bm = ts.by_month(USER)
        extra = ""
        if len(bm) >= 2:
            half = len(bm) // 2
            n1, n2 = half or 1, (len(bm) - half) or 1
            s1, s2 = sum(r[1] for r in bm[:half]) / n1, sum(r[1] for r in bm[half:]) / n2
            extra = f" Average monthly spend moved from {inr(s1)} (first half) to {inr(s2)} (second half)."
        topc = f" Your biggest category is {cats[0][0]} at {inr(cats[0][1])}." if cats else ""
        return (f"**You keep {rate:.1f}% of your income** — saving {inr(net)} of {inr(inc)} over "
                f"{nmon} months.{extra}{topc}")
    line = (f"**At a glance:** income {inr(inc)}, spending {inr(sp)}, net saved {inr(net)} — a "
            f"{rate:.1f}% savings rate over {nmon} months. On average you keep {inr(net / nmon)} a "
            f"month to put toward savings or investment.")
    if disc:
        line += " Your most flexible spending is " + ", ".join(f"{c} ({inr(a)})" for c, a in disc) + "."
    return line

def grounded_advice(q, thread="default", ctx=None):
    from .server import _append_log, stream_text
    """Advisory answer: the LLM reasons over a SQL-computed fact sheet, and every number
    is verified against those facts before going out, else a deterministic fallback.
    `ctx` (thread scope) pins the CURRENT TOPIC with that entity's own fact block."""
    facts = (ts.advice_facts(USER) + _concept_facts()   # + debt/fee/gambling obligations
             + _scoped_facts(ctx))                      # + carried-topic facts (Healthcare…)
    reply = _llm_complete(GROUNDED_ADVICE_SYSTEM + facts, q)
    if reply:
        reply = re.sub(r"^(?:answer|penny)\s*[:\-]\s*", "", reply, flags=re.I).strip()
        ok, why = _advice_grounded(reply, facts)
        if ok:
            _append_log(thread, q, reply, "advice")
            return stream_text("advice", reply)
        print(f"[advice] reply rejected ({why}); using deterministic fallback")
    fb = _advice_fallback(q)
    _append_log(thread, q, fb, "advice")
    return stream_text("advice", fb)

def concept_answer(q):
    """Answer a semantic-concept spend question (see _CONCEPTS) from the ledger merchants
    that match the concept. Markdown, or None if no concept is named. Period comes from
    THIS question only (a concept question is self-contained — no thread scope carried)."""
    low = q.lower()
    if _WHY_RE.search(low):
        return None            # "why …" is a reasoning question — the advice path owns it
    hit = next(((label, mrx) for label, trig, mrx in _CONCEPTS if trig.search(low)), None)
    if hit is None:
        return None
    label, mrx = hit
    # a NAMED stored merchant outranks a concept — "how much on Uber?" is a merchant
    # question even though "uber" also triggers the taxis concept.
    for m in _known_merchants():
        if re.search(r"\b" + re.escape(m.lower()) + r"\b", low):
            return None
    pf = _parse_period(q)
    period, plabel = (ts._norm_period(pf[0], pf[1]) if pf else (None, None))
    sfx = f" in {plabel}" if plabel else ""
    inr, grp = ts.inr, ts.grp

    parts = []
    for m in _known_merchants():
        if mrx.search(m):
            r = ts.merchant_spend(USER, m, None, period)
            if r["dcount"]:
                parts.append((m, r["debit"], r["dcount"]))
    if not parts:
        cov = ts.coverage(USER)
        span = f" Your data covers {ts._mlabel(cov[0])}–{ts._mlabel(cov[1])}." if cov else ""
        return (f"**I couldn't find any {label}-related transactions{sfx}.** "
                f"I checked every merchant in your statement against the concept.{span}")
    parts.sort(key=lambda x: -x[1])
    total = sum(a for _, a, _ in parts)
    n = sum(c for _, _, c in parts)

    # "% of my income goes on <concept>" -> concept spend vs income, same scope
    if (re.search(r"\bpercent\w*\b|%|\bproportion\b|\bshare\b|\bfraction\b", low)
            and re.search(r"\bincome\b|\bsalary\b|\bearn\w*\b", low)):
        inc = ts.overview(USER, None, period)["credit"]
        if not inc:
            return f"**No income recorded{sfx}** — can't compute a percentage."
        return (f"**{label.capitalize()} take {total / inc * 100.0:.1f}% of your income{sfx}** — "
                f"{inr(total)} against {inr(inc)} income  ("
                + ", ".join(f"{m} {inr(a)}" for m, a, _ in parts[:5]) + ").")

    # "how many gambling transactions ..." -> a count, per matched merchant
    if re.search(r"\b(how many|number of|no\.?\s*of|count)\b", low):
        return (f"**{label.capitalize()} transactions{sfx}: {grp(n)}**  ("
                + ", ".join(f"{m} {grp(c)}" for m, _, c in parts) + ")")

    head = f"**{label.capitalize()}{sfx}:** {inr(total)} across {grp(n)} transactions"
    nmon = len(ts.months_list(USER, None, period))
    if nmon > 1:                     # "what loans am I repaying each month?"
        head += f" — about {inr(total / nmon)}/month"
    if len(parts) == 1:
        return head + f"  ({parts[0][0]})"
    return head + "\n\n" + ts._table(
        ["Merchant", "Spent", "Txns"], [(m, inr(a), grp(c)) for m, a, c in parts])

def _concept_facts():
    """Deterministic obligations/habits lines for the advice fact sheet — the debt-shaped
    concept aggregates (loans / fees / gambling) over the whole ledger, so "what debt
    should I pay off first?" / "why was I charged overdraft fees?" reason over REAL
    obligations. '' when nothing matches; every number from SQL."""
    lines = []
    for label, _trig, mrx in _CONCEPTS:
        if label not in ("loan repayments", "bank fees", "gambling"):
            continue
        parts = []
        for m in _known_merchants():
            if mrx.search(m):
                r = ts.merchant_spend(USER, m, None, None)
                if r["dcount"]:
                    parts.append((m, r["debit"], r["dcount"]))
        if parts:
            parts.sort(key=lambda x: -x[1])
            tot = sum(a for _, a, _ in parts)
            det = ", ".join(f"{m} {ts.inr(a)}" for m, a, _ in parts[:5])
            lines.append(f"- {label.capitalize()} (whole statement): {ts.inr(tot)} — {det}")
    return ("\nOBLIGATIONS & HABITS (from the ledger):\n" + "\n".join(lines) + "\n") if lines else ""

def _scoped_facts(ctx):
    """CURRENT-TOPIC fact block for the advice prompt: when the thread carries a
    merchant/category, give the LLM that entity's REAL aggregates (total, share,
    month-by-month) and pin the topic — so "tell me some insights in this category" /
    "more insights" stays on the carried topic instead of whatever the account-wide
    sheet makes salient. '' on a fresh thread; every number from SQL."""
    cat = (ctx or {}).get("category", "")
    mer = (ctx or {}).get("merchant", "")
    inr = ts.inr
    if mer:
        r = ts.merchant_spend(USER, mer, None, None)
        if not r["count"]:
            return ""
        return (f"\nCURRENT TOPIC: the merchant {mer}. FACTS FOR {mer}: spent "
                f"{inr(r['debit'])} across {ts.grp(r['dcount'])} transactions"
                + (f", received {inr(r['credit'])}" if r["credit"] else "")
                + f". Answer about {mer} specifically unless the user changes topic.\n")
    if not cat:
        return ""
    total, cnt = 0.0, 0
    for c, a, n in ts.by_category(USER, None, None):
        if c == cat:
            total, cnt = a, n
            break
    if not cnt:
        return ""
    o = ts.overview(USER, None, None)
    pct = (total / o["debit"] * 100.0) if o["debit"] else 0.0
    series = ", ".join(
        f"{ts._mlabel(m)} {inr(next((a for c2, a, _n in ts.by_category(USER, None, m) if c2 == cat), 0.0))}"
        for m in ts.months_list(USER, None, None))
    return (f"\nCURRENT TOPIC: the {cat} category. FACTS FOR {cat}: total {inr(total)} "
            f"across {ts.grp(cnt)} transactions ({pct:.1f}% of all spending); by month: "
            f"{series}. Answer about {cat} specifically unless the user changes topic.\n")

def _entity_months(merchant, category, period=None):
    """Sorted distinct YYYY-MM the merchant/category actually transacted in over `period`
    (placeholder year-0000 rows excluded). The single source of truth shared by the
    per-merchant/category monthly average and the 'which months' enumeration, so the two
    can never disagree."""
    rows, _total = ts.list_transactions(USER, merchant or None, category or None, None, period, 5000)
    return sorted({r[0][:7] for r in rows if not r[0].startswith("0000")})

def _active_months(merchant, category, period=None):
    """Count of _entity_months, floored at 1 so it's a safe average denominator."""
    return len(_entity_months(merchant, category, period)) or 1

def analytics_answer(q):
    """Deterministic analytics (compare, average, %, argmax, amount filter, multi-entity,
    exclusion). Returns markdown or None (not an analytics question)."""
    low = q.lower()
    pp = _parse_period(q)
    period, plabel = (ts._norm_period(pp[0], pp[1]) if pp else (None, None))
    sfx = f" in {plabel}" if plabel else ""
    inr, grp = ts.inr, ts.grp
    cats, merchs = _find_categories(low), _find_merchants(low)

    def empty():
        return bool(period) and ts.overview(USER, None, period)["count"] == 0

    def nodata():
        cov = ts.coverage(USER)
        span = f" Your data covers {ts._mlabel(cov[0])}–{ts._mlabel(cov[1])}." if cov else ""
        return f"**No transactions found for {plabel}.**{span}"

    # ---- WHAT-IF (deterministic): "if I cut Shopping by 20%, how much would I save?"
    wif = re.search(r"\b(?:cut|reduce|trim|lower|slash|decreas\w*|drop)\b.*?\bby\s+(\d+(?:\.\d+)?)\s*%", low)
    if wif and (cats or merchs):
        pct = float(wif.group(1)) / 100.0
        nmw = len([1 for _m, d, c, _n in ts.by_month(USER, None, period) if d or c]) or 1
        if cats:
            amt = next((a for c, a, _ in ts.by_category(USER, None, period) if c == cats[0]), 0.0)
            name = cats[0]
        else:
            amt = ts.merchant_spend(USER, merchs[0], None, period)["debit"]; name = merchs[0]
        saved = amt * pct
        return (f"**Cutting {name} by {wif.group(1)}% would save {inr(saved)}{sfx}** — about "
                f"{inr(saved / nmw)}/month, {inr(saved / nmw * 12)}/year. "
                f"({name} is currently {inr(amt)} over {nmw} months.)")

    # ---- FILTERED transactions (weekend / weekday / debit-only / credit-only), scoped
    #      to a merchant/category/period. Powers follow-ups like "only weekends".
    we = re.search(r"\bweekend", low); wd = re.search(r"\bweekday", low)
    deb_only = re.search(r"\b(only (?:on )?debit|debit only|just debit)\b", low)
    cred_only = re.search(r"\b(only (?:on )?credit|credit only|just credit)\b", low)
    if we or wd or deb_only or cred_only:
        if empty():
            return nodata()
        mname = merchs[0] if merchs else None
        cname = cats[0] if cats else None
        weekend = True if we else (False if wd else None)
        ttype = "debit" if deb_only else ("credit" if cred_only else None)
        r = ts.filtered_summary(USER, merchant=mname, category=cname, period=period,
                                weekend=weekend, txn_type=ttype)
        flt = []
        if weekend is True:    flt.append("on weekends")
        elif weekend is False: flt.append("on weekdays")
        if ttype:              flt.append(f"{ttype} only")
        scope = f" at {mname}" if mname else (f" on {cname}" if cname else "")
        return (f"**{grp(r['count'])} transactions{scope}{sfx} ({' · '.join(flt)})** "
                f"— totaling {inr(r['total'])}")

    # ---- 0) FINANCIAL-REASONING questions (savings rate/target, runway, risky
    #         months, consistency, income trend/sources/timing, period compare,
    #         spending profile, habits). Every figure is computed from SQL; the
    #         "advisory" ones are grounded in the user's real numbers, not invented.
    if re.search(r"\bsav|runway|survive|income stop|risky|financially|consisten|stable|steady|"
                 r"volatil|erratic|fluctuat|predictab|\bvary\b|variab|earning|\bincome\b|salary|"
                 r"subscription|recurring|recurr|repeat\w*|lifestyle|personality|\bhabit|shop(?:ping)? online|how often|"
                 r"prevent|stopping me|last\s+\d+\s+months|\btrend\b|spending profile|spending style", low):
        bm = ts.by_month(USER, None, period)            # [(month, debit, credit, count)]
        o0 = ts.overview(USER, None, period)
        mset = [r for r in bm if (r[1] or r[2])]
        nmon0 = len(mset) or 1

        # period-vs-period: "last 6 months vs the previous 6 months"
        mcmp = re.search(r"last\s+(\d+)\s+months?\s+(?:with|to|and|vs\.?|versus|against|compared?\s+(?:to|with))\s+"
                         r"(?:the\s+)?(?:previous|prior|preceding|last|earlier)\s*(\d+)?\s*months?", low)
        if mcmp:
            allm = ts.by_month(USER)
            n1 = int(mcmp.group(1)); n2 = int(mcmp.group(2)) if mcmp.group(2) else n1
            if len(allm) >= n1 + n2:
                rec, prev = allm[-n1:], allm[-(n1 + n2):-n1]
                rd, rc = sum(r[1] for r in rec), sum(r[2] for r in rec)
                pd, pc = sum(r[1] for r in prev), sum(r[2] for r in prev)
                rl = f"{ts._mlabel(rec[0][0])}–{ts._mlabel(rec[-1][0])}"
                pl = f"{ts._mlabel(prev[0][0])}–{ts._mlabel(prev[-1][0])}"
                def pct(a, b):
                    return f"{'+' if a - b >= 0 else ''}{((a - b) / b * 100) if b else 0:.1f}%"
                body = [("Spending", inr(pd), inr(rd), pct(rd, pd)),
                        ("Income", inr(pc), inr(rc), pct(rc, pc)),
                        ("Net savings", inr(pc - pd), inr(rc - rd), pct(rc - rd, pc - pd))]
                return (f"**Last {n1} months ({rl}) vs previous {n2} ({pl})**\n\n"
                        + ts._table(["Metric", "Previous", "Recent", "Change"], body))

        # savings rate
        if re.search(r"\bsav(?:e|ed|es|ing|ings)\b", low) and \
           re.search(r"\b(rate|percent|percentage|%|ratio|proportion)\b", low) and \
           not re.search(r"\b(target|goal|should)\b", low):
            inc, sp = o0["credit"], o0["debit"]
            if inc <= 0:
                return f"**Savings rate{sfx}:** no income recorded."
            saved = inc - sp
            return (f"**Savings rate{sfx}:** {saved / inc * 100:.1f}% — saved {inr(saved)} of "
                    f"{inr(inc)} income (spent {inr(sp)}).")

        # savings target (20% guideline, grounded in their figures)
        if re.search(r"sav(?:ing|ings)?\s+(?:target|goal)|how much should i save|monthly savings target|"
                     r"how much.*should.*save", low):
            inc, sp = o0["credit"], o0["debit"]
            minc, cur = inc / nmon0, (inc - sp) / nmon0
            return (f"**Suggested monthly savings target{sfx}:** {inr(minc * 0.20)} — 20% of your "
                    f"average monthly income ({inr(minc)}). You already save about {inr(cur)}/month "
                    f"({(inc - sp) / inc * 100 if inc else 0:.1f}% of income).")

        # survival runway
        if re.search(r"how (?:long|many months).*(survive|last|go|cover)|\b(runway|emergency fund)\b|"
                     r"if (?:my )?income (?:stop|stopped|stops|dried)|without (?:any )?income|no income", low):
            bal = ts.latest_balance(USER, None, period)
            avg_sp = o0["debit"] / nmon0
            if bal is not None and avg_sp > 0:
                return (f"**Survival runway{sfx}:** about {bal / avg_sp:.1f} months — closing balance "
                        f"{inr(bal)} ÷ average monthly spend {inr(avg_sp)}.")

        # financially risky months (spending > income)
        if re.search(r"\b(risky|risk|overspent|over[-\s]?spent|deficit|in the red)\b", low) and \
           re.search(r"\bmonths?\b", low):
            neg = [(m, c - d_) for m, d_, c, _n in bm if (c - d_) < 0]
            if neg:
                body = ", ".join(f"{ts._mlabel(m)} ({inr(net)})" for m, net in neg)
                return f"**Financially risky months{sfx}** (spending beat income): {body}"
            tight = sorted(((m, c - d_) for m, d_, c, _n in bm), key=lambda r: r[1])[:3]
            body = ", ".join(f"{ts._mlabel(m)} (net {inr(net)})" for m, net in tight)
            return (f"**No risky months{sfx}** — income exceeded spending every month. "
                    f"Tightest: {body}.")

        # spending consistency (coefficient of variation of monthly spend)
        if re.search(r"\b(consisten|stable|steady|volatil|erratic|predictab|fluctuat|regular|vary|variab)\w*", low) \
           and re.search(r"spend|spending|expense", low):
            vals = [d_ for _m, d_, _c, _n in mset]
            if vals:
                mean = sum(vals) / len(vals)
                std = (sum((v - mean) ** 2 for v in vals) / len(vals)) ** 0.5
                cv = (std / mean * 100) if mean else 0
                verdict = ("very consistent" if cv < 10 else "fairly consistent" if cv < 20
                           else "somewhat variable" if cv < 35 else "highly variable")
                return (f"**Spending consistency{sfx}:** {verdict} — averages {inr(mean)}/month, "
                        f"ranging {inr(min(vals))}–{inr(max(vals))} (variation ±{cv:.0f}%).")

        # income trend / growth
        if re.search(r"\b(earning|earnings|income|salary)\b", low) and \
           re.search(r"\b(grow|growing|grew|increas\w*|rising|risen|trend|over time|going up|improv\w*|declin\w*|drop\w*)\b", low):
            creds = [c for _m, _d, c, _n in bm]
            if len(creds) >= 2:
                half = len(creds) // 2
                h1, h2 = sum(creds[:half]), sum(creds[half:])
                if h1 > 0:
                    chg = (h2 - h1) / h1 * 100
                    dirw = "growing" if chg > 2 else "declining" if chg < -2 else "broadly flat"
                    return (f"**Income trend{sfx}:** {dirw} — earlier half {inr(h1)} vs later half "
                            f"{inr(h2)} ({'+' if chg >= 0 else ''}{chg:.1f}%).")

        # income sources / reliability
        if re.search(r"income source|sources? of (?:my )?income|where (?:does|do)\s+(?:my\s+)?(?:income|earnings)\s+come from|"
                     r"\bincome\b.*\b(reliable|sources?|breakdown)\b|\b(reliable|main|primary|biggest)\b.*\bincome\b", low):
            rows = [r for r in ts.income_by_source(USER, None, period) if r[1] > 0]
            if rows:
                body = [(m, inr(c), grp(n)) for m, c, n in rows]
                return f"**Income sources{sfx}**\n\n" + ts._table(["Source", "Received", "Txns"], body)

        # income timing
        if re.search(r"when (?:does|do|is|am i|will).*(income|salary|earn|paid|money|credit|deposit)", low):
            creds = sorted(((m, c) for m, _d, c, _n in bm if c > 0), key=lambda r: r[1], reverse=True)
            if creds:
                body = ", ".join(f"{ts._mlabel(m)} ({inr(c)})" for m, c in creds[:3])
                return f"**When income arrives{sfx}:** biggest income months are {body}."

        # spending profile / personality / lifestyle
        if re.search(r"spending personality|describe my spend|what does my spending say|lifestyle|"
                     r"spending profile|spending style|kind of spender|type of spender", low):
            rows = ts.by_category(USER, None, period)
            tot = sum(a for _c, a, _n in rows) or 1
            if rows:
                parts = ", ".join(f"{c} ({a / tot * 100:.0f}%)" for c, a, _n in rows[:3])
                return (f"**Your spending profile{sfx}:** dominated by {parts}. Top category is "
                        f"{rows[0][0]} at {inr(rows[0][1])} of {inr(tot)} total spending.")

        # what's preventing me from saving -> biggest outflows
        if re.search(r"prevent.*sav|stop\w*.*sav|why can.?t i save|what.?s stopping|keeping me from saving|"
                     r"hard(?:er)? to save", low):
            rows = ts.by_category(USER, None, period)
            if rows:
                body = ", ".join(f"{c} ({inr(a)})" for c, a, _n in rows[:3])
                return (f"**What's eating your savings{sfx}:** biggest outflows are {body}. Total "
                        f"spending {inr(o0['debit'])} against {inr(o0['credit'])} income.")

        # habits to reconsider / change first -> biggest flexible categories
        if re.search(r"\bhabit", low) or re.search(r"(reconsider|change first|cut down|trim)", low):
            rows = ts.by_category(USER, None, period)
            disc = sorted([(c, a) for c, a, _n in rows
                           if c in ("Shopping", "Food & Dining", "Entertainment", "Transport")],
                          key=lambda r: r[1], reverse=True)
            if disc:
                body = ", ".join(f"{c} ({inr(a)})" for c, a in disc[:3])
                return (f"**Spending habits worth reviewing{sfx}:** your largest flexible categories "
                        f"are {body} — usually the easiest to trim.")

        # subscriptions: cost-trend ("which increased?") vs plain recurring-bill list
        if re.search(r"\bsubscription|recurring|recurr|repeat\w*", low):
            if re.search(r"increas|rose|risen|rising|went up|gone up|grew|growing|more expensive|"
                         r"cost.*chang|chang.*cost|decreas|dropp|fell|cheaper|\btrend\b|over time", low):
                tr = ts.subscription_trends(USER, None, period)
                up = [(m, a1, a2, c) for m, a1, a2, c in tr if c > 1]
                if up:
                    body = [(m, inr(a1), inr(a2), f"+{c:.0f}%") for m, a1, a2, c in up]
                    return ("**Subscriptions that increased in cost** (avg ₹/month: first half → second half)\n\n"
                            + ts._table(["Subscription", "Was", "Now", "Change"], body))
                if tr:
                    body = [(m, inr(a1), inr(a2), f"{'+' if c >= 0 else ''}{c:.0f}%") for m, a1, a2, c in tr]
                    return ("**No subscription rose meaningfully** — monthly cost is stable across the "
                            "period. Full trend (avg ₹/month: first half → second half):\n\n"
                            + ts._table(["Subscription", "Was", "Now", "Change"], body))
            det = ts.dispatch_intent({"type": "subscriptions", "start": "", "end": ""}, USER)
            if det:
                return det

        # online shopping frequency
        if re.search(r"shop(?:ping)? online|online shop|how often.*shop", low):
            for c, a, n in ts.by_category(USER, None, period):
                if c == "Shopping":
                    return (f"**Online shopping{sfx}:** {grp(n)} Shopping transactions totalling "
                            f"{inr(a)} (about {n // nmon0} a month).")

    # 1) PERCENT / share of total
    if re.search(r"percent|percentage|%|\bshare\b|fraction|proportion", low) and (cats or merchs):
        if empty():
            return nodata()
        tot = ts.overview(USER, None, period)["debit"] or 1
        if cats:
            amt = next((a for c, a, _ in ts.by_category(USER, None, period) if c == cats[0]), 0.0)
            name = cats[0]
        else:
            amt = ts.merchant_spend(USER, merchs[0], None, period)["debit"]
            name = merchs[0]
        return f"**{name}{sfx}:** {inr(amt)} — **{amt/tot*100:.1f}%** of total spending ({inr(tot)})"

    # 2) EXCLUSION
    if re.search(r"\b(excluding|except|other than|without|besides|apart from|minus|not counting)\b", low) and cats:
        if empty():
            return nodata()
        tot = ts.overview(USER, None, period)["debit"]
        amt = next((a for c, a, _ in ts.by_category(USER, None, period) if c == cats[0]), 0.0)
        return (f"**Spending{sfx} excluding {cats[0]}:** {inr(tot - amt)}  "
                f"(total {inr(tot)} − {cats[0]} {inr(amt)})")

    # 2b) COUNT of transactions above/below a THRESHOLD or the (scoped) AVERAGE.
    #     "how many transactions over 500", "no. of transactions above the average on zomato".
    #     Must precede the AVERAGE branch (which also matches "average").
    _dir_over = re.search(r"\b(above|over|greater than|more than|bigger than|exceed\w*|higher than|at\s?least|atleast)\b", low)
    _dir_under = re.search(r"\b(below|under|less than|smaller than|cheaper than|lower than)\b", low)
    _is_count = bool(re.search(r"\b(how many|number of|no\.?\s*of|count(?:\s+of)?|num\b)\b", low)
                     or re.search(r"\btransactions?\b.{0,40}\b(above|over|below|under|greater|more|less|exceed)", low))
    _wants_avg = re.search(r"\b(average|avg|mean)\b", low)
    _thr = _parse_amount(low)
    if _is_count and (_dir_over or _dir_under) and (_thr is not None or _wants_avg):
        if empty():
            return nodata()
        op = "under" if (_dir_under and not _dir_over) else "over"
        mname = merchs[0] if merchs else None
        cname = cats[0] if cats else None
        if _thr is not None:
            threshold, tlabel = _thr, inr(_thr)
        else:                                            # threshold = the scoped average
            if mname:
                r0 = ts.merchant_spend(USER, mname, None, period)
                threshold = (r0["debit"] / r0["dcount"]) if r0["dcount"] else 0.0
            elif cname:
                amt0 = cnt0 = 0
                for c, a, n in ts.by_category(USER, None, period):
                    if c == cname:
                        amt0, cnt0 = a, n
                        break
                threshold = (amt0 / cnt0) if cnt0 else 0.0
            else:
                o0 = ts.overview(USER, None, period)
                dc0 = ts.txn_count(USER, "debit", None, period)
                threshold = (o0["debit"] / dc0) if dc0 else 0.0
            tlabel = f"the average {inr(threshold)}"
        if threshold <= 0:
            return nodata()
        r = ts.amount_filter(USER, op, threshold, None, period, merchant=mname, category=cname)
        scope = f" at {mname}" if mname else (f" on {cname}" if cname else "")
        return (f"**{grp(r['count'])} transactions{scope}{sfx} {op} {tlabel}** "
                f"— totaling {inr(r['total'])}")

    # 3) AVERAGE (per month / per transaction) — scoped to a named merchant/category
    #    if one is present, else the whole account.
    if re.search(r"\b(average|avg|mean)\b", low):
        if empty():
            return nodata()
        per_txn = bool(re.search(r"per (?:transaction|txn|purchase|order|swipe|payment)|each (?:transaction|order|purchase)|a transaction|per[- ]txn", low)
                       or (re.search(r"transaction|txn|purchase|order", low) and not re.search(r"month", low)))
        nmon = len([1 for _m, d, c, _n in ts.by_month(USER, None, period) if d or c]) or 1
        if merchs:                                   # "average transaction at Zomato" / monthly at X
            r = ts.merchant_spend(USER, merchs[0], None, period)
            if r["count"] == 0:
                return f"**No transactions found for '{merchs[0]}'{sfx}.**"
            if per_txn:
                return (f"**Average transaction at {merchs[0]}{sfx}:** {inr(r['debit']/r['count'])}  "
                        f"(over {grp(r['count'])} transactions)")
            # divide by the months the MERCHANT was active, not every statement month — else a
            # merchant seen in 3 of 4 months is understated, and "over 4 months" contradicts the
            # "which months" enumeration. Same appearance-month basis months_which_answer uses.
            nmon_x = _active_months(merchs[0], None, period)
            return (f"**Average monthly spend at {merchs[0]}{sfx}:** {inr(r['debit']/nmon_x)}  "
                    f"(over {nmon_x} month{'s' if nmon_x != 1 else ''})")
        if cats:                                     # "average monthly spend on Groceries"
            amt = cnt = 0
            for c, a, n in ts.by_category(USER, None, period):
                if c == cats[0]:
                    amt, cnt = a, n
                    break
            if per_txn:
                return (f"**Average {cats[0]} transaction{sfx}:** {inr(amt/cnt) if cnt else inr(0)}  "
                        f"(over {grp(cnt)} transactions)")
            nmon_c = _active_months(None, cats[0], period)
            return (f"**Average monthly spend on {cats[0]}{sfx}:** {inr(amt/nmon_c)}  "
                    f"(over {nmon_c} month{'s' if nmon_c != 1 else ''})")
        o = ts.overview(USER, None, period)          # whole-account average
        if per_txn:
            dc = ts.txn_count(USER, "debit", None, period)   # average over DEBIT txns, not all rows
            if dc == 0:
                return nodata()
            return f"**Average transaction{sfx}:** {inr(o['debit']/dc)}  (over {grp(dc)} expenses)"
        return f"**Average monthly spend{sfx}:** {inr(o['debit']/nmon)}  (over {nmon} months)"

    # 3b) NAMED-CATEGORY TREND — "did my utility bills increase?" wants the month-by-month
    #     movement of THAT category, not its flat total. Every figure from by_category SQL.
    if cats and re.search(r"\b(increas\w*|decreas\w*|go(?:ne|ing)?\s+up|went\s+up|"
                          r"ris(?:e|en|ing)|drop\w*|fall\w*|grow\w*|creep\w*)\b", low):
        ms = ts.months_list(USER, None, period)
        series = [(m, next((a for c2, a, _n in ts.by_category(USER, None, m) if c2 == cats[0]), 0.0))
                  for m in ms]
        if len(series) >= 2:
            first, last = series[0][1], series[-1][1]
            word = ("increased" if last > first else
                    "decreased" if last < first else "stayed flat")
            body = [(ts._mlabel(m), inr(a)) for m, a in series]
            return (f"**{cats[0]} {word}** — {inr(first)} in {ts._mlabel(series[0][0])} → "
                    f"{inr(last)} in {ts._mlabel(series[-1][0])}.\n\n"
                    + ts._table(["Month", cats[0]], body))

    # 4) WHICH MONTH (argmax / argmin)
    _mon_superl = re.search(r"\b(most|least|highest|lowest|max|min|biggest|smallest|fewest|peak)\b", low)
    # "what about June month" / "June's total" NAMES a month with no superlative -> it's a
    # scope-to-that-month request, not "which month is the extreme"; let the factual path take it.
    # A deictic "this/last month" is likewise a SCOPE ("what bank fees have I been charged
    # this month?"), and "each/every/per month" is a cadence ("what loans am I repaying
    # each month?") — neither is ever a which-month argmax.
    _mon_deictic = re.search(r"\b(this|last|past|current|previous|each|every|per)\s+month\b", low)
    if (re.search(r"\b(which|what)\b.*\bmonth\b", low)
            or (re.search(r"\bmonth\b", low) and _mon_superl)) \
       and not _mon_deictic \
       and not (re.search(rf"\b({_MON_RE})\b", low) and not _mon_superl):
        if empty():
            return nodata()
        bm = ts.by_month(USER, None, period)
        if bm:
            least = bool(re.search(r"\b(least|lowest|min|smallest|fewest)\b", low))
            if re.search(r"\b(transactions?|txns?|count|purchases?|busiest|active)\b", low):
                rows = [(m, n) for m, _d, _c, n in bm]
                m, v = (min if least else max)(rows, key=lambda r: r[1])
                return (f"**{'Fewest' if least else 'Most'}-transaction month{sfx}:** "
                        f"{ts._mlabel(m)} — {grp(v)} transactions")
            if re.search(r"\b(receiv\w*|credit\w*|income|deposit\w*|earn\w*|inflow|salary)\b", low):
                rows = [(m, c) for m, _d, c, _n in bm]
                m, v = (min if least else max)(rows, key=lambda r: r[1])
                return f"**{'Lowest' if least else 'Highest'}-income month{sfx}:** {ts._mlabel(m)} — {inr(v)}"
            rows = [(m, d) for m, d, _c, _n in bm]
            m, v = (min if least else max)(rows, key=lambda r: r[1])
            return f"**{'Lowest' if least else 'Highest'}-spend month{sfx}:** {ts._mlabel(m)} — {inr(v)}"

    # 5) TOP / BIGGEST CATEGORY
    if re.search(r"\b(top|biggest|largest|highest|main|number one|#1|least|lowest|smallest|fewest)\b[^?]*\bcategor", low) or \
       re.search(r"\bcategor[^?]*\b(most|biggest|largest|highest|least|lowest|smallest|fewest)\b", low) or \
       re.search(r"what do i spend (?:the )?most on|where (?:does|do) (?:most of )?my money go", low):
        if empty():
            return nodata()
        rows = ts.by_category(USER, None, period)
        if rows:
            tot = sum(a for _, a, _ in rows) or 1
            least = bool(re.search(r"\b(least|lowest|smallest)\b", low))
            c, a, n = rows[-1] if least else rows[0]
            return (f"**{'Smallest' if least else 'Top'} spending category{sfx}:** "
                    f"{c} — {inr(a)} ({a/tot*100:.0f}%, {grp(n)} txns)")

    # 6) TOP MERCHANT(S) — incl. "which merchant did I spend (the most|more) [on <date>]"
    if re.search(r"\btop\s+\d*\s*merchant|biggest merchant|favou?rite merchant|"
                 r"most[^?]*\bmerchant|merchant[^?]*\bmost\b|who do i spend the most|"
                 r"(?:which|what)\s+merchant[^?]*\b(?:most|more|highest|biggest|largest)\b|"
                 r"\b(?:most|more|highest|biggest|largest)\b[^?]*\bmerchant\b", low):
        if empty():
            return nodata()
        nm = re.search(r"top\s+(\d+)", low)
        n = int(nm.group(1)) if nm else 5
        rows = ts.top_merchants(USER, n, None, period)
        if rows:
            if not nm or n == 1:
                c, a, cnt = rows[0]
                return f"**Top merchant{sfx}:** {c} — {inr(a)} across {grp(cnt)} transactions"
            body = [(i + 1, c, inr(a), grp(cnt)) for i, (c, a, cnt) in enumerate(rows)]
            return f"**Top {len(rows)} merchants{sfx}**\n\n" + ts._table(["#", "Merchant", "Spent", "Txns"], body)

    # 7) AMOUNT FILTER (optionally scoped to a merchant / category)
    amt = _parse_amount(low)
    if amt and re.search(r"\b(over|above|more than|greater than|bigger than|exceed\w*|higher than|"
                         r"under|below|less than|smaller than|cheaper than|lower than)\b", low):
        if empty():
            return nodata()
        op = "under" if re.search(r"\b(under|below|less than|smaller than|cheaper than|lower than)\b", low) else "over"
        mname = merchs[0] if merchs else None
        cname = cats[0] if cats else None
        is_credit = bool(re.search(r"\b(received|credit|deposit|income|earn(?:ed|ings|t)?|salary|inflow|recie?ve?d?)\b", low))
        ttype = "credit" if is_credit else "debit"
        r = ts.amount_filter(USER, op, amt, None, period, merchant=mname, category=cname, txn_type=ttype)
        scope = f" at {mname}" if mname else (f" on {cname}" if cname else "")
        label = "credit transactions" if is_credit else "transactions"
        return (f"**{grp(r['count'])} {label}{scope}{sfx} {op} {inr(amt)}** — totaling {inr(r['total'])}")

    # 8) MULTI-ENTITY (two+ merchants/categories combined)
    combine = re.search(r"\b(together|combined|total of|both|sum of|plus|altogether)\b", low)
    # implicit combine (two names, no compare word) must not swallow a date-lookup —
    # "when did I last shop at Aldi?" names Aldi AND the stored merchant "Shop", but it's
    # a merchant_date question, not "Aldi + Shop". An explicit "together/both" still combines.
    if len(merchs) >= 2 and (combine or not (re.search(r"\bor\b|more|less|vs\b|versus|compare|than", low)
                                             or _DATELOOKUP_RE.search(low))):
        if empty():
            return nodata()
        parts = [(m, ts.merchant_spend(USER, m, None, period)["debit"]) for m in merchs[:4]]
        tot = sum(a for _, a in parts)
        return (f"**{' + '.join(m for m, _ in parts)}{sfx}:** {inr(tot)}  ("
                + ", ".join(f"{m} {inr(a)}" for m, a in parts) + ")")
    if len(cats) >= 2 and combine and not re.search(r"\bor\b|more|less|vs\b|versus|compare|than", low):
        if empty():
            return nodata()
        cmap = {c: a for c, a, _ in ts.by_category(USER, None, period)}
        parts = [(c, cmap.get(c, 0.0)) for c in cats[:4]]
        tot = sum(a for _, a in parts)
        return (f"**{' + '.join(c for c, _ in parts)}{sfx}:** {inr(tot)}  ("
                + ", ".join(f"{c} {inr(a)}" for c, a in parts) + ")")

    # 9) COMPARE / DIFFERENCE (two periods, or two categories/merchants)
    if re.search(r"\b(more|less|higher|lower|difference|compare|versus|vs|than)\b|\bor\b", low):
        periods = _find_periods(q)
        if len(periods) >= 2:
            a, b = periods[0], periods[1]
            # thread a named category/merchant symmetrically through BOTH periods, so
            # "Entertainment: March vs May" compares Entertainment, not total spend.
            if cats:
                sa = next((x for c, x, _ in ts.by_category(USER, None, a) if c == cats[0]), 0.0)
                sb = next((x for c, x, _ in ts.by_category(USER, None, b) if c == cats[0]), 0.0)
                lbl = f"{cats[0]} "
            elif merchs:
                sa = ts.merchant_spend(USER, merchs[0], None, a)["debit"]
                sb = ts.merchant_spend(USER, merchs[0], None, b)["debit"]
                lbl = f"{merchs[0]} "
            else:
                sa = ts.overview(USER, None, a)["debit"]
                sb = ts.overview(USER, None, b)["debit"]
                lbl = ""
            diff = sa - sb
            rel = "more" if diff >= 0 else "less"
            pct = abs(diff) / (sb or 1) * 100
            return (f"**{lbl}{ts._plabel(a)}:** {inr(sa)}  vs  **{lbl}{ts._plabel(b)}:** {inr(sb)}\n\n"
                    f"You spent **{inr(abs(diff))} {rel}** in {ts._plabel(a)} ({pct:.0f}% {rel}).")
        if len(cats) >= 2:
            if empty():
                return nodata()
            cmap = {c: a for c, a, _ in ts.by_category(USER, None, period)}
            va, vb = cmap.get(cats[0], 0.0), cmap.get(cats[1], 0.0)
            hi = cats[0] if va >= vb else cats[1]
            return (f"**{cats[0]}{sfx}:** {inr(va)}  vs  **{cats[1]}:** {inr(vb)}\n\n"
                    f"You spent more on **{hi}** (by {inr(abs(va - vb))}).")
        if len(merchs) >= 2:
            if empty():
                return nodata()
            va = ts.merchant_spend(USER, merchs[0], None, period)["debit"]
            vb = ts.merchant_spend(USER, merchs[1], None, period)["debit"]
            hi = merchs[0] if va >= vb else merchs[1]
            return (f"**{merchs[0]}{sfx}:** {inr(va)}  vs  **{merchs[1]}:** {inr(vb)}\n\n"
                    f"You spent more at **{hi}** (by {inr(abs(va - vb))}).")
    return None

def months_which_answer(q, ctx):
    """Enumerate the months the carried merchant/category actually appears in. Returns
    markdown, or None to fall through (no plural-months ask, an argmax, a coverage question,
    or no carried entity)."""
    low = q.lower()
    if not _WHICH_MONTHS_RE.search(low):
        return None
    if re.search(r"\b(most|highest|biggest|largest|lowest|smallest|least|max|min|top|worst|best)\b", low):
        return None                                    # argmax ("which month did I spend most")
    if re.search(r"\bdo you have\b|\bavailable\b|\bcover(?:age|ed)?\b|\bdata\b|\bstatement\b", low):
        return None                                    # coverage question, handled elsewhere
    if re.search(r"\bspen|\bspent|\bbreakdown\b|\bhow much\b|\btotal\b|\bby month\b|\beach month\b|\bper month\b", low):
        return None                                    # a spend/breakdown ask, not month enumeration
    mer = (ctx or {}).get("merchant", "")
    cat = (ctx or {}).get("category", "")
    if not mer and not cat:
        return None                                    # nothing to enumerate -> fall through
    months = _entity_months(mer or None, cat or None)  # same basis as the monthly average
    if not months:
        return None
    label = ts._mname(mer) if mer else cat
    names = ", ".join(ts._mlabel(m) for m in months)
    return (f"**{label}** appears in {len(months)} "
            f"month{'s' if len(months) != 1 else ''}: {names}.")

def ml_answer(q):
    """Anomaly / forecast questions -> the sklearn models. Deterministic figures from the
    data. Returns markdown, or None if not applicable / not enough data."""
    low = q.lower()
    if _ANOM_RE.search(low):
        r = _ml("anom", lambda: ml.anomalies(USER))
        items = r.get("items", [])
        scanned = ts.grp(r.get("trained_on", 0))
        if not items:
            return (f"**No standout anomalies.** I ran an anomaly model over {scanned} expenses and "
                    f"nothing deviates strongly from your usual pattern.")
        body = [(it["date"], it["merchant"], ts.inr(it["amount"]), it["reason"]) for it in items]
        return (f"**Unusual transactions** — flagged by the anomaly model out of {scanned} expenses "
                f"(largest first):\n\n"
                + ts._table(["Date", "Merchant", "Amount", "Why flagged"], body))
    if _FCAST_RE.search(low):
        r = _ml("fc", lambda: ml.forecast(USER))
        t = r.get("total")
        if not t:
            return None
        rows = [(c["name"], ts.inr(c["predicted"]), c["trend"]) for c in r["per_category"][:8]]
        return (f"**Spend forecast for {r['next_month']}** — projected total **{ts.inr(t['predicted'])}** "
                f"(likely range {ts.inr(t['lo'])}–{ts.inr(t['hi'])}), from a per-category linear trend:\n\n"
                + ts._table(["Category", "Predicted next month", "Trend"], rows))
    if _PROJ_RE.search(low):
        o = ts.overview(USER); nm = max(len(ts.months_list(USER)), 1)
        msp, mnet = o["debit"] / nm, o["net"] / nm
        return (f"**Run-rate projection** (at your current pace): annual spending about "
                f"**{ts.inr(msp * 12)}** and annual net savings about **{ts.inr(mnet * 12)}** — "
                f"based on a {ts.inr(msp)} average monthly spend over {nm} months.")
    return None

def health_answer(q):
    h = ts.health_score(USER)
    if not h:
        return None
    comp = h["components"]
    strongest = max(comp, key=comp.get)
    weakest = min(comp, key=comp.get)
    kept = h["months"] - h["overspent_months"]
    body = [(k, f"{v} / 25") for k, v in comp.items()]
    return (f"**Financial health: {h['rating']} — {h['score']}/100.**\n\n"
            f"You save **{h['savings_rate']:.0f}%** of income and kept spending within income in "
            f"**{kept} of {h['months']}** months. Your strongest pillar is **{strongest.lower()}**; "
            f"your weakest is **{weakest.lower()}** — your top income source is "
            f"**{h['income_dependence']:.0f}%** of earnings and your top 5 merchants are "
            f"**{h['merchant_concentration']:.0f}%** of spending.\n\n"
            + ts._table(["Pillar (max 25)", "Score"], body))

def risk_answer(q):
    r = ts.risk_assessment(USER)
    if not r:
        return None
    if not r["flags"]:
        return (f"**Risk level: {r['risk_level']} — {r['risk_score']}/100.** No major structural "
                "risks — your savings rate, income mix and month-to-month spending are all in a "
                "healthy range. The main thing to watch as your finances grow is concentration.")
    body = [(f["rule"], f["detail"]) for f in r["flags"]]
    return (f"**Risk level: {r['risk_level']} — {r['risk_score']}/100.** "
            f"I flagged **{len(r['flags'])}** structural risk factor(s), heaviest first:\n\n"
            + ts._table(["Risk factor", "What I see"], body))

def recurring_answer(q):
    # Cost-trend ("which increased?") or advice ("should I cancel?") -> not the
    # auto-detector; return None so the subscription-trend / advice paths run.
    if _RECUR_DEFER.search(q.lower()):
        return None
    r = _ml("recur", lambda: ml.recurring(USER))
    items = r.get("items", [])
    if items:
        body = [(it["merchant"], it["cadence"], ts.inr(it["amount"]), ts.grp(it["count"]),
                 f"{int(round(it['confidence'] * 100))}%") for it in items[:15]]
        newly = r.get("newly_found", [])
        note = (f"\n\n_Auto-detected from your transactions (no preset list); surfaced beyond the "
                f"obvious: {', '.join(newly[:6])}._" if newly
                else "\n\n_Auto-detected from your transactions — no preset merchant list used._")
        return ("**Recurring charges & subscriptions** — payments that repeat at a regular cadence "
                "and similar amount:\n\n"
                + ts._table(["Merchant", "Cadence", "Typical amount", "Times", "Confidence"], body)
                + note)
    # Auto-detector found no stable cadence (e.g. amounts vary too much) -> fall back to
    # the known-subscription view so the answer is still useful, never worse than before.
    rec = ts.subscription_costs(USER)
    rec = [(m, mo, t, c) for m, mo, t, c in rec if mo]
    if rec:
        per_month = sum(t / mo for _m, mo, t, _c in rec)
        body = [(m, ts.grp(mo), ts.inr(t), ts.inr(t / mo)) for m, mo, t, _c in rec]
        return (f"**Recurring bills & subscriptions** — about {ts.inr(per_month)} every month:\n\n"
                + ts._table(["Merchant", "Months", "Total", "Avg / month"], body)
                + "\n\n_No single fixed-cadence pattern stood out in the raw transactions, so this is "
                "your known-subscription view._")
    return ("**No recurring charges or subscriptions detected.** Nothing repeats at a steady cadence "
            "and stable amount, and no known subscription merchants appear in your statement.")

def behavior_answer(q):
    b = ts.behavior_metrics(USER)
    if not b:
        return None
    rows = [
        ("Weekend vs weekday",
         f"{ts.inr(b['weekend_per_day'])}/day on weekends vs {ts.inr(b['weekday_per_day'])}/day midweek "
         f"({b['weekend_ratio']:.1f}×)"),
        ("Month-end vs month-start",
         f"{ts.inr(b['eom_spend'])} in the last third of the month vs {ts.inr(b['som_spend'])} in the "
         f"first ({b['eom_ratio']:.1f}×)"),
        ("Small / impulse spends",
         f"{ts.grp(b['small_count'])} of {ts.grp(b['debit_count'])} debits ({b['impulse_share']:.0f}%) "
         f"are under {ts.inr(b['small_threshold'])}"),
    ]
    if b["top_merchant"]:
        rows.append(("Merchant dependency",
                     f"{b['top_merchant']} alone is {b['top_merchant_share']:.0f}% of your spending"))
    if b["weekend_ratio"] >= 1.3:
        v = "weekend-heavy"
    elif b["eom_ratio"] >= 1.3:
        v = "back-loaded toward month-end"
    elif b["impulse_share"] >= 50:
        v = "driven by lots of small, frequent spends"
    else:
        v = "fairly even — no strong weekend, month-end or impulse skew"
    return (f"**Your spending behaviour looks {v}.**\n\n"
            + ts._table(["Behaviour", "What the data shows"], rows))

def impact_answer(q):
    m = re.search(r"\b(\d{1,2})\b", q)
    n = max(1, min(int(m.group(1)), 10)) if m else 5
    items = ts.transaction_impact(USER, n)
    if not items:
        return None
    body = [(it["date"], it["merchant"], ts.inr(it["amount"]),
             ("+" if it["direction"] == "credit" else "−") + str(abs(it["impact"]))) for it in items]
    return ("**The transactions with the biggest impact on your finances** — impact scores each "
            "transaction's size against your largest, signed by direction (+ inflow, − outflow):\n\n"
            + ts._table(["Date", "Merchant", "Amount", "Impact"], body))

def cattrend_answer(q):
    low = q.lower()
    window = 6 if re.search(r"\b(?:6|six)\b", low) else \
        12 if re.search(r"\b(?:12|twelve|year|annual)\b", low) else 3
    ct = ts.category_trend(USER, window)
    if not ct or not ct["movers"]:
        return None
    body = [(mv["category"], ts.inr(mv["prior_avg"]), ts.inr(mv["recent_avg"]),
             ts._pct(mv["recent_avg"], mv["prior_avg"])) for mv in ct["movers"][:8]]
    wl = f"{ct['window']}-month"
    return (f"**Category trends — prior {wl} average → recent {wl} average per month** "
            "(fastest-growing first):\n\n"
            + ts._table(["Category", "Was / mo", "Now / mo", "Change"], body))

def insights_answer(q):
    """Pre-computed insight digest (the Insight Engine surface). Reads stored
    insights; falls back to a live compute when none have been persisted yet."""
    items = ts.get_insights(USER) or ts.compute_insights(USER)
    if not items:
        return None
    order = {"risk": 0, "pattern": 1, "behavior": 2, "impact": 3, "health": 4}
    items = sorted(items, key=lambda it: (order.get(it["type"], 9), -(it.get("score") or 0)))
    lines = ["**Here's what stands out in your statement:**", ""]
    for it in items[:8]:
        lines.append(f"- **{it['title']}** — {it['explanation']}")
    lines += ["", "_Drill in with \"how healthy am I?\", \"what risks do you see?\", "
              "\"what subscriptions do I have?\" or \"what spending habits do I have?\"._"]
    return "\n".join(lines)

def intelligence_answer(q):
    """Dispatch to the pre-computed intelligence engines. Returns markdown or None
    (None -> the question wasn't one of these, so the normal cascade continues)."""
    low = q.lower()
    # Impact is checked before Health: "which transactions hurt my financial health"
    # mentions 'health' but is really an impact question. Impact needs the word
    # "transaction(s)", so it never steals a genuine health question.
    if _IMPACT_RE.search(low):
        return impact_answer(q)
    if _HEALTH_RE.search(low):
        return health_answer(q)
    # "which/what months were risky" wants a per-month breakdown, not the overall
    # risk score -> let the analytics risky-months handler take it.
    if _RISK_RE.search(low) and not re.search(r"(?:which|what)\b.{0,25}month", low):
        return risk_answer(q)
    if _RECUR_RE.search(low):
        return recurring_answer(q)
    if _CATTREND_RE.search(low):
        return cattrend_answer(q)
    if _BEHAVE_RE.search(low):
        return behavior_answer(q)
    if _PATTERN_RE.search(low):
        return insights_answer(q)
    return None


def _ml(kind, fn):
    key = (kind, ts.overview(USER)["count"])
    if key not in _ML_CACHE:
        _ML_CACHE.clear()
        _ML_CACHE[key] = fn()
    return _ML_CACHE[key]

