-- Normalize TikTok finance rows that arrived without settlement_date.
-- Keeps finance dashboard payout based on settlement_date without dropping valid TikTok rows.
update public.marketplace_finance_reports fr
set
  settlement_date = coalesce(fr.period_start::date, fr.created_at::date),
  period_start = coalesce(fr.period_start, coalesce(fr.period_start::date, fr.created_at::date)),
  period_end = coalesce(fr.period_end, coalesce(fr.period_start::date, fr.created_at::date)),
  updated_at = now()
where fr.marketplace in ('tiktok_shop', 'tiktok')
  and fr.settlement_date is null
  and coalesce(fr.period_start::date, fr.created_at::date) is not null;

notify pgrst, 'reload schema';
