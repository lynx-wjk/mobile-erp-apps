-- Fast finance breakdown backfill from import staging.
-- Avoids jsonb_agg(raw_row) per order, so it can run on 20k+ TikTok income rows.

create or replace function public.marketplace_backfill_finance_report_breakdown_from_staging(
  p_account_id uuid default null,
  p_marketplace text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '10min'
as $$
declare
  v_updated integer := 0;
  v_grouped integer := 0;
  v_marketplace text := coalesce(public.marketplace_normalize_key(p_marketplace), p_marketplace);
begin
  create temporary table tmp_finance_staging_breakdown on commit drop as
  select
    a.tenant_id,
    a.marketplace_account_id,
    a.marketplace,
    r.marketplace_order_sn as order_id,
    count(*)::integer as finance_rows,
    sum(coalesce(public.marketplace_import_text_num(nullif(r.normalized_row->>'discount_amount', '')), 0)) as discount_amount,
    sum(coalesce(public.marketplace_import_text_num(nullif(r.normalized_row->>'seller_discount', '')), 0)) as seller_discount,
    sum(coalesce(public.marketplace_import_text_num(nullif(r.normalized_row->>'platform_discount', '')), 0)) as platform_discount,
    sum(coalesce(public.marketplace_import_text_num(nullif(r.normalized_row->>'platform_fee', '')), 0)) as platform_fee,
    sum(coalesce(public.marketplace_import_text_num(nullif(r.normalized_row->>'commission_fee', '')), 0)) as commission_fee,
    sum(coalesce(public.marketplace_import_text_num(nullif(r.normalized_row->>'affiliate_fee', '')), 0)) as affiliate_fee,
    sum(coalesce(public.marketplace_import_text_num(nullif(r.normalized_row->>'shipping_fee', '')), 0)) as shipping_fee,
    sum(coalesce(public.marketplace_import_text_num(nullif(r.normalized_row->>'payment_transaction_fee', '')), 0)) as payment_transaction_fee,
    sum(coalesce(public.marketplace_import_text_num(nullif(r.normalized_row->>'other_fee', '')), 0)) as other_fee,
    sum(coalesce(public.marketplace_import_text_num(nullif(r.normalized_row->>'refund_amount', '')), 0)) as refund_amount,
    sum(coalesce(public.marketplace_import_text_num(nullif(r.normalized_row->>'tax_amount', '')), 0)) as tax_amount,
    sum(coalesce(public.marketplace_import_text_num(nullif(r.normalized_row->>'adjustment_amount', '')), 0)) as adjustment_amount,
    sum(coalesce(public.marketplace_import_text_num(nullif(r.normalized_row->>'fee_amount', '')), 0)) as fee_amount,
    sum(coalesce(public.marketplace_import_text_num(nullif(r.normalized_row->>'total_fees', '')), 0)) as total_fees
  from public.marketplace_finance_export_import_rows r
  join public.marketplace_finance_export_import_batches b
    on b.marketplace_finance_export_import_batch_id = r.batch_id
  join public.marketplace_accounts a
    on a.marketplace_account_id = b.marketplace_account_id
  where nullif(r.marketplace_order_sn, '') is not null
    and (p_account_id is null or a.marketplace_account_id = p_account_id)
    and (
      v_marketplace is null
      or v_marketplace = ''
      or v_marketplace = 'all'
      or a.marketplace = v_marketplace
    )
  group by a.tenant_id, a.marketplace_account_id, a.marketplace, r.marketplace_order_sn;

  get diagnostics v_grouped = row_count;

  create index on tmp_finance_staging_breakdown(tenant_id, marketplace_account_id, marketplace, order_id);

  with prepared as (
    select
      *,
      abs(coalesce(discount_amount, 0)) as v_discount_amount,
      abs(coalesce(platform_fee, 0)) as v_platform_fee,
      abs(coalesce(commission_fee, 0)) as v_commission_fee,
      abs(coalesce(affiliate_fee, 0)) as v_affiliate_fee,
      abs(coalesce(shipping_fee, 0)) as v_shipping_fee,
      abs(coalesce(payment_transaction_fee, 0)) as v_payment_transaction_fee,
      abs(coalesce(other_fee, 0)) as v_other_fee,
      abs(coalesce(refund_amount, 0)) as v_refund_amount,
      abs(coalesce(tax_amount, 0)) as v_tax_amount,
      coalesce(adjustment_amount, 0) as v_adjustment_amount,
      greatest(
        abs(coalesce(total_fees, 0)),
        abs(coalesce(fee_amount, 0)),
        abs(coalesce(platform_fee, 0)) +
        abs(coalesce(commission_fee, 0)) +
        abs(coalesce(affiliate_fee, 0)) +
        abs(coalesce(shipping_fee, 0)) +
        abs(coalesce(payment_transaction_fee, 0)) +
        abs(coalesce(other_fee, 0))
      ) as v_total_fees
    from tmp_finance_staging_breakdown
  ),
  updated as (
    update public.marketplace_finance_reports fr
    set
      discount_amount = p.v_discount_amount,
      platform_fee = p.v_platform_fee,
      commission_fee = p.v_commission_fee,
      affiliate_fee = p.v_affiliate_fee,
      shipping_fee = p.v_shipping_fee,
      fee_amount = p.v_total_fees,
      total_fees = p.v_total_fees,
      refund_amount = p.v_refund_amount,
      total_refund = p.v_refund_amount,
      adjustment_amount = p.v_adjustment_amount,
      raw_finance = coalesce(fr.raw_finance, '{}'::jsonb) || jsonb_build_object(
        'breakdown_source', 'historical_import_staging_backfill_fast',
        'breakdown_backfilled_at', now(),
        'finance_rows', p.finance_rows,
        'seller_discount', p.seller_discount,
        'platform_discount', p.platform_discount,
        'payment_transaction_fee', p.v_payment_transaction_fee,
        'other_fee', p.v_other_fee,
        'tax_amount', p.v_tax_amount
      ),
      raw_report = coalesce(fr.raw_report, '{}'::jsonb) || jsonb_build_object(
        'breakdown_source', 'historical_import_staging_backfill_fast',
        'finance_rows', p.finance_rows
      ),
      raw_response = coalesce(fr.raw_response, '{}'::jsonb) || jsonb_build_object(
        'breakdown_source', 'historical_import_staging_backfill_fast',
        'finance_rows', p.finance_rows
      ),
      updated_at = now()
    from prepared p
    where fr.tenant_id = p.tenant_id
      and fr.marketplace_account_id = p.marketplace_account_id
      and fr.marketplace = p.marketplace
      and fr.order_id = p.order_id
    returning 1
  )
  select count(*) into v_updated from updated;

  return jsonb_build_object(
    'ok', true,
    'mode', 'fast_no_raw_json_agg',
    'grouped_orders', v_grouped,
    'updated_reports', v_updated,
    'account_id', p_account_id,
    'marketplace', p_marketplace
  );
end;
$$;

grant execute on function public.marketplace_backfill_finance_report_breakdown_from_staging(uuid, text)
  to authenticated, service_role;

notify pgrst, 'reload schema';
