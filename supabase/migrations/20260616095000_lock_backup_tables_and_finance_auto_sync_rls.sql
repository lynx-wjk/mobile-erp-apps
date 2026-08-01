-- Security containment:
-- 1) Lock accidental public backup marketplace snapshot tables.
-- 2) Replace finance_auto_sync_settings policies with strict tenant/user policy.
-- Safe/idempotent. Does not delete business data.

begin;

do $$
declare
  r record;
begin
  for r in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and c.relname in (
        'backup_marketplace_product_snapshots_20260616_before_full_pull',
        'backup_marketplace_variant_snapshots_20260616_before_full_pull'
      )
  loop
    execute format('revoke all on table public.%I from anon, authenticated', r.relname);
    execute format('alter table public.%I enable row level security', r.relname);
    execute format('alter table public.%I force row level security', r.relname);
  end loop;
end $$;

do $$
declare
  r record;
begin
  if to_regclass('public.finance_auto_sync_settings') is null then
    return;
  end if;

  for r in
    select policyname
    from pg_policies
    where schemaname = 'public'
      and tablename = 'finance_auto_sync_settings'
  loop
    execute format(
      'drop policy if exists %I on public.finance_auto_sync_settings',
      r.policyname
    );
  end loop;

  revoke all on table public.finance_auto_sync_settings from anon;
  revoke all on table public.finance_auto_sync_settings from authenticated;

  grant select, insert, update, delete on table public.finance_auto_sync_settings to authenticated;

  alter table public.finance_auto_sync_settings enable row level security;
  alter table public.finance_auto_sync_settings force row level security;

  create policy finance_auto_sync_settings_strict_select
    on public.finance_auto_sync_settings
    for select
    to authenticated
    using (
      exists (
        select 1
        from public.users u
        where u.user_id = auth.uid()
          and coalesce(u.status, 'active') = 'active'
          and (
            lower(coalesce(u.role_id, '')) = 'platform_owner'
            or u.tenant_id = finance_auto_sync_settings.tenant_id
          )
      )
    );

  create policy finance_auto_sync_settings_strict_insert
    on public.finance_auto_sync_settings
    for insert
    to authenticated
    with check (
      exists (
        select 1
        from public.users u
        where u.user_id = auth.uid()
          and coalesce(u.status, 'active') = 'active'
          and (
            lower(coalesce(u.role_id, '')) = 'platform_owner'
            or u.tenant_id = finance_auto_sync_settings.tenant_id
          )
      )
    );

  create policy finance_auto_sync_settings_strict_update
    on public.finance_auto_sync_settings
    for update
    to authenticated
    using (
      exists (
        select 1
        from public.users u
        where u.user_id = auth.uid()
          and coalesce(u.status, 'active') = 'active'
          and (
            lower(coalesce(u.role_id, '')) = 'platform_owner'
            or u.tenant_id = finance_auto_sync_settings.tenant_id
          )
      )
    )
    with check (
      exists (
        select 1
        from public.users u
        where u.user_id = auth.uid()
          and coalesce(u.status, 'active') = 'active'
          and (
            lower(coalesce(u.role_id, '')) = 'platform_owner'
            or u.tenant_id = finance_auto_sync_settings.tenant_id
          )
      )
    );

  create policy finance_auto_sync_settings_strict_delete
    on public.finance_auto_sync_settings
    for delete
    to authenticated
    using (
      exists (
        select 1
        from public.users u
        where u.user_id = auth.uid()
          and coalesce(u.status, 'active') = 'active'
          and (
            lower(coalesce(u.role_id, '')) = 'platform_owner'
            or u.tenant_id = finance_auto_sync_settings.tenant_id
          )
      )
    );
end $$;

commit;
