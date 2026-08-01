-- Overlay finance dashboard current-day omzet/order_count from marketplace_orders realtime.
-- This keeps payout/settlement finance logic intact, but makes today's omzet match marketplace analytic.

do $$
begin
  if to_regprocedure('public.finance_dashboard_snapshot_base_20260624_realtime(date,date,text,uuid)') is null then
    alter function public.finance_dashboard_snapshot(date,date,text,uuid)
      rename to finance_dashboard_snapshot_base_20260624_realtime;
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
security invoker
set search_path = public
as $$
declare
  v_json jsonb;
  v_start date := coalesce(p_start, date_trunc('month', now() at time zone 'Asia/Jakarta')::date);
  v_end date := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);
  v_today date := (now() at time zone 'Asia/Jakarta')::date;

  v_today_omzet numeric := 0;
  v_today_orders integer := 0;
  v_old_today_omzet numeric := 0;
  v_old_today_orders integer := 0;
  v_delta_omzet numeric := 0;
  v_delta_orders integer := 0;

  v_daily jsonb := '[]'::jsonb;
  v_has_today boolean := false;

  v_current_omzet numeric := 0;
  v_current_orders integer := 0;
  v_new_omzet numeric := 0;
  v_new_orders integer := 0;
begin
  v_json := public.finance_dashboard_snapshot_base_20260624_realtime(
    p_start,
    p_end,
    p_marketplace,
    p_account_id
  );

  if v_today < v_start or v_today > v_end then
    return v_json;
  end if;

  select
    count(*)::integer,
    coalesce(sum(coalesce(nullif(to_jsonb(o)->>'gross_amount', '')::numeric, 0)), 0)::numeric
  into v_today_orders, v_today_omzet
  from public.marketplace_orders o
  where (coalesce(
      nullif(to_jsonb(o)->>'order_created_at', ''),
      nullif(to_jsonb(o)->>'created_at', '')
    )::timestamptz at time zone 'Asia/Jakarta')::date = v_today
    and (p_account_id is null or o.marketplace_account_id = p_account_id)
    and (
      coalesce(trim(p_marketplace), '') = ''
      or public._finance_marketplace_norm_20260624(to_jsonb(o)->>'marketplace')
         = public._finance_marketplace_norm_20260624(p_marketplace)
    )
    and upper(coalesce(
      to_jsonb(o)->>'order_status',
      to_jsonb(o)->>'status',
      ''
    )) not in ('CANCELLED', 'CANCELED', 'REFUND', 'RETURN', 'RETURNED');

  v_daily := coalesce(v_json->'daily', '[]'::jsonb);

  select
    coalesce(max(coalesce(nullif(elem->>'omzet_total', '')::numeric, nullif(elem->>'gross_sales', '')::numeric, 0)), 0),
    coalesce(max(coalesce(nullif(elem->>'order_count', '')::integer, nullif(elem->>'orders_count', '')::integer, 0)), 0),
    coalesce(bool_or(
      (coalesce(elem->>'date', elem->>'period_start', elem->>'day', '')::date) = v_today
    ), false)
  into v_old_today_omzet, v_old_today_orders, v_has_today
  from jsonb_array_elements(v_daily) elem
  where coalesce(elem->>'date', elem->>'period_start', elem->>'day', '') ~ '^\d{4}-\d{2}-\d{2}$'
    and (coalesce(elem->>'date', elem->>'period_start', elem->>'day', '')::date) = v_today;

  v_delta_omzet := v_today_omzet - coalesce(v_old_today_omzet, 0);
  v_delta_orders := v_today_orders - coalesce(v_old_today_orders, 0);

  if jsonb_array_length(v_daily) > 0 then
    select coalesce(jsonb_agg(
      case
        when coalesce(elem->>'date', elem->>'period_start', elem->>'day', '') ~ '^\d{4}-\d{2}-\d{2}$'
         and (coalesce(elem->>'date', elem->>'period_start', elem->>'day', '')::date) = v_today
        then elem || jsonb_build_object(
          'date', to_char(v_today, 'YYYY-MM-DD'),
          'period_start', to_char(v_today, 'YYYY-MM-DD'),
          'omzet_total', v_today_omzet,
          'gross_sales', v_today_omzet,
          'gross_amount', v_today_omzet,
          'order_count', v_today_orders,
          'orders_count', v_today_orders,
          'realtime_order_overlay', true
        )
        else elem
      end
      order by ord
    ), '[]'::jsonb)
    into v_daily
    from jsonb_array_elements(v_daily) with ordinality t(elem, ord);
  end if;

  if not v_has_today then
    v_daily := v_daily || jsonb_build_array(jsonb_build_object(
      'date', to_char(v_today, 'YYYY-MM-DD'),
      'period_start', to_char(v_today, 'YYYY-MM-DD'),
      'omzet_total', v_today_omzet,
      'gross_sales', v_today_omzet,
      'gross_amount', v_today_omzet,
      'order_count', v_today_orders,
      'orders_count', v_today_orders,
      'realtime_order_overlay', true
    ));
  end if;

  v_json := jsonb_set(v_json, '{daily}', v_daily, true);

  v_current_omzet := coalesce(
    nullif(v_json->>'omzet_total', '')::numeric,
    nullif(v_json->>'gross_sales', '')::numeric,
    nullif(v_json#>>'{summary,omzet_total}', '')::numeric,
    nullif(v_json#>>'{summary,gross_sales}', '')::numeric,
    0
  );

  v_current_orders := coalesce(
    nullif(v_json->>'order_count', '')::integer,
    nullif(v_json->>'orders_count', '')::integer,
    nullif(v_json#>>'{summary,order_count}', '')::integer,
    nullif(v_json#>>'{summary,orders_count}', '')::integer,
    0
  );

  if v_start = v_today and v_end = v_today then
    v_new_omzet := v_today_omzet;
    v_new_orders := v_today_orders;
  else
    v_new_omzet := v_current_omzet + v_delta_omzet;
    v_new_orders := v_current_orders + v_delta_orders;
  end if;

  v_json := v_json || jsonb_build_object(
    'omzet_total', v_new_omzet,
    'gross_sales', v_new_omzet,
    'gross_amount', v_new_omzet,
    'order_count', v_new_orders,
    'orders_count', v_new_orders,
    'today_realtime_order_overlay', true
  );

  v_json := jsonb_set(
    v_json,
    '{summary}',
    coalesce(v_json->'summary', '{}'::jsonb) || jsonb_build_object(
      'omzet_total', v_new_omzet,
      'gross_sales', v_new_omzet,
      'gross_amount', v_new_omzet,
      'order_count', v_new_orders,
      'orders_count', v_new_orders,
      'today_realtime_order_overlay', true
    ),
    true
  );

  return v_json;
end $$;

revoke all on function public.finance_dashboard_snapshot(date,date,text,uuid) from public;
grant execute on function public.finance_dashboard_snapshot(date,date,text,uuid) to authenticated, service_role;

notify pgrst, 'reload schema';