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
set statement_timeout to '20s'
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

  v_total_fees numeric := 0;
  v_platform_fee numeric := 0;
  v_commission_fee numeric := 0;
  v_affiliate_fee numeric := 0;
  v_shipping_fee numeric := 0;
  v_discount_amount numeric := 0;
  v_refund_amount numeric := 0;
  v_adjustment_amount numeric := 0;
  v_fee_amount numeric := 0;

  v_summary jsonb := '{}'::jsonb;
  v_daily jsonb := '[]'::jsonb;
  v_daily_by_marketplace jsonb := '[]'::jsonb;
  v_by_marketplace jsonb := '[]'::jsonb;
  v_expenses jsonb := '[]'::jsonb;
  v_approved_purchases jsonb := '[]'::jsonb;
  v_cash_flow jsonb := '[]'::jsonb;
  v_profit_loss_breakdown jsonb := '[]'::jsonb;
  v_profit_loss_by_marketplace jsonb := '[]'::jsonb;
  v_deduction_breakdown jsonb := '[]'::jsonb;
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
      coalesce(fr.total_hpp, 0)::numeric as hpp_total,
      coalesce(fr.total_fees, 0)::numeric as total_fees,
      coalesce(fr.platform_fee, 0)::numeric as platform_fee,
      coalesce(fr.commission_fee, 0)::numeric as commission_fee,
      coalesce(fr.affiliate_fee, 0)::numeric as affiliate_fee,
      coalesce(fr.shipping_fee, 0)::numeric as shipping_fee,
      coalesce(fr.discount_amount, 0)::numeric as discount_amount,
      coalesce(fr.refund_amount, 0)::numeric as refund_amount,
      coalesce(fr.adjustment_amount, 0)::numeric as adjustment_amount,
      coalesce(fr.fee_amount, 0)::numeric as fee_amount
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
    select abs(coalesce(e.amount, 0))::numeric as amount
    from public.finance_operational_expenses e
    where coalesce(e.expense_date, e.paid_at, e.created_at::date)::date between v_start and v_end
      and (v_tenant_id is null or e.tenant_id = v_tenant_id)
      and lower(coalesce(e.status, 'paid')) not in ('void', 'deleted', 'cancelled', 'canceled', 'rejected', 'reject')
      and abs(coalesce(e.amount, 0)) > 0
  ),
  purchase_rows as (
    select coalesce(p.total_pembelian, 0)::numeric as amount
    from public.purchases p
    where p.tanggal between v_start and v_end
      and (v_tenant_id is null or p.tenant_id = v_tenant_id)
      and lower(coalesce(p.status, '')) in ('verified_finance', 'verified', 'approved', 'paid', 'completed')
      and coalesce(p.total_pembelian, 0) > 0
  ),
  totals as (
    select
      coalesce(sum(gross_sales), 0)::numeric as gross_total,
      coalesce(sum(payout_amount), 0)::numeric as payout_total,
      coalesce(sum(hpp_total), 0)::numeric as hpp_total,
      count(distinct order_key)::integer as order_count,
      count(distinct order_key)::integer as finance_order_count,
      count(*)::integer as source_count,
      count(*) filter (where payout_amount < 0)::integer as negative_payout_count,
      coalesce(sum(abs(payout_amount)) filter (where payout_amount < 0), 0)::numeric as negative_payout_total_abs,
      coalesce(sum(total_fees), 0)::numeric as total_fees,
      coalesce(sum(platform_fee), 0)::numeric as platform_fee,
      coalesce(sum(commission_fee), 0)::numeric as commission_fee,
      coalesce(sum(affiliate_fee), 0)::numeric as affiliate_fee,
      coalesce(sum(shipping_fee), 0)::numeric as shipping_fee,
      coalesce(sum(discount_amount), 0)::numeric as discount_amount,
      coalesce(sum(refund_amount), 0)::numeric as refund_amount,
      coalesce(sum(adjustment_amount), 0)::numeric as adjustment_amount,
      coalesce(sum(fee_amount), 0)::numeric as fee_amount
    from finance_scoped
  ),
  et as (select coalesce(sum(amount), 0)::numeric as manual_expense_total from expense_rows),
  pt as (select coalesce(sum(amount), 0)::numeric as purchase_cashout from purchase_rows)
  select
    t.gross_total, t.payout_total, t.hpp_total,
    et.manual_expense_total, pt.purchase_cashout,
    t.order_count, t.finance_order_count, t.source_count,
    t.negative_payout_count, t.negative_payout_total_abs,
    t.total_fees, t.platform_fee, t.commission_fee, t.affiliate_fee,
    t.shipping_fee, t.discount_amount, t.refund_amount, t.adjustment_amount, t.fee_amount
  into
    v_gross_total, v_payout_total, v_hpp_total,
    v_manual_expense_total, v_purchase_cashout,
    v_order_count, v_finance_order_count, v_source_count,
    v_negative_payout_count, v_negative_payout_total_abs,
    v_total_fees, v_platform_fee, v_commission_fee, v_affiliate_fee,
    v_shipping_fee, v_discount_amount, v_refund_amount, v_adjustment_amount, v_fee_amount
  from totals t cross join et cross join pt;

  v_expense_total := coalesce(v_manual_expense_total, 0) + coalesce(v_purchase_cashout, 0);
  v_net_profit := coalesce(v_payout_total, 0) - coalesce(v_hpp_total, 0) - coalesce(v_expense_total, 0);

  with finance_mp as (
    select
      fs.marketplace,
      fs.marketplace_account_id,
      count(*) as finance_rows,
      count(distinct fs.order_key)::integer as finance_order_count,
      coalesce(sum(fs.gross_sales), 0)::numeric as finance_gross,
      coalesce(sum(fs.payout_amount), 0)::numeric as finance_payout,
      coalesce(sum(fs.hpp_total), 0)::numeric as hpp_total,
      count(*) filter (where fs.payout_amount < 0)::integer as negative_payout_count,
      coalesce(sum(abs(fs.payout_amount)) filter (where fs.payout_amount < 0), 0)::numeric as negative_payout_total_abs,
      coalesce(sum(fs.total_fees), 0)::numeric as total_fees,
      coalesce(sum(fs.platform_fee), 0)::numeric as platform_fee,
      coalesce(sum(fs.commission_fee), 0)::numeric as commission_fee,
      coalesce(sum(fs.affiliate_fee), 0)::numeric as affiliate_fee,
      coalesce(sum(fs.shipping_fee), 0)::numeric as shipping_fee,
      coalesce(sum(fs.discount_amount), 0)::numeric as discount_amount,
      coalesce(sum(fs.refund_amount), 0)::numeric as refund_amount,
      coalesce(sum(fs.adjustment_amount), 0)::numeric as adjustment_amount,
      coalesce(sum(fs.fee_amount), 0)::numeric as fee_amount
    from (
      select
        fr.marketplace_account_id,
        case
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(fr.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          else lower(regexp_replace(coalesce(fr.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end as marketplace,
        nullif(fr.order_id, '') as order_key,
        coalesce(fr.gross_amount, fr.gross_sales, 0)::numeric as gross_sales,
        coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)::numeric as payout_amount,
        coalesce(fr.total_hpp, 0)::numeric as hpp_total,
        coalesce(fr.total_fees, 0)::numeric as total_fees,
        coalesce(fr.platform_fee, 0)::numeric as platform_fee,
        coalesce(fr.commission_fee, 0)::numeric as commission_fee,
        coalesce(fr.affiliate_fee, 0)::numeric as affiliate_fee,
        coalesce(fr.shipping_fee, 0)::numeric as shipping_fee,
        coalesce(fr.discount_amount, 0)::numeric as discount_amount,
        coalesce(fr.refund_amount, 0)::numeric as refund_amount,
        coalesce(fr.adjustment_amount, 0)::numeric as adjustment_amount,
        coalesce(fr.fee_amount, 0)::numeric as fee_amount
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
    ) fs
    group by fs.marketplace, fs.marketplace_account_id
  ),
  order_mp as (
    select
      case
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace,
      o.marketplace_account_id,
      count(*)::integer as order_count,
      coalesce(sum(coalesce(o.gross_amount, o.paid_amount, o.total_amount, 0)), 0)::numeric as order_gross
    from public.marketplace_orders o
    where coalesce(o.order_created_at, o.created_time, o.created_at)::date between v_start and v_end
      and (v_tenant_id is null or o.tenant_id = v_tenant_id)
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or case
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
    group by 1, 2
  ),
  keys as (
    select marketplace, marketplace_account_id from finance_mp
    union
    select marketplace, marketplace_account_id from order_mp
  ),
  rows as (
    select
      k.marketplace,
      k.marketplace_account_id,
      coalesce(max(a.shop_name), max(a.store_alias), max(a.shop_id), k.marketplace) as shop_name,
      coalesce(max(a.store_alias), max(a.shop_name), max(a.shop_id), k.marketplace) as store_alias,
      coalesce(om.order_count, 0)::integer as order_count,
      coalesce(om.order_gross, 0)::numeric as order_gross,
      coalesce(fm.finance_rows, 0)::integer as finance_rows,
      coalesce(fm.finance_order_count, 0)::integer as finance_order_count,
      coalesce(fm.finance_gross, 0)::numeric as finance_gross,
      coalesce(fm.finance_payout, 0)::numeric as finance_payout,
      coalesce(fm.hpp_total, 0)::numeric as hpp_total,
      coalesce(fm.negative_payout_count, 0)::integer as negative_payout_count,
      coalesce(fm.negative_payout_total_abs, 0)::numeric as negative_payout_total_abs,
      coalesce(fm.total_fees, 0)::numeric as total_fees,
      coalesce(fm.platform_fee, 0)::numeric as platform_fee,
      coalesce(fm.commission_fee, 0)::numeric as commission_fee,
      coalesce(fm.affiliate_fee, 0)::numeric as affiliate_fee,
      coalesce(fm.shipping_fee, 0)::numeric as shipping_fee,
      coalesce(fm.discount_amount, 0)::numeric as discount_amount,
      coalesce(fm.refund_amount, 0)::numeric as refund_amount,
      coalesce(fm.adjustment_amount, 0)::numeric as adjustment_amount,
      coalesce(fm.fee_amount, 0)::numeric as fee_amount
    from keys k
    left join finance_mp fm on fm.marketplace = k.marketplace and fm.marketplace_account_id = k.marketplace_account_id
    left join order_mp om on om.marketplace = k.marketplace and om.marketplace_account_id = k.marketplace_account_id
    left join public.marketplace_accounts a on a.marketplace_account_id = k.marketplace_account_id
    group by k.marketplace, k.marketplace_account_id, om.order_count, om.order_gross,
             fm.finance_rows, fm.finance_order_count, fm.finance_gross, fm.finance_payout,
             fm.hpp_total, fm.negative_payout_count, fm.negative_payout_total_abs,
             fm.total_fees, fm.platform_fee, fm.commission_fee, fm.affiliate_fee,
             fm.shipping_fee, fm.discount_amount, fm.refund_amount, fm.adjustment_amount, fm.fee_amount
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'marketplace', marketplace,
    'marketplace_group', marketplace,
    'marketplace_account_id', marketplace_account_id,
    'shop_name', shop_name,
    'store_alias', store_alias,
    'account_name', store_alias,
    'order_count', case when finance_rows = 0 and order_count > 0 then order_count else greatest(order_count, finance_order_count) end,
    'orders_count', case when finance_rows = 0 and order_count > 0 then order_count else greatest(order_count, finance_order_count) end,
    'finance_order_count', finance_order_count,
    'finance_orders_count', finance_order_count,
    'order_gross_estimated', order_gross,
    'gross_sales', case when finance_rows = 0 and order_count > 0 then order_gross else finance_gross end,
    'gross_total', case when finance_rows = 0 and order_count > 0 then order_gross else finance_gross end,
    'omzet_total', case when finance_rows = 0 and order_count > 0 then order_gross else finance_gross end,
    'payout_total', finance_payout,
    'payout_amount', finance_payout,
    'net_settlement', finance_payout,
    'received_amount', finance_payout,
    'hpp_total', hpp_total,
    'total_hpp', hpp_total,
    'expense_total', 0,
    'operational_cost_total', 0,
    'net_profit', finance_payout - hpp_total,
    'profit', finance_payout - hpp_total,
    'settlement_status', case when finance_rows = 0 and order_count > 0 then 'waiting_settlement' else 'settled' end,
    'finance_status', case when finance_rows = 0 and order_count > 0 then 'waiting_settlement' else 'settled' end,
    'waiting_settlement_order_count', case when finance_rows = 0 and order_count > 0 then order_count else 0 end,
    'waiting_settlement_gross_estimated', case when finance_rows = 0 and order_count > 0 then order_gross else 0 end,
    'negative_payout_count', negative_payout_count,
    'negative_payout_total_abs', negative_payout_total_abs,
    'payout_minus_total_abs', negative_payout_total_abs,
    'total_fees', total_fees,
    'platform_fee', platform_fee,
    'commission_fee', commission_fee,
    'affiliate_fee', affiliate_fee,
    'shipping_fee', shipping_fee,
    'discount_amount', discount_amount,
    'refund_amount', refund_amount,
    'adjustment_amount', adjustment_amount,
    'fee_amount', fee_amount
  ) order by marketplace), '[]'::jsonb)
  into v_by_marketplace
  from rows;

  with expense_rows as (
    select
      'operational_expense'::text as source,
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
    union all
    select
      'approved_purchase'::text as source,
      p.purchase_id::text as expense_id,
      p.tanggal::date as expense_date,
      'Pembelian Disetujui'::text as category,
      concat_ws(' · ', nullif(p.nomor_pembelian, ''), nullif(p.supplier_name, ''), nullif(p.catatan, ''))::text as description,
      coalesce(p.total_pembelian, 0)::numeric as amount,
      coalesce(p.status, 'verified_finance')::text as status,
      'purchase'::text as source_module,
      p.purchase_id::text as source_ref
    from public.purchases p
    where p.tanggal between v_start and v_end
      and (v_tenant_id is null or p.tenant_id = v_tenant_id)
      and lower(coalesce(p.status, '')) in ('verified_finance', 'verified', 'approved', 'paid', 'completed')
      and coalesce(p.total_pembelian, 0) > 0
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'source', source,
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

  with purchase_rows as (
    select
      p.purchase_id::text as purchase_id,
      p.nomor_pembelian,
      p.tanggal,
      p.supplier_name,
      p.total_pembelian,
      p.status,
      p.verified_at,
      coalesce((
        select string_agg(coalesce(pi.nama_barang, pi.nama_barang_manual, pi.kode_sku, '-'), ', ' order by pi.created_at)
        from public.purchase_items pi
        where pi.purchase_id = p.purchase_id
      ), '') as items
    from public.purchases p
    where p.tanggal between v_start and v_end
      and (v_tenant_id is null or p.tenant_id = v_tenant_id)
      and lower(coalesce(p.status, '')) in ('verified_finance', 'verified', 'approved', 'paid', 'completed')
      and coalesce(p.total_pembelian, 0) > 0
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'source', 'approved_purchase',
    'purchase_id', purchase_id,
    'expense_id', purchase_id,
    'date', tanggal,
    'expense_date', tanggal,
    'category', 'Pembelian Disetujui',
    'description', concat_ws(' · ', nullif(nomor_pembelian, ''), nullif(supplier_name, ''), nullif(items, '')),
    'supplier_name', supplier_name,
    'items', items,
    'amount', total_pembelian,
    'total_amount', total_pembelian,
    'status', status,
    'verified_at', verified_at,
    'cash_type', 'out',
    'type', 'out'
  ) order by tanggal desc, purchase_id), '[]'::jsonb)
  into v_approved_purchases
  from purchase_rows;

  v_cash_flow := coalesce(v_expenses, '[]'::jsonb);

  with finance_daily as (
    select
      coalesce(fr.settlement_date::date, fr.period_start::date, fr.created_at::date) as day,
      count(distinct nullif(fr.order_id, ''))::integer as order_count,
      coalesce(sum(coalesce(fr.gross_amount, fr.gross_sales, 0)), 0)::numeric as gross_sales,
      coalesce(sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0)), 0)::numeric as payout_total,
      coalesce(sum(coalesce(fr.total_hpp, 0)), 0)::numeric as hpp_total
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
    group by 1
  ),
  expense_daily as (
    select expense_date as day, sum(amount)::numeric as expense_total
    from (
      select coalesce(e.expense_date, e.paid_at, e.created_at::date)::date as expense_date, abs(coalesce(e.amount,0))::numeric as amount
      from public.finance_operational_expenses e
      where coalesce(e.expense_date, e.paid_at, e.created_at::date)::date between v_start and v_end
        and (v_tenant_id is null or e.tenant_id = v_tenant_id)
        and lower(coalesce(e.status, 'paid')) not in ('void', 'deleted', 'cancelled', 'canceled', 'rejected', 'reject')
      union all
      select p.tanggal::date as expense_date, coalesce(p.total_pembelian,0)::numeric as amount
      from public.purchases p
      where p.tanggal between v_start and v_end
        and (v_tenant_id is null or p.tenant_id = v_tenant_id)
        and lower(coalesce(p.status, '')) in ('verified_finance', 'verified', 'approved', 'paid', 'completed')
    ) x
    where amount > 0
    group by 1
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

  with labels as (
    select * from (values
      ('gross_sales', 'Omzet / Gross Sales', v_gross_total, 'income'),
      ('payout_total', 'Payout / Settlement', v_payout_total, 'income'),
      ('hpp_total', 'HPP', v_hpp_total, 'cost'),
      ('manual_expense_total', 'Biaya Operasional', v_manual_expense_total, 'cost'),
      ('purchase_cashout', 'Pembelian Disetujui', v_purchase_cashout, 'cost'),
      ('total_fees', 'Fee Marketplace / Total Fees', v_total_fees, 'settlement_detail'),
      ('platform_fee', 'Platform Fee', v_platform_fee, 'settlement_detail'),
      ('commission_fee', 'Commission Fee', v_commission_fee, 'settlement_detail'),
      ('affiliate_fee', 'Affiliate Fee', v_affiliate_fee, 'settlement_detail'),
      ('shipping_fee', 'Shipping Fee', v_shipping_fee, 'settlement_detail'),
      ('discount_amount', 'Diskon / Voucher Marketplace', v_discount_amount, 'settlement_detail'),
      ('refund_amount', 'Refund', v_refund_amount, 'settlement_detail'),
      ('adjustment_amount', 'Adjustment', v_adjustment_amount, 'settlement_detail'),
      ('fee_amount', 'Fee Amount', v_fee_amount, 'settlement_detail'),
      ('net_profit', 'Laba Bersih', v_net_profit, 'profit')
    ) as t(key, label, amount, row_type)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'key', key,
    'name', label,
    'label', label,
    'amount', case when row_type in ('cost', 'settlement_detail') then -abs(amount) else amount end,
    'raw_amount', amount,
    'type', row_type,
    'format', 'money'
  )), '[]'::jsonb)
  into v_profit_loss_breakdown
  from labels
  where amount <> 0 or key in ('gross_sales','payout_total','hpp_total','manual_expense_total','purchase_cashout','net_profit');

  v_deduction_breakdown := (
    select coalesce(jsonb_agg(elem), '[]'::jsonb)
    from jsonb_array_elements(v_profit_loss_breakdown) elem
    where elem->>'type' = 'settlement_detail'
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
    'purchase_cashout', v_purchase_cashout,
    'approved_purchase_total', v_purchase_cashout,
    'approved_purchase_cashout', v_purchase_cashout,
    'operational_cost_total', v_expense_total,
    'expense_total', v_expense_total,
    'net_profit', v_net_profit,
    'profit', v_net_profit
  ) || jsonb_build_object(
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
    'unpaid_estimated_hpp_total', 0,
    'total_fees', v_total_fees,
    'platform_fee', v_platform_fee,
    'commission_fee', v_commission_fee,
    'affiliate_fee', v_affiliate_fee,
    'shipping_fee', v_shipping_fee,
    'discount_amount', v_discount_amount,
    'refund_amount', v_refund_amount,
    'adjustment_amount', v_adjustment_amount,
    'fee_amount', v_fee_amount
  );

  return jsonb_build_object(
    'ok', true,
    'version', 'finance_dashboard_snapshot_light_effective_date_20260622b',
    'wrapper_version', 'finance_dashboard_snapshot_light_effective_date_20260622b',
    'source', 'finance_dashboard_snapshot',
    'source_table', 'marketplace_finance_reports',
    'snapshot_mode', 'lightweight_effective_date_with_purchases_orders_deductions',
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
    'deduction_breakdown', coalesce(v_deduction_breakdown, '[]'::jsonb),
    'accounts', coalesce(v_by_marketplace, '[]'::jsonb),
    'expenses', coalesce(v_expenses, '[]'::jsonb),
    'approved_purchases', coalesce(v_approved_purchases, '[]'::jsonb),
    'skus', '[]'::jsonb,
    'sku_rows', '[]'::jsonb,
    'cash_flow', coalesce(v_cash_flow, '[]'::jsonb),
    'profit_loss_breakdown', coalesce(v_profit_loss_breakdown, '[]'::jsonb),
    'abnormals', '[]'::jsonb
  );
