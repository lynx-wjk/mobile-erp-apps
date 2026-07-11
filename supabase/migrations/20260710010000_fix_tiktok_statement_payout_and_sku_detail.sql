-- Migration: Fix TikTok Payout (Statement Rows) + SKU Detail Local SKU Matching
-- Date: 2026-07-10 01:00:00 WIB
--
-- ROOT CAUSE 1 (TikTok Payout Missing Jul 2-9):
--   `finance_snapshot_order_omzet_settlement_overlay_20260623` filters
--   `report_type <> 'statement'` from marketplace_finance_reports.
--   TikTok stores the ACTUAL daily bank-transfer payout in `statement` rows;
--   individual `order_settlement` rows carry payout_amount=0 (Jul 2-9).
--   Shopee stores payout per-order in `order_settlement` rows (no statement rows).
--   Fix: Use statement rows for TikTok payout; keep order_settlement for Shopee.
--
-- ROOT CAUSE 2 (SKU Detail returns 0 rows when p_local_sku is supplied):
--   `finance_sku_order_line_details` match_sku CTE only checks
--   `marketplace_order_items.local_sku / mapped_local_sku`.
--   For items where those columns are NULL but `local_sku` IS populated via the
--   auto-sync, those items still show up correctly.
--   However, for SKU summary cards that derive local_sku from `marketplace_variant_hpp_mappings`
--   (the enriched live_local_sku), the detail RPC finds nothing because neither
--   `oi.local_sku` nor `oi.mapped_local_sku` is filled yet.
--   Fix: In match_sku, also join hpp_mappings and check the resolved local_sku.
--
-- SAFETY RULES:
--   * Shopee payout logic is NOT changed.
--   * TikTok order-count (finance_order_count) still uses order_settlement rows.
--   * No destructive SQL. No schema changes. Only CREATE OR REPLACE FUNCTION.
--   * statement_timeout kept at 20s (same as before).


-- ============================================================================
-- FIX 1: finance_snapshot_order_omzet_settlement_overlay_20260623
--
-- Change: add `tiktok_statement_payout` CTE that sums TikTok statement rows.
--         In `merged`, use that CTE for TikTok payout instead of the
--         (zero) order_settlement aggregation.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.finance_snapshot_order_omzet_settlement_overlay_20260623(
  p_base jsonb,
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
set statement_timeout to '20s'
as $function$
declare
  v_claims jsonb := '{}'::jsonb;
  v_tenant_id uuid := null;
  v_start date := coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date);
  v_end date := coalesce(p_end, timezone('Asia/Jakarta', now())::date);
  v_marketplace text := null;
  v_summary jsonb := coalesce(p_base->'summary', '{}'::jsonb);
  v_by_marketplace jsonb := '[]'::jsonb;
  v_cash_adjustments jsonb := '[]'::jsonb;
  v_order_gross numeric := 0;
  v_order_count numeric := 0;
  v_payout numeric := 0;
  v_finance_count numeric := 0;
  v_expense numeric := 0;
  v_hpp numeric := 0;
