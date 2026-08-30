# TEST INFRASTRUCTURE & ARCHITECTURE: Mobile ERP Landing Page

## 1. Test Philosophy & Principles

### 1.1 Opaque-Box E2E Testing
The test suite treats the Mobile ERP enterprise landing page (`https://mdhproduction.com`, located under `landing_page/`) as an opaque-box system evaluated strictly through its observable external contracts: rendered HTML5 DOM structure, CSS design token compliance, JavaScript interaction handlers, robots crawler directives, XML sitemaps, JSON-LD Schema graphs, and WhatsApp/Email communication endpoints.

### 1.2 Authoritative Output Derivation
All expected outputs and assertion targets are derived directly from:
1. `ORIGINAL_REQUEST.md`: Core requirements (R1 Enterprise Taxonomy, R2 Visual Craftsmanship & Metallic Logo, R3 Enterprise Tone & 0 'owner' occurrences, R4 Search Engine Indexing & Rich Schema).
2. `PROJECT.md`: Master architecture, feature inventory (F1–F19), and interface contracts.
3. Survey Handoffs: `survey_1/handoff.md` (Codebase taxonomy & telemetry), `survey_2/handoff.md` (Landing page & asset audit), `survey_3/handoff.md` (SEO, Schemas & Consultation Engine specifications).

### 1.3 Strict Test Integrity (No Facade Tests)
Every test is designed with real assertions against actual files and data structures. Tests never hardcode unconditional passes. If an underlying file violates a specification (e.g. presence of "owner" wording, missing logo tag, invalid Schema, broken URL), the test will fail with an explicit diagnostic message and line/character context.

### 1.4 Independence & Determinism
All test cases are self-contained and isolated. They do not depend on external live internet connectivity or execution order; fallback structures and local parsers allow deterministic verification in any standard Python 3.10+ runtime.

---

## 2. Feature Inventory & Test Mapping

