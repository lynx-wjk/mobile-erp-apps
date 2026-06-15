-- 9I-H canonical production progress audit trigger function.
-- Repoints production progress audit triggers from audit_production_progress_change_v1()
-- to audit_production_progress_change().
-- Old *_v1 function is intentionally kept; no DROP FUNCTION here.

create or replace function public.audit_production_progress_change()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_before jsonb := null;
  v_after jsonb := null;
  v_tenant_id uuid := null;
  v_user_id uuid := auth.uid();
  v_user_name text := null;
  v_user_email text := null;
  v_role_id text := null;
  v_action text := lower(TG_OP) || '_' || TG_TABLE_NAME;
begin
  if TG_OP in ('UPDATE', 'DELETE') then
    v_before := to_jsonb(OLD);
    v_tenant_id := OLD.tenant_id;
  end if;

  if TG_OP in ('INSERT', 'UPDATE') then
    v_after := to_jsonb(NEW);
    v_tenant_id := NEW.tenant_id;
  end if;

  if v_user_id is not null then
    select u.nama, u.email, u.role_id
      into v_user_name, v_user_email, v_role_id
      from public.users u
     where u.user_id = v_user_id
     limit 1;
  end if;

  begin
    insert into public.audit_logs (
      user_id,
      nama_user,
      role_id,
      aktivitas,
      modul,
      data_sebelum,
      data_sesudah,
      created_at,
      user_name,
      user_email,
      activity,
      module,
      before_data,
      after_data,
      tenant_id
    )
    values (
      v_user_id,
      coalesce(v_user_name, v_user_email, 'system'),
      v_role_id,
      v_action,
      'produksi_berjalan',
      v_before,
      v_after,
      now(),
      coalesce(v_user_name, v_user_email, 'system'),
      v_user_email,
      v_action,
      'produksi_berjalan',
      v_before,
      v_after,
      v_tenant_id
    );
  exception when others then
    null;
  end;

  if TG_OP = 'DELETE' then
    return OLD;
  end if;

  return NEW;
end;
$function$;

do $$
declare
  r record;
  v_def text;
begin
  for r in
    select *
    from (
      values
        ('production_progress', 'trg_audit_production_progress_v1', 'trg_audit_production_progress'),
        ('production_progress_items', 'trg_audit_production_progress_items_v1', 'trg_audit_production_progress_items'),
        ('production_progress_stages', 'trg_audit_production_progress_stages_v1', 'trg_audit_production_progress_stages'),
        ('production_progress_files', 'trg_audit_production_progress_files_v1', 'trg_audit_production_progress_files'),
        ('production_tailor_payments', 'trg_audit_production_tailor_payments_v1', 'trg_audit_production_tailor_payments'),
        ('production_tailors', 'trg_audit_production_tailors_v1', 'trg_audit_production_tailors')
    ) as x(table_name, old_trigger_name, new_trigger_name)
  loop
    select pg_get_triggerdef(t.oid, true)
      into v_def
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = r.table_name
      and t.tgname = r.old_trigger_name
      and not t.tgisinternal;

    if v_def is null then
      raise exception 'Trigger not found: %.%', r.table_name, r.old_trigger_name;
    end if;

    execute format('drop trigger if exists %I on public.%I', r.old_trigger_name, r.table_name);

    v_def := replace(
      v_def,
      'CREATE TRIGGER ' || r.old_trigger_name,
      'CREATE TRIGGER ' || r.new_trigger_name
    );

    v_def := replace(
      v_def,
      'EXECUTE FUNCTION audit_production_progress_change_v1()',
      'EXECUTE FUNCTION public.audit_production_progress_change()'
    );

    v_def := replace(
      v_def,
      'EXECUTE FUNCTION public.audit_production_progress_change_v1()',
      'EXECUTE FUNCTION public.audit_production_progress_change()'
    );

    execute v_def;
  end loop;
end $$;

notify pgrst, 'reload schema';
