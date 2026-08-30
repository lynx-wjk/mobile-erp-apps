#!/usr/bin/env python3
"""
Empirical Challenger Test Suite for Mobile ERP Landing Page.
Executes live HTTP server verification, broken asset checks,
JSON-LD schema validation, WhatsApp URL decoding, and terminology governance.
"""

import http.server
import json
import os
import re
import socket
import socketserver
import sys
import threading
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path
from typing import Dict, List, Set, Tuple, Any

PROJECT_ROOT = Path(__file__).resolve().parent.parent
LANDING_PAGE_DIR = PROJECT_ROOT / "landing_page"
INDEX_HTML = LANDING_PAGE_DIR / "index.html"
STYLES_CSS = LANDING_PAGE_DIR / "styles.css"
APP_JS = LANDING_PAGE_DIR / "app.js"
ROBOTS_TXT = LANDING_PAGE_DIR / "robots.txt"
SITEMAP_XML = LANDING_PAGE_DIR / "sitemap.xml"
LOGO_PNG = LANDING_PAGE_DIR / "assets" / "logo.png"

CANONICAL_PHONE = "6285155338246"
LOCAL_PHONE = "085155338246"
OFFICIAL_EMAIL = "bdchydi@sre.co.id"


class QuietHTTPHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(LANDING_PAGE_DIR), **kwargs)

    def log_message(self, format, *args):
        pass


def get_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class HTMLTagExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.tags = []
        self.all_ids = set()
        self.img_srcs = []
        self.link_hrefs = []
        self.script_srcs = []
        self.a_hrefs = []
        self.scripts = []
        self.current_script_type = None
        self.current_script_content = []
        self.raw_text = []

    def handle_starttag(self, tag, attrs):
        attr_dict = dict(attrs)
        self.tags.append((tag, attr_dict, self.getpos()))
        if "id" in attr_dict:
            self.all_ids.add(attr_dict["id"])
        if tag == "img" and "src" in attr_dict:
            self.img_srcs.append((attr_dict["src"], attr_dict.get("alt", ""), self.getpos()))
        if tag == "link" and "href" in attr_dict:
            self.link_hrefs.append((attr_dict.get("rel", ""), attr_dict["href"], self.getpos()))
        if tag == "script":
            self.current_script_type = attr_dict.get("type", "text/javascript")
            self.current_script_content = []
            if "src" in attr_dict:
                self.script_srcs.append((attr_dict["src"], self.getpos()))
        if tag == "a" and "href" in attr_dict:
            self.a_hrefs.append((attr_dict["href"], attr_dict.get("class", ""), attr_dict.get("aria-label", ""), self.getpos()))

    def handle_endtag(self, tag):
        if tag == "script":
            content = "".join(self.current_script_content)
            self.scripts.append((self.current_script_type, content))
            self.current_script_type = None
            self.current_script_content = []

    def handle_data(self, data):
        if self.current_script_type is not None:
            self.current_script_content.append(data)
        self.raw_text.append(data)


