# Marketplace Service Contracts

This is the canonical marketplace integration entrypoint for new providers.
Shopee must be implemented behind these existing contracts, not by adding a
new Flutter-only service chain.

Active provider IDs:

- `tiktok_shop`
- `shopee`

Active Edge Functions used by Flutter:

- `marketplace-auth-start`
- `marketplace-product-pull`
- `marketplace-order-pull`
- `marketplace-stock-sync-worker`
- `marketplace-order-sync-jobs`
- `marketplace-return-refund-pull`

Rules:

- Send `marketplace = shopee` for Shopee.
- Store Shopee rows in the same marketplace tables/views where possible.
- Shopee OAuth callback stays on Supabase:
  `https://tllknfqoczarogizheal.supabase.co/functions/v1/marketplace-shopee-callback`.
- Vercel is only the result page through `MARKETPLACE_CONNECT_RESULT_URL`.
- Keep order pulls paginated and recent-window based. User-facing order,
  finance, and refund/cancel ranges default to 90 days / 3 months.
- Manual order pulls are capped at 90 days. Return/refund pull defaults to 90
  days. The auto order pull setting stores `days_back = 90` and
  `previous_unpacked_days = 90`.
- Marketplace/finance operational data older than 90 days is purged by
  `cleanup_marketplace_finance_older_than_90_days`; product, local stock,
  production, and master data are not part of that retention cleanup.
- Refresh non-completed order status; skip completed orders by default.
- Refund/Cancel Monitor must not expose HPP in list or detail views.
- Do not create bridge RPCs, versioned wrappers, table drops, or business-data
  deletes.

The legacy `docs/TIKTOK_SERVICE_ACTIONS.md` file now contains the expanded
payload examples for these generic contracts and should not be treated as a
TikTok-only integration guide anymore.
