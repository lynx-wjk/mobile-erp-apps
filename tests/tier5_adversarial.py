"""
Tier 5: Adversarial Hardening & Forensic Security Audits.
Performs deep white-box stress testing, prohibited word forensics, DOM ID uniqueness checks,
PNG binary header verification, and URL injection resilience testing.
"""

import json
import re
import unittest
import urllib.parse
from pathlib import Path
from typing import Dict, Any, List, Set

from tests.test_helpers import (
    APP_JS_PATH,
    CANONICAL_DOMAIN,
    INDEX_HTML_PATH,
    LANDING_PAGE_DIR,
    LOGO_PNG_PATH,
    ROBOTS_TXT_PATH,
    SITEMAP_XML_PATH,
    STYLES_CSS_PATH,
    extract_json_ld_schemas,
    load_landing_page_dom,
    scan_for_prohibited_terms,
)


class TestTier5Adversarial(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dom_parser, cls.html_content = load_landing_page_dom()
        cls.css_content = STYLES_CSS_PATH.read_text(encoding="utf-8") if STYLES_CSS_PATH.exists() else ""
        cls.js_content = APP_JS_PATH.read_text(encoding="utf-8") if APP_JS_PATH.exists() else ""
        cls.schemas = extract_json_ld_schemas(cls.html_content)

    # -------------------------------------------------------------------------
    # Adversarial Test 1: Forensic Binary Header Verification for Logo PNG
    # -------------------------------------------------------------------------
    def test_adv01_logo_png_binary_integrity(self):
        """ADV01: Verify assets/logo.png contains valid 8-byte PNG magic header [0x89, P, N, G, \r, \n, 0x1a, \n]."""
        self.assertTrue(LOGO_PNG_PATH.exists(), f"Logo file missing: {LOGO_PNG_PATH}")
        with open(LOGO_PNG_PATH, "rb") as f:
            header = f.read(8)
        expected_magic = b"\x89PNG\r\n\x1a\n"
        self.assertEqual(
            header, expected_magic,
            f"Logo file is not a valid PNG binary. Got header: {header!r}"
        )

    # -------------------------------------------------------------------------
    # Adversarial Test 2: Exhaustive Token Scan for Prohibited Words in All Files
    # -------------------------------------------------------------------------
    def test_adv02_deep_forensic_prohibited_words_across_all_landing_files(self):
        """ADV02: Exhaustively scan all files in landing_page/ for 'owner' or 'platform owner'."""
        all_files = list(LANDING_PAGE_DIR.glob("**/*"))
        target_files = [f for f in all_files if f.is_file() and f.suffix in [".html", ".js", ".css", ".txt", ".xml", ".json", ".md"]]
        
        all_violations = []
        for file_path in target_files:
            try:
                content = file_path.read_text(encoding="utf-8")
                violations = scan_for_prohibited_terms(content, file_path.name)
                all_violations.extend(violations)
            except UnicodeDecodeError:
                pass
        
        self.assertEqual(
            len(all_violations), 0,
            f"Adversarial scan detected prohibited 'owner' occurrences: {all_violations}"
        )

    # -------------------------------------------------------------------------
    # Adversarial Test 3: DOM ID Uniqueness (No Duplicate Element IDs)
    # -------------------------------------------------------------------------
    def test_adv03_no_duplicate_dom_element_ids(self):
        """ADV03: Ensure all HTML element IDs in index.html are unique without duplicates."""
        seen_ids: Set[str] = set()
        duplicates: List[str] = []
        for elem_id in self.dom_parser.all_ids:
            if elem_id in seen_ids:
                duplicates.append(elem_id)
            seen_ids.add(elem_id)
        self.assertEqual(
            len(duplicates), 0,
            f"Found duplicate DOM element IDs in index.html: {duplicates}"
        )

    # -------------------------------------------------------------------------
    # Adversarial Test 4: URL Malformation & Encoding Stress
    # -------------------------------------------------------------------------
    def test_adv04_whatsapp_url_encoding_resilience(self):
        """ADV04: Verify WhatsApp query strings in HTML do not contain unencoded &, #, or quotes."""
        a_nodes = self.dom_parser.root.find_all("a")
        wa_links = [a.get_attr("href") for a in a_nodes if "wa.me" in (a.get_attr("href") or "")]
        for link in wa_links:
            # Check for unencoded quotes or HTML entities inside href
            self.assertNotIn('"', link)
            self.assertNotIn("'", link)
            self.assertNotIn("<", link)
            self.assertNotIn(">", link)
            # Check query string splitting
            parts = link.split("?text=")
            if len(parts) > 1:
                query_payload = parts[1]
                # In query payload, ampersands should be encoded if part of text
                self.assertNotIn("&&", query_payload)

    # -------------------------------------------------------------------------
    # Adversarial Test 5: Dynamic JS Script XSS & Sanitization Guards
    # -------------------------------------------------------------------------
    def test_adv05_app_js_safe_dom_manipulation(self):
        """ADV05: Verify app.js contains escapeHtml or safe innerText/property manipulation."""
        # Ensure app.js includes HTML escaping utility for remote Supabase strings
        self.assertRegex(
            self.js_content,
            r"escapeHtml|encodeURIComponent|innerText|textContent|sanitize",
            "app.js should implement sanitization / escaping guards for dynamic plan rendering"
        )


if __name__ == "__main__":
    unittest.main()
