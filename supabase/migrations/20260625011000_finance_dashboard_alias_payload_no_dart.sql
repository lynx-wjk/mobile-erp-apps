do $$
begin
  if to_regprocedure('public.finance_dashboard_snapshot_core_20260625(date,date,text,uuid)') is null then
    alter function public.finance_dashboard_snapshot(date,date,text,uuid)
      rename to finance_dashboard_snapshot_core_20260625;
  end if;
end $$;

create or replace function public.finance_dashboard_snapshot(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  j jsonb;
  s jsonb;
  mp jsonb;
  cf jsonb;
  pl jsonb;
  fee jsonb;
begin
  j := public.finance_dashboard_snapshot_core_20260625(
    p_start,
    p_end,
    p_marketplace,
    p_account_id
  );

  s := coalesce(j->'summary', '{}'::jsonb);

  mp := coalesce(
    j->'marketplace_breakdown',
    j->'by_marketplace',
    j->'marketplaces',
    '[]'::jsonb
  );

  if jsonb_typeof(mp) is distinct from 'array' then
    mp := '[]'::jsonb;
  end if;

  cf := coalesce(j->'cash_flow', '[]'::jsonb);
  if jsonb_typeof(cf) is distinct from 'array' then
    cf := '[]'::jsonb;
  end if;

  -- Defensive: hapus row total marketplace kalau masih kebawa dari core lama.
  select coalesce(jsonb_agg(x), '[]'::jsonb)
  into cf
  from jsonb_array_elements(cf) x
  where lower(coalesce(x->>'category','')) not in (
    'payout marketplace',
    'marketplace payout',
    'total marketplace',
    'total payout marketplace'
  );

  pl := coalesce(
    j->'profit_loss',
    j->'profit_loss_breakdown',
    j->'deduction_breakdown',
    '[]'::jsonb
  );

  if jsonb_typeof(pl) is distinct from 'array' then
    pl := '[]'::jsonb;
  end if;

  fee := coalesce(j->'fee_breakdown', '{}'::jsonb);
  if jsonb_typeof(fee) is distinct from 'object' then
    fee := '{}'::jsonb;
  end if;

  -- Alias marketplace untuk semua tab lama/baru.
  j := jsonb_set(j, '{by_marketplace}', mp, true);
  j := jsonb_set(j, '{marketplaces}', mp, true);
  j := jsonb_set(j, '{marketplace_breakdown}', mp, true);
  j := jsonb_set(j, '{profit_loss_by_marketplace}', mp, true);

  -- Alias cashflow/laba rugi.
  j := jsonb_set(j, '{cash_flow}', cf, true);
  j := jsonb_set(j, '{cashflow}', cf, true);
  j := jsonb_set(j, '{profit_loss}', pl, true);
  j := jsonb_set(j, '{profit_loss_breakdown}', pl, true);
  j := jsonb_set(j, '{deduction_breakdown}', pl, true);
  j := jsonb_set(j, '{fee_breakdown}', fee, true);

  -- Alias top-level untuk tab Ringkasan yang baca top-level, bukan summary.
  j := jsonb_set(j, '{omzet_total}', coalesce(s->'omzet_total', s->'gross_sales', s->'gross_total', '0'::jsonb), true);
  j := jsonb_set(j, '{gross_sales}', coalesce(s->'gross_sales', s->'gross_total', s->'omzet_total', '0'::jsonb), true);
  j := jsonb_set(j, '{order_count}', coalesce(s->'order_count', s->'orders_count', '0'::jsonb), true);
  j := jsonb_set(j, '{orders_count}', coalesce(s->'orders_count', s->'order_count', '0'::jsonb), true);
  j := jsonb_set(j, '{payout_total}', coalesce(s->'payout_total', s->'payout_amount', s->'net_settlement', s->'received_amount', '0'::jsonb), true);
  j := jsonb_set(j, '{hpp_total}', coalesce(s->'hpp_total', s->'total_hpp', '0'::jsonb), true);
  j := jsonb_set(j, '{expense_total}', coalesce(s->'expense_total', s->'biaya_total', '0'::jsonb), true);
  j := jsonb_set(j, '{biaya_total}', coalesce(s->'biaya_total', s->'expense_total', '0'::jsonb), true);
  j := jsonb_set(j, '{net_profit}', coalesce(s->'net_profit', s->'profit', '0'::jsonb), true);

  j := jsonb_set(
    j,
    '{source}',
    to_jsonb((coalesce(j->>'source','finance_dashboard_snapshot') || '+alias_payload_no_dart_20260625')::text),
    true
  );

  return j;
end;
$$;

grant execute on function public.finance_dashboard_snapshot(date,date,text,uuid)
to anon, authenticated, service_role;

notify pgrst, 'reload schema';