-- ============================================================================
-- Migration: 20260614170700_platform_owner_invite_tenant_fix.sql
-- Fix create_invite: replace uuid_generate_v4() with gen_random_uuid()
-- Add canonical platform_create_tenant_for_app RPC
-- No versioned function names.
-- ============================================================================

-- ============================================================================
-- 1. REDEPLOY: create_invite
--    Replace uuid_generate_v4() with gen_random_uuid() (always available in PG14+)
--    Keep exact same signature and security rules.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.create_invite(
  p_tenant_id uuid,
  p_role_id text,
  p_email text,
  p_expires_in_days integer
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pgcrypto'
AS $$
declare
  v_user public.users%rowtype;
  v_raw_token text;
  v_token_hash text;
  v_expired_at timestamptz;
begin
  -- Resolve caller
  select * into v_user
  from public.users
  where user_id = auth.uid()
    and coalesce(status, 'active') = 'active'
  limit 1;

  if v_user.user_id is null then
    raise exception 'User profile tidak ditemukan.';
  end if;

  -- Validate permissions
  if v_user.role_id = 'platform_owner' then
    -- Platform Owner has full access to all tenants and roles
    null;
  elsif v_user.role_id = 'super_admin' then
    -- Super Admin can only invite to their own tenant
    if p_tenant_id <> v_user.tenant_id then
      raise exception 'Forbidden. Hanya bisa membuat undangan untuk tenant Anda sendiri.';
    end if;
    -- Super Admin cannot invite platform_owner or super_admin
    if lower(coalesce(p_role_id, '')) in ('platform_owner', 'super_admin', 'superadmin') then
      raise exception 'Forbidden. Tidak memiliki izin untuk mengundang peran ini.';
    end if;
  else
    raise exception 'Akses ditolak. Anda tidak memiliki izin membuat undangan.';
  end if;

  -- Generate token using gen_random_uuid() — no uuid-ossp extension required
  v_raw_token := gen_random_uuid()::text;
  v_token_hash := encode(digest(v_raw_token, 'sha256'), 'hex');
  v_expired_at := now() + (coalesce(p_expires_in_days, 7) || ' days')::interval;

  -- Insert invite record
  insert into public.tenant_invites (
    tenant_id,
    role_id,
    email,
    token_hash,
    status,
    max_uses,
    used_count,
    expired_at,
    created_by
  ) values (
    p_tenant_id,
    p_role_id,
    lower(nullif(trim(coalesce(p_email, '')), '')),
    v_token_hash,
    'pending',
    1,
    0,
    v_expired_at,
    v_user.user_id
  );

  return v_raw_token;
end;
$$;

GRANT EXECUTE ON FUNCTION public.create_invite(uuid, text, text, integer) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.create_invite(uuid, text, text, integer) FROM anon;


-- ============================================================================
-- 2. NEW CANONICAL: platform_create_tenant_for_app
--    Only platform_owner can call. Generates tenant_code from tenant_name.
--    No version suffix.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.platform_create_tenant_for_app(
  p_tenant_name text,
  p_owner_name text DEFAULT NULL,
  p_owner_email text DEFAULT NULL,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_user public.users%rowtype;
  v_tenant_code text;
  v_base_code text;
  v_suffix text;
  v_tenant_id uuid;
  v_attempt integer := 0;
begin
  -- Resolve caller
  select * into v_user
  from public.users
  where user_id = auth.uid()
    and coalesce(status, 'active') = 'active'
  limit 1;

  if v_user.user_id is null then
    raise exception 'User profile tidak ditemukan.';
  end if;

  if lower(coalesce(v_user.role_id, '')) <> 'platform_owner' then
    raise exception 'Akses ditolak. Hanya Platform Owner yang bisa membuat tenant baru.';
  end if;

  -- Validate tenant name
  if trim(coalesce(p_tenant_name, '')) = '' then
    raise exception 'Nama tenant tidak boleh kosong.';
  end if;

  -- Generate base tenant_code:
  -- lowercase, trim, replace non-alphanumeric chars with underscore,
  -- collapse multiple underscores, trim leading/trailing underscores
  v_base_code := lower(trim(p_tenant_name));
  v_base_code := regexp_replace(v_base_code, '[^a-z0-9]+', '_', 'g');
  v_base_code := regexp_replace(v_base_code, '_+', '_', 'g');
  v_base_code := trim(both '_' from v_base_code);

  -- Ensure base code is not empty after normalization
  if v_base_code = '' then
    v_base_code := 'tenant';
  end if;

  -- Truncate base code to 40 chars to allow space for suffix
  if length(v_base_code) > 40 then
    v_base_code := left(v_base_code, 40);
    v_base_code := trim(both '_' from v_base_code);
  end if;

  -- Generate unique tenant_code by appending a short random suffix
  -- Try up to 10 times to find a unique code
  loop
    v_attempt := v_attempt + 1;
    if v_attempt > 10 then
      raise exception 'Gagal menghasilkan kode tenant unik. Coba lagi.';
    end if;

    -- Generate 4-char alphanumeric suffix
    v_suffix := lower(substring(gen_random_uuid()::text, 1, 8));
    v_suffix := regexp_replace(v_suffix, '[^a-z0-9]', '', 'g');
    v_suffix := left(v_suffix, 4);

    v_tenant_code := v_base_code || '_' || v_suffix;

    -- Check uniqueness
    if not exists (
      select 1 from public.app_tenants where tenant_code = v_tenant_code
    ) then
      exit; -- unique, break loop
    end if;
  end loop;

  -- Insert new tenant
  insert into public.app_tenants (
    tenant_code,
    tenant_name,
    owner_name,
    owner_email,
    status,
    notes
  ) values (
    v_tenant_code,
    trim(p_tenant_name),
    nullif(trim(coalesce(p_owner_name, '')), ''),
    lower(nullif(trim(coalesce(p_owner_email, '')), '')),
    'active',
    nullif(trim(coalesce(p_notes, '')), '')
  )
  returning tenant_id into v_tenant_id;

  return jsonb_build_object(
    'ok', true,
    'tenant_id', v_tenant_id,
    'tenant_code', v_tenant_code,
    'tenant_name', trim(p_tenant_name)
  );
end;
$$;

GRANT EXECUTE ON FUNCTION public.platform_create_tenant_for_app(text, text, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.platform_create_tenant_for_app(text, text, text, text) FROM anon;
