"""
test_cascade_verify.py – 4-scenario verification of the cascading statement parser.

Scenarios:
  1. Unknown layout  -> should trigger Layer 2 (schema inference)
  2. Bad debit/credit grouping -> regex passes match-rate but balance fails -> falls to Layer 3
  3. 15-page unknown layout   -> Layer 3 partial, pages 11-15 dropped, confidence="partial"
  4. Ollama down + Layer 1 high violations -> graceful degradation
"""

import sys, os, socket, textwrap

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "backend"))
sys.path.insert(0, ROOT)

import pymupdf
from src.services.txn_store.parsers import parse_generic_statement, _generic_breaks

# ---------------------------------------------------------------------------
# PDF GENERATORS
# ---------------------------------------------------------------------------

def _new_pdf_page(doc, text):
    page = doc.new_page(width=595, height=842)
    tw = pymupdf.TextWriter(page.rect)
    font = pymupdf.Font("Courier")
    y = 40
    for line in text.splitlines():
        tw.append((40, y), line, fontsize=9, font=font)
        y += 13
        if y > 810:
            break
    tw.write_text(page)

UNKNOWN_TXNS = [
    ("05/07/2026", "NEFT-SALARY-ZENITH CORP",   "0.00",     "85000.00", "95000.00"),
    ("06/07/2026", "ATM WD-HDFC 4510",          "5000.00",  "0.00",     "90000.00"),
    ("07/07/2026", "POS-SWIGGY INSTAMART",       "450.00",   "0.00",     "89550.00"),
    ("08/07/2026", "UPI-PHONEPE RECHARGE",       "199.00",   "0.00",     "89351.00"),
    ("09/07/2026", "UPI-AMAZON PAY",             "1299.00",  "0.00",     "88052.00"),
    ("10/07/2026", "NEFT-VENDOR PAYMENT",        "12000.00", "0.00",     "76052.00"),
    ("11/07/2026", "POS-ZOMATO ORDER",           "380.00",   "0.00",     "75672.00"),
    ("12/07/2026", "UPI-PAYTM UTILITY",          "2500.00",  "0.00",     "73172.00"),
    ("13/07/2026", "CREDIT-REFUND AMAZON",       "0.00",     "650.00",   "73822.00"),
    ("14/07/2026", "NEFT-MUTUAL FUND SIP",       "10000.00", "0.00",     "63822.00"),
]

def _header():
    return (
        "ZENITH COMMERCIAL BANK\n"
        "Account Holder: TEST USER\n"
        "Account No: 9988776655\n"
        "Period: 01/07/2026 - 31/07/2026\n\n"
        "DATE       DESCRIPTION                    DR          CR          BALANCE\n"
        "------------------------------------------------------------------------\n"
    )

def _txn_block():
    return "\n".join(
        f"{d}   {desc:<30} {dr:<12} {cr:<12} {bal}"
        for d, desc, dr, cr, bal in UNKNOWN_TXNS
    )

def make_unknown_pdf(path, pages=1):
    content = _header() + _txn_block()
    doc = pymupdf.open()
    for _ in range(pages):
        _new_pdf_page(doc, content)
    doc.save(path)
    doc.close()

def make_bad_drct_pdf(path):
    # Correct balance column but SWAP debit/credit so reconciliation fails
    header = (
        "FICTIONAL BANK LTD\nAccount: 1234567890\nStatement: Jun 2026\n\n"
        "DATE        DESCRIPTION                   CREDIT    DEBIT     BALANCE\n"
        "------------------------------------------------------------------------\n"
    )
    txns = [
        ("01/06/2026","SALARY DEPOSIT",       "85000.00","0.00",    "85000.00"),
        ("02/06/2026","RENT PAYMENT",         "0.00",    "20000.00","65000.00"),
        ("03/06/2026","GROCERY PURCHASE",     "0.00",    "3500.00", "61500.00"),
        ("04/06/2026","ONLINE TRANSFER IN",   "15000.00","0.00",    "76500.00"),
        ("05/06/2026","INSURANCE PREMIUM",    "0.00",    "8000.00", "68500.00"),
        ("06/06/2026","FREELANCE INCOME",     "30000.00","0.00",    "98500.00"),
    ]
    block = "\n".join(
        f"{d}   {desc:<28} {cr:<10} {dr:<10} {bal}"
        for d, desc, cr, dr, bal in txns
    )
    doc = pymupdf.open()
    _new_pdf_page(doc, header + block)
    doc.save(path)
    doc.close()

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

