import os
import re
import json
import glob
import struct
import urllib.parse

LANDING_DIR = r"c:\Users\budic\Downloads\android\inventory_control_apps\landing_page"
LIB_DIR = r"c:\Users\budic\Downloads\android\inventory_control_apps\lib"
SCHEMA_SQL = r"c:\Users\budic\Downloads\android\inventory_control_apps\migration_selfhost\schema.sql"

results = {
    "static_analysis": {},
    "asset_verification": {},
    "schema_seo": {},
    "contact_consultation": {},
    "codebase_fidelity": {},
    "prohibited_patterns": {}
}

print("=================================================================")
print("STARTING FORENSIC INTEGRITY AUDIT: MOBILE ERP LANDING PAGE")
print("=================================================================\n")

# -------------------------------------------------------------
# 1. STATIC ANALYSIS & PROHIBITED STRINGS SCAN
# -------------------------------------------------------------
print("--- 1. STATIC ANALYSIS & PROHIBITED PATTERNS SCAN ---")
forbidden_terms = ["owner", "platform owner", "hubungi owner", "portal owner", "login portal owner", "TODO", "FIXME", "lorem", "ipsum", "fake", "mock_data"]
prohibited_findings = []

text_files = []
for root, _, files in os.walk(LANDING_DIR):
    for f in files:
        if not f.endswith(('.png', '.jpg', '.jpeg', '.ico', '.webp')):
            text_files.append(os.path.join(root, f))

for file_path in text_files:
    rel = os.path.relpath(file_path, LANDING_DIR)
    with open(file_path, "r", encoding="utf-8", errors="ignore") as fp:
        content = fp.read()
    
    # Prohibited words
    for term in forbidden_terms:
        matches = list(re.finditer(r'\b' + re.escape(term) + r'\b', content, re.IGNORECASE))
        if matches:
            prohibited_findings.append({
                "file": rel,
                "term": term,
                "count": len(matches),
                "samples": [content[max(0, m.start()-30):min(len(content), m.end()+30)] for m in matches[:3]]
            })

results["prohibited_patterns"]["forbidden_findings"] = prohibited_findings
print(f"Forbidden term matches count: {len(prohibited_findings)}")
if prohibited_findings:
    for item in prohibited_findings:
        print(f"  [FLAG] Found {item['term']} in {item['file']} ({item['count']} times)")
else:
    print("  [PASS] Zero occurrences of prohibited terms (owner, platform owner, TODO, lorem, etc.)")

# Check required enterprise terminology
index_path = os.path.join(LANDING_DIR, "index.html")
with open(index_path, "r", encoding="utf-8") as fp:
    index_html = fp.read()

required_terms = [
    "Tim Konsultan Enterprise",
    "Tim Solusi Mobile ERP",
    "Hubungi Tim Spesialis",
    "WMS", "Warehouse Management System",
    "OMS", "Omnichannel Management System",
    "FMS", "Financial Management System",
    "HRIS", "Stream Operations",
    "EMS", "Enterprise Multi-Tenant Security"
]

missing_required = []
for term in required_terms:
    if term not in index_html:
        missing_required.append(term)

print(f"Required enterprise terms check: {len(missing_required)} missing")
if missing_required:
    print(f"  [FLAG] Missing required terms: {missing_required}")
else:
    print("  [PASS] All formal enterprise taxonomy and consulting labels present in index.html")

# -------------------------------------------------------------
# 2. ASSET VERIFICATION (assets/logo.png)
# -------------------------------------------------------------
print("\n--- 2. ASSET VERIFICATION (assets/logo.png) ---")
logo_path = os.path.join(LANDING_DIR, "assets", "logo.png")
if not os.path.exists(logo_path):
    print("  [FLAG] assets/logo.png does NOT exist!")
    results["asset_verification"]["exists"] = False
else:
    file_size = os.path.getsize(logo_path)
    with open(logo_path, "rb") as f:
        header = f.read(24)
    
    # PNG signature: 89 50 4E 47 0D 0A 1A 0A
    is_png = header.startswith(b'\x89PNG\r\n\x1a\n')
    width, height = struct.unpack(">II", header[16:24])
    
    print(f"  File size: {file_size} bytes")
    print(f"  PNG Header Valid: {is_png}")
    print(f"  Dimensions: {width} x {height} px")
    
    results["asset_verification"] = {
        "exists": True,
        "file_size": file_size,
        "is_png": is_png,
        "width": width,
        "height": height
    }

