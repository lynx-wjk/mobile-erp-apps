# Handoff Report — Explorer 1 (Backend SQL Specialist)

## 1. Observation

### A. Current Implementation of `finance_sku_order_line_details`
In `supabase/migrations/20260724120000_fix_laba_rugi_breakdown_and_sku_details.sql` (and `20260721000000_finance_sku_details_resi.sql`):
1. **Hardcoded Exclusion in Root CTE (`valid_orders`)**:
   - At lines 333–337 of `finance_sku_order_details_v24_6_82o`:
     ```sql
     and not (
       upper(coalesce(o.order_status, o.status, o.raw_order->>'status', '')) like any (
         array['%CANCEL%', '%REFUND%', '%RETURN%', '%FAILED%', '%CLOSE%']
       )
     )
     ```
     This clause strips all returned, cancelled, and refunded orders at the first CTE level.
2. **Lack of `returned` Filter Handling**:
   - At lines 309–315:
     ```sql
     if v_payout_filter in ('settled', 'sudah_payout', 'sudah payout', 'sudah ada payout', 'paid') then
       v_payout_filter := 'paid';
     elsif v_payout_filter in ('belum_payout', 'belum payout', 'belum ada payout', 'pending', 'unpaid') then
       v_payout_filter := 'unpaid';
     elsif v_payout_filter in ('all', 'semua', '') then
       v_payout_filter := 'all';
     end if;
     ```
     `v_payout_filter = 'returned'` is not mapped or recognized.
3. **Filtering in `filtered_rows`**:
   - At lines 521–525:
     ```sql
     where (
       v_payout_filter = 'all'
       or (v_payout_filter = 'paid' and coalesce(c.payout_allocated, 0) <> 0 and c.payout_status_clean <> 'Cancel/Refund/Return')
       or (v_payout_filter = 'unpaid' and coalesce(c.payout_allocated, 0) = 0 and c.payout_status_clean <> 'Cancel/Refund/Return')
     )
     ```
     There is no condition for `v_payout_filter = 'returned'`.
4. **Missing `is_returned` Flag**: The output row JSON lacks `'is_returned'`, making it impossible for frontends or callers to distinguish return status cleanly.

---

### B. Current Implementation of `finance_sku_order_details_group_20260625`
In `supabase/migrations/20260725460000_drop_overloaded_sku_group_function.sql` (and `20260725450000_optimize_finance_sku_order_details_group.sql`):
1. **Hardcoded Exclusion in `valid_orders`**:
   - At lines 71:
     ```sql
     and not (lower(concat_ws(' ', o.order_status, o.status, o.raw_order->>'status')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)')
     ```
2. **Omission of Return and Unsettled Metrics in Aggregates**:
   - In `grouped` CTE (lines 185–204), the function only computes `total_qty`, `total_omzet`, `total_payout`, `total_hpp`, and `net_profit`.
   - It completely omits:
     - `qty_settled` (`paid_qty`)
     - `qty_unsettled` (`unpaid_qty`)
     - `unpaid_hpp`
     - `qty_returned` (`returned_qty`)
     - `hpp_return`
     - `settled_hpp`
3. **Frontend Expectation in `finance_report_page.dart`**:
   - Lines 10525–10565:
     ```dart
     int paidQtyDisplay = _numFirstNonZero([row['paid_qty_total'], row['settled_qty_total'], row['paid_qty'], row['settled_qty'], ...]);
     int unpaidQtyDisplay = _numFirstNonZero([row['unpaid_qty'], row['qty_unpaid'], row['qty_belum_payout'], ...]);
     int returnedQtyDisplay = _numFirstNonZero([row['qty_returned'], row['returned_qty'], row['qty_batal'], row['batal_qty']]);
     double hppReturnDisplay = _numFirstNonZero([row['hpp_return'], row['hpp_retur'], row['return_hpp'], row['batal_hpp']]);
     ```
     Because the RPC returns 0 or null for `qty_returned` and `hpp_return`, the Retur/Batal count badge and buttons remained at 0 or failed to open rows.

---

### C. Deployment Mechanism
- Migrations are saved under `supabase/migrations/YYYYMMDDHHMMSS_<name>.sql`.
- Deployed to the self-hosted Postgres database inside the Docker container on VPS via:
  ```powershell
  Get-Content supabase/migrations/YYYYMMDDHHMMSS_<name>.sql | ssh inventory-vps "docker exec -i supabase-db psql -U postgres -d postgres"
  ```
  or directly via `vps_ssh` MCP tool.

---

## 2. Logic Chain

