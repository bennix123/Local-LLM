"""
Generate a realistic Indian-bank-statement PDF with N transactions, plus a
sidecar ground-truth JSON of the exact aggregates. Used to stress-test the
deterministic SQL layer at lakh scale.

    python scripts/generate_statement.py --rows 100000 --out data/statement_1lakh.pdf

The PDF is a plain text-tabular layout (one transaction per line) so PyMuPDF's
get_text("text") extracts one clean row per line. Columns are separated by 2+
spaces; descriptions never contain a double space, so the parser can split on
runs of whitespace. Amounts use Indian comma grouping (realistic + exercises
the parser's comma stripping).
"""
import argparse
import json
import os
import random
from datetime import date, timedelta

from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import A4

# (merchant, category, txn-type, [min, max] amount range, debit?)
MERCHANTS = [
    ("Swiggy", "Food & Dining", "UPI", (120, 900), True),
    ("Zomato", "Food & Dining", "UPI", (150, 1100), True),
    ("Amazon", "Shopping", "UPI", (200, 8000), True),
    ("Flipkart", "Shopping", "UPI", (250, 9000), True),
    ("Myntra", "Shopping", "UPI", (400, 6000), True),
    ("BigBasket", "Groceries", "UPI", (300, 4500), True),
    ("Blinkit", "Groceries", "UPI", (100, 2200), True),
    ("DMart", "Groceries", "UPI", (500, 7000), True),
    ("Uber", "Transport", "UPI", (60, 850), True),
    ("Ola", "Transport", "UPI", (50, 700), True),
    ("IRCTC", "Transport", "NEFT", (200, 3500), True),
    ("Netflix", "Entertainment", "UPI", (199, 799), True),
    ("Spotify", "Entertainment", "UPI", (59, 299), True),
    ("BookMyShow", "Entertainment", "UPI", (200, 2400), True),
    ("Jio", "Utilities", "UPI", (199, 999), True),
    ("Airtel", "Utilities", "UPI", (299, 1499), True),
    ("Tata Power", "Utilities", "NEFT", (500, 5000), True),
    ("Apollo Pharmacy", "Healthcare", "UPI", (100, 3000), True),
    ("PharmEasy", "Healthcare", "UPI", (150, 4000), True),
    ("LIC Premium", "Investment & Insurance", "NEFT", (2000, 25000), True),
    ("Zerodha", "Investment & Insurance", "NEFT", (5000, 80000), True),
    ("Axis Bank Car Loan", "Investment & Insurance", "NEFT", (12000, 18000), True),
]
# Credits (income)
CREDITS = [
    ("Salary Credit", "Income", "NEFT", (60000, 95000)),
    ("Interest Earned", "Income", "INT", (50, 2500)),
    ("UPI Received", "Income", "UPI", (100, 15000)),
    ("Refund", "Income", "UPI", (100, 6000)),
]


def fmt_inr(n):
    """Indian comma grouping with 2 decimals: 1234567.5 -> '12,34,567.50'."""
    neg = n < 0
    n = abs(round(n, 2))
    s = f"{n:.2f}"
    intpart, dec = s.split(".")
    if len(intpart) > 3:
        head, tail = intpart[:-3], intpart[-3:]
        groups = []
        while len(head) > 2:
            groups.insert(0, head[-2:])
            head = head[:-2]
        if head:
            groups.insert(0, head)
        intpart = ",".join(groups) + "," + tail
    out = f"{intpart}.{dec}"
    return f"-{out}" if neg else out


