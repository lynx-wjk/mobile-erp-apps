-- Remove invalid TikTok finance report rows created from successful API
-- envelopes that contained no settlement data. The predicate intentionally
-- matches only the confirmed zero/no-data rows from the 2026-06-22 ingestion
-- run and preserves all non-zero payout rows.

begin;

delete from public.marketplace_finance_reports
where marketplace = 'tiktok_shop'
  and created_at >= timestamptz '2026-06-22 08:18:00+00'
  and payout_amount = 0
  and gross_sales = 0
  and transaction_count = 0
  and (raw_finance #>> '{data,total_count}')::numeric = 0
  and (raw_finance #>> '{data,settlement_amount}')::numeric = 0
  and (raw_finance #>> '{data,revenue_amount}')::numeric = 0
  and (raw_finance #> '{data,sku_transactions}') = '[]'::jsonb;

commit;
