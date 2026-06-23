create or replace function public.admin_hard_delete_user(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'auth'
as $function$
declare
  v_actor record;
  v_target record;
  r record;
  v_rows int := 0;
  v_total_reassigned int := 0;
  v_deleted_auth int := 0;
  v_deleted_public int := 0;
  v_updates jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then
    raise exception 'User belum login';
  end if;

  if p_user_id is null then
    raise exception 'p_user_id kosong';
  end if;

  select *
    into v_actor
  from public._rpc_current_user_for_write()
  limit 1;

  if v_actor.user_id is null then
    raise exception 'User aktif tidak ditemukan';
  end if;

  if v_actor.user_id = p_user_id then
    raise exception 'Tidak bisa hard delete akun sendiri';
  end if;

  if not (
    public._rpc_is_platform_owner_role(v_actor.normalized_role)
    or v_actor.normalized_role in ('super_admin', 'superadmin', 'owner', 'platform_super_admin')
  ) then
    raise exception 'Hard delete user hanya untuk Super Admin / Platform Owner';
  end if;

  select *
    into v_target
  from public.users u
  where u.user_id = p_user_id
    and (
      public._rpc_is_platform_owner_role(v_actor.normalized_role)
      or u.tenant_id = v_actor.tenant_id
    )
  limit 1;

  if v_target.user_id is null then
    raise exception 'Target user tidak ditemukan atau bukan tenant ini';
  end if;

  if lower(coalesce(v_target.role_id, '')) = 'platform_owner' then
    raise exception 'Platform Owner tidak bisa dihapus dari tenant user management';
  end if;

  for r in
    select
      n.nspname as schema_name,
      c.relname as table_name,
      a.attname as column_name,
      co.confdeltype,
      a.attnotnull
    from pg_constraint co
    join pg_class c on c.oid = co.conrelid
    join pg_namespace n on n.oid = c.relnamespace
    join unnest(co.conkey) with ordinality ck(attnum, ord) on true
    join pg_attribute a on a.attrelid = co.conrelid and a.attnum = ck.attnum
    where co.contype = 'f'
      and co.confrelid = 'public.users'::regclass
      and array_length(co.conkey, 1) = 1
      and n.nspname = 'public'
      and c.relname <> 'users'
    order by n.nspname, c.relname, a.attname
  loop
    if r.confdeltype = 'c' then
      continue;
    end if;

    if r.attnotnull then
      execute format(
        'update %I.%I set %I = $1 where %I = $2',
        r.schema_name, r.table_name, r.column_name, r.column_name
      )
      using v_actor.user_id, p_user_id;
    else
      execute format(
        'update %I.%I set %I = null where %I = $1',
        r.schema_name, r.table_name, r.column_name, r.column_name
      )
      using p_user_id;
    end if;

    get diagnostics v_rows = row_count;
    if v_rows > 0 then
      v_total_reassigned := v_total_reassigned + v_rows;
      v_updates := v_updates || jsonb_build_array(jsonb_build_object(
        'table', r.schema_name || '.' || r.table_name,
        'column', r.column_name,
        'rows', v_rows,
        'mode', case when r.attnotnull then 'reassigned_to_actor' else 'set_null' end
      ));
    end if;
  end loop;

  delete from auth.users where id = p_user_id;
  get diagnostics v_deleted_auth = row_count;

  delete from public.users where user_id = p_user_id;
  get diagnostics v_deleted_public = row_count;

  if v_deleted_auth = 0 and v_deleted_public = 0 then
    raise exception 'Target user tidak terhapus';
  end if;

  return jsonb_build_object(
    'ok', true,
    'deleted_user_id', p_user_id,
    'deleted_auth_rows', v_deleted_auth,
    'deleted_public_rows_fallback', v_deleted_public,
    'reassigned_or_nullified_refs', v_total_reassigned,
    'reference_updates', v_updates
  );
end;
$function$;

revoke all on function public.admin_hard_delete_user(uuid) from public;
grant execute on function public.admin_hard_delete_user(uuid) to authenticated;
