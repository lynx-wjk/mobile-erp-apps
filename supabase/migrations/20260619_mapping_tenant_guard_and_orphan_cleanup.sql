-- Tenant guard and orphan cleanup for marketplace mapping tables.
-- Dynamic and schema-aware. No new RPC.
-- Fix: PostgreSQL has no min(uuid), so default tenant uses first non-null tenant_id.

do $$
declare
  tbl text;
  has_tenant boolean;
  has_account boolean;
  default_tenant uuid;
  tenant_count int;
  deleted_count bigint;
  null_count bigint;
  total_count bigint;
begin
  select count(distinct tenant_id)
    into tenant_count
  from public.marketplace_accounts
  where tenant_id is not null;

  if tenant_count = 1 then
    select tenant_id
      into default_tenant
    from public.marketplace_accounts
    where tenant_id is not null
    limit 1;
  end if;

  foreach tbl in array array[
    'marketplace_variant_hpp_mappings',
    'marketplace_sku_maps',
    'marketplace_sku_mappings'
  ] loop
    if to_regclass('public.' || tbl) is null then
      raise notice '%.skip=table_missing', tbl;
      continue;
    end if;

    select exists (
      select 1 from information_schema.columns
      where table_schema='public' and table_name=tbl and column_name='tenant_id'
    ) into has_tenant;

    if not has_tenant then
      execute format('alter table public.%I add column tenant_id uuid', tbl);
      raise notice '%.tenant_id=added', tbl;
    end if;

    select exists (
      select 1 from information_schema.columns
      where table_schema='public' and table_name=tbl and column_name='marketplace_account_id'
    ) into has_account;

    if has_account then
      execute format($f$
        update public.%I m
        set tenant_id = a.tenant_id
        from public.marketplace_accounts a
        where m.marketplace_account_id = a.marketplace_account_id
          and a.tenant_id is not null
          and (m.tenant_id is null or m.tenant_id <> a.tenant_id)
      $f$, tbl);

      execute format($f$
        delete from public.%I m
        where m.marketplace_account_id is not null
          and not exists (
            select 1
            from public.marketplace_accounts a
            where a.marketplace_account_id = m.marketplace_account_id
          )
      $f$, tbl);
      get diagnostics deleted_count = row_count;
      raise notice '%.orphan_account_deleted=%', tbl, deleted_count;
    else
      raise notice '%.marketplace_account_id=missing_skip_orphan_delete', tbl;
    end if;

    if default_tenant is not null then
      execute format('update public.%I set tenant_id = $1 where tenant_id is null', tbl)
      using default_tenant;
    end if;

    execute format('create index if not exists %I on public.%I (tenant_id)', tbl || '_tenant_id_idx', tbl);

    execute format('select count(*), count(*) filter (where tenant_id is null) from public.%I', tbl)
      into total_count, null_count;
    raise notice '%.rows=% tenant_null_rows=%', tbl, total_count, null_count;
  end loop;
end $$;