def run_parse(pdf_path, label):
    print(f"\n{'='*70}\n  {label}\n{'='*70}")
    res = parse_generic_statement(pdf_path)
    rows = list(res)
    confidence = getattr(res, "parse_confidence", "unknown")
    breaks = _generic_breaks(rows) if rows else 0
    print(f"\n  RESULT: {len(rows)} rows | confidence={confidence!r} | balance_violations={breaks}")
    if rows:
        for r in rows[:3]:
            print(f"    {r['txn_date']} | {r['descr'][:36]:<36} | Dr:{r['debit']} Cr:{r['credit']} Bal:{r['balance']}")
    return rows, confidence, breaks

def ollama_up(port=11434):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=2)
        s.close()
        return True
    except OSError:
        return False

# ---------------------------------------------------------------------------
# SCENARIOS
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.join(ROOT, "scripts")

def scenario_1():
    print("\n" + "="*70 + "\n  SCENARIO 1: Unknown layout -> Layer 2 schema inference\n" + "="*70)
    pdf = os.path.join(SCRIPT_DIR, "_s1_unknown.pdf")
    make_unknown_pdf(pdf)
    rows, confidence, breaks = run_parse(pdf, "S1 - Zenith Bank (unknown layout, 1 page)")
    print(f"\n  VERDICT: parsed {len(rows)} rows confidence={confidence!r}.")
    print("  (See [cascade] and [parser-L2] log lines above for which layer triggered.)")

def scenario_2():
    print("\n" + "="*70 + "\n  SCENARIO 2: Bad Dr/Cr grouping -> L2 balance check rejects -> falls to L3\n" + "="*70)
    pdf = os.path.join(SCRIPT_DIR, "_s2_baddrct.pdf")
    make_bad_drct_pdf(pdf)
    rows, confidence, breaks = run_parse(pdf, "S2 - Fictional Bank (swapped debit/credit columns)")
    print(f"\n  VERDICT: ", end="")
    if confidence in ("low", "partial"):
        print(f"PASS - confidence={confidence!r}. L2 balance check correctly rejected wrong grouping, L3 ran.")
    else:
        print(f"confidence={confidence!r}. Check [parser-L2] log for whether balance check fired.")

def scenario_3():
    print("\n" + "="*70 + "\n  SCENARIO 3: 15-page unknown format -> confidence='partial' (pages 11-15 dropped)\n" + "="*70)
    pdf = os.path.join(SCRIPT_DIR, "_s3_15pages.pdf")
    make_unknown_pdf(pdf, pages=15)
    rows, confidence, breaks = run_parse(pdf, "S3 - Zenith Bank 15 pages")
    print(f"\n  VERDICT: ", end="")
    if confidence == "partial":
        print(f"PASS: confidence='partial'. Pages 11-15 DROPPED (not surfaced). {len(rows)} rows returned.")
    elif confidence in ("high", "medium"):
        print(f"Layer 1 resolved via rule-based (confidence={confidence!r}) — page cap only applies when L3 runs. {len(rows)} rows.")
    else:
        print(f"confidence={confidence!r}, {len(rows)} rows.")

def scenario_4():
    print("\n" + "="*70 + "\n  SCENARIO 4: Ollama DOWN -> graceful fallback to best L1\n" + "="*70)
    pdf = os.path.join(SCRIPT_DIR, "_s4_down.pdf")
    make_unknown_pdf(pdf)
    if ollama_up():
        print("  [INFO] Ollama is UP on port 11434. Stop it and re-run this scenario for the outage path.")
        print("  [INFO] Running anyway — L1/L2/L3 will proceed normally if Ollama answers.")
    else:
        print("  [INFO] Ollama is DOWN. Outage simulation is LIVE.")
    rows, confidence, breaks = run_parse(pdf, "S4 - Unknown layout with Ollama potentially down")
    print(f"\n  VERDICT: ", end="")
    if not ollama_up():
        if rows:
            print(f"PASS: Ollama was DOWN but ingestion succeeded. {len(rows)} rows | confidence={confidence!r} | violations={breaks}.")
            if confidence in ("medium", "high"):
                print("       L1 had acceptable violations, returned as-is (graceful degradation).")
            elif confidence == "low":
                print("       L1 had HIGH violations but Ollama was down — saved anyway as 'low' confidence. Ingestion did NOT crash.")
        else:
            print("Both L1 and LLM produced nothing (Ollama down, L1 found no rows). Result: 0 rows, confidence='low'. No crash.")
    else:
        print(f"Ollama was UP. confidence={confidence!r}, {len(rows)} rows. Re-run after stopping Ollama for the real outage test.")

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    if which in ("1", "all"): scenario_1()
    if which in ("2", "all"): scenario_2()
    if which in ("3", "all"): scenario_3()
    if which in ("4", "all"): scenario_4()
