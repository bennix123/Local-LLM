import sys
import os
import json
import sqlite3

# Resolve project paths
_CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
_PROJECT_ROOT = os.path.abspath(os.path.join(_CURRENT_DIR, ".."))
_REPO_ROOT = os.path.abspath(os.path.join(_PROJECT_ROOT, ".."))
_BACKEND_DIR = os.path.join(_PROJECT_ROOT, "backend")

sys.path.insert(0, _REPO_ROOT)
sys.path.insert(0, _PROJECT_ROOT)
sys.path.insert(0, _BACKEND_DIR)

try:
    from finquery.backend.src.services.txn_store.parsers import ingest_pdf, connect, init_db
except ImportError:
    try:
        from backend.src.services.txn_store.parsers import ingest_pdf, connect, init_db
    except ImportError:
        from src.services.txn_store.parsers import ingest_pdf, connect, init_db

# Path helper
FIXTURES_DIR = os.path.join(_CURRENT_DIR, "fixtures")
SCHEMA_FILE = os.path.join(_CURRENT_DIR, "schemas", "parsed_transaction.schema.json")

# Load Schema validation helper if jsonschema is available
HAS_JSONSCHEMA = False
try:
    import jsonschema
    HAS_JSONSCHEMA = True
except ImportError:
    pass

def validate_schema(data):
    if not HAS_JSONSCHEMA:
        # Simple manual check
        required = ["date", "description", "debit", "credit", "balance", "category", "bank"]
        for row in data:
            for field in required:
                if field not in row:
                    return False, f"Missing required field '{field}'"
        return True, ""
    
    with open(SCHEMA_FILE, "r") as f:
        schema = json.load(f)
    
    try:
        # Validate as an array of items matching the schema
        array_schema = {
            "type": "array",
            "items": schema
        }
        jsonschema.validate(instance=data, schema=array_schema)
        return True, ""
    except jsonschema.ValidationError as e:
        return False, str(e)

def run_parser_on_pdf(pdf_path):
    user_id = f"conformance_test_{os.path.basename(pdf_path)}"

    # 0. Ensure the schema exists (fresh DBs crashed on the DELETE below otherwise)
    init_db()

    # 1. Clean up old entries
    con = connect()
    con.execute("DELETE FROM transactions WHERE user_id = ?", (user_id,))
    con.commit()
    con.close()
    
    # 2. Ingest
    ingest_pdf(pdf_path, os.path.basename(pdf_path), user_id)
    
    # 3. Query results
    con = connect()
    cursor = con.execute("""
        SELECT txn_date, descr, debit, credit, balance, category, bank_name 
        FROM transactions 
        WHERE user_id = ? 
        ORDER BY seq
    """, (user_id,))
    
    rows = cursor.fetchall()
    txns = []
    for r in rows:
        txns.append({
            "date": r[0],
            "description": r[1],
            "debit": float(r[2]) if r[2] is not None else 0.0,
            "credit": float(r[3]) if r[3] is not None else 0.0,
            "balance": float(r[4]) if r[4] is not None else None,
            "category": r[5],
            "bank": r[6]
        })
    con.close()
    return txns

def main():
    generate = "--generate" in sys.argv
    
    pdf_files = [f for f in os.listdir(FIXTURES_DIR) if f.endswith(".pdf")]
    if not pdf_files:
        print("No PDF files found in contract/fixtures/")
        sys.exit(1)
        
    all_pass = True
    for pdf_name in pdf_files:
        pdf_path = os.path.join(FIXTURES_DIR, pdf_name)
        expected_json_path = os.path.join(FIXTURES_DIR, pdf_name.replace(".pdf", "_expected.json"))
        
        print(f"\nProcessing {pdf_name}...")
        parsed_txns = run_parser_on_pdf(pdf_path)
        
        # Validate schema
        ok, msg = validate_schema(parsed_txns)
        if not ok:
            print(f"[ERROR] Schema validation failed: {msg}")
            all_pass = False
            continue
            
        if generate:
            with open(expected_json_path, "w", encoding="utf-8") as f:
                json.dump(parsed_txns, f, indent=2)
            print(f"[GENERATE] Generated expected JSON at: {expected_json_path}")
        else:
            if not os.path.exists(expected_json_path):
                print(f"[ERROR] Missing expected JSON file for {pdf_name}. Run with --generate to create it.")
                all_pass = False
                continue
                
            with open(expected_json_path, "r", encoding="utf-8") as f:
                expected_txns = json.load(f)
                
            # Perform exact comparison
            if parsed_txns == expected_txns:
                print(f"[PASS] {pdf_name} MATCHED perfectly!")
            else:
                print(f"[FAIL] {pdf_name} MISMATCHED!")
                all_pass = False
                # Simple diff
                print(f"Expected count: {len(expected_txns)}, got: {len(parsed_txns)}")
                
    if all_pass:
        print("\n[SUCCESS] ALL TESTS PASSED SUCCESSFULLY!")
        sys.exit(0)
    else:
        print("\n[FAIL] SOME TESTS FAILED!")
        sys.exit(1)

if __name__ == "__main__":
    main()
