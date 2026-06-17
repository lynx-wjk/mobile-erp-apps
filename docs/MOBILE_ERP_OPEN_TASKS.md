# MOBILE ERP Open Tasks

Status after marketplace historical-import recovery.

## Done
- Historical Shopee and TikTok finalize completed.
- Product pull smoke inserts product and variant snapshots.
- Incremental order dispatcher smoke returns 200.
- Finance dispatcher smoke returns 200 when no pending finance window exists.
- Fast order list RPC hotfix installed.
- HPP sync from SKU mapping helper installed.

## Open
- Finish Excel SKU mapping export/import visibility if it is not visible on the deployed build.
- Populate SKU mapping and HPP mapping, then validate Finance.
- Fix Finance dashboard policy after HPP mappings are populated.
- Add analytics finance card to Flutter Web dashboard.
- Build dedicated marketplace job monitor page.
- Audit unused RPCs before deletion.
- Remove unprofessional wording from code, docs, and UI.
- Confirm refresh-token behavior for Shopee and TikTok product/order/finance paths.
- Confirm order status and payout incremental update cadence after cron settles.
