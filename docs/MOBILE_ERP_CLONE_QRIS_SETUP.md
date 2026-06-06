# mobile_erp Clone And QRIS Subscription Setup

## Current State

- Local clone path: `C:\Users\budic\Downloads\android\mobile_erp`
- Supabase project name: `mobile_erp`
- Supabase project ref: `qmmrjzlgaozwazxkvoxn`
- Supabase URL: `https://qmmrjzlgaozwazxkvoxn.supabase.co`
- Region: `ap-southeast-1`
- Status: `ACTIVE_HEALTHY`
- Applied migrations:
  - `subscription_entitlements_baseline_mobile_erp_v1`
  - `subscription_qris_payment_baseline_mobile_erp_v1`

The clone is separate from
`C:\Users\budic\Downloads\android\inventory_control_apps`; do not overwrite the
current production app while building subscription features.

## Subscription Plans

Use three monthly plans:

| Plan ID | Label | Core Scope |
| --- | --- | --- |
| `wms` | WMS Only | Warehouse, barcode stock in/out, stock history, low stock |
| `finance` | Finance Only | Finance report, manual expense/payment, finance export |
| `full` | Full ERP | WMS, marketplace, production, finance, analytics, export/audit |

The current baseline tables in `mobile_erp` are:

- `subscription_plans`
- `tenant_subscriptions`
- `feature_entitlements`
- `usage_counters`

The baseline is intentionally additive and RLS-enabled. Payment-specific tables
are already added to the clone project, but Edge Functions and gateway secrets
still need to be wired before accepting real payments.

## Database Clone Runbook

The source project is:

```text
tllknfqoczarogizheal
```

The target clone project is:

```text
qmmrjzlgaozwazxkvoxn
```

### Option A - Supabase CLI Dump/Restore

This is the preferred route once Docker Desktop is available locally.

1. Install/start Docker Desktop.
2. Link the source project.

```powershell
supabase link --project-ref tllknfqoczarogizheal
```

3. Dump schema and data.

```powershell
New-Item -ItemType Directory -Force mobile_erp_clone
supabase db dump --schema public --file mobile_erp_clone\source_schema.sql --linked --yes
supabase db dump --data-only --schema public --use-copy --file mobile_erp_clone\source_data.sql --linked --yes
```

4. Link the target project.

```powershell
supabase link --project-ref qmmrjzlgaozwazxkvoxn
```

5. Restore schema and data into the target database using the target database
   connection string from Supabase Dashboard.

```powershell
psql "<TARGET_DATABASE_URL>" -v ON_ERROR_STOP=1 -f mobile_erp_clone\source_schema.sql
psql "<TARGET_DATABASE_URL>" -v ON_ERROR_STOP=1 -f mobile_erp_clone\source_data.sql
```

6. Re-apply clone-only migrations if the restore replaced the subscription
   baseline.

```powershell
supabase db push --linked --include-all
```

### Option B - Schema First, Data Later

Use this when the marketplace/order tables are too large for a first clone:

1. Restore schema only.
2. Seed tenant, roles, users, products, suppliers, and WMS tables.
3. Leave marketplace order/finance history empty.
4. Pull marketplace data fresh after Shopee/TikTok accounts are reconnected.

This is safer for a subscription SaaS clone because each tenant starts clean,
while source production data remains untouched.

## QRIS Gateway Choice

Recommended first provider: Midtrans. It has QRIS support and a common webhook
flow for Indonesian payments.

Other viable providers:

- Xendit QR Codes for QRIS-style QR payments.
- Tripay payment channels if the account approval and fee model fit better.

Official docs to review before production:

- Midtrans QRIS reference: `https://docs.midtrans.com/reference/qris`
- Xendit QR Codes docs: `https://docs.xendit.co/`
- Tripay developer docs: `https://tripay.co.id/developer`

## Payment Architecture

The clone project has these payment tables:

- `subscription_invoices`
- `subscription_payments`
- `payment_webhook_events`

Suggested invoice fields:

- `subscription_invoice_id`
- `tenant_id`
- `plan_id`
- `amount`
- `currency`
- `period_start`
- `period_end`
- `status`: `pending`, `paid`, `expired`, `cancelled`, `failed`
- `gateway`: `midtrans`, `xendit`, or `tripay`
- `gateway_order_id`
- `qr_string`
- `qr_image_url`
- `paid_at`
- `expires_at`

Suggested Edge Functions:

- `subscription-create-qris-invoice`
- `subscription-payment-webhook`
- `subscription-expire-overdue-invoices`

Security rules:

- `subscription-create-qris-invoice` requires user JWT.
- `subscription-payment-webhook` does not require user JWT, but must verify the
  gateway signature/server key before updating any payment.
- Gateway server keys stay only in Supabase Edge Function secrets.
- Flutter receives only invoice status, QR payload/image, and public payment
  instructions.

## Step By Step QRIS Flow

1. User opens subscription page.
2. User selects `wms`, `finance`, or `full`.
3. Flutter calls `subscription-create-qris-invoice`.
4. Edge Function validates tenant/user and selected plan.
5. Edge Function creates a local `subscription_invoices` row with `pending`.
6. Edge Function creates QRIS payment at the gateway.
7. Edge Function saves `gateway_order_id`, QR data, `expires_at`, and payment
   payload snapshot.
8. Flutter displays the QR image/string and starts polling invoice status.
9. Gateway sends webhook to `subscription-payment-webhook`.
10. Webhook verifies signature and amount.
11. Webhook marks invoice/payment `paid`.
12. Webhook upserts `tenant_subscriptions` with:
    - `plan_id`
    - `status = active`
    - `current_period_start`
    - `current_period_end`
13. Flutter refreshes entitlements and unlocks the plan.
14. If no paid renewal exists after period end, scheduled job marks tenant
    subscription `expired` or locked.

## Environment Secrets

Use one gateway first. Example for Midtrans:

```text
MIDTRANS_SERVER_KEY=
MIDTRANS_CLIENT_KEY=
MIDTRANS_IS_PRODUCTION=false
SUBSCRIPTION_PAYMENT_WEBHOOK_SECRET=
```

For production, switch `MIDTRANS_IS_PRODUCTION=true` only after webhook smoke
tests pass in sandbox.

## CI/CD For mobile_erp

Use the same workflow pattern as the source app:

- Flutter CI for analyze/debug APK.
- Android release candidate on version tag.
- Vercel Web Deploy with a separate Vercel project and alias for `mobile_erp`.

Do not reuse `operational-management-app-two.vercel.app` for the clone. Create a
new Vercel project/domain for `mobile_erp`.
