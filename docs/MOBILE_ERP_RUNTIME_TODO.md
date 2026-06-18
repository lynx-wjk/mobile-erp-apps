# MOBILE ERP Runtime TODO Tracker

This file is the active runtime backlog. Keep this list in every handoff until each item is explicitly closed.

## P0 - Active failures
- Finance Dashboard chart does not render on initial dashboard.
- Finance local cache must render fast on first load and then refresh in background.
- Finance SKU settled tab is still partial.
- Laba Rugi marketplace breakdown is visible but numbers require validation.
- Cashflow/biaya is still double in UI although backend duplicate probe is clean.
- Marketplace HPP cards show 0 even when backend by_marketplace has hpp_total/total_hpp.
- Stock Out marketplace must search by physical shipping-label resi/tracking number only.
- Order page must not show OFG/package/order reference as Stock Out resi.

## P1 - Required next work
- Marketplace Job Monitoring must be a dedicated page for order/finance/product/retention/bootstrap dispatchers.
- Token refresh audit final for product/order/finance across Shopee and TikTok.
- Incremental order status validation after cron settle.
- Incremental payout/finance validation after cron settle.
- Repo hygiene: archive audit/temp/scripts outside repo and review untracked migrations one by one.
- RPC cleanup dependency audit before any drop.
- Cleanup sarcastic/satire wording in UI/docs/source/logs.
- Regression check old modules: upload evidence, demo read-only, stock in/out normal, finance purchases/expenses, refund/return.

## Hard rules
- No git add .
- No new RPC/function version unless explicitly approved.
- Overwrite existing canonical wrappers/functions when possible.
- No audit/tmp/log/env/secret/tar/zip commits.
- Self-host Docker/psql only.
- Product pull manual/onboarding only, not cron.
- 90-day finance/order scope.
- HPP and target margin from HPP mapping, not SKU mapping.
- SKU mapping only variant to local SKU/product/barcode/sync settings.

## 2026-06-19 remaining runtime patch
- Dashboard Finance chart visibility no longer depends on finance trend being non-empty.
- Dashboard Finance chart visibility no longer depends only on plan gate for owner/super-admin/admin/finance roles.
- Finance SKU loader now pulls all pages from existing finance_sku_order_details for settled and unpaid filters.
- Physical resi backfill tries to extract true tracking/AWB/waybill keys from raw marketplace JSON and explicitly excludes OFG/package/order references.

## 2026-06-19 chart sku pl ui follow-up
- Dashboard Finance chart must show full month-to-date range, not only sparse non-zero backend dates.
- SKU merge must preserve settled qty/payout/HPP when settled and unpaid rows share the same SKU key.
- Laba Rugi marketplace breakdown must use compact per-marketplace cards, not the old reconciliation matrix table.
- Order status/resi settle requires cron/logistics audit; Shopee physical resi remains 0 until logistics/AWB pull fills it.

## 2026-06-19 active handoff reminder
P0 still active:
- Finance daily chart source must be fixed from actual daily transaction/order/finance data; chart UI alone is not enough.
- SKU settled/HPP row-level must be fixed; HPP/item Rp 0 on settled rows means mapping/join source is still wrong.
- Shopee physical resi is not available from order pull yet; do not fallback to OFG/long package/order references.
- Order status/logistics update job must be validated and patched after cron/logistics audit.
- Laba Rugi card layout is improved but final formula/label validation remains.
- Cashflow double requires regression check.

P1 still active:
- Dedicated Marketplace Job Monitoring page.
- Token refresh audit for product/order/finance Shopee and TikTok.
- Incremental order+payout settle validation.
- Repo hygiene and migration review.
- RPC cleanup dependency audit before any drop.
- Cleanup sarcastic/satire wording in UI/docs/source.
- Regression: upload evidence, demo read-only, stock in/out, purchases/expenses, refund/return.
- Detail SKU sample rows after SKU/HPP base is correct.
