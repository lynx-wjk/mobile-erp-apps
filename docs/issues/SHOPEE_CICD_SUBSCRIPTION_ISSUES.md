# Issue Backlog: Shopee, CI/CD, Subscription

## Epic 1 - Shopee Auth And Account Lifecycle

### Issue 1.1 - Add Shopee provider adapter behind marketplace auth

Acceptance:

- `marketplace-auth-start` accepts `marketplace = shopee`.
- `auth_action = reconnect` keeps using existing marketplace account id.
- Response returns `authorization_url`, `state`, `expires_at`, and `marketplace`.
- No new Flutter function name is required.

### Issue 1.2 - Store Shopee account metadata safely

Acceptance:

- Existing marketplace account table/view can show Shopee store name, shop id,
  region, environment, token expiry, and status.
- Sensitive token values are never returned to Flutter.
- Admin can reconnect; only Super Admin can add/delete accounts.

## Epic 2 - Shopee Product, Order, Stock, Refund Flow

### Issue 2.1 - Pull Shopee products into existing cache

Acceptance:

- `marketplace-product-pull` supports Shopee.
- SKU Mapping can search Shopee products and variants.
- Pagination/cursor is used; no full-table or full-marketplace pull.

### Issue 2.2 - Pull Shopee recent orders and refresh status

Acceptance:

- `marketplace-order-pull` supports Shopee recent windows.
- Existing non-completed orders are refreshed by update time/status lookup.
- Completed orders are skipped by default.
- Output fields match the active Flutter result model.

### Issue 2.3 - Sync stock for Shopee mapped SKU

Acceptance:

- `marketplace-stock-sync-worker` can process Shopee mappings.
- Dry-run and real sync both return compact counts.
- Failed items are logged with user-friendly messages.

### Issue 2.4 - Extend refund/cancel monitor for Shopee

Acceptance:

- Detail includes date, order id, resi, status, buyer/shop, item list, local SKU,
  marketplace SKU, qty, stock action status, and reason where available.
- HPP is not shown in Refund/Cancel Monitor.
- Page remains paginated and light.

## Epic 3 - CI/CD And Version Governance

### Issue 3.1 - Add Flutter PR validation workflow

Acceptance:

- Workflow runs on pull request and main/develop pushes.
- It validates version, runs pub get, analyze, and debug APK build.
- Debug APK is uploaded as artifact.

### Issue 3.2 - Add Android release candidate workflow

Acceptance:

- Workflow runs on tag `vX.Y.Z+N`.
- Tag must match `pubspec.yaml`.
- APK release and AAB release are uploaded.
- Signing uses GitHub Secrets when configured.

### Issue 3.3 - Document release and rollback

Acceptance:

- Release steps include version bump, tag, artifact, smoke test, and rollback.
- `local.properties` is documented as local-only, not source of release truth.

## Epic 4 - Subscription Entitlement System

### Issue 4.1 - Add entitlement model

Acceptance:

- Plans `wms`, `finance`, and `full` have explicit limits and feature sets.
- Flutter has a central entitlement definition.
- Backend schema draft is additive and RLS-ready.

### Issue 4.2 - Add tenant subscription state

Acceptance:

- Tenant can have active plan, status, renewal period, and override fields.
- Expired/canceled tenant falls back to a safe locked state.

### Issue 4.3 - Enforce plan gates

Acceptance:

- Flutter hides locked features with a friendly locked state.
- Backend blocks high-cost actions if tenant plan does not allow them.
- Usage counters protect marketplace account limit, user seats, SKU count, and
  monthly order sync limit.

## Epic 5 - QA And Regression

### Issue 5.1 - Shopee smoke test

Acceptance:

- Connect/reconnect sandbox and production account.
- Pull product, map SKU, pull order, refresh status, sync stock, stock out scan,
  refund/cancel detail, and job monitor all pass.

### Issue 5.2 - Subscription role matrix smoke test

Acceptance:

- `super_admin` sees all plan-management controls allowed by plan.
- `admin` can operate marketplace but cannot access Finance.
- `finance` can access Finance only when plan allows finance.
- `warehouse` core stock flow has no regression.

### Issue 5.3 - Existing marketplace regression

Acceptance:

- TikTok/current marketplace flow still passes product, order, payout, stock,
  mapping, and job monitor smoke tests.
