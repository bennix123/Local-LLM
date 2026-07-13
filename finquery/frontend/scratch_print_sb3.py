import re

with open(r"c:\Users\akash\OneDrive\Desktop\thegradnew\finquery\frontend\clean_template.html", "r", encoding="utf-8") as f:
    text = f.read()

# Let's find class="sb" aside element
aside_match = re.search(r'<aside class="sb".*?</aside>', text, re.DOTALL)
if aside_match:
    print("Sidebar found in clean_template.html:")
    print(aside_match.group(0))
else:
    print("Sidebar class='sb' not found in clean_template.html!")
