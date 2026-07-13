import re

with open(r"D:\Downloads\Penny - Mac.html", "r", encoding="utf-8") as f:
    content = f.read()

# Let's see if there are type="__bundler/template" script tags
templates = re.findall(r'<script type="__bundler/template">(.*?)</script>', content, re.DOTALL)
print("Templates found:", len(templates))
if templates:
    # Let's save the first template to a file to examine it
    with open(r"c:\Users\akash\OneDrive\Desktop\thegradnew\finquery\frontend\unpacked_template.html", "w", encoding="utf-8") as out:
        out.write(templates[0])
    print("Saved template to unpacked_template.html")
