# PROJECT: Mobile ERP Landing Page Enterprise Re-engineering

## 1. Master Architecture & Objectives
Re-engineer the Mobile ERP landing page (`https://mdhproduction.com`, located at `landing_page/`) to meet Tier-1 Enterprise human-crafted standards (Linear/Stripe/Vercel benchmark).
- **Core Pillars**:
  1. Official Metallic Brand Logo (`assets/logo.png`) integration across navbar, footer, favicon, OpenGraph, and Schema.
  2. Formal Enterprise Module Taxonomy (WMS, OMS, FMS, HRIS, EMS) with 100% technical fidelity to `lib/features/`.
  3. Strict Terminology Governance (zero "owner" or "platform owner" phrasing; strictly "Tim Konsultan Enterprise", "Tim Solusi Mobile ERP", "Hubungi Tim Spesialis").
  4. WhatsApp & Email Consultation Engine (WhatsApp `085155338246` / `6285155338246`, Email `bdchydi@sre.co.id`).
  5. Indonesian Enterprise SEO & Rich Structured Data (JSON-LD `@graph`, `robots.txt`, `sitemap.xml`).
  6. Tier-1 Visual Craftsmanship (Deep obsidian `#080C14` / `#0D1322`, 1px borders `rgba(255, 255, 255, 0.07)`, responsive telemetry tables).

## 2. Code Layout
- `landing_page/index.html` — Semantic HTML5 enterprise landing page, SEO headers, Schema JSON-LD, section taxonomy.
- `landing_page/styles.css` — Enterprise stylesheet, CSS variables, obsidian dark palette, typography, micro-interactions.
- `landing_page/app.js` — Client-side interaction engine (interactive showcase tabs, FAQ accordion, dynamic Supabase RPC fallback, WhatsApp link builder).
- `landing_page/robots.txt` — Search crawler rules for Googlebot, Googlebot-Image, Bingbot.
- `landing_page/sitemap.xml` — XML sitemap index with Google Image schema for canonical logo.
- `landing_page/assets/logo.png` — Official 332x332 32-bit ARGB metallic app icon.
- `tests/` — Automated E2E verification test suite (Tiers 1-5, 94/94 passing).

## 3. Feature Inventory
| # | Feature | Description | Codebase Anchor | Milestone | Status | Source |
|---|---------|-------------|-----------------|-----------|--------|--------|
| 1 | Metallic App Logo Integration | Integrate `assets/logo.png` in navbar, footer, favicon, OpenGraph, Schema | `landing_page/assets/logo.png`, `index.html` | M1 | DONE | Survey (Exp 2) |
| 2 | Indonesian Enterprise SEO Meta Tags | Title, description, keywords, canonical, geo tags (Jakarta, ID) | `index.html:1-45` | M1 | DONE | Survey (Exp 3) |
| 3 | Rich JSON-LD `@graph` Schemas | SoftwareApplication, Organization, WebSite, BreadcrumbList, FAQPage | `index.html:46-130` | M1 | DONE | Survey (Exp 3) |
| 4 | Search Crawler Config | Verified `robots.txt` (allow assets, disallow admin) & `sitemap.xml` | `landing_page/robots.txt`, `sitemap.xml` | M1 | DONE | Survey (Exp 2, 3) |
| 5 | WMS Module Taxonomy & Telemetry | Multi-warehouse, barcode scanning, inter-location transfer, dynamic opname, ROP | `lib/features/stock/`, `work_locations`, `products` | M2 | DONE | Survey (Exp 1) |
| 6 | OMS Module Taxonomy & Telemetry | Shopee/TikTok 2-way sync, order queue dispatcher, SKU mapping, zero-oversell locking | `lib/features/marketplace/`, `supabase/functions/` | M2 | DONE | Survey (Exp 1) |
| 7 | FMS Module Taxonomy & Telemetry | 10-min escrow settlement reconciliation, HPP/COGS, 7-tab margin ledger, anomaly audit | `lib/features/finance/`, `marketplace_finance_*` | M2 | DONE | Survey (Exp 1) |
| 8 | HRIS Module Taxonomy & Telemetry | Live host scheduling, GPS geofencing & photo attendance, host commission, encrypted payroll | `lib/features/host_live/`, `attendance/`, `hr/` | M2 | DONE | Survey (Exp 1) |
| 9 | EMS Module Taxonomy & Telemetry | PostgreSQL RLS cryptographic isolation, sub-150ms latency, daily backups, 10-tier RBAC | `migration_selfhost/schema.sql`, `app_roles.dart` | M2 | DONE | Survey (Exp 1) |
| 10 | Interactive Live UI Demonstrator | 5-tab real ERP workflow simulator for WMS, OMS, FMS, HRIS, EMS | `landing_page/index.html`, `app.js` | M2 | DONE | Survey (Exp 1, 2) |
| 11 | Complete "Owner" Word Elimination | Zero occurrences of "owner" / "platform owner" across HTML, JS, CSS | Global `landing_page/` | M3 | DONE | Survey (Exp 2, 3) |
| 12 | Enterprise Corporate Phrasing | "Tim Konsultan Enterprise", "Tim Solusi Mobile ERP", "Hubungi Tim Spesialis" | `index.html`, `app.js` | M3 | DONE | Survey (Exp 3) |
| 13 | Tiered WhatsApp Consultation Links | Standardized inquiry templates for Trial, Starter, Growth, Pro, Enterprise to 085155338246 | `app.js`, `index.html` | M3 | DONE | Survey (Exp 3) |
| 14 | Official Direct Contacts Display | Prominently display WhatsApp `085155338246` and Email `bdchydi@sre.co.id` | Navbar, Contact Banner, Footer | M3 | DONE | Survey (Exp 2, 3) |
| 15 | Tier-1 Obsidian Aesthetic | Deep obsidian palette (`#080C14`/`#0D1322`), 1px borders, subtle glow lighting | `styles.css` | M4 | DONE | Survey (Exp 2) |
| 16 | Elimination of AI-Slop & Boxy Widgets | Remove harsh neon buttons, boxy uniform cards, basic static tables | `styles.css`, `index.html` | M4 | DONE | Survey (Exp 2) |
| 17 | Enterprise Typography & Layout Polish | Tight kerning, Outfit + Plus Jakarta Sans, tabular numbers, responsive design | `styles.css` | M4 | DONE | Survey (Exp 2) |
| 18 | E2E Testing Suite (Tiers 1-4) | Opaque-box automated test suite verifying all acceptance criteria (94/94 tests) | `tests/` | M5 | DONE | Testing Track |
| 19 | Adversarial Hardening (Tier 5) | White-box stress testing, edge-case validation, broken link checks, forensic audit | `tests/` | M5 | DONE | Testing Track |

