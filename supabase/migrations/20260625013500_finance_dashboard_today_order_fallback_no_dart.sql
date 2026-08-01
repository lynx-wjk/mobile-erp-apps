do $$
begin
  if to_regprocedure('public.finance_dashboard_snapshot_alias_20260625(date,date,text,uuid)') is null then
    alter function public.finance_dashboard_snapshot(date,date,text,uuid)
      rename to finance_dashboard_snapshot_alias_20260625;
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
  v_start date := coalesce(p_start, date_trunc('month', now() at time zone 'Asia/Jakarta')::date);
  v_end date := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);
  v_marketplace text := nullif(lower(trim(coalesce(p_marketplace,''))), '');
  v_user_id uuid;
  v_tenant_id uuid;
  v_order_mp jsonb := '[]'::jsonb;
  v_order_total numeric := 0;
  v_order_count integer := 0;
begin
  if v_marketplace in ('all','semua','_all','*') then
    v_marketplace := null;
  end if;

  j := public.finance_dashboard_snapshot_alias_20260625(
    p_start,p_end,p_marketplace,p_account_id
  );

  begin
    v_user_id := nullif(
      coalesce(
        auth.uid()::text,
        (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
      ),
      ''
    )::uuid;
  exception when others then
    v_user_id := null;
  end;

  select u.tenant_id
    into v_tenant_id
  from public.users u
  where u.user_id = v_user_id
  limit 1;

  if v_tenant_id is not null then
    with orders as (
      select
        public._finance_marketplace_norm_20260624(o.marketplace) as marketplace,
        count(*)::integer as order_count,
        coalesce(sum(coalesce(nullif(to_jsonb(o)->>'gross_amount','')::numeric, nullif(to_jsonb(o)->>'total_amount','')::numeric, nullif(to_jsonb(o)->>'paid_amount','')::numeric, 0)),0)::numeric as omzet_total
      from public.marketplace_orders o
      where o.tenant_id = v_tenant_id
        and (o.order_created_at at time zone 'Asia/Jakarta')::date between v_start and v_end
        and (p_account_id is null or o.marketplace_account_id = p_account_id)
        and (
          v_marketplace is null
          or public._finance_marketplace_norm_20260624(o.marketplace) = public._finance_marketplace_norm_20260624(v_marketplace)
        )
        and lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) not like '%cancel%'
        and lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) not like '%batal%'
        and lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) not like '%unpaid%'
      group by public._finance_marketplace_norm_20260624(o.marketplace)
    )
    select
      coalesce(jsonb_agg(jsonb_build_object(
        'marketplace', marketplace,
        'marketplace_name', marketplace,
        'omzet_total', omzet_total,
        'gross_sales', omzet_total,
        'gross_total', omzet_total,
        'order_count', order_count,
        'orders_count', order_count,
        'payout_total', 0,
        'payout_amount', 0,
        'net_settlement', 0,
        'received_amount', 0
      ) order by marketplace), '[]'::jsonb),
      coalesce(sum(omzet_total),0),
      coalesce(sum(order_count),0)::integer
    into v_order_mp, v_order_total, v_order_count
    from orders;
  end if;

  -- Kalau range hari ini / range dengan finance marketplace kosong, pakai order fallback.
  if v_order_count > 0 and (
    v_start = v_end
    or jsonb_array_length(coalesce(j->'marketplace_breakdown','[]'::jsonb)) = 0
  ) then
    j := jsonb_set(j, '{by_marketplace}', v_order_mp, true);
    j := jsonb_set(j, '{marketplaces}', v_order_mp, true);
    j := jsonb_set(j, '{marketplace_breakdown}', v_order_mp, true);

    j := jsonb_set(j, '{omzet_total}', to_jsonb(v_order_total), true);
    j := jsonb_set(j, '{gross_sales}', to_jsonb(v_order_total), true);
    j := jsonb_set(j, '{order_count}', to_jsonb(v_order_count), true);
    j := jsonb_set(j, '{orders_count}', to_jsonb(v_order_count), true);

    j := jsonb_set(j, '{summary,omzet_total}', to_jsonb(v_order_total), true);
    j := jsonb_set(j, '{summary,gross_sales}', to_jsonb(v_order_total), true);
    j := jsonb_set(j, '{summary,order_count}', to_jsonb(v_order_count), true);
    j := jsonb_set(j, '{summary,orders_count}', to_jsonb(v_order_count), true);
  end if;

  j := jsonb_set(
    j,
    '{source}',
    to_jsonb((coalesce(j->>'source','finance_dashboard_snapshot') || '+today_order_fallback_no_dart_20260625')::text),
    true
  );

  return j;
end;
$$;

grant execute on function public.finance_dashboard_snapshot(date,date,text,uuid)
to anon, authenticated, service_role;

notify pgrst, 'reload schema';