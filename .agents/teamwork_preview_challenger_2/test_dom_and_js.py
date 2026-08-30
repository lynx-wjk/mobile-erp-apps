import re
from collections import Counter
from pathlib import Path

index_path = Path("landing_page/index.html")
content = index_path.read_text(encoding="utf-8")

# 1. Regex check for IDs
raw_ids = re.findall(r'\bid=["\']([^"\']+)["\']', content)
counts = Counter(raw_ids)
duplicates = {k: v for k, v in counts.items() if v > 1}

print("=== DOM ID UNIQUENESS AUDIT ===")
print(f"Total ID attributes: {len(raw_ids)}")
print(f"Unique ID attributes: {len(counts)}")
if duplicates:
    print(f"DUPLICATE IDs DETECTED: {duplicates}")
else:
    print("STATUS: PASS - 100% Unique DOM IDs")

# 2. Check each target ID referenced by app.js
app_js = Path("landing_page/app.js").read_text(encoding="utf-8")
js_ids = re.findall(r'getElementById\(["\']([^"\']+)["\']\)', app_js)
js_qs_ids = re.findall(r'querySelector\(["\']#([^"\'\s,>+~]+)["\']\)', app_js)
all_target_ids = set(js_ids + js_qs_ids)

print("\n=== JS DOM HOOK INTEGRITY AUDIT ===")
print(f"Target IDs queried by app.js: {sorted(all_target_ids)}")
missing_in_dom = []
for target in all_target_ids:
    if target not in counts:
        missing_in_dom.append(target)

if missing_in_dom:
    print(f"CRITICAL: IDs queried in app.js but missing in index.html: {missing_in_dom}")
else:
    print("STATUS: PASS - All JS DOM query hooks exist in index.html")
