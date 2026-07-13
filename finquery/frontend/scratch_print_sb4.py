import re

with open(r"c:\Users\akash\OneDrive\Desktop\thegradnew\finquery\frontend\clean_template.html", "r", encoding="utf-8") as f:
    text = f.read()

aside_match = re.search(r'<aside class="sb".*?</aside>', text, re.DOTALL)
if aside_match:
    with open(r"c:\Users\akash\OneDrive\Desktop\thegradnew\finquery\frontend\extracted_sidebar.html", "w", encoding="utf-8") as f_out:
        f_out.write(aside_match.group(0))
    print("Saved extracted sidebar aside to extracted_sidebar.html")
else:
    print("Sidebar aside not found")
