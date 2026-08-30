"""
Tier 2: Boundary & Corner Cases E2E Tests.
Validates edge cases, URL encoding fidelity, broken asset references (404 prevention),
Schema.org field validations, case-insensitive regex word boundaries, and SEO metadata character limits.
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
    LANDING_PAGE_DIR,
    LOGO_PNG_PATH,
    OFFICIAL_EMAIL,
    OFFICIAL_PHONE_INTL,
    OFFICIAL_PHONE_RAW,
    ROBOTS_TXT_PATH,
    SITEMAP_XML_PATH,
    STYLES_CSS_PATH,
    extract_json_ld_schemas,
    load_landing_page_dom,
    parse_whatsapp_url,
    scan_for_prohibited_terms,
)


class TestTier2BoundaryCases(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dom_parser, cls.html_content = load_landing_page_dom()
        cls.css_content = STYLES_CSS_PATH.read_text(encoding="utf-8") if STYLES_CSS_PATH.exists() else ""
        cls.js_content = APP_JS_PATH.read_text(encoding="utf-8") if APP_JS_PATH.exists() else ""
        cls.schemas = extract_json_ld_schemas(cls.html_content)

    # -------------------------------------------------------------------------
    # Boundary Group 1: Missing Assets & 404 Prevention (5 Tests)
    # -------------------------------------------------------------------------
    def test_b01_tc01_all_local_img_sources_exist_on_disk(self):
        """B01-TC01: Verify all <img> src paths that point to local files exist physically on disk."""
        img_nodes = self.dom_parser.root.find_all("img")
        for img in img_nodes:
            src = img.get_attr("src") or ""
            if src and not src.startswith("http://") and not src.startswith("https://") and not src.startswith("data:"):
                # Clean query strings or anchors if any
                clean_src = src.split("?")[0].split("#")[0]
                target_path = LANDING_PAGE_DIR / clean_src
                self.assertTrue(
                    target_path.exists(),
                    f"Referenced image '{src}' does not exist at {target_path} (would cause 404 in production)"
                )

    def test_b01_tc02_all_local_link_hrefs_exist_on_disk(self):
        """B01-TC02: Verify stylesheet and favicon <link> hrefs pointing to local files exist on disk."""
        link_nodes = self.dom_parser.root.find_all("link")
        for link in link_nodes:
            rel = (link.get_attr("rel") or "").lower()
            href = link.get_attr("href") or ""
            if rel in ["stylesheet", "icon", "apple-touch-icon"] and href:
                if not href.startswith("http://") and not href.startswith("https://") and not href.startswith("//"):
                    clean_href = href.split("?")[0].split("#")[0]
                    target_path = LANDING_PAGE_DIR / clean_href
                    self.assertTrue(
                        target_path.exists(),
                        f"Referenced link '{href}' (rel='{rel}') does not exist at {target_path}"
                    )

    def test_b01_tc03_all_local_script_srcs_exist_on_disk(self):
        """B01-TC03: Verify script <script src='...'> pointing to local JS files exist on disk."""
        for attrs, _ in self.dom_parser.scripts:
            src = attrs.get("src")
            if src and not src.startswith("http://") and not src.startswith("https://") and not src.startswith("//"):
                clean_src = src.split("?")[0].split("#")[0]
                target_path = LANDING_PAGE_DIR / clean_src
                self.assertTrue(
                    target_path.exists(),
                    f"Referenced script '{src}' does not exist at {target_path}"
                )

    def test_b01_tc04_no_broken_favicon_ico_references(self):
        """B01-TC04: Verify index.html does NOT reference missing favicon.ico."""
        self.assertNotIn(
            "favicon.ico", self.html_content,
            "Found reference to non-existent 'favicon.ico'. Should reference 'assets/logo.png'"
        )

    def test_b01_tc05_all_images_have_non_empty_alt_text(self):
        """B01-TC05: Verify all <img> elements define an alt attribute for accessibility and SEO."""
        img_nodes = self.dom_parser.root.find_all("img")
        for img in img_nodes:
            src = img.get_attr("src")
            alt = img.get_attr("alt")
            self.assertIsNotNone(alt, f"Image '{src}' is missing an 'alt' attribute")
            self.assertGreater(len(alt.strip()), 0, f"Image '{src}' has an empty 'alt' attribute")

    # -------------------------------------------------------------------------
    # Boundary Group 2: Special Characters in URL Encoding (5 Tests)
    # -------------------------------------------------------------------------
    def test_b02_tc01_whatsapp_query_encoding_validity(self):
        """B02-TC01: Verify all WhatsApp URL hrefs parse without malformed % escape sequences."""
        a_nodes = self.dom_parser.root.find_all("a")
        wa_links = [a.get_attr("href") for a in a_nodes if "wa.me" in (a.get_attr("href") or "")]
        for link in wa_links:
            try:
                parsed = urllib.parse.urlparse(link)
                # Check unquote doesn't throw
                decoded_query = urllib.parse.unquote(parsed.query)
                self.assertIsNotNone(decoded_query)
            except Exception as e:
                self.fail(f"WhatsApp URL '{link}' has malformed encoding: {e}")

    def test_b02_tc02_whatsapp_parentheses_and_punctuation_encoding(self):
        """B02-TC02: Verify messages with punctuation like (Trial 14 Hari), commas, dots are properly formatted."""
        wa_links = [a.get_attr("href") for a in self.dom_parser.root.find_all("a") if "wa.me" in (a.get_attr("href") or "")]
        for link in wa_links:
            parsed = parse_whatsapp_url(link)
            text = parsed["decoded_text"]
            # Decoded text should not contain stray %20 or %28
            self.assertNotIn("%20", text, f"Decoded text contains unescaped '%20': {text}")
            self.assertNotIn("%28", text, f"Decoded text contains unescaped '%28': {text}")

    def test_b02_tc03_whatsapp_url_contains_no_raw_spaces(self):
        """B02-TC03: Verify raw WhatsApp href attribute has NO raw literal spaces (must use %20 or +)."""
        wa_links = [a.get_attr("href") for a in self.dom_parser.root.find_all("a") if "wa.me" in (a.get_attr("href") or "")]
        for link in wa_links:
            self.assertNotIn(
                " ", link,
                f"WhatsApp href '{link}' contains unencoded literal whitespace"
            )

    def test_b02_tc04_whatsapp_url_country_code_format(self):
        """B02-TC04: Verify WhatsApp phone is prefixed with 62 without leading +, spaces, or dashes in wa.me path."""
        wa_links = [a.get_attr("href") for a in self.dom_parser.root.find_all("a") if "wa.me" in (a.get_attr("href") or "")]
        for link in wa_links:
            parsed = parse_whatsapp_url(link)
            self.assertTrue(
                parsed["phone"].startswith("62"),
                f"WhatsApp path '{parsed['phone']}' should start with country code '62'"
            )
            self.assertNotIn("+", parsed["phone"])
            self.assertNotIn("-", parsed["phone"])

    def test_b02_tc05_mailto_url_encoding_and_validity(self):
        """B02-TC05: Verify mailto: links contain valid email syntax and optional subject encoding."""
        a_nodes = self.dom_parser.root.find_all("a")
        mailto_links = [a.get_attr("href") for a in a_nodes if (a.get_attr("href") or "").startswith("mailto:")]
        for link in mailto_links:
            email_part = link[len("mailto:"):].split("?")[0]
            self.assertIn("@", email_part)
            self.assertEqual(email_part, OFFICIAL_EMAIL)

    # -------------------------------------------------------------------------
    # Boundary Group 3: Schema.org Validator & Edge Cases (5 Tests)
    # -------------------------------------------------------------------------
    def test_b03_tc01_schema_software_application_ratings_bounds(self):
        """B03-TC01: Verify SoftwareApplication aggregateRating values are valid numbers within 1.0 to 5.0."""
        for schema in self.schemas:
            graph = schema.get("@graph", [schema]) if isinstance(schema, dict) else []
            for item in graph:
                if isinstance(item, dict) and item.get("@type") == "SoftwareApplication":
                    rating = item.get("aggregateRating")
                    self.assertIsNotNone(rating, "SoftwareApplication must have aggregateRating")
                    val = float(rating.get("ratingValue", 0))
                    best = float(rating.get("bestRating", 5))
                    worst = float(rating.get("worstRating", 1))
                    count = int(rating.get("ratingCount", 0))
                    self.assertTrue(1.0 <= val <= 5.0, f"Rating value {val} out of bounds [1.0, 5.0]")
                    self.assertEqual(best, 5.0)
                    self.assertEqual(worst, 1.0)
                    self.assertGreater(count, 0, "Rating count must be > 0")

    def test_b03_tc02_schema_offers_currency_and_prices(self):
        """B03-TC02: Verify schema offers define valid priceCurrency 'IDR' and non-negative prices."""
        for schema in self.schemas:
            graph = schema.get("@graph", [schema]) if isinstance(schema, dict) else []
            for item in graph:
                if isinstance(item, dict) and item.get("@type") == "SoftwareApplication":
                    offers = item.get("offers", {})
                    self.assertEqual(offers.get("priceCurrency"), "IDR")
                    offer_list = offers.get("offers", [])
                    self.assertGreaterEqual(len(offer_list), 5, "Expected 5 tiered offers in schema")
                    for off in offer_list:
                        self.assertEqual(off.get("priceCurrency"), "IDR")
                        price = float(off.get("price", -1))
                        self.assertGreaterEqual(price, 0.0, f"Price cannot be negative: {off}")
                        self.assertIn("name", off)

    def test_b03_tc03_schema_organization_has_complete_postal_address(self):
        """B03-TC03: Verify schema Organization specifies a valid PostalAddress with country 'ID'."""
        for schema in self.schemas:
            graph = schema.get("@graph", [schema]) if isinstance(schema, dict) else []
            for item in graph:
                if isinstance(item, dict) and item.get("@type") == "Organization":
                    addr = item.get("address", {})
                    self.assertEqual(addr.get("@type"), "PostalAddress")
                    self.assertEqual(addr.get("addressCountry"), "ID")
                    self.assertIn("Jakarta", addr.get("addressLocality", ""))

    def test_b03_tc04_schema_breadcrumb_list_positions_strictly_ascending(self):
        """B03-TC04: Verify BreadcrumbList item positions start at 1 and are strictly ascending."""
        for schema in self.schemas:
            graph = schema.get("@graph", [schema]) if isinstance(schema, dict) else []
            for item in graph:
                if isinstance(item, dict) and item.get("@type") == "BreadcrumbList":
                    elements = item.get("itemListElement", [])
                    self.assertGreaterEqual(len(elements), 3, "Breadcrumbs must have at least 3 levels")
                    for idx, el in enumerate(elements, start=1):
                        self.assertEqual(
                            el.get("position"), idx,
                            f"Breadcrumb position mismatch at index {idx}"
                        )
                        self.assertTrue(el.get("item", "").startswith("https://mdhproduction.com"))

    def test_b03_tc05_schema_faq_page_html_stripping(self):
        """B03-TC05: Verify FAQPage acceptedAnswer text contains clean plain text without unescaped HTML tags."""
        for schema in self.schemas:
            graph = schema.get("@graph", [schema]) if isinstance(schema, dict) else []
            for item in graph:
                if isinstance(item, dict) and item.get("@type") == "FAQPage":
                    entities = item.get("mainEntity", [])
                    for q in entities:
                        ans_text = q.get("acceptedAnswer", {}).get("text", "")
                        self.assertNotRegex(
                            ans_text,
                            r"<[a-z][\s\S]*>",
                            f"FAQ schema answer should be clean plain text without HTML tags: {ans_text}"
                        )

    # -------------------------------------------------------------------------
    # Boundary Group 4: Prohibited Word Regex & Word Boundaries (5 Tests)
    # -------------------------------------------------------------------------
    def test_b04_tc01_case_insensitive_owner_word_boundary_scan(self):
        """B04-TC01: Verify regex search r'\\bowner\\b' finds 0 matches in index.html, app.js, styles.css."""
        targets = [
            ("index.html", self.html_content),
            ("app.js", self.js_content),
            ("styles.css", self.css_content),
        ]
        all_violations = []
        for name, content in targets:
            violations = scan_for_prohibited_terms(content, name)
            all_violations.extend(violations)
        self.assertEqual(
            len(all_violations), 0,
            f"Prohibited word '\\bowner\\b' detected in codebase: {all_violations}"
        )

    def test_b04_tc02_compound_phrase_platform_owner_scan(self):
        """B04-TC02: Verify compound phrase 'platform owner' (and variations) has 0 occurrences."""
        combined = f"{self.html_content}\n{self.js_content}\n{self.css_content}"
        matches = re.findall(r"platform[\s_-]*owner", combined, re.IGNORECASE)
        self.assertEqual(
            len(matches), 0,
            f"Found 'platform owner' compound phrases: {matches}"
        )

    def test_b04_tc03_hubungi_owner_cta_phrase_scan(self):
        """B04-TC03: Verify CTA phrase 'hubungi owner' (and variations) has 0 occurrences."""
        combined = f"{self.html_content}\n{self.js_content}"
        matches = re.findall(r"hubungi[\s_-]*owner", combined, re.IGNORECASE)
        self.assertEqual(
            len(matches), 0,
            f"Found 'hubungi owner' CTA phrases: {matches}"
        )

    def test_b04_tc04_login_portal_owner_scan(self):
        """B04-TC04: Verify 'portal owner' / 'login owner' phrases have 0 occurrences."""
        combined = f"{self.html_content}\n{self.js_content}"
        matches = re.findall(r"(?:portal|login)[\s_-]*owner", combined, re.IGNORECASE)
        self.assertEqual(
            len(matches), 0,
            f"Found 'portal owner' / 'login owner' phrases: {matches}"
        )

    def test_b04_tc05_prohibited_terms_dictionary_exhaustive_check(self):
        """B04-TC05: Verify all entries in prohibited terms dictionary return 0 matches."""
        from tests.test_helpers import PROHIBITED_TERMS
        combined = f"{self.html_content}\n{self.js_content}\n{self.css_content}".lower()
        for term in PROHIBITED_TERMS:
            self.assertNotIn(
                term.lower(), combined,
                f"Prohibited dictionary term '{term}' found in landing page assets"
            )

    # -------------------------------------------------------------------------
    # Boundary Group 5: SEO Meta Tag Limits & Formatting (5 Tests)
    # -------------------------------------------------------------------------
    def test_b05_tc01_meta_title_character_length_bounds(self):
        """B05-TC01: Verify <title> length is within optimal SERP range (30 to 80 characters)."""
        title_node = self.dom_parser.root.find("title")
        self.assertIsNotNone(title_node, "<title> tag missing")
        title_text = title_node.get_full_text().strip()
        self.assertTrue(
            30 <= len(title_text) <= 90,
            f"Title length ({len(title_text)} chars) out of optimal bounds: '{title_text}'"
        )

    def test_b05_tc02_meta_description_length_bounds(self):
        """B05-TC02: Verify <meta name='description'> is within 120 to 250 characters."""
        desc_nodes = [m for m in self.dom_parser.root.find_all("meta") if m.get_attr("name") == "description"]
        self.assertGreaterEqual(len(desc_nodes), 1, "Meta description tag missing")
        desc = desc_nodes[0].get_attr("content") or ""
        self.assertTrue(
            120 <= len(desc) <= 260,
            f"Meta description length ({len(desc)} chars) out of optimal SERP bounds: '{desc}'"
        )

    def test_b05_tc03_canonical_url_is_absolute_https(self):
        """B05-TC03: Verify <link rel='canonical'> is an absolute HTTPS URL matching canonical domain."""
        canonical_links = [l for l in self.dom_parser.root.find_all("link") if (l.get_attr("rel") or "").lower() == "canonical"]
        self.assertEqual(len(canonical_links), 1, "Exactly one canonical link required")
        href = canonical_links[0].get_attr("href")
        self.assertTrue(
            href == f"{CANONICAL_DOMAIN}/" or href == CANONICAL_DOMAIN,
            f"Canonical link must be '{CANONICAL_DOMAIN}/', got '{href}'"
        )

    def test_b05_tc04_viewport_and_charset_meta_tags(self):
        """B05-TC04: Verify charset is UTF-8 and viewport specifies width=device-width."""
        charset_nodes = [m for m in self.dom_parser.root.find_all("meta") if m.get_attr("charset")]
        viewport_nodes = [m for m in self.dom_parser.root.find_all("meta") if m.get_attr("name") == "viewport"]
        self.assertGreaterEqual(len(charset_nodes), 1, "Charset meta tag missing")
        self.assertEqual(charset_nodes[0].get_attr("charset").lower(), "utf-8")
        self.assertGreaterEqual(len(viewport_nodes), 1, "Viewport meta tag missing")
        self.assertIn("width=device-width", viewport_nodes[0].get_attr("content"))

    def test_b05_tc05_geo_tags_localization_bounds(self):
        """B05-TC05: Verify Indonesian geo meta tags specify region 'ID' and Jakarta coordinates."""
        meta_nodes = self.dom_parser.root.find_all("meta")
        geo_regions = [m.get_attr("content") for m in meta_nodes if m.get_attr("name") == "geo.region"]
        geo_places = [m.get_attr("content") for m in meta_nodes if m.get_attr("name") == "geo.placename"]
        self.assertGreaterEqual(len(geo_regions), 1, "geo.region tag missing")
        self.assertEqual(geo_regions[0], "ID")
        self.assertGreaterEqual(len(geo_places), 1, "geo.placename tag missing")
        self.assertIn("Jakarta", geo_places[0])


if __name__ == "__main__":
    unittest.main()