def run_empirical_challenger_tests() -> Dict[str, Any]:
    report = {
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()),
        "total_checks": 0,
        "passed_checks": 0,
        "failed_checks": 0,
        "sections": {},
        "failures": [],
        "verdict": "APPROVE"
    }

    def check(section_name: str, check_name: str, condition: bool, details: str = ""):
        report["total_checks"] += 1
        if section_name not in report["sections"]:
            report["sections"][section_name] = {"passed": 0, "failed": 0, "items": []}
        
        status = "PASS" if condition else "FAIL"
        if condition:
            report["passed_checks"] += 1
            report["sections"][section_name]["passed"] += 1
        else:
            report["failed_checks"] += 1
            report["sections"][section_name]["failed"] += 1
            report["failures"].append(f"[{section_name}] {check_name}: {details}")
            report["verdict"] = "REQUEST_CHANGES"

        report["sections"][section_name]["items"].append({
            "name": check_name,
            "status": status,
            "details": details
        })
        print(f"  [{status}] {section_name} -> {check_name}" + (f" | {details}" if not condition else ""))

    # =========================================================================
    # SECTION 1: LIVE HTTP SERVER VERIFICATION
    # =========================================================================
    print("\n" + "="*80)
    print("  SECTION 1: LIVE HTTP SERVER & ENDPOINT VERIFICATION")
    print("="*80)

    port = get_free_port()
    server = socketserver.TCPServer(("127.0.0.1", port), QuietHTTPHandler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    time.sleep(0.1)

    base_url = f"http://127.0.0.1:{port}"

    try:
        # Check 1.1: Root endpoint GET /
        req = urllib.request.Request(f"{base_url}/")
        with urllib.request.urlopen(req, timeout=5) as res:
            status = res.getcode()
            ctype = res.headers.get_content_type()
            body = res.read()
            check("HTTP Server", "Root GET / returns HTTP 200", status == 200, f"Status: {status}")
            check("HTTP Server", "Root Content-Type is text/html", ctype == "text/html", f"Content-Type: {ctype}")
            check("HTTP Server", "Root HTML payload size > 10KB", len(body) > 10000, f"Size: {len(body)} bytes")

        # Check 1.2: Assets logo GET /assets/logo.png
        req_logo = urllib.request.Request(f"{base_url}/assets/logo.png")
        with urllib.request.urlopen(req_logo, timeout=5) as res:
            status = res.getcode()
            ctype = res.headers.get_content_type()
            body = res.read()
            check("HTTP Server", "Logo GET /assets/logo.png returns HTTP 200", status == 200, f"Status: {status}")
            check("HTTP Server", "Logo Content-Type is image/png", ctype == "image/png", f"Content-Type: {ctype}")
            check("HTTP Server", "Logo binary signature is valid PNG magic header", body.startswith(b"\x89PNG\r\n\x1a\n"), "Invalid PNG magic header")
            check("HTTP Server", "Logo file size > 50KB", len(body) > 50000, f"Size: {len(body)} bytes")

        # Check 1.3: robots.txt GET /robots.txt
        req_robots = urllib.request.Request(f"{base_url}/robots.txt")
        with urllib.request.urlopen(req_robots, timeout=5) as res:
            status = res.getcode()
            ctype = res.headers.get_content_type()
            body = res.read().decode("utf-8")
            check("HTTP Server", "robots.txt returns HTTP 200", status == 200, f"Status: {status}")
            check("HTTP Server", "robots.txt Content-Type is text/plain", ctype == "text/plain", f"Content-Type: {ctype}")
            check("HTTP Server", "robots.txt contains Sitemap directive", "sitemap.xml" in body.lower(), body)
            check("HTTP Server", "robots.txt allows Googlebot", "user-agent: *" in body.lower() or "googlebot" in body.lower(), body)

        # Check 1.4: sitemap.xml GET /sitemap.xml
        req_sitemap = urllib.request.Request(f"{base_url}/sitemap.xml")
        with urllib.request.urlopen(req_sitemap, timeout=5) as res:
            status = res.getcode()
            ctype = res.headers.get_content_type()
            body = res.read().decode("utf-8")
            check("HTTP Server", "sitemap.xml returns HTTP 200", status == 200, f"Status: {status}")
            check("HTTP Server", "sitemap.xml Content-Type is XML", ctype in ("application/xml", "text/xml"), f"Content-Type: {ctype}")
            try:
                root_xml = ET.fromstring(body)
                check("HTTP Server", "sitemap.xml parses as valid XML", root_xml is not None)
                locs = [elem.text for elem in root_xml.findall(".//{http://www.sitemaps.org/schemas/sitemap/0.9}loc")]
                check("HTTP Server", "sitemap.xml lists canonical domain https://mdhproduction.com/", "https://mdhproduction.com/" in locs or "https://mdhproduction.com" in locs, f"Locs: {locs}")
                
                # Check image schema in sitemap
                image_locs = [elem.text for elem in root_xml.findall(".//{http://www.google.com/schemas/sitemap-image/1.1}loc")]
                check("HTTP Server", "sitemap.xml includes Google image schema for logo.png", any("assets/logo.png" in l for l in image_locs), f"Image locs: {image_locs}")
            except Exception as e:
                check("HTTP Server", "sitemap.xml parses as valid XML", False, str(e))

        # Check 1.5: styles.css GET /styles.css
        req_css = urllib.request.Request(f"{base_url}/styles.css")
        with urllib.request.urlopen(req_css, timeout=5) as res:
            status = res.getcode()
            ctype = res.headers.get_content_type()
            body = res.read().decode("utf-8")
            check("HTTP Server", "styles.css returns HTTP 200", status == 200, f"Status: {status}")
            check("HTTP Server", "styles.css Content-Type is text/css", ctype == "text/css", f"Content-Type: {ctype}")
            check("HTTP Server", "styles.css is non-empty (>10KB)", len(body) > 10000, f"Size: {len(body)}")

        # Check 1.6: app.js GET /app.js
        req_js = urllib.request.Request(f"{base_url}/app.js")
        with urllib.request.urlopen(req_js, timeout=5) as res:
            status = res.getcode()
            ctype = res.headers.get_content_type()
            body = res.read().decode("utf-8")
            check("HTTP Server", "app.js returns HTTP 200", status == 200, f"Status: {status}")
            check("HTTP Server", "app.js Content-Type is javascript", "javascript" in ctype, f"Content-Type: {ctype}")
            check("HTTP Server", "app.js is non-empty (>5KB)", len(body) > 5000, f"Size: {len(body)}")

        # Check 1.7: 404 handling
        try:
            urllib.request.urlopen(f"{base_url}/nonexistent_audit_file.xyz", timeout=5)
            check("HTTP Server", "Nonexistent path returns 404", False, "Expected 404, got 200")
        except urllib.error.HTTPError as e:
            check("HTTP Server", "Nonexistent path returns 404", e.code == 404, f"Got: {e.code}")

    finally:
        server.shutdown()
        server.server_close()

    # =========================================================================
    # SECTION 2: DOM ASSETS & BROKEN LINK STRESS TESTING
    # =========================================================================
    print("\n" + "="*80)
    print("  SECTION 2: LOCAL ASSET INTEGRITY & BROKEN LINK STRESS TEST")
    print("="*80)

    html_text = INDEX_HTML.read_text(encoding="utf-8")
    parser = HTMLTagExtractor()
    parser.feed(html_text)

    # 2.1: Image assets existence
    check("Asset Integrity", "HTML contains <img> tags", len(parser.img_srcs) > 0, f"Found {len(parser.img_srcs)} images")
    for src, alt, pos in parser.img_srcs:
        if not src.startswith(("http://", "https://", "data:")):
            local_path = LANDING_PAGE_DIR / src
            check("Asset Integrity", f"Local image exists on disk: {src} (Line {pos[0]})", local_path.exists(), f"Path: {local_path}")
            if local_path.exists():
                check("Asset Integrity", f"Image {src} has non-zero size", local_path.stat().st_size > 0, f"Size: {local_path.stat().st_size}")
            check("Asset Integrity", f"Image {src} has non-empty alt text", len(alt.strip()) > 0, f"Alt: '{alt}'")

    # 2.2: CSS links existence
    css_links = [(rel, href, pos) for rel, href, pos in parser.link_hrefs if "stylesheet" in rel]
    for rel, href, pos in css_links:
        if not href.startswith(("http://", "https://")):
            local_path = LANDING_PAGE_DIR / href
            check("Asset Integrity", f"Local stylesheet exists: {href} (Line {pos[0]})", local_path.exists(), f"Path: {local_path}")

    # 2.3: Favicon link existence
    icon_links = [(rel, href, pos) for rel, href, pos in parser.link_hrefs if "icon" in rel]
    check("Asset Integrity", "Favicon link is declared", len(icon_links) > 0, f"Icons: {icon_links}")
    for rel, href, pos in icon_links:
        if not href.startswith(("http://", "https://")):
            local_path = LANDING_PAGE_DIR / href
            check("Asset Integrity", f"Favicon file exists: {href} (Line {pos[0]})", local_path.exists(), f"Path: {local_path}")

    # 2.4: Script src tags existence
    for src, pos in parser.script_srcs:
        if not src.startswith(("http://", "https://")):
            local_path = LANDING_PAGE_DIR / src
            check("Asset Integrity", f"Local script exists: {src} (Line {pos[0]})", local_path.exists(), f"Path: {local_path}")

    # 2.5: Internal anchor link validation
    internal_anchors = [(href, pos) for href, _, _, pos in parser.a_hrefs if href.startswith("#") and len(href) > 1]
    check("Anchor Integrity", "Page contains internal anchor navigation links", len(internal_anchors) >= 5, f"Found {len(internal_anchors)} anchors")
    for anchor, pos in internal_anchors:
        target_id = anchor.lstrip("#")
        check("Anchor Integrity", f"Anchor {anchor} targets valid DOM ID '{target_id}' (Line {pos[0]})", target_id in parser.all_ids, f"Target ID '{target_id}' not found in DOM IDs")

    # =========================================================================
    # SECTION 3: JSON-LD SCHEMA PARSING & STRUCTURE VALIDATION
    # =========================================================================
    print("\n" + "="*80)
    print("  SECTION 3: JSON-LD SCHEMA PARSING & VALIDATION")
    print("="*80)

    json_ld_scripts = [content for stype, content in parser.scripts if stype == "application/ld+json"]
    check("JSON-LD Schema", "At least one JSON-LD script block exists", len(json_ld_scripts) >= 1, f"Found: {len(json_ld_scripts)}")

    parsed_schemas = []
    for idx, raw_json in enumerate(json_ld_scripts):
        try:
            data = json.loads(raw_json)
            parsed_schemas.append(data)
            check("JSON-LD Schema", f"JSON-LD block #{idx+1} parses as valid JSON", True)
        except Exception as e:
            check("JSON-LD Schema", f"JSON-LD block #{idx+1} parses as valid JSON", False, str(e))

    # Validate Schema entities
    entities = []
    for s in parsed_schemas:
        if isinstance(s, dict):
            if "@graph" in s and isinstance(s["@graph"], list):
                entities.extend(s["@graph"])
            else:
                entities.append(s)

    types_found = {e.get("@type") for e in entities if isinstance(e, dict)}
    check("JSON-LD Schema", "Schema contains Organization entity", "Organization" in types_found, f"Types: {types_found}")
    check("JSON-LD Schema", "Schema contains SoftwareApplication entity", "SoftwareApplication" in types_found, f"Types: {types_found}")
    check("JSON-LD Schema", "Schema contains WebSite entity", "WebSite" in types_found, f"Types: {types_found}")
    check("JSON-LD Schema", "Schema contains BreadcrumbList entity", "BreadcrumbList" in types_found, f"Types: {types_found}")
    check("JSON-LD Schema", "Schema contains FAQPage entity", "FAQPage" in types_found, f"Types: {types_found}")

    # Validate Organization details
    org = next((e for e in entities if isinstance(e, dict) and e.get("@type") == "Organization"), None)
    if org:
        check("JSON-LD Schema", "Organization schema defines logo pointing to assets/logo.png", "assets/logo.png" in str(org.get("logo", "")), str(org.get("logo")))
        check("JSON-LD Schema", f"Organization schema defines official email {OFFICIAL_EMAIL}", org.get("email") == OFFICIAL_EMAIL, str(org.get("email")))
        check("JSON-LD Schema", "Organization schema defines telephone with country code", "+6285155338246" in str(org.get("telephone", "")), str(org.get("telephone")))

    # Validate SoftwareApplication details
    app_entity = next((e for e in entities if isinstance(e, dict) and e.get("@type") == "SoftwareApplication"), None)
    if app_entity:
        offers = app_entity.get("offers", {}).get("offers", [])
        check("JSON-LD Schema", "SoftwareApplication defines 5 pricing plan offers", len(offers) == 5, f"Offer count: {len(offers)}")
        plan_names = [o.get("name", "") for o in offers]
        for expected_tier in ["Trial", "Starter", "Growth", "Pro", "Enterprise"]:
            check("JSON-LD Schema", f"SoftwareApplication offers include '{expected_tier}' tier", any(expected_tier.lower() in name.lower() for name in plan_names), f"Plans: {plan_names}")

    # Validate FAQPage questions
    faq = next((e for e in entities if isinstance(e, dict) and e.get("@type") == "FAQPage"), None)
    if faq:
        questions = faq.get("mainEntity", [])
        check("JSON-LD Schema", "FAQPage contains >= 4 Q&A items", len(questions) >= 4, f"Count: {len(questions)}")

    # =========================================================================
    # SECTION 4: WHATSAPP URL & MESSAGE DECODING STRESS TEST
    # =========================================================================
    print("\n" + "="*80)
    print("  SECTION 4: WHATSAPP CONSULTATION ENGINE & URL DECODING")
    print("="*80)

    wa_anchors = [(href, cls, aria, pos) for href, cls, aria, pos in parser.a_hrefs if "wa.me" in href]
    check("WhatsApp Engine", "Page contains direct WhatsApp consultation links", len(wa_anchors) >= 4, f"Found {len(wa_anchors)} links")

    for idx, (link, cls, aria, pos) in enumerate(wa_anchors):
        parsed_url = urllib.parse.urlparse(link)
        phone = parsed_url.path.lstrip("/")
        query_params = urllib.parse.parse_qs(parsed_url.query)
        raw_text = query_params.get("text", [""])[0]
        decoded_text = urllib.parse.unquote_plus(raw_text)

        check("WhatsApp Engine", f"WhatsApp Link #{idx+1} routes to official phone 6285155338246 (Line {pos[0]})", phone == CANONICAL_PHONE, f"Phone: {phone}")
        check("WhatsApp Engine", f"WhatsApp Link #{idx+1} has non-empty consultation inquiry message (Line {pos[0]})", len(decoded_text.strip()) > 0, f"Decoded: '{decoded_text}'")
        check("WhatsApp Engine", f"WhatsApp Link #{idx+1} addresses consultant team (Line {pos[0]})", ("Tim Konsultan Mobile ERP" in decoded_text or "Tim Solusi Mobile ERP" in decoded_text), f"Text: '{decoded_text}'")

    # Validate dynamic app.js WhatsApp generation logic
    js_text = APP_JS.read_text(encoding="utf-8")
    check("WhatsApp Engine", "app.js defines CONFIG.CONSULTANT_PHONE with canonical number", "6285155338246" in js_text, "Missing phone config in app.js")
    check("WhatsApp Engine", "app.js generates professional consultation message template", "Halo Tim Konsultan Mobile ERP" in js_text, "Missing message template in app.js")
    check("WhatsApp Engine", "app.js includes Trial plan inquiry support", "Trial" in js_text or "isTrial" in js_text, "Missing trial handling in app.js")
    check("WhatsApp Engine", "app.js includes Enterprise plan inquiry support", "Enterprise" in js_text or "isEnterprise" in js_text, "Missing enterprise handling in app.js")

    # =========================================================================
    # SECTION 5: TERMINOLOGY GOVERNANCE & PROHIBITED TERM AUDIT
    # =========================================================================
    print("\n" + "="*80)
    print("  SECTION 5: TERMINOLOGY GOVERNANCE (ZERO 'OWNER' PHRASING)")
    print("="*80)

    prohibited_pattern = re.compile(r"\b(owner|platform[\s_-]?owner|hubungi[\s_-]?owner|portal[\s_-]?owner)\b", re.IGNORECASE)

    files_to_audit = [
        ("index.html", html_text),
        ("styles.css", STYLES_CSS.read_text(encoding="utf-8")),
        ("app.js", js_text),
        ("robots.txt", ROBOTS_TXT.read_text(encoding="utf-8")),
        ("sitemap.xml", SITEMAP_XML.read_text(encoding="utf-8")),
    ]

    for fname, content in files_to_audit:
        matches = prohibited_pattern.findall(content)
        check("Terminology Audit", f"Zero 'owner' or 'platform owner' terms in {fname}", len(matches) == 0, f"Matches found: {matches}")

    # Check for presence of required enterprise replacement terms
    check("Terminology Audit", "Page uses enterprise term 'Tim Konsultan'", "tim konsultan" in html_text.lower(), "Missing from index.html")
    check("Terminology Audit", "Page uses enterprise term 'Hubungi Tim Spesialis' / 'Tim Spesialis'", "tim spesialis" in html_text.lower(), "Missing from index.html")
    check("Terminology Audit", "Page uses consultation/demo term 'Demo'", "demo" in html_text.lower(), "Missing from index.html")

    # Check official direct contacts
    check("Terminology Audit", f"Human-readable phone {LOCAL_PHONE} displayed in HTML", LOCAL_PHONE in html_text, f"{LOCAL_PHONE} missing from index.html")
    check("Terminology Audit", f"Official email {OFFICIAL_EMAIL} displayed in HTML", OFFICIAL_EMAIL in html_text, f"{OFFICIAL_EMAIL} missing from index.html")
    check("Terminology Audit", f"mailto:{OFFICIAL_EMAIL} link present in HTML", f"mailto:{OFFICIAL_EMAIL}" in html_text, f"mailto:{OFFICIAL_EMAIL} missing")

    # =========================================================================
    # SECTION 6: ENTERPRISE 5-MODULE TAXONOMY & CODEBASE FIDELITY
    # =========================================================================
    print("\n" + "="*80)
    print("  SECTION 6: 5-MODULE ENTERPRISE TAXONOMY (WMS, OMS, FMS, HRIS, EMS)")
    print("="*80)

    modules = [
        ("WMS", "Warehouse Management System", ["Multi-Warehouse", "Barcode", "Reorder Point"]),
        ("OMS", "Omnichannel Management System", ["Shopee", "TikTok", "Sync", "Zero-Oversell"]),
        ("FMS", "Financial Management System", ["Settlement", "Rekonsiliasi", "HPP", "COGS"]),
        ("HRIS", "Human Resource Information System", ["Host Live", "Absensi", "GPS", "Payroll"]),
        ("EMS", "Enterprise Multi-Tenant Security", ["PostgreSQL", "RLS", "Row-Level Security", "Isolasi"]),
    ]

    for code, full_name, keywords in modules:
        check("Module Taxonomy", f"Module {code} ({full_name}) is present in features", code in html_text, f"Code {code} not found")
        for kw in keywords:
            check("Module Taxonomy", f"Module {code} mentions technical feature '{kw}'", kw.lower() in html_text.lower(), f"Keyword '{kw}' not found in HTML")

    # =========================================================================
    # SUMMARY & DIAGNOSTICS
    # =========================================================================
    print("\n" + "="*80)
    print("  CHALLENGER 1 EMPIRICAL TEST SUMMARY")
    print("="*80)
    print(f"  Total Empirical Checks : {report['total_checks']}")
    print(f"  Passed Checks          : {report['passed_checks']}")
    print(f"  Failed Checks          : {report['failed_checks']}")
    print(f"  Final Verdict          : {report['verdict']}")
    print("="*80 + "\n")

    return report


if __name__ == "__main__":
    rep = run_empirical_challenger_tests()
    if rep["failed_checks"] > 0:
        print("FAILURES DETECTED:")
        for f in rep["failures"]:
            print(" -", f)
        sys.exit(1)
    else:
        print("ALL EMPIRICAL CHALLENGER TESTS PASSED.")
        sys.exit(0)
