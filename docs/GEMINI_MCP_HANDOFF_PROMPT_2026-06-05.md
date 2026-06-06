# Gemini MCP Handoff Prompt - 2026-06-05

You are continuing the Flutter/Supabase project at:

`C:\Users\budic\Downloads\android\inventory_control_apps`

Continue from the current files on disk. Do not restart the implementation from scratch.

## Non-Negotiable Constraints

- Do not rename marketplace contracts.
- Do not rename existing Supabase RPC names.
- Do not rename existing tables.
- Keep local SKU as the core stock source of truth.
- Do not create destructive SQL, table drops, business-data deletes, or cleanup migrations unless the user explicitly asks and smoke tests are green.
- Keep marketplace service contracts additive and backward-compatible.
- If finance rows are deleted from Finance, production ledger rows must remain, with only finance linkage cleared.
- For Shopee developing accounts, use Testing/Sandbox by default.

## Current Supabase Project

- Project ref: `tllknfqoczarogizheal`
- Supabase URL: `https://tllknfqoczarogizheal.supabase.co`
- New clone project already exists:
  - Project ref: `qmmrjzlgaozwazxkvoxn`
  - Name: `mobile_erp`
  - Status: `ACTIVE_HEALTHY`
- Edge Functions verified active:
  - `marketplace-auth-start` ACTIVE version 15, updated `2026-06-05 09:58:29 UTC`
  - `marketplace-shopee-callback` ACTIVE version 15, updated `2026-06-05 09:51:11 UTC`

## Latest Update From Codex - 2026-06-05 17:40 WIB

### Marketplace Finance Backlog Fix

Problem found:

- TikTok order pull is not stuck. `marketplace_orders` had fresh data on 2026-06-05.
- Finance was stuck around `period_end = 2026-05-24`.
- Root cause: `finance_order_candidates_for_period_v3` only accepted order status `COMPLETED`, while later TikTok eligible payout orders are stored as `DELIVERED`.

Applied Supabase migration:

- Migration version: `20260605102410`
- Migration name: `include_tiktok_delivered_finance_candidates`
- Scope: `CREATE OR REPLACE FUNCTION public.finance_order_candidates_for_period_v3(...)`
- Contract preserved: same function name, same signature, no table/RPC rename.
- Change: candidates now include `DELIVERED` for TikTok/TikTok Shop, while still keeping `COMPLETED` behavior.

Verification:

- Candidate RPC returned rows again after migration.
- Manual backlog job inserted into existing `finance_sync_jobs`, not a new table:
  - Job id: `3b38c5e5-bc48-4c57-a340-9c75c30ec779`
  - Period: `2026-05-20` to `2026-06-05`
  - Status after worker: `pending` because it requeues while backlog remains.
  - Batch evidence: `checked=60`, `success=60`, `failed=0`, `has_more=true`.
- Edge worker picked the job automatically around `2026-06-05 10:30 UTC` and again around `10:41 UTC`.
- Finance rows are moving forward again:
  - `2026-05-20`: 218 rows
  - `2026-05-21`: 175 rows, latest pull `2026-06-05 10:41:05 UTC`
  - `2026-05-22`: 34 rows, latest pull `2026-06-05 10:41:12 UTC`
- Continue monitoring until the job reaches after `2026-05-24` and then current June dates.

Important next step:

- Do not reset order/finance data while this job is catching up.
- Let the worker continue every interval, or trigger from the existing Finance page button using the current logged-in user session.
- If backlog stalls, inspect `finance_sync_jobs.last_result` and Edge logs for `marketplace-finance-pull` / `marketplace-tiktok-service`.

### Vercel Deployment

Production deploy completed from clean `build/web`.

- Production deployment URL:
  - `https://operational-management-ptdskoq9o-ha-i-s-projects.vercel.app`
- Alias assigned successfully:
  - `https://operational-management-app-two.vercel.app`
