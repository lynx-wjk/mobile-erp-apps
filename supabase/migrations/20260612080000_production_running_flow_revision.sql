-- Production Running Flow Revision Migration
-- 1. Add stage_key column to production_tailor_payments if not exists
alter table public.production_tailor_payments add column if not exists stage_key text;

-- 2. Drop automatic default stages trigger and trigger function
drop trigger if exists trg_production_ensure_default_stages on public.production_progress;
drop function if exists public.production_ensure_default_stages();

-- 3. Drop constraint on stage keys to allow dynamic custom stages
alter table public.production_progress_stages drop constraint if exists production_progress_stages_stage_key_check;

-- 4. Drop old signatures for create_production_progress_full_for_app
drop function if exists public.create_production_progress_full_for_app(uuid, text, text, date, date, jsonb, numeric, date, text, text, text, text);
drop function if exists public.create_production_progress_full_for_app(uuid, text, text, date, date, jsonb, numeric, date, text, text, text, text, text);

-- 5. Create new create_production_progress_full_for_app with dynamic stages
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
  v_stage text;
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
    for v_stage in select jsonb_array_elements_text(p_active_stages) loop
      insert into public.production_progress_stages(
        progress_id, tenant_id, stage_key, stage_label, status, sort_order
      ) values (
        v_progress_id, v_tenant_id, v_stage,
        case v_stage
          when 'potong_kain' then 'Potong Kain'
          when 'jahit' then 'Jahit'
          when 'lubang_kancing' then 'Lubang Kancing'
          when 'finishing' then 'Finishing'
          when 'packing' then 'Packing'
          else initcap(replace(v_stage, '_', ' '))
        end,
        'pending',
        public.production_stage_sort_order(v_stage)
      );
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

-- 6. Drop old signature for upsert_production_tailor_payment_for_app
drop function if exists public.upsert_production_tailor_payment_for_app(uuid, uuid, uuid, text, numeric, date, text, text, date, uuid, text);
drop function if exists public.upsert_production_tailor_payment_for_app(uuid, uuid, uuid, text, numeric, date, text, text, date, uuid, text, text);

