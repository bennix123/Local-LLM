#!/usr/bin/env python3
"""Parse paytm.pdf (Paytm Payments Bank savings statement) into canonical JSON + reconcile."""
import pdfplumber, re, json, sys
from datetime import date

PDF = "/Users/shivduttchauhan/Desktop/paytm.pdf"

MONTHS = {m: i for i, m in enumerate(
    ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"], start=1)}

HEADER_RE = re.compile(
    r'^(\d{2}) ([A-Z][a-z]{2}) (\d{4})\s+(.+?)\s+([+-])\s+Rs\.([\d,]+\.\d{2})\s+Rs\.([\d,]+\.\d{2})\s*$')
TIME_RE = re.compile(r'^(\d{1,2}:\d{2}\s?(?:AM|PM))\b\s*(.*)$')
COLHDR = "DATE & TIME TRANSACTION DETAILS AMOUNT AVAILABLE BALANCE"

def money(s): return float(s.replace(",", ""))
def iso(dd, mon, yyyy): return f"{yyyy}-{MONTHS[mon]:02d}-{int(dd):02d}"

FOOTER_PREFIXES = (
    "This statement contains transactions upto System",
    "To view terms & conditions visit",
    "Powered By IndusInd Bank",
    "* PPBL Savings Account Interest rate",
    "Each depositor is insured by Deposit Insurance",
    "held by him/her in the same right",
    "Need Help? Visit",
    "**** THIS IS COMPUTER GENERATED DOCUMENT",
    "NEVER SHARE your card number",
    "details can lead to unauthorised access",
    "Page ",
)
def is_footer(l):
    s = l.strip()
    return s == COLHDR or any(s.startswith(p) for p in FOOTER_PREFIXES)

FD_START = "Fixed Deposits with Partner Bank"

# ---- collect lines tagged with page ----
lines = []  # (page, text)
page_texts = []
with pdfplumber.open(PDF) as pdf:
    npages = len(pdf.pages)
    for pi, pg in enumerate(pdf.pages, start=1):
        t = pg.extract_text() or ""
        page_texts.append(t)
        for raw in t.splitlines():
            l = raw.rstrip()
            if not l.strip():
                continue
            lines.append((pi, l))

# ---- find first transaction header index ----
first_txn = None
for i,(p,l) in enumerate(lines):
    if HEADER_RE.match(l):
        first_txn = i; break

# ---- parse account meta from page 1 preamble ----
p1 = page_texts[0]
def find(pat, text=p1, flags=0):
    m = re.search(pat, text, flags); return m.group(1).strip() if m else None

acct = {}
acct["account_holder"] = lines[0][1] if lines else None
m = re.search(r'Account statement for:(\d{2} [A-Za-z]{3} \d{4}) to (\d{2} [A-Za-z]{3} \d{4})', p1)
period = {"from": m.group(1), "to": m.group(2)} if m else {}
acct["opened_on"] = find(r'ACCOUNT OPENED ON:\s*([0-9a-zA-Z ]+?)\s*$', p1, re.M) or find(r'ACCOUNT OPENED ON:\s*([0-9a-zA-Z]+ \d{4})')
# summary numbers line: Rs. a Rs. b Rs. c Rs. d  followed by labels line
m = re.search(r'Rs\.\s*([\d,]+\.\d{2})\s+Rs\.\s*([\d,]+\.\d{2})\s+Rs\.\s*([\d,]+\.\d{2})\s+Rs\.\s*([\d,]+\.\d{2})', p1)
summ = {}
if m:
    summ = {"opening_balance": money(m.group(1)), "total_deposit": money(m.group(2)),
            "total_withdrawal": money(m.group(3)), "closing_balance": money(m.group(4))}
# account number / type line: 918054810988 SAVINGS PYTM0123456 110766001 2.5%
m = re.search(r'(\d{6,})\s+([A-Z]+)\s+([A-Z0-9]+)\s+(\d+)\s+([\d.]+%)', p1)
if m:
    acct.update({"account_number": m.group(1), "account_type": m.group(2),
                 "ifsc": m.group(3), "micr": m.group(4), "interest_rate": m.group(5)})
acct["gstin"] = find(r'GSTIN\s*-\s*([A-Z0-9]+)')
acct["email"] = find(r'([\w.]+@[\w.]+\.[a-z]+)')
acct["nominee"] = "Not Registered" if "Not Registered" in p1 else None
acct["bank"] = "Paytm Payments Bank"
acct["statement_period"] = period

# ---- parse transactions ----
def parse_txn(header_line, body, page):
    m = HEADER_RE.match(header_line)
    dd, mon, yyyy, desc, sign, amt, bal = m.groups()
    t = {
        "date": iso(dd, mon, yyyy),
        "date_raw": f"{dd} {mon} {yyyy}",
        "type": desc.strip(),
        "direction": "credit" if sign == "+" else "debit",
        "amount": money(amt),
        "available_balance": money(bal),
        "page": page,
        "time": None, "counterparty": None, "vpa": None,
        "account_ref": None, "bank_code": None,
        "transaction_id": None, "reference_number": None,
        "reference_type": None, "payer_mobile": None,
        "remarks": None, "details_raw": [],
    }
    for b in body:
        consumed = False
        mm = TIME_RE.match(b)
        if mm and t["time"] is None:
            t["time"] = mm.group(1).strip()
            b = mm.group(2).strip()          # keep any residual (e.g. wrapped a/c no)
            if not b:
                continue
        if b.startswith("Sent to:"):
            t["counterparty"] = b[len("Sent to:"):].strip(); consumed = True
        elif b.startswith("Sent to "):
            t["counterparty"] = b[len("Sent to "):].strip(); consumed = True
        elif b.startswith("Received from:"):
            t["counterparty"] = b[len("Received from:"):].strip(); consumed = True
        elif b.startswith("Received from "):
            t["counterparty"] = re.split(r'\s+A/C No', b[len("Received from "):].strip())[0].strip()
            consumed = True
        elif b.startswith("Paid successfully at "):
            t["counterparty"] = b[len("Paid successfully at "):].strip(); consumed = True
        elif b.startswith("Added back to"):
            t["counterparty"] = t["counterparty"] or "Savings account (refund)"; consumed = True
        if b.startswith("VPA:"):
            t["vpa"] = b[len("VPA:"):].strip(); consumed = True
        mm = re.match(r'A/C No:\s*(.+?)\s*(?:\(([^)]+)\))?\s*$', b)
        if mm and b.startswith("A/C No:"):
            t["account_ref"] = mm.group(1).strip()
            if mm.group(2): t["bank_code"] = mm.group(2).strip()
            consumed = True
        if b.startswith("From Account Number"):
            t["account_ref"] = b.split("From Account Number")[1].strip(); consumed = True
        mm = re.match(r'Transaction ID\s*:?\s*(\S+)', b)
        if mm and b.startswith("Transaction ID"):
            t["transaction_id"] = mm.group(1).strip(); consumed = True
        mm = re.match(r'(Reference Number|UPI Reference No|IMPS Reference No|NEFT Reference No|Reference No)\s*:?\s*(\S+)', b)
        if mm:
            t["reference_number"] = mm.group(2).strip()
            t["reference_type"] = mm.group(1).strip(); consumed = True
        if b.startswith("Remarks"):
            t["remarks"] = b.split(":",1)[1].strip() if ":" in b else b; consumed = True
        mm = re.search(r'linked to Mobile No\s+(\d+)', b)
        if mm:
            t["payer_mobile"] = mm.group(1); consumed = True
        if not consumed and b.strip():
            t["details_raw"].append(b.strip())
    return t

txns = []
fd_lines = []
i = first_txn
cur = None
in_fd = False
while i < len(lines):
    p, l = lines[i]
    if l.strip().startswith(FD_START):
        in_fd = True
    if in_fd:
        if not is_footer(l):
            fd_lines.append(l.strip())
        i += 1
        continue
    if HEADER_RE.match(l):
        if cur: txns.append(parse_txn(cur[0], cur[1], cur[2]))
        cur = [l, [], p]
    else:
        if cur and not is_footer(l):
            cur[1].append(l)
    i += 1
if cur: txns.append(parse_txn(cur[0], cur[1], cur[2]))

# ---- parse fixed deposits section (page 48) ----
fd = {"partner_bank": "IndusInd Bank", "period": None,
      "available_deposit_opening": None, "total_deposit": None,
      "total_withdrawal": None, "available_deposit_closing": None,
      "active_fixed_deposits": []}
fd_text = "\n".join(fd_lines)
m = re.search(r'Fixed Deposits with Partner Bank \(IndusInd Bank\)\s*:\s*(.+)', fd_text)
if m: fd["period"] = m.group(1).strip()
m = re.search(r'Rs\.([\d,]+\.\d{2})\s+Rs\.([\d,]+\.\d{2})\s+Rs\.([\d,]+\.\d{2})\s+Rs\.([\d,]+\.\d{2})', fd_text)
if m:
    fd["available_deposit_opening"] = money(m.group(1))
    fd["total_deposit"] = money(m.group(2))
    fd["total_withdrawal"] = money(m.group(3))
    fd["available_deposit_closing"] = money(m.group(4))
# active FD rows would follow the "BOOKING DATE ..." header; none present -> empty

# ---- reconciliation ----
opening = summ.get("opening_balance", 0.0)
running = opening
mismatches = []
for idx, t in enumerate(txns):
    signed = t["amount"] if t["direction"] == "credit" else -t["amount"]
    running = round(running + signed, 2)
    if abs(running - t["available_balance"]) > 0.005:
        mismatches.append({"index": idx, "txn_id": t["transaction_id"], "date": t["date"],
                           "type": t["type"], "expected_running": running,
                           "stated_balance": t["available_balance"],
                           "diff": round(running - t["available_balance"], 2)})
        running = t["available_balance"]  # resync to statement to isolate single errors

tot_credit = round(sum(t["amount"] for t in txns if t["direction"]=="credit"), 2)
tot_debit  = round(sum(t["amount"] for t in txns if t["direction"]=="debit"), 2)
final_bal = txns[-1]["available_balance"] if txns else None

recon = {
    "opening_balance": opening,
    "closing_balance_stated": summ.get("closing_balance"),
    "closing_balance_from_last_txn": final_bal,
    "total_deposit_stated": summ.get("total_deposit"),
    "total_deposit_computed": tot_credit,
    "total_withdrawal_stated": summ.get("total_withdrawal"),
    "total_withdrawal_computed": tot_debit,
    "opening_plus_dep_minus_wd": round(opening + tot_credit - tot_debit, 2),
    "transaction_count": len(txns),
    "running_balance_mismatches": mismatches,
}

# ---- diagnostics output ----
print("npages:", npages, "total lines:", len(lines), "first_txn_line_idx:", first_txn)
print("ACCOUNT:", json.dumps(acct, ensure_ascii=False))
print("SUMMARY:", json.dumps(summ))
print("TXN COUNT:", len(txns))
from collections import Counter
print("TYPES:", Counter(t["type"] for t in txns))
print("DIR:", Counter(t["direction"] for t in txns))
print("MISSING time:", sum(1 for t in txns if not t["time"]))
print("MISSING txn_id:", sum(1 for t in txns if not t["transaction_id"]))
print("MISSING counterparty:", sum(1 for t in txns if not t["counterparty"]))
print("\n--- RECON ---")
print(json.dumps({k:v for k,v in recon.items() if k!="running_balance_mismatches"}, indent=1))
print("running mismatches:", len(mismatches))
for mm in mismatches[:20]:
    print("  ", mm)
print("\nFIXED DEPOSITS:", json.dumps(fd, ensure_ascii=False))
resid = [dr for t in txns for dr in t["details_raw"]]
print("residual details_raw lines total:", len(resid), "| txns with residual:", sum(1 for t in txns if t["details_raw"]))

# ---- assign 1-based order index ----
for n, t in enumerate(txns, start=1):
    t["index"] = n

# dump
out = {"document": {"type": "Paytm Payments Bank Statement of Account",
                    "source_pdf": "paytm.pdf", "pages": npages,
                    "generator": "parse_paytm.py"},
       "account": acct, "account_summary": summ,
       "transaction_count": len(txns),
       "transactions": txns, "fixed_deposits": fd,
       "reconciliation": recon}
import os
OUT = os.environ.get("PAYTM_OUT",
    "/private/tmp/claude-501/-Users-shivduttchauhan-Desktop-delulu-Penny-PennyMac/da26bce9-8cef-44cd-836c-323f31966662/scratchpad/paytm_document.json")
json.dump(out, open(OUT, "w"), ensure_ascii=False, indent=1)
print("\nwrote", OUT)
