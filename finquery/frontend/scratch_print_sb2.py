with open(r"c:\Users\akash\OneDrive\Desktop\thegradnew\finquery\frontend\unpacked_template.html", "r", encoding="utf-8") as f:
    text = f.read()

# Let's clean up escapes in the template text to find elements
text_clean = text.replace(r"\n", "\n").replace(r"\"", '"').replace(r"\/", "/")

# Let's search for class="sb" inside the unescaped text
import re
match = re.search(r'<div class="sb".*?</div>', text_clean, re.DOTALL)
if match:
    print("Found div class=sb:")
    print(match.group(0)[:1500])
else:
    # Just print the first 2000 chars of body
    body_match = re.search(r'<body>(.*?)</body>', text_clean, re.DOTALL)
    if body_match:
        print("Found body:")
        print(body_match.group(1)[:2000])