-- 7. Create new upsert_production_tailor_payment_for_app with stage_key and fix date for finance biaya integration
create or replace function public.upsert_production_tailor_payment_for_app(
  p_payment_id uuid,
  p_progress_id uuid,
  p_tailor_id uuid,
  p_payment_type text,
  p_amount numeric,
  p_payment_date date,
  p_payment_status text,
  p_note text,
  p_finance_month date,
  p_proof_evidence_id uuid,
  p_proof_url text,
  p_stage_key text default null::text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_user_name text;
  v_user_email text;
  v_user_role text;
  v_tenant_id uuid;
  v_progress_tailor_id uuid;
  v_payment_id uuid;
  v_finance_id uuid;
  v_progress_label text;
  v_tailor_name text;
  v_category text;
  v_description text;
  v_status text := case when p_payment_status = 'sudah_bayar' then 'sudah_bayar' else 'belum_bayar' end;
  v_type text := coalesce(nullif(p_payment_type, ''), 'sewing_payment');
  v_amount numeric := coalesce(p_amount, 0);
  v_paid_at date := coalesce(p_payment_date, current_date);
  v_finance_date date := v_paid_at; -- Use paid date directly so it enters the correct monthly MTD/DTD report range!
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
  if v_amount <= 0 then
    raise exception 'Nominal pembayaran wajib lebih dari 0.';
  end if;
  if v_type not in ('deposit','sewing_payment','kasbon','kasbon_repayment') then
    raise exception 'Jenis pembayaran produksi tidak valid: %', v_type;
  end if;

  if p_progress_id is not null then
    select pp.tailor_id, coalesce(pp.pattern_code, pp.product_name, pp.nama_barang, pp.progress_id::text)
      into v_progress_tailor_id, v_progress_label
    from public.production_progress pp
    where pp.progress_id = p_progress_id
      and pp.tenant_id = v_tenant_id;

    if v_progress_label is null then
      raise exception 'Progress produksi tidak ditemukan.';
    end if;
  end if;

  p_tailor_id := coalesce(p_tailor_id, v_progress_tailor_id);

  if p_tailor_id is not null then
    select t.tailor_name into v_tailor_name
    from public.production_tailors t
    where t.tailor_id = p_tailor_id
      and t.tenant_id = v_tenant_id;

    if v_tailor_name is null then
      raise exception 'Pekerja tidak ditemukan.';
    end if;
  end if;

  if p_payment_id is null then
    insert into public.production_tailor_payments(
      tenant_id, progress_id, tailor_id, payment_type, amount, payment_date,
      payment_status, note, created_by, stage_key
    ) values (
      v_tenant_id, p_progress_id, p_tailor_id, v_type, v_amount,
      v_paid_at, v_status, nullif(p_note, ''), v_user_id, p_stage_key
    ) returning payment_id, finance_expense_id into v_payment_id, v_finance_id;
  else
    update public.production_tailor_payments
       set progress_id = p_progress_id,
           tailor_id = p_tailor_id,
           payment_type = v_type,
           amount = v_amount,
           payment_date = v_paid_at,
           payment_status = v_status,
           note = nullif(p_note, ''),
           stage_key = p_stage_key,
           updated_at = now()
     where payment_id = p_payment_id
       and tenant_id = v_tenant_id
    returning payment_id, finance_expense_id into v_payment_id, v_finance_id;

    if v_payment_id is null then
      raise exception 'Pembayaran produksi tidak ditemukan.';
    end if;
  end if;

  if p_proof_evidence_id is not null then
    update public.photo_evidences
       set reference_id = v_payment_id,
           module_name = coalesce(nullif(module_name, ''), 'production_payment'),
           purpose = coalesce(nullif(purpose, ''), v_type || '_proof')
     where evidence_id = p_proof_evidence_id
       and tenant_id = v_tenant_id;
  end if;

  if v_type = 'deposit' then
    if v_finance_id is not null then
      delete from public.finance_operational_expenses
       where tenant_id = v_tenant_id
         and (expense_id = v_finance_id or finance_operational_expense_id = v_finance_id);
    end if;

    delete from public.finance_operational_expenses
     where tenant_id = v_tenant_id
       and source_module = 'production'
       and source_ref = 'deposit'
       and source_id = v_payment_id;

    update public.production_tailor_payments
       set progress_id = null,
           tailor_id = null,
           finance_expense_id = null,
           updated_at = now()
     where payment_id = v_payment_id
       and tenant_id = v_tenant_id;

    return v_payment_id;
  end if;

  v_category := case v_type
    when 'sewing_payment' then 'Ongkos Jahit'
    when 'kasbon' then 'Kasbon Penjahit'
    else 'Pengembalian Kasbon Penjahit'
  end;
  v_description := concat_ws(' - ', v_category, nullif(v_tailor_name, ''), nullif(v_progress_label, ''));
  if p_stage_key is not null then
    v_description := concat_ws(' - ', v_category, nullif(v_tailor_name, ''), concat('Tahap: ', public.production_stage_sort_order(p_stage_key)::text || ' ' || p_stage_key), nullif(v_progress_label, ''));
  end if;

  if v_status = 'sudah_bayar' then
    if v_finance_id is null then
      insert into public.finance_operational_expenses(
        tenant_id, category, description, amount, paid_at, expense_date,
        payment_method, note, created_by, created_by_name, created_by_email,
        created_by_role, status, source_module, source_id, progress_id, tailor_id, source_ref
      ) values (
        v_tenant_id, v_category, v_description, v_amount, v_paid_at,
        v_finance_date, 'production', nullif(p_note, ''),
        v_user_id, v_user_name, v_user_email, v_user_role, 'paid', 'production',
        v_payment_id, p_progress_id, p_tailor_id, v_type
      ) returning expense_id into v_finance_id;

      update public.production_tailor_payments
         set finance_expense_id = v_finance_id,
             updated_at = now()
       where payment_id = v_payment_id;
    else
      update public.finance_operational_expenses
         set tenant_id = v_tenant_id,
             category = v_category,
             description = v_description,
             amount = v_amount,
             paid_at = v_paid_at,
             expense_date = v_finance_date,
             payment_method = 'production',
             note = nullif(p_note, ''),
             status = 'paid',
             source_module = 'production',
             source_id = v_payment_id,
             progress_id = p_progress_id,
             tailor_id = p_tailor_id,
             source_ref = v_type,
             updated_at = now()
       where expense_id = v_finance_id
         and tenant_id = v_tenant_id;
    end if;
  else
    if v_finance_id is not null then
      delete from public.finance_operational_expenses
       where tenant_id = v_tenant_id
         and (expense_id = v_finance_id or finance_operational_expense_id = v_finance_id);

      update public.production_tailor_payments
         set finance_expense_id = null,
             updated_at = now()
       where payment_id = v_payment_id;
    end if;
  end if;

  if p_progress_id is not null then
    perform public.production_recalculate_progress_totals(p_progress_id);
  end if;

  return v_payment_id;
end;
$$;

-- 8. Recreate production_recalculate_progress_totals based on stages
create or replace function public.production_recalculate_progress_totals(p_progress_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_id uuid;
  v_qty_total numeric := 0;
  v_item_total numeric := 0;
  v_paid_sewing numeric := 0;
begin
  select tenant_id into v_tenant_id
  from public.production_progress
  where progress_id = p_progress_id;

  if v_tenant_id is null then
    return;
  end if;

  select coalesce(sum(qty), 0)
    into v_qty_total
  from public.production_progress_items
  where progress_id = p_progress_id
    and tenant_id = v_tenant_id;

  update public.production_progress_stages s
  set payment_status = case
        when coalesce(s.total_amount, 0) > 0 and coalesce((
          select sum(p.amount)
          from public.production_tailor_payments p
          where p.progress_id = s.progress_id
            and p.tenant_id = s.tenant_id
            and p.stage_key = s.stage_key
            and p.payment_type = 'sewing_payment'
            and p.payment_status = 'sudah_bayar'
        ), 0) >= s.total_amount then 'sudah_bayar'
        else 'belum_bayar'
      end
  where s.progress_id = p_progress_id;

  select coalesce(sum(total_amount), 0)
    into v_item_total
  from public.production_progress_stages
  where progress_id = p_progress_id
    and tenant_id = v_tenant_id;

  select coalesce(sum(amount), 0)
    into v_paid_sewing
  from public.production_tailor_payments
  where progress_id = p_progress_id
    and tenant_id = v_tenant_id
    and payment_type = 'sewing_payment'
    and payment_status = 'sudah_bayar';

  update public.production_progress
  set qty = coalesce(v_qty_total, 0),
      sewing_total_amount = coalesce(v_item_total, 0),
      payment_paid_amount = coalesce(v_paid_sewing, 0),
      payment_unpaid_amount = greatest(coalesce(v_item_total, 0) - coalesce(v_paid_sewing, 0), 0),
      payment_status = case
        when coalesce(v_item_total, 0) > 0 and coalesce(v_paid_sewing, 0) >= coalesce(v_item_total, 0) then 'sudah_bayar'
        else 'belum_bayar'
      end,
      updated_at = now()
  where progress_id = p_progress_id;
end;
$$;

-- 9. Recreate upsert_production_process_stage_for_app to call recalculation of totals at the end
create or replace function public.upsert_production_process_stage_for_app(
  p_progress_id uuid,
  p_stage_key text,
  p_status text default 'progress',
  p_tailor_id uuid default null::uuid,
  p_tailor_name text default null::text,
  p_qty_in numeric default null::numeric,
  p_qty_out numeric default null::numeric,
  p_qty_reject numeric default null::numeric,
  p_price_per_pcs numeric default null::numeric,
  p_process_date date default current_date,
  p_proof_url text default null::text,
  p_note text default null::text,
  p_is_skipped boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users%rowtype;
  v_progress public.production_progress%rowtype;
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

  if lower(coalesce(v_user.role_id, '')) in ('demo_super_admin', 'demo') then
    raise exception 'Demo read-only.';
  end if;

  if lower(coalesce(v_user.role_id, '')) not in ('super_admin', 'production', 'produksi') then
    raise exception 'Akses ditolak. Hanya production dan super_admin yang bisa update proses produksi.';
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
    and tenant_id = v_user.tenant_id
  for update;

  if v_progress.progress_id is null then
    raise exception 'Surat Jalan/progress produksi tidak ditemukan.';
  end if;

  if coalesce(v_progress.status, '') = 'done'
     and (v_progress.stock_in_transaction_id is not null or v_progress.stock_in_batch_key is not null) then
    raise exception 'Produksi sudah Stock In. Proses tidak bisa diedit tanpa reversal.';
  end if;

  if p_tailor_id is not null then
    select *
      into v_tailor
    from public.production_tailors
    where tailor_id = p_tailor_id
      and tailor_id = p_tailor_id
      and tenant_id = v_user.tenant_id
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
    and s.tenant_id = v_user.tenant_id
    and coalesce(s.is_skipped, false) = false
    and coalesce(s.status, '') <> 'skipped'
    and public.production_stage_sort_order(s.stage_key) < v_sort
    and coalesce(s.qty_out, 0) > 0
  order by public.production_stage_sort_order(s.stage_key) desc
  limit 1;

  if not p_is_skipped and v_prev_qty is not null and v_qty_out <> v_prev_qty and coalesce(v_note, '') = '' then
    raise exception 'Catatan wajib diisi jika qty proses berubah dari proses sebelumnya (% ke %).', v_prev_qty, v_qty_out;
  end if;

  insert into public.production_progress_stages(
    progress_id,
    tenant_id,
    stage_key,
    stage_label,
    status,
    started_at,
    finished_at,
    proof_url,
    note,
    updated_by,
    tailor_id,
    tailor_name,
    process_date,
    qty_in,
    qty_out,
    qty_reject,
    unit,
    price_per_pcs,
    total_amount,
    payment_status,
    is_skipped,
    skip_reason,
    sort_order
  )
  values (
    p_progress_id,
    v_user.tenant_id,
    v_stage_key,
    case v_stage_key
      when 'potong_kain' then 'Potong Kain'
      when 'jahit' then 'Jahit'
      when 'lubang_kancing' then 'Lubang Kancing'
      when 'finishing' then 'Finishing'
      when 'packing' then 'Packing'
      else initcap(replace(v_stage_key, '_', ' '))
    end,
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
    v_sort
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
      sort_order = excluded.sort_order
  returning production_progress_stages.progress_stage_id into v_stage_id;

  update public.production_progress
     set status = case when coalesce(status, 'progress') = 'pending' then 'progress' else status end,
         updated_at = now()
   where progress_id = p_progress_id
     and tenant_id = v_user.tenant_id;

  perform public.production_recalculate_progress_totals(p_progress_id);

  return jsonb_build_object(
    'ok', true,
    'progress_stage_id', v_stage_id,
    'stage_key', v_stage_key,
    'status', v_status,
    'qty_in', v_qty_in,
    'qty_out', case when p_is_skipped then coalesce(v_prev_qty, v_qty_in) else v_qty_out end,
    'qty_reject', v_qty_reject,
    'surat_jalan_number', v_progress.surat_jalan_number
  );
end;
$$;

-- 10. Recreate delete_production_progress_for_app with stock reversal and payment/finance deletion
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
  if v_role not in ('super_admin', 'production', 'produksi') then
    raise exception 'Akses ditolak. Hanya production dan super_admin yang bisa hapus/cancel progress produksi.';
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
    and tenant_id = v_user.tenant_id
  for update;

  if v_progress.progress_id is null then
    raise exception 'Progress produksi tidak ditemukan.';
  end if;

  -- 1. Revert stock-in transactions if stock has been registered
  for v_item in
    select *
    from public.production_progress_items
    where progress_id = p_progress_id
      and tenant_id = v_user.tenant_id
  loop
    if v_item.stock_in_transaction_id is not null then
      update public.products
         set stock_saat_ini = coalesce(stock_saat_ini, 0) - v_item.qty,
             updated_at = now()
       where product_id = v_item.product_id
         and tenant_id = v_user.tenant_id;

      delete from public.stock_transactions
       where stock_transaction_id = v_item.stock_in_transaction_id;
    end if;
  end loop;

  if v_progress.stock_in_transaction_id is not null then
    update public.products
       set stock_saat_ini = coalesce(stock_saat_ini, 0) - v_progress.qty,
           updated_at = now()
     where product_id = v_progress.product_id
       and tenant_id = v_user.tenant_id;

    delete from public.stock_transactions
     where stock_transaction_id = v_progress.stock_in_transaction_id;
  end if;

  -- 2. Delete payments and their operational finance expenses
  for v_payment in
    select payment_id, finance_expense_id
    from public.production_tailor_payments
    where progress_id = p_progress_id
      and tenant_id = v_user.tenant_id
  loop
    if v_payment.finance_expense_id is not null then
      delete from public.finance_operational_expenses
       where expense_id = v_payment.finance_expense_id
         and tenant_id = v_user.tenant_id;
    end if;

    delete from public.production_tailor_payments
     where payment_id = v_payment.payment_id;
  end loop;

  -- 3. Delete files, stages, items, and progress itself
  delete from public.production_progress_files
   where progress_id = p_progress_id
     and tenant_id = v_user.tenant_id;

  delete from public.production_progress_stages
   where progress_id = p_progress_id
     and tenant_id = v_user.tenant_id;

  delete from public.production_progress_items
   where progress_id = p_progress_id
     and tenant_id = v_user.tenant_id;

  delete from public.production_progress
   where progress_id = p_progress_id
     and tenant_id = v_user.tenant_id;

  return jsonb_build_object(
    'ok', true,
    'action', 'deleted',
    'message', 'Progress produksi berhasil dihapus beserta pembalikan stock dan penghapusan pengeluaran biaya terkait.'
  );
end;
$$;