## 4. Milestones Decomposition

| # | Milestone Name | Scope | Dependencies | Status |
|---|----------------|-------|--------------|--------|
| **M1** | Brand Assets, Metallic Logo & SEO Infrastructure | Integrate `assets/logo.png`, Favicon, OpenGraph, Twitter Cards, 5 JSON-LD Schemas, Indonesian SEO meta tags, `robots.txt`, `sitemap.xml` | None | DONE |
| **M2** | Formal Enterprise Module Taxonomy (WMS, OMS, FMS, HRIS, EMS) | Restructure `#fitur` and `#showcase` into 5 formal enterprise modules with 100% fidelity to `lib/features/`; implement 5-tab live telemetry demonstrator | M1 | DONE |
| **M3** | Enterprise Copywriting, Terminology Sanitization & Consultation Engine | 100% elimination of "owner" phrasing; enterprise corporate terms; WhatsApp consultation triggers (085155338246) across 5 pricing tiers; email `bdchydi@sre.co.id` | M1, M2 | DONE |
| **M4** | Tier-1 Enterprise Visual Craftsmanship & UI Polish | Obsidian palette (`#080C14`/`#0D1322`), 1px micro-borders, remove harsh neon buttons and boxy AI cards, typography refinement, responsive polish | M2, M3 | DONE |
| **M5** | Final E2E Test Suite Pass (Tiers 1-4) & Adversarial Coverage Hardening (Tier 5) | Pass 100% of E2E test suite (94/94), live server HTTP 200 validation (132/132 checks), forensic integrity audit (CLEAN) | M1, M2, M3, M4 | DONE |

## 5. Interface Contracts
- **Brand Logo & Favicon**:
  - File: `landing_page/assets/logo.png` (332x332 px ARGB PNG)
  - Favicon link: `<link rel="icon" type="image/png" sizes="32x32" href="assets/logo.png">`
  - OpenGraph: `<meta property="og:image" content="https://mdhproduction.com/assets/logo.png">`
  - Schema logo: `"logo": { "@type": "ImageObject", "url": "https://mdhproduction.com/assets/logo.png" }`
- **Module Identifiers**:
  - `wms` (Warehouse Management System)
  - `oms` (Omnichannel Management System)
  - `fms` (Financial Management System)
  - `hris` (Human Resource Information System & Stream Operations)
  - `ems` (Enterprise Multi-Tenant Security & Infrastructure)
- **WhatsApp Consultation Contract**:
  - Base: `https://wa.me/6285155338246?text=`
  - Plan Message Format: `Halo Tim Konsultan Mobile ERP, saya tertarik dengan implementasi paket [Nama Paket]. Mohon informasi panduan setup dan aktivasi akun enterprise kami.`
- **Email Contact Contract**: `mailto:bdchydi@sre.co.id`
- **Terminology Blacklist**: `owner`, `platform owner`, `hubungi owner`, `login portal owner` (Strictly 0 occurrences).
