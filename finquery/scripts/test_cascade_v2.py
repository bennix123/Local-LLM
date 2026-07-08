"""
test_cascade_v2.py - Revised 4-scenario verification.
Forces L2 and L3 with models that are ACTUALLY available (mistral:latest).
"""
import sys, os, socket, json, time
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "backend"))
sys.path.insert(0, ROOT)

# Override LLM_MODEL to a model we know is installed
os.environ["LLM_MODEL"] = "mistral:latest"

import pymupdf
from src.services.txn_store.parsers import parse_generic_statement, _generic_breaks

# ---------------------------------------------------------------------------
# PDF GENERATORS
# ---------------------------------------------------------------------------

def _page(doc, lines, fontsize=8.5):
    """Add a page with courier text, returning the page."""
    page = doc.new_page(width=595, height=842)
    tw = pymupdf.TextWriter(page.rect)
    font = pymupdf.Font("Courier")
    y = 40
    for line in lines:
        tw.append((40, y), line, fontsize=fontsize, font=font)
        y += 12
        if y > 820:
            break
    tw.write_text(page)
    return page


def make_s1_l2forcing_pdf(path):
    """
    Scenario 1 v2: Format that forces L1 to FAIL.
    Strategy: NO balance column at all. Each line has only date, description, and
    a single amount with a DR/CR suffix. L1 will parse rows but all balances will be 0,
    giving 100% violation ratio -> L1 rejected -> escalates to L2.
    """
    lines = [
        "NOVA COOPERATIVE BANK",
        "Account Statement",
        "Period: Jul 2026",
        "",
        "TXN DATE | NARRATION                             | AMOUNT",
        "---------|---------------------------------------|----------",
        "04-Jul-26| SALARY CR FROM NOVA CORP              | 75000.00CR",
        "05-Jul-26| ATM-SBI BRANCH CASH WD                | 8000.00DR",
        "06-Jul-26| POS-BIGBASKET ONLINE                  | 2340.00DR",
        "07-Jul-26| NEFT-IN VENDOR REFUND                 | 5000.00CR",
        "08-Jul-26| UPI-ZOMATO SWIGGY                     | 890.00DR",
        "09-Jul-26| CHQ CLEARED NO 001234                 | 15000.00DR",
        "10-Jul-26| NEFT-OUT INSURANCE PREMIUM            | 3500.00DR",
        "11-Jul-26| INTEREST CREDIT QUARTERLY             | 1200.00CR",
        "12-Jul-26| POS-PETROL PUMP HPCL                  | 2200.00DR",
        "14-Jul-26| UPI-AMAZON SHOPPING                   | 4599.00DR",
        "15-Jul-26| CREDIT CARD PAYMENT                   | 10000.00DR",
        "16-Jul-26| DIVIDEND INCOME MUTUAL FUND           | 3000.00CR",
        "17-Jul-26| ECS-EMI HDFC HOME LOAN                | 22000.00DR",
        "18-Jul-26| POS-GROCERY DMART                     | 1890.00DR",
        "19-Jul-26| NEFT-RECEIVED FROM CLIENT             | 18000.00CR",
    ]
    doc = pymupdf.open()
    _page(doc, lines)
    doc.save(path)
    doc.close()


