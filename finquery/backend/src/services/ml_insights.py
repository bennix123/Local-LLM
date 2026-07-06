"""
ml_insights.py — a scikit-learn layer on top of the deterministic SQL store.

Design rule (unchanged from the rest of FinQuery): exact rupee figures still
come from SQL. scikit-learn only decides *which* rows are unusual, *what* next
month looks like, *which* charges recur, and *what category* an unseen merchant
belongs to. No model here invents a number that contradicts the ledger — every
amount returned is read straight from the transactions table.

Capabilities
  anomalies()          IsolationForest  -> unusual transactions
  forecast()           LinearRegression -> next-month spend per category
  recurring()          DBSCAN + cadence -> auto-detected subscriptions/EMIs
  categorizer_report() TF-IDF + LogReg  -> learn categories, generalise to unseen
"""
import os
import sys
from collections import Counter, defaultdict
from datetime import date

os.environ.setdefault("LOKY_MAX_CPU_COUNT", "4")   # silence joblib core-count probe on Windows

import numpy as np
from sklearn.ensemble import IsolationForest
from sklearn.preprocessing import StandardScaler, LabelEncoder
from sklearn.linear_model import LinearRegression, LogisticRegression
from sklearn.cluster import DBSCAN
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.pipeline import make_pipeline
from sklearn.model_selection import cross_val_score

try:                                   # works whether imported as a package or flat
    from . import txn_store as ts
except Exception:                      # pragma: no cover
    sys.path.insert(0, os.path.dirname(__file__))
    import txn_store as ts             # type: ignore

RNG = 42


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def _next_month_label(ym):
    """'2025-06' -> 'Jul 2025'."""
    y, m = int(ym[:4]), int(ym[5:7])
    m += 1
    if m == 13:
        m, y = 1, y + 1
    return f"{ts.MONTHS[f'{m:02d}']} {y}"


def _cadence(med_gap_days):
    g = med_gap_days
    if 5 <= g <= 9:
        return "weekly"
    if 12 <= g <= 16:
        return "fortnightly"
    if 26 <= g <= 33:
        return "monthly"
    if 58 <= g <= 64:
        return "every 2 months"
    if 85 <= g <= 96:
        return "quarterly"
    if 175 <= g <= 190:
        return "half-yearly"
    if 350 <= g <= 380:
        return "yearly"
    return f"every ~{int(round(g))}d"


# --------------------------------------------------------------------------- #
# 1) ANOMALY DETECTION  — IsolationForest
# --------------------------------------------------------------------------- #
def anomalies(user_id, n=12, contamination=0.004):
    """Flag expenses that don't fit the spending pattern, biased toward the
    *upper tail* (surprisingly large charges — what a user actually cares about).
    Features: log-amount, robust category z-score, merchant-rarity, day, category.
    IsolationForest picks the unusual rows; we report the biggest of those."""
    con = ts.connect()
    rows = con.execute(
        "SELECT txn_date,merchant,category,debit,day FROM transactions "
        "WHERE user_id=? AND debit>0", (user_id,)).fetchall()
    con.close()
    if len(rows) < 50:
        return {"trained_on": len(rows), "flagged": 0, "items": []}

    dates = [r[0] for r in rows]
    merch = [r[1] for r in rows]
    cats = [r[2] for r in rows]
    amt = np.array([r[3] for r in rows], float)
    dom = np.array([r[4] for r in rows], float)

    mcount = Counter(merch)
    freq = np.array([mcount[m] for m in merch], float)

    # robust per-category center/scale (median + MAD) -> how far above normal
    cvals = defaultdict(list)
    for c, a in zip(cats, amt):
        cvals[c].append(a)
    cmed = {c: float(np.median(v)) for c, v in cvals.items()}
    cmad = {c: float(np.median(np.abs(np.array(v) - np.median(v)))) + 1.0 for c, v in cvals.items()}
    z_cat = np.array([(amt[i] - cmed[cats[i]]) / (1.4826 * cmad[cats[i]]) for i in range(len(amt))])

    mvals = defaultdict(list)
    for m, a in zip(merch, amt):
        mvals[m].append(a)
    mmed = {m: float(np.median(v)) for m, v in mvals.items()}

    cat_code = LabelEncoder().fit_transform(cats)
    X = np.column_stack([np.log1p(amt), z_cat, np.log1p(freq), dom, cat_code])
    Xs = StandardScaler().fit_transform(X)

    iso = IsolationForest(n_estimators=200, contamination=contamination, random_state=RNG)
    pred = iso.fit_predict(Xs)            # -1 = anomaly
    score = iso.score_samples(Xs)         # lower = more anomalous

    cmed_arr = np.array([cmed[c] for c in cats])
    flagged = pred == -1                                 # IsolationForest's call
    strong = z_cat > 3.0                                 # clearly above category norm
    rare_big = (freq <= 3) & (amt > cmed_arr * 2)        # rare merchant, large charge
    # candidates = anything the model OR the deviation test calls unusual, but only
    # on the HIGH side (a surprisingly large charge, not a small one), ranked by size.
    cand = np.where((flagged | strong | rare_big) & (z_cat > 0))[0]
    cand = cand[np.argsort(-amt[cand])][:n]              # biggest unusual first

    items = []
    for i in cand:
        m = merch[i]
        ratio = amt[i] / mmed[m] if mmed[m] else 99.0
        if mcount[m] <= 3:
            reason = "rare merchant, large charge"
        elif ratio >= 3:
            reason = f"{ratio:.1f}× your usual {m}"
        elif z_cat[i] >= 2:
            reason = f"well above your {cats[i]} norm"
        else:
            reason = "unusual for your pattern"
        items.append({
            "date": ts._dlabel(dates[i]) if hasattr(ts, "_dlabel") else dates[i],
            "merchant": m, "category": cats[i], "amount": float(amt[i]),
            "reason": reason, "score": round(float(score[i]), 3),
        })
    return {"trained_on": len(rows), "flagged": int(flagged.sum()), "items": items}


