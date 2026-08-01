-- P0 bounded fix:
-- - finance_dashboard_snapshot resolves a selected account to its marketplace
--   when the UI sends "Semua platform" + one store.
-- - Adds a lightweight supplemental sample/free RPC without changing HPP or
--   importing mappings.

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
set statement_timeout = '8s'
as $$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_tenant_id uuid;
  v_role text := coalesce(nullif(v_claims->>'role', ''), nullif(current_setting('role', true), ''), current_user);
  v_current_start date := date_trunc('month', timezone('Asia/Jakarta', now()))::date;
  v_current_end date := timezone('Asia/Jakarta', now())::date;
  v_start date;
  v_end date;
  v_marketplace text;
  v_base jsonb;
  v_summary jsonb := '{}'::jsonb;
  v_by_marketplace jsonb := '[]'::jsonb;
  v_sample_orders jsonb := '[]'::jsonb;
  v_sample_order_count integer := 0;
  v_no_payout_count integer := 0;
  v_payout_minus_count integer := 0;
  v_payout_minus_total_abs numeric := 0;
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

  if v_marketplace is null and p_account_id is not null then
    select case
      when lower(regexp_replace(coalesce(ma.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      when lower(regexp_replace(coalesce(ma.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
      else nullif(lower(regexp_replace(coalesce(ma.marketplace, ''), '[^a-z0-9]+', '', 'g')), '')
    end
    into v_marketplace
    from public.marketplace_accounts ma
    where ma.marketplace_account_id = p_account_id
      and coalesce(ma.is_deleted, false) is false
      and (v_role = 'service_role' or ma.tenant_id = v_tenant_id)
    limit 1;
  end if;

  v_base := public.dashboard_marketplace_order_analytics_90d(v_marketplace, 20);
  v_start := coalesce(nullif(v_base->>'start_date', '')::date, p_start, v_current_start);
  v_end := coalesce(nullif(v_base->>'end_date', '')::date, p_end, v_current_end);

  with base_rows as (
    select row_value as row
    from jsonb_array_elements(coalesce(v_base->'by_marketplace', '[]'::jsonb)) row_value
  ),
  finance_rows as (
    select
      case
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
        else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace_group,
      coalesce(sum(fr.platform_fee), 0)::numeric as platform_fee,
      coalesce(sum(fr.commission_fee), 0)::numeric as commission_fee,
      coalesce(sum(fr.affiliate_fee), 0)::numeric as affiliate_fee,
      coalesce(sum(fr.shipping_fee), 0)::numeric as shipping_fee,
      coalesce(sum(fr.discount_amount), 0)::numeric as discount_amount,
      coalesce(sum(coalesce(fr.refund_amount, fr.total_refund, 0)), 0)::numeric as refund_amount,
      coalesce(sum(fr.adjustment_amount), 0)::numeric as adjustment_amount,
      coalesce(sum(coalesce(fr.fee_amount, fr.total_fees, 0)), 0)::numeric as fee_amount,
      coalesce(sum(fr.total_fees), 0)::numeric as total_fees,
      coalesce(sum(fr.total_refund), 0)::numeric as total_refund,
      count(*)::integer as finance_report_count
    from public.marketplace_finance_reports fr
    where fr.period_start >= v_start
      and fr.period_start <= v_end
      and (v_role = 'service_role' or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or (
          case
            when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
            when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
            else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
          end
        ) = v_marketplace
      )
    group by 1
  )
  select coalesce(jsonb_agg(
    br.row || jsonb_strip_nulls(jsonb_build_object(
      'platform_fee', fr.platform_fee,
      'commission_fee', fr.commission_fee,
      'affiliate_fee', fr.affiliate_fee,
      'shipping_fee', fr.shipping_fee,
      'discount_amount', fr.discount_amount,
      'refund_amount', fr.refund_amount,
      'adjustment_amount', fr.adjustment_amount,
      'fee_amount', fr.fee_amount,
      'total_fees', fr.total_fees,
      'total_refund', fr.total_refund,
      'finance_report_count', fr.finance_report_count,
      'breakdown_source', case when fr.finance_report_count > 0 then 'marketplace_finance_reports' else null end,
      'sample_free_source', 'strict_order_flags'
    ))
    order by br.row->>'marketplace'
  ), coalesce(v_base->'by_marketplace', '[]'::jsonb))
  into v_by_marketplace
  from base_rows br
  left join finance_rows fr
    on fr.marketplace_group = case
      when lower(regexp_replace(coalesce(br.row->>'marketplace', ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      when lower(regexp_replace(coalesce(br.row->>'marketplace', ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
      else lower(regexp_replace(coalesce(br.row->>'marketplace', 'unknown'), '[^a-z0-9]+', '', 'g'))
    end;

  v_sample_order_count := coalesce(nullif(v_base->'summary'->>'sample_order_count', '')::integer, 0);
  v_sample_orders := '[]'::jsonb;

  v_summary := coalesce(v_base->'summary', '{}'::jsonb) || jsonb_build_object(
    'sample_order_count', coalesce(v_sample_order_count, 0),
    'sample_free_count', coalesce(v_sample_order_count, 0),
    'missing_payout_non_sample_count', coalesce(nullif(v_base->'summary'->>'missing_payout_non_sample_count', '')::numeric, 0),
    'no_payout_count', coalesce(nullif(v_base->'summary'->>'no_payout_count', '')::numeric, 0),
    'negative_payout_count', coalesce(nullif(v_base->'summary'->>'negative_payout_count', '')::numeric, 0),
    'payout_minus_count', coalesce(nullif(v_base->'summary'->>'payout_minus_count', '')::numeric, 0),
    'payout_minus_total_abs', coalesce(nullif(v_base->'summary'->>'payout_minus_total_abs', '')::numeric, 0),
    'negative_payout_total_abs', coalesce(nullif(v_base->'summary'->>'negative_payout_total_abs', '')::numeric, 0)
  );

  return jsonb_build_object(
    'ok', true,
    'version', 'finance_dashboard_snapshot_fast_mtd_20260621_account_scope_sample_counts',
    'source', 'finance_dashboard_snapshot',
    'source_table', 'dashboard_marketplace_order_analytics_90d+marketplace_finance_reports',
    'timezone', 'Asia/Jakarta',
    'start_date', coalesce(v_base->>'start_date', v_current_start::text),
    'end_date', coalesce(v_base->>'end_date', v_current_end::text),
    'requested_start_date', coalesce(p_start, v_current_start),
    'requested_end_date', coalesce(p_end, v_current_end),
    'requested_account_id', p_account_id,
    'requested_marketplace', p_marketplace,
    'effective_marketplace', v_marketplace,
    'marketplace', coalesce(v_base->>'marketplace', coalesce(v_marketplace, 'all')),
    'summary', v_summary,
    'daily', coalesce(v_base->'daily', '[]'::jsonb),
    'trend', coalesce(v_base->'trend', v_base->'daily', '[]'::jsonb),
    'by_marketplace', v_by_marketplace,
    'marketplaces', v_by_marketplace,
    'profit_loss_by_marketplace', v_by_marketplace,
    'abnormal_aggregates', jsonb_build_object(
      'abnormal_count', coalesce(v_summary->'abnormal_count', '0'::jsonb),
      'negative_payout_count', coalesce(v_summary->'negative_payout_count', '0'::jsonb),
      'negative_payout_total_abs', coalesce(v_summary->'negative_payout_total_abs', '0'::jsonb),
      'no_payout_count', coalesce(v_summary->'no_payout_count', '0'::jsonb),
      'sample_order_count', coalesce(v_summary->'sample_order_count', '0'::jsonb)
    ),
    'accounts', '[]'::jsonb,
    'expenses', '[]'::jsonb,
    'approved_purchases', '[]'::jsonb,
    'skus', '[]'::jsonb,
    'sku_rows', '[]'::jsonb,
    'cash_flow', '[]'::jsonb,
    'profit_loss_breakdown', '[]'::jsonb,
    'abnormals', '[]'::jsonb,
    'sample_orders', v_sample_orders
  );
end;
$$;

revoke all on function public.finance_dashboard_snapshot(date, date, text, uuid) from public;
grant execute on function public.finance_dashboard_snapshot(date, date, text, uuid) to authenticated, service_role;

create or replace function public.finance_sample_order_counts(
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
set statement_timeout = '5s'
as $$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_tenant_id uuid;
  v_role text := coalesce(nullif(v_claims->>'role', ''), nullif(current_setting('role', true), ''), current_user);
  v_start date := coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date);
  v_end date := coalesce(p_end, timezone('Asia/Jakarta', now())::date);
  v_marketplace text;
  v_count integer := 0;
  v_rows jsonb := '[]'::jsonb;
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

  if v_marketplace is null and p_account_id is not null then
    select case
      when lower(regexp_replace(coalesce(ma.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
      when lower(regexp_replace(coalesce(ma.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
      else nullif(lower(regexp_replace(coalesce(ma.marketplace, ''), '[^a-z0-9]+', '', 'g')), '')
    end
    into v_marketplace
    from public.marketplace_accounts ma
    where ma.marketplace_account_id = p_account_id
      and coalesce(ma.is_deleted, false) is false
      and (v_role = 'service_role' or ma.tenant_id = v_tenant_id)
    limit 1;
  end if;

  with sample_orders as (
    select
      case
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
        else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace_group,
      o.marketplace_account_id,
      coalesce(nullif(o.order_sn, ''), nullif(o.external_order_id, ''), nullif(o.order_id, ''), o.marketplace_order_id::text) as order_key,
      o.order_status,
      o.tracking_number,
      o.order_created_at,
      coalesce(o.gross_amount, o.total_amount, o.paid_amount, 0)::numeric as gross_amount,
      coalesce(o.paid_amount, 0)::numeric as paid_amount
    from public.marketplace_orders o
    where o.order_created_at >= (v_start::timestamp at time zone 'Asia/Jakarta')
      and o.order_created_at < ((v_end + 1)::timestamp at time zone 'Asia/Jakarta')
      and (v_role = 'service_role' or o.tenant_id = v_tenant_id)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or (
          case
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
            else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
          end
        ) = v_marketplace
      )
      and (
        lower(coalesce(
          nullif(o.raw_order #>> '{is_sample_order}', ''),
          nullif(o.raw_order #>> '{is_sample}', ''),
          nullif(o.raw_order #>> '{sample_order}', ''),
          nullif(o.raw_order #>> '{is_free_sample}', ''),
          ''
        )) in ('true', '1', 'yes')
        or lower(coalesce(
          nullif(o.raw_order #>> '{payment_info,payment_text}', ''),
          nullif(o.raw_order #>> '{payment_text}', ''),
          nullif(o.raw_order #>> '{order_type}', ''),
          ''
        )) ~ '(gratis|free_sample|free sample|sample_gratis|sample gratis|seller_fund_free_sample|tester|giveaway|zero_payment|zero payment|pembayaran 0)'
      )
  ),
  counted as (
    select count(*)::integer as total from sample_orders
  ),
  limited as (
    select *
    from sample_orders
    order by order_created_at desc
    limit 100
  )
  select
    coalesce((select total from counted), 0),
    coalesce(jsonb_agg(jsonb_build_object(
      'abnormal_status', 'SAMPLE_FREE',
      'finance_status', 'SAMPLE_FREE',
      'payout_status', 'SAMPLE_FREE',
      'category', 'sample_free',
      'message', 'Sample/Gratis sesuai filter. Tidak masuk omzet normal.',
      'marketplace', marketplace_group,
      'marketplace_account_id', marketplace_account_id,
      'order_id', order_key,
      'order_sn', order_key,
      'external_order_id', order_key,
      'order_status', order_status,
      'order_date', order_created_at,
      'gross_amount', gross_amount,
      'payout_amount', 0,
      'resi', tracking_number,
      'is_sample_order', true
    ) order by order_created_at desc), '[]'::jsonb)
  into v_count, v_rows
  from limited;

  return jsonb_build_object(
    'ok', true,
    'source', 'finance_sample_order_counts',
    'timezone', 'Asia/Jakarta',
    'start_date', v_start,
    'end_date', v_end,
    'effective_marketplace', v_marketplace,
    'summary', jsonb_build_object(
      'sample_order_count', coalesce(v_count, 0),
      'sample_free_count', coalesce(v_count, 0)
    ),
    'rows', coalesce(v_rows, '[]'::jsonb),
    'sample_orders', coalesce(v_rows, '[]'::jsonb)
  );
end;
$$;

revoke all on function public.finance_sample_order_counts(date, date, text, uuid) from public;
grant execute on function public.finance_sample_order_counts(date, date, text, uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
