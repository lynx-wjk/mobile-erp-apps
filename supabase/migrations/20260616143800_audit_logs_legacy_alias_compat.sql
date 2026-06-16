-- Phase 3D-1E-B hotfix 4:
-- Full compatibility between legacy Indonesian audit_logs columns and newer English aliases.
--
-- Legacy NOT NULL:
-- - aktivitas
-- - modul
--
-- Newer RPC aliases:
-- - activity
-- - module
-- - before_data / after_data
-- - table_name / record_id

begin;

alter table if exists public.audit_logs
  add column if not exists activity text,
  add column if not exists module text,
  add column if not exists before_data jsonb,
  add column if not exists after_data jsonb,
  add column if not exists table_name text,
  add column if not exists record_id text;

create or replace function public.audit_logs_activity_compat_fill()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- activity <-> aktivitas
  if new.aktivitas is null then
    new.aktivitas := coalesce(new.activity, 'Audit event');
  end if;

  if new.activity is null then
    new.activity := new.aktivitas;
  end if;

  -- module <-> modul
  if new.modul is null then
    new.modul := coalesce(new.module, 'system');
  end if;

  if new.module is null then
    new.module := new.modul;
  end if;

  -- before_data <-> data_sebelum
  if new.data_sebelum is null then
    new.data_sebelum := new.before_data;
  end if;

  if new.before_data is null then
    new.before_data := new.data_sebelum;
  end if;

  -- after_data <-> data_sesudah
  if new.data_sesudah is null then
    new.data_sesudah := new.after_data;
  end if;

  if new.after_data is null then
    new.after_data := new.data_sesudah;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_audit_logs_activity_compat_fill on public.audit_logs;

create trigger trg_audit_logs_activity_compat_fill
before insert or update on public.audit_logs
for each row
execute function public.audit_logs_activity_compat_fill();

notify pgrst, 'reload schema';

commit;
