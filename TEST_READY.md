# TEST READY: Mobile ERP Enterprise Landing Page Automated E2E Test Suite

## 1. Test Suite Overview
The automated opaque-box E2E Test Suite for the Mobile ERP Enterprise Landing Page (`https://mdhproduction.com`, located in `landing_page/`) has been fully engineered, validated, and published.

- **Master Test Runner**: `tests/run_e2e_tests.py`
- **Test Infrastructure Document**: `TEST_INFRA.md`
- **Total Test Cases**: 94 self-contained test cases across 5 tiers
- **Runtime Dependencies**: 0 external dependencies (Standard Library: `unittest`, `html.parser`, `xml.etree.ElementTree`, `urllib.parse`, `json`, `re`, `pathlib`)
- **Execution Command**: `python tests/run_e2e_tests.py`

---

## 2. Test Tiers & Modules

| Tier | Module File | Description | Test Count |
|---|---|---|---|
| **Tier 1** | `tests/tier1_feature_coverage.py` | Feature Coverage: Logo integration (5 locations), 5-Module Taxonomy (WMS, OMS, FMS, HRIS, EMS), Zero 'owner' occurrences, WhatsApp Consultation links (5 plans + CTAs), Email contact (`bdchydi@sre.co.id`), `robots.txt`, `sitemap.xml`, JSON-LD Schemas (`@graph`), and Codebase alignment | 45 test cases |
| **Tier 2** | `tests/tier2_boundary_cases.py` | Boundary & Corner Cases: Missing asset 404 checks, URL parameter encoding, parentheses/punctuation encoding, Schema.org numeric & type validation, prohibited word regex boundary scans, and SEO meta limits (140-165 chars) | 25 test cases |
| **Tier 3** | `tests/tier3_cross_feature.py` | Cross-Feature Interactions: Navbar/Footer/Section anchor ID alignment, dynamic JS fallback vs Schema offers vs static HTML coherence, Showcase console tab state switching (WMS/OMS/FMS/HRIS/EMS), CSS Obsidian palette (`#080C14`/`#0D1322`), and 1px micro-border tokens | 14 test cases |
| **Tier 4** | `tests/tier4_user_workloads.py` | Real-World User Workloads: Simulation of 5 persona conversion flows (Omnichannel Retailer, Enterprise Warehouse Director, Live Stream Agency Head, Corporate Compliance Auditor, Search Engine Spider) | 5 test cases |
| **Tier 5** | `tests/tier5_adversarial.py` | Adversarial Hardening: PNG binary magic header verification, exhaustive codebase token scan for 'owner', DOM ID uniqueness, URL injection resilience, and dynamic XSS escaping guards | 5 test cases |

---

## 3. How to Run the Tests

### Complete Suite Execution
```powershell
python tests/run_e2e_tests.py
```

### Individual Tier Execution
```powershell
python -m unittest tests/tier1_feature_coverage.py
python -m unittest tests/tier2_boundary_cases.py
python -m unittest tests/tier3_cross_feature.py
python -m unittest tests/tier4_user_workloads.py
python -m unittest tests/tier5_adversarial.py
```

---

## 4. Current Test Baseline & Milestone Defect Status

Executing `python tests/run_e2e_tests.py` against the current pre-reengineered `landing_page/` yields:
- **Total Executed**: 94 Tests
- **Passed**: 59 Tests (Baseline capabilities, valid contact numbers, basic layout)
- **Failed**: 35 Tests (Expected pre-implementation defects)
- **Errors**: 0

### Summary of Defects Caught (To be fixed in Milestones M1–M4):
1. **M1 (Assets & SEO)**: Missing `<img>` metallic logo in navbar/footer; broken `assets/favicon.ico` link; missing OpenGraph image tags; incomplete Schema offers and image sitemaps.
2. **M2 (Taxonomy & Showcase)**: Features section and Showcase console use casual Indonesian labels instead of formal enterprise classifications (`WMS`, `OMS`, `FMS`, `HRIS`, `EMS`).
3. **M3 (Copywriting & Consultation Engine)**: 15+ remaining occurrences of prohibited word `"owner"` / `"Platform Owner"` in `index.html` and `app.js`; WhatsApp consultation messages lacking standardized Indonesian enterprise template text.
4. **M4 (Visual Craftsmanship)**: CSS lacks deep obsidian tokens (`#080C14` / `#0D1322`) and uses harsh accent buttons.
