-- Repair all remaining exact marketplace comparisons in finance SKU RPCs.

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

    -- Any "lower(coalesce(x.marketplace, '')) = v_marketplace"
    v_new := regexp_replace(
      v_new,
      'lower\(coalesce\(([a-zA-Z_][a-zA-Z0-9_]*)\.marketplace,\s*''''\)\)\s*=\s*v_marketplace',
      'public._finance_marketplace_norm_20260624(\1.marketplace) = public._finance_marketplace_norm_20260624(v_marketplace)',
      'g'
    );

    -- Any "lower(x.marketplace) = v_marketplace"
    v_new := regexp_replace(
      v_new,
      'lower\(([a-zA-Z_][a-zA-Z0-9_]*)\.marketplace\)\s*=\s*v_marketplace',
      'public._finance_marketplace_norm_20260624(\1.marketplace) = public._finance_marketplace_norm_20260624(v_marketplace)',
      'g'
    );

    -- Any "x.marketplace_group = v_marketplace"
    v_new := regexp_replace(
      v_new,
      '([a-zA-Z_][a-zA-Z0-9_]*)\.marketplace_group\s*=\s*v_marketplace',
      '\1.marketplace_group = public._finance_marketplace_norm_20260624(v_marketplace)',
      'g'
    );

    -- Strict payout classification stays strict.
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

    if v_new <> v_def then
      execute v_new;
      raise notice 'patched %', r.sig;
    else
      raise notice 'no change %', r.sig;
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';