-- Backfill normalized marketplace finance breakdown from historical import staging.
-- Used after app import/finalize so TikTok Excel detail fee/voucher/refund is not lost.

create or replace function public.marketplace_backfill_finance_report_breakdown_from_staging(
  p_account_id uuid default null,
  p_marketplace text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '120s'
as $$
declare
  v_updated integer := 0;
begin
  with staging as (
    select
      a.tenant_id,
      a.marketplace_account_id,
      a.marketplace,
      r.marketplace_order_sn as order_id,
      sum(public.marketplace_import_text_num(nullif(r.normalized_row->>'discount_amount', ''))) as discount_amount,
      sum(public.marketplace_import_text_num(nullif(r.normalized_row->>'seller_discount', ''))) as seller_discount,
      sum(public.marketplace_import_text_num(nullif(r.normalized_row->>'platform_discount', ''))) as platform_discount,
      sum(public.marketplace_import_text_num(nullif(r.normalized_row->>'platform_fee', ''))) as platform_fee,
      sum(public.marketplace_import_text_num(nullif(r.normalized_row->>'commission_fee', ''))) as commission_fee,
      sum(public.marketplace_import_text_num(nullif(r.normalized_row->>'affiliate_fee', ''))) as affiliate_fee,
      sum(public.marketplace_import_text_num(nullif(r.normalized_row->>'shipping_fee', ''))) as shipping_fee,
      sum(public.marketplace_import_text_num(nullif(r.normalized_row->>'payment_transaction_fee', ''))) as payment_transaction_fee,
      sum(public.marketplace_import_text_num(nullif(r.normalized_row->>'other_fee', ''))) as other_fee,
      sum(public.marketplace_import_text_num(nullif(r.normalized_row->>'refund_amount', ''))) as refund_amount,
      sum(public.marketplace_import_text_num(nullif(r.normalized_row->>'tax_amount', ''))) as tax_amount,
      sum(public.marketplace_import_text_num(nullif(r.normalized_row->>'adjustment_amount', ''))) as adjustment_amount,
      sum(public.marketplace_import_text_num(nullif(r.normalized_row->>'fee_amount', ''))) as legacy_fee_amount,
      jsonb_agg(jsonb_build_object(
        'row_index', r.row_index,
        'normalized_row', r.normalized_row,
        'raw_row', r.raw_row
      ) order by r.row_index) as finance_rows
    from public.marketplace_finance_export_import_rows r
    join public.marketplace_finance_export_import_batches b
      on b.marketplace_finance_export_import_batch_id = r.batch_id
    join public.marketplace_accounts a
      on a.marketplace_account_id = b.marketplace_account_id
    where nullif(r.marketplace_order_sn, '') is not null
      and (p_account_id is null or a.marketplace_account_id = p_account_id)
      and (
        p_marketplace is null
        or p_marketplace = ''
        or p_marketplace = 'all'
        or a.marketplace = coalesce(public.marketplace_normalize_key(p_marketplace), p_marketplace)
      )
    group by
      a.tenant_id,
      a.marketplace_account_id,
      a.marketplace,
      r.marketplace_order_sn
  ),
  prepared as (
    select
      *,
      coalesce(discount_amount, 0) as v_discount_amount,
      coalesce(platform_fee, 0) as v_platform_fee,
      coalesce(commission_fee, 0) as v_commission_fee,
      coalesce(affiliate_fee, 0) as v_affiliate_fee,
      coalesce(shipping_fee, 0) as v_shipping_fee,
      coalesce(payment_transaction_fee, 0) as v_payment_transaction_fee,
      coalesce(other_fee, 0) as v_other_fee,
      coalesce(refund_amount, 0) as v_refund_amount,
      coalesce(tax_amount, 0) as v_tax_amount,
      coalesce(adjustment_amount, 0) as v_adjustment_amount
    from staging
  ),
  updated as (
    update public.marketplace_finance_reports fr
    set
      discount_amount = abs(p.v_discount_amount),
      platform_fee = abs(p.v_platform_fee),
      commission_fee = abs(p.v_commission_fee),
      affiliate_fee = abs(p.v_affiliate_fee),
      shipping_fee = abs(p.v_shipping_fee),
      fee_amount = abs(
        p.v_platform_fee +
        p.v_commission_fee +
        p.v_affiliate_fee +
        p.v_shipping_fee +
        p.v_payment_transaction_fee +
        p.v_other_fee
      ),
      total_fees = abs(
        p.v_platform_fee +
        p.v_commission_fee +
        p.v_affiliate_fee +
        p.v_shipping_fee +
        p.v_payment_transaction_fee +
        p.v_other_fee
      ),
      refund_amount = abs(p.v_refund_amount),
      total_refund = abs(p.v_refund_amount),
      adjustment_amount = p.v_adjustment_amount,
      raw_finance = coalesce(fr.raw_finance, '{}'::jsonb) || jsonb_build_object(
        'breakdown_source', 'historical_import_staging_backfill',
        'breakdown_backfilled_at', now(),
        'seller_discount', p.seller_discount,
        'platform_discount', p.platform_discount,
        'payment_transaction_fee', p.v_payment_transaction_fee,
        'other_fee', p.v_other_fee,
        'tax_amount', p.v_tax_amount,
        'finance_rows', p.finance_rows
      ),
      raw_report = coalesce(fr.raw_report, '{}'::jsonb) || jsonb_build_object(
        'breakdown_source', 'historical_import_staging_backfill',
        'finance_rows', p.finance_rows
      ),
      raw_response = coalesce(fr.raw_response, '{}'::jsonb) || jsonb_build_object(
        'breakdown_source', 'historical_import_staging_backfill',
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
    'updated_reports', v_updated,
    'account_id', p_account_id,
    'marketplace', p_marketplace
  );
end;
$$;

grant execute on function public.marketplace_backfill_finance_report_breakdown_from_staging(uuid, text)
  to authenticated, service_role;

notify pgrst, 'reload schema';
