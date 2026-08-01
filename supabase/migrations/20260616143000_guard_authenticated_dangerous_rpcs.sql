-- Phase 3D-1E-B:
-- Guard authenticated dangerous RPCs.
--
-- Goals:
-- - keep UI-used RPCs executable but tenant/role guarded
-- - revoke authenticated access from unused/emergency destructive RPCs
-- - keep service_role for backend/maintenance jobs

begin;

create or replace function public._security_rpc_require_role(
  p_allowed_roles text[],
  p_required_tenant uuid default null
)
returns table(user_id uuid, tenant_id uuid, role_id text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_tenant_id uuid;
  v_role_id text;
begin
  if auth.uid() is null then
    raise exception 'User belum login.';
  end if;

  select
    u.user_id,
    u.tenant_id,
    regexp_replace(lower(coalesce(u.role_id, '')), '[^a-z0-9]+', '_', 'g')
  into
    v_user_id,
    v_tenant_id,
    v_role_id
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1;

  if v_user_id is null then
    raise exception 'User aktif tidak ditemukan.';
  end if;

  if v_role_id in ('demo', 'demo_super_admin', 'demo_reviewer') then
    raise exception 'Demo read-only.';
  end if;

  if not (v_role_id = any(p_allowed_roles)) then
    raise exception 'Role % tidak diizinkan untuk operasi ini.', v_role_id;
  end if;

  if p_required_tenant is not null
     and v_role_id <> 'platform_owner'
     and v_tenant_id is distinct from p_required_tenant then
    raise exception 'Tenant tidak sesuai.';
  end if;

  user_id := v_user_id;
  tenant_id := v_tenant_id;
  role_id := v_role_id;
  return next;
end;
$$;

revoke execute on function public._security_rpc_require_role(text[], uuid) from public, anon;
grant execute on function public._security_rpc_require_role(text[], uuid) to authenticated, service_role;


-- 1) Replace global stock-history clear with tenant-scoped clear.
create or replace function public.clear_stock_history_for_app()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ctx record;
  v_deleted integer := 0;
begin
  select *
    into v_ctx
  from public._security_rpc_require_role(
    array['super_admin', 'superadmin', 'admin', 'owner'],
    null
  );

  if v_ctx.tenant_id is null then
    raise exception 'Tenant user tidak ditemukan.';
  end if;

  delete from public.stock_transactions st
  where st.tenant_id = v_ctx.tenant_id;

  get diagnostics v_deleted = row_count;

  insert into public.audit_logs (
    tenant_id,
    user_id,
    activity,
    module,
    table_name,
    record_id,
    before_data,
    after_data,
    created_at
  )
  values (
    v_ctx.tenant_id,
    v_ctx.user_id,
    'Clear tenant stock history',
    'stock',
    'stock_transactions',
    v_ctx.tenant_id::text,
    jsonb_build_object('tenant_id', v_ctx.tenant_id),
    jsonb_build_object('deleted_rows', v_deleted),
    now()
  );
end;
$$;