# Check usages in index.html
usages = {
    "favicon": bool(re.search(r'<link[^>]+rel=["\'](?:shortcut )?icon["\'][^>]+href=["\']assets/logo\.png["\']', index_html, re.I)),
    "navbar_logo": bool(re.search(r'<nav[^>]*>[\s\S]*?<img[^>]+src=["\']assets/logo\.png["\'][\s\S]*?</nav>', index_html, re.I)),
    "footer_logo": bool(re.search(r'<footer[^>]*>[\s\S]*?<img[^>]+src=["\']assets/logo\.png["\'][\s\S]*?</footer>', index_html, re.I)),
    "og_image": bool(re.search(r'<meta[^>]+property=["\']og:image["\'][^>]+content=["\']https://mdhproduction\.com/assets/logo\.png["\']', index_html, re.I)),
    "twitter_image": bool(re.search(r'<meta[^>]+name=["\']twitter:image["\'][^>]+content=["\']https://mdhproduction\.com/assets/logo\.png["\']', index_html, re.I)),
    "schema_logo": ("assets/logo.png" in index_html and "mdhproduction.com/assets/logo.png" in index_html)
}

for k, v in usages.items():
    print(f"  Usage in {k}: {'[PASS]' if v else '[FLAG]'}")
results["asset_verification"]["usages"] = usages

# -------------------------------------------------------------
# 3. SCHEMA & SEO AUDIT
# -------------------------------------------------------------
print("\n--- 3. SCHEMA & SEO AUDIT ---")
# Extract JSON-LD script tags
json_ld_matches = re.findall(r'<script\s+type=["\']application/ld\+json["\']>([\s\S]*?)</script>', index_html, re.I)
print(f"  JSON-LD scripts found: {len(json_ld_matches)}")

schema_data = None
for script_content in json_ld_matches:
    try:
        parsed = json.loads(script_content)
        schema_data = parsed
        print("  [PASS] Successfully parsed JSON-LD block")
    except Exception as e:
        print(f"  [FLAG] JSON-LD parse error: {e}")

if schema_data:
    if "@graph" in schema_data:
        types = [item.get("@type") for item in schema_data["@graph"]]
        print(f"  @graph entity types found: {types}")
        expected_types = ["SoftwareApplication", "Organization", "WebSite", "FAQPage"]
        for et in expected_types:
            has_type = any(et in str(t) for t in types)
            print(f"    - Type {et}: {'[PASS]' if has_type else '[FLAG]'}")
    else:
        print("  [FLAG] JSON-LD root does not contain '@graph'")

# Robots.txt audit
robots_path = os.path.join(LANDING_DIR, "robots.txt")
with open(robots_path, "r", encoding="utf-8") as fp:
    robots_txt = fp.read()

has_user_agent = "User-agent:" in robots_txt
has_sitemap = "Sitemap: https://mdhproduction.com/sitemap.xml" in robots_txt
print(f"  robots.txt check:")
print(f"    - User-agent directive: {'[PASS]' if has_user_agent else '[FLAG]'}")
print(f"    - Sitemap directive: {'[PASS]' if has_sitemap else '[FLAG]'}")

# Sitemap.xml audit
sitemap_path = os.path.join(LANDING_DIR, "sitemap.xml")
with open(sitemap_path, "r", encoding="utf-8") as fp:
    sitemap_xml = fp.read()

has_url = "<loc>https://mdhproduction.com/</loc>" in sitemap_xml
has_image_loc = "<image:loc>https://mdhproduction.com/assets/logo.png</image:loc>" in sitemap_xml
print(f"  sitemap.xml check:")
print(f"    - Main loc tag: {'[PASS]' if has_url else '[FLAG]'}")
print(f"    - Image loc tag: {'[PASS]' if has_image_loc else '[FLAG]'}")