end;
$function$;

grant execute on function public.finance_dashboard_snapshot(date,date,text,uuid) to anon, authenticated, service_role;

-- Patch: optimized unmapped branch for existing finance_sku_order_line_details.
-- No new app RPC. Normal mapped SKU path delegates to the previous canonical body.
create index if not exists idx_mfr_order_id_fast_20260622
  on public.marketplace_finance_reports (marketplace_order_id)
  where marketplace_order_id is not null;

create index if not exists idx_moi_order_id_fast_20260622
  on public.marketplace_order_items (marketplace_order_id);

create index if not exists idx_moi_account_tenant_fast_20260622
  on public.marketplace_order_items (tenant_id, marketplace_account_id, marketplace);

create index if not exists idx_mo_account_tenant_date_fast_20260622
  on public.marketplace_orders (tenant_id, marketplace_account_id, order_created_at, created_time);

do $$
declare
  v_exists boolean := false;
  v_def text;
begin
  select exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'finance_sku_order_line_details_base_20260622'
  )
  into v_exists;

  if not v_exists then
    select pg_get_functiondef(
      'public.finance_sku_order_line_details(date,date,text,uuid,text,text,text,text,integer,integer)'::regprocedure
    )
    into v_def;

    v_def := replace(
      v_def,
      'CREATE OR REPLACE FUNCTION public.finance_sku_order_line_details(',
      'CREATE OR REPLACE FUNCTION public.finance_sku_order_line_details_base_20260622('
    );

    execute v_def;
  end if;
