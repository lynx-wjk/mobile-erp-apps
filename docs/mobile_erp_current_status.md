# Mobile ERP System Current Status (Post-Hotfix 3E)

This document provides a summary of the current verified state of the Mobile ERP application, tracking the implementation, testing, and acceptance of different modules.

---

## Phase 1: Authentication, Tenant Provisioning & Login Access Flow

* **Platform Owner Dashboard**: **PASS**
  - Dashboard loads correctly for Platform Owner.
  - Can view all tenants and their readiness status.
* **Tambah Tenant (Tenant Creation)**: **PASS**
  - Tenant registration form works.
  - Correctly calls `platform_create_tenant_for_app` canonical RPC.
* **Generate Undangan (Invite Token Generation)**: **PASS**
  - Invites can be generated for specific roles (`AppRole.admin`, `AppRole.production`, etc.).
  - Uses `create_invite` RPC. Invites are md5-hashed to support self-hosted Supabase instances without the pgcrypto extension.
* **Register via Invite**: **PASS**
  - Link/Token validation works via `check_invite` and registration completes via `accept_invite` RPCs.
  - Fixed infinite width crash in `FilledButton.icon` by applying localized `minimumSize` overrides on buttons.
* **Request Access Flow**: **PASS**
  - External contact fallback links function correctly.
  - Re-routed to trigger `launchUrl(externalApplication)` for WhatsApp, Email, and Instagram. If the platform fails to open, it safely falls back to copying the contact info/link to clipboard and showing a user feedback notification.
* **Hotfix 3E Clickable Invite Link**: **PASS** (Fixed in this patch)
  - Removed generation of localhost links (`http://localhost/register?invite=<token>`).
  - Added native Android intent-filter for `mobileerp://register` deep linking.
  - The dialog now outputs:
    1. Primary Link: `PUBLIC_WEB_REGISTER_URL?invite=<token>` (if configured in `.env`), or `mobileerp://register?invite=<token>` (if `.env` is unconfigured).
    2. Token Raw: For manual copy-paste fallback.
  - Configured buttons: **Copy Link**, **Open Link** (uses `url_launcher` externally, copies on failure), **Copy Token**, and **Done**.

---

## Phase 2: Production Progress & Payment Rules

* **Payment Edit/Save**: **PASS**
  - Edits to existing tailor payments are successfully updated in the DB.
* **Payment Delete/Void**: **PASS**
  - Deletions or voids of payment records are functional and no longer blocked by role checking.
* **Photo Proof Bypass**: **PASS**
  - Workers can register tailor payments without a mandatory photo proof if permitted.
* **Payment Label Rendering**: **PASS**
  - Fixed issue where the payment label would render as "--".
* **Production Deletion Access**: **PASS**
  - `delete_production_progress_for_app` checks allow users with the `production` role to delete tenant-owned progress records.
* **Done/Stock-in Lock Bypass**: **PASS**
  - Standard edits and payment inputs are blocked once a production run has been marked "Done" or "Stock-in", except for authorized stock correction flows.
* **Custom Progress Checklist & Dynamic Stages**: **DEFERRED / KNOWN ISSUE**
  - Custom progress checklist stage persistence still requires a final structural fix.
  - Editing, deleting, or restoring default/custom stages is still not fully accepted under all edge cases.
  - **Action**: Do not mark dynamic stages fully done yet.

---

## Phase 3: Canonical RPC Wrappers
* **Status**: **NOT IMPLEMENTED (ANALYSIS ONLY)**
  - Safe audit prepared in `docs/phase3_canonical_rpc_audit.md`.
  - RPC SQL drafts prepared in `supabase/migrations_draft/phase3_canonical_rpc_wrappers_draft.sql`.
  - No old/versioned RPCs have been deleted to avoid regression.

---

## Phase 4: Marketplace RLS Hardening
* **Status**: **NOT IMPLEMENTED (ANALYSIS ONLY)**
  - Audit plan completed in `docs/phase4_marketplace_rls_audit.md`.
  - No active database policies applied yet.

---

## Phase 5 to Phase 10: SaaS Subscription, Autojobs & Platform UI
* **Status**: **NOT IMPLEMENTED (ANALYSIS ONLY)**
  - Analysis and roadmap prepared. See corresponding markdown files in `docs/` for each phase.
  - No subscription tables created, no lifecycle crons scheduled, and no operational purges executed.