1. **Root Cause of Empty Retur/Batal Detail Modal (R1)**:
   - When the user clicks the "Retur/Batal" button, the Flutter client calls `finance_sku_order_line_details` with `p_payout_filter = 'returned'`.
   - Because `valid_orders` unconditionally filtered out any order whose status matched `cancel|batal|return|refund|failed|close`, zero rows survived.
   - Removing this hardcoded exclusion in `valid_orders`, classifying `is_returned := true` when `lower(concat_ws(' ', status, order_status, ...)) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)'`, and adding `or (v_payout_filter = 'returned' and c.is_returned)` in `filtered_rows` guarantees that all returned/cancelled order items are retrieved with complete order details (order SN, tracking number / resi, product name, variant name, gross amount, unit price, and HPP).

2. **Root Cause of Pending Payout Contamination (R2)**:
   - Without explicit segregation in `finance_sku_order_details_group_20260625`, cancelled/returned orders either disappear or risk inflating pending payout metrics.
   - To strictly enforce R2, aggregate metrics per SKU must be partitioned as follows:
     - **Settled Orders**: `has_payout and not is_returned`
       - `qty_settled = sum(qty) filter (where has_payout and not is_returned)`
       - `settled_hpp = sum(qty * unit_hpp) filter (where has_payout and not is_returned)`
       - `total_hpp = settled_hpp`
       - `total_omzet = sum(gross_line) filter (where not is_returned)`
       - `total_payout = sum(payout_total) filter (where not is_returned)`
     - **Active Pending Orders (`unpaid_hpp`, `qty_unsettled`)**:
       - `qty_unsettled = sum(qty) filter (where not has_payout and not is_returned)`
       - `unpaid_hpp = sum(qty * unit_hpp) filter (where not has_payout and not is_returned)`
     - **Returned / Cancelled Orders (`hpp_return`, `qty_returned`)**:
       - `qty_returned = sum(qty) filter (where is_returned)`
       - `hpp_return = sum(qty * unit_hpp) filter (where is_returned)`
   - This ensures that `unpaid_hpp` and `qty_unsettled` NEVER contain cancelled/returned items, and all return costs are strictly captured under `hpp_return` and `qty_returned`.

---

## 3. Caveats

1. **Tenant Resolution**: Both RPCs rely on `public._tenant_rpc_current_tenant_id()` or `public.app_current_tenant_id_or_default()` to enforce tenant isolation. In unauthenticated direct psql queries during manual testing, `tenant_id` must be set or fall back to the default tenant (`00000000-0000-0000-0000-000000000001` or active tenant UUID).
2. **Negative Payouts on Returns**: Under the project rules, orders with negative payouts (penalties/shipping costs) have real API escrow rows (`has_payout = true`). Their COGS is classified under `settled_hpp`, and their negative payout is added into `payout_total` to reduce overall payout correctly.
3. **No Database Write During Survey**: As an explorer subagent in read-only survey mode, the SQL definition has been designed, verified against existing tables/columns, and documented below for the implementer agent to deploy.

---

## 4. Conclusion & Precise SQL Fix

Create a single migration file: `supabase/migrations/20260815020000_fix_finance_sku_retur_batal_and_unpaid_separation.sql` containing the exact SQL definitions below:

