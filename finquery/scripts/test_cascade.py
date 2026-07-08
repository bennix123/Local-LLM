import sys
import os

# Ensure proper sys.path so modules can find each other
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "backend"))
sys.path.insert(0, ROOT)

import pymupdf
from src.services.txn_store.parsers import (
    _find_table_start,
    parse_generic_statement,
    is_statement_pdf,
    _generic_breaks
)

def run_test(pdf_path):
    print("=" * 60)
    print(f"Testing PDF: {pdf_path}")
    print("=" * 60)
    
    if not os.path.exists(pdf_path):
        print("File does not exist!")
        return

    try:
        doc = pymupdf.open(pdf_path)
        start_page = _find_table_start(doc)
        print(f"Detected table start page: {start_page}")
        doc.close()
    except Exception as e:
        print(f"Error opening document: {e}")
        return

    print(f"is_statement_pdf? {is_statement_pdf(pdf_path)}")

    print("\nRunning parse_generic_statement...")
    try:
        res = parse_generic_statement(pdf_path)
        rows = list(res)
        confidence = getattr(res, "parse_confidence", "unknown")
        print(f"Parsed {len(rows)} rows.")
        print(f"Confidence Level: {confidence}")
        
        if rows:
            print(f"First 3 transactions:")
            for r in rows[:3]:
                print(f"  {r['txn_date']} | {r['descr'][:40]} | Debit: {r['debit']} | Credit: {r['credit']} | Bal: {r['balance']}")
            print(f"Balance violations count: {_generic_breaks(rows)}")
    except Exception as e:
        print(f"Error during parse: {e}")

if __name__ == "__main__":
    # Test with a dummy statement or input arg
    test_pdf = sys.argv[1] if len(sys.argv) > 1 else "../indian_bank_statement.pdf"
    if not os.path.exists(test_pdf):
        # try checking relative to workspace root
        test_pdf = os.path.join(ROOT, "indian_bank_statement.pdf")
    
    run_test(test_pdf)
