-- Phase 3D-1E-B hotfix 2:
-- Ensure audit_logs has columns used by guarded/security RPC audit inserts.

begin;

alter table if exists public.audit_logs
  add column if not exists table_name text,
  add column if not exists record_id text,
  add column if not exists before_data jsonb,
  add column if not exists after_data jsonb;

comment on column public.audit_logs.table_name is
  'Optional source table name for RPC/audit events.';
comment on column public.audit_logs.record_id is
  'Optional affected record id for RPC/audit events.';
comment on column public.audit_logs.before_data is
  'Optional JSON snapshot before change.';
comment on column public.audit_logs.after_data is
  'Optional JSON snapshot after change.';

notify pgrst, 'reload schema';

commit;
