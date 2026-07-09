import json, sqlite3
from .db import connect
from .formatters import inr, grp, _mlabel, _mname, _table, _pct
from .queries import (
    overview, by_month, by_category, top_merchants, subscription_costs,
    top_expenses, income_by_source, category_movers, months_list, _scope,
    latest_balance, DISCRETIONARY
)

def build_insights(user_id, doc_name=None, period=None):
    """
    Returns (report_markdown, oneliner_grounding).
      report_markdown: deterministic, exact-figure insights (subscriptions, trend,
                       savings rate, concentration, projection). No LLM, no hallucination.
      oneliner_grounding: a NUMBER-FREE headline list for the LLM to turn into ONE sentence.
    """
    o = overview(user_id, doc_name, period)
    if o["count"] == 0:
        return "_No transactions to analyse._", "There is no data."
    months = months_list(user_id, doc_name, period)
    nmon = max(len(months), 1)

    parts = ["## Insights"]
    head = []  # number-free headlines for the LLM

    # 1) savings rate
    rate = (o["net"] / o["credit"] * 100) if o["credit"] > 0 else 0
    over = 0
    if months:
        w, p = _scope(user_id, doc_name, period)
        con = connect()
        mrows = con.execute(f"""SELECT month, SUM(debit), SUM(credit) FROM transactions
                                WHERE {w} GROUP BY month""", p).fetchall()
        con.close()
        over = sum(1 for _m, d, c in mrows if d > c)
    verdict = ("strong" if rate >= 30 else "healthy" if rate >= 15
               else "thin" if rate >= 0 else "negative")
    parts.append(
        f"**💰 Savings rate: {rate:.0f}%** ({verdict}) — you keep {inr(o['net'])} of "
        f"{inr(o['credit'])} income. " + (f"You overspent income in {over} of {nmon} months."
                                          if over else "You stayed within income every month."))
    head.append(f"savings rate is {verdict}")

    # 2) recurring subscriptions / committed bills
    rec = subscription_costs(user_id, doc_name, period)
    if rec:
        per_month = sum(t / mo for _m, mo, t, _c in rec if mo)
        body = [(m, grp(mo), inr(t), inr(t / mo)) for m, mo, t, _c in rec]
        parts.append("**🔁 Recurring bills & subscriptions** — about "
                     f"{inr(per_month)} every month:\n\n"
                     + _table(["Merchant", "Months", "Total", "Avg / month"], body))
        head.append(f"the largest recurring bill is {rec[0][0]}")

    # 3) month-over-month movers
    mv = category_movers(user_id, doc_name, period)
    if mv:
        prev_m, cur_m, movers = mv
        body = [(c, inr(prev), inr(cur), _pct(cur, prev))
                for c, cur, prev, _d in movers[:5]]
        parts.append(f"**📈 Change: {_mlabel(prev_m)} → {_mlabel(cur_m)}**\n\n"
                     + _table(["Category", _mlabel(prev_m), _mlabel(cur_m), "Change"], body))
        top_mv = movers[0]
        if abs(top_mv[3]) > 0:
            direction = "up" if top_mv[3] > 0 else "down"
            head.append(f"{top_mv[0]} spending went {direction} most recently")

    # 4) concentration
    tm = top_merchants(user_id, 5, doc_name)
    if tm and o["debit"] > 0:
        top5 = sum(t for _m, t, _c in tm)
        share = top5 / o["debit"] * 100
        names = ", ".join(m for m, _t, _c in tm)
        parts.append(f"**🎯 Concentration:** your top 5 merchants ({names}) account for "
                     f"{inr(top5)} — **{share:.0f}%** of all spending.")
        head.append("spending is concentrated in a few merchants" if share >= 50
                    else "spending is spread across many merchants")

    # 5) run-rate projection
    avg_m = o["debit"] / nmon
    parts.append(f"**🔮 Run-rate:** averaging {inr(avg_m)} spend/month → about "
                 f"{inr(avg_m * 12)} per year at this pace.")

    grounding = ("Headline findings about the user's finances (do NOT mention any numbers, "
                 "percentages or amounts — they are shown in a table): "
                 + "; ".join(head) + ".")
    return "\n\n".join(parts), grounding


# ============================================================ intelligence engines
# Health Score, Risk Engine, Behavioural Analytics, Transaction Impact, Category
# Trend and the Insight store. Every figure below is computed in SQL here, so the
# LLM that phrases any of it only ever repeats a number it never derived.


def _rating(score, bands):
    """First band whose floor the score meets. bands: [(floor, label), ...] high→low."""
    for lo, label in bands:
        if score >= lo:
            return label
    return bands[-1][1]


