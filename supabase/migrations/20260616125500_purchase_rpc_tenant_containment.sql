-- Purchase verification tenant containment.
-- Fixes SECURITY DEFINER leaks in:
-- - list_purchases_for_app()
-- - list_purchase_items_for_app(uuid)
-- - set_purchase_status_for_app(uuid, text, text)
-- - delete_purchase_by_admin(uuid)

begin;

create or replace function public.list_purchases_for_app()
returns table(
  purchase_id uuid,
  nomor_pembelian text,
  tanggal date,
  supplier_name text,
  total_pembelian numeric,
  status text,
  catatan text,
  photo_url text,
  latitude numeric,
  longitude numeric,
  created_by_name text,
  created_by_email text,
  created_by_role text,
  created_at timestamp with time zone,
  updated_at timestamp with time zone
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users%rowtype;
  v_role text;
begin
  if auth.uid() is null then
    raise exception 'User belum login';
  end if;

  select *
  into v_user
  from public.users as u
  where u.user_id = auth.uid();

  if not found then
    raise exception 'User tidak ditemukan di tabel users';
  end if;

  if coalesce(v_user.status, 'active') <> 'active' then
    raise exception 'User nonaktif';
  end if;

  v_role := regexp_replace(lower(coalesce(v_user.role_id, '')), '[^a-z0-9]+', '_', 'g');

  return query
  select
    p.purchase_id,
    coalesce(p.nomor_pembelian, '-') as nomor_pembelian,
    p.tanggal,
    coalesce(p.supplier_name, '-') as supplier_name,
    case
      when coalesce(p.status, 'draft') in ('rejected', 'cancelled') then 0
      else coalesce(p.total_pembelian, 0)
    end as total_pembelian,
    coalesce(p.status, 'draft') as status,
    p.catatan,
    coalesce(p.photo_url, p.nota_url, p.bukti_url) as photo_url,
    p.latitude,
    p.longitude,
    coalesce(p.created_by_name, p.user_name, '-') as created_by_name,
    coalesce(p.created_by_email, p.user_email, '-') as created_by_email,
    coalesce(p.created_by_role, p.user_role, '-') as created_by_role,
    p.created_at,
    p.updated_at
  from public.purchases as p
  where p.tenant_id = v_user.tenant_id
    and (
      v_role in ('super_admin', 'superadmin', 'admin', 'owner', 'finance', 'finanace')
      or coalesce(p.created_by, p.user_id)::text = v_user.user_id::text
    )
  order by p.created_at desc nulls last;
end;
$$;

create or replace function public.list_purchase_items_for_app(p_purchase_id uuid)
returns table(
  item_id uuid,
  purchase_id uuid,
  product_id uuid,
  kode_sku text,
  kode_barcode text,
  nama_barang text,
  qty numeric,
  satuan text,
  harga_item numeric,
  subtotal numeric,
  catatan text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users%rowtype;
begin
  if auth.uid() is null then
    raise exception 'User belum login';
  end if;

  select *
  into v_user
  from public.users as u
  where u.user_id = auth.uid();

  if not found then
    raise exception 'User tidak ditemukan di tabel users';
  end if;

  if coalesce(v_user.status, 'active') <> 'active' then
    raise exception 'User nonaktif';
  end if;

  if not exists (
    select 1
    from public.purchases p
    where p.purchase_id = p_purchase_id
      and p.tenant_id = v_user.tenant_id
  ) then
    raise exception 'Data pembelian tidak ditemukan';
  end if;

  return query
  select
    coalesce(pi.item_id, pi.purchase_item_id) as item_id,
    pi.purchase_id,
    pi.product_id,
    pi.kode_sku,
    pi.kode_barcode,
    coalesce(pi.nama_barang, pi.nama_barang_manual, '-') as nama_barang,
    coalesce(pi.qty, 0) as qty,
    coalesce(pi.satuan, 'pcs') as satuan,
    coalesce(pi.harga_item, pi.harga_per_item, pi.harga_satuan, 0) as harga_item,
    coalesce(
      pi.subtotal,
      coalesce(pi.qty, 0) * coalesce(pi.harga_item, pi.harga_per_item, pi.harga_satuan, 0)
    ) as subtotal,
    pi.catatan
  from public.purchase_items as pi
  join public.purchases as p
    on p.purchase_id = pi.purchase_id
   and p.tenant_id = v_user.tenant_id
  where pi.purchase_id = p_purchase_id
  order by pi.created_at asc nulls last;
end;
$$;

create or replace function public.set_purchase_status_for_app(
  p_purchase_id uuid,
  p_status text,
  p_note text
)
returns public.purchases
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users%rowtype;
  v_purchase public.purchases%rowtype;
  v_status text;
  v_role text;
  v_finance_status text;
begin
  if auth.uid() is null then
    raise exception 'User belum login';
  end if;

  select *
  into v_user
  from public.users as u
  where u.user_id = auth.uid();

  if not found then
    raise exception 'User tidak ditemukan di tabel users';
  end if;

  if coalesce(v_user.status, 'active') <> 'active' then
    raise exception 'User nonaktif';
  end if;

  v_role := regexp_replace(lower(coalesce(v_user.role_id, '')), '[^a-z0-9]+', '_', 'g');

  if v_role not in ('super_admin', 'superadmin', 'admin', 'owner', 'finance', 'finanace') then
    raise exception 'Hanya Finance atau Super Admin yang boleh verifikasi pembelian';
  end if;

  v_status := regexp_replace(lower(trim(coalesce(p_status, ''))), '[^a-z0-9]+', '_', 'g');

  if v_status not in ('submitted', 'verified_finance', 'approved', 'rejected', 'cancelled', 'revision') then
    raise exception 'Status pembelian tidak valid: %', p_status;
  end if;

  select *
  into v_purchase
  from public.purchases as p
  where p.purchase_id = p_purchase_id
    and p.tenant_id = v_user.tenant_id
  for update;

  if not found then
    raise exception 'Data pembelian tidak ditemukan';
  end if;

  update public.purchases
  set
    status = v_status,
    verification_note = nullif(trim(coalesce(p_note, '')), ''),
    verified_by = v_user.user_id,
    verified_by_name = v_user.nama,
    verified_by_email = v_user.email,
    verified_by_role = v_user.role_id,
    verified_at = now(),
    updated_at = now()
  where purchase_id = p_purchase_id
    and tenant_id = v_user.tenant_id
  returning * into v_purchase;

  if to_regclass('public.finance_verifications') is not null
     and v_status in ('approved', 'rejected', 'revision', 'verified_finance') then
    v_finance_status := case
      when v_status = 'revision' then 'revision_requested'
      when v_status = 'verified_finance' then 'approved'
      else v_status
    end;

    insert into public.finance_verifications (
      purchase_id,
      verified_by,
      status,
      catatan,
      verified_at
    ) values (
      p_purchase_id,
      v_user.user_id,
      v_finance_status,
      nullif(trim(coalesce(p_note, '')), ''),
      now()
    );
  end if;

  return v_purchase;
end;
$$;

create or replace function public.delete_purchase_by_admin(p_purchase_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users%rowtype;
  v_role text;
begin
  if auth.uid() is null then
    raise exception 'User belum login';
  end if;

  select *
  into v_user
  from public.users as u
  where u.user_id = auth.uid();

  if not found then
    raise exception 'User tidak ditemukan di tabel users';
  end if;

  if coalesce(v_user.status, 'active') <> 'active' then
    raise exception 'User nonaktif';
  end if;

  v_role := regexp_replace(lower(coalesce(v_user.role_id, '')), '[^a-z0-9]+', '_', 'g');

  if v_role not in ('super_admin', 'superadmin', 'admin', 'owner') then
    raise exception 'Hanya Super Admin yang boleh menghapus pembelian';
  end if;

  if not exists (
    select 1
    from public.purchases p
    where p.purchase_id = p_purchase_id
      and p.tenant_id = v_user.tenant_id
  ) then
    raise exception 'Data pembelian tidak ditemukan';
  end if;

  if to_regclass('public.finance_verifications') is not null then
    delete from public.finance_verifications fv
    using public.purchases p
    where fv.purchase_id = p_purchase_id
      and p.purchase_id = fv.purchase_id
      and p.tenant_id = v_user.tenant_id;
  end if;

  if to_regclass('public.purchase_receipts') is not null then
    delete from public.purchase_receipts pr
    using public.purchases p
    where pr.purchase_id = p_purchase_id
      and p.purchase_id = pr.purchase_id
      and p.tenant_id = v_user.tenant_id;
  end if;

  delete from public.purchase_items pi
  using public.purchases p
  where pi.purchase_id = p_purchase_id
    and p.purchase_id = pi.purchase_id
    and p.tenant_id = v_user.tenant_id;

  delete from public.purchases
  where purchase_id = p_purchase_id
    and tenant_id = v_user.tenant_id;

  return true;
end;
$$;

grant execute on function public.list_purchases_for_app() to authenticated;
grant execute on function public.list_purchase_items_for_app(uuid) to authenticated;
grant execute on function public.set_purchase_status_for_app(uuid, text, text) to authenticated;
grant execute on function public.delete_purchase_by_admin(uuid) to authenticated;

commit;
