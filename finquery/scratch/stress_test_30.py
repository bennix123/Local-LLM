import urllib.request
import json
import time

URL = "http://127.0.0.1:5668/query"

test_questions = [
    # Category / Merchant Spend & Count
    "how much money did i spend in groceries in may 2026?",
    "how many transactions do i have on swiggy?",
    "what is my average monthly spend on entertainment?",
    "who paid me recently?",
    "what was my balance after the last transaction?",
    "show me the breakdown of my spending by category in 2026",
    "total spent at aldi",
    "how much did i receive in savings space in wrenfield bank?",
    "which months did i spend on aldi?",
    "give me advice on how to save money for a car next year",
    # Complex Mathematical / Multi-entity Queries
    "what is the total spending in Coop Demo bank in June 2026?",
    "how much did i spend on transport and groceries combined in 2026?",
    "what is the ratio of groceries to total spending?",
    "which month did i spend the most?",
    "what is the average transaction size for shopping?",
    "show me all transactions above 1000",
    "how much money did i save in 2025?",
    "what is my net savings rate in the last 3 months?",
    "did i spend more on utilities or healthcare in 2026?",
    "what was my highest single credit?",
    # Pushing combinations and specific limits
    "what is the sum of all transfers in Wrenfield Bank?",
    "how much did i spend at aldi and morrisons together?",
    "how many times did i pay aldi in march 2026?",
    "what is the average spent per transaction overall?",
    "did i receive any freelance payment?",
    "what was my balance on 15 march 2026?",
    "list my top 3 merchants by total spending",
    "what is the ratio of my entertainment spending to groceries spending?",
    "how much money is left in all accounts combined?",
    "compare my spending in may 2026 vs june 2026"
]

def run_query(q):
    data = json.dumps({"question": q}).encode("utf-8")
    req = urllib.request.Request(URL, data=data, headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
        # 30 second timeout to accommodate Ollama warmup/CPU execution
        with urllib.request.urlopen(req, timeout=30) as resp:
            lines = resp.read().decode("utf-8").split("\n")
            ans_parts = []
            route = "unknown"
            for line in lines:
                if not line.strip():
                    continue
                try:
                    d = json.loads(line)
                    if d.get("type") == "chunk":
                        ans_parts.append(d.get("content", ""))
                    elif d.get("type") == "route":
                        route = d.get("content", "")
                except Exception:
                    pass
            ans = "".join(ans_parts).strip()
            dt = time.time() - t0
            return route, ans, dt
    except Exception as e:
        dt = time.time() - t0
        return "error", str(e), dt

print("Starting 30-Question Stress Test...")
results = []
for i, q in enumerate(test_questions, 1):
    print(f"Running Test {i}/30: {q} ... ", end="", flush=True)
    route, ans, dt = run_query(q)
    print(f"[{route}] in {dt:.1f}s")
    results.append({
        "index": i,
        "question": q,
        "route": route,
        "answer": ans,
        "time": dt
    })

# Write results to a markdown log for analysis
log_path = "scratch/stress_test_results.md"
with open(log_path, "w", encoding="utf-8") as f:
    f.write("# 30-Question Stress Test Results\n\n")
    f.write("| No | Question | Route | Time (s) | Answer |\n")
    f.write("| --- | --- | --- | --- | --- |\n")
    for r in results:
        # truncate answer for readability
        ans_short = r["answer"].replace("\n", " ").replace("|", "\\|")[:120]
        f.write(f"| {r['index']} | {r['question']} | {r['route']} | {r['time']:.2f} | {ans_short} |\n")

print(f"\nDone! Results logged to {log_path}")
