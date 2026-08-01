-- Redefining finance_dashboard_snapshot to make it fully dynamic and respect p_start/p_end/p_account_id
create or replace function public.finance_dashboard_snapshot(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '15s'
as $$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_tenant_id uuid;
  v_role text := coalesce(nullif(v_claims->>'role', ''), nullif(current_setting('role', true), ''), current_user);
  v_current_start date := date_trunc('month', timezone('Asia/Jakarta', now()))::date;
  v_current_end date := timezone('Asia/Jakarta', now())::date;
  v_start date := coalesce(p_start, v_current_start);
  v_end date := coalesce(p_end, v_current_end);
  v_start_ts timestamptz := (v_start::timestamp at time zone 'Asia/Jakarta');
  v_end_ts timestamptz := ((v_end + 1)::timestamp at time zone 'Asia/Jakarta');
  v_marketplace text;
  
  v_by_marketplace jsonb := '[]'::jsonb;
  v_daily jsonb := '[]'::jsonb;
  v_recon_summary jsonb := '{}'::jsonb;
  v_recon_breakdown jsonb := '[]'::jsonb;
  
  v_abnormal_count integer := 0;
  v_negative_payout_total_abs numeric := 0;
  v_sample_order_count integer := 0;
  v_sample_hpp_total numeric := 0;
  v_sample_negative_payout_total numeric := 0;
  v_sample_loss_estimate numeric := 0;
  v_no_payout_count integer := 0;
  v_payout_minus_count integer := 0;
  v_omzet_total numeric := 0;
  v_payout_total numeric := 0;
  v_hpp_total numeric := 0;
  v_orders_count integer := 0;
  v_finance_orders_count integer := 0;
begin
  select coalesce(
    case
      when (v_claims->>'tenant_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (v_claims->>'tenant_id')::uuid
      else null::uuid
    end,
    (select u.tenant_id from public.users u where u.user_id = auth.uid() limit 1)
  )
  into v_tenant_id;

  v_marketplace := case
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
    else null
  end;

  -- 1) Call profit/loss details to get the by_marketplace rows and aggregates
  with pl_res as (
    select coalesce(public.finance_marketplace_profit_loss_detail(v_start, v_end, p_marketplace, p_account_id)->'rows', '[]'::jsonb) as rows_val
  ),
  pl_elements as (
    select jsonb_array_elements(rows_val) as row_val from pl_res
  ),
  unpacked as (
    select
      coalesce((row_val->>'gross_sales')::numeric, 0) as gross_sales,
      coalesce((row_val->>'payout_total')::numeric, 0) as payout_total,
      coalesce((row_val->>'discount_amount')::numeric, 0) as discount_amount,
      coalesce((row_val->>'platform_fee')::numeric, 0) as platform_fee,
      coalesce((row_val->>'commission_fee')::numeric, 0) as commission_fee,
      coalesce((row_val->>'affiliate_fee')::numeric, 0) as affiliate_fee,
      coalesce((row_val->>'shipping_fee')::numeric, 0) as shipping_fee,
      coalesce((row_val->>'other_fee')::numeric, 0) as other_fee,
      coalesce((row_val->>'refund_amount')::numeric, 0) as refund_amount,
      coalesce((row_val->>'adjustment_amount')::numeric, 0) as adjustment_amount,
      coalesce((row_val->>'sample_order_count')::integer, 0) as sample_order_count,
      coalesce((row_val->>'sample_negative_payout_total')::numeric, 0) as sample_negative_payout_total,
      coalesce((row_val->>'order_count')::integer, 0) as order_count,
      coalesce((row_val->>'finance_order_count')::integer, 0) as finance_order_count,
      coalesce((row_val->>'unmatched_order_count')::integer, 0) as unmatched_order_count,
      coalesce((row_val->>'unmatched_order_gross')::numeric, 0) as unmatched_order_gross,
      row_val
    from pl_elements
  )
  select
    coalesce(sum(gross_sales), 0),
    coalesce(sum(payout_total), 0),
    coalesce(sum(sample_order_count), 0),
    coalesce(sum(sample_negative_payout_total), 0),
    coalesce(sum(order_count), 0),
    coalesce(sum(finance_order_count), 0),
    coalesce(sum(unmatched_order_count), 0),
    coalesce(jsonb_agg(row_val), '[]'::jsonb)
  into
    v_omzet_total,
    v_payout_total,
    v_sample_order_count,
    v_sample_negative_payout_total,
    v_orders_count,
    v_finance_orders_count,
    v_no_payout_count,
    v_by_marketplace
  from unpacked;

  -- 2) Call reconciliation breakdown for sample HPP and unclassified breakdown
  select
    coalesce((v_recon->'summary'->>'sample_hpp_total')::numeric, 0),
    coalesce((v_recon->'summary'->>'sample_loss_estimate')::numeric, 0),
    coalesce(v_recon->'profit_loss_breakdown', '[]'::jsonb)
  into
    v_sample_hpp_total,
    v_sample_loss_estimate,
    v_recon_breakdown
  from (
    select public.finance_marketplace_reconciliation_breakdown(v_start, v_end, p_marketplace, p_account_id) as v_recon
  ) x;

  -- 3) Calculate abnormal counts and negative payouts from finance reports
  select
    coalesce(count(*), 0)::integer,
    coalesce(sum(abs(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0))), 0)::numeric,
    coalesce(count(*) filter (where coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0) < 0), 0)::integer
  into
    v_abnormal_count,
    v_negative_payout_total_abs,
    v_payout_minus_count
  from public.marketplace_finance_reports fr
  where fr.period_start >= v_start
    and fr.period_start <= v_end
    and (v_role = 'service_role' or fr.tenant_id = v_tenant_id)
    and (p_account_id is null or fr.marketplace_account_id = p_account_id)
    and (v_marketplace is null or (
      case
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
        else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end
    ) = v_marketplace)
    and coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)::numeric < 0;

  -- 4) Build daily trend series dynamically
  with calendar as (
    select generate_series(v_start, v_end, interval '1 day')::date as day
  ),
  daily_orders as (
    select
      timezone('Asia/Jakarta', o.order_created_at)::date as order_date,
      coalesce(sum(coalesce(o.total_amount, o.gross_amount, o.paid_amount, 0)), 0)::numeric as gross_total,
      count(distinct coalesce(nullif(o.order_sn, ''), nullif(o.external_order_id, ''), nullif(o.order_id, ''), o.marketplace_order_id::text))::integer as orders_count
    from public.marketplace_orders o
    where o.order_created_at >= v_start_ts
      and o.order_created_at < v_end_ts
      and (v_role = 'service_role' or o.tenant_id = v_tenant_id)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (v_marketplace is null or (
        case
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
          else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end
      ) = v_marketplace)
      and lower(coalesce(o.order_status, o.status, '')) !~ '(cancel|batal|dibatalkan|unpaid|belum bayar|belum dibayar)'
    group by 1
  ),
  daily_finance as (
    select
      fr.period_start::date as finance_date,
      coalesce(sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)), 0)::numeric as payout_total,
      count(*)::integer as finance_orders_count,
      count(*) filter (where coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0) < 0)::integer as negative_payout_count,
      coalesce(sum(abs(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0))) filter (where coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0) < 0), 0)::numeric as negative_payout_total_abs
    from public.marketplace_finance_reports fr
    where fr.period_start >= v_start
      and fr.period_start <= v_end
      and (v_role = 'service_role' or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and (v_marketplace is null or (
        case
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
          else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end
      ) = v_marketplace)
    group by 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'date', c.day,
    'order_date', c.day,
    'omzet_total', coalesce(d_ord.gross_total, 0),
    'gross_total', coalesce(d_ord.gross_total, 0),
    'gross_sales', coalesce(d_ord.gross_total, 0),
    'payout_total', coalesce(d_fin.payout_total, 0),
    'hpp_total', 0,
    'orders_count', coalesce(d_ord.orders_count, 0),
    'order_count', coalesce(d_ord.orders_count, 0),
    'finance_orders_count', coalesce(d_fin.finance_orders_count, 0),
    'abnormal_count', coalesce(d_fin.negative_payout_count, 0),
    'negative_payout_total_abs', coalesce(d_fin.negative_payout_total_abs, 0)
  ) order by c.day), '[]'::jsonb)
  into v_daily
  from calendar c
  left join daily_orders d_ord on d_ord.order_date = c.day
  left join daily_finance d_fin on d_fin.finance_date = c.day;

  return jsonb_build_object(
    'ok', true,
    'version', 'finance_dashboard_snapshot_dynamic_dates_20260621',
    'source', 'finance_dashboard_snapshot',
    'source_table', 'finance_marketplace_profit_loss_detail+marketplace_finance_reports',
    'timezone', 'Asia/Jakarta',
    'start_date', v_start::text,
    'end_date', v_end::text,
    'requested_start_date', p_start,
    'requested_end_date', p_end,
    'requested_account_id', p_account_id,
    'marketplace', coalesce(p_marketplace, 'all'),
    'summary', jsonb_build_object(
      'omzet_total', v_omzet_total,
      'gross_total', v_omzet_total,
      'gross_sales', v_omzet_total,
      'payout_total', v_payout_total,
      'payout_amount', v_payout_total,
      'hpp_total', v_hpp_total,
      'total_hpp', v_hpp_total,
      'net_profit', v_payout_total - v_hpp_total,
      'orders_count', v_orders_count,
      'order_count', v_orders_count,
      'finance_orders_count', v_finance_orders_count,
      'finance_order_count', v_finance_orders_count,
      'abnormal_count', v_abnormal_count,
      'anomaly_count', v_abnormal_count,
      'negative_payout_total_abs', v_negative_payout_total_abs,
      'payout_minus_total_abs', v_negative_payout_total_abs,
      'sample_order_count', v_sample_order_count,
      'sample_hpp_total', v_sample_hpp_total,
      'sample_negative_payout_total', v_sample_negative_payout_total,
      'sample_loss_estimate', v_sample_loss_estimate,
      'no_payout_count', v_no_payout_count,
      'payout_minus_count', v_payout_minus_count
    ),
    'daily', v_daily,
    'trend', v_daily,
    'by_marketplace', v_by_marketplace,
    'marketplaces', v_by_marketplace,
    'profit_loss_by_marketplace', v_by_marketplace,
    'abnormal_aggregates', jsonb_build_object(
      'abnormal_count', v_abnormal_count,
      'negative_payout_total_abs', v_negative_payout_total_abs
    ),
    'accounts', '[]'::jsonb,
    'expenses', '[]'::jsonb,
    'approved_purchases', '[]'::jsonb,
    'skus', '[]'::jsonb,
    'sku_rows', '[]'::jsonb,
    'cash_flow', '[]'::jsonb,
    'profit_loss_breakdown', v_recon_breakdown,
    'abnormals', '[]'::jsonb
  );
