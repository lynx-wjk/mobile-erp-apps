-- ============================================================================
-- Supabase Migration: 20260614170600_production_hotfix3_login_access.sql
-- Idempotent hotfix for production/produksi delete and dynamic stages labels
-- ============================================================================

-- 1. DROP OLD FUNCTIONS SIGNATURES
DROP FUNCTION IF EXISTS public.delete_production_progress_for_app(uuid);
DROP FUNCTION IF EXISTS public.create_production_progress_full_for_app(text, date, date, jsonb, text, text, text, text, jsonb);
DROP FUNCTION IF EXISTS public.upsert_production_process_stage_for_app(uuid, text, text, uuid, text, numeric, numeric, numeric, numeric, date, text, text, boolean, jsonb);

-- 2. REDEPLOY: delete_production_progress_for_app
--    Permit production/produksi roles to delete progress cards even when done/stock-in.
--    Tenant ownership checks are strictly enforced via tenant_id comparison.
create or replace function public.delete_production_progress_for_app(p_progress_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users%rowtype;
  v_progress public.production_progress%rowtype;
  v_role text;
  v_item record;
  v_payment record;
begin
  select *
    into v_user
  from public.users
  where user_id = auth.uid()
    and coalesce(status, 'active') = 'active'
  limit 1;

  if v_user.user_id is null then
    raise exception 'User profile tidak ditemukan.';
  end if;

  v_role := lower(coalesce(v_user.role_id, ''));
  if v_role not in ('super_admin', 'platform_owner', 'production', 'produksi') then
    raise exception 'Akses ditolak. Hanya production, super_admin, dan platform_owner yang bisa hapus progress produksi.';
  end if;

  if v_role in ('demo_super_admin', 'demo') then
    raise exception 'Demo read-only.';
  end if;

  if p_progress_id is null then
    raise exception 'progress_id kosong.';
  end if;

  select *
    into v_progress
  from public.production_progress
  where progress_id = p_progress_id
    and (v_role = 'platform_owner' or tenant_id = v_user.tenant_id)
  for update;

  if v_progress.progress_id is null then
    raise exception 'Progress produksi tidak ditemukan.';
  end if;

  -- 1. Revert stock-in transactions if stock has been registered
  for v_item in
    select *
    from public.production_progress_items
    where progress_id = p_progress_id
      and (v_role = 'platform_owner' or tenant_id = v_user.tenant_id)
  loop
    if v_item.stock_in_transaction_id is not null then
      update public.products
         set stock_saat_ini = coalesce(stock_saat_ini, 0) - v_item.qty,
             updated_at = now()
       where product_id = v_item.product_id
         and (v_role = 'platform_owner' or tenant_id = v_user.tenant_id);

      delete from public.stock_transactions
       where stock_transaction_id = v_item.stock_in_transaction_id;
    end if;
  end loop;

  if v_progress.stock_in_transaction_id is not null then
    update public.products
       set stock_saat_ini = coalesce(stock_saat_ini, 0) - v_progress.qty,
           updated_at = now()
     where product_id = v_progress.product_id
       and (v_role = 'platform_owner' or tenant_id = v_user.tenant_id);

    delete from public.stock_transactions
     where stock_transaction_id = v_progress.stock_in_transaction_id;
  end if;

  -- 2. Delete payments and their operational finance expenses
  for v_payment in
    select payment_id, finance_expense_id
    from public.production_tailor_payments
    where progress_id = p_progress_id
      and (v_role = 'platform_owner' or tenant_id = v_user.tenant_id)
  loop
    if v_payment.finance_expense_id is not null then
      delete from public.finance_operational_expenses
       where expense_id = v_payment.finance_expense_id
         and (v_role = 'platform_owner' or tenant_id = v_user.tenant_id);
    end if;

    delete from public.production_tailor_payments
     where payment_id = v_payment.payment_id;
  end loop;

  -- 3. Delete files, stages, items, and progress itself
  delete from public.production_progress_files
   where progress_id = p_progress_id
     and (v_role = 'platform_owner' or tenant_id = v_user.tenant_id);

  delete from public.production_progress_stages
   where progress_id = p_progress_id
     and (v_role = 'platform_owner' or tenant_id = v_user.tenant_id);

  delete from public.production_progress_items
   where progress_id = p_progress_id
     and (v_role = 'platform_owner' or tenant_id = v_user.tenant_id);

  delete from public.production_progress
   where progress_id = p_progress_id
     and (v_role = 'platform_owner' or tenant_id = v_user.tenant_id);

  return jsonb_build_object(
    'ok', true,
    'action', 'deleted',
    'message', 'Progress produksi berhasil dihapus beserta pembalikan stock dan penghapusan pengeluaran biaya terkait.'
  );
end;
$$;

grant execute on function public.delete_production_progress_for_app(uuid) to authenticated, service_role;


-- 3. REDEPLOY: create_production_progress_full_for_app
--    Accept active stages as either strings or objects with key and label.
create or replace function public.create_production_progress_full_for_app(
  p_pattern_code text,
  p_production_date date,
  p_target_finish_date date,
  p_items jsonb,
  p_surat_jalan_url text,
  p_catatan text,
  p_proof_url text,
  p_surat_jalan_number text,
  p_active_stages jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_tenant_id uuid;
  v_user_name text;
  v_user_email text;
  v_user_role text;
  v_progress_id uuid;
  v_item jsonb;
  v_product_id uuid;
  v_product_name text;
  v_product_sku text;
  v_product_barcode text;
  v_product_status text;
  v_qty numeric;
  v_total_qty numeric := 0;
  v_first_product_id uuid;
  v_first_product_name text;
  v_first_sku text;
  v_sort integer := 0;
  v_stage_val jsonb;
  v_stage text;
  v_stage_label text;
begin
  select u.user_id, u.tenant_id, u.nama, u.email, u.role_id
  into v_user_id, v_tenant_id, v_user_name, v_user_email, v_user_role
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception 'User belum terhubung ke tenant aktif.';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Minimal satu baris size breakdown wajib diisi.';
  end if;

  if p_surat_jalan_number is null or trim(p_surat_jalan_number) = '' then
    raise exception 'Nomor Surat Jalan wajib diisi.';
  end if;

  if exists (
    select 1
    from public.production_progress pp
    where pp.tenant_id = v_tenant_id
      and lower(trim(coalesce(pp.surat_jalan_number, ''))) = lower(trim(p_surat_jalan_number))
  ) then
    raise exception 'Nomor Surat Jalan sudah dipakai.';
  end if;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_product_id := nullif(nullif(v_item->>'product_id', ''), 'null')::uuid;
    v_qty := coalesce(nullif(v_item->>'qty', '')::numeric, 0);

    if v_product_id is null then
      raise exception 'Produk lokal wajib dipilih untuk setiap baris size.';
    end if;
    if v_qty <= 0 then
      raise exception 'Qty jahit wajib lebih dari 0.';
    end if;

    select p.nama_barang, p.kode_sku, p.kode_barcode, p.status
    into v_product_name, v_product_sku, v_product_barcode, v_product_status
    from public.products p
    where p.product_id = v_product_id
      and p.tenant_id = v_tenant_id;

    if v_product_name is null then
      raise exception 'Produk lokal tidak ditemukan.';
    end if;
    if coalesce(v_product_status, 'active') <> 'active' then
      raise exception 'Produk lokal tidak aktif.';
    end if;

    v_total_qty := v_total_qty + v_qty;
    if v_first_product_id is null then
      v_first_product_id := v_product_id;
      v_first_product_name := v_product_name;
      v_first_sku := v_product_sku;
    end if;
  end loop;

  insert into public.production_progress(
    product_id, qty, status, tanggal_mulai, user_id, catatan,
    product_name, nama_barang, sku, source_note, target_finish_date,
    proof_url, proof_photo_url, created_by, created_by_name, created_by_email,
    created_by_role, tenant_id, pattern_code, production_date,
    sewing_total_amount, payment_unpaid_amount, payment_status,
    surat_jalan_url, surat_jalan_number
  ) values (
    v_first_product_id, v_total_qty, 'progress', coalesce(p_production_date, current_date)::timestamptz,
    v_user_id, nullif(p_catatan, ''), v_first_product_name, v_first_product_name, v_first_sku,
    'Produksi berjalan - SKU lokal breakdown', p_target_finish_date,
    nullif(p_proof_url, ''), nullif(p_proof_url, ''), v_user_id, v_user_name, v_user_email,
    v_user_role, v_tenant_id, nullif(p_pattern_code, ''),
    coalesce(p_production_date, current_date), 0, 0, 'belum_bayar',
    nullif(p_surat_jalan_url, ''), trim(p_surat_jalan_number)
  ) returning progress_id into v_progress_id;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_sort := v_sort + 1;
    v_product_id := nullif(nullif(v_item->>'product_id', ''), 'null')::uuid;
    v_qty := coalesce(nullif(v_item->>'qty', '')::numeric, 0);

    select p.nama_barang, p.kode_sku, p.kode_barcode
    into v_product_name, v_product_sku, v_product_barcode
    from public.products p
    where p.product_id = v_product_id
      and p.tenant_id = v_tenant_id;

    insert into public.production_progress_items(
      progress_id, tenant_id, product_id, local_sku, local_product_name,
      local_product_barcode, size_label, qty, sewing_price_per_pcs,
      line_total, sort_order
    ) values (
      v_progress_id, v_tenant_id, v_product_id, v_product_sku, v_product_name,
      v_product_barcode,
      coalesce(nullif(v_item->>'size_label', ''), v_product_sku),
      v_qty, 0, 0, v_sort
    );
  end loop;

  if p_active_stages is not null and jsonb_typeof(p_active_stages) = 'array' then
    for v_stage_val in select value from jsonb_array_elements(p_active_stages) loop
      if jsonb_typeof(v_stage_val) = 'object' then
        v_stage := lower(btrim(coalesce(v_stage_val->>'key', '')));
        v_stage_label := coalesce(v_stage_val->>'label', initcap(replace(v_stage, '_', ' ')));
      else
        v_stage := lower(btrim(coalesce(v_stage_val#>>'{}', '')));
        v_stage_label := case v_stage
          when 'potong_kain' then 'Potong Kain'
          when 'jahit' then 'Jahit'
          when 'lubang_kancing' then 'Lubang Kancing'
          when 'finishing' then 'Finishing'
          when 'packing' then 'Packing'
          else initcap(replace(v_stage, '_', ' '))
        end;
      end if;

      if v_stage <> '' then
        insert into public.production_progress_stages(
          progress_id, tenant_id, stage_key, stage_label, status, sort_order
        ) values (
          v_progress_id, v_tenant_id, v_stage, v_stage_label, 'pending', public.production_stage_sort_order(v_stage)
        )
        on conflict (progress_id, stage_key) do update
        set is_active = true,
            deleted_at = null,
            deleted_by = null;
      end if;
    end loop;
  end if;

  if nullif(p_surat_jalan_url, '') is not null then
    insert into public.production_progress_files(progress_id, tenant_id, file_type, file_name, file_url, created_by)
    values (v_progress_id, v_tenant_id, 'surat_jalan', 'Surat jalan', p_surat_jalan_url, v_user_id);
  end if;

  perform public.production_recalculate_progress_totals(v_progress_id);

  return v_progress_id;
end;
$$;

grant execute on function public.create_production_progress_full_for_app(text, date, date, jsonb, text, text, text, text, jsonb) to authenticated, service_role;


-- 4. REDEPLOY: upsert_production_process_stage_for_app
--    Add p_stage_label parameter to support custom/original progress labels on insert or restore.
CREATE OR REPLACE FUNCTION public.upsert_production_process_stage_for_app(
  p_progress_id uuid,
  p_stage_key text,
  p_status text DEFAULT 'progress'::text,
  p_tailor_id uuid DEFAULT NULL::uuid,
  p_tailor_name text DEFAULT NULL::text,
  p_qty_in numeric DEFAULT NULL::numeric,
  p_qty_out numeric DEFAULT NULL::numeric,
  p_qty_reject numeric DEFAULT NULL::numeric,
  p_price_per_pcs numeric DEFAULT NULL::numeric,
  p_process_date date DEFAULT CURRENT_DATE,
  p_proof_url text DEFAULT NULL::text,
  p_note text DEFAULT NULL::text,
  p_is_skipped boolean DEFAULT false,
  p_size_breakdown jsonb DEFAULT '[]'::jsonb,
  p_stage_label text DEFAULT NULL::text
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 AS $function$
declare
  v_user public.users%rowtype;
  v_progress public.production_progress%rowtype;
  v_role text;
  v_stage_key text := lower(btrim(coalesce(p_stage_key, '')));
  v_status text := lower(btrim(coalesce(p_status, 'progress')));
  v_tailor public.production_tailors%rowtype;
  v_tailor_name text := nullif(btrim(coalesce(p_tailor_name, '')), '');
  v_qty_in numeric := greatest(coalesce(p_qty_in, 0), 0);
  v_qty_out numeric := greatest(coalesce(p_qty_out, 0), 0);
  v_qty_reject numeric := greatest(coalesce(p_qty_reject, 0), 0);
  v_price numeric := greatest(coalesce(p_price_per_pcs, 0), 0);
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_sort integer;
  v_prev_qty numeric;
  v_stage_id uuid;
begin
  select *
    into v_user
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
    raise exception 'Akses ditolak. Hanya production, super_admin, dan platform_owner yang bisa update proses produksi.';
  end if;

  if v_status not in ('pending', 'progress', 'done', 'cancelled', 'skipped') then
    v_status := 'progress';
  end if;

  if p_is_skipped then
    v_status := 'skipped';
  end if;

  select *
    into v_progress
  from public.production_progress
  where progress_id = p_progress_id
    and (v_role = 'platform_owner' or tenant_id = v_user.tenant_id)
  for update;

  if v_progress.progress_id is null then
    raise exception 'Surat Jalan/progress produksi tidak ditemukan.';
  end if;

  if p_tailor_id is not null then
    select *
      into v_tailor
    from public.production_tailors
    where tailor_id = p_tailor_id
      and (v_role = 'platform_owner' or tenant_id = v_user.tenant_id)
      and coalesce(status, 'active') <> 'deleted'
    limit 1;

    if v_tailor.tailor_id is null then
      raise exception 'Pekerja produksi tidak ditemukan.';
    end if;
    v_tailor_name := coalesce(nullif(v_tailor.tailor_name, ''), v_tailor_name);
  end if;

  if not p_is_skipped and coalesce(v_tailor_name, '') = '' then
    raise exception 'Pekerja proses wajib diisi.';
  end if;

  if p_is_skipped and coalesce(v_note, '') = '' then
    raise exception 'Catatan wajib diisi jika proses dilewati.';
  end if;

  v_sort := public.production_stage_sort_order(v_stage_key);

  select s.qty_out
    into v_prev_qty
  from public.production_progress_stages s
  where s.progress_id = p_progress_id
    and (v_role = 'platform_owner' or s.tenant_id = v_user.tenant_id)
    and coalesce(s.is_skipped, false) = false
    and coalesce(s.status, '') <> 'skipped'
    and coalesce(s.is_active, true) = true
    and public.production_stage_sort_order(s.stage_key) < v_sort
    and coalesce(s.qty_out, 0) > 0
  order by public.production_stage_sort_order(s.stage_key) desc
  limit 1;

  if not p_is_skipped and v_prev_qty is not null and v_qty_out <> v_prev_qty and coalesce(v_note, '') = '' then
    raise exception 'Catatan wajib diisi jika qty proses berubah dari proses sebelumnya (% ke %).', v_prev_qty, v_qty_out;
  end if;

  insert into public.production_progress_stages(
    progress_id, tenant_id, stage_key, stage_label, status,
    started_at, finished_at, proof_url, note, updated_by,
    tailor_id, tailor_name, process_date, qty_in, qty_out,
    qty_reject, unit, price_per_pcs, total_amount, payment_status,
    is_skipped, skip_reason, sort_order, size_breakdown,
    is_active, deleted_at, deleted_by
  )
  values (
    p_progress_id,
    coalesce(v_progress.tenant_id, v_user.tenant_id),
    v_stage_key,
    coalesce(p_stage_label, case v_stage_key
      when 'potong_kain' then 'Potong Kain'
      when 'jahit' then 'Jahit'
      when 'lubang_kancing' then 'Lubang Kancing'
      when 'finishing' then 'Finishing'
      when 'packing' then 'Packing'
      else initcap(replace(v_stage_key, '_', ' '))
    end),
    v_status,
    case when v_status in ('progress', 'done') then now() else null end,
    case when v_status = 'done' then now() else null end,
    nullif(btrim(coalesce(p_proof_url, '')), ''),
    v_note,
    v_user.user_id,
    p_tailor_id,
    v_tailor_name,
    coalesce(p_process_date, current_date),
    v_qty_in,
    case when p_is_skipped then coalesce(v_prev_qty, v_qty_in) else v_qty_out end,
    v_qty_reject,
    'pcs',
    v_price,
    case when p_is_skipped then 0 else v_qty_out * v_price end,
    'belum_bayar',
    p_is_skipped,
    case when p_is_skipped then v_note else null end,
    v_sort,
    coalesce(p_size_breakdown, '[]'::jsonb),
    true, null, null
  )
  on conflict (progress_id, stage_key) do update
  set status = excluded.status,
      started_at = coalesce(public.production_progress_stages.started_at, excluded.started_at),
      finished_at = case when excluded.status = 'done' then now() else null end,
      proof_url = coalesce(excluded.proof_url, public.production_progress_stages.proof_url),
      note = excluded.note,
      updated_by = v_user.user_id,
      updated_at = now(),
      tailor_id = excluded.tailor_id,
      tailor_name = excluded.tailor_name,
      process_date = excluded.process_date,
      qty_in = excluded.qty_in,
      qty_out = excluded.qty_out,
      qty_reject = excluded.qty_reject,
      unit = excluded.unit,
      price_per_pcs = excluded.price_per_pcs,
      total_amount = excluded.total_amount,
      is_skipped = excluded.is_skipped,
      skip_reason = excluded.skip_reason,
      sort_order = excluded.sort_order,
      size_breakdown = excluded.size_breakdown,
      stage_label = coalesce(excluded.stage_label, public.production_progress_stages.stage_label),
      is_active = true,
      deleted_at = null,
      deleted_by = null
  returning production_progress_stages.progress_stage_id into v_stage_id;

  update public.production_progress
     set status = case when coalesce(status, 'progress') = 'pending' then 'progress' else status end,
         updated_at = now()
   where progress_id = p_progress_id
     and (v_role = 'platform_owner' or tenant_id = v_user.tenant_id);

  perform public.production_recalculate_progress_totals(p_progress_id);

  return jsonb_build_object(
    'ok', true,
    'progress_stage_id', v_stage_id,
    'stage_key', v_stage_key,
    'status', v_status,
    'qty_in', v_qty_in,
    'qty_out', case when p_is_skipped then coalesce(v_prev_qty, v_qty_in) else v_qty_out end,
    'qty_reject', v_qty_reject,
    'total_amount', case when p_is_skipped then 0 else v_qty_out * v_price end
  );
end;
$function$;

grant execute on function public.upsert_production_process_stage_for_app(uuid, text, text, uuid, text, numeric, numeric, numeric, numeric, date, text, text, boolean, jsonb, text) to authenticated, service_role;
