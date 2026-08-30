# Execution Plan: Mobile ERP Landing Page Re-engineering

## Phase 0: Discovery & Survey (Parallel Explorers)
- **Explorer 1 (Codebase Truth Miner)**: Scan `lib/features/` (wms, oms, fms, hris, live_host, konveksi, purchasing, tasks, ems) and extract genuine feature lists, data models, workflows, and role permissions. Verify exact constraints (GPS+selfie, marketplace APIs, no platform owner exposure).
- **Explorer 2 (Landing Page & UX Auditor)**: Inspect `landing_page/` (`index.html`, `styles.css`, `app.js`, assets), identify all hallucinations, outdated copy, missing modules, broken layout/styling, and review against UI/UX Pro Max standards.
- **Explorer 3 (Deployment & VPS Specialist)**: Inspect VPS deployment environment (`/var/www/landing_page/`, web server config, DNS/SSL for `mdhproduction.com`, sitemap, robots.txt, deployment scripts/MCP tools).

## Phase 1: Master Specification & Milestone Decomposition
- Synthesize findings into `PROJECT.md`.
- Establish strict feature inventory with milestone mapping.
- Set up interface contracts and asset layouts.

## Phase 2: Implementation & Re-engineering
- Dispatch **Worker** (loaded with `frontend` / `ui-ux-pro-max` skills) to:
  - Re-engineer `index.html`, `styles.css`, `app.js`, `sitemap.xml`, `robots.txt`.
  - Implement full obsidian theme (#080C14 / #0D1322), Outfit + Plus Jakarta Sans typography, micro-borders, metallic logo.
  - Implement genuine feature cards, interactive workflow demonstrator tabs across WMS, OMS, FMS, HRIS/Payroll, Live Host, Konveksi, Purchasing, Tasks, EMS.
  - Implement zero-hallucination copy, Bandung localization, WA link to 085155338246, Email to bdchydi@sre.co.id.
  - Exclude all Platform Owner features.

## Phase 3: Review, Challenge & Forensic Integrity Audit
- Dispatch 2 **Reviewers** (code quality, design compliance, mobile responsiveness, accessibility).
- Dispatch 2 **Challengers** (cross-browser layout checks, link/CTA verification, feature truthfulness validation, zero hallucination checks).
- Dispatch 1 **Forensic Auditor** (`teamwork_preview_auditor`) (static analysis, zero hallucination check, strict non-exposure of platform owner tools).

## Phase 4: Production Deployment & Verification
- Deploy updated assets to VPS `/var/www/landing_page/`.
- Verify live production endpoint `https://mdhproduction.com/` (HTTP 200 OK, SSL, sitemap.xml, robots.txt, responsive rendering).
- Synthesize final handoff and report to user.
