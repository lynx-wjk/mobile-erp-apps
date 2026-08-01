-- Migration: sync tiktok finance items to marketplace_finance_reports on change

create or replace function public.sync_marketplace_finance_items_to_reports()
returns trigger
language plpgsql
security definer
as $$
declare
  v_order_id text;
  v_tenant_id uuid;
  v_marketplace_account_id uuid;
  v_marketplace text;
  v_marketplace_norm text;
  
  v_period_start date;
  v_period_end date;
  v_gross_amount numeric;
  v_gross_sales numeric;
  v_payout_amount numeric;
  v_received_amount numeric;
  v_net_settlement numeric;
  v_settlement_date date;
begin
  if TG_OP = 'DELETE' then
    v_order_id := coalesce(nullif(OLD.order_id, ''), nullif(OLD.order_sn, ''), nullif(OLD.external_order_id, ''));
    v_tenant_id := OLD.tenant_id;
    v_marketplace_account_id := OLD.marketplace_account_id;
    v_marketplace := OLD.marketplace;
  else
    v_order_id := coalesce(nullif(NEW.order_id, ''), nullif(NEW.order_sn, ''), nullif(NEW.external_order_id, ''));
    v_tenant_id := NEW.tenant_id;
    v_marketplace_account_id := NEW.marketplace_account_id;
    v_marketplace := NEW.marketplace;
  end if;

  if v_order_id is null or v_tenant_id is null then
    return coalesce(NEW, OLD);
  end if;

  v_marketplace_norm := lower(v_marketplace);
  if v_marketplace_norm = 'tiktok' then
    v_marketplace_norm := 'tiktok_shop';
  end if;

  -- Aggregate values from marketplace_finance_items
  select
    min((coalesce(fi.order_created_at, fi.created_at) at time zone 'Asia/Jakarta')::date) as period_start,
    max((coalesce(fi.order_created_at, fi.created_at) at time zone 'Asia/Jakarta')::date) as period_end,
    sum(coalesce(fi.gross_amount, 0)) as gross_amount,
    sum(coalesce(fi.gross_amount, 0)) as gross_sales,
    sum(coalesce(fi.received_amount, fi.net_settlement, 0)) as payout_amount,
    sum(coalesce(fi.received_amount, fi.net_settlement, 0)) as received_amount,
    sum(coalesce(fi.net_settlement, fi.received_amount, 0)) as net_settlement,
    max(coalesce(fi.transaction_time, fi.updated_at, fi.created_at))::date as settlement_date
  into
    v_period_start, v_period_end, v_gross_amount, v_gross_sales, v_payout_amount, v_received_amount, v_net_settlement, v_settlement_date
  from public.marketplace_finance_items fi
  where fi.tenant_id = v_tenant_id
    and fi.marketplace_account_id = v_marketplace_account_id
    and lower(coalesce(fi.marketplace, '')) in ('tiktok', 'tiktok_shop')
    and coalesce(nullif(fi.order_id, ''), nullif(fi.order_sn, ''), nullif(fi.external_order_id, '')) = v_order_id;

  if v_period_start is not null then
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
    ) values (
      v_tenant_id,
      v_marketplace_account_id,
      v_marketplace_norm,
      v_order_id,
      'order_settlement',
      v_period_start,
      v_period_end,
      v_gross_amount,
      v_gross_sales,
      v_payout_amount,
      v_received_amount,
      v_net_settlement,
      'SETTLED',
      v_settlement_date,
      now(),
      now()
    )
    on conflict (tenant_id, marketplace, order_id) do update
    set
      marketplace_account_id = excluded.marketplace_account_id,
      period_start = excluded.period_start,
      period_end = excluded.period_end,
      gross_amount = excluded.gross_amount,
      gross_sales = excluded.gross_sales,
      payout_amount = excluded.payout_amount,
      received_amount = excluded.received_amount,
      net_settlement = excluded.net_settlement,
      settlement_status = 'SETTLED',
      settlement_date = excluded.settlement_date,
      updated_at = now();
  else
    update public.marketplace_finance_reports fr
    set
      gross_amount = 0,
      gross_sales = 0,
      payout_amount = 0,
      received_amount = 0,
      net_settlement = 0,
      settlement_status = 'UNSETTLED',
      updated_at = now()
    where fr.tenant_id = v_tenant_id
      and fr.marketplace = v_marketplace_norm
      and fr.order_id = v_order_id;
  end if;

  return coalesce(NEW, OLD);
end;
$$;

drop trigger if exists trg_sync_marketplace_finance_items_to_reports on public.marketplace_finance_items;
create trigger trg_sync_marketplace_finance_items_to_reports
after insert or update or delete
on public.marketplace_finance_items
for each row
execute function public.sync_marketplace_finance_items_to_reports();
