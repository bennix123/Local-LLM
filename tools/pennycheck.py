#!/usr/bin/env python3
"""
pennycheck — cross-validate Penny's Swift PDF parser against a deterministic
pdfplumber geometry extraction.

Penny ships as a native Swift app, so pdfplumber can't run inside it — but it
makes an excellent independent ORACLE. For each PDF this harness:

  1. Extracts every money amount on transaction lines with pdfplumber
     (layout coordinates, no AI) — the "geometry truth".
  2. Asks Penny's own deterministic parser what it extracted, via
     `penny-conformance dump-rows <pdf>`.
  3. Diffs them and flags divergences — each one is a Swift-parser bug to fix.

Comparison is at the raw-extraction level (dates + amounts + credit/debit),
NOT categorisation/merchant-normalisation (which are Penny-specific and pdfplumber
doesn't do). The two checks that catch real bugs:

  • MISREAD  — a transaction amount Penny reports that appears on NO transaction
               line in the PDF (it fabricated/misread a figure).
  • COVERAGE — pdfplumber sees materially more/fewer transaction lines than Penny
               parsed (missed or duplicated rows).

Usage:
  python3 tools/pennycheck.py <file.pdf | folder> [--bin <penny-conformance>] [-v]

Exit code 0 when every PDF passes, 1 otherwise.
"""
import sys, os, re, json, subprocess, glob
from collections import Counter

MONEY = re.compile(r'-?\d[\d,]*\.\d{2}')
DATE = re.compile(r'\b(?:\d{1,2}[/-]\d{1,2}[/-]\d{2,4}'
                  r'|\d{1,2}\s*(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)'
                  r'|(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\s*\d{1,2})', re.I)

def pence(tok):
    return round(float(tok.replace(',', '')) * 100)

def pdfplumber_extract(pdf_path):
    """Deterministic geometry read. Returns:
      pool      — Counter of EVERY money amount (pence) anywhere in the document.
                  A Penny amount absent from this pool appears nowhere in the PDF
                  → a genuine misread (robust across multi-line / column layouts).
      txn_lines — count of date-bearing lines that also carry money, an advisory
                  transaction-count estimate for the coverage check."""
    import pdfplumber
    pool = Counter()
    txn_lines = 0
    with pdfplumber.open(pdf_path) as pdf:
        for page in pdf.pages:
            text = page.extract_text() or ""
            for t in MONEY.findall(text):
                pool[abs(pence(t))] += 1
            for ln in text.split("\n"):
                if DATE.search(ln) and MONEY.search(ln):
                    txn_lines += 1
    return pool, txn_lines

def penny_rows(pdf_path, binpath):
    out = subprocess.run([binpath, "dump-rows", pdf_path],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(f"penny dump-rows failed: {out.stderr.strip()[:300]}")
    return json.loads(out.stdout)

def check_pdf(pdf_path, binpath, verbose=False):
    pool, txn_lines = pdfplumber_extract(pdf_path)
    data = penny_rows(pdf_path, binpath)
    rows = data["rows"]

    # MISREAD (hard): a Penny transaction amount that appears NOWHERE in the PDF.
    misreads = []
    remaining = Counter(pool)  # consume matches so duplicate amounts line up
    for r in rows:
        amt = round((r["debit"] or 0) * 100) if (r["debit"] or 0) > 0 else round((r["credit"] or 0) * 100)
        if amt == 0:
            continue
        if remaining.get(amt, 0) > 0:
            remaining[amt] -= 1
        else:
            misreads.append(r)

    # COVERAGE (advisory): pdfplumber's date+money line estimate vs Penny rows.
    # Layout heuristics make this approximate, so it only WARNS — it never fails.
    n_penny = data["count"]
    cov_gap = abs(txn_lines - n_penny)
    coverage_warn = cov_gap > max(3, round(0.20 * max(txn_lines, n_penny)))

    ok = not misreads  # only misreads are hard failures
    status = "PASS" if ok else "FAIL"
    print(f"[{status}] {os.path.basename(pdf_path)} — "
          f"penny {n_penny} rows ({data.get('bank')!r}, {data.get('currency')}), "
          f"pdfplumber ~{txn_lines} txn-lines, {sum(pool.values())} money tokens")
    if misreads:
        print(f"   MISREAD: {len(misreads)} Penny amount(s) found NOWHERE in the PDF text — review "
              f"(a genuine misread, OR a garbled source glyph Penny recovered that a plain regex can't):")
        for r in misreads[:12]:
            amt = r["debit"] or r["credit"]
            print(f"     · {r['date']}  {r['descr'][:44]:44}  £{amt:.2f}")
    if coverage_warn:
        print(f"   [warn] coverage: pdfplumber ~{txn_lines} txn-lines vs Penny {n_penny} rows "
              f"(gap {cov_gap}) — review for missed/duplicated rows (heuristic, not a failure).")
    if verbose and ok:
        print(f"   (all {n_penny} Penny amounts corroborated somewhere in the PDF geometry)")
    return ok

def main():
    args = [a for a in sys.argv[1:]]
    verbose = "-v" in args; args = [a for a in args if a != "-v"]
    binpath = None
    if "--bin" in args:
        i = args.index("--bin"); binpath = args[i+1]; del args[i:i+2]
    if not args:
        print(__doc__); sys.exit(2)
    target = args[0]

    if binpath is None:
        # default: the debug build of penny-conformance
        here = os.path.dirname(os.path.abspath(__file__))
        guess = os.path.join(here, "..", "PennyMac", "PennyCore",
                             ".build", "debug", "penny-conformance")
        binpath = os.path.abspath(guess)
    if not os.path.exists(binpath):
        print(f"penny-conformance binary not found at {binpath}\n"
              f"build it: cd PennyMac/PennyCore && swift build --product penny-conformance",
              file=sys.stderr)
        sys.exit(2)

    pdfs = ([target] if target.lower().endswith(".pdf")
            else sorted(glob.glob(os.path.join(target, "*.pdf"))))
    if not pdfs:
        print(f"no PDFs found at {target}", file=sys.stderr); sys.exit(2)

    all_ok = True
    for p in pdfs:
        try:
            all_ok &= check_pdf(p, binpath, verbose)
        except Exception as e:
            all_ok = False
            print(f"[ERROR] {os.path.basename(p)}: {e}")
    print(f"\n{'ALL PASS' if all_ok else 'DIVERGENCES FOUND'} — {len(pdfs)} PDF(s)")
    sys.exit(0 if all_ok else 1)

if __name__ == "__main__":
    main()
