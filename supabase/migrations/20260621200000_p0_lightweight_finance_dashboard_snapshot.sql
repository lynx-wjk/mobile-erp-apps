begin;

create or replace function public.finance_dashboard_snapshot(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '3s'
as $function$
declare
  v_claims jsonb := '{}'::jsonb;
  v_tenant_id uuid := null;
  v_role text := null;
  v_start date := coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date);
  v_end date := coalesce(p_end, timezone('Asia/Jakarta', now())::date);
  v_start_ts timestamptz := (coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date)::timestamp at time zone 'Asia/Jakarta');
  v_end_ts timestamptz := ((coalesce(p_end, timezone('Asia/Jakarta', now())::date) + 1)::timestamp at time zone 'Asia/Jakarta');
  v_marketplace text := null;
  v_summary jsonb := '{}'::jsonb;
  v_daily jsonb := '[]'::jsonb;
  v_by_marketplace jsonb := '[]'::jsonb;
  v_accounts jsonb := '[]'::jsonb;
begin
  begin
    v_claims := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  exception when others then
    v_claims := '{}'::jsonb;
  end;

  v_role := coalesce(nullif(v_claims->>'role', ''), nullif(current_setting('role', true), ''), current_user);
  v_tenant_id := coalesce(
    case
      when (v_claims->>'tenant_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (v_claims->>'tenant_id')::uuid
      else null::uuid
    end,
    (select u.tenant_id from public.users u where u.user_id = auth.uid() limit 1)
  );

  v_marketplace := case
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
    else null
  end;

  if v_role <> 'service_role' and v_tenant_id is null then
    return jsonb_build_object(
      'ok', true,
      'version', 'finance_dashboard_snapshot_light_20260621',
      'source', 'finance_dashboard_snapshot',
      'source_table', 'marketplace_finance_reports_light',
      'snapshot_mode', 'lightweight',
      'timezone', 'Asia/Jakarta',
      'start_date', v_start::text,
      'end_date', v_end::text,
      'requested_start_date', p_start,
      'requested_end_date', p_end,
      'requested_account_id', p_account_id,
      'marketplace', coalesce(p_marketplace, 'all'),
      'summary', jsonb_build_object(
        'omzet_total', 0,
        'gross_total', 0,
        'gross_sales', 0,
        'payout_total', 0,
        'payout_amount', 0,
        'hpp_total', 0,
        'total_hpp', 0,
        'manual_expense_total', 0,
        'approved_purchase_total', 0,
        'purchase_cashout', 0,
        'operational_expense', 0,
        'operational_cost_total', 0,
        'expense_total', 0,
        'net_profit', 0,
        'orders_count', 0,
        'order_count', 0,
        'finance_orders_count', 0,
        'finance_order_count', 0,
        'payout_minus_count', 0,
        'negative_payout_count', 0,
        'negative_payout_total_abs', 0,
        'payout_minus_total_abs', 0,
        'abnormal_count', 0,
        'source_count', 0
      ),
      'daily', '[]'::jsonb,
      'trend', '[]'::jsonb,
      'by_marketplace', '[]'::jsonb,
      'marketplaces', '[]'::jsonb,
      'profit_loss_by_marketplace', '[]'::jsonb,
      'accounts', '[]'::jsonb,
      'expenses', '[]'::jsonb,
      'approved_purchases', '[]'::jsonb,
      'skus', '[]'::jsonb,
      'sku_rows', '[]'::jsonb,
      'cash_flow', '[]'::jsonb,
      'profit_loss_breakdown', '[]'::jsonb,
      'abnormals', '[]'::jsonb
    );
  end if;

  with scoped_accounts as (
    select
      a.tenant_id,
      a.marketplace_account_id,
      case
        when lower(regexp_replace(coalesce(a.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(a.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
        else lower(regexp_replace(coalesce(a.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace_group,
      a.marketplace,
      coalesce(a.shop_name, a.store_alias, to_jsonb(a)->>'seller_name', a.shop_id, a.marketplace) as shop_name,
      a.store_alias,
      a.status,
      coalesce(a.is_active, lower(coalesce(a.status, 'active')) not in ('deleted', 'inactive', 'disabled')) as is_active
    from public.marketplace_accounts a
    where (v_role = 'service_role' or a.tenant_id = v_tenant_id)
      and (p_account_id is null or a.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or case
          when lower(regexp_replace(coalesce(a.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(a.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
          else lower(regexp_replace(coalesce(a.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
      and coalesce(a.is_deleted, false) = false
      and lower(coalesce(a.status, 'active')) <> 'deleted'
  ),
  finance_scoped as (
    select
      fr.tenant_id,
      fr.marketplace_account_id,
      case
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
        else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace_group,
      coalesce(fr.settlement_date, fr.period_start, fr.created_at::date)::date as day,
      nullif(fr.order_id, '') as order_key,
      coalesce(fr.gross_amount, fr.gross_sales, 0)::numeric as gross_amount,
      coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)::numeric as payout_amount,
      coalesce(fr.total_hpp, 0)::numeric as hpp_amount
    from public.marketplace_finance_reports fr
    where coalesce(fr.settlement_date, fr.period_start, fr.created_at::date)::date >= v_start
      and coalesce(fr.settlement_date, fr.period_start, fr.created_at::date)::date <= v_end
      and (v_role = 'service_role' or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or case
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
          else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
  ),
  operational_expenses as (
    select
      coalesce(sum(abs(e.amount)), 0)::numeric as manual_expense_total
    from public.finance_operational_expenses e
    where coalesce(e.expense_date, e.paid_at, e.created_at::date)::date >= v_start
      and coalesce(e.expense_date, e.paid_at, e.created_at::date)::date <= v_end
      and (v_role = 'service_role' or e.tenant_id = v_tenant_id)
      and lower(coalesce(e.status, 'posted')) not in ('void', 'deleted', 'cancelled', 'canceled')
  ),
  manual_expenses as (
    select
      coalesce(sum(abs(e.amount)), 0)::numeric as manual_expense_total
    from public.finance_manual_expenses e
    where e.expense_date >= v_start
      and e.expense_date <= v_end
      and (v_role = 'service_role' or e.tenant_id = v_tenant_id)
  ),
  purchase_request_totals as (
    select
      coalesce(sum(abs(pr.total_amount)), 0)::numeric as purchase_total
    from public.purchase_requests pr
    where coalesce(pr.tanggal_beli, pr.verified_at::date, pr.updated_at::date, pr.created_at::date) >= v_start
      and coalesce(pr.tanggal_beli, pr.verified_at::date, pr.updated_at::date, pr.created_at::date) <= v_end
      and (v_role = 'service_role' or pr.tenant_id = v_tenant_id)
      and lower(coalesce(pr.status, '')) ~ '(approved|approve|verified|accepted|done|paid)'
  ),
  purchase_totals as (
    select
      coalesce(sum(abs(p.total_pembelian)), 0)::numeric as purchase_total
    from public.purchases p
    where coalesce(p.tanggal, p.verified_at::date, p.updated_at::date, p.created_at::date) >= v_start
      and coalesce(p.tanggal, p.verified_at::date, p.updated_at::date, p.created_at::date) <= v_end
      and (v_role = 'service_role' or p.tenant_id = v_tenant_id)
      and lower(coalesce(p.status, '')) ~ '(approved|approve|verified|accepted|done|paid)'
  ),
  finance_account as (
    select
      tenant_id,
      marketplace_account_id,
      marketplace_group,
      count(distinct order_key)::integer as finance_order_count,
      coalesce(sum(gross_amount), 0)::numeric as finance_gross_total,
      coalesce(sum(payout_amount), 0)::numeric as payout_total,
      coalesce(sum(hpp_amount), 0)::numeric as hpp_total,
      count(*) filter (where payout_amount < 0)::integer as payout_minus_count,
      coalesce(sum(abs(payout_amount)) filter (where payout_amount < 0), 0)::numeric as payout_minus_total_abs
    from finance_scoped
    group by tenant_id, marketplace_account_id, marketplace_group
  ),
  account_rows as (
    select
      coalesce(f.tenant_id, a.tenant_id) as tenant_id,
      coalesce(f.marketplace_account_id, a.marketplace_account_id) as marketplace_account_id,
      coalesce(f.marketplace_group, a.marketplace_group) as marketplace_group,
      coalesce(a.marketplace, f.marketplace_group) as marketplace,
      coalesce(a.shop_name, coalesce(f.marketplace_group, 'Marketplace')) as shop_name,
      coalesce(f.finance_order_count, 0) as order_count,
      coalesce(f.finance_order_count, 0) as finance_order_count,
      coalesce(f.finance_gross_total, 0) as gross_sales,
      coalesce(f.payout_total, 0) as payout_total,
      coalesce(f.hpp_total, 0) as hpp_total,
      coalesce(f.payout_minus_count, 0) as payout_minus_count,
      coalesce(f.payout_minus_total_abs, 0) as payout_minus_total_abs
    from finance_account f
    full join scoped_accounts a
      on a.tenant_id = f.tenant_id
     and a.marketplace_account_id = f.marketplace_account_id
  ),
  summary_totals as (
    select
      coalesce(sum(gross_sales), 0)::numeric as gross_sales,
      coalesce(sum(payout_total), 0)::numeric as payout_total,
      coalesce(sum(hpp_total), 0)::numeric as hpp_total,
      coalesce(sum(order_count), 0)::integer as orders_count,
      coalesce(sum(finance_order_count), 0)::integer as finance_orders_count,
      coalesce(sum(payout_minus_count), 0)::integer as payout_minus_count,
      coalesce(sum(payout_minus_total_abs), 0)::numeric as payout_minus_total_abs,
      coalesce(count(*) filter (where order_count > 0 or finance_order_count > 0), 0)::integer as source_count
    from account_rows
  ),
  cost_totals as (
    select
      coalesce(oe.manual_expense_total, 0) + coalesce(me.manual_expense_total, 0) as manual_expense_total,
      coalesce(pr.purchase_total, 0) + coalesce(p.purchase_total, 0) as approved_purchase_total
    from operational_expenses oe
    cross join manual_expenses me
    cross join purchase_request_totals pr
    cross join purchase_totals p
  ),
  daily_finance as (
    select
      day,
      coalesce(sum(gross_amount), 0)::numeric as gross_total,
      coalesce(sum(payout_amount), 0)::numeric as payout_total,
      coalesce(sum(hpp_amount), 0)::numeric as hpp_total,
      count(distinct order_key)::integer as finance_orders_count,
      count(*) filter (where payout_amount < 0)::integer as negative_payout_count,
      coalesce(sum(abs(payout_amount)) filter (where payout_amount < 0), 0)::numeric as negative_payout_total_abs
    from finance_scoped
    group by day
  ),
  calendar as (
    select generate_series(v_start, v_end, interval '1 day')::date as day
  ),
  daily_rows as (
    select
      c.day,
      coalesce(f.gross_total, 0) as gross_total,
      coalesce(f.payout_total, 0) as payout_total,
      coalesce(f.hpp_total, 0) as hpp_total,
      coalesce(f.finance_orders_count, 0) as orders_count,
      coalesce(f.finance_orders_count, 0) as finance_orders_count,
      coalesce(f.negative_payout_count, 0) as negative_payout_count,
      coalesce(f.negative_payout_total_abs, 0) as negative_payout_total_abs
    from calendar c
    left join daily_finance f on f.day = c.day
  )
  select
    jsonb_build_object(
      'omzet_total', st.gross_sales,
      'gross_total', st.gross_sales,
      'gross_sales', st.gross_sales,
      'payout_total', st.payout_total,
      'payout_amount', st.payout_total,
      'received_amount', st.payout_total,
      'net_settlement', st.payout_total,
      'hpp_total', st.hpp_total,
      'total_hpp', st.hpp_total,
      'manual_expense_total', ct.manual_expense_total,
      'approved_purchase_total', ct.approved_purchase_total,
      'purchase_cashout', ct.approved_purchase_total,
      'operational_expense', ct.manual_expense_total + ct.approved_purchase_total,
      'operational_cost_total', ct.manual_expense_total + ct.approved_purchase_total,
      'expense_total', ct.manual_expense_total + ct.approved_purchase_total,
      'gross_profit', st.payout_total - st.hpp_total,
      'profit_before_expense', st.payout_total - st.hpp_total,
      'net_profit', st.payout_total - st.hpp_total - ct.manual_expense_total - ct.approved_purchase_total,
      'profit', st.payout_total - st.hpp_total - ct.manual_expense_total - ct.approved_purchase_total,
      'orders_count', st.orders_count,
      'order_count', st.orders_count,
      'finance_orders_count', st.finance_orders_count,
      'finance_order_count', st.finance_orders_count,
      'payout_minus_count', st.payout_minus_count,
      'negative_payout_count', st.payout_minus_count,
      'negative_payout_total_abs', st.payout_minus_total_abs,
      'payout_minus_total_abs', st.payout_minus_total_abs,
      'abnormal_count', st.payout_minus_count,
      'anomaly_count', st.payout_minus_count,
      'source_count', st.source_count,
      'marketplace_count', st.source_count,
      'summary_policy', 'lightweight_snapshot_no_reconciliation_no_sku_no_sample'
    ),
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'date', d.day,
        'order_date', d.day,
        'omzet_total', d.gross_total,
        'gross_total', d.gross_total,
        'gross_sales', d.gross_total,
        'payout_total', d.payout_total,
        'hpp_total', d.hpp_total,
        'orders_count', d.orders_count,
        'order_count', d.orders_count,
        'finance_orders_count', d.finance_orders_count,
        'abnormal_count', d.negative_payout_count,
        'negative_payout_total_abs', d.negative_payout_total_abs
      ) order by d.day)
      from daily_rows d
    ), '[]'::jsonb),
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'row_kind', 'lightweight_marketplace_summary',
        'marketplace', ar.marketplace_group,
        'marketplace_account_id', ar.marketplace_account_id,
        'shop_name', ar.shop_name,
        'account_name', ar.shop_name,
        'order_count', ar.order_count,
        'finance_order_count', ar.finance_order_count,
        'gross_sales', ar.gross_sales,
        'gross_total', ar.gross_sales,
        'omzet', ar.gross_sales,
        'payout_total', ar.payout_total,
        'payout_amount', ar.payout_total,
        'received_amount', ar.payout_total,
        'hpp_total', ar.hpp_total,
        'total_hpp', ar.hpp_total,
        'net_profit', ar.payout_total - ar.hpp_total,
        'profit', ar.payout_total - ar.hpp_total,
        'payout_minus_count', ar.payout_minus_count,
        'payout_minus_total_abs', ar.payout_minus_total_abs,
        'gross_payout_gap', greatest(ar.gross_sales - ar.payout_total, 0)
      ) order by ar.marketplace_group, ar.shop_name)
      from account_rows ar
      where ar.order_count > 0 or ar.finance_order_count > 0
    ), '[]'::jsonb),
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'marketplace_account_id', a.marketplace_account_id,
        'tenant_id', a.tenant_id,
        'marketplace', a.marketplace,
        'marketplace_group', a.marketplace_group,
        'shop_name', a.shop_name,
        'store_alias', a.store_alias,
        'account_name', a.shop_name,
        'status', a.status,
        'is_active', a.is_active
      ) order by a.marketplace_group, a.shop_name)
      from scoped_accounts a
    ), '[]'::jsonb)
  into v_summary, v_daily, v_by_marketplace, v_accounts
  from summary_totals st
  cross join cost_totals ct;

  return jsonb_build_object(
    'ok', true,
    'version', 'finance_dashboard_snapshot_light_20260621',
    'source', 'finance_dashboard_snapshot',
    'source_table', 'marketplace_finance_reports_light',
    'snapshot_mode', 'lightweight',
    'timezone', 'Asia/Jakarta',
    'start_date', v_start::text,
    'end_date', v_end::text,
    'requested_start_date', p_start,
    'requested_end_date', p_end,
    'requested_account_id', p_account_id,
    'marketplace', coalesce(p_marketplace, 'all'),
    'summary', coalesce(v_summary, '{}'::jsonb),
    'daily', coalesce(v_daily, '[]'::jsonb),
    'trend', coalesce(v_daily, '[]'::jsonb),
    'by_marketplace', coalesce(v_by_marketplace, '[]'::jsonb),
    'marketplaces', coalesce(v_by_marketplace, '[]'::jsonb),
    'profit_loss_by_marketplace', '[]'::jsonb,
    'accounts', coalesce(v_accounts, '[]'::jsonb),
    'expenses', '[]'::jsonb,
    'approved_purchases', '[]'::jsonb,
    'skus', '[]'::jsonb,
    'sku_rows', '[]'::jsonb,
    'cash_flow', '[]'::jsonb,
    'profit_loss_breakdown', '[]'::jsonb,
    'abnormals', '[]'::jsonb
  );
end;
$function$;

revoke all on function public.finance_dashboard_snapshot(date, date, text, uuid) from public;
grant execute on function public.finance_dashboard_snapshot(date, date, text, uuid) to authenticated, service_role;

commit;

notify pgrst, 'reload schema';