-- 2) Tenant-scope delete stock transaction and stock rollback.
create or replace function public.delete_stock_transaction_for_app(p_stock_transaction_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ctx record;
  v_tx public.stock_transactions%rowtype;
  v_product public.products%rowtype;
  v_new_stock numeric;
  v_deleted_reviews integer := 0;
  v_deleted_movements integer := 0;
  v_resi_norm text;
begin
  select *
    into v_ctx
  from public._security_rpc_require_role(
    array['super_admin', 'superadmin', 'admin', 'owner', 'platform_owner'],
    null
  );

  if p_stock_transaction_id is null then
    raise exception 'ID transaksi stok kosong.';
  end if;

  select *
    into v_tx
  from public.stock_transactions st
  where st.stock_transaction_id = p_stock_transaction_id
    and (
      v_ctx.role_id = 'platform_owner'
      or st.tenant_id = v_ctx.tenant_id
    )
  for update;

  if not found then
    raise exception 'Transaksi stok tidak ditemukan untuk tenant ini.';
  end if;

  select *
    into v_product
  from public.products p
  where p.product_id = v_tx.product_id
    and (
      v_ctx.role_id = 'platform_owner'
      or p.tenant_id = v_tx.tenant_id
    )
  for update;

  if not found then
    raise exception 'Produk untuk transaksi ini tidak ditemukan untuk tenant ini.';
  end if;

  if upper(coalesce(v_tx.transaction_type, '')) = 'OUT' then
    v_new_stock := coalesce(v_product.stock_saat_ini, 0) + coalesce(v_tx.qty, 0);
  elsif upper(coalesce(v_tx.transaction_type, '')) = 'IN' then
    if coalesce(v_product.stock_saat_ini, 0) < coalesce(v_tx.qty, 0) then
      raise exception
        'Transaksi IN tidak bisa dihapus karena stok saat ini (%) lebih kecil dari qty transaksi (%).',
        v_product.stock_saat_ini,
        v_tx.qty;
    end if;
    v_new_stock := coalesce(v_product.stock_saat_ini, 0) - coalesce(v_tx.qty, 0);
  else
    raise exception 'Tipe transaksi stok tidak valid: %', coalesce(v_tx.transaction_type, '-');
  end if;

  update public.products p
     set stock_saat_ini = v_new_stock,
         updated_at = now()
   where p.product_id = v_tx.product_id
     and (
       v_ctx.role_id = 'platform_owner'
       or p.tenant_id = v_tx.tenant_id
     );

  if to_regclass('public.marketplace_stock_out_reviews') is not null then
    delete from public.marketplace_stock_out_reviews r
    where r.stock_transaction_id = p_stock_transaction_id
      and (
        v_ctx.role_id = 'platform_owner'
        or r.tenant_id = v_tx.tenant_id
      );
    get diagnostics v_deleted_reviews = row_count;
  end if;

  if to_regclass('public.marketplace_orders') is not null then
    update public.marketplace_orders o
       set stock_transaction_id = null,
           updated_at = now()
     where o.stock_transaction_id = p_stock_transaction_id
       and (
         v_ctx.role_id = 'platform_owner'
         or o.tenant_id = v_tx.tenant_id
       );
  end if;

  if to_regclass('public.marketplace_order_stock_movements') is not null then
    delete from public.marketplace_order_stock_movements m
    where m.stock_transaction_id = p_stock_transaction_id
      and (
        v_ctx.role_id = 'platform_owner'
        or m.tenant_id = v_tx.tenant_id
      );
    get diagnostics v_deleted_movements = row_count;
  end if;

  if to_regclass('public.stock_out_resi_locks') is not null
     and nullif(trim(coalesce(v_tx.nomor_resi, '')), '') is not null then
    begin
      v_resi_norm := public.stock_out_normalize_resi(v_tx.nomor_resi);

      delete from public.stock_out_resi_locks l
      where l.normalized_resi = v_resi_norm
        and (
          v_ctx.role_id = 'platform_owner'
          or l.tenant_id = v_tx.tenant_id
        );
    exception when undefined_function then
      null;
    end;
  end if;

  delete from public.stock_transactions st
  where st.stock_transaction_id = p_stock_transaction_id
    and (
      v_ctx.role_id = 'platform_owner'
      or st.tenant_id = v_tx.tenant_id
    );

  insert into public.audit_logs (
    tenant_id,
    user_id,
    activity,
    module,
    table_name,
    record_id,
    before_data,
    after_data,
    created_at
  )
  values (
    v_tx.tenant_id,
    v_ctx.user_id,
    'Delete stock transaction',
    'stock',
    'stock_transactions',
    p_stock_transaction_id::text,
    to_jsonb(v_tx),
    jsonb_build_object(
      'stock_after_delete', v_new_stock,
      'deleted_reviews', v_deleted_reviews,
      'deleted_movements', v_deleted_movements
    ),
    now()
  );

  return jsonb_build_object(
    'ok', true,
    'stock_transaction_id', p_stock_transaction_id,
    'product_id', v_tx.product_id,
    'transaction_type', v_tx.transaction_type,
    'qty', v_tx.qty,
    'stock_after_delete', v_new_stock,
    'deleted_reviews', v_deleted_reviews,
    'deleted_movements', v_deleted_movements,
    'message', 'Transaksi stok berhasil dihapus dan stok produk sudah disesuaikan.'
  );
end;
$$;


-- 3) Tenant-scope supplier delete.
create or replace function public.delete_supplier_for_app(p_supplier_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ctx record;
  v_supplier record;
  v_deleted integer := 0;
begin
  select *
    into v_ctx
  from public._security_rpc_require_role(
    array[
      'super_admin',
      'superadmin',
      'admin',
      'owner',
      'production',
      'produksi',
      'platform_owner'
    ],
    null
  );

  if p_supplier_id is null then
    raise exception 'Supplier ID kosong.';
  end if;

  select *
    into v_supplier
  from public.suppliers s
  where s.supplier_id = p_supplier_id
    and (
      v_ctx.role_id = 'platform_owner'
      or s.tenant_id = v_ctx.tenant_id
    )
  limit 1;

  if v_supplier.supplier_id is null then
    return jsonb_build_object(
      'ok', false,
      'deleted', 0,
      'message', 'Supplier tidak ditemukan untuk tenant ini.'
    );
  end if;

  delete from public.suppliers s
  where s.supplier_id = p_supplier_id
    and (
      v_ctx.role_id = 'platform_owner'
      or s.tenant_id = v_ctx.tenant_id
    );

  get diagnostics v_deleted = row_count;

  insert into public.audit_logs (
    tenant_id,
    user_id,
    activity,
    module,
    table_name,
    record_id,
    before_data,
    after_data,
    created_at
  )
  values (
    v_supplier.tenant_id,
    v_ctx.user_id,
    'Delete supplier',
    'supplier',
    'suppliers',
    p_supplier_id::text,
    to_jsonb(v_supplier),
    jsonb_build_object('deleted_rows', v_deleted),
    now()
  );

  return jsonb_build_object(
    'ok', true,
    'deleted', v_deleted,
    'supplier_id', p_supplier_id,
    'message', case when v_deleted > 0 then 'Supplier berhasil dihapus.' else 'Supplier tidak ditemukan.' end
  );
end;
$$;


-- 4) Replace hard marketplace account delete with guarded soft delete + token wipe.
-- This keeps UI delete usable but avoids direct authenticated hard purge.
create or replace function public.marketplace_delete_account(
  p_tenant_id uuid,
  p_marketplace_account_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ctx record;
  v_account public.marketplace_accounts%rowtype;
  v_archive_result jsonb := '{}'::jsonb;
  v_updated integer := 0;
  v_col text;
  v_token_cols text[] := array[
    'access_token',
    'refresh_token',
    'token_type',
    'token_payload',
    'access_token_expires_at',
    'access_token_expired_at',
    'refresh_token_expires_at',
    'refresh_token_expired_at'
  ];
begin
  if p_tenant_id is null then
    return jsonb_build_object('ok', false, 'message', 'Tenant ID kosong.');
  end if;

  if p_marketplace_account_id is null then
    return jsonb_build_object('ok', false, 'message', 'Marketplace account ID kosong.');
  end if;

  select *
    into v_ctx
  from public._security_rpc_require_role(
    array[
      'super_admin',
      'superadmin',
      'admin',
      'owner',
      'operational_admin',
      'platform_owner'
    ],
    p_tenant_id
  );

  select *
    into v_account
  from public.marketplace_accounts ma
  where ma.tenant_id = p_tenant_id
    and ma.marketplace_account_id = p_marketplace_account_id
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'message', 'Akun marketplace tidak ditemukan.');
  end if;

  begin
    v_archive_result := public.marketplace_archive_sku_maps_for_account(
      p_tenant_id,
      p_marketplace_account_id
    );
  exception when others then
    v_archive_result := jsonb_build_object('ok', false, 'message', sqlerrm);
  end;

  update public.marketplace_accounts ma
     set status = 'deleted',
         is_deleted = true,
         deleted_at = now(),
         updated_at = now()
   where ma.tenant_id = p_tenant_id
     and ma.marketplace_account_id = p_marketplace_account_id;

  get diagnostics v_updated = row_count;

  foreach v_col in array v_token_cols loop
    if exists (
      select 1
      from information_schema.columns
      where table_schema = 'public'
        and table_name = 'marketplace_accounts'
        and column_name = v_col
    ) then
      execute format(
        'update public.marketplace_accounts
            set %I = null,
                updated_at = now()
          where tenant_id = $1
            and marketplace_account_id = $2',
        v_col
      )
      using p_tenant_id, p_marketplace_account_id;
    end if;
  end loop;

  insert into public.audit_logs (
    tenant_id,
    user_id,
    activity,
    module,
    table_name,
    record_id,
    before_data,
    after_data,
    created_at
  )
  values (
    p_tenant_id,
    v_ctx.user_id,
    'Marketplace account soft deleted',
    'marketplace',
    'marketplace_accounts',
    p_marketplace_account_id::text,
    to_jsonb(v_account),
    jsonb_build_object(
      'soft_deleted', true,
      'deleted_at', now(),
      'token_wiped', true,
      'sku_mapping_archive', v_archive_result
    ),
    now()
  );

  return jsonb_build_object(
    'ok', v_updated > 0,
    'message', case
      when v_updated > 0 then 'Akun marketplace dinonaktifkan dan token dihapus. Data historis tidak dipurge.'
      else 'Akun marketplace tidak berubah.'
    end,
    'marketplace_account_id', p_marketplace_account_id,
    'soft_deleted', v_updated > 0,
    'token_wiped', true,
    'sku_mapping_archive', v_archive_result
  );
