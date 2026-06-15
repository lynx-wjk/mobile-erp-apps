# Mobile ERP System Current Status (Post-Phase 4B RLS Hardening)

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
* **Hotfix 3F Clickable Invite Link**: **PASS** (Updated in this patch)
  - Removed generation of localhost links.
  - Ensured the primary share/WhatsApp link is HTTPS.
  - The dialog now outputs:
    1. Primary Link: `<PUBLIC_WEB_REGISTER_URL>?invite=<token>` (if configured in `.env`), or fallback `https://mobile-erp-apps.vercel.app/register?invite=<token>` (if unconfigured).
    2. Token Raw: For manual copy-paste fallback.
    3. Link Aplikasi (Deep Link): `mobileerp://register?invite=<token>` as a secondary app deep link.
  - Configured buttons: **Copy Link** (HTTPS), **Open Link** (HTTPS), **Copy Token**, **Copy App Link** (deep link), and **Done**.

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
* **Status**: **ACTIVE - COMPLETED FOR SAFE WRAPPERS**
  - Audited and created SQL wrappers in `supabase/migrations/20260615120000_phase3_canonical_wrappers.sql` for low-risk functions: `finance_customer_dashboard_snapshot`, `finance_sku_summary_rows`, `finance_unpaid_sku_rows`, and `finance_mark_no_payout_order`.
  - Audited and created SQL wrappers in `supabase/migrations/20260615120100_phase3_remaining_wrappers.sql` for additional low-risk functions: `finance_get_latest_runtime_progress` and `finance_list_manual_operational_expenses`.
  - Rerouted `dashboard_page.dart` call from `finance_customer_dashboard_snapshot_v24_6_82o` to `finance_customer_dashboard_snapshot` with automatic fallback to versioned names.
  - Rerouted `finance_report_page.dart` calls for `finance_sku_summary_rows`, `finance_unpaid_sku_rows`, `finance_mark_no_payout_order`, `finance_list_manual_operational_expenses`, and `finance_get_latest_runtime_progress` to canonical wrappers with automatic fallback.
  - Old/versioned RPCs are retained for backward-compatibility.
  - High-risk sync and operational queue RPCs left untouched.

---

## Phase 4: Marketplace RLS Hardening
* **Status**: **ACTIVE (COMPLETED)**
  - Audited marketplace table readiness and Edge Function superuser service role clients in `docs/phase4_marketplace_rls_service_role_audit_result.md`.
  - Staged minimal safe database migration `20260615150000_phase4b_marketplace_rls_hardening.sql` implementing view security parameters, indexing, and strict policies.
  - Secured `marketplace_accounts_public` and `marketplace_stock_sync_logs_public` views by setting `security_invoker = true`.
  - Enabled RLS on 19 tenant-owned tables and deployed policies enforcing `tenant_id = app_current_tenant_id_or_default()`.
  - Enabled RLS on global tables (`marketplace_auto_runner_locks`, `marketplace_cron_edge_config_v24_6_82q`) to block authenticated/anonymous roles, restricting them solely to `service_role` and `postgres`.
  - Added join-based SELECT tenant safety for `marketplace_auto_pull_request_log_v24_6_82q` using `marketplace_accounts`.
  - Created emergency recovery rollback script in `docs/phase4b_marketplace_rls_rollback.sql`.

---

## Phase 5: SaaS Subscription Core
* **Status**: **ACTIVE (COMPLETED)**
  - Migration `supabase/migrations/20260615160000_phase5_subscription_core.sql` has been applied and validated on VPS self-host DB.
  - Setup scripts ready for tables `feature_catalog`, `subscription_plans`, `subscription_plan_features`, `tenant_subscriptions`, `tenant_subscription_overrides`, `tenant_subscription_events`, and `tenant_deletion_audit`.
  - Idempotent seeds ready for 21 core features and 5 plans (`trial`, `starter`, `growth`, `pro`, `enterprise`) with their feature mappings.
  - Setup scripts ready for row-level security (RLS) on all new tables restricting writes to platform owner role, and allowing scoped SELECT checks.
  - Read-only RPCs `list_subscription_plans_for_app` and `get_my_subscription_snapshot` staged with zero-enforcement safe fallbacks for unassigned tenants.


---

## Phase 6: Entitlement RPCs & Platform UI
* **Status**: **ACTIVE (COMPLETED)**
  - Migration `supabase/migrations/20260615170000_phase6_entitlement_rpcs.sql` has been applied and validated on VPS self-host DB.
  - Created unversioned platform owner helper `app_is_platform_owner` and entitlement RPCs: `tenant_has_feature`, `get_my_entitlements`, `platform_tenant_subscription_set`, and `platform_tenant_subscription_override_set`.
  - Added safe fallbacks for unassigned tenants returning a default active status with core features (`stock_basic`, `production_basic`, `finance_basic`, `invite_management`).
  - Added read-only Subscription Plans Page, Tenant Subscription Detail Page with plan updating, feature overrides, and live entitlement preview, and integrated it into the Platform Owner Dashboard.
  - Read-only RPCs and UI elements do not block any user login or features.

---

## Phase 7: Lifecycle Maintenance Routine
* **Status**: **STAGED / PENDING SELF-HOST APPLY**
  - Migration `supabase/migrations/20260615180000_phase7_subscription_lifecycle.sql` is staged locally.
  - Created unversioned routine `run_subscription_lifecycle_maintenance(p_dry_run, p_now)` with dry-run capabilities and transition logic: `trialing -> expired`, `active -> past_due`, `past_due -> suspended`, and `canceled -> expired`.
  - Deployed unversioned preview helper `preview_subscription_lifecycle_maintenance(p_now)`.
  - Gated write operations strictly to platform owner with no automated cron runs or app suspension enabled.

---

## Phase 8 to Phase 10: data wipe & remaining phases
* **Status**: **NOT IMPLEMENTED (ANALYSIS ONLY)**
  - Analysis and roadmap prepared. See corresponding markdown files in `docs/` for each phase.
  - No operational data purges or automatic account disconnections executed.

