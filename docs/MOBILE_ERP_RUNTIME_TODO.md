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
