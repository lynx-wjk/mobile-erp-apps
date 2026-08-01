-- Insert Platform Owner role
insert into public.roles (role_id, role_name)
values ('platform_owner', 'Platform Owner')
on conflict (role_id) do update set role_name = excluded.role_name;

-- Re-define RLS access helpers to bypass for platform_owner

CREATE OR REPLACE FUNCTION public.app_has_tenant_access(p_tenant_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
    from public.users u
    where u.user_id = auth.uid()
      and coalesce(u.status, 'active') = 'active'
      and (
        u.role_id = 'platform_owner'
        or u.tenant_id = p_tenant_id
      )
  );
$function$;

CREATE OR REPLACE FUNCTION public.app_has_tenant_write_access(p_tenant_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
    from public.users u
    where u.user_id = auth.uid()
      and coalesce(u.status, 'active') = 'active'
      and (
        u.role_id = 'platform_owner'
        or (u.tenant_id = p_tenant_id and lower(coalesce(u.role_id, '')) not in ('demo_super_admin', 'demo'))
      )
  );
$function$;

CREATE OR REPLACE FUNCTION public.app_has_tenant_super_admin_access(p_tenant_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
    from public.users u
    where u.user_id = auth.uid()
      and coalesce(u.status, 'active') = 'active'
      and (
        u.role_id = 'platform_owner'
        or (u.tenant_id = p_tenant_id and lower(coalesce(u.role_id, '')) = 'super_admin')
      )
  );
$function$;

CREATE OR REPLACE FUNCTION public.production_has_tenant_access(p_tenant_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
    from public.users u
    where u.user_id = auth.uid()
      and coalesce(u.status, 'active') = 'active'
      and (
        u.role_id = 'platform_owner'
        or u.tenant_id = p_tenant_id
      )
  );
$function$;

CREATE OR REPLACE FUNCTION public.marketplace_assert_tenant_access(p_tenant_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not exists (
    select 1 from public.users u
    where u.user_id = auth.uid()
      and u.status = 'active'
      and (u.role_id = 'platform_owner' or u.tenant_id = p_tenant_id)
  ) then
    raise exception 'Forbidden tenant access';
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.marketplace_can_read()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
    from public.users u
    where u.user_id = auth.uid()
      and u.status = 'active'
      and (
        u.role_id in ('platform_owner', 'super_admin', 'demo_super_admin', 'superadmin', 'admin', 'owner', 'finance', 'warehouse')
        or coalesce(u.is_demo_account, false) = true
      )
  );
$function$;

CREATE OR REPLACE FUNCTION public.marketplace_can_write()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
    from public.users u
    where u.user_id = auth.uid()
      and u.status = 'active'
      and (
        u.role_id = 'platform_owner'
        or (
          u.role_id in ('super_admin', 'superadmin', 'admin', 'owner')
          and u.role_id <> 'demo_super_admin'
          and coalesce(u.is_demo_account, false) = false
        )
      )
  );
$function$;

-- Create tenant_invites table
create table if not exists public.tenant_invites (
  invite_id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.app_tenants(tenant_id) on delete cascade,
  role_id text not null references public.roles(role_id),
  email text,
  token_hash text not null unique,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'revoked', 'expired')),
  max_uses int not null default 1,
  used_count int not null default 0,
  created_at timestamptz not null default now(),
  expired_at timestamptz not null,
  created_by uuid references public.users(user_id) on delete set null,
  revoked_by uuid references public.users(user_id) on delete set null,
  revoked_at timestamptz,
  accepted_by uuid references public.users(user_id) on delete set null,
  accepted_at timestamptz,
  updated_at timestamptz not null default now()
);

-- RLS policies for tenant_invites
alter table public.tenant_invites enable row level security;

drop policy if exists tenant_invites_platform_owner_all on public.tenant_invites;
create policy tenant_invites_platform_owner_all on public.tenant_invites
  for all to authenticated
  using (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.role_id = 'platform_owner'
        and u.status = 'active'
    )
  )
  with check (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.role_id = 'platform_owner'
        and u.status = 'active'
    )
  );

