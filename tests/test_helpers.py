"""
Test Helpers & Parsers for Mobile ERP Landing Page E2E Test Suite.
Built strictly with Python standard library (zero external dependencies).
"""

import json
import re
import urllib.parse
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# Base Project Paths
PROJECT_ROOT = Path(__file__).resolve().parent.parent
LANDING_PAGE_DIR = PROJECT_ROOT / "landing_page"
INDEX_HTML_PATH = LANDING_PAGE_DIR / "index.html"
STYLES_CSS_PATH = LANDING_PAGE_DIR / "styles.css"
APP_JS_PATH = LANDING_PAGE_DIR / "app.js"
ROBOTS_TXT_PATH = LANDING_PAGE_DIR / "robots.txt"
SITEMAP_XML_PATH = LANDING_PAGE_DIR / "sitemap.xml"
LOGO_PNG_PATH = LANDING_PAGE_DIR / "assets" / "logo.png"

# Enterprise Constants & Interface Contracts
CANONICAL_DOMAIN = "https://mdhproduction.com"
OFFICIAL_PHONE_RAW = "085155338246"
OFFICIAL_PHONE_INTL = "6285155338246"
OFFICIAL_EMAIL = "bdchydi@sre.co.id"
MODULE_TAXONOMY = ["WMS", "OMS", "FMS", "HRIS", "EMS"]
PROHIBITED_TERMS = [
    "owner",
    "platform owner",
    "hubungi owner",
    "chat platform owner",
    "kontak owner",
    "pilih paket (hubungi owner)",
    "klaim trial (hubungi owner)",
    "hubungi owner (custom)",
    "login portal owner",
]


class HTMLDOMNode:
    def __init__(self, tag: str, attrs: Dict[str, str], parent: Optional['HTMLDOMNode'] = None):
        self.tag = tag
        self.attrs = attrs
        self.parent = parent
        self.children: List['HTMLDOMNode'] = []
        self.text_content: str = ""

    def get_attr(self, name: str, default: Optional[str] = None) -> Optional[str]:
        return self.attrs.get(name, default)

    def find_all(self, tag: Optional[str] = None, attrs: Optional[Dict[str, str]] = None) -> List['HTMLDOMNode']:
        results = []
        if (tag is None or self.tag == tag):
            match = True
            if attrs:
                for k, v in attrs.items():
                    if k == "class":
                        node_classes = self.attrs.get("class", "").split()
                        target_classes = v.split() if isinstance(v, str) else [v]
                        if not all(c in node_classes for c in target_classes):
                            match = False
                            break
                    elif self.attrs.get(k) != v:
                        match = False
                        break
            if match and (tag is not None or attrs is not None):
                results.append(self)

        for child in self.children:
            results.extend(child.find_all(tag, attrs))
        return results

    def find(self, tag: Optional[str] = None, attrs: Optional[Dict[str, str]] = None) -> Optional['HTMLDOMNode']:
        res = self.find_all(tag, attrs)
        return res[0] if res else None

    def get_full_text(self) -> str:
        text_parts = [self.text_content]
        for child in self.children:
            text_parts.append(child.get_full_text())
        return " ".join("".join(text_parts).split())


class LandingPageDOMParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.root = HTMLDOMNode("root", {})
        self.current_node = self.root
        self.raw_elements: List[Tuple[str, Dict[str, str], str]] = []
        self.scripts: List[Tuple[Dict[str, str], str]] = []
        self.all_ids: List[str] = []
        self._current_script_attrs: Optional[Dict[str, str]] = None
        self._current_script_text: List[str] = []

    def handle_starttag(self, tag: str, attrs: List[Tuple[str, Optional[str]]]):
        attr_dict = {k: (v if v is not None else "") for k, v in attrs}
        node = HTMLDOMNode(tag, attr_dict, self.current_node)
        self.current_node.children.append(node)
        
        if "id" in attr_dict and attr_dict["id"]:
            self.all_ids.append(attr_dict["id"])

        if tag.lower() not in ["meta", "link", "img", "br", "hr", "input", "source"]:
            self.current_node = node

        if tag.lower() == "script":
            self._current_script_attrs = attr_dict
            self._current_script_text = []

    def handle_endtag(self, tag: str):
        if tag.lower() == "script" and self._current_script_attrs is not None:
            self.scripts.append((self._current_script_attrs, "".join(self._current_script_text)))
            self._current_script_attrs = None
            self._current_script_text = []

        if self.current_node.parent is not None and self.current_node.tag == tag:
            self.current_node = self.current_node.parent

    def handle_data(self, data: str):
        if self._current_script_attrs is not None:
            self._current_script_text.append(data)
        else:
            self.current_node.text_content += data


def load_landing_page_dom() -> Tuple[LandingPageDOMParser, str]:
    """Reads index.html and parses it into DOM tree."""
    if not INDEX_HTML_PATH.exists():
        raise FileNotFoundError(f"Landing page index.html not found at: {INDEX_HTML_PATH}")
    content = INDEX_HTML_PATH.read_text(encoding="utf-8")
    parser = LandingPageDOMParser()
    parser.feed(content)
    return parser, content


