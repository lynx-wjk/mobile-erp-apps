-- Sync allocated TikTok finance item payouts into marketplace_finance_reports
-- so existing finance dashboard/SKU summary reads payout correctly.

with src as (
  select
    fi.tenant_id,
    fi.marketplace_account_id,
    'tiktok_shop'::text as marketplace,
    coalesce(nullif(fi.order_id, ''), nullif(fi.order_sn, ''), nullif(fi.external_order_id, '')) as order_id,
    min((coalesce(fi.order_created_at, fi.created_at) at time zone 'Asia/Jakarta')::date) as period_start,
    max((coalesce(fi.order_created_at, fi.created_at) at time zone 'Asia/Jakarta')::date) as period_end,
    sum(coalesce(fi.gross_amount, 0))::numeric as gross_amount,
    sum(coalesce(fi.gross_amount, 0))::numeric as gross_sales,
    sum(coalesce(fi.received_amount, fi.net_settlement, 0))::numeric as payout_amount,
    sum(coalesce(fi.received_amount, fi.net_settlement, 0))::numeric as received_amount,
    sum(coalesce(fi.net_settlement, fi.received_amount, 0))::numeric as net_settlement,
    max(coalesce(fi.transaction_time, fi.updated_at, fi.created_at)) as settlement_date,
    min(fi.statement_id) as statement_id
  from public.marketplace_finance_items fi
  where lower(coalesce(fi.marketplace, '')) in ('tiktok', 'tiktok_shop')
    and coalesce(nullif(fi.order_id, ''), nullif(fi.order_sn, ''), nullif(fi.external_order_id, '')) is not null
    and greatest(abs(coalesce(fi.received_amount, 0)), abs(coalesce(fi.net_settlement, 0))) > 0
  group by
    fi.tenant_id,
    fi.marketplace_account_id,
    coalesce(nullif(fi.order_id, ''), nullif(fi.order_sn, ''), nullif(fi.external_order_id, ''))
),
updated as (
  update public.marketplace_finance_reports fr
  set
    marketplace = src.marketplace,
    gross_amount = src.gross_amount,
    gross_sales = src.gross_sales,
    payout_amount = src.payout_amount,
    received_amount = src.received_amount,
    net_settlement = src.net_settlement,
    settlement_status = 'SETTLED',
    settlement_date = src.settlement_date,
    updated_at = now()
  from src
  where fr.tenant_id = src.tenant_id
    and fr.marketplace_account_id = src.marketplace_account_id
    and fr.order_id = src.order_id
  returning fr.order_id
),
inserted as (
  insert into public.marketplace_finance_reports (
    tenant_id,
    marketplace_account_id,
    marketplace,
    order_id,
    report_type,
    period_start,
    period_end,
    gross_amount,
    gross_sales,
    payout_amount,
    received_amount,
    net_settlement,
    settlement_status,
    settlement_date,
    created_at,
    updated_at
  )
  select
    src.tenant_id,
    src.marketplace_account_id,
    src.marketplace,
    src.order_id,
    'order_settlement',
    src.period_start,
    src.period_end,
    src.gross_amount,
    src.gross_sales,
    src.payout_amount,
    src.received_amount,
    src.net_settlement,
    'SETTLED',
    src.settlement_date,
    now(),
    now()
  from src
  where not exists (
    select 1
    from public.marketplace_finance_reports fr
    where fr.tenant_id = src.tenant_id
      and fr.marketplace_account_id = src.marketplace_account_id
      and fr.order_id = src.order_id
  )
  returning order_id
)
select
  (select count(*) from src) as source_orders,
  (select count(*) from updated) as updated_reports,
  (select count(*) from inserted) as inserted_reports;

notify pgrst, 'reload schema';