- Smoke result:
  - `https://operational-management-app-two.vercel.app/` loads `Operations Control`.
  - Console errors: `0`.
  - `https://operational-management-app-two.vercel.app/marketplace-connected.html?marketplace=shopee&status=test` loads `Marketplace Connected`.
  - Console errors: `0`.

Current smoke screenshots:

- `web_smoke_desktop_20260605_current.png`
- `web_smoke_mobile_20260605_current.png`
- `web_smoke_vercel_20260605_current.png`
- `web_smoke_callback_20260605_current.png`

Deployment safety:

- `vercel_deploy` still contains an old `.env.local`; do not deploy that folder directly.
- Deploy from `build/web` after verifying:
  - `Get-ChildItem -Force build\web | Where-Object { $_.Name -like '.env*' }`
  - result must be empty.

### Shopee Auth Status

Current function code uses the Shopee v2 auth sign base string:

- `partner_id + path + timestamp`
- Auth path: `/api/v2/shop/auth_partner`
- Token path: `/api/v2/auth/token/get`

Deployment status:

- `marketplace-auth-start` ACTIVE version 15.
- `marketplace-shopee-callback` ACTIVE version 15.

Database evidence:

- Latest Shopee OAuth states were created before the strict fix deployment.
- No Shopee account is stored yet.
- Therefore old browser URLs from history can still show `error_sign` or `invalid_partner_id`; generate a new link from Marketplace Accounts after deployment.

Expected Shopee test flow:

1. Open deployed app.
2. Login.
3. Go to Marketplace Accounts.
4. Add Shopee.
5. Keep environment `Testing`.
6. Generate a new auth link.
7. Confirm diagnostics show:
   - environment `testing`
   - credential source `testing`
   - no fallback credential
   - redirect configured
8. Open that new link only.
9. If Shopee still returns `error_sign`, the `SHOPEE_TEST_PARTNER_KEY` does not match the `SHOPEE_TEST_PARTNER_ID` or sandbox host.
10. If Shopee returns `invalid_partner_id`, the partner id does not belong to that host/environment.

### Flutter UI / Theme Status

Verified changes:

- `lib/main.dart` now follows `AppThemeModeController` for light/dark mode.
- `lib/core/theme/app_theme.dart` has separate light and dark themes.
- `lib/features/dashboard/presentation/dashboard_page.dart` desktop content starts at `left: 316`, so it no longer covers sidebar hit testing.
- Sidebar itself uses `Expanded(ListView(...))`; content uses its own `ListView`.
- Local web smoke:
  - Desktop login clean, console errors `0`.
  - Mobile login clean at `390x844`, console errors `0`.

Limitation:

- Authenticated web sidebar click/scroll still needs a valid logged-in browser session or test credential. Local/Vercel smoke only reached login because no web session credential was available in this run.

## What Was Implemented In This Pass

### Shopee Auth Strict Environment

Patched deploy bundle:

- `C:\Users\budic\Downloads\finance_patch40_pagination_free_plan_bundle\FINAL_STABLE\supabase\functions\marketplace-auth-start\index.ts`
- `C:\Users\budic\Downloads\finance_patch40_pagination_free_plan_bundle\FINAL_STABLE\supabase\functions\marketplace-shopee-callback\index.ts`

Changes:

- Testing requires `SHOPEE_TEST_PARTNER_ID` and `SHOPEE_TEST_PARTNER_KEY`.
- Production requires `SHOPEE_PARTNER_ID` and `SHOPEE_PARTNER_KEY`.
- Removed Testing fallback to production credentials.
- Auth-start diagnostic now includes safe fields:
  - `shopee_host`
  - `shopee_credential_source`
  - `shopee_partner_id_masked`
  - `shopee_redirect_uri_configured`
  - `shopee_used_fallback_credential`
- Callback token exchange resolves credentials from OAuth state environment.
- Callback raw token diagnostic includes environment, host, credential source, and fallback flag.

Shopee troubleshooting:

