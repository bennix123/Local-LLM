import urllib.request
import json
import sys

URL = "http://127.0.0.1:5668/query"

test_questions = [
    "how much money did i spend in groceries in may 2026?",
    "how many transactions do i have on swiggy?",
    "what is my average monthly spend on entertainment?",
    "who paid me recently?",
    "what was my balance after the last transaction?",
    "show me the breakdown of my spending by category in 2026",
    "total spent at aldi",
    "how much did i receive in savings space in wrenfield bank?",
    "which months did i spend on aldi?",
    "give me advice on how to save money for a car next year"
]

def run_query(q):
    data = json.dumps({"question": q}).encode("utf-8")
    req = urllib.request.Request(URL, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
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
            return route, ans
    except Exception as e:
        return "error", str(e)

print("Starting comprehensive test...")
for i, q in enumerate(test_questions, 1):
    print(f"\n--- Test {i}: {q} ---")
    route, ans = run_query(q)
    print(f"Route: {route}")
    print(f"Answer: {ans}")