drop policy if exists tenant_invites_super_admin_select on public.tenant_invites;
create policy tenant_invites_super_admin_select on public.tenant_invites
  for select to authenticated
  using (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.tenant_id = tenant_invites.tenant_id
        and u.role_id = 'super_admin'
        and u.status = 'active'
    )
  );

-- RLS policies for app_tenants
drop policy if exists app_tenants_platform_owner_all on public.app_tenants;
create policy app_tenants_platform_owner_all on public.app_tenants
  for all to authenticated
  using (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.role_id = 'platform_owner'
        and u.status = 'active'
    )
  )
  with check (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.role_id = 'platform_owner'
        and u.status = 'active'
    )
  );

drop policy if exists app_tenants_tenant_select on public.app_tenants;
create policy app_tenants_tenant_select on public.app_tenants
  for select to authenticated
  using (
    exists (
      select 1 from public.users u
      where u.user_id = auth.uid()
        and u.tenant_id = app_tenants.tenant_id
        and u.status = 'active'
    )
  );

-- RPC for creating invites
CREATE OR REPLACE FUNCTION public.create_invite(
  p_tenant_id uuid,
  p_role_id text,
  p_email text,
  p_expires_in_days int
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pgcrypto'
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
    -- Platform Owner has full access
  elsif v_user.role_id = 'super_admin' then
    -- Super Admin can only invite to their own tenant
    if p_tenant_id <> v_user.tenant_id then
      raise exception 'Forbidden. Hanya bisa membuat undangan untuk tenant Anda sendiri.';
    end if;
    -- Super Admin cannot invite platform_owner or super_admin
    if p_role_id in ('platform_owner', 'super_admin', 'superadmin') then
      raise exception 'Forbidden. Tidak memiliki izin untuk mengundang peran ini.';
    end if;
  else
    raise exception 'Akses ditolak. Anda tidak memiliki izin membuat undangan.';
  end if;

  -- Generate token
  v_raw_token := uuid_generate_v4()::text;
  v_token_hash := encode(digest(v_raw_token, 'sha256'), 'hex');
  v_expired_at := now() + (coalesce(p_expires_in_days, 7) || ' days')::interval;

  -- Insert invite
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
    lower(nullif(trim(p_email), '')),
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

-- RPC for checking invites
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
SET search_path TO 'public', 'pgcrypto'
AS $$
declare
  v_hash text;
  v_invite record;
  v_tenant_name text;
begin
  v_hash := encode(digest(p_token, 'sha256'), 'hex');

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

-- RPC for accepting invites
CREATE OR REPLACE FUNCTION public.accept_invite(
  p_token text,
  p_nama text,
  p_username text,
  p_nomor_hp text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pgcrypto'
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

  -- Verify token
  v_hash := encode(digest(p_token, 'sha256'), 'hex');
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
    nullif(trim(p_nama), ''),
    lower(coalesce(v_auth_email, v_invite.email, '')),
    nullif(trim(p_username), ''),
    nullif(trim(p_nomor_hp), ''),
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

-- RPC for revoking invites
CREATE OR REPLACE FUNCTION public.revoke_invite(p_invite_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
declare
  v_user public.users%rowtype;
  v_invite record;
begin
  select * into v_user
  from public.users
  where user_id = auth.uid()
    and coalesce(status, 'active') = 'active'
  limit 1;

  if v_user.user_id is null then
    raise exception 'User profile tidak ditemukan.';
  end if;

  select * into v_invite
  from public.tenant_invites
  where invite_id = p_invite_id;

  if v_invite.invite_id is null then
    raise exception 'Undangan tidak ditemukan.';
  end if;

  if v_user.role_id = 'platform_owner' then
    -- allowed
  elsif v_user.role_id = 'super_admin' then
    if v_invite.tenant_id <> v_user.tenant_id then
      raise exception 'Forbidden. Hanya bisa membatalkan undangan untuk tenant Anda sendiri.';
    end if;
  else
    raise exception 'Akses ditolak. Anda tidak memiliki izin membatalkan undangan.';
  end if;

  update public.tenant_invites
  set status = 'revoked',
      revoked_by = v_user.user_id,
      revoked_at = now(),
      updated_at = now()
  where invite_id = p_invite_id;

  return jsonb_build_object('ok', true, 'invite_id', p_invite_id);
end;
$$;

-- RPC for readiness summary
CREATE OR REPLACE FUNCTION public.platform_tenant_readiness_summary()
RETURNS TABLE (
  tenant_id uuid,
  tenant_name text,
  tenant_status text,
  marketplace text,
  marketplace_account_id uuid,
  store_alias text,
  account_status text,
  product_snapshot_count bigint,
  variant_snapshot_count bigint,
  order_count bigint,
  finance_count bigint,
  sku_mapped_count bigint,
  hpp_mapped_count bigint,
  unmapped_order_item_count bigint,
  readiness_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
begin
  -- Only platform_owner can access this
  if not exists (
    select 1 from public.users u
    where u.user_id = auth.uid()
      and u.role_id = 'platform_owner'
      and u.status = 'active'
  ) then
    raise exception 'Forbidden';
  end if;

  return query
  select
    t.tenant_id,
    t.tenant_name,
    t.status as tenant_status,
    ma.marketplace,
    ma.marketplace_account_id,
    coalesce(ma.store_alias, ma.shop_name, '-'),
    ma.status as account_status,
    (
      select count(*)
      from public.marketplace_product_snapshots p
      where p.tenant_id = t.tenant_id
        and p.marketplace_account_id = ma.marketplace_account_id
    ) as product_snapshot_count,
    (
      select count(*)
      from public.marketplace_variant_snapshots v
      where v.tenant_id = t.tenant_id
        and v.marketplace_account_id = ma.marketplace_account_id
    ) as variant_snapshot_count,
    (
      select count(*)
      from public.marketplace_orders o
      where o.tenant_id = t.tenant_id
        and o.marketplace_account_id = ma.marketplace_account_id
    ) as order_count,
    (
      select count(*)
      from public.marketplace_finance_reports f
      where f.tenant_id = t.tenant_id
        and f.marketplace_account_id = ma.marketplace_account_id
    ) as finance_count,
    (
      select count(*)
      from public.marketplace_sku_maps m
      where m.tenant_id = t.tenant_id
        and m.marketplace_account_id = ma.marketplace_account_id
    ) as sku_mapped_count,
    (
      select count(*)
      from public.marketplace_variant_hpp_mappings h
      where h.tenant_id = t.tenant_id
        and h.marketplace_account_id = ma.marketplace_account_id
    ) as hpp_mapped_count,
    (
      select count(*)
      from public.marketplace_order_items oi
      join public.marketplace_orders o on o.marketplace_order_id = oi.marketplace_order_id
      where o.tenant_id = t.tenant_id
        and o.marketplace_account_id = ma.marketplace_account_id
        and not exists (
          select 1
          from public.marketplace_sku_maps m
          where m.tenant_id = t.tenant_id
            and m.marketplace_account_id = ma.marketplace_account_id
            and (m.marketplace_variant_snapshot_id = oi.marketplace_variant_snapshot_id or m.remote_sku_id = oi.marketplace_sku_id)
        )
    ) as unmapped_order_item_count,
    (
      case
        when ma.marketplace_account_id is null then 'no_account'
        when ma.access_token_expired_at <= now() then 'token_expired'
        when (
          select count(*)
          from public.marketplace_variant_snapshots v
          where v.tenant_id = t.tenant_id
            and v.marketplace_account_id = ma.marketplace_account_id
        ) = 0 then 'no_variants'
        when (
          select count(*)
          from public.marketplace_variant_snapshots v
          where v.tenant_id = t.tenant_id
            and v.marketplace_account_id = ma.marketplace_account_id
            and not exists (
              select 1
              from public.marketplace_sku_maps m
              where m.tenant_id = t.tenant_id
                and m.marketplace_account_id = ma.marketplace_account_id
                and m.marketplace_variant_snapshot_id = v.marketplace_variant_snapshot_id
            )
        ) > 0 then 'unmapped_skus'
        else 'ready'
      end
    ) as readiness_status
  from public.app_tenants t
  left join public.marketplace_accounts ma on ma.tenant_id = t.tenant_id and coalesce(ma.is_deleted, false) = false
  order by t.tenant_name, ma.marketplace;
end;
$$;
