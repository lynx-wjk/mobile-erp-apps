"""
Tier 3: Cross-Feature Interactions & Architectural Alignment.
Verifies integration coherence across HTML DOM anchors, JS dynamic fallbacks,
JSON-LD Schema offers, Showcase tabs, and CSS Obsidian design system tokens.
"""

import json
import re
import unittest
from pathlib import Path
from typing import Dict, Any, List, Set

from tests.test_helpers import (
    APP_JS_PATH,
    CANONICAL_DOMAIN,
    INDEX_HTML_PATH,
    MODULE_TAXONOMY,
    OFFICIAL_PHONE_INTL,
    STYLES_CSS_PATH,
    extract_json_ld_schemas,
    load_landing_page_dom,
    parse_whatsapp_url,
)


class TestTier3CrossFeature(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dom_parser, cls.html_content = load_landing_page_dom()
        cls.css_content = STYLES_CSS_PATH.read_text(encoding="utf-8") if STYLES_CSS_PATH.exists() else ""
        cls.js_content = APP_JS_PATH.read_text(encoding="utf-8") if APP_JS_PATH.exists() else ""
        cls.schemas = extract_json_ld_schemas(cls.html_content)

    # -------------------------------------------------------------------------
    # Group 1: Navbar & Footer Anchor Alignment with Section IDs (4 Tests)
    # -------------------------------------------------------------------------
    def test_c01_tc01_navbar_anchor_links_resolve_to_existing_ids(self):
        """C01-TC01: Verify all internal anchor hrefs in <nav> correspond to existing element IDs."""
        nav = self.dom_parser.root.find("nav")
        self.assertIsNotNone(nav, "Navbar not found")
        nav_anchors = [a.get_attr("href") for a in nav.find_all("a") if (a.get_attr("href") or "").startswith("#")]
        self.assertGreaterEqual(len(nav_anchors), 3, "Navbar must have at least 3 internal anchor links")
        
        all_ids = set(self.dom_parser.all_ids)
        for anchor in nav_anchors:
            target_id = anchor.lstrip("#")
            self.assertIn(
                target_id, all_ids,
                f"Navbar link '{anchor}' targets non-existent element id='{target_id}'"
            )

    def test_c01_tc02_footer_anchor_links_resolve_to_existing_ids(self):
        """C01-TC02: Verify all internal anchor hrefs in <footer> correspond to existing element IDs."""
        footer = self.dom_parser.root.find("footer")
        self.assertIsNotNone(footer, "Footer not found")
        footer_anchors = [a.get_attr("href") for a in footer.find_all("a") if (a.get_attr("href") or "").startswith("#")]
        all_ids = set(self.dom_parser.all_ids)
        for anchor in footer_anchors:
            target_id = anchor.lstrip("#")
            self.assertIn(
                target_id, all_ids,
                f"Footer link '{anchor}' targets non-existent element id='{target_id}'"
            )

    def test_c01_tc03_core_sections_exist_in_document(self):
        """C01-TC03: Verify essential section IDs (hero, fitur, showcase, paket-harga, faq, kontak) exist."""
        required_sections = ["hero", "fitur", "showcase", "paket-harga", "faq", "kontak"]
        all_ids = set(self.dom_parser.all_ids)
        for sec in required_sections:
            self.assertIn(
                sec, all_ids,
                f"Required section id='{sec}' is missing from the landing page DOM"
            )

    def test_c01_tc04_navbar_and_footer_brand_logo_consistency(self):
        """C01-TC04: Verify both navbar and footer brand blocks render the official logo with identical paths."""
        nav = self.dom_parser.root.find("nav")
        footer = self.dom_parser.root.find("footer")
        nav_logo = nav.find("img") if nav else None
        footer_logo = footer.find("img") if footer else None
        self.assertIsNotNone(nav_logo, "Navbar logo missing")
        self.assertIsNotNone(footer_logo, "Footer logo missing")
        self.assertEqual(
            nav_logo.get_attr("src"), footer_logo.get_attr("src"),
            "Navbar and footer logo image sources should match"
        )

    # -------------------------------------------------------------------------
    # Group 2: Dynamic JS Fallback vs Static HTML vs Schema Offers (4 Tests)
    # -------------------------------------------------------------------------
    def test_c02_tc01_pricing_plans_taxonomy_coherence(self):
        """C02-TC01: Verify the 5 pricing tiers (Trial, Starter, Growth, Pro, Enterprise) are in JS and Schema."""
        expected_plans = ["Trial", "Starter", "Growth", "Pro", "Enterprise"]
        
        # Check Schema offers
        schema_plan_names = []
        for s in self.schemas:
            graph = s.get("@graph", [s]) if isinstance(s, dict) else []
            for item in graph:
                if isinstance(item, dict) and item.get("@type") == "SoftwareApplication":
                    for off in item.get("offers", {}).get("offers", []):
                        schema_plan_names.append(off.get("name", ""))
        
        for plan in expected_plans:
            # Check Schema
            self.assertTrue(
                any(plan.lower() in name.lower() for name in schema_plan_names),
                f"Plan '{plan}' not found in Schema.org offers"
            )
            # Check JS
            self.assertIn(
                plan.lower(), self.js_content.lower(),
                f"Plan '{plan}' not defined in app.js dynamic fallback"
            )

    def test_c02_tc02_pricing_tier_whatsapp_messages_consistency(self):
        """C02-TC02: Verify WhatsApp messages generated for all plans mention 'Tim Konsultan Mobile ERP'."""
        self.assertIn("Tim Konsultan Mobile ERP", self.js_content)
        self.assertNotIn("Platform Owner", self.js_content)

    def test_c02_tc03_faq_accordion_items_align_with_schema_faq(self):
        """C02-TC03: Verify FAQ questions displayed in HTML match questions defined in FAQPage schema."""
        faq_section = self.dom_parser.root.find("section", {"id": "faq"})
        self.assertIsNotNone(faq_section, "FAQ section missing")
        faq_text = faq_section.get_full_text()
        
        for s in self.schemas:
            graph = s.get("@graph", [s]) if isinstance(s, dict) else []
            for item in graph:
                if isinstance(item, dict) and item.get("@type") == "FAQPage":
                    for q in item.get("mainEntity", []):
                        q_name = q.get("name", "")
                        # At least key keywords of each schema question should be present in the FAQ section
                        key_words = [w for w in q_name.split() if len(w) > 4][:2]
                        for kw in key_words:
                            self.assertIn(
                                kw.lower(), faq_text.lower(),
                                f"FAQ keyword '{kw}' from Schema question '{q_name}' not found in rendered FAQ"
                            )

    # -------------------------------------------------------------------------
    # Group 3: Interactive Showcase Console Tab Coherence (3 Tests)
    # -------------------------------------------------------------------------
    def test_c03_tc01_showcase_tabs_cover_enterprise_taxonomy(self):
        """C03-TC01: Verify showcase interactive console contains tabs for WMS, OMS, FMS, HRIS, EMS."""
        showcase = self.dom_parser.root.find("section", {"id": "showcase"})
        self.assertIsNotNone(showcase, "Showcase section <section id='showcase'> missing")
        showcase_text = showcase.get_full_text().upper()
        for mod in MODULE_TAXONOMY:
            self.assertIn(
                mod, showcase_text,
                f"Showcase section missing tab or data panel for module '{mod}'"
            )

    def test_c03_tc02_showcase_tab_triggers_defined_in_dom(self):
        """C03-TC02: Verify tab buttons or pill triggers define data-tab attributes."""
        tab_buttons = self.dom_parser.root.find_all("button", {"class": "tab-btn"}) or \
                      self.dom_parser.root.find_all("button", {"class": "console-tab-btn"}) or \
                      [b for b in self.dom_parser.root.find_all("button") if b.get_attr("data-tab")]
        self.assertGreaterEqual(
            len(tab_buttons), 4,
            "Showcase console must define at least 4 interactive tab switch buttons with data-tab"
        )

    def test_c03_tc03_js_tab_switching_engine_bound(self):
        """C03-TC03: Verify app.js contains tab switching event handlers for showcase console."""
        self.assertRegex(
            self.js_content,
            r"data-tab|tab-btn|active|showcase",
            "app.js must implement showcase tab switching interaction engine"
        )

    # -------------------------------------------------------------------------
    # Group 4: CSS Obsidian Design System & Typography Tokens (4 Tests)
    # -------------------------------------------------------------------------
    def test_c04_tc01_obsidian_palette_variables_declared(self):
        """C04-TC01: Verify styles.css declares dark obsidian background tokens (#080C14 / #0D1322)."""
        self.assertRegex(
            self.css_content,
            r"#080c14|#0d1322|#070a12|#0b0f19",
            "styles.css must declare dark luxury obsidian color tokens"
        )

    def test_c04_tc02_ultra_fine_border_tokens_declared(self):
        """C04-TC02: Verify styles.css declares 1px micro-border tokens with low-opacity white."""
        self.assertRegex(
            self.css_content,
            r"rgba\(\s*255\s*,\s*255\s*,\s*255\s*,\s*0\.0[5-9]\s*\)|1px\s+solid\s+rgba\(255",
            "styles.css must use ultra-fine 1px borders (rgba(255,255,255, 0.07-0.08))"
        )

    def test_c04_tc03_typography_font_stacks_declared(self):
        """C04-TC03: Verify styles.css specifies Outfit and Plus Jakarta Sans font families."""
        self.assertIn("Outfit", self.css_content, "Outfit font family missing from styles.css")
        self.assertIn("Plus Jakarta Sans", self.css_content, "Plus Jakarta Sans font family missing from styles.css")

    def test_c04_tc04_no_prohibited_owner_classnames_in_css(self):
        """C04-TC04: Verify styles.css does NOT define legacy .owner-* classes."""
        self.assertNotIn(".owner-contact-banner", self.css_content)
        self.assertNotIn(".owner-cta", self.css_content)


if __name__ == "__main__":
    unittest.main()