end $$;

grant execute on function public.finance_sku_order_line_details_base_20260622(
  date,date,text,uuid,text,text,text,text,integer,integer
) to anon, authenticated, service_role;

create or replace function public.finance_sku_order_line_details(
  p_start date default null::date,
  p_end date default null::date,
  p_marketplace text default null::text,
  p_account_id uuid default null::uuid,
  p_marketplace_sku text default null::text,
  p_local_sku text default null::text,
  p_search text default null::text,
  p_payout_filter text default 'all'::text,
  p_page integer default 1,
  p_page_size integer default 25
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
set statement_timeout to '10s'
as $function$
declare
  v_claims jsonb := '{}'::jsonb;
  v_tenant_id uuid := null;
  v_default_tenant_id uuid := null;
  v_start date := coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date);
  v_end date := coalesce(p_end, timezone('Asia/Jakarta', now())::date);
  v_marketplace text := null;
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 25), 1), 100);
  v_offset integer := 0;
  v_filter text := lower(coalesce(nullif(trim(p_payout_filter), ''), 'all'));
  v_marker text := lower(trim(concat_ws(' ', p_marketplace_sku, p_local_sku, p_search)));
  v_is_unmapped_lookup boolean := false;
  v_total integer := 0;
  v_rows jsonb := '[]'::jsonb;
