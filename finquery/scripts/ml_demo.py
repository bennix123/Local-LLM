"""
Run the scikit-learn insight layer on the live transaction DB and print a
readable report. Proves all four capabilities on the real (lakh-row) data.
"""
import os
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "backend", "src"))
from services import txn_store as ts
from services import ml_insights as ml

ts.DB_PATH = os.environ.get(
    "FINQ_DB", os.path.join(os.path.dirname(__file__), "..", "data", "live_txn.db"))
USER = "local"
inr = ts.inr


def section(t):
    print("\n" + "=" * 70 + f"\n{t}\n" + "=" * 70)


def main():
    o = ts.overview(USER)
    print(f"DB: {o['count']:,} transactions · spend {inr(o['debit'])} · income {inr(o['credit'])}")

    # 1) anomalies
    section("1 · ANOMALY DETECTION  (IsolationForest)")
    t = time.time()
    a = ml.anomalies(USER)
    print(f"trained on {a['trained_on']:,} expenses · flagged {a['flagged']} unusual · {time.time()-t:.1f}s\n")
    for it in a["items"]:
        print(f"  {it['date']:<13} {it['merchant']:<20} {inr(it['amount']):>16}   ← {it['reason']}")

    # 2) forecast
    section("2 · SPEND FORECAST  (LinearRegression per category)")
    t = time.time()
    f = ml.forecast(USER)
    print(f"from {f['months_seen']} months → forecast for {f['next_month']} · {time.time()-t:.1f}s\n")
    for c in f["per_category"]:
        arrow = {"rising": "▲", "falling": "▼", "flat": "≈"}[c["trend"]]
        print(f"  {c['name']:<24} {inr(c['predicted']):>15}  {arrow} (recent avg {inr(c['recent_avg'])})")
    tot = f["total"]
    print(f"\n  TOTAL next month ≈ {inr(tot['predicted'])}  (range {inr(tot['lo'])} – {inr(tot['hi'])})")

    # 3) recurring
    section("3 · RECURRING DETECTION  (DBSCAN + cadence, no hardcoded list)")
    t = time.time()
    r = ml.recurring(USER)
    print(f"detected {len(r['items'])} recurring charges · {time.time()-t:.1f}s\n")
    for it in r["items"]:
        flag = "" if it["merchant"] in r["hardcoded_list"] else "  ✦ NEW (not in old list)"
        print(f"  {it['merchant']:<22} {it['cadence']:<14} {inr(it['amount']):>14}  ×{it['count']:<3} conf {it['confidence']}{flag}")
    print(f"\n  hardcoded list was: {', '.join(r['hardcoded_list'])}")
    if r["newly_found"]:
        print(f"  ML additionally found: {', '.join(r['newly_found'])}")

    # 4) categorize
    section("4 · AUTO-CATEGORISATION  (TF-IDF + LogisticRegression)")
    t = time.time()
    c = ml.categorizer_report(USER)
    acc = f"{c['accuracy']*100:.1f}% ± {c['accuracy_std']*100:.1f}" if c["accuracy"] is not None else "n/a"
    print(f"trained on {c['trained_on']:,} rows · {c['classes']} categories · 3-fold accuracy {acc} · {time.time()-t:.1f}s")
    print(f"('Other'/signal-less transfers: {c['other_total']:,} · model abstains, labels 0 — correct)\n")
    print("  generalisation probe — merchants the keyword map has NEVER seen:")
    for e in c.get("generalization_probe", []):
        print(f"    {e['descr']:<32} → {e['predicted']:<22} ({e['confidence']})")

    section("done")


if __name__ == "__main__":
    main()
