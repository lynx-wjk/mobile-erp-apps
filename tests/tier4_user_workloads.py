"""
Tier 4: Real-World User Workloads & Journey Simulation.
Simulates end-to-end user evaluation journeys across 5 real-world personas:
Omnichannel Retailer, Enterprise Warehouse Director, Live Stream Agency Head,
Corporate Procurement Auditor, and Search Engine Crawler Spiders.
"""

import json
import re
import unittest
import urllib.parse
from pathlib import Path
from typing import Dict, Any, List

from tests.test_helpers import (
    APP_JS_PATH,
    CANONICAL_DOMAIN,
    INDEX_HTML_PATH,
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
)


class TestTier4UserWorkloads(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dom_parser, cls.html_content = load_landing_page_dom()
        cls.css_content = STYLES_CSS_PATH.read_text(encoding="utf-8") if STYLES_CSS_PATH.exists() else ""
        cls.js_content = APP_JS_PATH.read_text(encoding="utf-8") if APP_JS_PATH.exists() else ""
        cls.robots_content = ROBOTS_TXT_PATH.read_text(encoding="utf-8") if ROBOTS_TXT_PATH.exists() else ""
        cls.sitemap_content = SITEMAP_XML_PATH.read_text(encoding="utf-8") if SITEMAP_XML_PATH.exists() else ""
        cls.schemas = extract_json_ld_schemas(cls.html_content)

    # -------------------------------------------------------------------------
    # Persona Journey 1: Omnichannel Retailer (Shopee & TikTok Seller)
    # -------------------------------------------------------------------------
    def test_uj01_omnichannel_seller_journey(self):
        """UJ01: Omnichannel seller evaluates OMS sync, reviews Growth plan, and generates WhatsApp lead."""
        # Step 1: Discover OMS feature on landing page
        features_section = self.dom_parser.root.find("section", {"id": "fitur"})
        self.assertIsNotNone(features_section, "Features section missing")
        features_text = features_section.get_full_text()
        self.assertIn("OMS", features_text, "Seller cannot find OMS module")
        self.assertIn("Shopee", features_text, "Seller cannot find Shopee sync")
        self.assertIn("TikTok", features_text, "Seller cannot find TikTok sync")

        # Step 2: Check Interactive Showcase for OMS
        showcase_section = self.dom_parser.root.find("section", {"id": "showcase"})
        self.assertIsNotNone(showcase_section, "Showcase section missing")
        self.assertIn("OMS", showcase_section.get_full_text().upper())

        # Step 3: Evaluate Growth Plan (Rp 500.000/bln)
        self.assertIn("Growth", self.html_content)
        
        # Step 4: Verify WhatsApp inquiry payload for Growth Plan
        # Expected template: 'Halo Tim Konsultan Mobile ERP, saya tertarik dengan implementasi paket Growth...'
        self.assertIn("Tim Konsultan Mobile ERP", self.js_content)
        self.assertRegex(self.js_content, r"Growth", "Growth plan missing in consultation engine")

    # -------------------------------------------------------------------------
    # Persona Journey 2: Enterprise Warehouse Operations Director
    # -------------------------------------------------------------------------
    def test_uj02_enterprise_warehouse_director_journey(self):
        """UJ02: Warehouse director evaluates WMS barcode scanning & EMS RLS isolation, then triggers Enterprise Plan."""
        # Step 1: Scan WMS Multi-Warehouse capabilities
        features_section = self.dom_parser.root.find("section", {"id": "fitur"})
        text = features_section.get_full_text() if features_section else ""
        self.assertIn("WMS", text, "Director cannot find WMS module")
        self.assertRegex(text, r"Barcode|Scanner|QR", "WMS missing Barcode scanning capability")
        self.assertRegex(text, r"Multi-Gudang|Multi-Warehouse|Gudang", "WMS missing Multi-warehouse capability")

        # Step 2: Review EMS Security Isolation
        self.assertIn("EMS", text, "Director cannot find EMS module")
        self.assertRegex(text, r"RLS|Row-Level Security|PostgreSQL", "EMS missing PostgreSQL RLS details")

        # Step 3: Trigger Enterprise Custom Plan
        self.assertRegex(self.js_content, r"Enterprise", "Enterprise plan missing in consultation engine")
        self.assertRegex(
            self.js_content,
            r"Tim Konsultan Mobile ERP",
            "Enterprise inquiry missing Tim Konsultan greeting"
        )

    # -------------------------------------------------------------------------
    # Persona Journey 3: Live Streaming Studio / Host Agency Head
    # -------------------------------------------------------------------------
    def test_uj03_live_streaming_agency_head_journey(self):
        """UJ03: Agency manager reviews HRIS live host scheduling, GPS attendance, and selects Pro Plan."""
        # Step 1: Locate HRIS and Stream Operations
        features_section = self.dom_parser.root.find("section", {"id": "fitur"})
        text = features_section.get_full_text() if features_section else ""
        self.assertIn("HRIS", text, "Agency head cannot find HRIS module")
        self.assertRegex(text, r"Host|Live|Stream", "HRIS missing Live Host details")
        self.assertRegex(text, r"GPS|Geotag|Absensi", "HRIS missing GPS attendance details")

        # Step 2: Review Pro Plan
        self.assertIn("Pro", self.html_content)
        self.assertRegex(self.js_content, r"Pro", "Pro plan missing in consultation engine")

    # -------------------------------------------------------------------------
    # Persona Journey 4: Corporate Procurement & Compliance Auditor
    # -------------------------------------------------------------------------
    def test_uj04_corporate_compliance_auditor_journey(self):
        """UJ04: Auditor verifies official enterprise contact channels, company email, and schema validity."""
        # Step 1: Check verified email bdchydi@sre.co.id
        self.assertIn(OFFICIAL_EMAIL, self.html_content)
        a_nodes = self.dom_parser.root.find_all("a")
        mailto_links = [a.get_attr("href") for a in a_nodes if f"mailto:{OFFICIAL_EMAIL}" in (a.get_attr("href") or "")]
        self.assertGreaterEqual(len(mailto_links), 1, "Mailto link missing")

        # Step 2: Check verified WhatsApp 085155338246
        wa_links = [a.get_attr("href") for a in a_nodes if "wa.me" in (a.get_attr("href") or "")]
        for link in wa_links:
            parsed = parse_whatsapp_url(link)
            self.assertEqual(parsed["phone"], OFFICIAL_PHONE_INTL)
            self.assertIn("Tim Konsultan Mobile ERP", parsed["decoded_text"])

        # Step 3: Check FAQ accordion & schema Q&As
        faq_section = self.dom_parser.root.find("section", {"id": "faq"})
        self.assertIsNotNone(faq_section, "FAQ section missing")
        self.assertGreaterEqual(len(faq_section.find_all("details") or faq_section.find_all("div", {"class": "faq-card"})), 3)

    # -------------------------------------------------------------------------
    # Persona Journey 5: Search Engine Crawler / SEO Bot
    # -------------------------------------------------------------------------
    def test_uj05_search_crawler_spider_journey(self):
        """UJ05: Search engine spider crawls robots.txt -> sitemap.xml -> canonical URL -> JSON-LD Graph."""
        # Step 1: Read robots.txt
        parsed_robots = parse_robots_txt(self.robots_content)
        self.assertIn(f"{CANONICAL_DOMAIN}/sitemap.xml", parsed_robots["sitemaps"])

        # Step 2: Read sitemap.xml
        urls = parse_sitemap_xml(self.sitemap_content)
        root_url = [u for u in urls if u["loc"] == f"{CANONICAL_DOMAIN}/"]
        self.assertEqual(len(root_url), 1)
        self.assertEqual(len(root_url[0]["images"]), 1)

        # Step 3: Validate JSON-LD Graph entities
        self.assertGreaterEqual(len(self.schemas), 1)
        graph = self.schemas[0].get("@graph", self.schemas)
        types_found = {item.get("@type") for item in graph if isinstance(item, dict)}
        self.assertIn("Organization", types_found)
        self.assertIn("SoftwareApplication", types_found)
        self.assertIn("WebSite", types_found)
        self.assertIn("FAQPage", types_found)


if __name__ == "__main__":
    unittest.main()
