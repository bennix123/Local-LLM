import urllib.request
import json

URL = "http://127.0.0.1:5668/query"

test_questions = [
    "june 2026 me kitna kharch kiya groceries par?",
    "swiggy par total kitne transaction huye?",
    "mujhe batao sabse bada kharcha kaun sa tha?",
    "mere account me kitna balance bacha hai?"
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

print("Starting Hinglish test...")
for i, q in enumerate(test_questions, 1):
    print(f"\n--- Test {i}: {q} ---")
    route, ans = run_query(q)
    print(f"Route: {route}")
    print(f"Answer: {ans}")
