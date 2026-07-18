import urllib.request
import json
import time
import sys

# Set standard output to UTF-8 to prevent UnicodeEncodeError in command prompt
sys.stdout.reconfigure(encoding='utf-8')

URL = "http://127.0.0.1:5668/query"

test_questions = [
    "should i cap my groceries spending?",
    "why is my net savings rate what it is?",
    "where can i save money to buy a car next year?",
    "roast my spending style",
    "is my current spending healthy compared to my income?",
    "explain why i spent money on rent",
    "am i dependent on a single income source?",
    "why is there a difference between my income and spending?",
    "should i reduce my shopping expenses?",
    "how can i invest my surplus money?",
    "what is the biggest threat to my savings?",
    "explain my entertainment spending habits",
    "how much buffer do i have for an emergency fund?",
    "should i stop spending on subscriptions?",
    "roast my groceries expenses",
    "is my lifestyle sustainable?",
    "why did my balance change between last year and this year?",
    "where is most of my money leaking?",
    "can i afford to buy a premium laptop next month?",
    "explain why my monthly net savings are positive",
    "what should be my top next step to improve my financial health?",
    "roast my shopping habits",
    "should i cut down on utilities?",
    "is my savings rate of 24 percent good or bad?",
    "why was my highest transaction so big?",
    "give me advice on how to invest ₹10000000",
    "should i worry about my entertainment spending?",
    "how can i double my savings next month?",
    "explain where my cash withdrawals are going",
    "roast my overall financial state"
]

def run_query(q):
    data = json.dumps({"question": q}).encode("utf-8")
    req = urllib.request.Request(URL, data=data, headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
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

print("Starting 30-Question LLM Advice & Reasoning Stress Test...")
results = []
for i, q in enumerate(test_questions, 1):
    # Only run the remaining questions (25-30) or we can run all of them again. Let's run all of them with proper encoding.
    print(f"Running LLM Test {i}/30: {q} ... ", end="", flush=True)
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
log_path = "scratch/llm_test_results.md"
with open(log_path, "w", encoding="utf-8") as f:
    f.write("# 30-Question LLM Stress Test Results\n\n")
    f.write("| No | Question | Route | Time (s) | Answer |\n")
    f.write("| --- | --- | --- | --- | --- |\n")
    for r in results:
        ans_short = r["answer"].replace("\n", " ").replace("|", "\\|")[:120]
        f.write(f"| {r['index']} | {r['question']} | {r['route']} | {r['time']:.2f} | {ans_short} |\n")

print(f"\nDone! Results logged to {log_path}")