```sql
-- Migration: 20260815020000_fix_finance_sku_retur_batal_and_unpaid_separation.sql
-- Fixes Retur/Batal modal order details (R1) and enforces strict separation of pending payout vs returned/cancelled orders (R2)

-- 1. DROP and RECREATE finance_sku_order_line_details
CREATE OR REPLACE FUNCTION public.finance_sku_order_line_details(
  p_start date DEFAULT NULL::date,
  p_end date DEFAULT NULL::date,
  p_marketplace text DEFAULT NULL::text,
  p_account_id uuid DEFAULT NULL::uuid,
  p_marketplace_sku text DEFAULT NULL::text,
  p_local_sku text DEFAULT NULL::text,
  p_search text DEFAULT NULL::text,
  p_payout_filter text DEFAULT 'all'::text,
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 25
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '120s'
AS $function$
declare
  v_start date := coalesce(p_start, date_trunc('month', now() at time zone 'Asia/Jakarta')::date);
  v_end date := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);
  v_t_start timestamp with time zone := (v_start::text || ' 00:00:00+07')::timestamp with time zone;
  v_t_end timestamp with time zone := ((v_end + 1)::text || ' 00:00:00+07')::timestamp with time zone;
  v_tenant_id uuid := public._tenant_rpc_current_tenant_id();
  v_marketplace text := lower(trim(coalesce(p_marketplace, '')));
  v_payout_filter text := lower(trim(coalesce(p_payout_filter, 'all')));
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 25), 1), 200);
  v_offset integer := (v_page - 1) * v_page_size;

  v_marketplace_sku text := lower(trim(coalesce(p_marketplace_sku, '')));
  v_local_sku text := lower(trim(coalesce(p_local_sku, '')));
  v_search text := lower(trim(coalesce(p_search, '')));

  v_rows jsonb := '[]'::jsonb;
  v_total integer := 0;
  v_total_pages integer := 1;
begin
  if v_tenant_id is null then
    return jsonb_build_object('ok', false, 'error', 'tenant_id required');
  end if;

  if nullif(v_marketplace, '') is null or v_marketplace in ('all', 'semua', 'semua platform', '-', 'unknown', 'null') then
    v_marketplace := '';
  else
    v_marketplace := case
      when v_marketplace ~ 'tiktok' then 'tiktok_shop'
      when v_marketplace ~ 'shopee' then 'shopee'
      else regexp_replace(v_marketplace, '[^a-z0-9]+', '', 'g')
    end;
  end if;

  if v_payout_filter in ('settled', 'sudah_payout', 'sudah payout', 'sudah ada payout', 'paid', 'payout') then
    v_payout_filter := 'paid';
  elsif v_payout_filter in ('belum_payout', 'belum payout', 'belum ada payout', 'pending', 'unpaid') then
    v_payout_filter := 'unpaid';
  elsif v_payout_filter in ('returned', 'retur', 'batal', 'cancel', 'refund', 'return', 'cancelled', 'canceled') then
    v_payout_filter := 'returned';
  elsif v_payout_filter in ('all', 'semua', '') then
    v_payout_filter := 'all';
  end if;

  with valid_orders as (
    select
      o.tenant_id,
      o.marketplace_account_id,
      o.marketplace_order_id,
      o.marketplace,
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_key,
      coalesce(o.order_status, o.status, o.raw_order->>'status', '-') as order_status,
      (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta') as order_ts_wib,
      (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date as order_date_wib,
      coalesce(nullif(o.tracking_number, ''), nullif(o.raw_order->>'tracking_number', ''), '-') as tracking_number
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and (
        v_marketplace = ''
        or case
          when lower(coalesce(o.marketplace, '')) ~ 'tiktok' then 'tiktok_shop'
          when lower(coalesce(o.marketplace, '')) ~ 'shopee' then 'shopee'
          else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date between v_start and v_end
      -- Exclusions for cancel/return removed to include full records
  ),
  finance_payout_by_id as (
    select
      fr.marketplace_order_id,
      max(fr.settlement_status) as settlement_status,
      max(fr.statement_id) as statement_id,
      max(fr.finance_report_id::text) as finance_report_id,
      max(fr.period_start::text) as finance_at,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)) as payout_total
    from valid_orders vo
    join public.marketplace_finance_reports fr on fr.tenant_id = vo.tenant_id and fr.marketplace_order_id = vo.marketplace_order_id
    where fr.marketplace_order_id is not null
    group by fr.marketplace_order_id
  ),
  finance_payout_by_key as (
    select
      fr.order_id,
      max(fr.settlement_status) as settlement_status,
      max(fr.statement_id) as statement_id,
      max(fr.finance_report_id::text) as finance_report_id,
      max(fr.period_start::text) as finance_at,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)) as payout_total
    from valid_orders vo
    join public.marketplace_finance_reports fr on fr.tenant_id = vo.tenant_id and fr.order_id = vo.order_key
    where fr.order_id is not null
    group by fr.order_id
  ),
  order_payout_matched as (
    select
      vo.tenant_id,
      vo.marketplace_account_id,
      vo.marketplace_order_id,
      vo.marketplace,
      vo.order_key,
      vo.order_status,
      vo.order_ts_wib,
      vo.order_date_wib,
      vo.tracking_number,
      coalesce(fpi.payout_total, fpk.payout_total, 0) as payout_total,
      coalesce(fpi.settlement_status, fpk.settlement_status, '') as settlement_status,
      coalesce(fpi.statement_id, fpk.statement_id) as statement_id,
      coalesce(fpi.finance_report_id, fpk.finance_report_id) as finance_report_id,
      coalesce(fpi.finance_at, fpk.finance_at) as finance_at
    from valid_orders vo
    left join finance_payout_by_id fpi on fpi.marketplace_order_id = vo.marketplace_order_id
    left join finance_payout_by_key fpk on fpk.order_id = vo.order_key and fpi.payout_total is null
  ),
  order_items_filtered as (
    select
      opm.*,
      coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku_id,
      coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as marketplace_seller_sku,
      coalesce(nullif(trim(oi.mapped_local_sku),''), nullif(trim(oi.local_sku),''), nullif(trim(oi.seller_sku),''), nullif(trim(oi.marketplace_seller_sku),''), nullif(trim(oi.marketplace_sku_id),''), '-') as local_sku,
      coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1) as qty,
      coalesce(nullif(oi.product_name, ''), nullif(oi.marketplace_product_name, ''), nullif(oi.local_product_name, '')) as product_name,
      coalesce(nullif(oi.variant_name, ''), nullif(oi.marketplace_variant_name, ''), nullif(oi.variation_name, '')) as variant_name,
      greatest(
        coalesce(oi.gross_amount, 0),
        coalesce(oi.paid_amount, 0),
        coalesce(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1), 1)
      ) as gross_line
    from order_payout_matched opm
    join public.marketplace_order_items oi
      on oi.tenant_id = opm.tenant_id
     and oi.marketplace_order_id = opm.marketplace_order_id
    where (
      (v_marketplace_sku = '' and v_local_sku = '')
      or (v_marketplace_sku <> '' and (
        lower(coalesce(oi.marketplace_sku_id, oi.remote_sku_id, '')) = v_marketplace_sku
        or lower(coalesce(oi.marketplace_seller_sku, oi.seller_sku, '')) = v_marketplace_sku
        or lower(coalesce(oi.mapped_local_sku, oi.local_sku, '')) = v_marketplace_sku
      ))
      or (v_local_sku <> '' and (
        lower(coalesce(oi.mapped_local_sku, oi.local_sku, '')) = v_local_sku
        or lower(coalesce(oi.marketplace_seller_sku, oi.seller_sku, '')) = v_local_sku
        or lower(coalesce(oi.marketplace_sku_id, oi.remote_sku_id, '')) = v_local_sku
        or lower(coalesce(oi.product_name, '')) = v_local_sku
      ))
    )
    and (
      v_search = ''
      or lower(coalesce(opm.order_key, '')) like '%' || v_search || '%'
      or lower(coalesce(opm.tracking_number, '')) like '%' || v_search || '%'
      or lower(coalesce(oi.product_name, '')) like '%' || v_search || '%'
      or lower(coalesce(oi.variant_name, '')) like '%' || v_search || '%'
      or lower(coalesce(oi.local_sku, '')) like '%' || v_search || '%'
    )
  ),
  hpp_sku as (
    select lower(nullif(marketplace_sku_id, '')) as sku_id,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp,
           max(nullif(local_sku, '')) as mapped_local_sku
    from public.marketplace_variant_hpp_mappings
    where tenant_id = v_tenant_id and coalesce(is_active, true) = true and nullif(marketplace_sku_id, '') is not null
    group by 1
  ),
  hpp_seller as (
    select lower(nullif(marketplace_seller_sku, '')) as seller_sku,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp,
           max(nullif(local_sku, '')) as mapped_local_sku
    from public.marketplace_variant_hpp_mappings
    where tenant_id = v_tenant_id and coalesce(is_active, true) = true and nullif(marketplace_seller_sku, '') is not null
    group by 1
  ),
  hpp_local as (
    select lower(nullif(local_sku, '')) as local_sku,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp,
           max(nullif(local_sku, '')) as mapped_local_sku
    from public.marketplace_variant_hpp_mappings
    where tenant_id = v_tenant_id and coalesce(is_active, true) = true and nullif(local_sku, '') is not null
    group by 1
  ),
  enriched as (
    select
      d.*,
      coalesce(hs.mapped_local_sku, hsel.mapped_local_sku, hl.mapped_local_sku, d.local_sku) as live_local_sku,
      coalesce(hs.hpp, hsel.hpp, hl.hpp, 0)::numeric as unit_hpp,
      sum(nullif(d.gross_line, 0)) over (partition by d.marketplace_account_id, d.order_key) as gross_order_scope,
      sum(d.qty) over (partition by d.marketplace_account_id, d.order_key) as qty_order_scope
    from order_items_filtered d
    left join hpp_sku hs on hs.sku_id = lower(nullif(d.marketplace_sku_id, ''))
    left join hpp_seller hsel on hsel.seller_sku = lower(nullif(d.marketplace_seller_sku, ''))
    left join hpp_local hl on hl.local_sku = lower(nullif(d.local_sku, ''))
  ),
  allocated as (
    select
      e.*,
      case
        when coalesce(e.payout_total, 0) = 0 then 0
        when coalesce(e.gross_order_scope, 0) > 0 and e.gross_line > 0 then e.payout_total * e.gross_line / e.gross_order_scope
        when coalesce(e.qty_order_scope, 0) > 0 then e.payout_total * e.qty / e.qty_order_scope
        else e.payout_total
      end as payout_allocated
    from enriched e
  ),
  calculated as (
    select
      a.*,
      (
        lower(concat_ws(' ', a.order_status, a.order_key)) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)'
      ) as is_returned,
      case
        when lower(concat_ws(' ', a.order_status, a.order_key)) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)' then 'Cancel/Refund/Return'
        when coalesce(a.payout_allocated, 0) <> 0 then coalesce(nullif(a.settlement_status, ''), 'Settled')
        else 'Belum Payout'
      end as payout_status_clean,
      (a.payout_allocated - (a.qty * a.unit_hpp)) as net_margin_nominal,
      case
        when a.payout_allocated > 0 then round(((a.payout_allocated - (a.qty * a.unit_hpp)) / a.payout_allocated * 100)::numeric, 2)
        else 0
      end as net_margin_percent
    from allocated a
  ),
  filtered_rows as (
    select c.*, row_number() over (order by order_date_wib desc, order_key desc) as rn
    from calculated c
    where (
      v_payout_filter = 'all'
      or (v_payout_filter = 'paid' and coalesce(c.payout_allocated, 0) <> 0 and not c.is_returned)
      or (v_payout_filter = 'unpaid' and coalesce(c.payout_allocated, 0) = 0 and not c.is_returned)
      or (v_payout_filter = 'returned' and c.is_returned)
    )
  ),
  counted as (
    select count(*)::integer as total_count from filtered_rows
  ),
  paged as (
    select *
    from filtered_rows
    where rn > v_offset and rn <= v_offset + v_page_size
    order by rn
  )
  select
    (select total_count from counted),
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', md5(concat_ws('_', marketplace_account_id, order_key, marketplace_sku_id, live_local_sku)),
          'source', 'finance_sku_order_line_details',
          'order_id', order_key,
          'order_sn', order_key,
          'external_order_id', order_key,
          'order_date', order_date_wib,
          'order_created_at', order_date_wib,
          'created_time', order_date_wib,
          'created_at', order_date_wib,
          'finance_at', finance_at,
          'order_status', order_status,
          'status', order_status,
          'is_returned', is_returned,
          'payout_status', payout_status_clean,
          'settlement_status', payout_status_clean,
          'tracking_number', tracking_number,
          'resi', tracking_number,
          'marketplace', marketplace,
          'shop_name', marketplace,
          'marketplace_account_id', marketplace_account_id,
          'marketplace_sku_id', marketplace_sku_id,
          'marketplace_sku', marketplace_sku_id,
          'marketplace_seller_sku', marketplace_seller_sku,
          'local_sku', live_local_sku,
          'product_name', product_name,
          'variant_name', variant_name,
          'quantity', qty,
          'qty', qty,
          'gross_line', gross_line,
          'gross_amount', gross_line,
          'payout_amount', payout_allocated,
          'payout_allocated', payout_allocated,
          'net_settlement', payout_allocated,
          'received_amount', payout_allocated,
          'has_payout', (payout_allocated > 0 and not is_returned),
          'hpp', unit_hpp,
          'hpp_per_item', unit_hpp,
          'unit_hpp', unit_hpp,
          'hpp_total', qty * unit_hpp,
          'net_profit', net_margin_nominal,
          'profit', net_margin_nominal,
          'net_margin_nominal', net_margin_nominal,
          'net_margin_percent', net_margin_percent,
          'margin_percent', net_margin_percent,
          'statement_id', statement_id,
          'finance_report_id', finance_report_id
        ) order by rn
      ),
      '[]'::jsonb
    )
  into v_total, v_rows
  from paged;

  v_total := coalesce(v_total, 0);
  v_total_pages := greatest(ceil(v_total::numeric / v_page_size::numeric)::integer, 1);

  return jsonb_build_object(
    'ok', true,
    'source', 'finance_sku_order_line_details',
    'page', v_page,
    'page_size', v_page_size,
    'total', v_total,
    'total_count', v_total,
    'total_pages', v_total_pages,
    'rows', v_rows,
    'items', v_rows,
    'data', v_rows
  );
end;
$function$;


-- 2. RECREATE finance_sku_order_details_group_20260625 with strict return & unpaid metrics
CREATE OR REPLACE FUNCTION public.finance_sku_order_details_group_20260625(
  p_start date DEFAULT NULL::date,
  p_end date DEFAULT NULL::date,
  p_marketplace text DEFAULT NULL::text,
  p_account_id uuid DEFAULT NULL::uuid,
  p_search text DEFAULT NULL::text,
  p_payout_filter text DEFAULT NULL::text,
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 20
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
SET statement_timeout TO '120s'
AS $function$
declare
  v_start date := coalesce(p_start, current_date - 30);
  v_end date := coalesce(p_end, current_date);
  v_t_start timestamp with time zone := (v_start::text || ' 00:00:00+07')::timestamp with time zone;
  v_t_end timestamp with time zone := ((v_end + 1)::text || ' 00:00:00+07')::timestamp with time zone;
  v_tenant_id uuid := public._tenant_rpc_current_tenant_id();
  v_marketplace text := lower(trim(coalesce(p_marketplace, '')));
  v_search text := lower(trim(coalesce(p_search, '')));
  v_payout_filter text := lower(trim(coalesce(p_payout_filter, 'all')));
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := greatest(coalesce(p_page_size, 20), 1);
  v_offset integer := (v_page - 1) * v_page_size;
  v_res jsonb;

  v_total_sku_count integer := 0;
  v_total_orders_count integer := 0;
  v_total_qty_count integer := 0;
  v_total_omzet numeric := 0;
  v_total_payout numeric := 0;
  v_total_hpp numeric := 0;
  v_total_unpaid_hpp numeric := 0;
  v_total_hpp_return numeric := 0;
  v_total_qty_returned integer := 0;
  v_total_laba numeric := 0;
  v_items jsonb := '[]'::jsonb;
begin
  if v_tenant_id is null then
    return jsonb_build_object('ok', false, 'error', 'tenant_id required');
  end if;

  if nullif(v_marketplace, '') is null or v_marketplace in ('all', 'semua', 'semua platform', '-', 'unknown', 'null') then
    v_marketplace := null;
  else
    v_marketplace := case
      when v_marketplace ~ 'tiktok' then 'tiktok_shop'
      when v_marketplace ~ 'shopee' then 'shopee'
      else regexp_replace(v_marketplace, '[^a-z0-9]+', '', 'g')
    end;
  end if;

  if v_payout_filter in ('settled', 'sudah_payout', 'sudah payout', 'sudah ada payout', 'paid', 'payout') then
    v_payout_filter := 'paid';
  elsif v_payout_filter in ('belum_payout', 'belum payout', 'belum ada payout', 'pending', 'unpaid') then
    v_payout_filter := 'unpaid';
  elsif v_payout_filter in ('returned', 'retur', 'batal', 'cancel', 'refund', 'return', 'cancelled', 'canceled') then
    v_payout_filter := 'returned';
  elsif v_payout_filter in ('all', 'semua', '') then
    v_payout_filter := 'all';
  end if;

  with valid_orders as (
    select
      o.tenant_id,
      o.marketplace_order_id,
      o.marketplace_account_id,
      o.marketplace,
      o.external_order_id,
      o.order_sn,
      o.order_status,
      o.status,
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_key,
      (
        lower(concat_ws(' ', o.order_status, o.status, o.raw_order->>'status')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)'
      ) as is_returned
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and o.order_created_at >= v_t_start and o.order_created_at < v_t_end
      and (
        v_marketplace is null or
        case
          when lower(coalesce(o.marketplace, '')) ~ 'tiktok' then 'tiktok_shop'
          when lower(coalesce(o.marketplace, '')) ~ 'shopee' then 'shopee'
          else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
  ),
  finance_payout_by_id as (
    select
      fr.marketplace_order_id,
      max(fr.settlement_status) as settlement_status,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)) as payout_total
    from valid_orders vo
    join public.marketplace_finance_reports fr on fr.tenant_id = vo.tenant_id and fr.marketplace_order_id = vo.marketplace_order_id
    where fr.marketplace_order_id is not null
    group by fr.marketplace_order_id
  ),
  finance_payout_by_key as (
    select
      fr.order_id,
      max(fr.settlement_status) as settlement_status,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)) as payout_total
    from valid_orders vo
    join public.marketplace_finance_reports fr on fr.tenant_id = vo.tenant_id and fr.order_id = vo.order_key
    where fr.order_id is not null
    group by fr.order_id
  ),
  order_payout_matched as (
    select
      vo.tenant_id,
      vo.marketplace_account_id,
      vo.marketplace_order_id,
      vo.order_key,
      vo.order_status,
      vo.is_returned,
      coalesce(fpi.payout_total, fpk.payout_total, 0) as payout_total,
      coalesce(fpi.settlement_status, fpk.settlement_status, '') as settlement_status
    from valid_orders vo
    left join finance_payout_by_id fpi on fpi.marketplace_order_id = vo.marketplace_order_id
    left join finance_payout_by_key fpk on fpk.order_id = vo.order_key and fpi.payout_total is null
  ),
  hpp_sku as (
    select lower(nullif(marketplace_sku_id, '')) as sku_id,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where tenant_id = v_tenant_id and coalesce(is_active, true) = true and nullif(marketplace_sku_id, '') is not null
    group by 1
  ),
  hpp_seller as (
    select lower(nullif(marketplace_seller_sku, '')) as seller_sku,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where tenant_id = v_tenant_id and coalesce(is_active, true) = true and nullif(marketplace_seller_sku, '') is not null
    group by 1
  ),
  hpp_local as (
    select lower(nullif(local_sku, '')) as local_sku,
           max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
    from public.marketplace_variant_hpp_mappings
    where tenant_id = v_tenant_id and coalesce(is_active, true) = true and nullif(local_sku, '') is not null
    group by 1
  ),
  detail as (
    select
      opm.marketplace_order_id,
      opm.order_key,
      opm.order_status,
      opm.is_returned,
      opm.payout_total,
      opm.settlement_status,
      (opm.payout_total <> 0) as has_payout,
      coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku_id,
      coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1) as qty,
      coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as marketplace_seller_sku,
      coalesce(nullif(trim(oi.mapped_local_sku),''), nullif(trim(oi.local_sku),''), nullif(trim(oi.seller_sku),''), nullif(trim(oi.marketplace_seller_sku),''), nullif(trim(oi.marketplace_sku_id),''), 'Unmapped') as local_sku,
      coalesce(nullif(oi.product_name, ''), nullif(oi.marketplace_product_name, ''), nullif(oi.local_product_name, '')) as product_name,
      coalesce(nullif(oi.variant_name, ''), nullif(oi.marketplace_variant_name, ''), nullif(oi.variation_name, '')) as variant_name,
      greatest(
        coalesce(oi.gross_amount, 0),
        coalesce(oi.paid_amount, 0),
        coalesce(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1), 1)
      ) as gross_line,
      coalesce(hs.hpp, hsel.hpp, hl.hpp, 0)::numeric as unit_hpp
    from order_payout_matched opm
    join public.marketplace_order_items oi on oi.marketplace_order_id = opm.marketplace_order_id
    left join hpp_sku hs on hs.sku_id = lower(nullif(oi.marketplace_sku_id, ''))
    left join hpp_seller hsel on hsel.seller_sku = lower(nullif(oi.marketplace_seller_sku, ''))
    left join hpp_local hl on hl.local_sku = lower(nullif(coalesce(oi.mapped_local_sku, oi.local_sku), ''))
  ),
  classified as (
    select
      d.*,
      case
        when d.is_returned then 'Cancel/Refund/Return'
        when d.payout_total = 0 then 'Belum Payout'
        when d.payout_total < 0 then 'Payout Minus'
        else coalesce(nullif(d.settlement_status, ''), 'Settled')
      end as payout_status_clean
    from detail d
    where (
      v_search = ''
      or lower(d.local_sku) like '%' || v_search || '%'
      or lower(coalesce(d.marketplace_seller_sku, '')) like '%' || v_search || '%'
      or lower(coalesce(d.product_name, '')) like '%' || v_search || '%'
    )
  ),
  grouped as (
    select
      f.local_sku,
      max(f.marketplace_seller_sku) as marketplace_seller_sku,
      max(f.marketplace_sku_id) as marketplace_sku_id,
      max(f.product_name) as product_name,
      max(f.variant_name) as variant_name,
      max(f.unit_hpp) as unit_hpp,

      count(distinct f.marketplace_order_id)::integer as order_count,
      sum(f.qty)::integer as total_qty,
      coalesce(sum(f.gross_line) filter (where not f.is_returned), 0)::numeric as total_omzet,
      coalesce(sum(f.payout_total) filter (where not f.is_returned), 0)::numeric as total_payout,

      -- Settled (Active paid orders)
      coalesce(sum(f.qty) filter (where f.has_payout and not f.is_returned), 0)::integer as qty_settled,
      coalesce(sum(f.qty * f.unit_hpp) filter (where f.has_payout and not f.is_returned), 0)::numeric as total_hpp,
      coalesce(sum(f.qty * f.unit_hpp) filter (where f.has_payout and not f.is_returned), 0)::numeric as settled_hpp,

      -- Unsettled / Belum Payout (Active orders missing payout)
      coalesce(sum(f.qty) filter (where not f.has_payout and not f.is_returned), 0)::integer as qty_unsettled,
      coalesce(sum(f.qty * f.unit_hpp) filter (where not f.has_payout and not f.is_returned), 0)::numeric as unpaid_hpp,

      -- Returned / Cancelled (Strictly separated)
      coalesce(sum(f.qty) filter (where f.is_returned), 0)::integer as qty_returned,
      coalesce(sum(f.qty * f.unit_hpp) filter (where f.is_returned), 0)::numeric as hpp_return,

      -- Profit & Margin
      coalesce(sum(f.payout_total - (f.qty * f.unit_hpp)) filter (where f.has_payout and not f.is_returned), 0)::numeric as net_profit,
      case
        when sum(f.payout_total) filter (where f.has_payout and not f.is_returned) > 0 then
          round(((sum(f.payout_total - (f.qty * f.unit_hpp)) filter (where f.has_payout and not f.is_returned) / sum(f.payout_total) filter (where f.has_payout and not f.is_returned)) * 100)::numeric, 2)
        else 0
      end as margin_percent
    from classified f
    group by f.local_sku
  ),
  filtered as (
    select *
    from grouped g
    where (
      v_payout_filter in ('all', 'semua', '')
      or (v_payout_filter = 'paid' and g.qty_settled > 0)
      or (v_payout_filter = 'unpaid' and g.qty_unsettled > 0)
      or (v_payout_filter = 'returned' and g.qty_returned > 0)
    )
  )
  select
    count(*)::integer,
    coalesce(sum(order_count), 0)::integer,
    coalesce(sum(total_qty), 0)::integer,
    coalesce(sum(total_omzet), 0)::numeric,
    coalesce(sum(total_payout), 0)::numeric,
    coalesce(sum(total_hpp), 0)::numeric,
    coalesce(sum(unpaid_hpp), 0)::numeric,
    coalesce(sum(hpp_return), 0)::numeric,
    coalesce(sum(qty_returned), 0)::integer,
    coalesce(sum(net_profit), 0)::numeric,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'local_sku', g.local_sku,
          'seller_sku', g.marketplace_seller_sku,
          'marketplace_seller_sku', g.marketplace_seller_sku,
          'marketplace_sku_id', g.marketplace_sku_id,
          'product_name', g.product_name,
          'variant_name', g.variant_name,
          'unit_hpp', g.unit_hpp,
          'hpp_per_item', g.unit_hpp,

          'order_count', g.order_count,
          'orders_count', g.order_count,
          'total_qty', g.total_qty,
          'qty_total', g.total_qty,
          'total_omzet', g.total_omzet,
          'omzet_total', g.total_omzet,
          'gross_sales', g.total_omzet,
          'total_payout', g.total_payout,
          'payout_total', g.total_payout,

          'qty_settled', g.qty_settled,
          'settled_qty', g.qty_settled,
          'paid_qty', g.qty_settled,
          'settled_hpp', g.settled_hpp,
          'total_hpp', g.total_hpp,
          'hpp_total', g.total_hpp,

          'qty_unsettled', g.qty_unsettled,
          'unpaid_qty', g.qty_unsettled,
          'qty_belum_payout', g.qty_unsettled,
          'unpaid_hpp', g.unpaid_hpp,

          'qty_returned', g.qty_returned,
          'returned_qty', g.qty_returned,
          'qty_batal', g.qty_returned,
          'hpp_return', g.hpp_return,
          'hpp_retur', g.hpp_return,

          'net_profit', g.net_profit,
          'laba_net', g.net_profit,
          'margin_percent', g.margin_percent
        ) order by g.total_omzet desc
      ),
      '[]'::jsonb
    )
  into
    v_total_sku_count,
    v_total_orders_count,
    v_total_qty_count,
    v_total_omzet,
    v_total_payout,
    v_total_hpp,
    v_total_unpaid_hpp,
    v_total_hpp_return,
    v_total_qty_returned,
    v_total_laba,
    v_items
  from (
    select * from filtered order by total_omzet desc limit v_page_size offset v_offset
  ) g;

  v_res := jsonb_build_object(
    'ok', true,
    'total_sku_count', v_total_sku_count,
    'total_orders_count', v_total_orders_count,
    'total_qty_count', v_total_qty_count,
    'total_omzet', v_total_omzet,
    'total_payout', v_total_payout,
    'total_hpp', v_total_hpp,
    'total_unpaid_hpp', v_total_unpaid_hpp,
    'total_hpp_return', v_total_hpp_return,
    'total_qty_returned', v_total_qty_returned,
    'total_laba', v_total_laba,
    'page', v_page,
    'page_size', v_page_size,
    'total_pages', greatest(ceil(coalesce(v_total_sku_count, 0)::numeric / v_page_size)::integer, 1),
    'items', v_items,
    'rows', v_items,
    'data', v_items
  );

  return v_res;
end;
$function$;

GRANT EXECUTE ON FUNCTION public.finance_sku_order_line_details(date, date, text, uuid, text, text, text, text, integer, integer) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.finance_sku_order_details_group_20260625(date, date, text, uuid, text, text, integer, integer) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
```

