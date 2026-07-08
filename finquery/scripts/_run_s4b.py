import sys, os, socket
sys.path.insert(0, os.path.join(os.getcwd(), "backend"))
sys.path.insert(0, os.getcwd())
from src.services.txn_store.parsers import parse_generic_statement, _generic_breaks

def ollama_up():
    try:
        s = socket.create_connection(("127.0.0.1", 11434), timeout=2)
        s.close()
        return True
    except Exception:
        return False

status = "UP" if ollama_up() else "DOWN"
print(f"Ollama status: {status}")
print()
print("--- SCENARIO 4b: L1 HIGH VIOLATIONS + OLLAMA DOWN ---")

res = parse_generic_statement("scripts/_s4b_highviolations.pdf")
rows = list(res)
confidence = getattr(res, "parse_confidence", "unknown")
breaks = _generic_breaks(rows) if rows else 0
ratio = breaks / len(rows) if rows else 0

print(f"Result: {len(rows)} rows | confidence={confidence!r} | violations={breaks} ({ratio:.1%})")
if rows:
    for r in rows[:3]:
        print(f"  {r['txn_date']} | {r['descr'][:35]} | Dr:{r['debit']} Cr:{r['credit']} Bal:{r['balance']}")

print()
if not ollama_up():
    if rows:
        if confidence in ("medium", "high"):
            print("VERDICT: Ingestion SUCCEEDED (no crash).")
            print(f"         L1 had {ratio:.1%} violation rate + Ollama was DOWN.")
            print("         Data saved with confidence='medium' (not 'low', not failed).")
            print("         Clarification: current code does NOT downgrade to 'low' in this combo — it saves best L1 as 'medium'.")
        elif confidence == "low":
            print("VERDICT: Saved as 'low' confidence. Ingestion did not crash.")
    else:
        print("VERDICT: 0 rows — both L1 and LLMs returned nothing. Empty result (not a crash).")
else:
    print(f"Ollama is UP — not a true outage test. Result: {confidence}")
