import os
import sys
import json
import sqlite3

# Align Python search paths
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "backend"))
sys.path.insert(0, ROOT)

from src.services.txn_store import queries
from src.services import txn_store as ts
from scripts.test_server.server import needs_bank_clarification

# Setup test user and database paths
USER_ID = "test_user_multidoc"

def setup_synthetic_data(mixed_currency=False):
    con = queries.connect()
    # Clear prior test data
    con.execute("DELETE FROM transactions WHERE user_id=?", (USER_ID,))
    con.execute("DELETE FROM document_metadata WHERE user_id=?", (USER_ID,))
    
    # 1. HDFC Bank Statement
    hdfc_txns = [
        (USER_ID, "hdfc.pdf", "HDFC Bank", "2026-05-01", "2026-05", 2026, 5, 1, "Salary Credit", "Salary", "Income", 0.0, 100000.0, 100000.0, "INR", 1),
        (USER_ID, "hdfc.pdf", "HDFC Bank", "2026-05-02", "2026-05", 2026, 5, 2, "Rent", "Rent", "Housing", 20000.0, 0.0, 80000.0, "INR", 2)
    ]
    
    # 2. SBI Bank Statement
    sbi_currency = "GBP" if mixed_currency else "INR"
    sbi_txns = [
        (USER_ID, "sbi.pdf", "SBI", "2026-05-01", "2026-05", 2026, 5, 1, "Refund", "Refund", "Income", 0.0, 5000.0, 5000.0, sbi_currency, 1),
        (USER_ID, "sbi.pdf", "SBI", "2026-05-03", "2026-05", 2026, 5, 3, "Grocery DMart", "DMart", "Groceries", 2000.0, 0.0, 3000.0, sbi_currency, 2)
    ]
    
    for row in hdfc_txns + sbi_txns:
        con.execute("""
            INSERT INTO transactions (user_id, doc_name, bank_name, txn_date, month, year, month_no, day, descr, merchant, category, debit, credit, balance, currency, seq)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, row)
        
    # Insert metadata
    con.execute("INSERT INTO document_metadata (user_id, doc_name, parse_confidence, upload_ts) VALUES (?, ?, ?, '2026-07-08 12:00:00')",
                (USER_ID, "hdfc.pdf", "high"))
    con.execute("INSERT INTO document_metadata (user_id, doc_name, parse_confidence, upload_ts) VALUES (?, ?, ?, '2026-07-08 12:05:00')",
                (USER_ID, "sbi.pdf", "high"))
    
    con.commit()
    con.close()

def run_test_suite():
    print("====================================================================")
    # Reset active doc context
    queries.ACTIVE_DOC_NAME = None
    
    # ------------------------------------------------------------------
    print("\n[TEST 1] Single document, balance query")
    setup_synthetic_data(mixed_currency=False)
    # Simulate single document by deleting sbi
    con = queries.connect()
    con.execute("DELETE FROM transactions WHERE user_id=? AND doc_name='sbi.pdf'", (USER_ID,))
    con.execute("DELETE FROM document_metadata WHERE user_id=? AND doc_name='sbi.pdf'", (USER_ID,))
    con.commit()
    con.close()
    
    ctx = {}
    doc, payload = needs_bank_clarification(USER_ID, "what is my balance?", ctx)
    print(f"  Query: 'what is my balance?'")
    print(f"  Outcome: doc_name={doc!r}, clarification_needed={payload is not None}")
    assert payload is None, "Should not trigger clarification for single document"
    
    # ------------------------------------------------------------------
    print("\n[TEST 2] Two documents, balance query, no bank named (Ambiguous)")
    setup_synthetic_data(mixed_currency=False)
    ctx = {}
    doc, payload = needs_bank_clarification(USER_ID, "what is my balance?", ctx)
    print(f"  Query: 'what is my balance?'")
    print(f"  Outcome: clarification_needed={payload is not None}")
    if payload:
        print(f"  Payload options:")
        for opt in payload["options"]:
            print(f"    - ID: {opt['id']} | Label: {opt['label']} | Sublabel: {opt['sublabel']}")
    assert payload is not None, "Should trigger clarification for ambiguous balance query"
    
    # ------------------------------------------------------------------
    print("\n[TEST 3] Two documents, balance query, bank named explicitly")
    ctx = {}
    doc, payload = needs_bank_clarification(USER_ID, "what's my HDFC balance", ctx)
    print(f"  Query: 'what's my HDFC balance'")
    print(f"  Outcome: doc_name={doc!r}, clarification_needed={payload is not None}")
    assert doc == "hdfc.pdf" and payload is None, "Should resolve directly to hdfc.pdf"
    
    # ------------------------------------------------------------------
    print("\n[TEST 4] Two documents, balance query, overall phrasing")
    ctx = {}
    doc, payload = needs_bank_clarification(USER_ID, "what is my total balance across everything?", ctx)
    print(f"  Query: 'what is my total balance across everything?'")
    print(f"  Outcome: doc_name={doc!r}, clarification_needed={payload is not None}")
    assert doc is None and payload is None, "Should resolve to overall (None) directly"
    
    # Call overall_balance to verify sum
    from src.services.txn_store.queries import overall_balance
    ob = overall_balance(USER_ID)
    print(f"  Overall Balance Total: {ob['currency']} {ob['total']} (mixed_currency={ob['mixed_currency']})")
    assert ob["total"] == 83000.0, "Overall balance should sum 80,000 + 3,000 = 83,000"
    
    # ------------------------------------------------------------------
    print("\n[TEST 5] Two documents, spending query (Trigger clarification)")
    ctx = {}
    doc, payload = needs_bank_clarification(USER_ID, "how much did I spend on food this month?", ctx)
    print(f"  Query: 'how much did I spend on food this month?'")
    print(f"  Outcome: doc_name={doc!r}, clarification_needed={payload is not None}")
    assert payload is not None, "Spending query should trigger clarification when multiple banks exist"
    
    # ------------------------------------------------------------------
    print("\n[TEST 6] Clarification round-trip simulation")
    ctx = {}
    # 1. First request triggers clarification
    doc, payload = needs_bank_clarification(USER_ID, "what is my balance?", ctx)
    assert payload is not None
    # 2. Simulate user selection: "hdfc.pdf"
    selected_id = "doc:hdfc.pdf"
    resolved_doc = None if selected_id == "overall" else selected_id[4:]
    ctx["default_doc_name"] = resolved_doc
    
    # Re-evaluate clarification on next turn
    doc, payload = needs_bank_clarification(USER_ID, "what is my balance?", ctx)
    print(f"  Outcome: doc_name={doc!r}, clarification_needed={payload is not None}")
    assert doc == "hdfc.pdf" and payload is None, "Should resolve to selected doc on follow-up turn"
    
    # ------------------------------------------------------------------
    print("\n[TEST 7] In-session memory context carry")
    # Using ctx from previous test which has default_doc_name = "hdfc.pdf"
    doc, payload = needs_bank_clarification(USER_ID, "what is my current balance?", ctx)
    print(f"  Query: 'what is my current balance?' (within active session)")
    print(f"  Outcome: doc_name={doc!r}, clarification_needed={payload is not None}")
    assert doc == "hdfc.pdf" and payload is None, "Should remember HDFC selection without re-asking"
    
    # ------------------------------------------------------------------
    print("\n[TEST 8] Override within remembered session")
    # Using same ctx with default_doc_name = "hdfc.pdf", but query explicitly says "overall"
    doc, payload = needs_bank_clarification(USER_ID, "show me my overall balance", ctx)
    print(f"  Query: 'show me my overall balance' (default HDFC is active)")
    print(f"  Outcome: doc_name={doc!r}, clarification_needed={payload is not None}")
    assert doc is None and payload is None, "Explicit overall phrasing should override remembered default"
    
    # ------------------------------------------------------------------
    print("\n[TEST 9] Mixed-currency overall balance safety check")
    setup_synthetic_data(mixed_currency=True)
    ob = overall_balance(USER_ID)
    print(f"  Mixed currency balance:")
    print(f"    - mixed_currency flag: {ob['mixed_currency']}")
    print(f"    - total in payload: {ob['total']}")
    print(f"    - breakdown:")
    for b in ob["breakdown"]:
        print(f"      * {b['bank_name']}: {b['currency']} {b['balance']}")
    assert ob["mixed_currency"] is True, "Mixed currency flag should be True"
    assert ob["total"] is None, "Total summed balance should be None for mixed currencies"
    
    print("\n====================================================================")
    print("  ALL TESTS PASSED SUCCESSFULLY!")
    print("====================================================================")

if __name__ == "__main__":
    run_test_suite()