- `invalid_partner_id` on production host usually means a sandbox/testing partner id was used against production.
- `error_sign` usually means partner id/key/host/signing string do not match, or the URL was generated with stale/wrong credential.
- For developing Shopee app, generate the link with environment `testing`.
- Required Testing secrets:
  - `SHOPEE_TEST_PARTNER_ID`
  - `SHOPEE_TEST_PARTNER_KEY`
  - Optional `SHOPEE_TEST_HOST`, default should be `https://partner.test-stable.shopeemobile.com`
  - `SHOPEE_TEST_REDIRECT_URI` or `SHOPEE_REDIRECT_URI`
- Required Production secrets:
  - `SHOPEE_PARTNER_ID`
  - `SHOPEE_PARTNER_KEY`
  - Optional `SHOPEE_HOST`, default should be `https://partner.shopeemobile.com`
  - `SHOPEE_REDIRECT_URI`

Shopee usage steps for the user:

1. Open Marketplace Accounts.
2. Choose Shopee.
3. Keep environment as Testing while Shopee app status is developing.
4. Generate auth link.
5. Confirm diagnostic shows environment Testing, credential source Testing, masked partner id, and redirect configured.
6. Open auth link and authorize the sandbox/dev shop.
7. Callback should land on `marketplace-connected.html`.
8. After account is stored, run product/order/stock/return sync through the existing generic marketplace actions.

### Flutter Marketplace Accounts UI

Patched:

- `lib/features/marketplace/services/marketplace_service.dart`
- `lib/features/marketplace/presentation/marketplace_accounts_page.dart`

Changes:

- `MarketplaceConnectLink` parses Shopee diagnostic fields.
- Shopee defaults to Testing in the UI.
- UI warning explains developing Shopee accounts must use Testing/Sandbox.
- UI displays credential source and masked partner id after link generation.
- UI warns when redirect URI is not configured.
- Old fallback wording was replaced with strict-mode wording.

### Shell / Sidebar Hit-Test Fix

Patched:

- `lib/features/dashboard/presentation/dashboard_page.dart`

Changes:

- Desktop/tablet content layer is now positioned to the right of the sidebar.
- Content no longer covers sidebar hit-test area.
- Sidebar and content can scroll independently in the existing shell structure.
- Page background now follows light/dark theme gradient.

Important: web-authenticated menu smoke still needs a logged-in web session to verify actual sidebar click/scroll after login. Device smoke did verify the authenticated Finance screen renders.

### Theme Cleanup

Patched:

- `lib/main.dart`
- `lib/core/theme/app_theme.dart`
- `lib/core/ui/app_ui.dart`
- `lib/features/marketplace/presentation/marketplace_job_monitor_page.dart`
- `lib/features/auth/presentation/login_page.dart`

Changes:

- App no longer forces light mode.
- `ThemeMode` follows `AppThemeModeController` visual mode.
- `AppTheme.lightTheme` and `AppTheme.darkTheme` are separated.
- `AppTheme.manTheme` remains as alias to avoid breaking existing screens.
- Removed global `ColorFiltered` inversion from `AppGlobalBackdrop`.
- Added `darkPageGradient` and `pageGradientFor(context)`.
- Added `canvasColor` and `popupMenuTheme` to reduce dropdown/menu contrast bugs.
- Fixed marketplace job monitor card/log text contrast.
- Fixed login form width constraints for smaller web/mobile viewports.

### Separator Nominal Global

Patched:

- `lib/core/ui/app_ui.dart`
- `lib/features/finance/presentation/finance_report_page.dart`
- `lib/features/production/presentation/stock_progress_page.dart`
- `lib/features/stock/presentation/product_form_page.dart`
- `lib/features/marketplace/presentation/marketplace_sku_mapping_page.dart`

Changes:

- Display money uses Indonesian Rupiah style through `AppUi.rupiah`, for example `Rp 411.635.406`.
- Money input formatter preserves cursor based on digit position.
- Finance `_money(num)` delegates to `AppUi.rupiah`.
- Finance local thousands formatter delegates to `AppMoneyInputFormatter`.
- Production running forms now format:
  - harga jahit per pcs
  - deposit
  - kasbon
  - pembayaran jahit
  - pembelian bahan/barang item price
