import urllib.request
import json
import time

URL = "http://127.0.0.1:5668/query"

test_questions = [
    # Anomalies
    "do i have any unusual transactions?",
    "are there any strange transactions?",
    "show me unusual expenses",
    "detect anomalies in my statement",
    "anomalous transactions recently",
    "unusual spending patterns",
    "flag strange transactions",
    "any suspicious charges?",
    "any outliers in my spending?",
    "show me all anomalies",
    # Forecasts
    "predict my spending for next month",
    "what is my spending forecast?",
    "forecast next month spending",
    "project my spending",
    "future spending prediction",
    "next month expense forecast",
    "forecast spending by category",
    "what will i spend next month?",
    "predict next month total spent",
    "spending projection for next month",
    # Projections / Run-rate
    "what is my annual run-rate projection?",
    "project my annual spending and savings",
    "run-rate projection",
    "annual savings projection",
    "project my future net savings",
    "annual spending rate",
    "what is my current pace of spending?",
    "projected annual spending at this pace",
    "what is my annual run-rate?",
    "projected yearly savings",
    # Bank-specific / Category-specific ML queries
    "unusual transactions in Coop Demo bank",
    "detect anomalies in Wrenfield Bank",
    "forecast spending for Coop Demo bank",
    "project my annual spending in Wrenfield Bank",
    "are there any unusual shopping expenses?",
    "forecast shopping spending next month",
    "any anomalous grocery spending?",
    "forecast groceries spending",
    "project annual groceries spend",
    "are there any strange entertainment payments?"
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

print("Starting 40-Question ML Stress Test...")
results = []
for i, q in enumerate(test_questions, 1):
    print(f"Running ML Test {i}/40: {q} ... ", end="", flush=True)
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
log_path = "scratch/ml_test_results.md"
with open(log_path, "w", encoding="utf-8") as f:
    f.write("# 40-Question ML Stress Test Results\n\n")
    f.write("| No | Question | Route | Time (s) | Answer |\n")
    f.write("| --- | --- | --- | --- | --- |\n")
    for r in results:
        ans_short = r["answer"].replace("\n", " ").replace("|", "\\|")[:120]
        f.write(f"| {r['index']} | {r['question']} | {r['route']} | {r['time']:.2f} | {ans_short} |\n")

print(f"\nDone! Results logged to {log_path}")
