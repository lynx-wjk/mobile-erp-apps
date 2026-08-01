-- Canonical runtime cron auth for self-host marketplace automation.
-- No version suffixes. No secrets are stored in this migration.
-- This migration is safe to re-run against the current self-host DB state.

create schema if not exists app_private;

create table if not exists app_private.runtime_secrets (
  secret_key text primary key,
  secret_value text not null,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

revoke all on schema app_private from public;
revoke all on all tables in schema app_private from public;
revoke all on all functions in schema app_private from public;

create or replace function app_private.get_runtime_secret(p_key text)
returns text
language plpgsql
security definer
set search_path = app_private, public, pg_temp
as $$
declare
  v_secret text;
begin
  select secret_value
    into v_secret
  from app_private.runtime_secrets
  where secret_key = trim(coalesce(p_key, ''));

  return v_secret;
end;
$$;

create or replace function app_private.set_runtime_secret(
  p_key text,
  p_secret text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, pg_temp
as $$
declare
  v_key text := trim(coalesce(p_key, ''));
  v_secret text := trim(coalesce(p_secret, ''));
begin
  if v_key = '' then
    raise exception 'runtime secret key kosong';
  end if;

  if v_secret = '' then
    raise exception 'runtime secret value kosong';
  end if;

  insert into app_private.runtime_secrets(secret_key, secret_value, note)
  values (v_key, v_secret, p_note)
  on conflict (secret_key) do update
    set secret_value = excluded.secret_value,
        note = excluded.note,
        updated_at = now();

  return jsonb_build_object(
    'ok', true,
    'secret_key', v_key,
    'has_secret', true,
    'secret_length', length(v_secret),
    'updated_at', now()
  );
end;
$$;

create or replace function public.verify_marketplace_cron_secret(p_secret text)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, pg_temp
as $$
declare
  v_expected text;
  v_incoming text := trim(coalesce(p_secret, ''));
begin
  if v_incoming = '' then
    return false;
  end if;

  v_expected := app_private.get_runtime_secret('marketplace_cron_secret');

  if trim(coalesce(v_expected, '')) = '' then
    return false;
  end if;

  return v_incoming = v_expected;
end;
$$;

revoke all on function app_private.get_runtime_secret(text) from public, anon, authenticated;
revoke all on function app_private.set_runtime_secret(text,text,text) from public, anon, authenticated;
revoke all on function public.verify_marketplace_cron_secret(text) from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.verify_marketplace_cron_secret(text) to service_role;
  end if;
end $$;

comment on table app_private.runtime_secrets is
'Private runtime secrets for self-host automation. Do not expose to anon/authenticated clients.';

comment on function app_private.get_runtime_secret(text) is
'Canonical private runtime secret getter for DB-side automation. No version suffix.';

comment on function app_private.set_runtime_secret(text,text,text) is
'Canonical private runtime secret setter. No version suffix.';

comment on function public.verify_marketplace_cron_secret(text) is
'Canonical Edge Function cron secret verifier. No version suffix.';

notify pgrst, 'reload schema';