begin
  v_offset := (v_page - 1) * v_page_size;

  v_is_unmapped_lookup :=
    v_marker in ('unmapped', '__unmapped__', 'belum mapping', 'belum ada sku marketplace', 'produk belum diberi nama')
    or v_marker like '%unmapped%'
    or v_marker like '%belum mapping%'
    or v_marker like '%produk belum diberi nama%';

  if not v_is_unmapped_lookup then
    return public.finance_sku_order_line_details_base_20260622(
      p_start, p_end, p_marketplace, p_account_id,
      p_marketplace_sku, p_local_sku, p_search, p_payout_filter,
      p_page, p_page_size
    );
  end if;

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

  with candidate as (
    select
      oi.marketplace_order_item_id,
      oi.marketplace_order_id,
      oi.marketplace_product_id,
      coalesce(mo.marketplace_account_id, oi.marketplace_account_id) as marketplace_account_id,
      case
        when lower(regexp_replace(coalesce(oi.marketplace, mo.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
        when lower(regexp_replace(coalesce(oi.marketplace, mo.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
        else lower(regexp_replace(coalesce(oi.marketplace, mo.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
      end as marketplace,
      coalesce(mo.order_sn, oi.order_sn, mo.order_id, mo.external_order_id, oi.external_order_id) as order_sn,
      coalesce(mo.external_order_id, oi.external_order_id, mo.order_id, mo.order_sn, oi.order_sn) as external_order_id,
      coalesce(mo.tracking_number, oi.tracking_number, mo.package_id, oi.package_id) as tracking_number,
      coalesce(mo.order_status, mo.status, mo.order_status_label, mo.fulfillment_status, '-') as order_status,
      coalesce(mo.order_created_at, mo.created_time, oi.created_at) as order_date,
      coalesce(oi.marketplace_product_name, oi.product_name, oi.local_product_name, 'Produk belum diberi nama') as product_name,
      coalesce(oi.marketplace_variant_name, oi.variant_name, oi.variation_name, '-') as variant_name,
      coalesce(oi.marketplace_sku, oi.marketplace_sku_id, oi.remote_sku_id, '') as marketplace_sku,
      coalesce(oi.marketplace_sku_id, oi.remote_sku_id, '') as marketplace_sku_id,
      coalesce(oi.marketplace_seller_sku, oi.seller_sku, '') as marketplace_seller_sku,
      coalesce(oi.mapped_local_sku, oi.local_sku, '') as local_sku,
      coalesce(oi.quantity, oi.qty, 1)::numeric as qty,
      coalesce(
        oi.gross_amount,
        oi.unit_gross_amount * coalesce(oi.quantity, oi.qty, 1),
        mo.gross_amount,
        mo.total_amount,
        0
      )::numeric as gross_amount,
      coalesce(oi.mapping_status, '') as mapping_status
    from public.marketplace_order_items oi
    left join public.marketplace_orders mo
      on mo.marketplace_order_id = oi.marketplace_order_id
    where coalesce(mo.order_created_at, mo.created_time, oi.created_at)::date between v_start and v_end
      and (v_tenant_id is null or coalesce(oi.tenant_id, mo.tenant_id) = v_tenant_id)
      and (p_account_id is null or coalesce(oi.marketplace_account_id, mo.marketplace_account_id) = p_account_id)
      and (
        v_marketplace is null
        or case
          when lower(regexp_replace(coalesce(oi.marketplace, mo.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
          when lower(regexp_replace(coalesce(oi.marketplace, mo.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok_shop'
          else lower(regexp_replace(coalesce(oi.marketplace, mo.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
        end = v_marketplace
      )
      and (
        nullif(trim(coalesce(p_marketplace_sku, '')), '') is null
        or lower(coalesce(oi.marketplace_sku, '')) = lower(trim(p_marketplace_sku))
        or lower(coalesce(oi.marketplace_sku_id, '')) = lower(trim(p_marketplace_sku))
        or lower(coalesce(oi.remote_sku_id, '')) = lower(trim(p_marketplace_sku))
        or lower(coalesce(oi.marketplace_seller_sku, '')) = lower(trim(p_marketplace_sku))
        or lower(coalesce(oi.seller_sku, '')) = lower(trim(p_marketplace_sku))
        or lower(coalesce(oi.marketplace_product_id, '')) = lower(trim(p_marketplace_sku))
      )
      and (
        nullif(trim(coalesce(oi.mapped_local_sku, '')), '') is null
        or nullif(trim(coalesce(oi.local_sku, '')), '') is null
        or lower(coalesce(oi.local_sku, '')) in ('unmapped', '-', 'belum mapping', 'belum_mapping')
        or lower(coalesce(oi.mapped_local_sku, '')) in ('unmapped', '-', 'belum mapping', 'belum_mapping')
        or lower(coalesce(oi.mapping_status, '')) in ('', 'unmapped', 'not_mapped', 'not mapped', 'missing', 'pending', 'belum_mapping')
        or (oi.mapped_product_id is null and oi.product_id is null and oi.local_product_id is null)
      )
  ),
  filtered as (
    select c.*
    from candidate c
    where
      v_filter in ('', 'all')
      or (
        v_filter in ('paid', 'settled', 'released')
        and exists (
          select 1
          from public.marketplace_finance_reports fr
          where fr.marketplace_order_id = c.marketplace_order_id
            and coalesce(fr.settlement_date::date, fr.period_start::date, fr.created_at::date) between v_start and v_end
            and coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0) <> 0
          limit 1
        )
      )
      or (
        v_filter in ('unpaid', 'pending', 'missing_payout', 'no_payout')
        and not exists (
          select 1
          from public.marketplace_finance_reports fr
          where fr.marketplace_order_id = c.marketplace_order_id
            and coalesce(fr.settlement_date::date, fr.period_start::date, fr.created_at::date) between v_start and v_end
            and coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0) <> 0
          limit 1
        )
      )
  ),
  counted as (
    select count(*)::integer as total from filtered
  ),
  paged as (
    select *
    from filtered
    order by order_date desc nulls last, order_sn desc nulls last, marketplace_order_item_id
    limit v_page_size offset v_offset
  ),
  enriched as (
    select
      p.*,
      coalesce(fin.finance_payout, 0)::numeric as finance_payout,
      fin.statement_id,
      fin.settlement_status,
      fin.settlement_date
    from paged p
    left join lateral (
      select
        max(fr.statement_id) as statement_id,
        max(fr.settlement_status) as settlement_status,
        max(fr.settlement_date) as settlement_date,
        sum(coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0))::numeric as finance_payout
      from public.marketplace_finance_reports fr
      where fr.marketplace_order_id = p.marketplace_order_id
        and coalesce(fr.settlement_date::date, fr.period_start::date, fr.created_at::date) between v_start and v_end
    ) fin on true
  )
  select
    counted.total,
    coalesce(jsonb_agg(jsonb_build_object(
      'marketplace_order_item_id', e.marketplace_order_item_id,
      'marketplace_order_id', e.marketplace_order_id,
      'marketplace_product_id', nullif(e.marketplace_product_id, ''),
      'marketplace', e.marketplace,
      'marketplace_account_id', e.marketplace_account_id,
      'order_id', e.order_sn,
      'order_sn', e.order_sn,
      'external_order_id', e.external_order_id,
      'resi', e.tracking_number,
      'tracking_number', e.tracking_number,
      'order_status', e.order_status,
      'status', e.order_status,
      'order_date', e.order_date,
      'date', e.order_date,
      'product_name', e.product_name,
      'variant_name', e.variant_name,
      'marketplace_sku', nullif(e.marketplace_sku, ''),
      'marketplace_sku_id', nullif(e.marketplace_sku_id, ''),
      'marketplace_seller_sku', nullif(e.marketplace_seller_sku, ''),
      'local_sku', nullif(e.local_sku, ''),
      'sku', coalesce(nullif(e.local_sku, ''), nullif(e.marketplace_sku, ''), nullif(e.marketplace_seller_sku, ''), 'unmapped'),
      'qty', e.qty,
      'quantity', e.qty,
      'gross', e.gross_amount,
      'gross_amount', e.gross_amount,
      'gross_sales', e.gross_amount,
      'payout', e.finance_payout,
      'payout_amount', e.finance_payout,
      'net_settlement', e.finance_payout,
      'received_amount', e.finance_payout,
      'statement_id', e.statement_id,
      'settlement_status', case when e.finance_payout <> 0 then coalesce(e.settlement_status, 'settled') else 'missing_payout' end,
      'finance_status', case when e.finance_payout <> 0 then coalesce(e.settlement_status, 'settled') else 'missing_payout' end,
      'payout_status', case when e.finance_payout <> 0 then 'SETTLED' else 'PENDING_PAYOUT' end,
      'mapping_status', coalesce(nullif(e.mapping_status, ''), 'unmapped'),
      'source', 'finance_sku_order_line_details_unmapped_existing_rpc'
    ) order by e.order_date desc nulls last, e.order_sn desc nulls last)
      filter (where e.marketplace_order_item_id is not null),
      '[]'::jsonb
    )
  into v_total, v_rows
  from counted
  left join enriched e on true
  group by counted.total;

  return jsonb_build_object(
    'ok', true,
    'source', 'finance_sku_order_line_details_unmapped_existing_rpc',
    'page', v_page,
    'page_size', v_page_size,
    'total', coalesce(v_total, 0),
    'total_count', coalesce(v_total, 0),
    'total_pages', greatest(1, ceil(coalesce(v_total, 0)::numeric / v_page_size)::integer),
    'rows', coalesce(v_rows, '[]'::jsonb)
  );
end;
$function$;

grant execute on function public.finance_sku_order_line_details(
  date,date,text,uuid,text,text,text,text,integer,integer
) to anon, authenticated, service_role;

-- Patch: restore fast finance_sku_order_details MTD implementation.
create or replace function public.finance_sku_order_details(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null,
  p_marketplace_sku text default null,
  p_local_sku text default null,
  p_search text default null,
  p_payout_filter text default 'all',
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '30s'
as $$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_tenant_id uuid;
  v_role text;
  v_start date := coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date);
  v_end date := coalesce(p_end, timezone('Asia/Jakarta', now())::date);
  v_start_ts timestamptz;
  v_end_ts timestamptz;
  v_marketplace text;
  v_account_id uuid := p_account_id;
  v_marketplace_sku text := lower(nullif(trim(coalesce(p_marketplace_sku, '')), ''));
  v_local_sku text := lower(nullif(trim(coalesce(p_local_sku, '')), ''));
  v_search text := lower(nullif(trim(coalesce(p_search, '')), ''));
  v_filter text := lower(trim(coalesce(p_payout_filter, 'all')));
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 20), 1), 25);
  v_offset integer;
  v_detail_mode boolean;
begin
  -- Set local work_mem to 64MB to keep sorts in-memory (e.g. for partition window functions)
  perform set_config('work_mem', '64MB', true);

  select
    coalesce(
      case
        when (v_claims->>'tenant_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then (v_claims->>'tenant_id')::uuid
        else null::uuid
      end,
      (select u.tenant_id from public.users u where u.user_id = auth.uid() limit 1)
    ),
    coalesce(nullif(v_claims->>'role', ''), '')
  into v_tenant_id, v_role;

  v_start_ts := (v_start::timestamp at time zone 'Asia/Jakarta');
  v_end_ts := ((v_end + 1)::timestamp at time zone 'Asia/Jakarta');
  v_offset := (v_page - 1) * v_page_size;
  v_filter := case
    when v_filter in ('settled', 'released', 'release', 'payout', 'paid payout', 'sudah payout') then 'paid'
    when v_filter in ('pending', 'belum payout', 'no payout', 'missing payout') then 'unpaid'
    when v_filter = '' then 'all'
    else v_filter
  end;
  v_marketplace := case
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
    else null
  end;
  v_detail_mode := v_marketplace_sku is not null
    or v_local_sku is not null
    or v_search is not null;

  if v_role <> 'service_role' and v_tenant_id is null then
    return jsonb_build_object(
      'rows', '[]'::jsonb,
      'page', v_page,
      'page_size', v_page_size,
      'total', 0,
      'total_count', 0,
      'total_pages', 1,
      'source', 'finance_sku_order_details_fast_mtd'
    );
  end if;

  if v_detail_mode then
    return (
      with order_base as (
        select *
        from (
          select
            o.marketplace_order_id,
            o.tenant_id,
            o.marketplace_account_id,
            o.order_created_at,
            timezone('Asia/Jakarta', o.order_created_at)::date as order_date,
            coalesce(nullif(o.order_id::text, ''), nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), o.marketplace_order_id::text) as order_key,
            coalesce(nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), nullif(o.order_id::text, '')) as order_sn,
            coalesce(nullif(o.tracking_number, ''), nullif(o.label_code, ''), nullif(o.package_id, '')) as tracking_number,
            lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) as status_text,
            coalesce(nullif(o.gross_amount, 0), nullif(o.total_amount, 0), nullif(o.paid_amount, 0), 0)::numeric as order_gross,
            case
              when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
              when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
              else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
            end as marketplace_group
          from public.marketplace_orders o
          where o.order_created_at >= v_start_ts
            and o.order_created_at < v_end_ts
            and (v_role = 'service_role' or o.tenant_id = v_tenant_id)
            and (v_account_id is null or o.marketplace_account_id = v_account_id)
        ) o
        where (v_marketplace is null or o.marketplace_group = v_marketplace)
          and o.status_text not like '%cancel%'
          and o.status_text not like '%batal%'
          and o.status_text not like '%unpaid%'
          and o.status_text not like '%in_cancel%'
      ),
      finance_by_order as (
        select
          ob.marketplace_order_id,
          coalesce(sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)), 0)::numeric as payout,
          coalesce(sum(coalesce(fr.gross_amount, fr.gross_sales, 0)), 0)::numeric as finance_gross
        from order_base ob
        join public.marketplace_finance_reports fr
          on fr.tenant_id = ob.tenant_id
         and fr.marketplace_account_id = ob.marketplace_account_id
         and fr.order_id = ob.order_key
        group by ob.marketplace_order_id
      ),
      line_base as (
        select
          ob.*,
          oi.marketplace_order_item_id,
          coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku_id,
          coalesce(nullif(oi.marketplace_sku, ''), nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku,
          coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as marketplace_seller_sku,
          coalesce(nullif(oi.local_sku, ''), nullif(oi.mapped_local_sku, '')) as local_sku,
          coalesce(nullif(oi.marketplace_product_name, ''), nullif(oi.product_name, ''), nullif(oi.local_product_name, '')) as product_name,
          coalesce(nullif(oi.marketplace_variant_name, ''), nullif(oi.variant_name, ''), nullif(oi.variation_name, '')) as variant_name,
          greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1)::numeric as qty,
          coalesce(
            nullif(oi.gross_amount, 0),
            nullif(oi.paid_amount, 0),
            nullif(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1),
            0
          )::numeric as line_gross
        from order_base ob
        join public.marketplace_order_items oi
          on oi.tenant_id = ob.tenant_id
         and oi.marketplace_order_id = ob.marketplace_order_id
        where (v_marketplace_sku is null or v_marketplace_sku in (
            lower(coalesce(oi.marketplace_sku_id, '')),
            lower(coalesce(oi.marketplace_sku, '')),
            lower(coalesce(oi.remote_sku_id, '')),
            lower(coalesce(oi.marketplace_seller_sku, '')),
            lower(coalesce(oi.seller_sku, ''))
          ))
          and (v_local_sku is null or v_local_sku = lower(coalesce(oi.local_sku, oi.mapped_local_sku, '')))
          and (v_search is null or lower(concat_ws(' ', ob.order_key, ob.order_sn, ob.tracking_number, oi.marketplace_sku_id, oi.marketplace_sku, oi.marketplace_seller_sku, oi.seller_sku, oi.local_sku, oi.mapped_local_sku, oi.marketplace_product_name, oi.product_name, oi.marketplace_variant_name, oi.variant_name)) like '%' || v_search || '%')
      ),
      line_calc as (
        select lb.*, sum(lb.line_gross) over (partition by lb.marketplace_order_id) as order_line_gross
        from line_base lb
      ),
      enriched_base as (
        select
          lc.*,
          coalesce(f.payout, 0)::numeric as order_payout,
          (f.marketplace_order_id is not null) as has_payout
        from line_calc lc
        left join finance_by_order f on f.marketplace_order_id = lc.marketplace_order_id
      ),
      filtered as (
        select *
        from enriched_base
        where (v_filter = 'all' or (v_filter = 'paid' and has_payout) or (v_filter = 'unpaid' and not has_payout))
      ),
      counted as (
        select filtered.*, count(*) over ()::integer as total_count
        from filtered
      ),
      paged as (
        select *
        from counted
        order by order_created_at desc, order_key
        offset v_offset
        limit v_page_size
      ),
      hpp_sku as (
        select tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
               max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
               max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
        from public.marketplace_variant_hpp_mappings
        where coalesce(is_active, true) is true and nullif(marketplace_sku_id, '') is not null
          and (v_role = 'service_role' or tenant_id = v_tenant_id)
        group by tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, ''))
      ),
      hpp_seller as (
        select tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
               max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
               max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
        from public.marketplace_variant_hpp_mappings
        where coalesce(is_active, true) is true and nullif(marketplace_seller_sku, '') is not null
          and (v_role = 'service_role' or tenant_id = v_tenant_id)
        group by tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, ''))
      ),
      hpp_local as (
        select tenant_id, marketplace_account_id, lower(nullif(local_sku, '')) as local_sku,
               max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
               max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
        from public.marketplace_variant_hpp_mappings
        where coalesce(is_active, true) is true and nullif(local_sku, '') is not null
          and (v_role = 'service_role' or tenant_id = v_tenant_id)
        group by tenant_id, marketplace_account_id, lower(nullif(local_sku, ''))
      ),
      paged_enriched as (
        select
          p.*,
          coalesce(hs.hpp, hsel.hpp, hl.hpp, 0)::numeric as unit_hpp,
          coalesce(hs.target_margin, hsel.target_margin, hl.target_margin, 0)::numeric as target_margin
        from paged p
        left join hpp_sku hs on hs.tenant_id = p.tenant_id and hs.marketplace_account_id = p.marketplace_account_id and hs.marketplace_sku_id = lower(nullif(p.marketplace_sku_id, ''))
        left join hpp_seller hsel on hsel.tenant_id = p.tenant_id and hsel.marketplace_account_id = p.marketplace_account_id and hsel.marketplace_seller_sku = lower(nullif(p.marketplace_seller_sku, ''))
        left join hpp_local hl on hl.tenant_id = p.tenant_id and hl.marketplace_account_id = p.marketplace_account_id and hl.local_sku = lower(nullif(p.local_sku, ''))
      )
      select jsonb_build_object(
        'rows', coalesce(jsonb_agg(jsonb_build_object(
          'source', 'finance_sku_order_details_fast_mtd_detail',
          'order', order_key,
          'order_id', order_key,
          'order_sn', order_sn,
          'marketplace_order_id', marketplace_order_id,
          'marketplace_order_item_id', marketplace_order_item_id,
          'resi', tracking_number,
          'tracking_number', tracking_number,
          'order_date', order_created_at,
          'order_created_at', order_created_at,
          'marketplace', marketplace_group,
          'marketplace_account_id', marketplace_account_id,
          'local_sku', coalesce(nullif(local_sku, ''), '-'),
          'sku', coalesce(nullif(local_sku, ''), nullif(marketplace_sku_id, ''), nullif(marketplace_seller_sku, ''), '-'),
          'marketplace_sku_id', marketplace_sku_id,
          'marketplace_sku', marketplace_sku,
          'marketplace_seller_sku', marketplace_seller_sku,
          'product_name', product_name,
          'variant_name', variant_name,
          'marketplace_variation_name', variant_name,
          'qty', qty,
          'quantity', qty,
          'gross', line_gross,
          'gross_amount', line_gross,
          'gross_total', line_gross,
          'gross_per_item', case when qty > 0 then line_gross / qty else 0 end,
          'payout', case when has_payout and order_line_gross > 0 then order_payout * (line_gross / order_line_gross) else 0 end,
          'payout_amount', case when has_payout and order_line_gross > 0 then order_payout * (line_gross / order_line_gross) else 0 end,
          'payout_per_item', case when has_payout and order_line_gross > 0 and qty > 0 then (order_payout * (line_gross / order_line_gross)) / qty else 0 end,
          'hpp', unit_hpp * qty,
          'hpp_total', unit_hpp * qty,
          'hpp_per_item', unit_hpp,
          'unit_hpp', unit_hpp,
          'hpp_status', case when unit_hpp > 0 then 'HPP mapping' else 'HPP belum mapping' end,
          'target_margin_percent', target_margin,
          'finance_status', case when has_payout then 'SETTLED' else 'PENDING_PAYOUT' end,
          'payout_status', case when has_payout then 'SETTLED' else 'PENDING_PAYOUT' end
        ) order by order_created_at desc, order_key), '[]'::jsonb),
        'page', v_page,
        'page_size', v_page_size,
        'total', coalesce(max(total_count), 0),
        'total_count', coalesce(max(total_count), 0),
        'total_pages', greatest(1, ceil(coalesce(max(total_count), 0)::numeric / v_page_size)::integer),
        'source', 'finance_sku_order_details_fast_mtd'
      )
      from paged_enriched
    );
  end if;

  return (
    with order_base as (
      select *
      from (
        select
          o.marketplace_order_id,
          o.tenant_id,
          o.marketplace_account_id,
          o.order_created_at,
          timezone('Asia/Jakarta', o.order_created_at)::date as order_date,
          coalesce(nullif(o.order_id::text, ''), nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), o.marketplace_order_id::text) as order_key,
          lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) as status_text,
          case
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
            else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
          end as marketplace_group
        from public.marketplace_orders o
        where o.order_created_at >= v_start_ts
          and o.order_created_at < v_end_ts
          and (v_role = 'service_role' or o.tenant_id = v_tenant_id)
          and (v_account_id is null or o.marketplace_account_id = v_account_id)
      ) o
      where (v_marketplace is null or o.marketplace_group = v_marketplace)
        and o.status_text not like '%cancel%'
        and o.status_text not like '%batal%'
        and o.status_text not like '%unpaid%'
        and o.status_text not like '%in_cancel%'
    ),
    finance_by_order as (
      select
        ob.marketplace_order_id,
        coalesce(sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)), 0)::numeric as payout
      from order_base ob
      join public.marketplace_finance_reports fr
        on fr.tenant_id = ob.tenant_id
       and fr.marketplace_account_id = ob.marketplace_account_id
       and fr.order_id = ob.order_key
      group by ob.marketplace_order_id
    ),
    line_base as (
      select
        ob.*,
        oi.marketplace_order_item_id,
        coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku_id,
        coalesce(nullif(oi.marketplace_sku, ''), nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku,
        coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as marketplace_seller_sku,
        coalesce(nullif(oi.local_sku, ''), nullif(oi.mapped_local_sku, '')) as local_sku,
        coalesce(nullif(oi.marketplace_product_name, ''), nullif(oi.product_name, ''), nullif(oi.local_product_name, '')) as product_name,
        coalesce(nullif(oi.marketplace_variant_name, ''), nullif(oi.variant_name, ''), nullif(oi.variation_name, '')) as variant_name,
        greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1)::numeric as qty,
        coalesce(
          nullif(oi.gross_amount, 0),
          nullif(oi.paid_amount, 0),
          nullif(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1),
          0
        )::numeric as line_gross
      from order_base ob
      join public.marketplace_order_items oi
        on oi.tenant_id = ob.tenant_id
       and oi.marketplace_order_id = ob.marketplace_order_id
    ),
    line_calc as (
      select lb.*, sum(lb.line_gross) over (partition by lb.marketplace_order_id) as order_line_gross
      from line_base lb
    ),
    enriched_base as (
      select
        lc.*,
        coalesce(f.payout, 0)::numeric as order_payout,
        (f.marketplace_order_id is not null) as has_payout
      from line_calc lc
      left join finance_by_order f on f.marketplace_order_id = lc.marketplace_order_id
    ),
    filtered as (
      select *
      from enriched_base
      where (v_filter = 'all' or (v_filter = 'paid' and has_payout) or (v_filter = 'unpaid' and not has_payout))
    ),
    grouped as (
      select
        tenant_id,
        marketplace_account_id,
        marketplace_group,
        coalesce(nullif(marketplace_sku_id, ''), nullif(marketplace_seller_sku, ''), nullif(local_sku, ''), 'unmapped') as sku_key,
        min(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
        min(nullif(marketplace_sku, '')) as marketplace_sku,
        min(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
        min(nullif(local_sku, '')) as local_sku,
        min(nullif(product_name, '')) as product_name,
        min(nullif(variant_name, '')) as variant_name,
        sum(qty)::numeric as qty_total,
        sum(line_gross)::numeric as gross_total,
        sum(line_gross) filter (where has_payout)::numeric as settled_gross_total,
        sum(line_gross) filter (where not has_payout)::numeric as unpaid_gross_total,
        sum(case when has_payout and order_line_gross > 0 then order_payout * (line_gross / order_line_gross) else 0 end)::numeric as payout_total,
        sum(case when has_payout and order_line_gross > 0 and order_payout > 0 then order_payout * (line_gross / order_line_gross) else 0 end)::numeric as positive_payout_total,
        sum(case when has_payout and order_line_gross > 0 and order_payout < 0 then order_payout * (line_gross / order_line_gross) else 0 end)::numeric as negative_payout_total,
        sum(qty) filter (where has_payout)::numeric as settled_qty,
        sum(qty) filter (where not has_payout)::numeric as unpaid_qty,
        count(distinct order_key)::integer as order_count,
        count(distinct order_key) filter (where has_payout)::integer as settled_order_count,
        count(distinct order_key) filter (where not has_payout)::integer as unpaid_order_count
      from filtered
      group by tenant_id, marketplace_account_id, marketplace_group,
        coalesce(nullif(marketplace_sku_id, ''), nullif(marketplace_seller_sku, ''), nullif(local_sku, ''), 'unmapped')
    ),
    hpp_sku as (
      select tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
             max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
             max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
      from public.marketplace_variant_hpp_mappings
      where coalesce(is_active, true) is true and nullif(marketplace_sku_id, '') is not null
        and (v_role = 'service_role' or tenant_id = v_tenant_id)
      group by tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, ''))
    ),
    hpp_seller as (
      select tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
             max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
             max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
      from public.marketplace_variant_hpp_mappings
      where coalesce(is_active, true) is true and nullif(marketplace_seller_sku, '') is not null
        and (v_role = 'service_role' or tenant_id = v_tenant_id)
      group by tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, ''))
    ),
    hpp_local as (
      select tenant_id, marketplace_account_id, lower(nullif(local_sku, '')) as local_sku,
             max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
             max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
      from public.marketplace_variant_hpp_mappings
      where coalesce(is_active, true) is true and nullif(local_sku, '') is not null
        and (v_role = 'service_role' or tenant_id = v_tenant_id)
      group by tenant_id, marketplace_account_id, lower(nullif(local_sku, ''))
    ),
    grouped_enriched as (
      select
        g.*,
        coalesce(hs.hpp, hsel.hpp, hl.hpp, 0)::numeric as hpp_per_item,
        coalesce(hs.target_margin, hsel.target_margin, hl.target_margin, 0)::numeric as target_margin_percent,
        (coalesce(hs.hpp, hsel.hpp, hl.hpp, 0) * g.qty_total)::numeric as hpp_total
      from grouped g
      left join hpp_sku hs on hs.tenant_id = g.tenant_id and hs.marketplace_account_id = g.marketplace_account_id and hs.marketplace_sku_id = lower(nullif(g.marketplace_sku_id, ''))
      left join hpp_seller hsel on hsel.tenant_id = g.tenant_id and hsel.marketplace_account_id = g.marketplace_account_id and hsel.marketplace_seller_sku = lower(nullif(g.marketplace_seller_sku, ''))
      left join hpp_local hl on hl.tenant_id = g.tenant_id and hl.marketplace_account_id = g.marketplace_account_id and hl.local_sku = lower(nullif(g.local_sku, ''))
    ),
    counted as (
      select grouped_enriched.*, count(*) over ()::integer as total_count
      from grouped_enriched
    ),
    paged as (
      select *
      from counted
      order by payout_total desc nulls last, gross_total desc nulls last, sku_key
      offset v_offset
      limit v_page_size
    ),
    aggregates as (
      select
        coalesce(sum(gross_total), 0)::numeric as gross_total,
        coalesce(sum(payout_total), 0)::numeric as payout_total,
        coalesce(sum(hpp_total), 0)::numeric as hpp_total,
        coalesce(sum(qty_total), 0)::numeric as qty_total,
        coalesce(sum(settled_qty), 0)::numeric as settled_qty,
        coalesce(sum(unpaid_qty), 0)::numeric as unpaid_qty
      from grouped_enriched
    )
    select jsonb_build_object(
      'rows', coalesce(jsonb_agg(jsonb_build_object(
        'source', 'finance_sku_order_details_fast_mtd_group',
        'sku_detail_source', 'v82o',
        'marketplace', marketplace_group,
        'marketplace_account_id', marketplace_account_id,
        'sku', coalesce(nullif(local_sku, ''), nullif(marketplace_sku_id, ''), nullif(marketplace_seller_sku, ''), sku_key),
        'local_sku', coalesce(nullif(local_sku, ''), '-'),
        'marketplace_sku_id', marketplace_sku_id,
        'marketplace_sku', marketplace_sku,
        'marketplace_seller_sku', marketplace_seller_sku,
        'product_name', product_name,
        'variant_name', variant_name,
        'marketplace_variation_name', variant_name,
        'qty', coalesce(qty_total, 0),
        'qty_total', coalesce(qty_total, 0),
        'quantity', coalesce(qty_total, 0),
        'paid_qty', coalesce(settled_qty, 0),
        'settled_qty', coalesce(settled_qty, 0),
        'qty_settled', coalesce(settled_qty, 0),
        'unpaid_qty', coalesce(unpaid_qty, 0),
        'qty_unpaid', coalesce(unpaid_qty, 0),
        'gross_total', coalesce(gross_total, 0),
        'gross_sales', coalesce(gross_total, 0),
        'gross_amount', coalesce(gross_total, 0),
        'paid_gross_total', coalesce(settled_gross_total, 0),
        'settled_gross_total', coalesce(settled_gross_total, 0),
        'unpaid_gross_total', coalesce(unpaid_gross_total, 0),
        'payout_total', coalesce(payout_total, 0),
        'payout_amount', coalesce(payout_total, 0),
        'received_amount', coalesce(payout_total, 0),
        'net_settlement', coalesce(payout_total, 0),
        'positive_payout_total', coalesce(positive_payout_total, 0),
        'negative_payout_total', coalesce(negative_payout_total, 0),
        'hpp_total', coalesce(hpp_total, 0),
        'total_hpp', coalesce(hpp_total, 0),
        'paid_hpp_total', coalesce(hpp_total, 0),
        'settled_hpp_total', coalesce(hpp_total, 0),
        'hpp_per_item', coalesce(hpp_per_item, 0),
        'unit_hpp', coalesce(hpp_per_item, 0),
        'hpp', coalesce(hpp_per_item, 0),
        'hpp_status', case when coalesce(hpp_per_item, 0) > 0 then 'HPP mapping' else 'HPP belum mapping' end,
        'target_margin_percent', coalesce(target_margin_percent, 0),
        'order_count', coalesce(order_count, 0),
        'paid_order_count', coalesce(settled_order_count, 0),
        'settled_order_count', coalesce(settled_order_count, 0),
        'unpaid_order_count', coalesce(unpaid_order_count, 0),
        'gross_per_item', case when coalesce(qty_total, 0) > 0 then coalesce(gross_total, 0) / qty_total else 0 end,
        'payout_per_item', case when coalesce(settled_qty, 0) > 0 then coalesce(payout_total, 0) / settled_qty else 0 end
      ) order by payout_total desc nulls last, gross_total desc nulls last, sku_key), '[]'::jsonb),
      'page', v_page,
      'page_size', v_page_size,
      'total', coalesce(max(total_count), 0),
      'total_count', coalesce(max(total_count), 0),
      'total_pages', greatest(1, ceil(coalesce(max(total_count), 0)::numeric / v_page_size)::integer),
      'aggregates', (select to_jsonb(a) from aggregates a),
      'source', 'finance_sku_order_details_fast_mtd'
    )
    from paged
  );
