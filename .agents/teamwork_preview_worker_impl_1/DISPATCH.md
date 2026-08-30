## 2026-08-16T12:48:12Z

You are the Enterprise Landing Page Lead Worker for the Mobile ERP Landing Page project.
Your working directory is: c:\Users\budic\Downloads\android\inventory_control_apps\.agents\teamwork_preview_worker_impl_1

Read:
- c:\Users\budic\Downloads\android\inventory_control_apps\ORIGINAL_REQUEST.md
- c:\Users\budic\Downloads\android\inventory_control_apps\PROJECT.md
- Survey handoffs:
  - c:\Users\budic\Downloads\android\inventory_control_apps\.agents\teamwork_preview_explorer_survey_1\handoff.md (Codebase feature evidence)
  - c:\Users\budic\Downloads\android\inventory_control_apps\.agents\teamwork_preview_explorer_survey_2\handoff.md (Landing page audit)
  - c:\Users\budic\Downloads\android\inventory_control_apps\.agents\teamwork_preview_explorer_survey_3\handoff.md (SEO & WhatsApp specs)

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A teamwork_preview_auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Your implementation tasks (Milestones M1, M2, M3, M4):
You exclusively own and will modify files in: `landing_page/` (specifically `landing_page/index.html`, `landing_page/styles.css`, `landing_page/app.js`, `landing_page/robots.txt`, `landing_page/sitemap.xml`).

1. **M1 (Brand Assets & SEO Infrastructure)**:
   - Integrate `assets/logo.png` (official metallic app logo) into the navbar header, footer, favicon (`<link rel="icon" type="image/png" sizes="32x32" href="assets/logo.png">`, apple-touch-icon), OpenGraph (`og:image`), Twitter cards (`twitter:image`), and Schema.
   - Inject the full 5-schema JSON-LD `@graph` block (`Organization`, `SoftwareApplication`, `WebSite`, `BreadcrumbList`, `FAQPage`) exactly as specified in Explorer 3's handoff.
   - Add Indonesian Enterprise SEO meta tags, geo-tags (Jakarta, ID), title, description, and keywords.
   - Update `robots.txt` and `sitemap.xml` with Google image schema.

2. **M2 (Formal Enterprise Module Taxonomy: WMS, OMS, FMS, HRIS, EMS)**:
   - Restructure `#fitur` and `#showcase` into formal enterprise module classifications matching real `lib/features/` code:
     - WMS: Multi-Warehouse Architecture, Inbound/Outbound Barcode Scanning, Inter-Location Stock Transfer, Dynamic Stock Opname, Automated Reorder Point (ROP) Limits.
     - OMS: Shopee Open Platform & TikTok Shop Partner bidirectional API synchronization, centralized order queue routing, multi-store variant mapping, zero-oversell stock locking.
     - FMS: Automated 10-minute escrow settlement reconciliation, HPP/COGS calculation, multi-store net margin ledger, payout discrepancy anomaly detection.
     - HRIS & Stream Operations: Live broadcast host shift scheduling, GPS & photo geotagged attendance check-in, performance-tiered host commission engine, digital encrypted payroll slips.
     - EMS: Cryptographic tenant data isolation via PostgreSQL Row-Level Security (RLS), sub-150ms query latency, daily automated backups, granular RBAC (Role-Based Access Control).
   - Re-engineer the Interactive Live UI Demonstrator to showcase genuine ERP telemetry across 5 tabs (`wms`, `oms`, `fms`, `hris`, `ems`).

3. **M3 (Enterprise Copywriting, Terminology & Consultation Engine)**:
   - STRICTLY ELIMINATE all occurrences of the word "owner" or "platform owner" across `index.html`, `styles.css`, `app.js`. Zero occurrences allowed.
   - Use enterprise corporate terms: "Tim Konsultan Enterprise", "Tim Solusi Mobile ERP", "Hubungi Tim Spesialis", "Jadwalkan Demo Sistem".
   - Wire all pricing matrix buttons (Trial, Starter, Growth, Pro, Enterprise) and consultation CTAs to WhatsApp `085155338246` (`6285155338246`) with the exact standardized Indonesian messages:
     "Halo Tim Konsultan Mobile ERP, saya tertarik dengan implementasi paket [Nama Paket]. Mohon informasi panduan setup dan aktivasi akun enterprise kami."
   - Prominently display official contacts: WhatsApp `085155338246` and Email `bdchydi@sre.co.id`.
   - Update both static HTML and dynamic JS plans/RPC fallback.

4. **M4 (Tier-1 Enterprise Visual Craftsmanship & UI Polish)**:
   - Deep obsidian canvas (`#080C14` / `#0D1322`) with ultra-fine 1px border lines (`rgba(255, 255, 255, 0.07)`).
   - Premium typography with tight kerning (Outfit headings + Plus Jakarta Sans body, tabular numbers for data).
   - Completely remove all boxy AI-slop widgets, harsh neon containers, and fake placeholder shapes.
   - Elegant floating/sticky glass navbar with metallic logo and primary CTA.
   - Fully responsive, breathable, human-crafted enterprise polish across mobile and desktop.