# -------------------------------------------------------------
# 4. CONTACT & CONSULTATION ENGINE AUDIT
# -------------------------------------------------------------
print("\n--- 4. CONTACT & CONSULTATION ENGINE AUDIT ---")
# Check phone number & email
phone_checks = {
    "raw_phone_0851": "085155338246" in index_html,
    "intl_phone_62851": "6285155338246" in index_html,
    "email_bdchydi": "bdchydi@sre.co.id" in index_html,
    "mailto_link": "mailto:bdchydi@sre.co.id" in index_html
}
for k, v in phone_checks.items():
    print(f"  Contact field {k}: {'[PASS]' if v else '[FLAG]'}")

# Check pricing tier WhatsApp links
tiers = ["Trial Enterprise", "Starter Enterprise", "Growth Enterprise", "Pro Enterprise", "Custom Enterprise"]
# Also check if tiers use short names or full names
print("  Checking pricing tier WhatsApp links in index.html / app.js...")
pricing_buttons = re.findall(r'href=["\'](https://wa\.me/6285155338246\?text=[^"\']+)["\']', index_html)
print(f"  Direct WhatsApp links in HTML: {len(pricing_buttons)}")
for url in pricing_buttons:
    parsed_url = urllib.parse.urlparse(url)
    params = urllib.parse.parse_qs(parsed_url.query)
    text_param = params.get("text", [""])[0]
    print(f"    - Target text: {text_param}")

# Check app.js for WhatsApp builder logic
app_js_path = os.path.join(LANDING_DIR, "app.js")
with open(app_js_path, "r", encoding="utf-8") as fp:
    app_js = fp.read()

has_wa_builder = "6285155338246" in app_js
print(f"  app.js WhatsApp integration: {'[PASS]' if has_wa_builder else '[FLAG]'}")

# -------------------------------------------------------------
# 5. CODEBASE FIDELITY AUDIT (lib/features & SQL Schema)
# -------------------------------------------------------------
print("\n--- 5. CODEBASE FIDELITY AUDIT ---")
feature_mappings = [
    # WMS
    ("WMS Multi-Warehouse", os.path.exists(os.path.join(LIB_DIR, "features", "stock"))),
    # OMS
    ("OMS Shopee/TikTok Sync", os.path.exists(os.path.join(LIB_DIR, "features", "marketplace"))),
    # FMS
    ("FMS Finance Settlement", os.path.exists(os.path.join(LIB_DIR, "features", "finance"))),
    # HRIS
    ("HRIS Live Host", os.path.exists(os.path.join(LIB_DIR, "features", "host_live"))),
    ("HRIS Attendance/Payroll", os.path.exists(os.path.join(LIB_DIR, "features", "attendance")) and os.path.exists(os.path.join(LIB_DIR, "features", "hr"))),
]

for name, exists in feature_mappings:
    print(f"  Feature module {name}: {'[PASS]' if exists else '[FLAG]'}")

# Verify database tables mentioned in EMS / FMS / OMS / WMS
with open(SCHEMA_SQL, "r", encoding="utf-8", errors="ignore") as fp:
    schema_sql_content = fp.read()

db_tables_to_check = [
    "work_locations", "products", "stock_transfers", "stock_opnames",
    "marketplace_store_integrations", "marketplace_order_sync", "marketplace_item_variants",
    "marketplace_finance_settlements", "marketplace_finance_discrepancies",
    "live_stream_sessions", "staff_attendances", "payroll_records", "staff_commissions"
]

print("  Checking PostgreSQL Schema Table Existence in migration_selfhost/schema.sql:")
for tbl in db_tables_to_check:
    tbl_exists = f"CREATE TABLE IF NOT EXISTS {tbl}" in schema_sql_content or f"CREATE TABLE {tbl}" in schema_sql_content or f"public.{tbl}" in schema_sql_content
    print(f"    - Table '{tbl}': {'[PASS]' if tbl_exists else '[FLAG]'}")

# Check RLS enabled
rls_enabled_count = len(re.findall(r'ENABLE ROW LEVEL SECURITY', schema_sql_content, re.I))
print(f"  PostgreSQL Tables with Row Level Security (RLS) enabled: {rls_enabled_count}")

print("\n=================================================================")
print("FORENSIC CHECK EXECUTION COMPLETE")
print("=================================================================")