end;
$$;


-- 5) Revoke authenticated access from unused/emergency destructive RPCs.
do $$
declare
  v_sig text;
  v_oid oid;
  v_blocklist text[] := array[
    'public.clear_audit_logs_for_app()',
    'public.drop_table_if_empty(text)',
    'public.finance_clear_all_customer_data_v2(boolean)',
    'public.finance_clear_marketplace_data(uuid,boolean)',
    'public.marketplace_force_cleanup_deleted_account_leftovers(uuid)',
    'public.marketplace_force_cleanup_stock_out_review_leftovers(uuid)',
    'public.marketplace_force_clear_all_stock_out_reviews_for_tenant(uuid)',
    'public.marketplace_purge_all_soft_deleted_accounts()',
    'public.marketplace_purge_soft_deleted_accounts(uuid)',
    'public.marketplace_reset_stale_auto_jobs(integer,integer,boolean)'
  ];
begin
  foreach v_sig in array v_blocklist loop
    v_oid := to_regprocedure(v_sig);
    if v_oid is not null then
      execute format('revoke execute on function %s from public', v_oid::regprocedure);
      execute format('revoke execute on function %s from anon', v_oid::regprocedure);
      execute format('revoke execute on function %s from authenticated', v_oid::regprocedure);
      execute format('grant execute on function %s to service_role', v_oid::regprocedure);
    end if;
  end loop;
end $$;

-- Keep UI-used guarded functions executable.
grant execute on function public.clear_stock_history_for_app() to authenticated, service_role;
grant execute on function public.delete_stock_transaction_for_app(uuid) to authenticated, service_role;
grant execute on function public.delete_supplier_for_app(uuid) to authenticated, service_role;
grant execute on function public.marketplace_delete_account(uuid, uuid) to authenticated, service_role;

revoke execute on function public.clear_stock_history_for_app() from anon;
revoke execute on function public.delete_stock_transaction_for_app(uuid) from anon;
revoke execute on function public.delete_supplier_for_app(uuid) from anon;
revoke execute on function public.marketplace_delete_account(uuid, uuid) from anon;

notify pgrst, 'reload schema';

commit;
