create or replace function public.set_production_stage_active_for_app(
  p_progress_id uuid,
  p_stage_key text,
  p_stage_label text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user record;
  v_progress record;
  v_stage_key text;
  v_stage_label text;
  v_sort_order integer;
  v_updated_key text;
begin
  v_stage_key := trim(coalesce(p_stage_key, ''));
  if v_stage_key = '' then
    raise exception 'Stage key wajib diisi.';
  end if;

  select u.user_id, u.tenant_id, u.role_id, u.status
    into v_user
  from public.users u
  where u.user_id = auth.uid();

  if not found or coalesce(v_user.status, 'inactive') <> 'active' then
    raise exception 'User tidak aktif atau tidak ditemukan.';
  end if;

  if v_user.role_id not in ('platform_owner', 'super_admin', 'production', 'produksi') then
    raise exception 'Role tidak diizinkan mengubah progress produksi.';
  end if;

  select p.progress_id, p.tenant_id
    into v_progress
  from public.production_progress p
  where p.progress_id = p_progress_id;

  if not found then
    raise exception 'Progress produksi tidak ditemukan.';
  end if;

  if v_user.role_id <> 'platform_owner' and v_progress.tenant_id <> v_user.tenant_id then
    raise exception 'Tenant tidak sesuai.';
  end if;

  v_stage_label := nullif(trim(coalesce(p_stage_label, '')), '');
  if v_stage_label is null then
    v_stage_label := initcap(replace(v_stage_key, '_', ' '));
  end if;

  update public.production_progress_stages s
     set stage_label = v_stage_label,
         is_active = true,
         deleted_at = null,
         deleted_by = null,
         updated_at = now()
   where s.progress_id = p_progress_id
     and s.stage_key = v_stage_key
   returning s.stage_key into v_updated_key;

  if found then
    perform public.production_recalculate_progress_totals(p_progress_id);
    return jsonb_build_object(
      'ok', true,
      'action', 'updated',
      'progress_id', p_progress_id,
      'stage_key', v_stage_key,
      'stage_label', v_stage_label
    );
  end if;

  select coalesce(max(s.sort_order), 0) + 1
    into v_sort_order
  from public.production_progress_stages s
  where s.progress_id = p_progress_id;

  insert into public.production_progress_stages (
    progress_id,
    tenant_id,
    stage_key,
    stage_label,
    status,
    process_date,
    is_active,
    sort_order,
    created_at,
    updated_at
  ) values (
    p_progress_id,
    v_progress.tenant_id,
    v_stage_key,
    v_stage_label,
    'pending',
    now()::date,
    true,
    v_sort_order,
    now(),
    now()
  );

  perform public.production_recalculate_progress_totals(p_progress_id);

  return jsonb_build_object(
    'ok', true,
    'action', 'inserted',
    'progress_id', p_progress_id,
    'stage_key', v_stage_key,
    'stage_label', v_stage_label
  );
end;
$function$;

grant execute on function public.set_production_stage_active_for_app(uuid, text, text) to authenticated;
revoke all on function public.set_production_stage_active_for_app(uuid, text, text) from anon;
