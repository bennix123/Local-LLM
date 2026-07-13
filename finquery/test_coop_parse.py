import sys, os
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", "finquery", "backend")))

from src.services.txn_store.parsers import ingest_pdf, connect

pdf_path = "finquery/data/uploads/Coop_Demo_Statement.pdf"
if not os.path.exists(pdf_path):
    # try relative to finquery Cwd
    pdf_path = "data/uploads/Coop_Demo_Statement.pdf"

print("Parsing Coop statement at:", pdf_path)
count = ingest_pdf(pdf_path, "Coop_Demo_Statement.pdf", "test_user_coop")
print(f"Ingested {count} transactions.")

con = connect()
rows = con.execute("SELECT txn_date, descr, category FROM transactions WHERE user_id='test_user_coop' ORDER BY seq").fetchall()
print("\nParsed Coop transactions details:")
for r in rows:
    print(r)
con.close()