def _monthly_series(user_id, doc_name=None, period=None):
    """[(month, debit, credit)] in chronological order — the spine of stability/overspend."""
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    rows = con.execute(f"""SELECT month, COALESCE(SUM(debit),0), COALESCE(SUM(credit),0)
                           FROM transactions WHERE {w} GROUP BY month ORDER BY month""", p).fetchall()
    con.close()
    return rows


def _cv(xs):
    """Coefficient of variation (std/mean); 0 = perfectly steady. 1.0 if mean<=0."""
    xs = [x for x in xs]
    if not xs:
        return 1.0
    m = sum(xs) / len(xs)
    if m <= 0:
        return 1.0
    var = sum((x - m) ** 2 for x in xs) / len(xs)
    return (var ** 0.5) / m


def health_score(user_id, doc_name=None, period=None):
    """Composite financial-health score (0-100) from four 0-25 pillars: savings,
    spending discipline, income stability and diversification. Returns a dict
    (score/rating/components/supporting figures) or None when there is no data."""
    o = overview(user_id, doc_name, period)
    if o["count"] == 0:
        return None
    months = months_list(user_id, doc_name, period)
    nmon = max(len(months), 1)
    inc, sp, net = o["credit"], o["debit"], o["net"]
    rate = (net / inc * 100) if inc > 0 else (0.0 if net >= 0 else -100.0)

    mrows = _monthly_series(user_id, doc_name, period)
    incs = [c for _m, _d, c in mrows]
    over = sum(1 for _m, d, c in mrows if d > c)

    # 1) SAVINGS (0-25): savings rate, 30%+ tops out the pillar.
    sav = max(0.0, min(25.0, rate / 30.0 * 25.0))
    # 2) SPENDING DISCIPLINE (0-25): share of months kept within income.
    disc = 25.0 * (1 - over / nmon)
    # 3) STABILITY (0-25): income consistency; CV 0 -> 25, CV >= 0.5 -> 0.
    icv = _cv(incs)
    stab = max(0.0, min(25.0, 25.0 * (1 - min(icv / 0.5, 1.0))))
    # 4) DIVERSIFICATION (0-25): penalised by income- and merchant-concentration.
    src = [r for r in income_by_source(user_id, doc_name, period) if r[1] > 0]
    dep = (src[0][1] / inc * 100) if (src and inc > 0) else 100.0
    tm = top_merchants(user_id, 5, doc_name, period)
    mconc = (sum(t for _m, t, _c in tm) / sp * 100) if (tm and sp > 0) else 0.0
    div = max(0.0, min(25.0, 25.0
                       - max(0.0, (dep - 50) / 50 * 12.5)
                       - max(0.0, (mconc - 50) / 50 * 12.5)))

    comp = {"Savings": round(sav, 1), "Spending discipline": round(disc, 1),
            "Income stability": round(stab, 1), "Diversification": round(div, 1)}
    score = round(sav + disc + stab + div)
    rating = _rating(score, [(85, "Excellent"), (70, "Good"), (55, "Fair"),
                             (40, "Needs work"), (0, "Poor")])
    return {"score": score, "rating": rating, "components": comp,
            "savings_rate": rate, "overspent_months": over, "months": nmon,
            "income_dependence": dep, "merchant_concentration": mconc, "income_cv": icv}


