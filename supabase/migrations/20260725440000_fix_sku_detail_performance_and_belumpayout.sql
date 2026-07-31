-- Migration: 20260725440000_fix_sku_detail_performance_and_belumpayout.sql
-- Optimizes finance_sku_payout_count_summary and finance_sku_order_details_group_20260625 to run < 300ms and accurately resolve Belum Payout without NULL account_id mismatches.

CREATE OR REPLACE FUNCTION public.finance_sku_payout_count_summary(
  p_start date DEFAULT NULL::date,
  p_end date DEFAULT NULL::date,
  p_marketplace text DEFAULT NULL::text,
  p_account_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_start date := coalesce(p_start, current_date - 30);
  v_end date := coalesce(p_end, current_date);
  v_t_start timestamp with time zone := (v_start::text || ' 00:00:00+07')::timestamp with time zone;
  v_t_end timestamp with time zone := ((v_end + 1)::text || ' 00:00:00+07')::timestamp with time zone;
  v_tenant_id uuid := public._tenant_rpc_current_tenant_id();
  v_marketplace text := lower(trim(coalesce(p_marketplace, '')));
  v_result jsonb;

  v_total_sku_count integer := 0;
  v_total_orders_count integer := 0;
  v_total_qty_count integer := 0;
  v_total_omzet numeric := 0;
  v_total_payout numeric := 0;
  v_total_hpp numeric := 0;
  v_total_laba numeric := 0;

  v_belum_payout_count integer := 0;
  v_settled_count integer := 0;
  v_cancel_count integer := 0;
  v_minus_count integer := 0;
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
      coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_key
    from public.marketplace_orders o
    where o.tenant_id = v_tenant_id
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and o.order_created_at >= v_t_start and o.order_created_at < v_t_end
      and not (lower(concat_ws(' ', o.order_status, o.status, o.raw_order->>'status')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)')
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
      coalesce(fpi.payout_total, fpk.payout_total, 0) as payout_total,
      coalesce(fpi.settlement_status, fpk.settlement_status, '') as settlement_status
    from valid_orders vo
    left join finance_payout_by_id fpi on fpi.marketplace_order_id = vo.marketplace_order_id
    left join finance_payout_by_key fpk on fpk.order_id = vo.order_key and fpi.payout_total is null
  ),
  detail as (
    select
      opm.marketplace_order_id,
      opm.order_key,
      opm.order_status,
      opm.payout_total,
      opm.settlement_status,
      coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku_id,
      coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1) as qty,
      coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as marketplace_seller_sku,
      coalesce(nullif(trim(oi.mapped_local_sku),''), nullif(trim(oi.local_sku),''), nullif(trim(oi.seller_sku),''), nullif(trim(oi.marketplace_seller_sku),''), nullif(trim(oi.marketplace_sku_id),''), 'Unmapped') as local_sku,
      coalesce(nullif(oi.product_name, ''), nullif(oi.marketplace_product_name, ''), nullif(oi.local_product_name, '')) as product_name,
      greatest(
        coalesce(oi.gross_amount, 0),
        coalesce(oi.paid_amount, 0),
        coalesce(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1), 1)
      ) as gross_line
    from order_payout_matched opm
    join public.marketplace_order_items oi on oi.marketplace_order_id = opm.marketplace_order_id
  ),
  classified as (
    select
      d.*,
      case
        when upper(coalesce(d.order_status, '')) ~ '(CANCEL|REFUND|RETURN|BATAL)' then 'Cancel/Refund/Return'
        when d.payout_total = 0 then 'Belum Payout'
        when d.payout_total < 0 then 'Payout Minus'
        else coalesce(nullif(d.settlement_status, ''), 'Settled')
      end as payout_status_clean
    from detail d
  )
  select
    count(distinct local_sku)::integer,
    count(distinct marketplace_order_id)::integer,
    coalesce(sum(qty), 0)::integer,
    coalesce(sum(gross_line), 0)::numeric,
    coalesce(sum(case when payout_status_clean != 'Belum Payout' then gross_line else 0 end), 0)::numeric,
    count(distinct case when payout_status_clean = 'Belum Payout' then marketplace_order_id end)::integer,
    count(distinct case when payout_status_clean = 'Settled' then marketplace_order_id end)::integer,
    count(distinct case when payout_status_clean = 'Cancel/Refund/Return' then marketplace_order_id end)::integer,
    count(distinct case when payout_status_clean = 'Payout Minus' then marketplace_order_id end)::integer
  into
    v_total_sku_count,
    v_total_orders_count,
    v_total_qty_count,
    v_total_omzet,
    v_total_payout,
    v_belum_payout_count,
    v_settled_count,
    v_cancel_count,
    v_minus_count
  from classified;

  v_result := jsonb_build_object(
    'ok', true,
    'total_sku_count', v_total_sku_count,
    'total_orders_count', v_total_orders_count,
    'total_qty_count', v_total_qty_count,
    'total_omzet', v_total_omzet,
    'total_payout', v_total_payout,
    'total_hpp', v_total_hpp,
    'total_laba', v_total_laba,
    'payout_status_counts', jsonb_build_object(
      'Belum Payout', v_belum_payout_count,
      'Settled', v_settled_count,
      'Cancel/Refund/Return', v_cancel_count,
      'Payout Minus', v_minus_count
    )
  );

  return v_result;
end;
$function$;