# --------------------------------------------------------------------------- #
# 2) SPEND FORECAST  — LinearRegression per category
# --------------------------------------------------------------------------- #
def forecast(user_id):
    """Fit a linear trend to each category's monthly spend and project next
    month, with a ± band from the regression residuals."""
    con = ts.connect()
    months = [r[0] for r in con.execute(
        "SELECT DISTINCT month FROM transactions WHERE user_id=? ORDER BY month",
        (user_id,))]
    rows = con.execute(
        "SELECT month,category,SUM(debit) FROM transactions "
        "WHERE user_id=? AND debit>0 GROUP BY month,category", (user_id,)).fetchall()
    con.close()
    if len(months) < 3:
        return {"months_seen": len(months), "next_month": None, "per_category": [], "total": None}

    midx = {m: i for i, m in enumerate(months)}
    series = defaultdict(lambda: np.zeros(len(months)))
    for m, c, s in rows:
        series[c][midx[m]] = s

    X = np.arange(len(months)).reshape(-1, 1)
    nxt = len(months)
    per_cat, total_pred, total_var = [], 0.0, 0.0
    for c, y in series.items():
        lr = LinearRegression().fit(X, y)
        pred = max(float(lr.predict([[nxt]])[0]), 0.0)
        resid_std = float((y - lr.predict(X)).std())
        recent = float(y[-3:].mean())
        slope = float(lr.coef_[0])
        trend = "rising" if slope > recent * 0.02 else "falling" if slope < -recent * 0.02 else "flat"
        per_cat.append({"name": c, "predicted": pred, "recent_avg": recent,
                        "band": resid_std, "trend": trend})
        total_pred += pred
        total_var += resid_std ** 2
    per_cat.sort(key=lambda d: d["predicted"], reverse=True)
    band = float(np.sqrt(total_var))
    return {
        "months_seen": len(months), "next_month": _next_month_label(months[-1]),
        "per_category": per_cat,
        "total": {"predicted": total_pred, "lo": max(total_pred - band, 0), "hi": total_pred + band},
    }