end;
$$;

grant execute on function public.finance_sku_order_details(date, date, text, uuid, text, text, text, text, integer, integer)
  to authenticated, service_role;
grant execute on function public.finance_sku_order_details(date, date, text, uuid, text, text, text, text, integer, integer)
  to anon;
notify pgrst, 'reload schema';
-- Patch: support indexes for restored fast finance_sku_order_details MTD.
create index if not exists idx_mo_fin_sku_mtd_tenant_date_acc_20260622
  on public.marketplace_orders (tenant_id, order_created_at, marketplace_account_id, marketplace_order_id);

create index if not exists idx_mo_fin_sku_mtd_order_key_20260622
  on public.marketplace_orders (tenant_id, marketplace_account_id, order_id, order_sn, external_order_id);

create index if not exists idx_moi_fin_sku_mtd_order_20260622
  on public.marketplace_order_items (tenant_id, marketplace_order_id);

create index if not exists idx_moi_fin_sku_mtd_sku_20260622
  on public.marketplace_order_items (tenant_id, marketplace_order_id, marketplace_sku_id, remote_sku_id, marketplace_seller_sku, seller_sku, local_sku, mapped_local_sku);

create index if not exists idx_mfr_fin_sku_mtd_orderid_20260622
  on public.marketplace_finance_reports (tenant_id, marketplace_account_id, order_id);

create index if not exists idx_mfr_fin_sku_mtd_marketplace_order_20260622
  on public.marketplace_finance_reports (tenant_id, marketplace_account_id, marketplace_order_id);

create index if not exists idx_hpp_fin_sku_mtd_marketplace_sku_20260622
  on public.marketplace_variant_hpp_mappings (tenant_id, marketplace_account_id, marketplace_sku_id)
  where coalesce(is_active, true) is true;

create index if not exists idx_hpp_fin_sku_mtd_seller_sku_20260622
  on public.marketplace_variant_hpp_mappings (tenant_id, marketplace_account_id, marketplace_seller_sku)
  where coalesce(is_active, true) is true;

create index if not exists idx_hpp_fin_sku_mtd_local_sku_20260622
  on public.marketplace_variant_hpp_mappings (tenant_id, marketplace_account_id, local_sku)
  where coalesce(is_active, true) is true;

analyze public.marketplace_orders;
analyze public.marketplace_order_items;
analyze public.marketplace_finance_reports;
analyze public.marketplace_variant_hpp_mappings;
