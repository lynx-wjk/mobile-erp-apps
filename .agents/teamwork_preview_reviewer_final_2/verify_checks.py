import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

lp = Path(r"landing_page")
index = (lp / "index.html").read_text(encoding="utf-8")
js = (lp / "app.js").read_text(encoding="utf-8")
css = (lp / "styles.css").read_text(encoding="utf-8")
robots = (lp / "robots.txt").read_text(encoding="utf-8")
sitemap = (lp / "sitemap.xml").read_text(encoding="utf-8")

# 1. Prohibited scan
for name, content in [('index.html', index), ('app.js', js), ('styles.css', css), ('robots.txt', robots), ('sitemap.xml', sitemap)]:
    matches = re.findall(r'\bowner\b', content, re.IGNORECASE)
    assert len(matches) == 0, f"Found owner in {name}: {matches}"
print("[PASS] Prohibited words: 0 matches across all files.")

# 2. Schema validation
schema_blocks = re.findall(r'<script[^>]*application/ld\+json[^>]*>(.*?)</script>', index, re.DOTALL)
assert len(schema_blocks) >= 1
data = json.loads(schema_blocks[0])
graph = data.get('@graph', [])
types = {item.get('@type') for item in graph}
expected = {'Organization', 'SoftwareApplication', 'WebSite', 'BreadcrumbList', 'FAQPage'}
assert expected.issubset(types), f"Missing types: {expected - types}"
print(f"[PASS] JSON-LD Schema @graph contains all 5 required schemas: {types}")

# 3. XML Sitemap validation
tree = ET.fromstring(sitemap)
urls = [elem.text for elem in tree.findall('.//{http://www.sitemaps.org/schemas/sitemap/0.9}loc')]
print(f"[PASS] Sitemap.xml valid XML with {len(urls)} URLs: {urls}")

# 4. Robots.txt validation
assert "User-agent: Googlebot" in robots
assert "Sitemap: https://mdhproduction.com/sitemap.xml" in robots
print("[PASS] robots.txt properly configured for Googlebot with canonical sitemap URL.")

# 5. Indonesian SEO & Geo
assert 'name="geo.region" content="ID"' in index
assert 'Jakarta, Indonesia' in index
assert 'lang="id"' in index
print("[PASS] Indonesian SEO & Geo tags fully verified.")

# 6. 5-Module taxonomy check
for mod in ['WMS', 'OMS', 'FMS', 'HRIS', 'EMS']:
    assert mod in index, f"Missing module {mod}"
print("[PASS] 5-Module taxonomy (WMS, OMS, FMS, HRIS, EMS) present.")

# 7. Check WhatsApp link formatting & official contact numbers
wa_links = re.findall(r'href=[\'"](https://wa\.me/[^\'"]+)[\'"]', index)
print(f"[PASS] Found {len(wa_links)} WhatsApp links in index.html, all pointing to wa.me:")
for idx, link in enumerate(wa_links, 1):
    assert "6285155338246" in link, f"Invalid phone in link {link}"
    assert "Halo%20Tim%20Konsultan" in link or "Halo%20Tim%20" in link, f"Invalid message greeting in link {link}"
    print(f"  {idx}. {link[:80]}...")
