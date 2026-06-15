-- ============================================================================
-- Migration: 20260614170800_invite_register_stage_ui_fix.sql
-- Fix A: create_invite / check_invite / accept_invite use md5() not digest()
-- Fix B: add set_production_stage_active_for_app canonical RPC
--        (activates/inserts a stage row without requiring tailor — for edit-flow
--         brand-new stages added in the checklist but not yet worked on)
-- No versioned function names.
-- ============================================================================


-- ============================================================================
-- A1. REDEPLOY: public.create_invite
--     Use md5() for token_hash. No pgcrypto digest() required.
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
SET search_path = public
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
  if lower(coalesce(v_user.role_id, '')) = 'platform_owner' then
    -- Platform Owner has full access to all tenants and roles
    null;
  elsif lower(coalesce(v_user.role_id, '')) = 'super_admin' then
    -- Super Admin can only invite to their own tenant
    if p_tenant_id <> v_user.tenant_id then
      raise exception 'Forbidden. Hanya bisa membuat undangan untuk tenant Anda sendiri.';
    end if;
    -- Super Admin cannot invite platform_owner or super_admin
    if lower(coalesce(p_role_id, '')) in ('platform_owner', 'super_admin') then
      raise exception 'Forbidden. Tidak memiliki izin untuk mengundang peran ini.';
    end if;
  else
    raise exception 'Akses ditolak. Anda tidak memiliki izin membuat undangan.';
  end if;

  -- Generate token using gen_random_uuid() — no extension required
  v_raw_token := gen_random_uuid()::text
              || '-'
              || gen_random_uuid()::text;

  -- Hash using md5() — built-in, no pgcrypto needed
  v_token_hash := md5(v_raw_token);

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
-- A2. REDEPLOY: public.check_invite
--     Use md5(p_token) for hash lookup. No pgcrypto digest() required.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.check_invite(p_token text)
RETURNS TABLE (
  invite_id uuid,
  tenant_id uuid,
  tenant_name text,
  role_id text,
  email text,
  status text,
  is_valid boolean,
  message text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_hash text;
  v_invite record;
  v_tenant_name text;
begin
  if p_token is null or trim(p_token) = '' then
    return query select
      null::uuid, null::uuid, null::text, null::text, null::text, null::text,
      false, 'Token undangan tidak boleh kosong.'::text;
    return;
  end if;

  -- md5 hash — must match how create_invite stores it
  v_hash := md5(trim(p_token));

  select i.* into v_invite
  from public.tenant_invites i
  where i.token_hash = v_hash;

  if v_invite.invite_id is null then
    return query select
      null::uuid, null::uuid, null::text, null::text, null::text, null::text,
      false, 'Token undangan tidak valid atau tidak ditemukan.'::text;
    return;
  end if;

  select t.tenant_name into v_tenant_name
  from public.app_tenants t
  where t.tenant_id = v_invite.tenant_id;

  if v_invite.status = 'revoked' then
    return query select
      v_invite.invite_id, v_invite.tenant_id, v_tenant_name, v_invite.role_id, v_invite.email, v_invite.status,
      false, 'Undangan telah dibatalkan.'::text;
  elsif v_invite.status = 'expired' or v_invite.expired_at <= now() then
    return query select
      v_invite.invite_id, v_invite.tenant_id, v_tenant_name, v_invite.role_id, v_invite.email, v_invite.status,
      false, 'Undangan telah kedaluwarsa.'::text;
  elsif v_invite.status = 'accepted' or v_invite.used_count >= v_invite.max_uses then
    return query select
      v_invite.invite_id, v_invite.tenant_id, v_tenant_name, v_invite.role_id, v_invite.email, v_invite.status,
      false, 'Undangan telah digunakan.'::text;
  else
    return query select
      v_invite.invite_id, v_invite.tenant_id, v_tenant_name, v_invite.role_id, v_invite.email, v_invite.status,
      true, 'Undangan valid.'::text;
  end if;
end;
$$;

GRANT EXECUTE ON FUNCTION public.check_invite(text) TO authenticated, anon, service_role;


-- ============================================================================
-- A3. REDEPLOY: public.accept_invite
--     Use md5(p_token) for hash lookup. No pgcrypto digest() required.
--     Uses auth.uid() — no client p_user_id.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.accept_invite(
  p_token text,
  p_nama text,
  p_username text,
  p_nomor_hp text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
declare
  v_uid uuid;
  v_hash text;
  v_invite record;
  v_auth_email text;
begin
  -- Retrieve auth.uid()
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'Unauthorized. Sesi auth Supabase wajib aktif.';
  end if;

  -- Verify token using md5 hash
  v_hash := md5(trim(coalesce(p_token, '')));
  select * into v_invite
  from public.tenant_invites
  where token_hash = v_hash
  for update;

  if v_invite.invite_id is null then
    raise exception 'Undangan tidak ditemukan.';
  end if;

  if v_invite.status = 'revoked' then
    raise exception 'Undangan telah dibatalkan.';
  end if;

  if v_invite.expired_at <= now() then
    raise exception 'Undangan telah kedaluwarsa.';
  end if;

  if v_invite.status = 'accepted' or v_invite.used_count >= v_invite.max_uses then
    raise exception 'Undangan telah habis digunakan.';
  end if;

  -- Check if user already has an active profile in any tenant
  if exists (
    select 1
    from public.users
    where user_id = v_uid
      and status = 'active'
  ) then
    raise exception 'Akses ditolak. Pengguna ini sudah terhubung ke tenant aktif.';
  end if;

  -- Retrieve email from auth.users
  select email into v_auth_email
  from auth.users
  where id = v_uid;

  -- Validate email if invite.email is set
  if v_invite.email is not null and v_invite.email <> '' then
    if lower(coalesce(v_auth_email, '')) <> lower(v_invite.email) then
      raise exception 'Undangan ditujukan untuk email %, tetapi email Anda %.', v_invite.email, v_auth_email;
    end if;
  end if;

  -- Insert or update user profile
  insert into public.users (
    user_id,
    nama,
    email,
    username,
    nomor_hp,
    role_id,
    status,
    tenant_id,
    created_at,
    updated_at
  ) values (
    v_uid,
    nullif(trim(coalesce(p_nama, '')), ''),
    lower(coalesce(v_auth_email, v_invite.email, '')),
    nullif(trim(coalesce(p_username, '')), ''),
    nullif(trim(coalesce(p_nomor_hp, '')), ''),
    v_invite.role_id,
    'active',
    v_invite.tenant_id,
    now(),
    now()
  )
  on conflict (user_id) do update set
    nama = excluded.nama,
    email = excluded.email,
    username = excluded.username,
    nomor_hp = excluded.nomor_hp,
    role_id = excluded.role_id,
    status = 'active',
    tenant_id = excluded.tenant_id,
    updated_at = now();

  -- Update invite count and status
  update public.tenant_invites
  set used_count = used_count + 1,
      status = case when used_count + 1 >= max_uses then 'accepted'::text else status end,
      accepted_by = v_uid,
      accepted_at = now(),
      updated_at = now()
  where invite_id = v_invite.invite_id;

  return jsonb_build_object(
    'ok', true,
    'user_id', v_uid,
    'tenant_id', v_invite.tenant_id,
    'role_id', v_invite.role_id
  );
end;
$$;

GRANT EXECUTE ON FUNCTION public.accept_invite(text, text, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.accept_invite(text, text, text, text) FROM anon;


-- ============================================================================
-- B. NEW CANONICAL: set_production_stage_active_for_app
--    Activates (inserts or restores) a checklist stage WITHOUT requiring a
--    tailor. Used by the edit-progress dialog for newly-added custom stages
--    that haven't been worked on yet (status = pending).
--    Deactivating (is_active = false) uses existing delete_production_progress_stage_for_app.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.set_production_stage_active_for_app(
  p_progress_id uuid,
  p_stage_key text,
  p_stage_label text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
declare
  v_user public.users%rowtype;
  v_progress public.production_progress%rowtype;
  v_role text;
  v_stage_key text := lower(btrim(coalesce(p_stage_key, '')));
  v_stage_label text;
  v_sort integer;
begin
  select * into v_user
  from public.users
  where user_id = auth.uid()
    and coalesce(status, 'active') = 'active'
  limit 1;

  if v_user.user_id is null then
    raise exception 'User profile tidak ditemukan.';
  end if;

  v_role := lower(coalesce(v_user.role_id, ''));

  if v_role in ('demo_super_admin', 'demo') then
    raise exception 'Demo read-only.';
  end if;

  if v_role not in ('super_admin', 'production', 'produksi', 'platform_owner') then
    raise exception 'Akses ditolak.';
  end if;

  if v_stage_key = '' then
    raise exception 'stage_key tidak boleh kosong.';
  end if;

  select * into v_progress
  from public.production_progress
  where progress_id = p_progress_id
    and (v_role = 'platform_owner' or tenant_id = v_user.tenant_id)
  for update;

  if v_progress.progress_id is null then
    raise exception 'Progress produksi tidak ditemukan.';
  end if;

  -- Determine label
  v_stage_label := coalesce(
    nullif(trim(coalesce(p_stage_label, '')), ''),
    case v_stage_key
      when 'potong_kain' then 'Potong Kain'
      when 'jahit' then 'Jahit'
      when 'lubang_kancing' then 'Lubang Kancing'
      when 'finishing' then 'Finishing'
      when 'packing' then 'Packing'
      else initcap(replace(v_stage_key, '_', ' '))
    end
  );

  v_sort := public.production_stage_sort_order(v_stage_key);

  -- Upsert: insert new or restore soft-deleted stage
  insert into public.production_progress_stages (
    progress_id, tenant_id, stage_key, stage_label, status,
    sort_order, is_active, deleted_at, deleted_by
  ) values (
    p_progress_id,
    coalesce(v_progress.tenant_id, v_user.tenant_id),
    v_stage_key,
    v_stage_label,
    'pending',
    v_sort,
    true,
    null,
    null
  )
  on conflict (progress_id, stage_key) do update set
    is_active = true,
    stage_label = coalesce(excluded.stage_label, public.production_progress_stages.stage_label),
    deleted_at = null,
    deleted_by = null,
    updated_at = now();

  return jsonb_build_object(
    'ok', true,
    'stage_key', v_stage_key,
    'stage_label', v_stage_label
  );
end;
$$;

GRANT EXECUTE ON FUNCTION public.set_production_stage_active_for_app(uuid, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.set_production_stage_active_for_app(uuid, text, text) FROM anon;