# --------------------------------------------------------------------------- #
# 3) RECURRING DETECTION  — DBSCAN on amounts + interval regularity
# --------------------------------------------------------------------------- #
def recurring(user_id, min_occurrences=3):
    """Auto-detect recurring charges (subscriptions, EMIs, bills). For each
    merchant, DBSCAN finds the dominant stable amount; we then require the
    payments to land at a regular cadence. No hardcoded merchant list."""
    con = ts.connect()
    rows = con.execute(
        "SELECT merchant,txn_date,debit FROM transactions "
        "WHERE user_id=? AND debit>0 ORDER BY merchant,txn_date", (user_id,)).fetchall()
    con.close()

    by = defaultdict(list)
    for m, d, a in rows:
        by[m].append((d, a))

    found = []
    for m, txns in by.items():
        if len(txns) < min_occurrences:
            continue
        amts = np.array([a for _, a in txns], float).reshape(-1, 1)
        # tolerance: amounts within ~5% (or a small absolute) count as "the same bill"
        eps = max(float(amts.mean()) * 0.05, 1.0)
        labels = DBSCAN(eps=eps, min_samples=min_occurrences).fit(amts).labels_
        clusters = Counter(l for l in labels if l != -1)
        if not clusters:
            continue
        best = clusters.most_common(1)[0][0]
        mask = labels == best
        if mask.sum() < min_occurrences:
            continue

        ords = sorted(date.fromisoformat(d).toordinal()
                      for (d, _), keep in zip(txns, mask) if keep)
        gaps = np.diff(ords)
        if len(gaps) == 0:
            continue
        med_gap = float(np.median(gaps))
        if med_gap < 3:
            continue
        regularity = 1.0 - min(float(np.std(gaps)) / (med_gap + 1e-9), 1.0)
        if regularity < 0.5:
            continue

        cnt = int(mask.sum())
        amt_recur = float(np.median(amts[mask]))
        total = float(amts[mask].sum())
        conf = round(0.5 * regularity + 0.5 * min(cnt / 12.0, 1.0), 2)
        found.append({"merchant": m, "cadence": _cadence(med_gap),
                      "amount": amt_recur, "count": cnt, "total": total,
                      "regularity": round(regularity, 2), "confidence": conf})

    found.sort(key=lambda d: d["total"], reverse=True)
    hardcoded = sorted(ts.SUBSCRIPTION_MERCHANTS)
    new = [f["merchant"] for f in found if f["merchant"] not in ts.SUBSCRIPTION_MERCHANTS]
    return {"items": found, "hardcoded_list": hardcoded, "newly_found": new}


# --------------------------------------------------------------------------- #
# 4) AUTO-CATEGORISATION  — TF-IDF + LogisticRegression
# --------------------------------------------------------------------------- #
def categorizer_report(user_id, sample=25000):
    """Train a text classifier on already-categorised descriptions, report
    cross-validated accuracy, then apply it to 'Other' (uncategorised) rows to
    show how many it can confidently label that the keyword map missed."""
    con = ts.connect()
    known = con.execute(
        "SELECT descr,category FROM transactions "
        "WHERE user_id=? AND category<>'Other'", (user_id,)).fetchall()
    other = [r[0] for r in con.execute(
        "SELECT descr FROM transactions WHERE user_id=? AND category='Other'",
        (user_id,))]
    con.close()

    if len(known) < 50:
        return {"trained_on": len(known), "accuracy": None, "classes": 0,
                "other_total": len(other), "other_confident": 0, "examples": []}

    X = [r[0] for r in known]
    y = [r[1] for r in known]
    if len(X) > sample:                                  # subsample for speed
        rs = np.random.RandomState(RNG)
        keep = rs.choice(len(X), sample, replace=False)
        X = [X[i] for i in keep]
        y = [y[i] for i in keep]

    pipe = make_pipeline(
        TfidfVectorizer(analyzer="char_wb", ngram_range=(3, 5), min_df=2),
        LogisticRegression(max_iter=2000),
    )
    cv = cross_val_score(pipe, X, y, cv=3)
    pipe.fit(X, y)

    other_conf = 0
    if other:
        conf = pipe.predict_proba(other).max(axis=1)
        other_conf = int((conf >= 0.60).sum())

    # generalisation probe: merchants the keyword map has NEVER seen, but whose
    # text overlaps a known one — shows the classifier transfers, unlike a lookup.
    probe_in = [
        "UPI/Swiggy_Instamart/REF", "UPI/Zomato_Gold/REF", "UPI/Amazon_Fresh/REF",
        "UPI/BigBasket_Daily/REF", "UPI/Ola_Auto/REF", "UPI/PharmEasy_Plus/REF",
        "NEFT/Zerodha_Coin/REF", "UPI/BookMyShow_Stream/REF",
    ]
    pp = pipe.predict_proba(probe_in)
    probe = [{"descr": d, "predicted": pipe.classes_[row.argmax()],
              "confidence": round(float(row.max()), 2)} for d, row in zip(probe_in, pp)]

    return {
        "trained_on": len(X), "accuracy": round(float(cv.mean()), 4),
        "accuracy_std": round(float(cv.std()), 4), "classes": len(set(y)),
        "other_total": len(other), "other_confident": other_conf,
        "generalization_probe": probe,
    }
