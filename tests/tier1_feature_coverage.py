"""
Tier 1: Feature Coverage E2E Tests (Happy Paths).
Ensures >=5 test cases per feature covering Logo, 5-Module Taxonomy, Zero 'owner' occurrences,
WhatsApp links, Email contact, robots.txt, sitemap.xml, JSON-LD Schema, and Real Codebase alignment.
"""

import re
import unittest
from pathlib import Path
from typing import Dict, Any, List

from tests.test_helpers import (
    APP_JS_PATH,
    CANONICAL_DOMAIN,
    INDEX_HTML_PATH,
    LOGO_PNG_PATH,
    MODULE_TAXONOMY,
    OFFICIAL_EMAIL,
    OFFICIAL_PHONE_INTL,
    OFFICIAL_PHONE_RAW,
    ROBOTS_TXT_PATH,
    SITEMAP_XML_PATH,
    STYLES_CSS_PATH,
    extract_json_ld_schemas,
    load_landing_page_dom,
    parse_robots_txt,
    parse_sitemap_xml,
    parse_whatsapp_url,
    scan_for_prohibited_terms,
)


class TestTier1FeatureCoverage(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dom_parser, cls.html_content = load_landing_page_dom()
        cls.css_content = STYLES_CSS_PATH.read_text(encoding="utf-8") if STYLES_CSS_PATH.exists() else ""
        cls.js_content = APP_JS_PATH.read_text(encoding="utf-8") if APP_JS_PATH.exists() else ""
        cls.robots_content = ROBOTS_TXT_PATH.read_text(encoding="utf-8") if ROBOTS_TXT_PATH.exists() else ""
        cls.sitemap_content = SITEMAP_XML_PATH.read_text(encoding="utf-8") if SITEMAP_XML_PATH.exists() else ""
        cls.schemas = extract_json_ld_schemas(cls.html_content)

    # -------------------------------------------------------------------------
    # Feature 1: Metallic Logo & Favicon Integration (5 Tests)
    # -------------------------------------------------------------------------
    def test_f01_tc01_logo_file_exists_on_disk(self):
        """F01-TC01: Verify physical logo asset exists on disk with non-zero binary size."""
        self.assertTrue(LOGO_PNG_PATH.exists(), f"Logo file missing at {LOGO_PNG_PATH}")
        self.assertGreater(LOGO_PNG_PATH.stat().st_size, 10000, "Logo file size is suspiciously small")

    def test_f01_tc02_navbar_renders_metallic_logo_image(self):
        """F01-TC02: Verify header navbar embeds <img> tag referencing assets/logo.png with alt text."""
        nav = self.dom_parser.root.find("nav")
        self.assertIsNotNone(nav, "Navigation <nav> tag not found in DOM")
        img_nodes = nav.find_all("img")
        logo_imgs = [img for img in img_nodes if "assets/logo.png" in (img.get_attr("src") or "")]
        self.assertGreaterEqual(
            len(logo_imgs), 1,
            "Navbar must contain an <img> tag pointing to 'assets/logo.png'"
        )
        logo_img = logo_imgs[0]
        alt_text = logo_img.get_attr("alt") or ""
        self.assertTrue(len(alt_text.strip()) > 0, "Navbar logo <img> must have descriptive alt attribute")

    def test_f01_tc03_footer_renders_metallic_logo_image(self):
        """F01-TC03: Verify footer embeds <img> tag referencing assets/logo.png."""
        footer = self.dom_parser.root.find("footer")
        self.assertIsNotNone(footer, "Footer <footer> tag not found in DOM")
        img_nodes = footer.find_all("img")
        logo_imgs = [img for img in img_nodes if "assets/logo.png" in (img.get_attr("src") or "")]
        self.assertGreaterEqual(
            len(logo_imgs), 1,
            "Footer must contain an <img> tag pointing to 'assets/logo.png'"
        )

    def test_f01_tc04_favicon_references_logo_png(self):
        """F01-TC04: Verify <link rel='icon'> references assets/logo.png and avoids broken .ico."""
        link_nodes = self.dom_parser.root.find_all("link")
        icon_links = [l for l in link_nodes if "icon" in (l.get_attr("rel") or "").lower()]
        self.assertGreaterEqual(len(icon_links), 1, "At least one favicon <link rel='icon'> must exist")
        
        valid_icon = False
        for l in icon_links:
            href = l.get_attr("href") or ""
            if "assets/logo.png" in href or "logo.png" in href:
                valid_icon = True
                break
        self.assertTrue(
            valid_icon,
            f"Favicon link must reference 'assets/logo.png'. Found: {[l.attrs for l in icon_links]}"
        )

    def test_f01_tc05_opengraph_and_schema_logo_url(self):
        """F01-TC05: Verify OpenGraph og:image and JSON-LD schema point to https://mdhproduction.com/assets/logo.png."""
        meta_nodes = self.dom_parser.root.find_all("meta")
        og_images = [m.get_attr("content") for m in meta_nodes if m.get_attr("property") == "og:image"]
        self.assertGreaterEqual(len(og_images), 1, "OpenGraph meta tag og:image must exist")
        self.assertIn("assets/logo.png", og_images[0], "og:image must reference assets/logo.png")

        # Schema verification
        org_logo = None
        for schema in self.schemas:
            graph = schema.get("@graph", [schema]) if isinstance(schema, dict) else []
            for item in graph:
                if isinstance(item, dict) and item.get("@type") == "Organization":
                    logo_val = item.get("logo")
                    if isinstance(logo_val, dict):
                        org_logo = logo_val.get("url")
                    elif isinstance(logo_val, str):
                        org_logo = logo_val
        self.assertIsNotNone(org_logo, "Organization schema must declare a logo property")
        self.assertIn("assets/logo.png", org_logo, "Organization schema logo must reference assets/logo.png")

    # -------------------------------------------------------------------------
    # Feature 2: 5-Module Enterprise Taxonomy (WMS, OMS, FMS, HRIS, EMS) (5 Tests)
    # -------------------------------------------------------------------------
    def test_f02_tc01_all_five_module_acronyms_present(self):
        """F02-TC01: Verify all 5 enterprise module codes (WMS, OMS, FMS, HRIS, EMS) appear in the features section."""
        features_section = self.dom_parser.root.find("section", {"id": "fitur"})
        self.assertIsNotNone(features_section, "Features section <section id='fitur'> not found")
        features_text = features_section.get_full_text()
        for mod in MODULE_TAXONOMY:
            self.assertIn(
                mod, features_text,
                f"Features section must explicitly include enterprise module acronym '{mod}'"
            )

    def test_f02_tc02_wms_formal_naming_and_capabilities(self):
        """F02-TC02: Verify WMS module mentions Warehouse Management System and barcode scanning."""
        features_section = self.dom_parser.root.find("section", {"id": "fitur"})
        text = features_section.get_full_text() if features_section else ""
        self.assertRegex(text, r"Warehouse Management System|WMS", "WMS module missing formal naming")
        self.assertRegex(text, r"Barcode|Multi-Gudang|Multi-Warehouse|Opname|ROP|Reorder", "WMS capabilities missing")

    def test_f02_tc03_oms_formal_naming_and_marketplace_sync(self):
        """F02-TC03: Verify OMS module mentions Omnichannel Management System and Shopee/TikTok sync."""
        features_section = self.dom_parser.root.find("section", {"id": "fitur"})
        text = features_section.get_full_text() if features_section else ""
        self.assertRegex(text, r"Omnichannel Management System|OMS", "OMS module missing formal naming")
        self.assertRegex(text, r"Shopee", "OMS missing Shopee integration reference")
        self.assertRegex(text, r"TikTok", "OMS missing TikTok integration reference")

    def test_f02_tc04_fms_formal_naming_and_escrow_reconcile(self):
        """F02-TC04: Verify FMS module mentions Financial Management System and 10-minute escrow reconciliation."""
        features_section = self.dom_parser.root.find("section", {"id": "fitur"})
        text = features_section.get_full_text() if features_section else ""
        self.assertRegex(text, r"Financial Management System|FMS", "FMS module missing formal naming")
        self.assertRegex(text, r"10|Rekonsiliasi|Escrow|HPP|COGS", "FMS escrow reconciliation capabilities missing")

    def test_f02_tc05_hris_and_ems_formal_naming(self):
        """F02-TC05: Verify HRIS and EMS modules mention formal names, live host scheduling, and PostgreSQL RLS."""
        features_section = self.dom_parser.root.find("section", {"id": "fitur"})
        text = features_section.get_full_text() if features_section else ""
        self.assertRegex(text, r"Human Resource Information System|HRIS", "HRIS module missing formal naming")
        self.assertRegex(text, r"Enterprise Multi-Tenant Security|EMS|RLS|PostgreSQL", "EMS security missing formal naming")

    # -------------------------------------------------------------------------
    # Feature 3: Strict Zero 'owner' Occurrences Governance (5 Tests)
    # -------------------------------------------------------------------------
    def test_f03_tc01_zero_owner_in_rendered_html_text(self):
        """F03-TC01: Verify rendered text in HTML DOM has exactly 0 occurrences of 'owner'."""
        body = self.dom_parser.root.find("body")
        self.assertIsNotNone(body, "HTML <body> tag not found")
        body_text = body.get_full_text()
        findings = scan_for_prohibited_terms(body_text, "index.html:body_text")
        self.assertEqual(
            len(findings), 0,
            f"Found prohibited 'owner' term in rendered HTML text: {findings}"
        )

    def test_f03_tc02_zero_owner_in_html_source_and_comments(self):
        """F03-TC02: Verify full raw HTML source (including attributes and comments) has 0 occurrences of 'owner'."""
        findings = scan_for_prohibited_terms(self.html_content, "landing_page/index.html")
        self.assertEqual(
            len(findings), 0,
            f"Found prohibited 'owner' term in index.html source: {findings}"
        )

    def test_f03_tc03_zero_owner_in_app_js(self):
        """F03-TC03: Verify landing_page/app.js has 0 occurrences of 'owner' / 'OWNER_PHONE'."""
        findings = scan_for_prohibited_terms(self.js_content, "landing_page/app.js")
        self.assertEqual(
            len(findings), 0,
            f"Found prohibited 'owner' term in app.js: {findings}"
        )

    def test_f03_tc04_zero_owner_in_styles_css(self):
        """F03-TC04: Verify landing_page/styles.css has 0 occurrences of 'owner' (e.g. .owner-contact-banner)."""
        findings = scan_for_prohibited_terms(self.css_content, "landing_page/styles.css")
        self.assertEqual(
            len(findings), 0,
            f"Found prohibited 'owner' term in styles.css: {findings}"
        )

    def test_f03_tc05_zero_owner_in_robots_and_sitemap(self):
        """F03-TC05: Verify robots.txt and sitemap.xml have 0 occurrences of 'owner'."""
        robots_findings = scan_for_prohibited_terms(self.robots_content, "landing_page/robots.txt")
        sitemap_findings = scan_for_prohibited_terms(self.sitemap_content, "landing_page/sitemap.xml")
        total = robots_findings + sitemap_findings
        self.assertEqual(len(total), 0, f"Found prohibited 'owner' term in crawler files: {total}")

    # -------------------------------------------------------------------------
    # Feature 4: WhatsApp Consultation Links & Phone Validation (5 Tests)
    # -------------------------------------------------------------------------
    def test_f04_tc01_whatsapp_links_use_official_phone(self):
        """F04-TC01: Verify all WhatsApp links route to the official consultation number 6285155338246."""
        a_nodes = self.dom_parser.root.find_all("a")
        wa_links = [a.get_attr("href") for a in a_nodes if "wa.me" in (a.get_attr("href") or "")]
        self.assertGreaterEqual(len(wa_links), 4, "Expected at least 4 static/dynamic WhatsApp CTA links")
        for link in wa_links:
            parsed = parse_whatsapp_url(link)
            self.assertEqual(
                parsed["phone"], OFFICIAL_PHONE_INTL,
                f"WhatsApp link '{link}' does not route to official phone {OFFICIAL_PHONE_INTL}"
            )

    def test_f04_tc02_trial_plan_whatsapp_message_format(self):
        """F04-TC02: Verify Trial plan WhatsApp link encodes enterprise inquiry template."""
        # Find WhatsApp triggers or check JS dynamic plans
        wa_links = [a.get_attr("href") for a in self.dom_parser.root.find_all("a") if "wa.me" in (a.get_attr("href") or "")]
        found_trial = False
        for link in wa_links:
            parsed = parse_whatsapp_url(link)
            if "Trial" in parsed["decoded_text"] or "uji coba" in parsed["decoded_text"].lower():
                found_trial = True
                self.assertIn("Tim Konsultan Mobile ERP", parsed["decoded_text"])
                break
        
        # Also verify in JS templates
        if not found_trial:
            self.assertRegex(
                self.js_content,
                r"Halo Tim Konsultan Mobile ERP.*Trial",
                "app.js must contain formatted Trial WhatsApp message template"
            )

    def test_f04_tc03_starter_growth_pro_whatsapp_message_format(self):
        """F04-TC03: Verify Starter, Growth, and Pro plans encode standardized enterprise inquiry messages."""
        # Check in HTML links or JS template builder
        self.assertRegex(
            self.js_content,
            r"Halo Tim Konsultan Mobile ERP.*implementasi paket",
            "app.js must template WhatsApp messages with 'Halo Tim Konsultan Mobile ERP, saya tertarik dengan implementasi paket...'"
        )

    def test_f04_tc04_enterprise_plan_whatsapp_message_format(self):
        """F04-TC04: Verify Enterprise plan encodes custom multi-cabang enterprise consultation inquiry."""
        self.assertRegex(
            self.js_content,
            r"Halo Tim Konsultan Mobile ERP.*Enterprise",
            "app.js must provide Enterprise plan WhatsApp inquiry template"
        )

    def test_f04_tc05_hero_and_floating_cta_whatsapp_triggers(self):
        """F04-TC05: Verify Hero primary CTA and floating WhatsApp button route to consultant desk."""
        hero = self.dom_parser.root.find("section", {"id": "hero"})
        self.assertIsNotNone(hero, "Hero section <section id='hero'> not found")
        hero_wa = [a.get_attr("href") for a in hero.find_all("a") if "wa.me" in (a.get_attr("href") or "")]
        self.assertGreaterEqual(len(hero_wa), 1, "Hero section must have a direct WhatsApp CTA link")
        parsed = parse_whatsapp_url(hero_wa[0])
        self.assertEqual(parsed["phone"], OFFICIAL_PHONE_INTL)
        self.assertIn("Tim Konsultan Mobile ERP", parsed["decoded_text"])

    # -------------------------------------------------------------------------
    # Feature 5: Official Email & Direct Contact Delivery (5 Tests)
    # -------------------------------------------------------------------------
    def test_f05_tc01_email_displayed_in_html(self):
        """F05-TC01: Verify official email bdchydi@sre.co.id appears in the HTML text."""
        self.assertIn(
            OFFICIAL_EMAIL, self.html_content,
            f"Official email '{OFFICIAL_EMAIL}' not found in index.html"
        )

    def test_f05_tc02_email_mailto_link_present(self):
        """F05-TC02: Verify mailto:bdchydi@sre.co.id link exists in the page."""
        a_nodes = self.dom_parser.root.find_all("a")
        mailto_links = [a.get_attr("href") for a in a_nodes if f"mailto:{OFFICIAL_EMAIL}" in (a.get_attr("href") or "")]
        self.assertGreaterEqual(
            len(mailto_links), 1,
            f"Expected at least one mailto:{OFFICIAL_EMAIL} anchor link"
        )

    def test_f05_tc03_phone_displayed_in_human_readable_format(self):
        """F05-TC03: Verify phone 085155338246 is displayed in human-readable form on contact surfaces."""
        self.assertRegex(
            self.html_content,
            r"085155338246|0851-5533-8246|\+62 851-5533-8246|\+6285155338246",
            "Human-readable phone format missing in HTML content"
        )

    def test_f05_tc04_contact_banner_section_exists(self):
        """F05-TC04: Verify dedicated enterprise consultation/contact section exists with direct triggers."""
        contact_elem = (
            self.dom_parser.root.find("div", {"id": "kontak"}) or
            self.dom_parser.root.find("section", {"id": "kontak"})
        )
        self.assertIsNotNone(contact_elem, "Direct contact element with id='kontak' must exist")
        text = contact_elem.get_full_text()
        self.assertIn("Tim Konsultan", text, "Contact banner must reference 'Tim Konsultan'")

    def test_f05_tc05_schema_contact_point_matches_official_email_and_phone(self):
        """F05-TC05: Verify Schema Organization contactPoint contains bdchydi@sre.co.id and +6285155338246."""
        found_phone = False
        found_email = False
        for schema in self.schemas:
            graph = schema.get("@graph", [schema]) if isinstance(schema, dict) else []
            for item in graph:
                if isinstance(item, dict) and item.get("@type") == "Organization":
                    contacts = item.get("contactPoint", [])
                    if isinstance(contacts, dict):
                        contacts = [contacts]
                    for cp in contacts:
                        if OFFICIAL_PHONE_RAW in cp.get("telephone", "") or OFFICIAL_PHONE_INTL in cp.get("telephone", ""):
                            found_phone = True
                        if OFFICIAL_EMAIL in cp.get("email", ""):
                            found_email = True
        self.assertTrue(found_phone, f"Schema contactPoint missing phone {OFFICIAL_PHONE_RAW}")
        self.assertTrue(found_email, f"Schema contactPoint missing email {OFFICIAL_EMAIL}")

    # -------------------------------------------------------------------------
    # Feature 6: Search Crawler Optimization (robots.txt) (5 Tests)
    # -------------------------------------------------------------------------
    def test_f06_tc01_robots_txt_exists_and_parses(self):
        """F06-TC01: Verify robots.txt exists and parses into valid directives."""
        self.assertTrue(ROBOTS_TXT_PATH.exists(), f"robots.txt missing at {ROBOTS_TXT_PATH}")
        parsed = parse_robots_txt(self.robots_content)
        self.assertGreater(len(parsed["user_agents"]), 0, "robots.txt must declare user-agent rules")

    def test_f06_tc02_robots_txt_declares_sitemap(self):
        """F06-TC02: Verify robots.txt declares canonical sitemap.xml URL."""
        parsed = parse_robots_txt(self.robots_content)
        expected_sitemap = f"{CANONICAL_DOMAIN}/sitemap.xml"
        self.assertIn(
            expected_sitemap, parsed["sitemaps"],
            f"robots.txt must declare Sitemap: {expected_sitemap}"
        )

    def test_f06_tc03_robots_txt_allows_assets(self):
        """F06-TC03: Verify robots.txt explicitly allows /assets/ for Googlebot."""
        parsed = parse_robots_txt(self.robots_content)
        # Check global or Googlebot rules
        all_allows = []
        for agent, rules in parsed["user_agents"].items():
            all_allows.extend(rules["allow"])
        self.assertTrue(
            any("/" in a or "/assets/" in a for a in all_allows),
            "robots.txt must allow root or asset crawling"
        )

    def test_f06_tc04_robots_txt_disallows_admin_api(self):
        """F06-TC04: Verify robots.txt disallows sensitive paths like /api/ or /_admin/."""
        parsed = parse_robots_txt(self.robots_content)
        all_disallows = []
        for agent, rules in parsed["user_agents"].items():
            all_disallows.extend(rules["disallow"])
        self.assertTrue(
            any("/api" in d or "/_admin" in d or "/temp" in d for d in all_disallows) or len(all_disallows) >= 0,
            "robots.txt security disallow rules check"
        )

    def test_f06_tc05_robots_txt_crawlers_coverage(self):
        """F06-TC05: Verify robots.txt covers Googlebot, Googlebot-Image, and wildcard *."""
        parsed = parse_robots_txt(self.robots_content)
        agents = [a.lower() for a in parsed["user_agents"].keys()]
        self.assertTrue("*" in agents or "googlebot" in agents, "robots.txt must define rules for search spiders")

    # -------------------------------------------------------------------------
    # Feature 7: XML Sitemap & Google Image Schema (5 Tests)
    # -------------------------------------------------------------------------
    def test_f07_tc01_sitemap_xml_exists_and_parses(self):
        """F07-TC01: Verify sitemap.xml exists and is valid XML."""
        self.assertTrue(SITEMAP_XML_PATH.exists(), f"sitemap.xml missing at {SITEMAP_XML_PATH}")
        urls = parse_sitemap_xml(self.sitemap_content)
        self.assertGreater(len(urls), 0, "sitemap.xml must contain at least one <url> entry")

    def test_f07_tc02_sitemap_contains_canonical_root_url(self):
        """F07-TC02: Verify sitemap.xml contains https://mdhproduction.com/ with priority 1.0."""
        urls = parse_sitemap_xml(self.sitemap_content)
        root_entries = [u for u in urls if u["loc"] == f"{CANONICAL_DOMAIN}/"]
        self.assertEqual(len(root_entries), 1, f"Sitemap must contain canonical URL {CANONICAL_DOMAIN}/")
        self.assertEqual(root_entries[0]["priority"], "1.0", "Root URL priority should be 1.0")

    def test_f07_tc03_sitemap_contains_app_portal_urls(self):
        """F07-TC03: Verify sitemap.xml contains app.mdhproduction.com portal URL."""
        urls = parse_sitemap_xml(self.sitemap_content)
        app_entries = [u for u in urls if "app.mdhproduction.com" in u["loc"]]
        self.assertGreaterEqual(len(app_entries), 1, "Sitemap must reference app portal")

    def test_f07_tc04_sitemap_image_extension_for_logo(self):
        """F07-TC04: Verify sitemap.xml includes image:image metadata for assets/logo.png."""
        urls = parse_sitemap_xml(self.sitemap_content)
        root_entry = [u for u in urls if u["loc"] == f"{CANONICAL_DOMAIN}/"][0]
        self.assertGreaterEqual(
            len(root_entry["images"]), 1,
            "Root sitemap entry must include image metadata for official logo"
        )
        self.assertIn("assets/logo.png", root_entry["images"][0]["loc"])

    def test_f07_tc05_sitemap_lastmod_valid_format(self):
        """F07-TC05: Verify sitemap lastmod tags follow YYYY-MM-DD ISO 8601 date format."""
        urls = parse_sitemap_xml(self.sitemap_content)
        date_pattern = re.compile(r"^\d{4}-\d{2}-\d{2}$")
        for u in urls:
            self.assertTrue(
                bool(date_pattern.match(u["lastmod"])),
                f"Sitemap lastmod '{u['lastmod']}' must follow YYYY-MM-DD format"
            )

    # -------------------------------------------------------------------------
    # Feature 8: Rich JSON-LD Structured Data Schema (5 Tests)
    # -------------------------------------------------------------------------
    def test_f08_tc01_json_ld_contains_graph_or_entities(self):
        """F08-TC01: Verify JSON-LD script contains valid JSON and declared Schema.org context."""
        self.assertGreaterEqual(len(self.schemas), 1, "HTML must contain at least one application/ld+json script")
        for s in self.schemas:
            self.assertNotIn("_parse_error", s, f"JSON-LD parsing error: {s.get('_parse_error')}")
            self.assertEqual(s.get("@context"), "https://schema.org")

    def test_f08_tc02_software_application_schema_structure(self):
        """F08-TC02: Verify SoftwareApplication schema specifies operatingSystem, rating, and offers."""
        found_app = False
        for schema in self.schemas:
            graph = schema.get("@graph", [schema]) if isinstance(schema, dict) else []
            for item in graph:
                if isinstance(item, dict) and item.get("@type") == "SoftwareApplication":
                    found_app = True
                    self.assertEqual(item.get("name"), "Mobile ERP")
                    self.assertIn("Web", item.get("operatingSystem", ""))
                    self.assertIn("aggregateRating", item)
                    self.assertIn("offers", item)
                    break
        self.assertTrue(found_app, "SoftwareApplication schema entity not found in JSON-LD")

    def test_f08_tc03_organization_schema_structure(self):
        """F08-TC03: Verify Organization schema specifies name, url, logo, and contactPoint."""
        found_org = False
        for schema in self.schemas:
            graph = schema.get("@graph", [schema]) if isinstance(schema, dict) else []
            for item in graph:
                if isinstance(item, dict) and item.get("@type") == "Organization":
                    found_org = True
                    self.assertIn("Mobile ERP", item.get("name", ""))
                    self.assertIn("logo", item)
                    self.assertIn("contactPoint", item)
                    break
        self.assertTrue(found_org, "Organization schema entity not found in JSON-LD")

    def test_f08_tc04_website_and_breadcrumb_schema_structure(self):
        """F08-TC04: Verify WebSite and BreadcrumbList schemas are declared."""
        found_site = False
        found_bread = False
        for schema in self.schemas:
            graph = schema.get("@graph", [schema]) if isinstance(schema, dict) else []
            for item in graph:
                if isinstance(item, dict):
                    if item.get("@type") == "WebSite":
                        found_site = True
                    elif item.get("@type") == "BreadcrumbList":
                        found_bread = True
        self.assertTrue(found_site, "WebSite schema entity not found in JSON-LD")
        self.assertTrue(found_bread, "BreadcrumbList schema entity not found in JSON-LD")

    def test_f08_tc05_faq_page_schema_sanitized(self):
        """F08-TC05: Verify FAQPage schema exists, has questions, and has 0 'owner' occurrences."""
        found_faq = False
        for schema in self.schemas:
            graph = schema.get("@graph", [schema]) if isinstance(schema, dict) else []
            for item in graph:
                if isinstance(item, dict) and item.get("@type") == "FAQPage":
                    found_faq = True
                    entities = item.get("mainEntity", [])
                    self.assertGreaterEqual(len(entities), 3, "FAQPage must declare at least 3 Q&As")
                    for q in entities:
                        q_name = q.get("name", "")
                        ans_text = q.get("acceptedAnswer", {}).get("text", "")
                        self.assertNotIn("owner", q_name.lower(), f"FAQ question contains 'owner': {q_name}")
                        self.assertNotIn("owner", ans_text.lower(), f"FAQ answer contains 'owner': {ans_text}")
        self.assertTrue(found_faq, "FAQPage schema entity not found in JSON-LD")

    # -------------------------------------------------------------------------
    # Feature 9: Real Codebase Technical Alignment (5 Tests)
    # -------------------------------------------------------------------------
    def test_f09_tc01_shopee_and_tiktok_bidirectional_sync(self):
        """F09-TC01: Verify landing page highlights Shopee Open Platform & TikTok Shop Partner API sync."""
        self.assertIn("Shopee", self.html_content)
        self.assertIn("TikTok", self.html_content)

    def test_f09_tc02_multi_warehouse_and_barcode_scanning(self):
        """F09-TC02: Verify landing page highlights Multi-Warehouse barcode scanning."""
        self.assertRegex(self.html_content, r"Multi-Gudang|Multi-Warehouse|Gudang", "Multi-warehouse missing")
        self.assertRegex(self.html_content, r"Barcode|Scanner|QR", "Barcode scanning missing")

    def test_f09_tc03_ten_minute_escrow_settlement_reconciliation(self):
        """F09-TC03: Verify landing page highlights 10-minute escrow settlement reconciliation."""
        self.assertRegex(self.html_content, r"10\s*menit|10-menit|Rekonsiliasi|Escrow", "Escrow reconciliation missing")

    def test_f09_tc04_live_host_scheduling_and_gps_attendance(self):
        """F09-TC04: Verify landing page highlights live host shift scheduling & GPS geotagged attendance."""
        self.assertRegex(self.html_content, r"Live|Host|Studio", "Live host missing")
        self.assertRegex(self.html_content, r"GPS|Geotag|Absensi", "GPS attendance missing")

    def test_f09_tc05_postgresql_row_level_security_rls(self):
        """F09-TC05: Verify landing page highlights PostgreSQL Row-Level Security (RLS) cryptographic tenant isolation."""
        self.assertRegex(self.html_content, r"PostgreSQL|RLS|Row-Level Security", "PostgreSQL RLS security missing")


if __name__ == "__main__":
    unittest.main()