| Feature ID | Feature Name | Description | Test Module | Target Tier |
|---|---|---|---|---|
| **F01** | Metallic Logo Integration | `assets/logo.png` rendered in Navbar, Footer, Favicon, OpenGraph, Schema | `tests/tier1_feature_coverage.py` | Tier 1, Tier 2 |
| **F02** | 5-Module Taxonomy | Formal classification: WMS, OMS, FMS, HRIS, EMS | `tests/tier1_feature_coverage.py` | Tier 1, Tier 3 |
| **F03** | Zero 'Owner' Terminology | Strict 0 occurrences of "owner" / "platform owner" across HTML, JS, CSS | `tests/tier1_feature_coverage.py` | Tier 1, Tier 2, Tier 5 |
| **F04** | Tiered WhatsApp Triggers | Formatted WhatsApp links to `085155338246` with exact Indonesian plan inquiries | `tests/tier1_feature_coverage.py` | Tier 1, Tier 3, Tier 4 |
| **F05** | Official Direct Email Contact | `bdchydi@sre.co.id` displayed and linked via `mailto:` | `tests/tier1_feature_coverage.py` | Tier 1, Tier 4 |
| **F06** | Search Crawler Directives | `robots.txt` rules for Googlebot, Bingbot, asset allowances, disallowed routes | `tests/tier1_feature_coverage.py` | Tier 1, Tier 2 |
| **F07** | XML Sitemap & Image Schema | `sitemap.xml` with Google image extension for metallic logo | `tests/tier1_feature_coverage.py` | Tier 1, Tier 2 |
| **F08** | Rich JSON-LD Schemas | `@graph` with SoftwareApplication, Organization, WebSite, Breadcrumbs, FAQPage | `tests/tier1_feature_coverage.py` | Tier 1, Tier 2 |
| **F09** | WMS Telemetry & Showcase | Multi-warehouse, barcode scan, inter-warehouse transfer, opname, ROP | `tests/tier1_feature_coverage.py`, `tests/tier3_cross_feature.py` | Tier 1, Tier 3 |
| **F10** | OMS Telemetry & Showcase | Shopee/TikTok 2-way sync, order dispatcher, SKU mapping, zero-oversell locking | `tests/tier1_feature_coverage.py`, `tests/tier3_cross_feature.py` | Tier 1, Tier 3 |
| **F11** | FMS Telemetry & Showcase | 10-minute escrow reconciliation, HPP/COGS, 7-tab margin ledger, anomaly audit | `tests/tier1_feature_coverage.py`, `tests/tier3_cross_feature.py` | Tier 1, Tier 3 |
| **F12** | HRIS Telemetry & Showcase | Host live scheduling, GPS/photo geotagged attendance, commissions, payroll slips | `tests/tier1_feature_coverage.py`, `tests/tier3_cross_feature.py` | Tier 1, Tier 3 |
| **F13** | EMS Telemetry & Showcase | PostgreSQL RLS cryptographic isolation, sub-150ms latency, daily backups, RBAC | `tests/tier1_feature_coverage.py`, `tests/tier3_cross_feature.py` | Tier 1, Tier 3 |
| **F14** | Interactive Console UI | 5-tab live workflow simulator matching WMS, OMS, FMS, HRIS, EMS | `tests/tier3_cross_feature.py`, `tests/tier4_user_workloads.py` | Tier 3, Tier 4 |
| **F15** | Tier-1 Obsidian Palette | Deep obsidian `#080C14` / `#0D1322`, 1px borders `rgba(255,255,255,0.07)` | `tests/tier3_cross_feature.py` | Tier 3 |
| **F16** | Anti-AI Slop Governance | Removal of boxy neon containers, fake placeholder cards, uniform pastel grids | `tests/tier3_cross_feature.py` | Tier 3, Tier 5 |
| **F17** | Typography & Kerning | Outfit headings, Plus Jakarta Sans body, tabular numbers | `tests/tier3_cross_feature.py` | Tier 3 |
| **F18** | End-to-End User Conversion | Simulated journey: Load -> Explore -> Tab Switch -> Plan Select -> WhatsApp Trigger | `tests/tier4_user_workloads.py` | Tier 4 |
| **F19** | Adversarial Hardening | URL encoding stress, injection resilience, schema validator, forensic checks | `tests/tier5_adversarial.py` | Tier 5 |

---

## 3. Test Architecture & Structure

The test suite is built in Python using standard libraries (`unittest`, `html.parser`, `xml.etree.ElementTree`, `urllib.parse`, `json`, `re`, `pathlib`) for 100% portable, zero-dependency execution.

```
tests/
├── run_e2e_tests.py           # Master CLI test runner executing Tiers 1-5 with colored reports
├── test_helpers.py            # Shared HTML DOM parser, Schema extractor, WhatsApp URL decoder, XML validators
├── tier1_feature_coverage.py  # Tier 1: Feature Coverage (>=5 test cases per feature)
├── tier2_boundary_cases.py    # Tier 2: Boundary & Corner Cases (>=5 test cases per feature)
├── tier3_cross_feature.py     # Tier 3: Cross-Feature Interactions & Alignment
├── tier4_user_workloads.py    # Tier 4: Real-World User Conversion Workloads
└── tier5_adversarial.py       # Tier 5: Adversarial Hardening & Forensic Audits
```

### 3.1 Tier Structure & Test Tiers

1. **Tier 1: Feature Coverage**
   - Direct verification of primary specifications (happy paths).
   - Every core feature has at least 5 distinct test assertions.
   - Covers: Logo in 5 locations, 5-module taxonomy headings/descriptions, 0 'owner' occurrences across all files, WhatsApp consultation engine across 5 pricing plans + hero/nav/footer, direct email links, robots.txt directives, sitemap.xml structure, and JSON-LD Schema entities.

2. **Tier 2: Boundary & Corner Cases**
   - Edge-case validation and error boundary checks.
   - At least 5 boundary test cases per feature.
   - Covers: Empty URL query parameters, special characters in URL encoding (parentheses, commas, spaces, currency symbols), missing asset path checks (404 prevention), Schema validator (missing properties, bad formats, invalid types), prohibited word regex scanners (case-insensitive substring and word-boundary matching), meta description character limits (150-160 chars).

