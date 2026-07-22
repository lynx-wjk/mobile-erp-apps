-- Fix TikTok finance payout allocation + strict paid/unpaid matching.
-- Paid/settled must mean payout > 0, not just finance row exists.

create or replace function public.tiktok_finance_allocate_statement_payout_20260624(
  p_start date default null,
  p_end date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start date := coalesce(p_start, (now() at time zone 'Asia/Jakarta')::date - 10);
  v_end date := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);
  v_updated integer := 0;
begin
  with base as (
    select
      fi.ctid as rid,
      fi.statement_id,
      fi.tenant_id,
      fi.marketplace_account_id,
      greatest(
        coalesce(fi.gross_amount, 0),
        coalesce(fi.expected_amount, 0),
        0
      )::numeric as alloc_gross,
      case
        when nullif(fi.raw_finance->'statement'->>'settlement_amount', '') ~ '^-?[0-9]+(\.[0-9]+)?$'
          then (fi.raw_finance->'statement'->>'settlement_amount')::numeric
        when nullif(fi.raw_finance->'statement'->>'net_sales_amount', '') ~ '^-?[0-9]+(\.[0-9]+)?$'
          then (fi.raw_finance->'statement'->>'net_sales_amount')::numeric
        else 0
      end as statement_payout
    from public.marketplace_finance_items fi
    where lower(coalesce(fi.marketplace, '')) in ('tiktok', 'tiktok_shop')
      and fi.statement_id is not null
      and ((coalesce(fi.order_created_at, fi.created_at) at time zone 'Asia/Jakarta')::date between v_start and v_end)
  ),
  grouped as (
    select
      rid,
      statement_id,
      tenant_id,
      marketplace_account_id,
      alloc_gross,
      max(statement_payout) over (
        partition by tenant_id, marketplace_account_id, statement_id
      ) as statement_payout,
      sum(alloc_gross) over (
        partition by tenant_id, marketplace_account_id, statement_id
      ) as statement_gross
    from base
  ),
  alloc as (
    select
      rid,
      case
        when statement_payout > 0 and statement_gross > 0 and alloc_gross > 0
          then round(statement_payout * alloc_gross / statement_gross)
        else 0
      end::numeric as allocated_payout
    from grouped
  ),
  upd as (
    update public.marketplace_finance_items fi
    set
      received_amount = alloc.allocated_payout,
      net_settlement = alloc.allocated_payout,
      estimated_profit = alloc.allocated_payout - coalesce(fi.hpp_amount, 0),
      updated_at = now()
    from alloc
    where fi.ctid = alloc.rid
      and alloc.allocated_payout > 0
      and coalesce(fi.received_amount, fi.net_settlement, 0) <= 0
    returning 1
  )
  select count(*) into v_updated from upd;

  return jsonb_build_object(
    'ok', true,
    'updated_rows', v_updated,
    'start', v_start,
    'end', v_end
  );
end $$;

revoke all on function public.tiktok_finance_allocate_statement_payout_20260624(date, date) from public;
grant execute on function public.tiktok_finance_allocate_statement_payout_20260624(date, date) to authenticated, service_role;

select public.tiktok_finance_allocate_statement_payout_20260624('2026-06-01'::date, (now() at time zone 'Asia/Jakarta')::date);

do $$
declare
  r record;
  v_def text;
  v_new text;
  v_finance_source text := $src$
(
  select
    tenant_id,
    marketplace_account_id,
    marketplace,
    order_id,
    marketplace_order_id,
    gross_amount,
    gross_sales,
    payout_amount,
    received_amount,
    net_settlement
  from public.marketplace_finance_reports
  where lower(coalesce(marketplace, '')) not in ('tiktok', 'tiktok_shop')

  union all

  select
    tenant_id,
    marketplace_account_id,
    marketplace,
    coalesce(nullif(order_id, ''), nullif(order_sn, ''), nullif(external_order_id, '')) as order_id,
    marketplace_order_id,
    gross_amount,
    gross_amount as gross_sales,
    received_amount as payout_amount,
    received_amount,
    net_settlement
  from public.marketplace_finance_items
  where lower(coalesce(marketplace, '')) in ('tiktok', 'tiktok_shop')
)$src$;
begin
  for r in
    select p.oid, p.oid::regprocedure::text as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('finance_sku_order_details', 'finance_sku_order_line_details')
  loop
    v_def := pg_get_functiondef(r.oid);
    v_new := v_def;

    -- TikTok payout source: use allocated finance_items instead of zero report rows.
    v_new := replace(
      v_new,
      'public.marketplace_finance_reports fr',
      v_finance_source || ' fr'
    );

    -- Main bug: finance row existing is not payout. Payout must be positive.
    v_new := replace(
      v_new,
      '(f.marketplace_order_id is not null) as has_payout',
      '(coalesce(f.payout, 0) > 0) as has_payout'
    );

    -- Raw fallback bug: paid/unpaid must be based on actual payout, not fi_order_sn.
    v_new := replace(
      v_new,
      'coalesce(fi_order_sn, '''') <> ''''',
      'coalesce(fi_received_amount, fi_net_settlement, 0) > 0'
    );

    v_new := replace(
      v_new,
      'coalesce(fi_order_sn, '''') = ''''',
      'coalesce(fi_received_amount, fi_net_settlement, 0) <= 0'
    );

    v_new := replace(
      v_new,
      '''status'', case when fi_order_sn is null then ''unpaid'' else ''settled'' end',
      '''status'', case when coalesce(fi_received_amount, fi_net_settlement, 0) > 0 then ''settled'' else ''unpaid'' end'
    );

    v_new := replace(
      v_new,
      '''payout_status'', case when fi_order_sn is null then ''pending'' else ''settled'' end',
      '''payout_status'', case when coalesce(fi_received_amount, fi_net_settlement, 0) > 0 then ''SETTLED'' else ''PENDING_PAYOUT'' end'
    );

    if v_new <> v_def then
      execute v_new;
      raise notice 'patched %', r.sig;
    else
      raise notice 'no change %', r.sig;
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
