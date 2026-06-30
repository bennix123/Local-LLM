"""
Generate a REALISTIC personal bank statement with patterns that machine
learning can actually find — used to showcase the scikit-learn insight layer:

  * fixed-amount monthly subscriptions / bills / EMI   -> recurring detection
  * a monthly salary credit (with a mid-period raise)  -> recurring income
  * a few injected ANOMALIES (known merchants at absurd amounts)
                                                       -> anomaly detection
  * a long noisy tail of ordinary spends               -> realistic baseline

Emits the same 2-space tabular PDF layout the SQL parser expects, plus a
sidecar *_truth.json listing the planted recurring + anomalies so the ML
results can be checked.

    python scripts/generate_realistic.py --out data/statement_real.pdf
"""
import argparse
import calendar
import json
import os
import random
from datetime import date

from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import A4

from generate_statement import fmt_inr   # reuse the Indian-comma formatter

# ----- ordinary noise pool: (merchant, category, type, (lo, hi)) -----
NOISE = [
    ("Swiggy", "Food & Dining", "UPI", (120, 900)),
    ("Zomato", "Food & Dining", "UPI", (150, 1100)),
    ("Amazon", "Shopping", "UPI", (200, 8000)),
    ("Flipkart", "Shopping", "UPI", (250, 9000)),
    ("Myntra", "Shopping", "UPI", (400, 6000)),
    ("BigBasket", "Groceries", "UPI", (300, 4500)),
    ("Blinkit", "Groceries", "UPI", (100, 2200)),
    ("DMart", "Groceries", "UPI", (500, 7000)),
    ("Uber", "Transport", "UPI", (60, 850)),
    ("Ola", "Transport", "UPI", (50, 700)),
    ("IRCTC", "Transport", "NEFT", (200, 3500)),
    ("BookMyShow", "Entertainment", "UPI", (200, 2400)),
    ("Apollo Pharmacy", "Healthcare", "UPI", (100, 3000)),
    ("PharmEasy", "Healthcare", "UPI", (150, 4000)),
    ("Zerodha", "Investment & Insurance", "NEFT", (5000, 80000)),
]
CREDIT_NOISE = [
    ("Interest Earned", "INT", (50, 2500)),
    ("UPI Received", "UPI", (100, 15000)),
    ("Refund", "UPI", (100, 6000)),
]

# ----- fixed recurring debits: (merchant, type, amount, day, every_n_months) -----
RECURRING = [
    ("Netflix", "UPI", 649, 12, 1),
    ("Spotify", "UPI", 119, 7, 1),
    ("Jio", "UPI", 399, 18, 1),
    ("Airtel", "UPI", 599, 22, 1),
    ("Tata Power", "NEFT", 1800, 9, 1),
    ("Cult Gym", "UPI", 1500, 3, 1),          # not in any keyword map -> "Other"
    ("House Rent", "NEFT", 22000, 2, 1),      # not in any keyword map -> "Other"
    ("Axis Bank Car Loan", "NEFT", 14500, 5, 1),   # EMI
    ("LIC Premium", "NEFT", 12000, 10, 3),    # quarterly
]

# ----- injected anomalies: known merchants at wildly off amounts -----
# (merchant, type, amount, year, month, day) — far above the merchant's normal range
ANOMALIES = [
    ("Amazon", "UPI", 234000, 2024, 3, 14),
    ("Apollo Pharmacy", "UPI", 248000, 2024, 6, 9),
    ("Swiggy", "UPI", 86000, 2024, 8, 21),
    ("Flipkart", "UPI", 295000, 2024, 11, 27),
    ("Uber", "UPI", 62000, 2025, 1, 5),
    ("DMart", "UPI", 178000, 2025, 2, 18),
    ("Myntra", "UPI", 210000, 2025, 4, 2),
    ("Zerodha", "NEFT", 640000, 2025, 5, 30),
    ("IRCTC", "NEFT", 141000, 2025, 7, 12),
    ("PharmEasy", "UPI", 190000, 2025, 9, 8),
    ("BigBasket", "UPI", 120000, 2025, 10, 16),
    ("Tata Power", "NEFT", 96000, 2025, 12, 11),
]

CATEGORY = {  # merchant -> category for the deterministic columns (parser re-derives, but keep consistent)
    m[0]: m[1] for m in NOISE
}


def _day(y, m, d):
    return date(y, m, min(d, calendar.monthrange(y, m)[1]))