---

## 5. Verification Method

### Step 1: Migration Deployment Verification
Deploy the migration to VPS and reload schema:
```powershell
Get-Content supabase/migrations/20260815020000_fix_finance_sku_retur_batal_and_unpaid_separation.sql | ssh inventory-vps "docker exec -i supabase-db psql -U postgres -d postgres"
```

### Step 2: Line Details Test (`p_payout_filter = 'returned'`)
Run SQL query on Postgres for June & July 2026:
```sql
SELECT public.finance_sku_order_line_details(
  '2026-06-01'::date,
  '2026-07-31'::date,
  'all',
  NULL,
  NULL,
  NULL,
  NULL,
  'returned',
  1,
  25
);
```
**Expected Outcome**: Returns JSON object with `total > 0`, `rows` array populated with cancelled/returned order line rows, containing `is_returned = true`, `order_sn`, `status = 'CANCELLED'` / `'RETURNED'`, valid `qty`, and `resi`.

### Step 3: Group Aggregates Test (`finance_sku_order_details_group_20260625`)
Run SQL query on Postgres:
```sql
SELECT public.finance_sku_order_details_group_20260625(
  '2026-06-01'::date,
  '2026-07-31'::date,
  'all',
  NULL,
  NULL,
  'all',
  1,
  20
);
```
**Expected Outcome**:
- `total_unpaid_hpp` and SKU `unpaid_hpp` reflect ONLY active pending orders.
- `total_hpp_return` and SKU `hpp_return` reflect returned/cancelled orders.
- `total_qty_returned` > 0 if returns exist.
- `p_payout_filter = 'returned'` returns only SKUs with `qty_returned > 0`.

### Invalidation Conditions:
- If `finance_sku_order_line_details` with `'returned'` returns `[]` despite returned orders existing in `marketplace_orders` in June/July 2026.
- If `unpaid_hpp` includes any cancelled or returned order.