def extract_json_ld_schemas(html_content: str) -> List[Dict[str, Any]]:
    """Extracts all JSON-LD script blocks from HTML string."""
    pattern = re.compile(r'<script[^>]*type=["\']application/ld\+json["\'][^>]*>(.*?)</script>', re.DOTALL | re.IGNORECASE)
    matches = pattern.findall(html_content)
    schemas = []
    for raw_json in matches:
        cleaned = raw_json.strip()
        if cleaned:
            try:
                data = json.loads(cleaned)
                schemas.append(data)
            except json.JSONDecodeError as e:
                schemas.append({"_parse_error": str(e), "_raw": cleaned})
    return schemas


def parse_whatsapp_url(url: str) -> Dict[str, Any]:
    """Parses a WhatsApp URL into components: phone number and decoded query message."""
    parsed = urllib.parse.urlparse(url)
    phone = ""
    # Extract phone from path e.g. /6285155338246 or /send/?phone=6285155338246
    path_clean = parsed.path.strip("/")
    if path_clean.startswith("send"):
        query = urllib.parse.parse_qs(parsed.query)
        phone = query.get("phone", [""])[0]
    elif path_clean:
        phone = path_clean

    query = urllib.parse.parse_qs(parsed.query)
    text = query.get("text", [""])[0]

    return {
        "scheme": parsed.scheme,
        "netloc": parsed.netloc,
        "phone": phone,
        "raw_text": text,
        "decoded_text": text,  # parse_qs already unquotes
        "full_url": url,
    }


def parse_robots_txt(content: str) -> Dict[str, Any]:
    """Parses robots.txt into structured rules per user-agent and sitemaps."""
    lines = content.splitlines()
    user_agents: Dict[str, Dict[str, List[str]]] = {}
    current_agent: Optional[str] = None
    sitemaps: List[str] = []
    host: Optional[str] = None

    for line in lines:
        cleaned = line.strip()
        if not cleaned or cleaned.startswith("#"):
            continue
        if ":" in cleaned:
            key, val = [part.strip() for part in cleaned.split(":", 1)]
            key_lower = key.lower()
            if key_lower == "user-agent":
                current_agent = val
                if current_agent not in user_agents:
                    user_agents[current_agent] = {"allow": [], "disallow": []}
            elif key_lower == "allow" and current_agent:
                user_agents[current_agent]["allow"].append(val)
            elif key_lower == "disallow" and current_agent:
                user_agents[current_agent]["disallow"].append(val)
            elif key_lower == "sitemap":
                sitemaps.append(val)
            elif key_lower == "host":
                host = val

    return {
        "user_agents": user_agents,
        "sitemaps": sitemaps,
        "host": host,
    }


def parse_sitemap_xml(content: str) -> List[Dict[str, Any]]:
    """Parses sitemap.xml into list of URL entries with optional image metadata."""
    root = ET.fromstring(content)
    # Default namespace handling
    ns = {
        "sm": "http://www.sitemaps.org/schemas/sitemap/0.9",
        "image": "http://www.google.com/schemas/sitemap-image/1.1",
        "xhtml": "http://www.w3.org/1999/xhtml"
    }

    urls = []
    # Handle elements with or without namespace
    for url_elem in root.findall("sm:url", ns) or root.findall("url"):
        loc_el = url_elem.find("sm:loc", ns) if url_elem.find("sm:loc", ns) is not None else url_elem.find("loc")
        lastmod_el = url_elem.find("sm:lastmod", ns) if url_elem.find("sm:lastmod", ns) is not None else url_elem.find("lastmod")
        changefreq_el = url_elem.find("sm:changefreq", ns) if url_elem.find("sm:changefreq", ns) is not None else url_elem.find("changefreq")
        priority_el = url_elem.find("sm:priority", ns) if url_elem.find("sm:priority", ns) is not None else url_elem.find("priority")

        images = []
        for img_el in url_elem.findall("image:image", ns):
            img_loc = img_el.find("image:loc", ns)
            img_title = img_el.find("image:title", ns)
            images.append({
                "loc": img_loc.text if img_loc is not None else "",
                "title": img_title.text if img_title is not None else "",
            })

        urls.append({
            "loc": loc_el.text if loc_el is not None else "",
            "lastmod": lastmod_el.text if lastmod_el is not None else "",
            "changefreq": changefreq_el.text if changefreq_el is not None else "",
            "priority": priority_el.text if priority_el is not None else "",
            "images": images,
        })
    return urls


def scan_for_prohibited_terms(text: str, filename: str = "") -> List[Dict[str, Any]]:
    """Scans text line-by-line for case-insensitive occurrences of 'owner'."""
    findings = []
    lines = text.splitlines()
    for idx, line in enumerate(lines, start=1):
        # We search for word 'owner' case-insensitively
        matches = re.finditer(r'\bowner\b', line, re.IGNORECASE)
        for match in matches:
            findings.append({
                "file": filename,
                "line_number": idx,
                "matched_text": match.group(0),
                "line_content": line.strip(),
            })
    return findings
