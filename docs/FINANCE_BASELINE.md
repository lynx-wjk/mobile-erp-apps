# Finance Baseline Documentation

**Project:** Stock Role Management App (Flutter + Supabase)  
**Last Updated:** 2026-06-07  
**Author:** Antigravity AI (Gemini DeepMind)

---

## 1. Active RPC Function

| Field | Value |
|:------|:------|
| **Function Name** | `public.finance_customer_dashboard_snapshot_v24_6_82o` |
| **Language** | `plpgsql` |
| **Security** | `SECURITY DEFINER` |
| **Returns** | `jsonb` |
| **File** | [`patch_snapshot.sql`](../patch_snapshot.sql) |

### Parameters

| Parameter | Type | Default | Description |
|:----------|:-----|:--------|:------------|
| `p_start` | `date` | today | Period start date (WIB) |
| `p_end` | `date` | today | Period end date (WIB) |
| `p_marketplace` | `text` | `null` | Filter by marketplace name (e.g. `tiktok_shop`) |
| `p_account_id` | `uuid` | `null` | Filter by marketplace account ID |

---

## 2. Data Sources

| Source Table | Description |
|:-------------|:------------|
| `public.marketplace_orders` | Order data — used for Omzet calculation |
| `public.marketplace_order_items` | SKU item data per order — used for HPP calculation |
| `public.marketplace_finance_reports` | Raw finance settlement — used for Payout calculation |
| `public.marketplace_variant_hpp_mappings` | SKU → HPP mapping table |

---

## 3. Calculation Logic

### Omzet
- Source: `marketplace_orders`
- Filter: `gross_amount OR paid_amount > 0`, valid order statuses, within date range (WIB) with ±2 day buffer
- Formula: `sum(greatest(gross_amount, paid_amount))`

### Payout
- Source: `marketplace_finance_reports`
- Filter: `period_start` within date range
- Formula: `sum(payout_amount OR received_amount OR net_settlement)`

### Settled HPP (HPP)
- Source: SKU items joined to orders that have a positive payout in the period
- Formula: `sum(paid_qty * hpp_per_item)`
- Where `paid_qty = sum(item.qty)` for orders with `order_payout > 0`

### Est. HPP Belum Payout (Unpaid HPP)
- Source: SKU items joined to orders with zero or no payout in the period
- Formula: `sum(unpaid_qty * hpp_per_item)`
- Where `unpaid_qty = sum(item.qty)` for orders with `order_payout <= 0`

### Laba Bersih (Net Profit)
- Formula: `payout - settled_hpp - expenses`
- If `payout = 0`, net_profit is forced to 0

### Abnormal (Payout Minus)
- Source: `marketplace_finance_reports` rows where `payout_amount < 0`
- Summary: count + signed total
- Detail: paginated (top 20 shown inline, rest paginated from Flutter)

---

## 4. Verified Baselines

### June 2026 (2026-06-01 to 2026-06-30)

| Metric | Value |
|:-------|:------|
| Omzet | Rp 79.620.825 |
| Orders | 1.215 |
| Payout | Rp 6.312.694 |
| Settled HPP | Rp 4.263.000 |
| Est. HPP Belum Payout | Rp 38.936.500 |
| Laba Bersih | Rp 2.049.694 |
| Margin Net | 32.47% |
| Abnormal count | 1 |
| Payout Minus | -Rp 7.595 |

### May 2026 (2026-05-01 to 2026-05-31)

| Metric | Value |
|:-------|:------|
| Omzet | Rp 365.440.666 |
| Orders | 5.444 |
| Payout | Rp 182.045.707 |
| Settled HPP | Rp 118.816.000 |
| Est. HPP Belum Payout | Rp 68.777.000 |
| Laba Bersih | Rp 63.229.707 |
| Margin Net | 34.73% |
| Abnormal count | 247 |
| Payout Minus | -Rp 5.048.487 |

---

## 5. How to Apply / Redeploy

```bash
# 1. Apply the SQL patch
supabase db query --linked -f patch_snapshot.sql

# 2. Reload PostgREST schema (REQUIRED after any function change)
supabase db query --linked "NOTIFY pgrst, 'reload schema';"

# 3. Verify
supabase db query --linked "select (public.finance_customer_dashboard_snapshot_v24_6_82o('2026-05-01','2026-05-31') ->> 'summary')::jsonb;"
```

> [!IMPORTANT]
> Always run `NOTIFY pgrst, 'reload schema';` after applying the SQL patch. PostgREST caches the schema and will serve stale function signatures until notified.

---

## 6. Constraints & Rules

- **No new RPC versions** — always overwrite `finance_customer_dashboard_snapshot_v24_6_82o`
- **No new Edge Functions** — all logic stays in the database function
- **Finance data limit** — maximum 90-day lookback from Flutter
- **Local cache** — Flutter uses local cache first, server refresh updates cache
- **Pagination** — SKU, Abnormal, order refs are paginated; summary aggregates are not
- **Date timezone** — all dates use `Asia/Jakarta` (WIB, UTC+7)
- **Naming** — use "Abnormal" (not "anomali") for negative payout items

---

## 7. Key Flutter Files (do not refactor UI)

| File | Description |
|:-----|:------------|
| `lib/features/finance/` | Finance page and dashboard widgets |
| `lib/features/dashboard/` | Main dashboard showing finance summary |
| `lib/core/services/` | Supabase client and cache services |