def make_s2_bad_balance_pdf(path):
    """
    Scenario 2: Wrong balance column — balance values are RANDOM (not DR-CR reconciling).
    L1 will pick up rows but all balance checks will fail (high violation ratio).
    L2 will get a valid regex from LLM but the regex will extract wrong balance ->
    balance validation inside try_schema_inference rejects L2 -> falls to L3.
    The balance column has garbage values that don't reconcile with any DR/CR pattern.
    """
    lines = [
        "PARAMOUNT BANK LIMITED",
        "Customer: Test User",
        "Acct No: PBL-778899-XX",
        "Statement for: June 2026",
        "",
        "Date         Description                    Debit       Credit      Balance",
        "--------------------------------------------------------------------------",
        # Correct DR, CR entries but Balance column is completely wrong (random)
        "01-Jun-2026  Salary from Paramount Corp     0.00        90000.00    12345.67",
        "02-Jun-2026  Grocery Store Purchase          3200.00     0.00        99999.00",
        "03-Jun-2026  Online Transfer In              0.00        15000.00    11111.11",
        "04-Jun-2026  Electricity Bill Payment        2500.00     0.00        88888.88",
        "05-Jun-2026  EMI Housing Loan                25000.00    0.00        77777.77",
        "06-Jun-2026  Freelance Payment Received      0.00        35000.00    55555.55",
        "07-Jun-2026  Insurance Premium Auto          8000.00     0.00        44444.44",
        "08-Jun-2026  Petrol Pump Payment             1800.00     0.00        33333.33",
        "09-Jun-2026  Dividend from Mutual Fund       0.00        4500.00     22222.22",
        "10-Jun-2026  ATM Cash Withdrawal             5000.00     0.00        11111.11",
        "11-Jun-2026  Credit Card Settlement          12000.00    0.00        00000.01",
        "12-Jun-2026  Vendor Refund Credit            0.00        2000.00     99000.00",
    ]
    doc = pymupdf.open()
    _page(doc, lines)
    doc.save(path)
    doc.close()


def make_s3_15page_nobalance_pdf(path):
    """
    Scenario 3: 15 pages, same no-balance format as Scenario 1 (forces L3).
    With LLM working and 15 pages, Layer 3 will hit the MAX_LLM_FALLBACK_PAGES=10 cap.
    Pages 11-15 are dropped. confidence='partial'.
    """
    lines_per_page = [
        "NOVA COOPERATIVE BANK",
        "Account Statement - Page {pg}",
        "Period: Jul 2026",
        "",
        "TXN DATE | NARRATION                             | AMOUNT",
        "---------|---------------------------------------|----------",
    ]
    txns = [
        "04-Jul-26| SALARY CR FROM NOVA CORP              | 75000.00CR",
        "05-Jul-26| ATM-SBI BRANCH CASH WD                | 8000.00DR",
        "06-Jul-26| POS-BIGBASKET ONLINE                  | 2340.00DR",
        "07-Jul-26| NEFT-IN VENDOR REFUND                 | 5000.00CR",
        "08-Jul-26| UPI-ZOMATO SWIGGY                     | 890.00DR",
        "09-Jul-26| CHQ CLEARED NO 001234                 | 15000.00DR",
        "10-Jul-26| NEFT-OUT INSURANCE PREMIUM            | 3500.00DR",
        "11-Jul-26| INTEREST CREDIT QUARTERLY             | 1200.00CR",
        "12-Jul-26| POS-PETROL PUMP HPCL                  | 2200.00DR",
        "14-Jul-26| UPI-AMAZON SHOPPING                   | 4599.00DR",
    ]
    doc = pymupdf.open()
    for pg in range(1, 16):
        hdr = [l.replace("{pg}", str(pg)) for l in lines_per_page]
        _page(doc, hdr + txns)
    doc.save(path)
    doc.close()


# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

def run_parse(pdf_path, label):
    print(f"\n{'='*68}\n  {label}\n{'='*68}")
    t0 = time.time()
    res = parse_generic_statement(pdf_path)
    rows = list(res)
    confidence = getattr(res, "parse_confidence", "unknown")
    breaks = _generic_breaks(rows) if rows else 0
    ratio = breaks / len(rows) if rows else 0
    elapsed = time.time() - t0
    print(f"\n  RESULT: {len(rows)} rows | confidence={confidence!r} | violations={breaks} ({ratio:.1%}) | elapsed={elapsed:.1f}s")
    if rows:
        for r in rows[:3]:
            print(f"    {r['txn_date']} | {r['descr'][:38]} | Dr:{r['debit']} Cr:{r['credit']} Bal:{r['balance']}")
    return rows, confidence, breaks


