import os
import re
import sys
import json
import struct
import urllib.parse
import xml.etree.ElementTree as ET

def log_check(name, passed, details=""):
    status = "PASS" if passed else "FAIL"
    print(f"[{status}] {name}: {details}")
    return passed

def main():
    print("=" * 70)
    print("STARTING FORENSIC INTEGRITY AUDIT - MOBILE ERP LANDING PAGE")
    print("=" * 70)
    
    root_dir = os.path.abspath("landing_page")
    all_passed = True

    # -------------------------------------------------------------
    # Check 1: Static Analysis & Prohibited Terms
    # -------------------------------------------------------------
    print("\n--- Phase 1: Static Analysis & Prohibited Terms ---")
    prohibited_terms = [
        r"\bowner\b",
        r"\bplatform owner\b",
        r"\btodo\b",
        r"\blorem\b",
        r"\bipsum\b",
        r"\bfixme\b",
        r"\bplaceholder\b"
    ]
    
    scanned_files = []
    found_violations = []
    for root, dirs, files in os.walk(root_dir):
        for f in files:
            if f.endswith(('.html', '.css', '.js', '.txt', '.xml')):
                file_path = os.path.join(root, f)
                scanned_files.append(file_path)
                with open(file_path, 'r', encoding='utf-8', errors='ignore') as fh:
                    content = fh.read()
                    lines = content.splitlines()
                    for line_idx, line in enumerate(lines, 1):
                        for term in prohibited_terms:
                            if re.search(term, line, re.IGNORECASE):
                                # Exception: none permitted
                                found_violations.append((file_path, line_idx, term, line.strip()))

    passed = len(found_violations) == 0
    all_passed &= log_check(
        "Static Prohibited Terms Scan",
        passed,
        f"Scanned {len(scanned_files)} files. Found {len(found_violations)} prohibited occurrences."
    )
    if found_violations:
        for f, l, term, line in found_violations:
            print(f"   Violation in {f}:{l} matching '{term}': {line}")

    # -------------------------------------------------------------
    # Check 2: Asset Verification (assets/logo.png)
    # -------------------------------------------------------------
    print("\n--- Phase 2: Asset Verification (assets/logo.png) ---")
    logo_path = os.path.join(root_dir, "assets", "logo.png")
    logo_exists = os.path.exists(logo_path)
    all_passed &= log_check("Logo Exists", logo_exists, logo_path)
    
    if logo_exists:
        with open(logo_path, "rb") as f:
            header = f.read(8)
            valid_header = (header == b"\x89PNG\r\n\x1a\n")
            all_passed &= log_check("PNG Magic Bytes Signature", valid_header, f"Header: {header}")
            
            ihdr_len = struct.unpack(">I", f.read(4))[0]
            ihdr_type = f.read(4)
            valid_ihdr = (ihdr_type == b"IHDR")
            all_passed &= log_check("IHDR Chunk", valid_ihdr, f"Chunk Type: {ihdr_type}")
            
            w, h, bit_depth, color_type, comp, filt, interlace = struct.unpack(">IIBBBBB", f.read(13))
            is_332x332 = (w == 332 and h == 332)
            all_passed &= log_check("Logo Dimensions (332x332)", is_332x332, f"{w}x{h} px")
            
            is_32bit_rgba = (bit_depth == 8 and color_type == 6)
            all_passed &= log_check("Logo Color Depth (32-bit ARGB/RGBA)", is_32bit_rgba, f"BitDepth: {bit_depth}, ColorType: {color_type}")

    # Check asset usages in HTML
    html_path = os.path.join(root_dir, "index.html")
    with open(html_path, "r", encoding="utf-8") as f:
        html_content = f.read()

    favicon_present = '<link rel="icon" type="image/png" sizes="32x32" href="assets/logo.png">' in html_content
    all_passed &= log_check("Favicon Link Integration", favicon_present, "sizes=32x32")

    og_image_present = 'https://mdhproduction.com/assets/logo.png' in html_content
    all_passed &= log_check("OG & Twitter Image Integration", og_image_present, "mdhproduction.com/assets/logo.png")

    navbar_logo_present = '<img src="assets/logo.png"' in html_content and 'class="brand-logo-img"' in html_content
    all_passed &= log_check("Navbar Brand Logo Integration", navbar_logo_present, "class='brand-logo-img'")

    # -------------------------------------------------------------
    # Check 3: Schema & SEO Audit
    # -------------------------------------------------------------
    print("\n--- Phase 3: Schema & SEO Audit ---")
    schema_match = re.search(r'<script type="application/ld\+json">([\s\S]*?)</script>', html_content)
    schema_valid = False
    if schema_match:
        try:
            schema_data = json.loads(schema_match.group(1).strip())
            schema_valid = True
            all_passed &= log_check("JSON-LD Schema Valid JSON", True, "Successfully parsed")
            
            graph = schema_data.get("@graph", [])
            types = [item.get("@type") for item in graph]
            expected_types = ["Organization", "SoftwareApplication", "WebSite", "BreadcrumbList", "FAQPage"]
            has_all_types = all(t in types for t in expected_types)
            all_passed &= log_check("JSON-LD 5-Schema Coverage", has_all_types, f"Types found: {types}")
            
            # Check Organization details
            org = next((x for x in graph if x.get("@type") == "Organization"), {})
            org_ok = (org.get("email") == "bdchydi@sre.co.id" and org.get("telephone") == "+6285155338246")
            all_passed &= log_check("Organization Contact in Schema", org_ok, f"Tel: {org.get('telephone')}, Email: {org.get('email')}")
            
            # Check FAQPage
            faq = next((x for x in graph if x.get("@type") == "FAQPage"), {})
            faq_count = len(faq.get("mainEntity", []))
            all_passed &= log_check("FAQPage Schema Items", faq_count >= 5, f"{faq_count} questions defined")
            
        except Exception as e:
            all_passed &= log_check("JSON-LD Schema Valid JSON", False, str(e))
    else:
        all_passed &= log_check("JSON-LD Schema Tag", False, "Missing ld+json script tag")

    # Check robots.txt
    robots_path = os.path.join(root_dir, "robots.txt")
    with open(robots_path, "r", encoding="utf-8") as f:
        robots_txt = f.read()
    robots_ok = "Googlebot" in robots_txt and "sitemap.xml" in robots_txt and "Allow: /assets/" in robots_txt
    all_passed &= log_check("robots.txt Directives", robots_ok, "Googlebot, Allow assets, sitemap declared")

    # Check sitemap.xml
    sitemap_path = os.path.join(root_dir, "sitemap.xml")
    try:
        tree = ET.parse(sitemap_path)
        root_elem = tree.getroot()
        urls = [elem.text for elem in root_elem.iter('{http://www.sitemaps.org/schemas/sitemap/0.9}loc')]
        sitemap_ok = "https://mdhproduction.com/" in urls and "https://app.mdhproduction.com/" in urls
        all_passed &= log_check("sitemap.xml Structure & URLs", sitemap_ok, f"Found {len(urls)} URLs: {urls}")
    except Exception as e:
        all_passed &= log_check("sitemap.xml Structure & URLs", False, str(e))

    # -------------------------------------------------------------
    # Check 4: Contact & Consultation Engine Audit
    # -------------------------------------------------------------
    print("\n--- Phase 4: Contact & Consultation Engine Audit ---")
    phone_raw = "085155338246"
    phone_intl = "6285155338246"
    email_canonical = "bdchydi@sre.co.id"
    
    phone_ok = (phone_raw in html_content) and (phone_intl in html_content)
    all_passed &= log_check("Canonical Phone Verification", phone_ok, f"085155338246 / +6285155338246")
    
    email_ok = (email_canonical in html_content) and (f"mailto:{email_canonical}" in html_content)
    all_passed &= log_check("Canonical Email Verification", email_ok, f"mailto:{email_canonical}")

    # Check WhatsApp links in Pricing Matrix
    pricing_tiers = ["Trial", "Starter", "Growth", "Pro", "Enterprise"]
    tier_links_found = 0
    for tier in pricing_tiers:
        expected_substr = urllib.parse.quote(f"paket {tier}")
        if expected_substr in html_content or tier in html_content:
            tier_links_found += 1
    all_passed &= log_check("Pricing Matrix WhatsApp Triggers", tier_links_found == len(pricing_tiers), f"{tier_links_found}/{len(pricing_tiers)} tiers configured")

    # -------------------------------------------------------------
    # Check 5: Codebase Fidelity (lib/features/ & Schema mapping)
    # -------------------------------------------------------------
    print("\n--- Phase 5: Codebase Fidelity Audit ---")
    lib_features_dir = os.path.abspath("lib/features")
    expected_modules = {
        "WMS (Warehouse Management)": ["stock"],
        "OMS (Omnichannel Management)": ["marketplace"],
        "FMS (Financial Management)": ["finance"],
        "HRIS (Live Host & HR)": ["host_live", "attendance", "hr"],
        "EMS (Security & RLS)": ["app_roles.dart", "auth"]
    }
    
    for mod_name, indicators in expected_modules.items():
        found = False
        for ind in indicators:
            if os.path.exists(os.path.join(lib_features_dir, ind)) or \
               os.path.exists(os.path.join("lib/core/auth", ind)) or \
               os.path.exists(os.path.join("lib/core/constants", ind)) or \
               os.path.exists(os.path.join("lib/core", ind)):
                found = True
                break
        all_passed &= log_check(f"Codebase Anchor: {mod_name}", found, f"Indicators: {indicators}")

    # Check table names & terminology in index.html matching real schema
    real_db_tables = ["work_locations", "products", "stock_movements", "marketplace_orders", "marketplace_finance_settlement", "live_shifts", "attendance_logs"]
    tables_referenced = sum(1 for tbl in real_db_tables if tbl in html_content or tbl.replace("_", " ") in html_content.lower())
    all_passed &= log_check("Real Database Schema Alignment", tables_referenced >= 5, f"{tables_referenced}/{len(real_db_tables)} schema concepts present")

    print("\n" + "=" * 70)
    print(f"OVERALL FORENSIC VERDICT: {'CLEAN' if all_passed else 'INTEGRITY VIOLATION'}")
    print("=" * 70)
    return 0 if all_passed else 1

if __name__ == "__main__":
    sys.exit(main())
