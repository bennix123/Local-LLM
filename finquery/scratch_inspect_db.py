import sqlite3, os

db_files = [
    "data/live_txn.db",
    "data/user_asdfg1234.db",
    "data/users.db"
]

# Walk user_dbs directory too
user_dbs_dir = "data/user_dbs"
if os.path.exists(user_dbs_dir):
    for f in os.listdir(user_dbs_dir):
        if f.endswith(".db"):
            db_files.append(os.path.join(user_dbs_dir, f))

print("Found DB files:", db_files)

for path in db_files:
    if not os.path.exists(path):
        print(f"File {path} does not exist.")
        continue
    try:
        con = sqlite3.connect(path)
        tables = [r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()]
        print(f"\nDB: {path} | Tables: {tables}")
        if "transactions" in tables:
            rows = con.execute("SELECT doc_name, bank_name, txn_date, descr, category, raw_category FROM transactions LIMIT 5").fetchall()
            print(f"Transactions (first 5):")
            for r in rows:
                print(r)
            other_rows = con.execute("SELECT doc_name, bank_name, txn_date, descr, category, raw_category FROM transactions WHERE category = 'Other' LIMIT 5").fetchall()
            print(f"Other Transactions (first 5):")
            for r in other_rows:
                print(r)
        con.close()
    except Exception as e:
        print(f"Error reading {path}: {e}")