def generate(rows, out_path, seed=42, start_balance=50000.0,
             start_date=date(2024, 1, 1), end_date=date(2025, 12, 31)):
    rng = random.Random(seed)
    span_days = (end_date - start_date).days

    # ground-truth accumulators
    gt = {
        "rows": rows, "total_debit": 0.0, "total_credit": 0.0,
        "by_category": {}, "by_merchant": {}, "by_month": {},
        "upi_count": 0, "debit_count": 0, "credit_count": 0,
        "largest_debit": 0.0, "smallest_debit": None, "largest_credit": 0.0,
    }

    c = canvas.Canvas(out_path, pagesize=A4)
    width, height = A4
    x = 40
    line_h = 11
    top = height - 90
    bottom = 50

    def header(page_no):
        c.setFont("Helvetica-Bold", 14)
        c.drawString(x, height - 45, "STATE BANK OF INDIA - Account Statement")
        c.setFont("Helvetica", 8)
        c.drawString(x, height - 60, "Account No: 3041 5567 8899   Name: TEST USER   Branch: Bengaluru MG Road")
        c.drawString(x, height - 70, f"Period: {start_date.isoformat()} to {end_date.isoformat()}   Currency: INR")
        c.setFont("Helvetica-Bold", 8)
        c.drawString(x, height - 82, "Date         Description                                  Type   Debit            Credit           Balance")

    header(1)
    c.setFont("Courier", 7)
    y = top
    balance = start_balance

    # pre-pick dates sorted so balance is chronological
    days = sorted(rng.randint(0, span_days) for _ in range(rows))

    for i in range(rows):
        d = start_date + timedelta(days=days[i])
        is_debit = rng.random() < 0.78  # ~78% spends, 22% credits
        if is_debit:
            merch, cat, ttype, (lo, hi), _ = rng.choice(MERCHANTS)
            amt = round(rng.uniform(lo, hi), 2)
            balance -= amt
            gt["total_debit"] += amt
            gt["debit_count"] += 1
            gt["largest_debit"] = max(gt["largest_debit"], amt)
            gt["smallest_debit"] = amt if gt["smallest_debit"] is None else min(gt["smallest_debit"], amt)
            drcr, debit_s, credit_s = "DR", fmt_inr(amt), ""
        else:
            merch, cat, ttype, (lo, hi) = rng.choice(CREDITS)
            amt = round(rng.uniform(lo, hi), 2)
            balance += amt
            gt["total_credit"] += amt
            gt["credit_count"] += 1
            gt["largest_credit"] = max(gt["largest_credit"], amt)
            drcr, debit_s, credit_s = "CR", "", fmt_inr(amt)

        if ttype == "UPI":
            gt["upi_count"] += 1
        ym = d.strftime("%Y-%m")
        gt["by_category"][cat] = round(gt["by_category"].get(cat, 0.0) + (amt if is_debit else 0.0), 2)
        gt["by_merchant"][merch] = round(gt["by_merchant"].get(merch, 0.0) + (amt if is_debit else 0.0), 2)
        m = gt["by_month"].setdefault(ym, {"debit": 0.0, "credit": 0.0})
        m["debit" if is_debit else "credit"] = round(m["debit" if is_debit else "credit"] + amt, 2)

        ref = f"REF{i:08d}"
        desc = f"{ttype}/{merch.replace(' ', '_')}/{ref}"
        # 2-space-separated columns; description has no double spaces
        line = f"{d.strftime('%d-%m-%Y')}  {desc:<44.44}  {drcr}  {debit_s:>14}  {credit_s:>14}  {fmt_inr(balance):>16}"
        c.drawString(x, y, line)
        y -= line_h
        if y < bottom:
            c.showPage()
            header(0)
            c.setFont("Courier", 7)
            y = top

    c.save()

    # round + finalize ground truth
    gt["total_debit"] = round(gt["total_debit"], 2)
    gt["total_credit"] = round(gt["total_credit"], 2)
    gt["net"] = round(gt["total_credit"] - gt["total_debit"], 2)
    gt["final_balance"] = round(balance, 2)
    gt_path = os.path.splitext(out_path)[0] + "_truth.json"
    with open(gt_path, "w") as f:
        json.dump(gt, f, indent=2)

    size_mb = os.path.getsize(out_path) / 1e6
    print(f"PDF:   {out_path}  ({size_mb:.1f} MB, {rows:,} txns)")
    print(f"Truth: {gt_path}")
    print(f"  total debit  {fmt_inr(gt['total_debit'])}")
    print(f"  total credit {fmt_inr(gt['total_credit'])}")
    print(f"  net          {fmt_inr(gt['net'])}")
    print(f"  final bal    {fmt_inr(gt['final_balance'])}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=100000)
    ap.add_argument("--out", default="data/statement.pdf")
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    generate(args.rows, args.out, seed=args.seed)
