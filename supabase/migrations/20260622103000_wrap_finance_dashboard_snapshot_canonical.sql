create or replace function public.finance_dashboard_snapshot(
  p_start date default null::date,
  p_end date default null::date,
  p_marketplace text default null::text,
  p_account_id uuid default null::uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
set statement_timeout to '15s'
as $function$
declare
  v_claims jsonb := '{}'::jsonb;
  v_tenant_id uuid := null;
  v_default_tenant_id uuid := null;
  v_start date := coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date);
  v_end date := coalesce(p_end, timezone('Asia/Jakarta', now())::date);
  v_marketplace text := null;

  v_gross_total numeric := 0;
  v_payout_total numeric := 0;
  v_hpp_total numeric := 0;
  v_manual_expense_total numeric := 0;
  v_purchase_cashout numeric := 0;
  v_expense_total numeric := 0;
  v_net_profit numeric := 0;
  v_order_count integer := 0;
  v_finance_order_count integer := 0;
  v_source_count integer := 0;
  v_negative_payout_count integer := 0;
  v_negative_payout_total_abs numeric := 0;

  v_summary jsonb := '{}'::jsonb;
  v_daily jsonb := '[]'::jsonb;
  v_daily_by_marketplace jsonb := '[]'::jsonb;
  v_by_marketplace jsonb := '[]'::jsonb;
  v_accounts jsonb := '[]'::jsonb;
  v_expenses jsonb := '[]'::jsonb;
  v_profit_loss_breakdown jsonb := '[]'::jsonb;
  v_profit_loss_by_marketplace jsonb := '[]'::jsonb;