def risk_assessment(user_id, doc_name=None, period=None):
    """Rule-based structural risk. risk_score (0-100) is the sum of triggered-flag
    severities; risk_level bands it. Differs from anomaly detection: this is about
    standing financial structure, not one-off odd transactions. Returns dict/None."""
    o = overview(user_id, doc_name, period)
    if o["count"] == 0:
        return None
    months = months_list(user_id, doc_name, period)
    nmon = max(len(months), 1)
    inc, sp, net = o["credit"], o["debit"], o["net"]
    rate = (net / inc * 100) if inc > 0 else 0.0
    msp = sp / nmon

    mrows = _monthly_series(user_id, doc_name, period)
    over = sum(1 for _m, d, c in mrows if d > c)

    flags = []
    # 1) thin / negative savings
    if rate < 0:
        flags.append(("Negative savings", 35,
                      f"You spent more than you earned over the period (savings rate {rate:.0f}%)."))
    elif rate < 10:
        flags.append(("Low savings rate", 22,
                      f"Savings rate is just {rate:.0f}% — under the 10% safety floor."))
    # 2) overspending months (only when not already overall-negative)
    if over and rate >= 0:
        sev = 15 if over <= max(1, nmon // 3) else 22
        flags.append(("Overspending months", sev,
                      f"Spending beat income in {over} of {nmon} months."))
    # 3) rising discretionary spend (food/shopping/entertainment), half over half
    if len(months) >= 2 and DISCRETIONARY:
        half = len(months) // 2
        h1, h2 = months[:half], months[half:]
        qm = ",".join("?" * len(DISCRETIONARY))
        s1 = ",".join("?" * len(h1)) or "''"
        s2 = ",".join("?" * len(h2)) or "''"
        w, p = _scope(user_id, doc_name, period)
        con = connect()
        d1, d2 = con.execute(
            f"""SELECT COALESCE(SUM(CASE WHEN month IN ({s1}) THEN debit END),0),
                       COALESCE(SUM(CASE WHEN month IN ({s2}) THEN debit END),0)
                FROM transactions WHERE {w} AND category IN ({qm})""",
            h1 + h2 + p + sorted(DISCRETIONARY)).fetchone()
        con.close()
        a1, a2 = d1 / (len(h1) or 1), d2 / (len(h2) or 1)
        if a1 > 0 and (a2 - a1) / a1 * 100 > 30:
            g = (a2 - a1) / a1 * 100
            flags.append(("Rising discretionary spend", 15,
                          f"Discretionary spend (food/shopping/entertainment) climbed {g:.0f}% — "
                          f"{inr(a1)} to {inr(a2)} per month."))
    # 4) single-income-source dependence
    src = [r for r in income_by_source(user_id, doc_name, period) if r[1] > 0]
    if src and inc > 0:
        dep = src[0][1] / inc * 100
        if dep >= 80:
            flags.append(("Single income source", 20,
                          f"{dep:.0f}% of income comes from one source ({_mname(src[0][0])})."))
        elif dep >= 60:
            flags.append(("Income concentration", 12,
                          f"{dep:.0f}% of income comes from one source ({_mname(src[0][0])})."))
    # 5) merchant concentration
    tm = top_merchants(user_id, 5, doc_name, period)
    if tm and sp > 0:
        mc = sum(t for _m, t, _c in tm) / sp * 100
        if mc >= 60:
            flags.append(("Spending concentration", 10,
                          f"Your top 5 merchants are {mc:.0f}% of all spending."))
    # 6) thin cash buffer
    bal = latest_balance(user_id, doc_name, period)
    if bal is not None and msp > 0 and bal / msp < 1:
        flags.append(("Thin cash buffer", 10,
                      f"Closing balance of {inr(bal)} covers under a month of spending."))

    score = min(100, sum(s for _r, s, _d in flags))
    level = _rating(score, [(66, "High"), (35, "Medium"), (15, "Low"), (0, "Minimal")])
    flags.sort(key=lambda f: f[1], reverse=True)
    return {"risk_score": score, "risk_level": level,
            "flags": [{"rule": r, "severity": s, "detail": d} for r, s, d in flags]}


def behavior_metrics(user_id, doc_name=None, period=None):
    """Behavioural diagnostics (how you spend, not how much): weekend-vs-weekday
    intensity, month-end vs month-start, impulse/small-spend frequency and the
    single-merchant dependency. Returns a dict, or None when there is no spend."""
    o = overview(user_id, doc_name, period)
    if o["count"] == 0 or o["debit"] <= 0:
        return None
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    we_sum, wd_sum, we_days, wd_days = con.execute(
        f"""SELECT
              COALESCE(SUM(CASE WHEN CAST(strftime('%w',txn_date) AS INT) IN (0,6) THEN debit END),0),
              COALESCE(SUM(CASE WHEN CAST(strftime('%w',txn_date) AS INT) NOT IN (0,6) THEN debit END),0),
              COUNT(DISTINCT CASE WHEN CAST(strftime('%w',txn_date) AS INT) IN (0,6) THEN txn_date END),
              COUNT(DISTINCT CASE WHEN CAST(strftime('%w',txn_date) AS INT) NOT IN (0,6) THEN txn_date END)
            FROM transactions WHERE {w} AND debit>0""", p).fetchone()
    eom, som = con.execute(
        f"""SELECT COALESCE(SUM(CASE WHEN day>=21 THEN debit END),0),
                   COALESCE(SUM(CASE WHEN day<=10 THEN debit END),0)
            FROM transactions WHERE {w} AND debit>0""", p).fetchone()
    thr = 500.0
    dcount, small = con.execute(
        f"""SELECT COUNT(*), COALESCE(SUM(CASE WHEN debit<? THEN 1 ELSE 0 END),0)
            FROM transactions WHERE {w} AND debit>0""", [thr] + p).fetchone()
    con.close()

    we_per = we_sum / we_days if we_days else 0.0
    wd_per = wd_sum / wd_days if wd_days else 0.0
    tm = top_merchants(user_id, 1, doc_name, period)
    return {
        "weekend_spend": we_sum, "weekday_spend": wd_sum,
        "weekend_per_day": we_per, "weekday_per_day": wd_per,
        "weekend_ratio": (we_per / wd_per) if wd_per else 0.0,
        "eom_spend": eom, "som_spend": som,
        "eom_ratio": (eom / som) if som else 0.0,
        "debit_count": dcount, "small_count": small, "small_threshold": thr,
        "impulse_share": (small / dcount * 100) if dcount else 0.0,
        "top_merchant": _mname(tm[0][0]) if tm else None,
        "top_merchant_share": (tm[0][1] / o["debit"] * 100) if (tm and o["debit"] > 0) else 0.0,
    }


def transaction_impact(user_id, n=5, doc_name=None, period=None):
    """Rank the individual transactions that move the financial picture most.
    impact = signed (credit +, debit -) size of the transaction relative to the
    single largest transaction on record, plus a small bump for committed
    obligations and income. Deduped to one (the heaviest) line per merchant so the
    list shows variety, not five identical salary credits. Returns top-n dicts."""
    o = overview(user_id, doc_name, period)
    if o["count"] == 0:
        return []
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    # Pull the biggest debits and biggest credits SEPARATELY, so large expenses are
    # never crowded out of the candidate pool by even-larger salary credits.
    deb_rows = con.execute(
        f"""SELECT txn_date, merchant, category, debit FROM transactions
            WHERE {w} AND debit>0 ORDER BY debit DESC LIMIT 80""", p).fetchall()
    cre_rows = con.execute(
        f"""SELECT txn_date, merchant, category, credit FROM transactions
            WHERE {w} AND credit>0 ORDER BY credit DESC LIMIT 80""", p).fetchall()
    con.close()
    max_deb = max((r[3] for r in deb_rows), default=1.0) or 1.0
    max_cre = max((r[3] for r in cre_rows), default=1.0) or 1.0
    heavy = {"Investment & Insurance", "Income"}
    best = {}  # merchant -> heaviest-impact transaction seen
    def consider(dt, mer, cat, amt, credit):
        base = amt / (max_cre if credit else max_deb) * 100
        bump = 8 if cat in heavy else 0
        impact = round((1 if credit else -1) * min(100.0, base + bump))
        rec = {"date": dt, "merchant": _mname(mer), "category": cat, "amount": amt,
               "direction": "credit" if credit else "debit", "impact": impact}
        if mer not in best or abs(impact) > abs(best[mer]["impact"]):
            best[mer] = rec
    for dt, mer, cat, amt in cre_rows:
        consider(dt, mer, cat, amt, True)
    for dt, mer, cat, amt in deb_rows:
        consider(dt, mer, cat, amt, False)
    out = sorted(best.values(), key=lambda r: abs(r["impact"]), reverse=True)
    return out[:n]


def category_trend(user_id, window=3, doc_name=None, period=None):
    """Longitudinal category trend: average monthly spend over the most recent
    `window` months vs the `window` months before, per category, % change,
    fastest-growing first. Returns dict or None (needs >= 2 months)."""
    months = months_list(user_id, doc_name, period)
    if len(months) < 2:
        return None
    window = max(1, min(window, len(months) // 2))
    recent = months[-window:]
    prior = months[-2 * window:-window]
    if not prior:
        return None
    rs = ",".join("?" * len(recent))
    ps = ",".join("?" * len(prior))
    w, p = _scope(user_id, doc_name, period)
    con = connect()
    rows = con.execute(
        f"""SELECT category,
                   COALESCE(SUM(CASE WHEN month IN ({rs}) THEN debit END),0),
                   COALESCE(SUM(CASE WHEN month IN ({ps}) THEN debit END),0)
            FROM transactions WHERE {w} AND debit>0 GROUP BY category""",
        recent + prior + p).fetchall()
    con.close()
    nr, npr = len(recent), len(prior)
    movers = []
    for cat, r, pr in rows:
        ar, ap = r / nr, pr / npr
        if ar == 0 and ap == 0:
            continue
        chg = ((ar - ap) / ap * 100) if ap > 0 else (100.0 if ar > 0 else 0.0)
        movers.append({"category": cat, "recent_avg": ar, "prior_avg": ap, "change": chg})
    movers.sort(key=lambda d: d["change"], reverse=True)
    return {"window": window, "recent": recent, "prior": prior, "movers": movers}


# ------------------------------------------------------------------ insight store


def save_insights(user_id, items, doc_name=None):
    """Replace this user/doc's stored insights with a freshly computed set."""
    con = connect()
    con.execute("DELETE FROM insights WHERE user_id=? AND COALESCE(doc_name,'')=COALESCE(?,'')",
                (user_id, doc_name or ""))
    con.executemany(
        "INSERT INTO insights(user_id,doc_name,type,title,explanation,score,evidence) "
        "VALUES(?,?,?,?,?,?,?)",
        [(user_id, doc_name, it["type"], it["title"], it.get("explanation", ""),
          it.get("score"), it.get("evidence", "")) for it in items])
    con.commit()
    con.close()
    return len(items)


def get_insights(user_id, doc_name=None, type=None):
    """Read back stored insights (highest score first). Empty list if none."""
    w = "user_id=?"
    p = [user_id]
    if doc_name:
        w += " AND doc_name=?"; p.append(doc_name)
    if type:
        w += " AND type=?"; p.append(type)
    con = connect()
    rows = con.execute(f"""SELECT type,title,explanation,score,evidence FROM insights
                           WHERE {w} ORDER BY score DESC""", p).fetchall()
    con.close()
    return [{"type": t, "title": ti, "explanation": e, "score": s, "evidence": ev}
            for t, ti, e, s, ev in rows]


def compute_insights(user_id, doc_name=None, period=None):
    """The Insight Engine: run the deterministic engines once and emit a list of
    insight rows (type/title/explanation/score/evidence) ready to persist. Pure SQL
    — no LLM, no sklearn (auto-recurring is surfaced separately at the ML layer)."""
    items = []
    h = health_score(user_id, doc_name, period)
    if h:
        c = h["components"]
        items.append({
            "type": "health",
            "title": f"Financial health: {h['rating']} ({h['score']}/100)",
            "explanation": (f"Savings {c['Savings']}/25, spending discipline "
                            f"{c['Spending discipline']}/25, income stability "
                            f"{c['Income stability']}/25, diversification {c['Diversification']}/25."),
            "score": h["score"], "evidence": json.dumps(h)})
    r = risk_assessment(user_id, doc_name, period)
    if r:
        items.append({
            "type": "risk",
            "title": f"Risk level: {r['risk_level']} ({r['risk_score']}/100)",
            "explanation": ("; ".join(f["detail"] for f in r["flags"])
                            or "No significant structural risks detected."),
            "score": r["risk_score"], "evidence": json.dumps(r)})
    ct = category_trend(user_id, 3, doc_name, period)
    if ct and ct["movers"]:
        top = ct["movers"][0]
        if top["change"] > 15:
            items.append({
                "type": "pattern",
                "title": f"{top['category']} spending is rising",
                "explanation": (f"{top['category']} averaged {inr(top['recent_avg'])}/month recently "
                                f"vs {inr(top['prior_avg'])} before (+{top['change']:.0f}%)."),
                "score": round(min(100, abs(top["change"]))), "evidence": json.dumps(top)})
    b = behavior_metrics(user_id, doc_name, period)
    if b and b["weekend_ratio"] >= 1.3:
        items.append({
            "type": "behavior",
            "title": "Weekend spending spikes",
            "explanation": (f"You spend about {b['weekend_ratio']:.1f}x as much per weekend day "
                            f"({inr(b['weekend_per_day'])}) as per weekday ({inr(b['weekday_per_day'])})."),
            "score": round(min(100, b["weekend_ratio"] * 30)), "evidence": json.dumps(b)})
    if b and b["impulse_share"] >= 50:
        items.append({
            "type": "behavior",
            "title": "Lots of small, frequent spends",
            "explanation": (f"{grp(b['small_count'])} of {grp(b['debit_count'])} debits "
                            f"({b['impulse_share']:.0f}%) are under {inr(b['small_threshold'])}."),
            "score": round(b["impulse_share"]), "evidence": json.dumps(b)})
    for it in transaction_impact(user_id, 3, doc_name, period):
        if it["direction"] == "debit" and abs(it["impact"]) >= 50:
            items.append({
                "type": "impact",
                "title": f"High-impact expense: {it['merchant']}",
                "explanation": f"{inr(it['amount'])} to {it['merchant']} was a large single hit on your balance.",
                "score": abs(it["impact"]), "evidence": json.dumps(it)})
    return items


# ------------------------------------------------------------------ router
MONTHS = {"01": "Jan", "02": "Feb", "03": "Mar", "04": "Apr", "05": "May", "06": "Jun",
          "07": "Jul", "08": "Aug", "09": "Sep", "10": "Oct", "11": "Nov", "12": "Dec"}