def build_txns(rng, start=date(2024, 1, 1), end=date(2025, 12, 31),
               noise_per_month=180, credits_per_month=40):
    txns = []   # (date, merchant, type, amount, is_debit)
    months = []
    y, m = start.year, start.month
    while (y, m) <= (end.year, end.month):
        months.append((y, m))
        m += 1
        if m == 13:
            m, y = 1, y + 1

    # recurring debits
    for mi, (y, m) in enumerate(months):
        for merch, ttype, amt, day, every in RECURRING:
            if mi % every != 0:
                continue
            jitter = rng.randint(-1, 1)                      # ±1 day, amount fixed
            txns.append((_day(y, m, day + jitter), merch, ttype, float(amt), True))
        # monthly salary (raise after 12 months)
        sal = 85000 if mi < 12 else 92000
        txns.append((_day(y, m, 1), "Salary Credit", "NEFT", float(sal), False))

    # ordinary noise
    for (y, m) in months:
        last = calendar.monthrange(y, m)[1]
        for _ in range(noise_per_month):
            merch, cat, ttype, (lo, hi) = rng.choice(NOISE)
            txns.append((_day(y, m, rng.randint(1, last)), merch, ttype,
                         round(rng.uniform(lo, hi), 2), True))
        for _ in range(credits_per_month):
            merch, ttype, (lo, hi) = rng.choice(CREDIT_NOISE)
            txns.append((_day(y, m, rng.randint(1, last)), merch, ttype,
                         round(rng.uniform(lo, hi), 2), False))

    # anomalies
    for merch, ttype, amt, y, m, d in ANOMALIES:
        txns.append((_day(y, m, d), merch, ttype, float(amt), True))

    txns.sort(key=lambda t: t[0])
    return txns, months


def generate(out_path, seed=7, start_balance=120000.0):
    rng = random.Random(seed)
    txns, months = build_txns(rng)

    c = canvas.Canvas(out_path, pagesize=A4)
    width, height = A4
    x, line_h, top, bottom = 40, 11, height - 90, 50

    def header():
        c.setFont("Helvetica-Bold", 14)
        c.drawString(x, height - 45, "STATE BANK OF INDIA - Account Statement")
        c.setFont("Helvetica", 8)
        c.drawString(x, height - 60, "Account No: 3041 5567 8899   Name: TEST USER   Branch: Bengaluru MG Road")
        c.drawString(x, height - 70, "Period: 2024-01-01 to 2025-12-31   Currency: INR")
        c.setFont("Helvetica-Bold", 8)
        c.drawString(x, height - 82, "Date         Description                                  Type   Debit            Credit           Balance")

    header()
    c.setFont("Courier", 7)
    y = top
    balance = start_balance
    for i, (d, merch, ttype, amt, is_debit) in enumerate(txns):
        if is_debit:
            balance -= amt
            drcr, debit_s, credit_s = "DR", fmt_inr(amt), ""
        else:
            balance += amt
            drcr, debit_s, credit_s = "CR", "", fmt_inr(amt)
        ref = f"REF{i:08d}"
        desc = f"{ttype}/{merch.replace(' ', '_')}/{ref}"
        line = f"{d.strftime('%d-%m-%Y')}  {desc:<44.44}  {drcr}  {debit_s:>14}  {credit_s:>14}  {fmt_inr(balance):>16}"
        c.drawString(x, y, line)
        y -= line_h
        if y < bottom:
            c.showPage(); header(); c.setFont("Courier", 7); y = top
    c.save()

    truth = {
        "rows": len(txns), "months": len(months),
        "planted_recurring": [
            {"merchant": r[0], "amount": r[1], "cadence": "monthly" if r[4] == 1 else f"every {r[4]}m"}
            for r in RECURRING
        ] + [{"merchant": "Salary Credit", "amount": "85000→92000", "cadence": "monthly (income)"}],
        "planted_anomalies": [
            {"merchant": a[0], "amount": a[2], "date": f"{a[3]}-{a[4]:02d}-{a[5]:02d}"} for a in ANOMALIES
        ],
        "final_balance": round(balance, 2),
    }
    with open(os.path.splitext(out_path)[0] + "_truth.json", "w") as f:
        json.dump(truth, f, indent=2)

    print(f"PDF: {out_path}  ({os.path.getsize(out_path)/1e6:.2f} MB, {len(txns):,} txns)")
    print(f"  planted recurring : {len(RECURRING)} bills + salary")
    print(f"  planted anomalies : {len(ANOMALIES)}")
    print(f"  final balance     : {fmt_inr(balance)}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="data/statement_real.pdf")
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    generate(args.out, seed=args.seed)
