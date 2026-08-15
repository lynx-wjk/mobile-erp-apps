# Project Plan: Finance SKU Report & Retur/Batal Fix

## Overview
Update database RPCs and Flutter UI to correctly categorize returned/cancelled orders, display full order rows in Retur/Batal modal, ensure pending payout strictly excludes returned/cancelled orders across June & July 2026, and deploy web build to VPS.

## Milestones & Roadmap
- [ ] **Phase 0: Survey & Scope Mapping**
  - Explorer 1: Inspect SQL migrations & backend RPC definitions (`finance_sku_order_line_details`, `finance_sku_order_details_group_20260625`, CTEs, payout filters).
  - Explorer 2: Inspect Flutter UI (`finance_report_page.dart`, modal dialogs, `_skuReturnedCountMap`, payout filter wiring).
  - Explorer 3: Inspect Supabase deployment & database live connection / migrations applying scripts / VPS deployment setup.
- [ ] **Phase 1: Database RPC Implementation (M1)**
  - Worker updates/creates SQL migration scripts.
  - Apply RPC migrations to Supabase database.
  - Review, Challenge, and Audit M1.
- [ ] **Phase 2: Flutter UI Implementation (M2)**
  - Worker updates `finance_report_page.dart` and any related widgets.
  - Review, Challenge, and Audit M2.
- [ ] **Phase 3: E2E Verification & Web Build VPS Deployment (M3)**
  - Worker runs flutter tests, `flutter build web --release`, deploys to VPS (`https://mdhproduction.com`).
  - Verify live web endpoint & RPC execution outputs.
  - Final Review & Forensic Audit.
