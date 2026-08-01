-- Migration: 20260725340000_fix_outer_snapshot_tenant_resolution.sql
-- Updates outer finance_dashboard_snapshot function to resolve tenant_id with fallback when user_id is null

CREATE OR REPLACE FUNCTION public.finance_dashboard_snapshot(
  p_start date DEFAULT NULL::date,
  p_end date DEFAULT NULL::date,
  p_marketplace text DEFAULT NULL::text,
  p_account_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
    p_start, p_end, p_marketplace, p_account_id
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

  v_tenant_id := coalesce(
    (select u.tenant_id from public.users u where u.user_id = v_user_id limit 1),
    (select u.tenant_id from public.users u where u.user_id = auth.uid() limit 1),
    (select tenant_id from public.users where tenant_id is not null limit 1),
    public.app_current_tenant_id_or_default()
  );

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

  if v_order_count > 0 and jsonb_array_length(coalesce(j->'marketplace_breakdown','[]'::jsonb)) = 0 then
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
$function$;
