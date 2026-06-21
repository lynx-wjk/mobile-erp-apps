-- Audit: Duplicate Keys and Settlement Gaps (Read-Only)
-- Target: C:\Users\budic\Downloads\android\inventory_control_apps\supabase\sql\audit_finance_duplicates_readonly.sql

-- 1. Audit duplicate finance reports by order and statement
select
  tenant_id,
  marketplace,
  marketplace_account_id,
  order_id,
  statement_id,
  count(*) as duplicate_count,
  sum(coalesce(payout_amount, received_amount, net_settlement, 0)) as total_payout_amount,
  array_agg(finance_report_id) as finance_report_ids
from public.marketplace_finance_reports
group by tenant_id, marketplace, marketplace_account_id, order_id, statement_id
having count(*) > 1
order by duplicate_count desc
limit 100;

-- 2. Audit duplicate order items by marketplace item ID
select
  tenant_id,
  marketplace_order_id,
  marketplace_order_item_id,
  count(*) as duplicate_count,
  array_agg(marketplace_order_item_id) as order_item_ids
from public.marketplace_order_items
group by tenant_id, marketplace_order_id, marketplace_order_item_id
having count(*) > 1
order by duplicate_count desc
limit 100;

-- 3. Audit orders with payout but no matching local order records (orphaned payouts)
select
  fr.tenant_id,
  fr.marketplace,
  fr.marketplace_account_id,
  fr.order_id,
  fr.statement_id,
  fr.payout_amount,
  fr.settlement_date
from public.marketplace_finance_reports fr
left join public.marketplace_orders o
  on o.tenant_id = fr.tenant_id
 and o.marketplace_account_id = fr.marketplace_account_id
 and (o.marketplace_order_id = fr.marketplace_order_id or o.order_id = fr.order_id)
where o.marketplace_order_id is null
order by fr.settlement_date desc
limit 100;

-- 4. Duplicate cleanup preparation (SELECT preview only, no DELETE)
-- This CTE generates the list of duplicate IDs to keep (the first/oldest one) and the ones to prune.
with duplicate_ranks as (
  select
    finance_report_id,
    row_number() over (
      partition by tenant_id, marketplace, marketplace_account_id, order_id, statement_id
      order by created_at asc, finance_report_id asc
    ) as row_rank
  from public.marketplace_finance_reports
)
select
  dr.finance_report_id,
  fr.tenant_id,
  fr.marketplace,
  fr.order_id,
  fr.statement_id,
  fr.payout_amount,
  fr.created_at
from duplicate_ranks dr
join public.marketplace_finance_reports fr on fr.finance_report_id = dr.finance_report_id
where dr.row_rank > 1
order by fr.created_at desc;
