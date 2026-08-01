-- 9I-J canonical finance payout trigger function.
-- Creates canonical payout normalizer + trigger function, then repoints marketplace_finance_reports trigger.
-- Old *_v24_6_25 functions are intentionally kept; no DROP FUNCTION here.
-- Body is copied 1:1 from old functions, only names are canonicalized.

create or replace function public.finance_report_normalized_payout_amount(
  p_payout_amount numeric,
  p_received_amount numeric,
  p_net_settlement numeric,
  p_raw_finance jsonb,
  p_raw_response jsonb,
  p_raw_report jsonb
)
returns numeric
language plpgsql
immutable
as $function$
declare
  v_text text;
  v_result numeric;
begin
  if coalesce(p_payout_amount, 0) <> 0 then
    return p_payout_amount;
  end if;

  if coalesce(p_received_amount, 0) <> 0 then
    return p_received_amount;
  end if;

  if coalesce(p_net_settlement, 0) <> 0 then
    return p_net_settlement;
  end if;

  v_text := coalesce(
    nullif(p_raw_finance #>> '{data,settlement_amount}', ''),
    nullif(p_raw_finance #>> '{data,payout_amount}', ''),
    nullif(p_raw_finance #>> '{data,received_amount}', ''),
    nullif(p_raw_finance #>> '{data,revenue_amount}', ''),
    nullif(p_raw_finance ->> 'settlement_amount', ''),
    nullif(p_raw_finance ->> 'payout_amount', ''),
    nullif(p_raw_finance ->> 'received_amount', ''),
    nullif(p_raw_response #>> '{data,settlement_amount}', ''),
    nullif(p_raw_response #>> '{data,payout_amount}', ''),
    nullif(p_raw_response #>> '{data,received_amount}', ''),
    nullif(p_raw_report ->> 'settlement_amount', ''),
    nullif(p_raw_report ->> 'payout_amount', ''),
    nullif(p_raw_report ->> 'received_amount', '')
  );

  if coalesce(v_text, '') ~ '^-?[0-9]+(\.[0-9]+)?$' then
    v_result := v_text::numeric;
    if coalesce(v_result, 0) <> 0 then
      return v_result;
    end if;
  end if;

  return coalesce(p_payout_amount, 0);
end;
$function$;

create or replace function public.finance_reports_set_payout_amount()
returns trigger
language plpgsql
as $function$
begin
  NEW.payout_amount := public.finance_report_normalized_payout_amount(
    NEW.payout_amount,
    NEW.received_amount,
    NEW.net_settlement,
    NEW.raw_finance,
    NEW.raw_response,
    NEW.raw_report
  );

  return NEW;
end;
$function$;

do $$
declare
  v_def text;
begin
  select pg_get_triggerdef(t.oid, true)
    into v_def
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = 'marketplace_finance_reports'
    and t.tgname = 'trg_finance_reports_set_payout_amount_v24_6_25'
    and not t.tgisinternal;

  if v_def is null then
    raise exception 'Old trigger not found: trg_finance_reports_set_payout_amount_v24_6_25';
  end if;

  execute 'drop trigger if exists trg_finance_reports_set_payout_amount_v24_6_25 on public.marketplace_finance_reports';

  v_def := replace(
    v_def,
    'CREATE TRIGGER trg_finance_reports_set_payout_amount_v24_6_25',
    'CREATE TRIGGER trg_finance_reports_set_payout_amount'
  );

  v_def := replace(
    v_def,
    'EXECUTE FUNCTION finance_reports_set_payout_amount_v24_6_25()',
    'EXECUTE FUNCTION public.finance_reports_set_payout_amount()'
  );

  v_def := replace(
    v_def,
    'EXECUTE FUNCTION public.finance_reports_set_payout_amount_v24_6_25()',
    'EXECUTE FUNCTION public.finance_reports_set_payout_amount()'
  );

  execute v_def;
end $$;

notify pgrst, 'reload schema';
