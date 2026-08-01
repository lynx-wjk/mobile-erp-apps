-- Phase 3D-1E-B hotfix 3:
-- audit_logs has legacy NOT NULL column "aktivitas".
-- New guarded RPC audit inserts use "activity".
-- Keep both compatible.

begin;

alter table if exists public.audit_logs
  add column if not exists activity text;

create or replace function public.audit_logs_activity_compat_fill()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- Legacy Indonesian column required by old schema.
  if new.aktivitas is null then
    new.aktivitas := coalesce(new.activity, 'Audit event');
  end if;

  -- New English alias used by newer RPCs.
  if new.activity is null then
    new.activity := new.aktivitas;
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
