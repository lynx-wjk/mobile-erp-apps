-- Tighten Produksi Berjalan tenant isolation and audit all production writes.

alter table public.production_progress enable row level security;
alter table public.production_progress_files enable row level security;
alter table public.production_progress_items enable row level security;
alter table public.production_progress_stages enable row level security;
alter table public.production_tailor_payments enable row level security;
alter table public.production_tailors enable row level security;

drop policy if exists authenticated_all on public.production_progress;
drop policy if exists production_progress_admin_all on public.production_progress;
drop policy if exists production_progress_tenant_access on public.production_progress;

create policy production_progress_tenant_access
  on public.production_progress
  for all
  to authenticated
  using (public.production_has_tenant_access(tenant_id))
  with check (public.production_has_tenant_access(tenant_id));

create or replace function public.audit_production_progress_change_v1()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
$$;

drop trigger if exists trg_audit_production_progress on public.production_progress;
drop trigger if exists trg_audit_production_progress_v1 on public.production_progress;
create trigger trg_audit_production_progress_v1
after insert or update or delete on public.production_progress
for each row execute function public.audit_production_progress_change_v1();

drop trigger if exists trg_audit_production_progress_items_v1 on public.production_progress_items;
create trigger trg_audit_production_progress_items_v1
after insert or update or delete on public.production_progress_items
for each row execute function public.audit_production_progress_change_v1();

drop trigger if exists trg_audit_production_progress_stages_v1 on public.production_progress_stages;
create trigger trg_audit_production_progress_stages_v1
after insert or update or delete on public.production_progress_stages
for each row execute function public.audit_production_progress_change_v1();

drop trigger if exists trg_audit_production_progress_files_v1 on public.production_progress_files;
create trigger trg_audit_production_progress_files_v1
after insert or update or delete on public.production_progress_files
for each row execute function public.audit_production_progress_change_v1();

drop trigger if exists trg_audit_production_tailor_payments_v1 on public.production_tailor_payments;
create trigger trg_audit_production_tailor_payments_v1
after insert or update or delete on public.production_tailor_payments
for each row execute function public.audit_production_progress_change_v1();

drop trigger if exists trg_audit_production_tailors_v1 on public.production_tailors;
create trigger trg_audit_production_tailors_v1
after insert or update or delete on public.production_tailors
for each row execute function public.audit_production_progress_change_v1();

comment on function public.audit_production_progress_change_v1() is
'Audits Produksi Berjalan progress, items, stages, files, workers, and payment changes with tenant_id.';
