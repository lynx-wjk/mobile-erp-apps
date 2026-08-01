# DevOps Pending P0/P1 Tracker

Track list of critical post-reconciliation / platform engineering tasks.

## P0 Backlog (Action Required)

### 1. Shopee Real Stock Sync `invalid_partner_id`
- **Issue**: Attempting to synchronize live stock values to Shopee OpenAPI returns `invalid_partner_id`.
- **Root Cause**: The partner ID config used for signature generation mismatching the active credentials in sandbox or production app whitelist.
- **Action Plan**:
  - Audit Shopee app console partner configuration.
  - Test signature generation locally with sandbox partner credentials.
  - Update credentials in `public.marketplace_accounts` securely.

### 2. Android Physical Smoke Test
- **Issue**: Physical Android build smoke testing required to verify layout rendering on smaller handheld devices.
- **Action Plan**:
  - Run physical build on target Android test device.
  - Verify layout responsiveness, dialog widths, and text wrapping issues on screen sizes under 360dp.

## P1 Backlog (Medium Priority)

### 3. RPC/Cron Cleanup Audit
- **Issue**: Legacy versioned RPCs and pg_cron sync jobs cluttering the schema.
- **Rule**: Do not drop RPCs or crons yet until date-range scoping is fully validated in production.
- **Action Plan**:
  - Review all versioned functions in `versioned_rpc_refs.txt`.
  - Prepare a safe migration script to drop unused legacy RPCs after validation.

### 4. Continuous Deployment (CD) Plan
- **Goal**: Implement automatic deployment of database migrations and Flutter web builds on merge.
- **Action Plan**:
  - Draft GitHub Actions workflow file for automated test execution, DB migration rollout, and hosting deployment.

### 5. HPP Mapping / Import Approval
- **Status**: Pending approval from finance team.
- **Rule**: **Do not execute HPP import/sync in this patch.**
- **Action Plan**: Wait for written approval on mapping rules from accounting before executing backfill crons.

### 6. Self-Host Partition/Index Follow-Up
- **Goal**: Implement tenant database splitting recommendations from the tenant isolation dry-run report.
- **Action Plan**:
  - Add missing indices by `tenant_id` + `order_created_at` on high-volume tables (`marketplace_orders`, `marketplace_order_items`, `marketplace_finance_reports`).
  - Draft RLS policies for strict tenant partition container isolation.
