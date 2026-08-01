-- Fix Sample/Gratis to use explicit raw TikTok sample/export proof.
-- No destructive SQL. This only replaces the existing read-only RPC contract.

begin;

create or replace function public.finance_sample_order_counts(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null,
  p_count_only boolean default true,
  p_page integer default 1,
  p_page_size integer default 50
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
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_rows jsonb := '[]'::jsonb;
  v_summary jsonb := '{}'::jsonb;
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

  if v_role <> 'service_role' and v_tenant_id is null then
    return jsonb_build_object(
      'ok', true,
      'source', 'finance_sample_order_counts',
      'version', 'raw_tiktok_sample_proof_fast_20260621',
      'summary', '{}'::jsonb,
      'rows', '[]'::jsonb,
      'sample_orders', '[]'::jsonb
    );
  end if;

  if v_marketplace is not null and v_marketplace <> 'tiktok' then
    return jsonb_build_object(
      'ok', true,
      'source', 'finance_sample_order_counts',
      'version', 'raw_tiktok_sample_proof_fast_20260621',
      'timezone', 'Asia/Jakarta',
      'start_date', v_start,
      'end_date', v_end,
      'effective_marketplace', v_marketplace,
      'summary', jsonb_build_object(
        'sample_order_count', 0,
        'confirmed_sample_count', 0,
        'sample_free_count', 0,
        'source_breakdown', jsonb_build_object(
          'confirmed_sample_count', 0,
          'sample_raw_tiktok_order_count', 0,
          'sample_raw_tiktok_item_row_count', 0
        )
      ),
      'rows', '[]'::jsonb,
      'sample_orders', '[]'::jsonb
    );
  end if;

  with raw_tiktok_samples as materialized (
    select
      o.tenant_id,
      'tiktok'::text as marketplace_group,
      o.marketplace_account_id,
      o.marketplace_order_id,
      coalesce(nullif(o.order_sn, ''), nullif(o.external_order_id, ''), nullif(o.order_id::text, ''), nullif(o.remote_order_id, ''), o.marketplace_order_id::text) as order_key,
      coalesce(nullif(o.order_status_label, ''), nullif(o.order_status, ''), nullif(o.status, ''), nullif(o.raw_order->>'status', ''), '-') as display_status,
      coalesce(nullif(o.raw_order->>'order_substatus', ''), nullif(o.raw_order->>'substatus', ''), nullif(o.raw_order->>'sub_status', ''), nullif(o.logistic_status, ''), nullif(o.fulfillment_status, ''), '-') as display_substatus,
      coalesce(nullif(o.order_status, ''), nullif(o.status, ''), nullif(o.order_status_label, ''), nullif(o.raw_order->>'status', ''), '-') as order_status,
      upper(coalesce(o.order_status, o.status, o.order_status_label, o.raw_order->>'status', '')) as status_upper,
      o.tracking_number,
      o.order_created_at,
      coalesce(o.gross_amount, o.total_amount, o.paid_amount, 0)::numeric as gross_amount,
      coalesce(
        jsonb_array_length(case when jsonb_typeof(o.raw_order->'line_items') = 'array' then o.raw_order->'line_items' else '[]'::jsonb end),
        0
      ) +
      case
        when coalesce(o.raw_order->>'item_rows', '') ~ '^[0-9]+$' then (o.raw_order->>'item_rows')::integer
        else 0
      end as raw_item_row_count,
      case
        when coalesce(o.raw_order->>'is_sample_order', '') = 'true'
          then 'raw_tiktok_sample_flag'
        else 'raw_tiktok_historical_export_zero_amount'
      end as sample_evidence_source
    from public.marketplace_orders o
    where o.order_created_at >= (v_start::timestamp at time zone 'Asia/Jakarta')
      and o.order_created_at < ((v_end + 1)::timestamp at time zone 'Asia/Jakarta')
      and (v_role = 'service_role' or o.tenant_id = v_tenant_id)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and lower(coalesce(o.marketplace, '')) like '%tiktok%'
      and coalesce(o.gross_amount, o.total_amount, o.paid_amount, 0) <= 0
      and coalesce(nullif(o.order_sn, ''), nullif(o.external_order_id, ''), nullif(o.order_id::text, ''), nullif(o.remote_order_id, ''), o.marketplace_order_id::text) <> 'Platform unique order ID.'
      and coalesce(nullif(o.order_status, ''), nullif(o.status, ''), nullif(o.order_status_label, ''), '') <> 'CURRENT ORDER STATUS.'
      and (
        coalesce(o.raw_order->>'is_sample_order', '') = 'true'
        or (
          coalesce(o.raw_order->>'source', '') = 'historical_export_import'
          and coalesce(nullif(o.order_sn, ''), nullif(o.external_order_id, ''), nullif(o.order_id::text, ''), nullif(o.remote_order_id, ''), '') ~ '^[0-9]{8,}$'
        )
      )
  ),
  sample_orders as materialized (
    select *
    from raw_tiktok_samples
    where status_upper not like '%CANCEL%'
      and status_upper not like '%BATAL%'
      and status_upper not like '%RETURN%'
      and status_upper not like '%REFUND%'
      and status_upper not like '%GAGAL%'
      and status_upper not like '%FAILED%'
      and status_upper not like '%CLOSED%'
  ),
  sample_counts as (
    select
      coalesce(count(*), 0)::integer as confirmed_sample_count,
      0::integer as sample_text_marker_count,
      0::integer as sample_label_count,
      0::integer as sample_discount_100_count,
      0::integer as sample_finance_flag_count,
      coalesce(count(*), 0)::integer as sample_raw_tiktok_order_count,
      coalesce(count(*) filter (where sample_evidence_source = 'raw_tiktok_sample_flag'), 0)::integer as sample_raw_tiktok_api_flag_count,
      coalesce(count(*) filter (where sample_evidence_source = 'raw_tiktok_historical_export_zero_amount'), 0)::integer as sample_raw_tiktok_import_count,
      coalesce(sum(raw_item_row_count), 0)::integer as sample_raw_tiktok_item_row_count,
      coalesce(sum(gross_amount), 0)::numeric as sample_gross_total
    from sample_orders
  ),
  status_breakdown as (
    select coalesce(jsonb_object_agg(display_status, order_count order by order_count desc, display_status), '{}'::jsonb) as data
    from (
      select display_status, count(*)::integer as order_count
      from sample_orders
      group by display_status
    ) s
  ),
  substatus_breakdown as (
    select coalesce(jsonb_object_agg(display_substatus, order_count order by order_count desc, display_substatus), '{}'::jsonb) as data
    from (
      select display_substatus, count(*)::integer as order_count
      from sample_orders
      group by display_substatus
    ) s
  ),
  category_counts as (
    select
      coalesce(count(*) filter (
        where status_upper like '%CANCEL%'
           or status_upper like '%BATAL%'
           or status_upper like '%RETURN%'
           or status_upper like '%REFUND%'
           or status_upper like '%GAGAL%'
           or status_upper like '%FAILED%'
           or status_upper like '%CLOSED%'
      ), 0)::integer as cancelled_count
    from raw_tiktok_samples
  ),
  counts as (
    select
      s.*,
      c.cancelled_count,
      0::integer as pending_count,
      0::integer as no_payout_eligible_count,
      0::integer as payout_minus_count,
      0::numeric as payout_minus_total_abs,
      0::integer as other_count,
      sb.data as sample_status_breakdown,
      ssb.data as sample_substatus_breakdown
    from sample_counts s
    cross join category_counts c
    cross join status_breakdown sb
    cross join substatus_breakdown ssb
  ),
  limited as (
    select *
    from sample_orders
    order by order_created_at desc
    offset ((v_page - 1) * v_page_size)
    limit (case when p_count_only then 0 else v_page_size end)
  )
  select
    jsonb_build_object(
      'sample_order_count', c.confirmed_sample_count,
      'confirmed_sample_count', c.confirmed_sample_count,
      'sample_free_count', c.confirmed_sample_count,
      'sample_text_marker_count', c.sample_text_marker_count,
      'sample_label_count', c.sample_label_count,
      'sample_discount_100_count', c.sample_discount_100_count,
      'sample_finance_flag_count', c.sample_finance_flag_count,
      'sample_raw_tiktok_order_count', c.sample_raw_tiktok_order_count,
      'sample_raw_tiktok_item_row_count', c.sample_raw_tiktok_item_row_count,
      'sample_raw_tiktok_api_flag_count', c.sample_raw_tiktok_api_flag_count,
      'sample_raw_tiktok_import_count', c.sample_raw_tiktok_import_count,
      'sample_status_breakdown', c.sample_status_breakdown,
      'sample_substatus_breakdown', c.sample_substatus_breakdown,
      'sample_gross_total', c.sample_gross_total,
      'sample_payout_total', 0,
      'sample_payout_minus_total', 0,
      'sample_payout_minus_total_abs', 0,
      'sample_payout_minus_shipping_total', 0,
      'sample_payout_minus_ongkir_total', 0,
      'sample_payout_minus_voucher_total', 0,
      'sample_payout_minus_platform_total', 0,
      'sample_payout_minus_settlement_total', 0,
      'sample_discount_total', 0,
      'sample_shipping_total', 0,
      'sample_fee_total', 0,
      'sample_refund_total', 0,
      'sample_adjustment_total', 0,
      'cancelled_count', c.cancelled_count,
      'pending_count', c.pending_count,
      'no_payout_eligible_count', c.no_payout_eligible_count,
      'payout_minus_count', c.payout_minus_count,
      'payout_minus_total_abs', c.payout_minus_total_abs,
      'other_count', c.other_count,
      'source_breakdown', jsonb_build_object(
        'confirmed_sample_count', c.confirmed_sample_count,
        'sample_raw_tiktok_order_count', c.sample_raw_tiktok_order_count,
        'sample_raw_tiktok_item_row_count', c.sample_raw_tiktok_item_row_count,
        'sample_raw_tiktok_api_flag_count', c.sample_raw_tiktok_api_flag_count,
        'sample_raw_tiktok_import_count', c.sample_raw_tiktok_import_count,
        'sample_text_marker_count', c.sample_text_marker_count,
        'sample_label_count', c.sample_label_count,
        'sample_discount_100_count', c.sample_discount_100_count,
        'sample_finance_flag_count', c.sample_finance_flag_count,
        'cancelled_count', c.cancelled_count,
        'pending_count', c.pending_count,
        'no_payout_eligible_count', c.no_payout_eligible_count,
        'payout_minus_count', c.payout_minus_count,
        'other_count', c.other_count
      )
    ),
    coalesce(jsonb_agg(jsonb_build_object(
      'abnormal_status', 'SAMPLE_FREE',
      'finance_status', 'SAMPLE_FREE',
      'payout_status', 'SAMPLE_FREE',
      'category', 'sample_free',
      'classification_category', 'confirmed_sample',
      'sample_evidence_source', sample_evidence_source,
      'payout_minus_reason', null,
      'message', 'Confirmed Sample/Gratis berdasarkan bukti raw TikTok sample/export.',
      'marketplace', marketplace_group,
      'marketplace_account_id', marketplace_account_id,
      'marketplace_order_id', marketplace_order_id,
      'order_id', order_key,
      'order_sn', order_key,
      'external_order_id', order_key,
      'order_status', order_status,
      'status_label', display_status,
      'substatus_label', display_substatus,
      'order_date', order_created_at,
      'gross_amount', gross_amount,
      'payout_amount', 0,
      'raw_tiktok_item_row_count', raw_item_row_count,
      'resi', tracking_number,
      'tracking_number', tracking_number,
      'is_sample_order', true
    ) order by order_created_at desc) filter (where marketplace_group is not null), '[]'::jsonb)
  into v_summary, v_rows
  from counts c
  left join limited on true
  group by c.confirmed_sample_count, c.sample_text_marker_count, c.sample_label_count,
           c.sample_discount_100_count, c.sample_finance_flag_count,
           c.sample_raw_tiktok_order_count, c.sample_raw_tiktok_item_row_count,
           c.sample_raw_tiktok_api_flag_count, c.sample_raw_tiktok_import_count,
           c.sample_status_breakdown, c.sample_substatus_breakdown,
           c.sample_gross_total, c.cancelled_count, c.pending_count,
           c.no_payout_eligible_count, c.payout_minus_count, c.payout_minus_total_abs,
           c.other_count;

  return jsonb_build_object(
    'ok', true,
    'source', 'finance_sample_order_counts',
    'version', 'raw_tiktok_sample_proof_fast_20260621',
    'timezone', 'Asia/Jakarta',
    'start_date', v_start,
    'end_date', v_end,
    'effective_marketplace', v_marketplace,
    'summary', coalesce(v_summary, '{}'::jsonb),
    'rows', coalesce(v_rows, '[]'::jsonb),
    'sample_orders', coalesce(v_rows, '[]'::jsonb)
  );
end;
$$;

grant execute on function public.finance_sample_order_counts(date, date, text, uuid, boolean, integer, integer) to authenticated, service_role;

notify pgrst, 'reload schema';

commit;
