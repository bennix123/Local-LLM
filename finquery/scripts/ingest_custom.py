import sys
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "backend"))
sys.path.insert(0, ROOT)

from src.services.txn_store.parsers import ingest_pdf
from src.services.txn_store.db import connect

if len(sys.argv) < 2:
    print("Usage: python scripts/ingest_custom.py <path_to_pdf>")
    sys.exit(1)

pdf_path = sys.argv[1]
if not os.path.exists(pdf_path):
    print(f"Error: file not found: {pdf_path}")
    sys.exit(1)

doc_name = os.path.basename(pdf_path)
user_id = "test_user"

print(f"Ingesting {pdf_path} for user {user_id}...")
count = ingest_pdf(pdf_path, doc_name, user_id)
print(f"Ingestion finished! Successfully ingested {count} transactions.")

# Let's show the confidence level stored in document_metadata
conn = connect()
meta = conn.execute("SELECT parse_confidence FROM document_metadata WHERE user_id=? AND doc_name=?", (user_id, doc_name)).fetchone()
txns = conn.execute("SELECT txn_date, descr, debit, credit, balance FROM transactions WHERE user_id=? AND doc_name=? ORDER BY seq LIMIT 5", (user_id, doc_name)).fetchall()
conn.close()

if meta:
    print(f"Parse Confidence Level stored in DB: {meta[0]}")
if txns:
    print("\nFirst 5 transactions stored in database:")
    for t in txns:
        print(f"  {t[0]} | {t[1][:40]:<40} | Dr: {t[2]} | Cr: {t[3]} | Bal: {t[4]}")