begin
  begin
    v_claims := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  exception when others then
    v_claims := '{}'::jsonb;
  end;

  v_tenant_id := case
    when (v_claims->>'tenant_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (v_claims->>'tenant_id')::uuid
    else null::uuid
  end;

  if v_tenant_id is null then
    select case when count(*) = 1 then (array_agg(tenant_id))[1] else null end
      into v_tenant_id
    from (select distinct tenant_id from public.users where tenant_id is not null) t;
  end if;

  v_marketplace := case
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) in ('', 'all', 'semua') then null
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
    else lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g'))
  end;

  with unique_orders as (
    select
      coalesce(nullif(o.order_id, ''), nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_key,
      min((coalesce(o.paid_at, o.order_created_at, o.created_at) at time zone 'Asia/Jakarta')::date) as order_date,
      max(o.marketplace) as marketplace,
      max(o.marketplace_account_id::text) as account_id,
      max(greatest(coalesce(o.gross_amount, 0), coalesce(o.paid_amount, 0))) as omzet_value
    from public.marketplace_orders o
    where (v_tenant_id is null or o.tenant_id = v_tenant_id)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and coalesce(o.paid_at, o.order_created_at, o.created_at) >= (v_start::timestamp at time zone 'Asia/Jakarta' - interval '2 days')
      and coalesce(o.paid_at, o.order_created_at, o.created_at) <= ((v_end + 1)::timestamp at time zone 'Asia/Jakarta' + interval '2 days')
      and coalesce(o.gross_amount, o.paid_amount, 0) > 0
      and not (lower(coalesce(o.order_status, '')) ~ '(cancel|canceled|cancelled|batal|return|returned|refund|refunded|unpaid|failed|reject|in_cancel)')
      and not (lower(coalesce(o.payment_status, '')) ~ '(unpaid|failed|cancel|canceled|cancelled|refund|refunded)')
      -- Exclude UUID fake orders
      and not (o.order_sn ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
      and not (coalesce(o.order_id, '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
    group by coalesce(nullif(o.order_id, ''), nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text)
  ),
  order_omzet as (
    select
      case
        when lower(regexp_replace(coalesce(marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        when lower(regexp_replace(coalesce(marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        else lower(regexp_replace(coalesce(marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace,
      count(*)::numeric as order_count,
      sum(omzet_value)::numeric as omzet_total
    from unique_orders
    where order_date >= v_start
      and order_date <= v_end
      and (
        v_marketplace is null or
        case
          when lower(regexp_replace(coalesce(marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          when lower(regexp_replace(coalesce(marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          else lower(regexp_replace(coalesce(marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
    group by 1
  ),
  -- order_settlement rows only (for Shopee payout + all finance_order_count).
  -- Statement rows are explicitly excluded here to avoid double-counting.
  deduped_reports as (
    select distinct on (tenant_id, marketplace_account_id, coalesce(nullif(order_id, ''), statement_id))
      fr.*
    from public.marketplace_finance_reports fr
    where (v_tenant_id is null or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and coalesce(fr.settlement_date::date, fr.period_start::date, fr.created_at::date) between v_start and v_end
      -- Exclude statement rows from this CTE; TikTok statement payout handled separately below
      and coalesce(fr.report_type, '') <> 'statement'
      and (
        v_marketplace is null or
        case
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
    -- Prioritize API-pulled detailed rows over historical Excel rows
    order by tenant_id, marketplace_account_id, coalesce(nullif(order_id, ''), statement_id),
             case when statement_id not like 'historical:%' then 1 else 2 end
  ),
  -- FIX: TikTok actual daily bank-transfer payout comes from `statement` rows.
  -- These are daily totals synced from the TikTok Seller Center settlement page.
  -- Individual `order_settlement` rows for TikTok have payout_amount=0 (Jul 2 onward).
  tiktok_statement_payout as (
    select
      'tiktok_shop' as marketplace,
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0))::numeric as payout_total
    from public.marketplace_finance_reports fr
    where (v_tenant_id is null or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and fr.report_type = 'statement'
      and lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%'
      and coalesce(fr.settlement_date::date, fr.period_start::date, fr.created_at::date) between v_start and v_end
      -- Only apply when marketplace filter allows TikTok
      and (v_marketplace is null or v_marketplace = 'tiktok_shop')
  ),
  finance_payout as (
    select
      case
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace,
      count(distinct coalesce(fr.marketplace_order_id::text, fr.order_id::text, fr.statement_id::text, fr.finance_report_id::text))::numeric as finance_order_count,
      -- For Shopee: sum payout from order_settlement rows (correct per-order payout)
      -- For TikTok: payout is 0 here; actual payout comes from tiktok_statement_payout CTE
      sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0))::numeric as payout_total,
      sum(coalesce(fr.platform_fee, 0))::numeric as platform_fee,
      sum(coalesce(fr.commission_fee, 0))::numeric as commission_fee,
      sum(coalesce(fr.affiliate_fee, 0))::numeric as affiliate_fee,
      sum(coalesce(fr.shipping_fee, 0))::numeric as shipping_fee,
      sum(coalesce(fr.discount_amount, 0))::numeric as discount_amount,
      sum(coalesce(fr.refund_amount, 0))::numeric as refund_amount,
      sum(coalesce(fr.adjustment_amount, 0))::numeric as adjustment_amount,
      sum(coalesce(fr.fee_amount, 0))::numeric as fee_amount
    from deduped_reports fr
    group by 1
  ),
  merged as (
    select
      coalesce(o.marketplace, f.marketplace) as marketplace,
      coalesce(o.order_count, 0) as order_count,
      coalesce(o.omzet_total, 0) as omzet_total,
      coalesce(f.finance_order_count, 0) as finance_order_count,
      -- PAYOUT SOURCE:
      --   TikTok: use daily statement payout (actual bank transfer from Seller Center)
      --   Shopee/others: use order_settlement payout (per-order from deduped_reports)
      case
        when coalesce(o.marketplace, f.marketplace) = 'tiktok_shop'
          then coalesce(tk.payout_total, 0)
        else coalesce(f.payout_total, 0)
      end as payout_total,
      coalesce(f.platform_fee, 0) as platform_fee,
      coalesce(f.commission_fee, 0) as commission_fee,
      coalesce(f.affiliate_fee, 0) as affiliate_fee,
      coalesce(f.shipping_fee, 0) as shipping_fee,
      coalesce(f.discount_amount, 0) as discount_amount,
      coalesce(f.refund_amount, 0) as refund_amount,
      coalesce(f.adjustment_amount, 0) as adjustment_amount,
      coalesce(f.fee_amount, 0) as fee_amount
    from order_omzet o
    full outer join finance_payout f using (marketplace)
    left join tiktok_statement_payout tk
      on tk.marketplace = coalesce(o.marketplace, f.marketplace)
  )
  select
    coalesce(sum(omzet_total), 0),
    coalesce(sum(order_count), 0),
    coalesce(sum(payout_total), 0),
    coalesce(sum(finance_order_count), 0),
    coalesce(jsonb_agg(jsonb_build_object(
      'marketplace', marketplace,
      'marketplace_label', marketplace,
      'shop_name', case
        when marketplace = 'tiktok_shop' then 'TikTok'
        when marketplace = 'shopee' then 'Shopee'
        else 'Marketplace'
      end,
      'order_count', order_count,
      'orders_count', order_count,
      'finance_order_count', finance_order_count,
      'finance_orders_count', finance_order_count,
      'omzet_total', omzet_total,
      'gross_sales', omzet_total,
      'gross_total', omzet_total,
      'gross_amount', omzet_total,
      'payout_total', payout_total,
      'payout_amount', payout_total,
      'received_amount', payout_total,
      'net_settlement', payout_total,
      'platform_fee', platform_fee,
      'commission_fee', commission_fee,
      'affiliate_fee', affiliate_fee,
      'shipping_fee', shipping_fee,
      'discount_amount', discount_amount,
      'refund_amount', refund_amount,
      'adjustment_amount', adjustment_amount,
      'fee_amount', fee_amount,
      'hpp_total', 0,
      'profit', payout_total,
      'net_profit', payout_total,
      'net_margin_percent', case when payout_total > 0 then 100 else 0 end,
      'omzet_source', 'marketplace_orders.order_created_at',
      'payout_source', case
        when marketplace = 'tiktok_shop' then 'marketplace_finance_reports.statement (daily_transfer)'
        else 'marketplace_finance_reports.settlement_date'
      end
    ) order by marketplace), '[]'::jsonb)
  into v_order_gross, v_order_count, v_payout, v_finance_count, v_by_marketplace
  from merged;

  select coalesce(jsonb_agg(jsonb_build_object(
      'cash_adjustment_id', cash_adjustment_id,
      'tenant_id', tenant_id,
      'adjustment_date', adjustment_date,
      'date', adjustment_date,
      'direction', direction,
      'type', case when lower(coalesce(direction, '')) = 'out' then 'out' else 'in' end,
      'cash_type', case when lower(coalesce(direction, '')) = 'out' then 'out' else 'in' end,
      'amount', amount,
      'category', category,
      'source', category,
      'title', category,
      'note', note,
      'description', note,
      'created_at', created_at
    ) order by adjustment_date desc, created_at desc), '[]'::jsonb)
    into v_cash_adjustments
  from public.finance_company_cash_adjustments
  where (v_tenant_id is null or tenant_id = v_tenant_id)
    and adjustment_date between v_start and v_end;

  v_expense := coalesce(nullif(v_summary->>'expense_total', '')::numeric, 0);
  v_hpp := coalesce(nullif(v_summary->>'hpp_total', '')::numeric, 0);

  v_summary := v_summary || jsonb_build_object(
    'omzet_total', v_order_gross,
    'gross_sales', v_order_gross,
    'gross_total', v_order_gross,
    'gross_amount', v_order_gross,
    'order_count', v_order_count,
    'orders_count', v_order_count,
    'all_orders_count', v_order_count,
    'payout_total', v_payout,
    'payout_amount', v_payout,
    'received_amount', v_payout,
    'net_settlement', v_payout,
    'finance_order_count', v_finance_count,
    'finance_orders_count', v_finance_count,
    'net_profit', v_payout - v_hpp - v_expense,
    'profit', v_payout - v_hpp - v_expense,
    'summary_policy', 'omzet_by_order_date_tiktok_payout_by_statement_shopee_by_order_settlement'
  );

  return p_base || jsonb_build_object(
    'summary', v_summary,
    'by_marketplace', v_by_marketplace,
    'marketplaces', v_by_marketplace,
    'cash_adjustments', v_cash_adjustments,
    'company_cash_adjustments', v_cash_adjustments,
    'wrapper_version', coalesce(p_base->>'wrapper_version', '') || '_order_omzet_statement_payout_tiktok_20260710'
  );
end;
$function$;


-- ============================================================================
-- FIX 2: finance_sku_order_line_details
--
-- Change: In the mapped path's `match_sku` CTE, also resolve local_sku via
-- marketplace_variant_hpp_mappings when marketplace_order_items.local_sku is NULL.
-- This ensures that SKU detail rows appear when clicking a summary card whose
-- live_local_sku was derived from HPP mappings (not from the order item itself).
-- ============================================================================

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
 SET statement_timeout TO '25s'
 AS $function$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_start date := coalesce(p_start, date_trunc('month', now() at time zone 'Asia/Jakarta')::date);
  v_end date := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);
  v_marketplace text := nullif(lower(trim(coalesce(p_marketplace,''))), '');
  v_filter text := lower(trim(coalesce(p_payout_filter,'all')));
  v_local_sku text := lower(trim(coalesce(p_local_sku,'')));
  v_page integer := greatest(1, coalesce(p_page, 1));
  v_page_size integer := least(100, greatest(1, coalesce(p_page_size, 25)));
  v_offset integer;
  v_is_unmapped boolean := false;
  v_rows jsonb;
  v_total integer;
begin
  v_offset := (v_page - 1) * v_page_size;

  if v_marketplace in ('all','semua','_all','*','-','semua platform') then
    v_marketplace := null;
  end if;

  if v_filter in ('','all','semua','-') then
    v_filter := 'all';
  elsif v_filter in ('settled','released','release','payout','paid','sudah payout') then
    v_filter := 'paid';
  elsif v_filter in ('pending','unpaid','belum payout','no payout','missing payout') then
    v_filter := 'unpaid';
  end if;

  -- Detect UI "unmapped" label -> search for null local_sku in DB
  if v_local_sku in ('unmapped','not_mapped','tidak_dipetakan','belum dipetakan','belum_dipetakan') then
    v_is_unmapped := true;
    v_local_sku := '';
  end if;

  -- Fast path for unmapped: query marketplace_order_items directly
  if v_is_unmapped then
    with base as (
      select
        o.tenant_id,
        o.marketplace,
        coalesce(nullif(o.order_id::text,''), nullif(o.order_sn,''), o.marketplace_order_id::text) as order_key,
        o.order_created_at,
        o.order_status,
        o.marketplace_account_id,
        oi.marketplace_order_item_id,
        oi.marketplace_sku,
        oi.marketplace_seller_sku,
        oi.seller_sku,
        null::text as local_sku,
        oi.marketplace_product_name,
        oi.product_name,
        oi.marketplace_variant_name,
        oi.variant_name,
        greatest(1, coalesce(nullif(oi.quantity,0), nullif(oi.qty,0), 1))::integer as qty,
        coalesce(oi.gross_amount, 0)::numeric as gross_amount,
        coalesce(oi.unit_gross_amount, 0)::numeric as unit_price,
        oi.marketplace_product_id,
        oi.marketplace_sku_id,
        oi.marketplace_order_id
      from public.marketplace_order_items oi
      join public.marketplace_orders o
        on o.marketplace_order_id = oi.marketplace_order_id
        and o.tenant_id = oi.tenant_id
      where oi.tenant_id = v_tenant_id
        and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date >= v_start
        and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date <= v_end
        and (p_account_id is null or o.marketplace_account_id = p_account_id)
        and (
          v_marketplace is null
          or public._finance_marketplace_norm_20260624(o.marketplace)
             = public._finance_marketplace_norm_20260624(v_marketplace)
        )
        -- Exclude cancelled/unpaid/batal/failed/refunded orders
        and not (lower(coalesce(o.order_status, '')) ~ '(cancel|canceled|cancelled|batal|return|returned|refund|refunded|unpaid|failed|reject|in_cancel)')
        and not (lower(coalesce(o.payment_status, '')) ~ '(unpaid|failed|cancel|canceled|cancelled|refund|refunded)')
        -- Exclude UUID fake orders
        and not (o.order_sn ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        and not (coalesce(o.order_id, '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        -- unmapped: local_sku is null/empty on the item
        and coalesce(nullif(trim(oi.local_sku),''), nullif(trim(oi.mapped_local_sku),'')) is null
        -- Filter by p_marketplace_sku and p_search in unmapped path
        and (
          p_marketplace_sku is null or p_marketplace_sku = ''
          or lower(p_marketplace_sku) in (
             lower(oi.marketplace_sku::text),
             lower(oi.marketplace_seller_sku::text),
             lower(oi.seller_sku::text),
             lower(oi.marketplace_sku_id::text),
             lower(oi.marketplace_product_id::text)
          )
        )
        and (
          p_search is null or p_search = ''
          or o.order_id::text ilike '%' || p_search || '%'
          or coalesce(oi.marketplace_product_name, oi.product_name, '') ilike '%' || p_search || '%'
        )
    ),
    unmapped_base as (
      select b.*
      from base b
      left join lateral (
        select m.local_sku
        from public.marketplace_sku_maps m
        where m.tenant_id = b.tenant_id
          and m.marketplace_account_id = b.marketplace_account_id
          and m.marketplace_product_id = b.marketplace_product_id
          and m.marketplace_sku_id = b.marketplace_sku_id
          and coalesce(m.status, 'active') = 'active'
        limit 1
      ) m on true
      where m.local_sku is null
    ),
    with_payout as (
      select
        u.*,
        coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)::numeric as order_payout,
        (fr.finance_report_id is not null) as has_payout
      from unmapped_base u
      left join lateral (
        select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement
        from (
          select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, 1 as priority
          from public.marketplace_finance_reports fr
          where fr.tenant_id = u.tenant_id
            and fr.marketplace_account_id = u.marketplace_account_id
            and fr.order_id = u.order_key
            and coalesce(fr.report_type, '') <> 'statement'
          union all
          select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, 2 as priority
          from public.marketplace_finance_reports fr
          where fr.tenant_id = u.tenant_id
            and fr.marketplace_account_id = u.marketplace_account_id
            and fr.marketplace_order_id = u.marketplace_order_id
            and coalesce(fr.report_type, '') <> 'statement'
        ) fr
        order by priority
        limit 1
      ) fr on true
    ),
    filtered as (
      select *
      from with_payout
      where
        v_filter = 'all'
        or (v_filter = 'paid' and has_payout)
        or (v_filter = 'unpaid' and not has_payout)
    ),
    counted as (
      select count(*)::integer as total from filtered
    ),
    paged as (
      select * from filtered
      order by order_created_at desc, order_key, marketplace_order_item_id
      limit v_page_size offset v_offset
    )
    select
      coalesce(jsonb_agg(
        jsonb_build_object(
          'id', marketplace_order_item_id,
          'order_id', order_key,
          'order_sn', order_key,
          'marketplace', marketplace,
          'marketplace_name', marketplace,
          'created_at', order_created_at,
          'order_status', order_status,
          'status', order_status,
          'product_name', coalesce(marketplace_product_name, product_name, '-'),
          'variant_name', coalesce(marketplace_variant_name, variant_name, '-'),
          'marketplace_sku', coalesce(marketplace_sku, marketplace_seller_sku, seller_sku, marketplace_sku_id::text, marketplace_product_id::text, '-'),
          'local_sku', 'Unmapped',
          'qty', qty,
          'quantity', qty,
          'gross_amount', gross_amount,
          'unit_price', unit_price,
          'order_payout', order_payout,
          'has_payout', has_payout
        ) order by order_created_at desc, order_key
      ), '[]'::jsonb),
      (select coalesce(max(total),0) from counted)
    into v_rows, v_total
    from paged;

    return jsonb_build_object(
      'ok', true,
      'source', 'unmapped_direct_join',
      'rows', v_rows,
      'total', v_total,
      'page', v_page,
      'page_size', v_page_size,
      'total_pages', ceil(v_total::numeric / v_page_size::numeric),
      'total_count', v_total,
      'summary_source', 'marketplace_order_items'
    );
  end if;

  -- Default mapped logic
  -- FIX: Also join marketplace_variant_hpp_mappings to resolve local_sku for
  -- items where marketplace_order_items.local_sku / mapped_local_sku is NULL
  -- but the HPP mapping table has a local_sku for this marketplace_sku_id or
  -- marketplace_seller_sku. This ensures SKU detail popup works for cards
  -- whose live_local_sku was derived from HPP mappings in the summary function.
  with base_items as (
    select
      i.marketplace_order_item_id,
      i.marketplace_order_id,
      o.marketplace,
      o.marketplace_account_id,
      coalesce(nullif(o.order_id::text,''), nullif(o.order_sn,''), o.marketplace_order_id::text) as order_key,
      o.order_created_at,
      o.order_status,
      i.marketplace_product_name,
      i.product_name,
      i.marketplace_variant_name,
      i.variant_name,
      i.marketplace_sku,
      i.marketplace_seller_sku,
      i.seller_sku,
      coalesce(nullif(trim(i.local_sku),''), nullif(trim(i.mapped_local_sku),'')) as local_sku,
      greatest(1, coalesce(nullif(i.quantity,0), nullif(i.qty,0), 1))::integer as qty,
      coalesce(i.gross_amount, 0)::numeric as gross_amount,
      coalesce(i.unit_gross_amount, 0)::numeric as unit_price,
      i.marketplace_sku_id,
      i.marketplace_product_id
    from public.marketplace_order_items i
    join public.marketplace_orders o
      on o.marketplace_order_id = i.marketplace_order_id
      and o.tenant_id = i.tenant_id
    where i.tenant_id = v_tenant_id
      and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date >= v_start
      and (coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date <= v_end
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or public._finance_marketplace_norm_20260624(o.marketplace)
           = public._finance_marketplace_norm_20260624(v_marketplace)
      )
      -- Exclude cancelled/unpaid/batal/failed/refunded orders
      and not (lower(coalesce(o.order_status, '')) ~ '(cancel|canceled|cancelled|batal|return|returned|refund|refunded|unpaid|failed|reject|in_cancel)')
      and not (lower(coalesce(o.payment_status, '')) ~ '(unpaid|failed|cancel|canceled|cancelled|refund|refunded)')
      -- Exclude UUID fake orders
      and not (o.order_sn ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
      and not (coalesce(o.order_id, '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
  ),
  -- Resolve local_sku from HPP mappings for items where order_items.local_sku is NULL.
  -- This is needed because the summary function uses `live_local_sku` from HPP mappings
  -- which may not have been written back to marketplace_order_items yet.
  hpp_resolved as (
    select
      b.marketplace_order_item_id,
      -- Prefer order_items.local_sku; fall back to HPP mapping by marketplace_sku_id,
      -- then by marketplace_seller_sku. This matches the summary function's priority.
      coalesce(
        b.local_sku,
        hm_sku.local_sku,
        hm_sel.local_sku
      ) as effective_local_sku
    from base_items b
    left join lateral (
      select hm.local_sku
      from public.marketplace_variant_hpp_mappings hm
      where hm.tenant_id = v_tenant_id
        and hm.marketplace_account_id = b.marketplace_account_id
        and lower(nullif(hm.marketplace_sku_id,'')) = lower(nullif(coalesce(b.marketplace_sku, b.marketplace_seller_sku, b.seller_sku),''))
        and coalesce(hm.is_active, true) = true
        and nullif(hm.local_sku,'') is not null
      order by hm.updated_at desc nulls last
      limit 1
    ) hm_sku on true
    left join lateral (
      select hm.local_sku
      from public.marketplace_variant_hpp_mappings hm
      where hm.tenant_id = v_tenant_id
        and hm.marketplace_account_id = b.marketplace_account_id
        and lower(nullif(hm.marketplace_seller_sku,'')) = lower(nullif(coalesce(b.marketplace_seller_sku, b.marketplace_sku),''))
        and coalesce(hm.is_active, true) = true
        and nullif(hm.local_sku,'') is not null
      order by hm.updated_at desc nulls last
      limit 1
    ) hm_sel on true
  ),
  match_sku as (
    select b.*, hr.effective_local_sku
    from base_items b
    join hpp_resolved hr on hr.marketplace_order_item_id = b.marketplace_order_item_id
    where
      (
        p_marketplace_sku is null or p_marketplace_sku = ''
        or lower(p_marketplace_sku) in (
           lower(b.marketplace_sku::text),
           lower(b.marketplace_seller_sku::text),
           lower(b.seller_sku::text),
           lower(b.marketplace_sku_id::text),
           lower(b.marketplace_product_id::text)
        )
      )
      and (
        -- When v_local_sku is provided, match on effective_local_sku
        -- (which includes HPP-resolved values, not just order_items.local_sku)
        v_local_sku is null or v_local_sku = ''
        or lower(coalesce(hr.effective_local_sku,'')) = v_local_sku
      )
      and (
        p_search is null or p_search = ''
        or b.order_key ilike '%' || p_search || '%'
        or coalesce(b.marketplace_product_name, b.product_name, '') ilike '%' || p_search || '%'
      )
  ),
  with_payout as (
    select
      m.*,
      coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)::numeric as order_payout,
      (fr.finance_report_id is not null) as has_payout
    from match_sku m
    left join lateral (
      select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement
      from (
        select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, 1 as priority
        from public.marketplace_finance_reports fr
        where fr.tenant_id = v_tenant_id
          and fr.marketplace_account_id = m.marketplace_account_id
          and fr.order_id = m.order_key
          and coalesce(fr.report_type, '') <> 'statement'
        union all
        select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement, 2 as priority
        from public.marketplace_finance_reports fr
        where fr.tenant_id = v_tenant_id
          and fr.marketplace_account_id = m.marketplace_account_id
          and fr.marketplace_order_id = m.marketplace_order_id
          and coalesce(fr.report_type, '') <> 'statement'
      ) fr
      order by priority
      limit 1
    ) fr on true
  ),
  filtered as (
    select *
    from with_payout
    where
      v_filter = 'all'
      or (v_filter = 'paid' and has_payout)
      or (v_filter = 'unpaid' and not has_payout)
  ),
  counted as (
    select count(*)::integer as total from filtered
  ),
  paged as (
    select * from filtered
    order by order_created_at desc, order_key, marketplace_order_item_id
    limit v_page_size offset v_offset
  )
  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'id', marketplace_order_item_id,
        'order_id', order_key,
        'order_sn', order_key,
        'marketplace', marketplace,
        'marketplace_name', marketplace,
        'created_at', order_created_at,
        'order_status', order_status,
        'status', order_status,
        'product_name', coalesce(marketplace_product_name, product_name, '-'),
        'variant_name', coalesce(marketplace_variant_name, variant_name, '-'),
        'marketplace_sku', coalesce(marketplace_sku, marketplace_seller_sku, seller_sku, marketplace_sku_id::text, marketplace_product_id::text, '-'),
        'local_sku', coalesce(effective_local_sku, local_sku, 'Unmapped'),
        'qty', qty,
        'quantity', qty,
        'gross_amount', gross_amount,
        'unit_price', unit_price,
        'order_payout', order_payout,
        'has_payout', has_payout
      ) order by order_created_at desc, order_key
    ), '[]'::jsonb),
    (select coalesce(max(total),0) from counted)
  into v_rows, v_total
  from paged;

  return jsonb_build_object(
    'ok', true,
    'source', 'mapped_direct_join_hpp_resolved',
    'rows', v_rows,
    'total', v_total,
    'page', v_page,
    'page_size', v_page_size,
    'total_pages', ceil(v_total::numeric / v_page_size::numeric),
    'total_count', v_total,
    'summary_source', 'marketplace_order_items'
  );
end;
$function$;


-- Verify the functions were created/replaced successfully
DO $$
BEGIN
  ASSERT (
    SELECT COUNT(*) FROM pg_proc
    WHERE proname = 'finance_snapshot_order_omzet_settlement_overlay_20260623'
  ) >= 1, 'finance_snapshot_order_omzet_settlement_overlay_20260623 not found after migration';

  ASSERT (
    SELECT COUNT(*) FROM pg_proc
    WHERE proname = 'finance_sku_order_line_details'
  ) >= 1, 'finance_sku_order_line_details not found after migration';

  RAISE NOTICE 'Migration 20260710010000 applied successfully.';
END;
$$;