def ollama_up(port=11434):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=2)
        s.close()
        return True
    except Exception:
        return False


SDIR = os.path.join(ROOT, "scripts")

# ---------------------------------------------------------------------------
# SCENARIOS
# ---------------------------------------------------------------------------

def scenario_1_v2():
    print("\n" + "#"*68)
    print("  SCENARIO 1 (v2): L2-forcing format (no balance col) -> Layer 2 must trigger")
    print("#"*68)
    pdf = os.path.join(SDIR, "_sv2_s1_nobalance.pdf")
    make_s1_l2forcing_pdf(pdf)
    rows, confidence, breaks = run_parse(pdf, "S1v2 - Nova Bank (no balance col, DR/CR suffix only)")
    print(f"\n  VERDICT: ", end="")
    if confidence in ("medium", "high"):
        print(f"Layer 2 or Layer 3 resolved it. confidence={confidence!r}.")
        print("  (Check [parser-L2] >>> L2 ACCEPTED log above)")
    elif confidence == "low":
        print("Layer 3 resolved it (L2 failed to produce valid schema). confidence='low'.")
    elif confidence == "partial":
        print("Layer 3 ran with page-cap (unexpected on 1-page doc). confidence='partial'.")
    else:
        print(f"Unexpected confidence={confidence!r}.")


def scenario_2():
    print("\n" + "#"*68)
    print("  SCENARIO 2: L2 regex accepted but balance check MUST reject -> fall to L3")
    print("#"*68)
    pdf = os.path.join(SDIR, "_sv2_s2_badbalance.pdf")
    make_s2_bad_balance_pdf(pdf)
    rows, confidence, breaks = run_parse(pdf, "S2 - Paramount Bank (random balance col, Dr/Cr correct)")
    print(f"\n  VERDICT: ", end="")
    # Key expectation: [parser-L2] log should say "L2 REJECTED: balance violation_ratio"
    # and [cascade] should show Layer 3 ran
    if confidence in ("low", "partial"):
        print(f"PASS: confidence={confidence!r}. L3 resolved after L2 balance rejection.")
    elif confidence in ("medium", "high"):
        print(f"confidence={confidence!r}. Check [parser-L2] log - did balance check fire?")
        print("  If L2 ACCEPTED this despite random balances, the balance-check threshold needs review.")
    else:
        print(f"confidence={confidence!r} (unexpected).")


def scenario_3():
    print("\n" + "#"*68)
    print("  SCENARIO 3: 15-page no-balance format -> Layer 3 must run with page-cap -> partial")
    print("#"*68)
    pdf = os.path.join(SDIR, "_sv2_s3_15pages.pdf")
    make_s3_15page_nobalance_pdf(pdf)
    rows, confidence, breaks = run_parse(pdf, "S3 - Nova Bank 15 pages (should hit MAX_LLM_FALLBACK_PAGES=10)")
    print(f"\n  VERDICT: ", end="")
    if confidence == "partial":
        print(f"PASS: confidence='partial'. Layer 3 ran, page cap applied, pages 11-15 dropped. {len(rows)} rows from first 10 pages.")
    elif confidence in ("medium", "high"):
        print(f"Layer 1 resolved it (confidence={confidence!r}). L3 page-cap not exercised.")
        print("  This means L1 columnar survived the no-balance format — balance violations may not have hit the 10% threshold.")
        print("  Check violation ratio in RESULT line above.")
    elif confidence == "low":
        print(f"L3 ran but no page-cap triggered (document < 10 effective pages from table start, or L3 yielded < 3 rows).")
    else:
        print(f"Unexpected confidence={confidence!r}")


# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    print(f"\nOllama status: {'UP' if ollama_up() else 'DOWN'}")
    print(f"LLM_MODEL: {os.environ.get('LLM_MODEL', 'not set')}")

    if which in ("1", "all"): scenario_1_v2()
    if which in ("2", "all"): scenario_2()
    if which in ("3", "all"): scenario_3()
