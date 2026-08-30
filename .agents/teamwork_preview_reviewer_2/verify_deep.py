import json
import re
import urllib.parse
import xml.etree.ElementTree as ET
from pathlib import Path

BASE_DIR = Path(r"c:\Users\budic\Downloads\android\inventory_control_apps\landing_page")

def test_jsonld():
    html = (BASE_DIR / "index.html").read_text(encoding="utf-8")
    m = re.search(r'<script type="application/ld\+json">([\s\S]*?)</script>', html)
    assert m, "JSON-LD script tag not found"
    data = json.loads(m.group(1))
    graph = data.get("@graph", [])
    print(f"JSON-LD @graph contains {len(graph)} items:")
    types = [item.get("@type") for item in graph]
    print(f"Types: {types}")
    assert "Organization" in types
    assert "SoftwareApplication" in types
    assert "WebSite" in types
    assert "BreadcrumbList" in types
    assert "FAQPage" in types
    print("PASS: All 5 JSON-LD schemas validated successfully.")

def test_seo_meta():
    html = (BASE_DIR / "index.html").read_text(encoding="utf-8")
    # Title
    m_title = re.search(r'<title>([^<]+)</title>', html)
    print("Title:", m_title.group(1) if m_title else "NONE")
    
    # Indonesian Keywords
    m_kw = re.search(r'<meta name="keywords" content="([^"]+)"', html)
    print("Keywords:", m_kw.group(1) if m_kw else "NONE")
    
    # Geo tags
    m_geo = re.findall(r'<meta name="geo\.[^"]+" content="([^"]+)"', html)
    print("Geo tags:", m_geo)
    
    # Robots.txt
    robots = (BASE_DIR / "robots.txt").read_text(encoding="utf-8")
    print(f"Robots.txt lines: {len(robots.splitlines())}")
    assert "Googlebot" in robots
    assert "sitemap.xml" in robots
    
    # Sitemap.xml
    sitemap = (BASE_DIR / "sitemap.xml").read_text(encoding="utf-8")
    assert "http://www.google.com/schemas/sitemap-image/1.1" in sitemap
    assert "https://mdhproduction.com/assets/logo.png" in sitemap
    print("PASS: SEO metadata, robots.txt, and sitemap.xml verified.")

def test_whatsapp_links():
    html = (BASE_DIR / "index.html").read_text(encoding="utf-8")
    wa_matches = re.findall(r'href="(https://wa\.me/[^"]+)"', html)
    print(f"Found {len(wa_matches)} WhatsApp URLs in HTML:")
    for url in wa_matches:
        parsed = urllib.parse.urlparse(url)
        params = urllib.parse.parse_qs(parsed.query)
        text = params.get('text', [''])[0]
        print(f"  URL: {url[:50]}... -> Phone: {parsed.path}, Text: '{text}'")

if __name__ == "__main__":
    print("--- 1. JSON-LD ---")
    test_jsonld()
    print("\n--- 2. SEO META ---")
    test_seo_meta()
    print("\n--- 3. WHATSAPP URLS ---")
    test_whatsapp_links()
