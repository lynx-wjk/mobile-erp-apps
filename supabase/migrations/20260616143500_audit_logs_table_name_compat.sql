-- Phase 3D-1E-B hotfix:
-- Some guarded RPC audit inserts write audit_logs.table_name.
-- Self-host audit_logs schema did not have that column yet.

begin;

alter table if exists public.audit_logs
  add column if not exists table_name text;

comment on column public.audit_logs.table_name is
  'Optional source table name for RPC/audit events. Added for guarded dangerous RPC audit compatibility.';

notify pgrst, 'reload schema';

commit;