3. **Tier 3: Cross-Feature Interactions**
   - State and structural coherence across multiple modules.
   - Covers: Navbar anchor targets aligning with page section IDs; Footer links matching Navbar links; Dynamic JS fallback plans matching JSON-LD Schema offers; Interactive Showcase tab attributes matching module taxonomy (WMS, OMS, FMS, HRIS, EMS); CSS theme tokens matching obsidian palette `#080C14`/`#0D1322` and ultra-fine 1px borders.

4. **Tier 4: Real-World User Workloads**
   - Simulation of end-user journeys from entry to conversion:
     - **Workflow 1 (SME Retailer / Omnichannel Seller)**: Lands on page -> scans WMS/OMS modules -> switches to OMS console tab -> chooses Growth Plan (Rp 500k) -> triggers WhatsApp consultation link with Growth Plan prefilled message.
     - **Workflow 2 (Enterprise Factory / Multi-Warehouse Director)**: Lands on page -> reads WMS multi-location opname -> checks EMS PostgreSQL RLS security -> switches to EMS/WMS console tabs -> selects Enterprise Plan -> triggers custom consultation WhatsApp message.
     - **Workflow 3 (Live Streaming Studio / Agency Manager)**: Lands on page -> reviews HRIS host scheduling & commissions -> switches to HRIS console tab -> selects Pro Plan (Rp 800k) -> triggers Pro Plan WhatsApp consultation link.
     - **Workflow 4 (Corporate Procurement Officer / Technical Auditor)**: Lands on page -> verifies official company contact (WhatsApp `085155338246`, Email `bdchydi@sre.co.id`) -> reviews Schema FAQ -> tests mailto links.
     - **Workflow 5 (Search Engine Crawler / Bot Audit)**: Requests robots.txt -> verifies crawler allowances -> parses sitemap.xml -> fetches image schemas -> validates JSON-LD Schema graph.

5. **Tier 5: Adversarial Hardening**
   - Aggressive white-box and black-box stress tests:
     - Deep forensic scans for accidental remnants of prohibited words (`owner`, `platform owner`, `platform_owner`, `hubungi owner`).
     - URL malformation tests (injection of script tags, SQL payloads, unencoded ampersands in query strings).
     - Strict HTML5 semantic structure validation (no duplicate IDs, unclosed tags, broken relative links).
     - Strict CSS validation (ensuring harsh neon `#25d366` button fills and generic boxy `.kpi-card` widgets are removed).

---

## 4. Coverage Thresholds & Quality Gates

| Metric | Target / Gate | Enforcement Mechanism |
|---|---|---|
| **Tier 1 Feature Coverage** | >= 5 test cases per feature | `tests/tier1_feature_coverage.py` |
| **Tier 2 Boundary Coverage** | >= 5 test cases per feature | `tests/tier2_boundary_cases.py` |
| **Tier 3 Cross-Feature Interaction** | 100% alignment across components | `tests/tier3_cross_feature.py` |
| **Tier 4 User Workloads** | 5 complete end-user persona flows | `tests/tier4_user_workloads.py` |
| **Tier 5 Adversarial Hardening** | 0 security/formatting/forensic violations | `tests/tier5_adversarial.py` |
| **Zero 'Owner' Phrasing** | Exactly 0 matches in HTML/JS/CSS/Schema | Case-insensitive regex scan |
| **Test Execution Reliability** | 100% pass on completed milestone | `python tests/run_e2e_tests.py` |

---

## 5. Execution Instructions

To run the complete automated E2E test suite:
```powershell
python tests/run_e2e_tests.py
```

To run a specific test tier:
```powershell
python -m unittest tests/tier1_feature_coverage.py
python -m unittest tests/tier2_boundary_cases.py
python -m unittest tests/tier3_cross_feature.py
python -m unittest tests/tier4_user_workloads.py
python -m unittest tests/tier5_adversarial.py
```
