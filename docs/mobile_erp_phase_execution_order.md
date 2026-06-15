# Mobile ERP Phase Execution Order & Roadmap

This document outlines the final consolidated roadmap, detailing the exact order of operations to implement future enhancements on the Mobile ERP platform.

---

## 1. Baseline & Current State

* **Current Branch**: `rescue/antigravity-unmerged-selfhost-20260614`
* **Applied Migrations List**:
  1. `20260612080000_production_running_flow_revision.sql`
  2. `20260612141500_*` (production process stage)
  3. `20260614170000_platform_owner_and_invites.sql`
  4. `20260614170600_production_hotfix3_login_access.sql`
  5. `20260614170700_platform_owner_invite_tenant_fix.sql`
  6. `20260614170800_invite_register_stage_ui_fix.sql`
  7. `20260615120000_phase3_canonical_wrappers.sql`
  8. `20260615120100_phase3_remaining_wrappers.sql`
  9. `20260615150000_phase4b_marketplace_rls_hardening.sql`
  10. `20260615160000_phase5_subscription_core.sql` (ACTIVE - COMPLETED)
  11. `20260615170000_phase6_entitlement_rpcs.sql` (ACTIVE - COMPLETED)
  12. `20260615180000_phase7_subscription_lifecycle.sql` (Staged - Pending Self-Host Apply)


---

## 2. Dependencies & Blockers

- **Safe to Patch Next**: Phase 2 dynamic stage persistence fixes.
- **Must Wait**: Active table migrations for subscription management (Phase 5) must wait until Phase 2 and Phase 3 (canonical RPCs) are fully stable and accepted.
- **RLS Enforcement**: Marketplace RLS (Phase 4) is now staged with tenant-aware policies. The sync runner nodes use `service_role` credentials to execute background functions, ensuring background processes continue smoothly.

---

## 3. Phase-by-Phase Execution Order

### Phase 2: Production Stage Checklists (Deferred Fix)
- **Goal**: Finalize custom stage persistence and deletion.
- **Files Likely Changed**:
  - `lib/features/production/presentation/stock_progress_page.dart`
- **Migration Suggestion**: None (Uses existing `set_production_stage_active_for_app` RPC).
- **Validation**:
  ```bash
  flutter analyze
  ```
- **Rollback Risk**: Low.

---

### Phase 3: Canonical RPC Wrappers
- **Goal**: Reroute Flutter `.rpc` calls to unversioned canonical SQL functions.
- **Status**: **ACTIVE (COMPLETED FOR SAFE WRAPPERS)**
  - Created migrations `supabase/migrations/20260615120000_phase3_canonical_wrappers.sql` and `supabase/migrations/20260615120100_phase3_remaining_wrappers.sql`.
  - Rerouted `dashboard_page.dart` to try `finance_customer_dashboard_snapshot` first.
  - Rerouted `finance_report_page.dart` calls for `finance_sku_summary_rows`, `finance_unpaid_sku_rows`, `finance_mark_no_payout_order`, `finance_list_manual_operational_expenses`, and `finance_get_latest_runtime_progress` to try canonical wrappers first.
- **Files Likely Changed**:
  - `lib/features/dashboard/presentation/dashboard_page.dart` (Completed)
  - `lib/features/finance/presentation/finance_report_page.dart` (Completed)
- **Migration Suggestion**: `supabase/migrations/20260615120000_phase3_canonical_wrappers.sql`, `supabase/migrations/20260615120100_phase3_remaining_wrappers.sql`
- **SQL Functions**: `finance_customer_dashboard_snapshot`, `finance_sku_summary_rows`, `finance_unpaid_sku_rows`, `finance_mark_no_payout_order`, `finance_list_manual_operational_expenses`, `finance_get_latest_runtime_progress`
- **Rollback Risk**: Medium. If signatures mismatch, screens will fail to load. Restore versioned names in Flutter if needed.

---

### Phase 4: Marketplace RLS Hardening
- **Goal**: Enable RLS on all marketplace log and credential tables.
- **Status**: **ACTIVE (COMPLETED)**
  - Created database policies and secured the public views.
- **Files Likely Changed**: None (Database schema only).
- **Migration Suggestion**: `supabase/migrations/20260615150000_phase4b_marketplace_rls_hardening.sql`
- **SQL Functions**: None (RLS Policies).
- **Rollback Risk**: High. Disables synchronization if workers fail to bypass RLS. Staged rollback scripts at `docs/phase4b_marketplace_rls_rollback.sql`.

---

### Phase 5: SaaS Subscription Core
- **Goal**: Create plans, subscription mappings, and event tracking tables.
- **Status**: **ACTIVE (COMPLETED)**
- **Files Likely Changed**: None (Database schema only).
- **Migration Suggestion**: `supabase/migrations/20260615160000_phase5_subscription_core.sql` (Applied and validated on VPS self-host DB)
- **Rollback Risk**: Low.

---

### Phase 6: Entitlement RPCs
- **Goal**: Write subscription set, bypass, and features checking functions.
- **Status**: **ACTIVE (COMPLETED)**
- **Files Likely Changed**: None (Database schema/RPCs only).
- **Migration Suggestion**: `supabase/migrations/20260615170000_phase6_entitlement_rpcs.sql` (Applied and validated on VPS self-host DB)
- **SQL Functions**: `tenant_has_feature`, `get_my_entitlements`, `platform_tenant_subscription_set`, `platform_tenant_subscription_override_set`, `app_is_platform_owner`
- **Rollback Risk**: Low. Read-only checks use safe fallbacks and do not gate UI or enforce blocks yet.

---

### Phase 7: Lifecycle Maintenance (Staged - Pending Self-Host Apply)
- **Goal**: Manual trial/billing expiration routine.
- **Files Likely Changed**: None (Database schema only).
- **Migration Suggestion**: `supabase/migrations/20260615180000_phase7_subscription_lifecycle.sql`
- **SQL Functions**: `run_subscription_lifecycle_maintenance`, `preview_subscription_lifecycle_maintenance`
- **Rollback Risk**: Medium. Dry-run capability mitigates data issues.


---

### Phase 8: Token Wipe & Purge
- **Goal**: Implement token revoking and hard-deleting tenant data.
- **Files Likely Changed**: None (Database schema only).
- **Migration Suggestion**: `supabase/migrations/20260615190000_phase8_data_purge.sql`
- **SQL Functions**: `purge_tenant_operational_data`, `marketplace_disconnect_account`
- **Rollback Risk**: High (Irreversible deletion). Wrote explicit safeguards requiring verification input.

---

### Phase 9: Scalable Autojob Queue
- **Goal**: Configure concurrent priority queue with FOR UPDATE SKIP LOCKED.
- **Files Likely Changed**: Background sync worker daemon.
- **Migration Suggestion**: `supabase/migrations/20260615200000_phase9_job_queue.sql`
- **SQL Functions**: `dequeue_next_sync_job`
- **Rollback Risk**: High. Lock timeouts could stall order processing.

---

### Phase 10: Subscription Platform UI
- **Goal**: Build subscription manager pages in Flutter.
- **Files Likely Changed**:
  - `lib/features/admin/presentation/subscription_plans_page.dart`
  - `lib/features/admin/presentation/tenant_subscription_detail_page.dart`
  - `lib/features/admin/presentation/tenant_lifecycle_actions_page.dart`
- **Rollback Risk**: Low. Standard UI enhancements.