begin
  begin
    v_claims := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  exception when others then
    v_claims := '{}'::jsonb;
  end;

  v_tenant_id := case
    when (v_claims->>'tenant_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (v_claims->>'tenant_id')::uuid
    else null::uuid
  end;

  if v_tenant_id is null then
    begin
      select u.tenant_id
      into v_tenant_id
      from public.users u
      where u.user_id = auth.uid()
      limit 1;
    exception when others then
      v_tenant_id := null;
    end;
  end if;

  if v_tenant_id is null then
    select case when count(*) = 1 then (array_agg(tenant_id))[1] else null end
    into v_default_tenant_id
    from (
      select distinct tenant_id
      from public.users
      where tenant_id is not null
    ) t;

    v_tenant_id := v_default_tenant_id;
  end if;

  v_marketplace := case
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) in ('', 'all', 'semua') then null
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
    else lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g'))
  end;

  with finance_scoped as (
    select
      fr.tenant_id,
      fr.marketplace_account_id,
      case
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace,
      coalesce(fr.settlement_date::date, fr.period_start::date, fr.created_at::date) as finance_date,
      nullif(fr.order_id, '') as order_key,
      coalesce(fr.gross_amount, fr.gross_sales, 0)::numeric as gross_sales,
      coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)::numeric as payout_amount,
      coalesce(fr.total_hpp, 0)::numeric as hpp_total
    from public.marketplace_finance_reports fr
    where coalesce(fr.settlement_date::date, fr.period_start::date, fr.created_at::date) between v_start and v_end
      and (v_tenant_id is null or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or case
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
      and (
        coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0) <> 0
        or coalesce(fr.gross_amount, fr.gross_sales, 0) <> 0
      )
  ),
  expense_rows as (
    select
      e.finance_operational_expense_id::text as expense_id,
      coalesce(e.expense_date, e.paid_at, e.created_at::date)::date as expense_date,
      coalesce(e.category, 'Operasional')::text as category,
      coalesce(e.description, e.note, e.category, 'Biaya operasional')::text as description,
      abs(coalesce(e.amount, 0))::numeric as amount,
      coalesce(e.status, 'paid')::text as status,
      coalesce(e.source_module, '')::text as source_module,
      coalesce(e.source_ref, '')::text as source_ref
    from public.finance_operational_expenses e
    where coalesce(e.expense_date, e.paid_at, e.created_at::date)::date between v_start and v_end
      and (v_tenant_id is null or e.tenant_id = v_tenant_id)
      and lower(coalesce(e.status, 'paid')) not in ('void', 'deleted', 'cancelled', 'canceled', 'rejected', 'reject')
      and abs(coalesce(e.amount, 0)) > 0
  ),
  finance_total as (
    select
      coalesce(sum(gross_sales), 0)::numeric as gross_total,
      coalesce(sum(payout_amount), 0)::numeric as payout_total,
      coalesce(sum(hpp_total), 0)::numeric as hpp_total,
      count(distinct order_key)::integer as order_count,
      count(distinct order_key)::integer as finance_order_count,
      count(*)::integer as source_count,
      count(*) filter (where payout_amount < 0)::integer as negative_payout_count,
      coalesce(sum(abs(payout_amount)) filter (where payout_amount < 0), 0)::numeric as negative_payout_total_abs
    from finance_scoped
  ),
  expense_total as (
    select coalesce(sum(amount), 0)::numeric as manual_expense_total
    from expense_rows
  )
  select
    ft.gross_total,
    ft.payout_total,
    ft.hpp_total,
    et.manual_expense_total,
    ft.order_count,
    ft.finance_order_count,
    ft.source_count,
    ft.negative_payout_count,
    ft.negative_payout_total_abs
  into
    v_gross_total,
    v_payout_total,
    v_hpp_total,
    v_manual_expense_total,
    v_order_count,
    v_finance_order_count,
    v_source_count,
    v_negative_payout_count,
    v_negative_payout_total_abs
  from finance_total ft cross join expense_total et;

  v_expense_total := coalesce(v_manual_expense_total, 0) + coalesce(v_purchase_cashout, 0);
  v_net_profit := coalesce(v_payout_total, 0) - coalesce(v_hpp_total, 0) - coalesce(v_expense_total, 0);

  with finance_scoped as (
    select
      fr.tenant_id,
      fr.marketplace_account_id,
      case
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace,
      coalesce(fr.settlement_date::date, fr.period_start::date, fr.created_at::date) as finance_date,
      nullif(fr.order_id, '') as order_key,
      coalesce(fr.gross_amount, fr.gross_sales, 0)::numeric as gross_sales,
      coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)::numeric as payout_amount,
      coalesce(fr.total_hpp, 0)::numeric as hpp_total
    from public.marketplace_finance_reports fr
    where coalesce(fr.settlement_date::date, fr.period_start::date, fr.created_at::date) between v_start and v_end
      and (v_tenant_id is null or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or case
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
      and (
        coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0) <> 0
        or coalesce(fr.gross_amount, fr.gross_sales, 0) <> 0
      )
  ),
  by_mp as (
    select
      fs.marketplace,
      fs.marketplace_account_id,
      coalesce(max(a.shop_name), max(a.store_alias), max(a.shop_id), fs.marketplace) as shop_name,
      coalesce(max(a.store_alias), max(a.shop_name), max(a.shop_id), fs.marketplace) as store_alias,
      count(distinct fs.order_key)::integer as order_count,
      count(distinct fs.order_key)::integer as finance_order_count,
      coalesce(sum(fs.gross_sales), 0)::numeric as gross_sales,
      coalesce(sum(fs.payout_amount), 0)::numeric as payout_total,
      coalesce(sum(fs.hpp_total), 0)::numeric as hpp_total,
      count(*) filter (where fs.payout_amount < 0)::integer as negative_payout_count,
      coalesce(sum(abs(fs.payout_amount)) filter (where fs.payout_amount < 0), 0)::numeric as negative_payout_total_abs
    from finance_scoped fs
    left join public.marketplace_accounts a
      on a.marketplace_account_id = fs.marketplace_account_id
    group by fs.marketplace, fs.marketplace_account_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'marketplace', marketplace,
    'marketplace_group', marketplace,
    'marketplace_account_id', marketplace_account_id,
    'shop_name', shop_name,
    'store_alias', store_alias,
    'account_name', store_alias,
    'order_count', order_count,
    'orders_count', order_count,
    'finance_order_count', finance_order_count,
    'finance_orders_count', finance_order_count,
    'gross_sales', gross_sales,
    'gross_total', gross_sales,
    'omzet_total', gross_sales,
    'payout_total', payout_total,
    'payout_amount', payout_total,
    'net_settlement', payout_total,
    'received_amount', payout_total,
    'hpp_total', hpp_total,
    'total_hpp', hpp_total,
    'expense_total', 0,
    'operational_cost_total', 0,
    'net_profit', payout_total - hpp_total,
    'profit', payout_total - hpp_total,
    'negative_payout_count', negative_payout_count,
    'negative_payout_total_abs', negative_payout_total_abs,
    'payout_minus_total_abs', negative_payout_total_abs
  ) order by marketplace), '[]'::jsonb)
  into v_by_marketplace
  from by_mp;

  with finance_scoped as (
    select
      case
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace,
      coalesce(fr.settlement_date::date, fr.period_start::date, fr.created_at::date) as finance_date,
      nullif(fr.order_id, '') as order_key,
      coalesce(fr.gross_amount, fr.gross_sales, 0)::numeric as gross_sales,
      coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)::numeric as payout_amount,
      coalesce(fr.total_hpp, 0)::numeric as hpp_total
    from public.marketplace_finance_reports fr
    where coalesce(fr.settlement_date::date, fr.period_start::date, fr.created_at::date) between v_start and v_end
      and (v_tenant_id is null or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or case
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
      and (
        coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0) <> 0
        or coalesce(fr.gross_amount, fr.gross_sales, 0) <> 0
      )
  ),
  expense_daily as (
    select
      coalesce(e.expense_date, e.paid_at, e.created_at::date)::date as day,
      coalesce(sum(abs(e.amount)), 0)::numeric as expense_total
    from public.finance_operational_expenses e
    where coalesce(e.expense_date, e.paid_at, e.created_at::date)::date between v_start and v_end
      and (v_tenant_id is null or e.tenant_id = v_tenant_id)
      and lower(coalesce(e.status, 'paid')) not in ('void', 'deleted', 'cancelled', 'canceled', 'rejected', 'reject')
      and abs(coalesce(e.amount, 0)) > 0
    group by 1
  ),
  finance_daily as (
    select
      finance_date as day,
      count(distinct order_key)::integer as order_count,
      coalesce(sum(gross_sales), 0)::numeric as gross_sales,
      coalesce(sum(payout_amount), 0)::numeric as payout_total,
      coalesce(sum(hpp_total), 0)::numeric as hpp_total
    from finance_scoped
    group by finance_date
  ),
  all_days as (
    select day from finance_daily
    union
    select day from expense_daily
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'date', d.day,
    'day', d.day,
    'gross_sales', coalesce(fd.gross_sales, 0),
    'gross_total', coalesce(fd.gross_sales, 0),
    'omzet_total', coalesce(fd.gross_sales, 0),
    'payout_total', coalesce(fd.payout_total, 0),
    'payout_amount', coalesce(fd.payout_total, 0),
    'hpp_total', coalesce(fd.hpp_total, 0),
    'expense_total', coalesce(ed.expense_total, 0),
    'manual_expense_total', coalesce(ed.expense_total, 0),
    'net_profit', coalesce(fd.payout_total, 0) - coalesce(fd.hpp_total, 0) - coalesce(ed.expense_total, 0),
    'order_count', coalesce(fd.order_count, 0),
    'orders_count', coalesce(fd.order_count, 0),
    'finance_order_count', coalesce(fd.order_count, 0)
  ) order by d.day), '[]'::jsonb)
  into v_daily
  from all_days d
  left join finance_daily fd on fd.day = d.day
  left join expense_daily ed on ed.day = d.day;

  with finance_scoped as (
    select
      case
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace,
      fr.marketplace_account_id,
      coalesce(fr.settlement_date::date, fr.period_start::date, fr.created_at::date) as finance_date,
      nullif(fr.order_id, '') as order_key,
      coalesce(fr.gross_amount, fr.gross_sales, 0)::numeric as gross_sales,
      coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)::numeric as payout_amount,
      coalesce(fr.total_hpp, 0)::numeric as hpp_total
    from public.marketplace_finance_reports fr
    where coalesce(fr.settlement_date::date, fr.period_start::date, fr.created_at::date) between v_start and v_end
      and (v_tenant_id is null or fr.tenant_id = v_tenant_id)
      and (p_account_id is null or fr.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or case
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
      and (
        coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0) <> 0
        or coalesce(fr.gross_amount, fr.gross_sales, 0) <> 0
      )
  ),
  daily_mp as (
    select
      finance_date as day,
      marketplace,
      marketplace_account_id,
      count(distinct order_key)::integer as order_count,
      coalesce(sum(gross_sales), 0)::numeric as gross_sales,
      coalesce(sum(payout_amount), 0)::numeric as payout_total,
      coalesce(sum(hpp_total), 0)::numeric as hpp_total
    from finance_scoped
    group by 1,2,3
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'date', day,
    'day', day,
    'marketplace', marketplace,
    'marketplace_group', marketplace,
    'marketplace_account_id', marketplace_account_id,
    'gross_sales', gross_sales,
    'gross_total', gross_sales,
    'omzet_total', gross_sales,
    'payout_total', payout_total,
    'payout_amount', payout_total,
    'hpp_total', hpp_total,
    'expense_total', 0,
    'net_profit', payout_total - hpp_total,
    'order_count', order_count,
    'orders_count', order_count,
    'finance_order_count', order_count
  ) order by day, marketplace), '[]'::jsonb)
  into v_daily_by_marketplace
  from daily_mp;

  with expense_rows as (
    select
      e.finance_operational_expense_id::text as expense_id,
      coalesce(e.expense_date, e.paid_at, e.created_at::date)::date as expense_date,
      coalesce(e.category, 'Operasional')::text as category,
      coalesce(e.description, e.note, e.category, 'Biaya operasional')::text as description,
      abs(coalesce(e.amount, 0))::numeric as amount,
      coalesce(e.status, 'paid')::text as status,
      coalesce(e.source_module, '')::text as source_module,
      coalesce(e.source_ref, '')::text as source_ref
    from public.finance_operational_expenses e
    where coalesce(e.expense_date, e.paid_at, e.created_at::date)::date between v_start and v_end
      and (v_tenant_id is null or e.tenant_id = v_tenant_id)
      and lower(coalesce(e.status, 'paid')) not in ('void', 'deleted', 'cancelled', 'canceled', 'rejected', 'reject')
      and abs(coalesce(e.amount, 0)) > 0
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'source', 'operational_expense',
    'expense_id', expense_id,
    'date', expense_date,
    'expense_date', expense_date,
    'category', category,
    'description', description,
    'note', description,
    'amount', amount,
    'cash_type', 'out',
    'type', 'out',
    'status', status,
    'source_module', source_module,
    'source_ref', source_ref
  ) order by expense_date desc, expense_id), '[]'::jsonb)
  into v_expenses
  from expense_rows;

  v_profit_loss_breakdown := jsonb_build_array(
    jsonb_build_object('key', 'gross_sales', 'label', 'Omzet / Gross Sales', 'amount', v_gross_total, 'type', 'income'),
    jsonb_build_object('key', 'payout_total', 'label', 'Payout / Settlement', 'amount', v_payout_total, 'type', 'income'),
    jsonb_build_object('key', 'hpp_total', 'label', 'HPP', 'amount', v_hpp_total, 'type', 'cost'),
    jsonb_build_object('key', 'manual_expense_total', 'label', 'Biaya Operasional / Manual Expense', 'amount', v_manual_expense_total, 'type', 'cost'),
    jsonb_build_object('key', 'purchase_cashout', 'label', 'Pembelian Disetujui', 'amount', v_purchase_cashout, 'type', 'cost'),
    jsonb_build_object('key', 'net_profit', 'label', 'Laba Bersih', 'amount', v_net_profit, 'type', 'profit')
  );

  select coalesce(jsonb_agg(
    elem || jsonb_build_object(
      'manual_expense_total', 0,
      'purchase_cashout', 0,
      'profit_loss_amount', coalesce(nullif(elem->>'net_profit','')::numeric, 0)
    )
  ), '[]'::jsonb)
  into v_profit_loss_by_marketplace
  from jsonb_array_elements(v_by_marketplace) elem;

  v_summary := jsonb_build_object(
    'period_start', v_start,
    'period_end', v_end,
    'omzet', v_gross_total,
    'omzet_total', v_gross_total,
    'gross_sales', v_gross_total,
    'gross_total', v_gross_total,
    'gross_amount', v_gross_total,
    'payout_total', v_payout_total,
    'payout_amount', v_payout_total,
    'net_settlement', v_payout_total,
    'received_amount', v_payout_total,
    'net_received', v_payout_total,
    'hpp_total', v_hpp_total,
    'total_hpp', v_hpp_total,
    'paid_hpp_total', v_hpp_total,
    'settled_hpp_total', v_hpp_total,
    'manual_expense_total', v_manual_expense_total,
    'manual_operational_expense', v_manual_expense_total,
    'operational_expense', v_manual_expense_total,
    'operational_cost_total', v_expense_total,
    'expense_total', v_expense_total,
    'purchase_cashout', v_purchase_cashout,
    'approved_purchase_total', v_purchase_cashout,
    'approved_purchase_cashout', v_purchase_cashout,
    'net_profit', v_net_profit,
    'profit', v_net_profit,
    'margin_percent', case when v_payout_total <> 0 then round((v_net_profit / v_payout_total) * 100, 2) else 0 end,
    'net_margin_percent', case when v_payout_total <> 0 then round((v_net_profit / v_payout_total) * 100, 2) else 0 end,
    'orders_count', v_order_count,
    'order_count', v_order_count,
    'finance_orders_count', v_finance_order_count,
    'finance_order_count', v_finance_order_count,
    'source_count', v_source_count,
    'marketplace_count', jsonb_array_length(coalesce(v_by_marketplace, '[]'::jsonb)),
    'negative_payout_count', v_negative_payout_count,
    'payout_minus_count', v_negative_payout_count,
    'negative_payout_total_abs', v_negative_payout_total_abs,
    'payout_minus_total_abs', v_negative_payout_total_abs,
    'abnormal_count', v_negative_payout_count,
    'pending_hpp_total', 0,
    'estimated_unpaid_hpp_total', 0,
    'unpaid_estimated_hpp_total', 0
  );

  return jsonb_build_object(
    'ok', true,
    'version', 'finance_dashboard_snapshot_light_effective_date_20260622',
    'wrapper_version', 'finance_dashboard_snapshot_light_effective_date_20260622',
    'source', 'finance_dashboard_snapshot',
    'source_table', 'marketplace_finance_reports',
    'snapshot_mode', 'lightweight_effective_date',
    'timezone', 'Asia/Jakarta',
    'start_date', v_start::text,
    'end_date', v_end::text,
    'requested_start_date', p_start,
    'requested_end_date', p_end,
    'requested_account_id', p_account_id,
    'marketplace', coalesce(p_marketplace, 'all'),
    'summary', v_summary,
    'daily', coalesce(v_daily, '[]'::jsonb),
    'trend', coalesce(v_daily, '[]'::jsonb),
    'daily_by_marketplace', coalesce(v_daily_by_marketplace, '[]'::jsonb),
    'by_marketplace', coalesce(v_by_marketplace, '[]'::jsonb),
    'marketplaces', coalesce(v_by_marketplace, '[]'::jsonb),
    'profit_loss_by_marketplace', coalesce(v_profit_loss_by_marketplace, '[]'::jsonb),
    'accounts', coalesce(v_by_marketplace, '[]'::jsonb),
    'expenses', coalesce(v_expenses, '[]'::jsonb),
    'approved_purchases', '[]'::jsonb,
    'skus', '[]'::jsonb,
    'sku_rows', '[]'::jsonb,
    'cash_flow', coalesce(v_expenses, '[]'::jsonb),
    'profit_loss_breakdown', coalesce(v_profit_loss_breakdown, '[]'::jsonb),
    'abnormals', '[]'::jsonb
  );
end;
$function$;

grant execute on function public.finance_dashboard_snapshot(date,date,text,uuid) to anon, authenticated, service_role;