end;
$$;

grant execute on function public.finance_dashboard_snapshot(date, date, text, uuid) to authenticated, service_role;


-- Redefining finance_sku_order_line_details to expose order_payout and order_line_gross
create or replace function public.finance_sku_order_line_details(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null,
  p_marketplace_sku text default null,
  p_local_sku text default null,
  p_search text default null,
  p_payout_filter text default 'all',
  p_page integer default 1,
  p_page_size integer default 25
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '8s'
as $$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_tenant_id uuid;
  v_role text := coalesce(nullif(v_claims->>'role', ''), nullif(current_setting('role', true), ''), current_user);
  v_start date := coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date);
  v_end date := coalesce(p_end, timezone('Asia/Jakarta', now())::date);
  v_start_ts timestamptz;
  v_end_ts timestamptz;
  v_marketplace text;
  v_marketplace_sku_raw text := nullif(trim(coalesce(p_marketplace_sku, '')), '');
  v_local_sku_raw text := nullif(trim(coalesce(p_local_sku, '')), '');
  v_marketplace_sku text := lower(nullif(trim(coalesce(p_marketplace_sku, '')), ''));
  v_local_sku text := lower(nullif(trim(coalesce(p_local_sku, '')), ''));
  v_search text := lower(nullif(trim(coalesce(p_search, '')), ''));
  v_filter text := lower(trim(coalesce(p_payout_filter, 'all')));
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 25), 1), 25);
  v_offset integer;
