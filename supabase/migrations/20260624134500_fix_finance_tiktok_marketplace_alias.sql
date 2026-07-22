-- Normalize marketplace alias inside finance RPCs.
-- tiktok and tiktok_shop must be treated as the same marketplace.

create or replace function public._finance_marketplace_norm_20260624(p_marketplace text)
returns text
language sql
immutable
as $$
  select case
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
    when coalesce(trim(p_marketplace), '') = '' then ''
    else lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g'))
  end;
$$;

do $$
declare
  r record;
  v_def text;
  v_new text;
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

    -- Order side alias.
    v_new := replace(
      v_new,
      'o.marketplace_group = v_marketplace',
      'o.marketplace_group = public._finance_marketplace_norm_20260624(v_marketplace)'
    );

    v_new := replace(
      v_new,
      'v_marketplace is null or o.marketplace_group = public._finance_marketplace_norm_20260624(v_marketplace)',
      'v_marketplace is null or v_marketplace = '''' or o.marketplace_group = public._finance_marketplace_norm_20260624(v_marketplace)'
    );

    -- Finance item side alias. This is the important part for tiktok vs tiktok_shop.
    v_new := replace(
      v_new,
      'lower(coalesce(fi.marketplace, '''')) = v_marketplace',
      'public._finance_marketplace_norm_20260624(fi.marketplace) = public._finance_marketplace_norm_20260624(v_marketplace)'
    );

    -- Re-assert strict payout classification, in case older fallback text still exists.
    v_new := replace(
      v_new,
      'coalesce(fi_order_sn, '''') <> ''''',
      'greatest(abs(coalesce(fi_received_amount, 0)), abs(coalesce(fi_net_settlement, 0))) > 0'
    );

    v_new := replace(
      v_new,
      'coalesce(fi_order_sn, '''') = ''''',
      'greatest(abs(coalesce(fi_received_amount, 0)), abs(coalesce(fi_net_settlement, 0))) <= 0'
    );

    v_new := replace(
      v_new,
      '(f.marketplace_order_id is not null) as has_payout',
      '(coalesce(f.payout, 0) > 0) as has_payout'
    );

    v_new := replace(
      v_new,
      '''status'', case when fi_order_sn is null then ''unpaid'' else ''settled'' end',
      '''status'', case when greatest(abs(coalesce(fi_received_amount, 0)), abs(coalesce(fi_net_settlement, 0))) > 0 then ''settled'' else ''unpaid'' end'
    );

    v_new := replace(
      v_new,
      '''payout_status'', case when fi_order_sn is null then ''pending'' else ''settled'' end',
      '''payout_status'', case when greatest(abs(coalesce(fi_received_amount, 0)), abs(coalesce(fi_net_settlement, 0))) > 0 then ''SETTLED'' else ''PENDING_PAYOUT'' end'
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