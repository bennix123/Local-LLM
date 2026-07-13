import json

with open(r"c:\Users\akash\OneDrive\Desktop\thegradnew\finquery\frontend\unpacked_template.html", "r", encoding="utf-8") as f:
    raw = f.read()

# Since unpacked_template.html is stored as a JSON string literal (e.g. starting with "), we load it as json
try:
    decoded = json.loads(raw)
except Exception:
    # If not valid json directly, maybe strip whitespace or try raw
    decoded = raw

# Save unescaped clean HTML
with open(r"c:\Users\akash\OneDrive\Desktop\thegradnew\finquery\frontend\clean_template.html", "w", encoding="utf-8") as f:
    f.write(decoded)

print("Saved unescaped clean HTML to clean_template.html (len: {})".format(len(decoded)))