begin
  select coalesce(
    case
      when (v_claims->>'tenant_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (v_claims->>'tenant_id')::uuid
      else null::uuid
    end,
    (select u.tenant_id from public.users u where u.user_id = auth.uid() limit 1)
  )
  into v_tenant_id;

  v_start_ts := (v_start::timestamp at time zone 'Asia/Jakarta');
  v_end_ts := ((v_end + 1)::timestamp at time zone 'Asia/Jakarta');
  v_offset := (v_page - 1) * v_page_size;
  v_filter := case
    when v_filter in ('settled', 'released', 'release', 'payout', 'paid', 'paid payout', 'sudah payout') then 'paid'
    when v_filter in ('pending', 'unpaid', 'belum payout', 'no payout', 'missing payout') then 'unpaid'
    when v_filter = '' then 'all'
    else v_filter
  end;
  v_marketplace := case
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
    else null
  end;

  if v_role <> 'service_role' and v_tenant_id is null then
    return jsonb_build_object('rows', '[]'::jsonb, 'page', v_page, 'page_size', v_page_size, 'total', 0, 'total_count', 0, 'total_pages', 1, 'source', 'finance_sku_order_line_details_page_first');
  end if;

  if v_marketplace_sku is null and v_local_sku is null and v_search is null then
    return jsonb_build_object('rows', '[]'::jsonb, 'page', v_page, 'page_size', v_page_size, 'total', 0, 'total_count', 0, 'total_pages', 1, 'source', 'finance_sku_order_line_details_page_first');
  end if;

  return (
    with matched_with_extra as materialized (
      select
        o.marketplace_order_id,
        o.tenant_id,
        o.marketplace_account_id,
        o.order_created_at,
        timezone('Asia/Jakarta', o.order_created_at)::date as order_date,
        coalesce(nullif(o.order_id::text, ''), nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), o.marketplace_order_id::text) as order_key,
        coalesce(nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), nullif(o.order_id::text, '')) as order_sn,
        coalesce(nullif(o.tracking_number, ''), nullif(o.label_code, ''), nullif(o.package_id, '')) as tracking_number,
        lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) as status_text,
        coalesce(nullif(o.order_status, ''), nullif(o.status, ''), nullif(o.order_status_label, '')) as order_status,
        coalesce(nullif(o.order_status_label, ''), nullif(o.order_status, ''), nullif(o.status, '')) as order_status_label,
        case
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
          else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end as marketplace_group,
        oi.marketplace_order_item_id,
        coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku_id,
        coalesce(nullif(oi.marketplace_sku, ''), nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku,
        coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as marketplace_seller_sku,
        coalesce(nullif(oi.local_sku, ''), nullif(oi.mapped_local_sku, '')) as local_sku,
        coalesce(nullif(oi.marketplace_product_name, ''), nullif(oi.product_name, ''), nullif(oi.local_product_name, '')) as product_name,
        coalesce(nullif(oi.marketplace_variant_name, ''), nullif(oi.variant_name, ''), nullif(oi.variation_name, '')) as variant_name,
        greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1)::numeric as qty,
        coalesce(
          nullif(oi.gross_amount, 0),
          nullif(oi.paid_amount, 0),
          nullif(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1),
          0
        )::numeric as line_gross
      from public.marketplace_order_items oi
      join public.marketplace_orders o
        on o.tenant_id = oi.tenant_id
        and o.marketplace_order_id = oi.marketplace_order_id
      where o.order_created_at >= v_start_ts
        and o.order_created_at < v_end_ts
        and (v_role = 'service_role' or oi.tenant_id = v_tenant_id)
        and (v_role = 'service_role' or o.tenant_id = v_tenant_id)
        and (p_account_id is null or oi.marketplace_account_id = p_account_id)
        and (p_account_id is null or o.marketplace_account_id = p_account_id)
        and (
          v_marketplace_sku is null
          or oi.marketplace_sku_id = v_marketplace_sku_raw
          or oi.marketplace_sku = v_marketplace_sku_raw
          or oi.remote_sku_id = v_marketplace_sku_raw
          or oi.marketplace_seller_sku = v_marketplace_sku_raw
          or oi.seller_sku = v_marketplace_sku_raw
          or v_marketplace_sku in (
              lower(coalesce(oi.marketplace_sku_id, '')),
              lower(coalesce(oi.marketplace_sku, '')),
              lower(coalesce(oi.remote_sku_id, '')),
              lower(coalesce(oi.marketplace_seller_sku, '')),
              lower(coalesce(oi.seller_sku, ''))
            )
        )
        and (
          v_local_sku is null
          or oi.local_sku = v_local_sku_raw
          or oi.mapped_local_sku = v_local_sku_raw
          or v_local_sku = lower(coalesce(oi.local_sku, oi.mapped_local_sku, ''))
        )
        and (
          v_search is null
          or lower(concat_ws(' ', o.order_id, o.order_sn, o.external_order_id, o.tracking_number, oi.marketplace_sku_id, oi.marketplace_sku, oi.marketplace_seller_sku, oi.seller_sku, oi.local_sku, oi.mapped_local_sku, oi.marketplace_product_name, oi.product_name, oi.marketplace_variant_name, oi.variant_name)) like '%' || v_search || '%'
        )
        and (v_marketplace is null or (
          case
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
            else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
          end
        ) = v_marketplace)
        and lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) not like '%cancel%'
        and lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) not like '%batal%'
        and lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) not like '%unpaid%'
        and lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) not like '%in_cancel%'
        and (
          v_filter = 'all'
          or (
            v_filter = 'paid'
            and exists (
              select 1
              from public.marketplace_finance_reports fr
              where fr.tenant_id = o.tenant_id
                and fr.marketplace_account_id = o.marketplace_account_id
                and (
                  fr.marketplace_order_id = o.marketplace_order_id
                  or fr.order_id = coalesce(nullif(o.order_id::text, ''), nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), o.marketplace_order_id::text)
                )
            )
          )
          or (
            v_filter = 'unpaid'
            and not exists (
              select 1
              from public.marketplace_finance_reports fr
              where fr.tenant_id = o.tenant_id
                and fr.marketplace_account_id = o.marketplace_account_id
                and (
                  fr.marketplace_order_id = o.marketplace_order_id
                  or fr.order_id = coalesce(nullif(o.order_id::text, ''), nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), o.marketplace_order_id::text)
                )
            )
          )
        )
      order by o.order_created_at desc, coalesce(nullif(o.order_id::text, ''), nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), o.marketplace_order_id::text), oi.marketplace_order_item_id
      offset v_offset
      limit v_page_size + 1
    ),
    paged as (
      select *
      from matched_with_extra
      order by order_created_at desc, order_key, marketplace_order_item_id
      limit v_page_size
    ),
    page_meta as (
      select
        (select count(*)::integer from paged) as visible_count,
        (select count(*)::integer from matched_with_extra) > v_page_size as has_more
    ),
    enriched as (
      select
        pl.*,
        coalesce(olt.order_line_gross, pl.line_gross, 0)::numeric as order_line_gross,
        coalesce(fin.order_payout, 0)::numeric as order_payout,
        coalesce(fin.has_payout, false) as has_payout,
        coalesce(fin.statement_id, '') as statement_id,
        coalesce(fin.settlement_status, '') as settlement_status,
        fin.settlement_date,
        coalesce(fin.payout_source, '') as payout_source,
        coalesce(fin.platform_fee, 0)::numeric as platform_fee,
        coalesce(fin.commission_fee, 0)::numeric as commission_fee,
        coalesce(fin.affiliate_fee, 0)::numeric as affiliate_fee,
        coalesce(fin.shipping_fee, 0)::numeric as shipping_fee,
        coalesce(fin.discount_amount, 0)::numeric as discount_amount,
        coalesce(fin.refund_amount, 0)::numeric as refund_amount,
        coalesce(fin.adjustment_amount, 0)::numeric as adjustment_amount,
        coalesce(fin.fee_amount, 0)::numeric as fee_amount,
        coalesce(hpp.unit_hpp, 0)::numeric as unit_hpp,
        coalesce(hpp.target_margin, 0)::numeric as target_margin
      from paged pl
      left join lateral (
        select coalesce(sum(coalesce(
          nullif(oi2.gross_amount, 0),
          nullif(oi2.paid_amount, 0),
          nullif(oi2.unit_gross_amount, 0) * greatest(coalesce(nullif(oi2.qty, 0), nullif(oi2.quantity, 0), 1), 1),
          0
        )), 0)::numeric as order_line_gross
        from public.marketplace_order_items oi2
        where oi2.tenant_id = pl.tenant_id
          and oi2.marketplace_order_id = pl.marketplace_order_id
      ) olt on true
      left join lateral (
        select
          coalesce(sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)), 0)::numeric as order_payout,
          count(fr.finance_report_id) > 0 as has_payout,
          max(nullif(fr.statement_id, '')) as statement_id,
          max(nullif(fr.settlement_status, '')) as settlement_status,
          max(fr.settlement_date) as settlement_date,
          coalesce(sum(fr.platform_fee), 0)::numeric as platform_fee,
          coalesce(sum(fr.commission_fee), 0)::numeric as commission_fee,
          coalesce(sum(fr.affiliate_fee), 0)::numeric as affiliate_fee,
          coalesce(sum(fr.shipping_fee), 0)::numeric as shipping_fee,
          coalesce(sum(fr.discount_amount), 0)::numeric as discount_amount,
          coalesce(sum(coalesce(fr.refund_amount, fr.total_refund, 0)), 0)::numeric as refund_amount,
          coalesce(sum(fr.adjustment_amount), 0)::numeric as adjustment_amount,
          coalesce(sum(coalesce(fr.fee_amount, fr.total_fees, 0)), 0)::numeric as fee_amount,
          case
            when count(fr.payout_amount) filter (where fr.payout_amount is not null) > 0 then 'marketplace_finance_reports.payout_amount'
            when count(fr.received_amount) filter (where fr.received_amount is not null) > 0 then 'marketplace_finance_reports.received_amount'
            when count(fr.net_settlement) filter (where fr.net_settlement is not null) > 0 then 'marketplace_finance_reports.net_settlement'
            when count(fr.finance_report_id) > 0 then 'marketplace_finance_reports.settlement_status'
            else ''
          end as payout_source
        from public.marketplace_finance_reports fr
        where fr.tenant_id = pl.tenant_id
          and fr.marketplace_account_id = pl.marketplace_account_id
          and (
            fr.marketplace_order_id = pl.marketplace_order_id
            or fr.order_id = pl.order_key
          )
      ) fin on true
      left join lateral (
        select
          max(coalesce(m.hpp, m.hpp_amount, m.hpp_per_item, 0))::numeric as unit_hpp,
          max(coalesce(m.target_margin_percent, m.target_margin, 0))::numeric as target_margin
        from public.marketplace_variant_hpp_mappings m
        where m.tenant_id = pl.tenant_id
          and m.marketplace_account_id = pl.marketplace_account_id
          and coalesce(m.is_active, true) is true
          and (
            lower(nullif(m.marketplace_sku_id, '')) = lower(nullif(pl.marketplace_sku_id, ''))
            or lower(nullif(m.marketplace_seller_sku, '')) = lower(nullif(pl.marketplace_seller_sku, ''))
            or lower(nullif(m.local_sku, '')) = lower(nullif(pl.local_sku, ''))
          )
      ) hpp on true
    )
    select jsonb_build_object(
      'rows', coalesce(jsonb_agg((
        jsonb_build_object(
          'source', 'finance_sku_order_line_details_page_first',
          'sku_detail_source', 'finance_sku_order_line_details_page_first',
          'payout_source', nullif(payout_source, ''),
          'order', order_key,
          'order_id', order_key,
          'order_sn', order_sn,
          'marketplace_order_id', marketplace_order_id,
          'marketplace_order_item_id', marketplace_order_item_id,
          'resi', tracking_number,
          'tracking_number', tracking_number,
          'order_date', order_created_at,
          'order_created_at', order_created_at,
          'marketplace', marketplace_group,
          'marketplace_account_id', marketplace_account_id,
          'order_payout', order_payout,
          'order_line_gross', order_line_gross
        ) ||
        jsonb_build_object(
          'status', order_status,
          'order_status', order_status,
          'order_status_label', order_status_label,
          'local_sku', coalesce(nullif(local_sku, ''), '-'),
          'sku', coalesce(nullif(local_sku, ''), nullif(marketplace_sku_id, ''), nullif(marketplace_seller_sku, ''), '-'),
          'marketplace_sku_id', marketplace_sku_id,
          'marketplace_sku', marketplace_sku,
          'marketplace_seller_sku', marketplace_seller_sku,
          'product_name', product_name,
          'variant_name', variant_name,
          'marketplace_variation_name', variant_name,
          'qty', qty,
          'quantity', qty,
          'gross', line_gross,
          'gross_amount', line_gross,
          'gross_total', line_gross,
          'gross_per_item', case when qty > 0 then line_gross / qty else 0 end,
          'payout', case when has_payout and order_line_gross > 0 then order_payout * (line_gross / order_line_gross) else 0 end,
          'payout_amount', case when has_payout and order_line_gross > 0 then order_payout * (line_gross / order_line_gross) else 0 end,
          'payout_per_item', case when has_payout and order_line_gross > 0 and qty > 0 then (order_payout * (line_gross / order_line_gross)) / qty else 0 end
        ) ||
        jsonb_build_object(
          'platform_fee_item', case when has_payout and order_line_gross > 0 then platform_fee * (line_gross / order_line_gross) else 0 end,
          'commission_fee_item', case when has_payout and order_line_gross > 0 then commission_fee * (line_gross / order_line_gross) else 0 end,
          'affiliate_fee_item', case when has_payout and order_line_gross > 0 then affiliate_fee * (line_gross / order_line_gross) else 0 end,
          'shipping_fee_item', case when has_payout and order_line_gross > 0 then shipping_fee * (line_gross / order_line_gross) else 0 end,
          'discount_amount_item', case when has_payout and order_line_gross > 0 then discount_amount * (line_gross / order_line_gross) else 0 end,
          'refund_amount_item', case when has_payout and order_line_gross > 0 then refund_amount * (line_gross / order_line_gross) else 0 end,
          'adjustment_amount_item', case when has_payout and order_line_gross > 0 then adjustment_amount * (line_gross / order_line_gross) else 0 end,
          'fee_amount_item', case when has_payout and order_line_gross > 0 then fee_amount * (line_gross / order_line_gross) else 0 end,
          'hpp', unit_hpp * qty,
          'hpp_total', unit_hpp * qty,
          'hpp_per_item', unit_hpp,
          'unit_hpp', unit_hpp,
          'hpp_status', case when unit_hpp > 0 then 'HPP mapping' else 'HPP belum mapping' end,
          'target_margin_percent', target_margin,
          'statement_id', nullif(statement_id, ''),
          'settlement_ref', nullif(statement_id, ''),
          'settlement_status', case when has_payout then coalesce(nullif(settlement_status, ''), 'SETTLED') else 'PENDING_PAYOUT' end,
          'settlement_date', settlement_date,
          'finance_status', case when has_payout then coalesce(nullif(settlement_status, ''), 'SETTLED') else 'PENDING_PAYOUT' end,
          'payout_status', case when has_payout then coalesce(nullif(settlement_status, ''), 'SETTLED') else 'PENDING_PAYOUT' end
        )
      ) order by order_created_at desc, order_key, marketplace_order_item_id)
        filter (where marketplace_order_item_id is not null), '[]'::jsonb),
      'page', v_page,
      'page_size', v_page_size,
      'total', v_offset + page_meta.visible_count + case when page_meta.has_more then 1 else 0 end,
      'total_count', v_offset + page_meta.visible_count + case when page_meta.has_more then 1 else 0 end,
      'total_pages', case when page_meta.has_more then v_page + 1 else greatest(v_page, 1) end,
      'has_more', page_meta.has_more,
      'source', 'finance_sku_order_line_details_page_first'
    )
  );
end;
$$;

grant execute on function public.finance_sku_order_line_details(date, date, text, uuid, text, text, text, text, integer, integer) to authenticated, service_role;

notify pgrst, 'reload schema';