- Product HPP default input now formats with thousands separators and parses back to numeric.
- Marketplace SKU Mapping HPP input/display now uses thousands separators/Rupiah parser.

## Build / Smoke Evidence

Commands run successfully:

- `flutter analyze --no-fatal-infos --no-fatal-warnings`
  - Result: exit 0.
  - Remaining baseline analyzer output: 508 info/deprecation/style items.
- `flutter build web --release`
  - Result: built `build\web`.
  - Note: Flutter warned about Cupertino icon font asset not found; build still succeeded.
- `flutter build apk --debug`
  - Result: built `build\app\outputs\flutter-apk\app-debug.apk`.
- Installed APK to physical Android device:
  - Device id: `FAYXUG4PRKKV4DPV`
  - Package: `com.example.inventory_control_apps`
  - Install result: Success.
- Supabase Edge deploy/list:
  - `marketplace-auth-start` deployed and active.
  - `marketplace-shopee-callback` deployed and active.

Smoke screenshots created in workspace:

- `inventory_smoke_20260605_wait2.png`
  - Authenticated device screen opened Finance page.
  - Money visible with separators, e.g. `Rp 411.635.406`, `Rp 132.789.048`, `Rp 93.699.000`.
- `web_smoke_desktop_20260605_loginfix.png`
  - Web login desktop renders.
- `web_smoke_mobile_20260605_final.png`
  - Web login mobile headless renders, but headless Chrome appears to crop/shift viewport to the right. Recheck in real browser/devtools mobile mode.

Security / deployment note:

- `build\web\.env.local` appeared from a previous build/deploy artifact and was removed before final static smoke.
- `build\web` final check had no `.env*` files.
- Before any web deploy, verify no `.env*` files are present in the static output.

## Still Needs Follow-Up

### Web Authenticated Smoke

Need a logged-in web session or test credential to verify:

- Sidebar click and scroll on desktop/tablet dashboard after login.
- All authenticated menus open after shell hit-test fix.
- Dark/light contrast on all menu forms/dropdowns.
- Bottom navigation on mobile authenticated pages.

### Shopee Live Auth Test

Need user/Shopee dev-shop action:

1. Confirm Supabase Secrets for Testing are present.
2. Generate Shopee Testing link from UI.
3. Open link.
4. If Shopee returns error:
   - `invalid_partner_id`: check testing id is used with testing host.
   - `error_sign`: check testing key, host, and generated timestamp/sign.
5. Confirm callback creates marketplace account row.
6. Then test product pull, order pull, stock sync, and return/refund pull.

### UI Remaining Work

Continue a full authenticated UI sweep:

- Dashboard/Analytics
- Stock
- Marketplace
- Finance
- Produksi Berjalan
- Pembelian
- Supplier
- Attendance
- Task
- HR
- Live
- Content
- Admin

For each menu:

- Open page in light and dark mode.
- Open add/edit bottom sheet/dialog.
- Open dropdowns.
- Check empty/loading/error states.
- Check mobile width does not overflow.
- Verify all money input fields use `AppMoneyInputFormatter`.
- Verify all money displays use `AppUi.rupiah` or equivalent Indonesian separator format.

### Production / Refund Continuation

Keep previous feature plan in force:

- Produksi Berjalan ledger monthly flow with deposit awal, penjahit, kasbon, payments, purchases, evidence, edit/delete/reset/export Excel.
- Deposit awal is separate from tambah produksi and is reduced by paid sewing/payment/kasbon/purchases.
- Finance only receives paid production expenses; unpaid remains production recap only.
- Refund scan resi must search globally across tenant database, not just visible rows.
- Size breakdown must use local SKU mapping/core local product stock.

## Recommended Next Commands

```powershell
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter build web --release
flutter build apk --debug
supabase functions list --project-ref tllknfqoczarogizheal
```

For web deploy, first verify:

```powershell
Get-ChildItem -Path build\web -Force | Where-Object { $_.Name -like '.env*' }
```

The result must be empty before publishing.
