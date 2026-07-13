import re

with open(r"c:\Users\akash\OneDrive\Desktop\thegradnew\finquery\frontend\unpacked_template.html", "r", encoding="utf-8") as f:
    text = f.read()

# Search for the class="sb" aside element
aside_match = re.search(r'<aside class="sb".*?</aside>', text, re.DOTALL)
if aside_match:
    print("Found Sidebar aside:")
    # Print the aside block but replace \n with actual newlines if escaped
    raw_aside = aside_match.group(0).replace(r"\n", "\n").replace(r"\"", '"').replace(r"\/", "/")
    print(raw_aside)
else:
    print("Aside class='sb' not found directly. Let's find any class='sb'")
    for match in re.finditer(r'class="sb"', text):
        start = max(0, match.start() - 100)
        end = min(len(text), match.end() + 1000)
        print(text[start:end])
