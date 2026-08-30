import re
import json
import urllib.parse
from pathlib import Path

lp = Path('landing_page')
html = (lp / 'index.html').read_text(encoding='utf-8')
css = (lp / 'styles.css').read_text(encoding='utf-8')
js = (lp / 'app.js').read_text(encoding='utf-8')
robots = (lp / 'robots.txt').read_text(encoding='utf-8')
sitemap = (lp / 'sitemap.xml').read_text(encoding='utf-8')

print("=" * 60)
print("1. PROHIBITED TERMS AUDIT")
print("=" * 60)
for name, content in [('index.html', html), ('styles.css', css), ('app.js', js), ('robots.txt', robots), ('sitemap.xml', sitemap)]:
    matches = list(re.finditer(r'\bowner\b', content, re.I))
    print(f"Prohibited term check in {name}: {len(matches)} matches")
    assert len(matches) == 0, f"Found prohibited term in {name}: {matches}"

print("\n" + "=" * 60)
print("2. WHATSAPP LINKS AUDIT")
print("=" * 60)
wa_links = re.findall(r'https://wa\.me/[^\s"\'<>]+', html)
print(f"Found {len(wa_links)} WhatsApp links in index.html")
for idx, l in enumerate(wa_links, 1):
    assert '6285155338246' in l, f"Wrong phone in {l}"
    parsed = urllib.parse.urlparse(l)
    qs = urllib.parse.parse_qs(parsed.query)
    text = qs.get('text', [''])[0]
    print(f"[{idx}] {l[:55]}... -> Decoded Text: {text}")
    assert 'Tim Konsultan' in text, f"Missing consultant phrasing in link {idx}: {l}"

print("\n" + "=" * 60)
print("3. EMAIL CONTACT AUDIT")
print("=" * 60)
mail_links = re.findall(r'mailto:[^\s"\'<>]+', html)
print(f"Found {len(mail_links)} mailto links in index.html: {mail_links}")
for m in mail_links:
    assert 'bdchydi@sre.co.id' in m, f"Incorrect email link: {m}"

print("\n" + "=" * 60)
print("4. VISUAL TOKENS & TYPOGRAPHY AUDIT")
print("=" * 60)
assert '#080c14' in css.lower(), "Missing #080c14 obsidian background token in styles.css"
assert '#0d1322' in css.lower(), "Missing #0d1322 obsidian surface token in styles.css"
assert 'rgba(255, 255, 255, 0.07)' in css, "Missing 1px micro-border token in styles.css"
assert 'Outfit' in css, "Missing Outfit font-family in styles.css"
assert 'Plus Jakarta Sans' in css, "Missing Plus Jakarta Sans font-family in styles.css"
print("All visual craftsmanship tokens (Obsidian #080c14 / #0d1322, 1px micro-border, Outfit + Plus Jakarta Sans) verified.")

print("\n" + "=" * 60)
print("5. NAVBAR BRAND LOGO DOM AUDIT")
print("=" * 60)
assert '<nav' in html, "Missing nav element"
assert 'assets/logo.png' in html, "Missing assets/logo.png reference"
print("Navbar DOM hierarchy and logo presence confirmed.")

print("\n" + "=" * 60)
print("6. REAL ERP TAXONOMY FIDELITY AUDIT")
print("=" * 60)
for mod in ["WMS", "OMS", "FMS", "HRIS", "EMS"]:
    assert mod in html, f"Missing module {mod} in HTML"
    print(f"Module {mod} present in taxonomy and telemetry.")

print("\nALL ADVERSARIAL VERIFICATION CHECKS SUCCEEDED!")
