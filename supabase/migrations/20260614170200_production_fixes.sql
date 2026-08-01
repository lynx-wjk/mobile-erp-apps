-- Phase 2: Production Progress & Payment Rules
-- Migration: 20260614170200_production_fixes.sql
-- Created: 2026-06-14 17:02:00
-- Scope: Schema additions, RPC updates for platform_owner, soft-delete stages,
--         void payments, payment_label, done/stock-in payment unlock

-- ============================================================================
-- 1. SCHEMA MODIFICATIONS
-- ============================================================================

-- 1a. production_progress_stages: soft-delete columns
ALTER TABLE public.production_progress_stages
  ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;
ALTER TABLE public.production_progress_stages
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE public.production_progress_stages
  ADD COLUMN IF NOT EXISTS deleted_by uuid;

-- 1b. production_tailor_payments: payment_label + void columns
ALTER TABLE public.production_tailor_payments
  ADD COLUMN IF NOT EXISTS payment_label text;
ALTER TABLE public.production_tailor_payments
  ADD COLUMN IF NOT EXISTS is_voided boolean NOT NULL DEFAULT false;
ALTER TABLE public.production_tailor_payments
  ADD COLUMN IF NOT EXISTS voided_at timestamptz;
ALTER TABLE public.production_tailor_payments
  ADD COLUMN IF NOT EXISTS voided_by uuid;
ALTER TABLE public.production_tailor_payments
  ADD COLUMN IF NOT EXISTS void_reason text;

-- ============================================================================
-- 2. REDEPLOY: production_recalculate_progress_totals
--    Filter out soft-deleted stages and voided payments
-- ============================================================================
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

  -- Update payment_status per active stage, excluding voided payments
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
            and coalesce(p.is_voided, false) = false
        ), 0) >= s.total_amount then 'sudah_bayar'
        else 'belum_bayar'
      end
  where s.progress_id = p_progress_id
    and coalesce(s.is_active, true) = true;

  -- Sum from active stages only
  select coalesce(sum(total_amount), 0)
    into v_item_total
  from public.production_progress_stages
  where progress_id = p_progress_id
    and tenant_id = v_tenant_id
    and coalesce(is_active, true) = true;

  -- Sum from non-voided payments only
  select coalesce(sum(amount), 0)
    into v_paid_sewing
  from public.production_tailor_payments
  where progress_id = p_progress_id
    and tenant_id = v_tenant_id
    and payment_type = 'sewing_payment'
    and payment_status = 'sudah_bayar'
    and coalesce(is_voided, false) = false;

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

-- ============================================================================
-- 3. REDEPLOY: delete_production_progress_for_app
--    Add platform_owner role, bypass tenant for platform_owner,
--    Block production/produksi if done/stock-in
-- ============================================================================
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

  -- Block production/produksi if done/stock-in
  if v_role in ('production', 'produksi') then
    if coalesce(v_progress.status, '') = 'done'
       or v_progress.stock_in_transaction_id is not null
       or v_progress.stock_in_batch_key is not null then
      raise exception 'Produksi sudah Done/Stock In. Role production tidak bisa menghapus.';
    end if;
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

-- ============================================================================
-- 4. REDEPLOY: delete_production_tailor_payment_for_app
--    Add platform_owner, production, produksi roles
--    Do NOT block based on production done/stock-in status
-- ============================================================================
create or replace function public.delete_production_tailor_payment_for_app(p_payment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_tenant_id uuid;
  v_role text;
  v_payment record;
begin
  select u.user_id, u.tenant_id, lower(coalesce(u.role_id,''))
  into v_user_id, v_tenant_id, v_role
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1;

  if v_user_id is null then
    raise exception 'User belum terhubung ke tenant aktif.';
  end if;
  if v_role not in ('super_admin','superadmin','admin','owner','finance','platform_owner','production','produksi') then
    raise exception 'Role tidak diizinkan menghapus pembayaran produksi.';
  end if;

  select * into v_payment
  from public.production_tailor_payments p
  where p.payment_id = p_payment_id
    and (v_role = 'platform_owner' or p.tenant_id = v_tenant_id);

  if v_payment.payment_id is null then
    raise exception 'Pembayaran produksi tidak ditemukan.';
  end if;

  if v_payment.finance_expense_id is not null then
    delete from public.finance_operational_expenses
    where expense_id = v_payment.finance_expense_id
      and (v_role = 'platform_owner' or tenant_id = v_tenant_id);
  end if;

  delete from public.production_tailor_payments
  where payment_id = v_payment.payment_id
    and (v_role = 'platform_owner' or tenant_id = v_tenant_id);

  if v_payment.progress_id is not null then
    perform public.production_recalculate_progress_totals(v_payment.progress_id);
  end if;

  return jsonb_build_object('ok', true, 'payment_id', p_payment_id);
end;
$$;

-- ============================================================================
-- 5. REDEPLOY: delete_production_material_purchase_for_app
--    Add platform_owner, production, produksi roles
-- ============================================================================
create or replace function public.delete_production_material_purchase_for_app(p_purchase_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_tenant_id uuid;
  v_role text;
  v_count integer := 0;
begin
  select u.user_id, u.tenant_id, lower(coalesce(u.role_id,''))
  into v_user_id, v_tenant_id, v_role
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1;

  if v_user_id is null then
    raise exception 'User belum terhubung ke tenant aktif.';
  end if;
  if v_role not in ('super_admin','superadmin','admin','owner','finance','platform_owner','production','produksi') then
    raise exception 'Role tidak diizinkan menghapus pembelian produksi.';
  end if;

  delete from public.purchases p
  where p.purchase_id = p_purchase_id
    and (v_role = 'platform_owner' or p.tenant_id = v_tenant_id)
    and position('[production_material]' in lower(coalesce(p.catatan,''))) > 0;
  get diagnostics v_count = row_count;

  if v_count = 0 then
    raise exception 'Pembelian bahan produksi tidak ditemukan.';
  end if;

  return jsonb_build_object('ok', true, 'purchase_id', p_purchase_id, 'deleted', v_count);
end;
$$;

-- ============================================================================
-- 6. REDEPLOY: upsert_production_process_stage_for_app
--    Add platform_owner role, bypass tenant, restore soft-deleted on conflict,
--    Only block qty changes when done/stock-in (not payment actions)
-- ============================================================================
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
  p_size_breakdown jsonb DEFAULT '[]'::jsonb
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

  -- Block qty/stock changes if done+stock-in, but allow non-qty updates
  if coalesce(v_progress.status, '') = 'done'
     and (v_progress.stock_in_transaction_id is not null or v_progress.stock_in_batch_key is not null) then
    raise exception 'Produksi sudah Stock In. Proses tidak bisa diedit tanpa reversal.';
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
      -- Restore soft-deleted stage on re-upsert
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
    'size_breakdown', coalesce(p_size_breakdown, '[]'::jsonb),
    'surat_jalan_number', v_progress.surat_jalan_number
  );
end;
$function$;

-- ============================================================================
-- 7. REDEPLOY: upsert_production_tailor_payment_for_app
--    Add p_payment_label, platform_owner role, bypass tenant,
--    REMOVE done/stock-in block — payment RPCs stay callable
-- ============================================================================
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
  p_stage_key text default null::text,
  p_payment_label text default null::text
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
  v_finance_date date := v_paid_at;
  v_role text;
begin
  select u.user_id, u.tenant_id, u.nama, u.email, u.role_id
    into v_user_id, v_tenant_id, v_user_name, v_user_email, v_user_role
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1;

  v_role := lower(coalesce(v_user_role, ''));

  if v_tenant_id is null and v_role <> 'platform_owner' then
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
      and (v_role = 'platform_owner' or pp.tenant_id = v_tenant_id);

    if v_progress_label is null then
      raise exception 'Progress produksi tidak ditemukan.';
    end if;
  end if;

  p_tailor_id := coalesce(p_tailor_id, v_progress_tailor_id);

  if p_tailor_id is not null then
    select t.tailor_name into v_tailor_name
    from public.production_tailors t
    where t.tailor_id = p_tailor_id
      and (v_role = 'platform_owner' or t.tenant_id = v_tenant_id);

    if v_tailor_name is null then
      raise exception 'Pekerja tidak ditemukan.';
    end if;
  end if;

  if p_payment_id is null then
    insert into public.production_tailor_payments(
      tenant_id, progress_id, tailor_id, payment_type, amount, payment_date,
      payment_status, note, created_by, stage_key, payment_label
    ) values (
      v_tenant_id, p_progress_id, p_tailor_id, v_type, v_amount,
      v_paid_at, v_status, nullif(p_note, ''), v_user_id, p_stage_key,
      nullif(btrim(coalesce(p_payment_label, '')), '')
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
           payment_label = nullif(btrim(coalesce(p_payment_label, '')), ''),
           updated_at = now()
     where payment_id = p_payment_id
       and (v_role = 'platform_owner' or tenant_id = v_tenant_id)
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
       and (v_role = 'platform_owner' or tenant_id = v_tenant_id);
  end if;

  if v_type = 'deposit' then
    if v_finance_id is not null then
      delete from public.finance_operational_expenses
       where (v_role = 'platform_owner' or tenant_id = v_tenant_id)
         and (expense_id = v_finance_id or finance_operational_expense_id = v_finance_id);
    end if;

    delete from public.finance_operational_expenses
     where (v_role = 'platform_owner' or tenant_id = v_tenant_id)
       and source_module = 'production'
       and source_ref = 'deposit'
       and source_id = v_payment_id;

    update public.production_tailor_payments
       set progress_id = null,
           tailor_id = null,
           finance_expense_id = null,
           updated_at = now()
     where payment_id = v_payment_id
       and (v_role = 'platform_owner' or tenant_id = v_tenant_id);

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
        coalesce(v_tenant_id, (select tenant_id from public.production_progress where progress_id = p_progress_id)),
        v_category, v_description, v_amount, v_paid_at,
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
         set tenant_id = coalesce(v_tenant_id, tenant_id),
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
         and (v_role = 'platform_owner' or tenant_id = v_tenant_id);
    end if;
  else
    if v_finance_id is not null then
      delete from public.finance_operational_expenses
       where (v_role = 'platform_owner' or tenant_id = v_tenant_id)
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

-- ============================================================================
-- 8. REDEPLOY: upsert_production_deposit_for_app
--    Add p_payment_label, platform_owner role
-- ============================================================================
create or replace function public.upsert_production_deposit_for_app(
  p_payment_id uuid default null::uuid,
  p_amount numeric default 0,
  p_payment_date date default current_date,
  p_payment_status text default 'sudah_bayar'::text,
  p_note text default null::text,
  p_finance_month date default null::date,
  p_proof_evidence_id uuid default null::uuid,
  p_proof_url text default null::text,
  p_payment_label text default null::text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_tenant_id uuid;
  v_role text;
  v_payment_id uuid;
  v_finance_id uuid;
  v_status text := case when p_payment_status = 'belum_bayar' then 'belum_bayar' else 'sudah_bayar' end;
  v_amount numeric := coalesce(p_amount, 0);
  v_paid_at date := coalesce(p_payment_date, current_date);
begin
  select u.user_id, u.tenant_id, lower(coalesce(u.role_id, ''))
    into v_user_id, v_tenant_id, v_role
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1;

  if v_tenant_id is null and v_role <> 'platform_owner' then
    raise exception 'User belum terhubung ke tenant aktif.';
  end if;
  if v_amount <= 0 then
    raise exception 'Nominal deposit wajib lebih dari 0.';
  end if;

  if p_payment_id is null then
    insert into public.production_tailor_payments(
      tenant_id, progress_id, tailor_id, payment_type, amount, payment_date,
      payment_status, note, created_by, payment_label
    ) values (
      v_tenant_id, null, null, 'deposit', v_amount, v_paid_at,
      v_status, nullif(p_note, ''), v_user_id,
      nullif(btrim(coalesce(p_payment_label, '')), '')
    ) returning payment_id, finance_expense_id into v_payment_id, v_finance_id;
  else
    update public.production_tailor_payments
       set progress_id = null,
           tailor_id = null,
           payment_type = 'deposit',
           amount = v_amount,
           payment_date = v_paid_at,
           payment_status = v_status,
           note = nullif(p_note, ''),
           payment_label = nullif(btrim(coalesce(p_payment_label, '')), ''),
           updated_at = now()
     where payment_id = p_payment_id
       and (v_role = 'platform_owner' or tenant_id = v_tenant_id)
       and payment_type = 'deposit'
    returning payment_id, finance_expense_id into v_payment_id, v_finance_id;

    if v_payment_id is null then
      raise exception 'Deposit produksi tidak ditemukan.';
    end if;
  end if;

  if p_proof_evidence_id is not null then
    update public.photo_evidences
       set reference_id = v_payment_id,
           module_name = coalesce(nullif(module_name, ''), 'production_deposit'),
           purpose = coalesce(nullif(purpose, ''), 'deposit_proof')
     where evidence_id = p_proof_evidence_id
       and (v_role = 'platform_owner' or tenant_id = v_tenant_id);
  end if;

  if v_finance_id is not null then
    delete from public.finance_operational_expenses
     where (v_role = 'platform_owner' or tenant_id = v_tenant_id)
       and (expense_id = v_finance_id or finance_operational_expense_id = v_finance_id);
  end if;

  delete from public.finance_operational_expenses
   where (v_role = 'platform_owner' or tenant_id = v_tenant_id)
     and source_module = 'production'
     and source_ref = 'deposit'
     and source_id = v_payment_id;

  update public.production_tailor_payments
     set progress_id = null,
         tailor_id = null,
         finance_expense_id = null,
         updated_at = now()
   where payment_id = v_payment_id
     and (v_role = 'platform_owner' or tenant_id = v_tenant_id);

  return v_payment_id;
end;
$$;

-- ============================================================================
-- 9. NEW: delete_production_progress_stage_for_app
--    Soft-delete stage, void related payments + expenses
-- ============================================================================
create or replace function public.delete_production_progress_stage_for_app(
  p_progress_id uuid,
  p_stage_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user public.users%rowtype;
  v_role text;
  v_stage record;
  v_payment record;
  v_voided_payment_count integer := 0;
  v_voided_expense_count integer := 0;
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
    raise exception 'Akses ditolak.';
  end if;

  -- Find the stage
  select *
    into v_stage
  from public.production_progress_stages
  where progress_id = p_progress_id
    and stage_key = lower(btrim(coalesce(p_stage_key, '')))
    and (v_role = 'platform_owner' or tenant_id = v_user.tenant_id)
    and coalesce(is_active, true) = true
  for update;

  if v_stage.progress_stage_id is null then
    raise exception 'Tahapan proses tidak ditemukan atau sudah dihapus.';
  end if;

  -- Soft-delete the stage
  update public.production_progress_stages
     set is_active = false,
         deleted_at = now(),
         deleted_by = v_user.user_id,
         updated_at = now()
   where progress_stage_id = v_stage.progress_stage_id;

  -- Void related tailor payments (preserve audit trail)
  for v_payment in
    select payment_id, finance_expense_id
    from public.production_tailor_payments
    where progress_id = p_progress_id
      and stage_key = lower(btrim(coalesce(p_stage_key, '')))
      and (v_role = 'platform_owner' or tenant_id = v_user.tenant_id)
      and coalesce(is_voided, false) = false
  loop
    -- Void the payment
    update public.production_tailor_payments
       set is_voided = true,
           voided_at = now(),
           voided_by = v_user.user_id,
           void_reason = 'Stage deleted',
           updated_at = now()
     where payment_id = v_payment.payment_id;
    v_voided_payment_count := v_voided_payment_count + 1;

    -- Void the linked finance expense
    if v_payment.finance_expense_id is not null then
      update public.finance_operational_expenses
         set status = 'voided',
             updated_at = now()
       where expense_id = v_payment.finance_expense_id;
      v_voided_expense_count := v_voided_expense_count + 1;
    end if;
  end loop;

  -- Recalculate totals
  perform public.production_recalculate_progress_totals(p_progress_id);

  return jsonb_build_object(
    'ok', true,
    'action', 'stage_deleted',
    'stage_key', p_stage_key,
    'voided_payment_count', v_voided_payment_count,
    'voided_expense_count', v_voided_expense_count,
    'message', format('Tahapan %s berhasil dihapus. %s pembayaran di-void.', p_stage_key, v_voided_payment_count)
  );
end;
$$;

-- ============================================================================
-- 10. REDEPLOY: list_production_progress_full_for_app
--     Add platform_owner bypass, filter soft-deleted stages, filter voided payments
-- ============================================================================
create or replace function public.list_production_progress_full_for_app(
  p_tailor_id uuid default null::uuid,
  p_status text default null::text,
  p_payment_status text default null::text,
  p_search text default null::text,
  p_month date default null::date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_id uuid;
  v_role text;
  v_rows jsonb;
  v_summary jsonb;
  v_tailors jsonb;
  v_deposits jsonb;
  v_material_purchases jsonb;
  v_search text := lower(btrim(coalesce(p_search, '')));
  v_month_start date := case when p_month is null then null else public._production_month_start(p_month) end;
  v_month_next date := case when p_month is null then null else (public._production_month_start(p_month) + interval '1 month')::date end;
  v_deposit_paid_total numeric := 0;
  v_paid_sewing_global numeric := 0;
  v_paid_kasbon_global numeric := 0;
  v_material_paid_total numeric := 0;
  v_material_unpaid_total numeric := 0;
begin
  select u.tenant_id, lower(coalesce(u.role_id, ''))
    into v_tenant_id, v_role
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1;

  if v_tenant_id is null and v_role <> 'platform_owner' then
    raise exception 'User belum terhubung ke tenant aktif.';
  end if;

  -- Global payment sums — exclude voided
  select
    coalesce(sum(amount) filter (where payment_type = 'deposit' and payment_status = 'sudah_bayar' and coalesce(is_voided, false) = false), 0),
    coalesce(sum(amount) filter (where payment_type = 'sewing_payment' and payment_status = 'sudah_bayar' and coalesce(is_voided, false) = false), 0),
    coalesce(sum(case
      when payment_type = 'kasbon' then amount
      when payment_type = 'kasbon_repayment' then -amount
      else 0
    end) filter (where payment_status = 'sudah_bayar' and coalesce(is_voided, false) = false), 0)
  into v_deposit_paid_total, v_paid_sewing_global, v_paid_kasbon_global
  from public.production_tailor_payments
  where (v_role = 'platform_owner' or tenant_id = v_tenant_id)
    and (v_month_start is null or (payment_date >= v_month_start and payment_date < v_month_next));

  select
    coalesce(sum(total_pembelian) filter (where lower(coalesce(status,'')) in ('approved','verified_finance','paid','done','accepted')), 0),
    coalesce(sum(total_pembelian) filter (where lower(coalesce(status,'')) not in ('approved','verified_finance','paid','done','accepted')), 0)
  into v_material_paid_total, v_material_unpaid_total
  from public.purchases p
  where (v_role = 'platform_owner' or p.tenant_id = v_tenant_id)
    and position('[production_material]' in lower(coalesce(p.catatan,''))) > 0
    and (v_month_start is null or (p.tanggal >= v_month_start and p.tanggal < v_month_next));

  with base as (
    select pp.*,
           coalesce(pp.tailor_name, t.tailor_name, '-') as effective_tailor_name
    from public.production_progress pp
    left join public.production_tailors t on t.tailor_id = pp.tailor_id and t.tenant_id = pp.tenant_id
    where (v_role = 'platform_owner' or pp.tenant_id = v_tenant_id)
      and (v_month_start is null or (coalesce(pp.production_date, pp.created_at::date) >= v_month_start and coalesce(pp.production_date, pp.created_at::date) < v_month_next))
      and (p_tailor_id is null or pp.tailor_id = p_tailor_id)
      and (p_status is null or p_status = '' or p_status = 'all' or pp.status = p_status)
      and (p_payment_status is null or p_payment_status = '' or p_payment_status = 'all' or pp.payment_status = p_payment_status)
      and (
        v_search = '' or
        lower(
          coalesce(pp.surat_jalan_number, '') || ' ' ||
          coalesce(pp.product_name, '') || ' ' ||
          coalesce(pp.nama_barang, '') || ' ' ||
          coalesce(pp.sku, '') || ' ' ||
          coalesce(pp.pattern_code, '') || ' ' ||
          coalesce(pp.source_note, '') || ' ' ||
          coalesce(pp.catatan, '') || ' ' ||
          coalesce(pp.tailor_name, '') || ' ' ||
          coalesce(t.tailor_name, '')
        ) like '%' || v_search || '%'
      )
  ), row_payload as (
    select jsonb_build_object(
      'progress_id', b.progress_id,
      'surat_jalan_number', b.surat_jalan_number,
      'product_id', b.product_id,
      'product_name', b.product_name,
      'nama_barang', b.nama_barang,
      'sku', b.sku,
      'qty', b.qty,
      'status', b.status,
      'source_note', b.source_note,
      'target_finish_date', b.target_finish_date,
      'proof_url', b.proof_url,
      'proof_photo_url', b.proof_photo_url,
      'catatan', b.catatan,
      'created_by', b.created_by,
      'created_by_name', b.created_by_name,
      'created_by_email', b.created_by_email,
      'created_by_role', b.created_by_role,
      'finished_by', b.finished_by,
      'finished_at', b.finished_at,
      'stock_in_transaction_id', b.stock_in_transaction_id,
      'stock_in_batch_key', b.stock_in_batch_key,
      'created_at', b.created_at,
      'updated_at', b.updated_at,
      'tailor_id', b.tailor_id,
      'tailor_name', b.effective_tailor_name,
      'pattern_code', b.pattern_code,
      'production_date', b.production_date,
      'payment_status', b.payment_status,
      'deposit_amount', 0,
      'deposit_date', b.deposit_date,
      'sewing_price_per_pcs', b.sewing_price_per_pcs,
      'sewing_total_amount', b.sewing_total_amount,
      'payment_paid_amount', b.payment_paid_amount,
      'payment_unpaid_amount', b.payment_unpaid_amount,
      'deposit_remaining_amount', 0,
      'surat_jalan_url', b.surat_jalan_url,
      'items', coalesce((
        select jsonb_agg(to_jsonb(i) order by i.sort_order, i.created_at)
        from public.production_progress_items i
        where i.progress_id = b.progress_id and i.tenant_id = b.tenant_id
      ), '[]'::jsonb),
      'stages', coalesce((
        select jsonb_agg(
          to_jsonb(s)
          order by case s.stage_key
            when 'potong_kain' then 1
            when 'jahit' then 2
            when 'lubang_kancing' then 3
            when 'finishing' then 4
            when 'packing' then 5
            else 99
          end,
          s.created_at
        )
        from public.production_progress_stages s
        where s.progress_id = b.progress_id and s.tenant_id = b.tenant_id
          and coalesce(s.is_active, true) = true
      ), '[]'::jsonb),
      'files', coalesce((
        select jsonb_agg(to_jsonb(f) order by f.created_at desc)
        from public.production_progress_files f
        where f.progress_id = b.progress_id and f.tenant_id = b.tenant_id
      ), '[]'::jsonb),
      'payments', coalesce((
        select jsonb_agg(
          to_jsonb(p) || jsonb_build_object(
            'proof_url', pe.public_url,
            'proof_evidence_id', pe.evidence_id
          ) order by p.payment_date desc, p.created_at desc
        )
        from public.production_tailor_payments p
        left join lateral (
          select e.evidence_id, e.public_url
          from public.photo_evidences e
          where e.tenant_id = p.tenant_id
            and e.reference_id = p.payment_id
          order by e.created_at desc
          limit 1
        ) pe on true
        where p.progress_id = b.progress_id
          and p.tenant_id = b.tenant_id
          and p.payment_type <> 'deposit'
          and coalesce(p.is_voided, false) = false
          and (v_month_start is null or (p.payment_date >= v_month_start and p.payment_date < v_month_next))
      ), '[]'::jsonb)
    ) as payload,
    b.created_at
    from base b
  )
  select coalesce(jsonb_agg(payload order by created_at desc), '[]'::jsonb)
    into v_rows
  from row_payload;

  -- Summary
  with base as (
    select pp.*
    from public.production_progress pp
    left join public.production_tailors t on t.tailor_id = pp.tailor_id and t.tenant_id = pp.tenant_id
    where (v_role = 'platform_owner' or pp.tenant_id = v_tenant_id)
      and (v_month_start is null or (coalesce(pp.production_date, pp.created_at::date) >= v_month_start and coalesce(pp.production_date, pp.created_at::date) < v_month_next))
      and (p_tailor_id is null or pp.tailor_id = p_tailor_id)
      and (p_status is null or p_status = '' or p_status = 'all' or pp.status = p_status)
      and (p_payment_status is null or p_payment_status = '' or p_payment_status = 'all' or pp.payment_status = p_payment_status)
      and (
        v_search = '' or
        lower(
          coalesce(pp.surat_jalan_number, '') || ' ' ||
          coalesce(pp.product_name, '') || ' ' ||
          coalesce(pp.nama_barang, '') || ' ' ||
          coalesce(pp.sku, '') || ' ' ||
          coalesce(pp.pattern_code, '') || ' ' ||
          coalesce(pp.source_note, '') || ' ' ||
          coalesce(pp.catatan, '') || ' ' ||
          coalesce(pp.tailor_name, '') || ' ' ||
          coalesce(t.tailor_name, '')
        ) like '%' || v_search || '%'
      )
  )
  select jsonb_build_object(
    'total_progress', count(*)::integer,
    'progress_count', count(*) filter (where status = 'progress')::integer,
    'done_count', count(*) filter (where status = 'done')::integer,
    'cancelled_count', count(*) filter (where status = 'cancelled')::integer,
    'deposit_total', coalesce(v_deposit_paid_total, 0),
    'paid_total', coalesce(v_paid_sewing_global, 0),
    'unpaid_total', coalesce(sum(payment_unpaid_amount), 0),
    'material_paid_total', coalesce(v_material_paid_total, 0),
    'material_unpaid_total', coalesce(v_material_unpaid_total, 0),
    'deposit_remaining_total', coalesce(v_deposit_paid_total, 0) - coalesce(v_paid_sewing_global, 0) - coalesce(v_paid_kasbon_global, 0) - coalesce(v_material_paid_total, 0),
    'kasbon_active_total', greatest(coalesce(v_paid_kasbon_global, 0), 0),
    'kasbon_paid_total', greatest(coalesce(v_paid_kasbon_global, 0), 0),
    'month_start', v_month_start,
    'month_end', case when v_month_start is null then null else (v_month_next - 1) end
  ) into v_summary
  from base;

  -- Deposits — exclude voided
  select coalesce(jsonb_agg(
    to_jsonb(p) || jsonb_build_object(
      'proof_url', pe.public_url,
      'proof_evidence_id', pe.evidence_id
    ) order by p.payment_date desc, p.created_at desc
  ), '[]'::jsonb)
  into v_deposits
  from public.production_tailor_payments p
  left join lateral (
    select e.evidence_id, e.public_url
    from public.photo_evidences e
    where e.tenant_id = p.tenant_id
      and e.reference_id = p.payment_id
    order by e.created_at desc
    limit 1
  ) pe on true
  where (v_role = 'platform_owner' or p.tenant_id = v_tenant_id)
    and p.payment_type = 'deposit'
    and coalesce(p.is_voided, false) = false
    and (v_month_start is null or (p.payment_date >= v_month_start and p.payment_date < v_month_next));

  -- Material purchases
  select coalesce(jsonb_agg(
    to_jsonb(p) || jsonb_build_object(
      'payment_status', case when lower(coalesce(p.status,'')) in ('approved','verified_finance','paid','done','accepted') then 'sudah_bayar' else 'belum_bayar' end,
      'actual_date', substring(coalesce(p.catatan,'') from 'actual_date=([0-9]{4}-[0-9]{2}-[0-9]{2})'),
      'items', coalesce((
        select jsonb_agg(to_jsonb(pi) || jsonb_build_object(
          'stock_in', position('stock_in=true' in lower(coalesce(pi.catatan,''))) > 0
        ) order by pi.created_at)
        from public.purchase_items pi
        where pi.purchase_id = p.purchase_id
          and pi.tenant_id = p.tenant_id
      ), '[]'::jsonb)
    ) order by p.tanggal desc, p.created_at desc
  ), '[]'::jsonb)
  into v_material_purchases
  from public.purchases p
  where (v_role = 'platform_owner' or p.tenant_id = v_tenant_id)
    and position('[production_material]' in lower(coalesce(p.catatan,''))) > 0
    and (v_month_start is null or (p.tanggal >= v_month_start and p.tanggal < v_month_next));

  -- Tailor cards
  with base as (
    select pp.*
    from public.production_progress pp
    left join public.production_tailors t on t.tailor_id = pp.tailor_id and t.tenant_id = pp.tenant_id
    where (v_role = 'platform_owner' or pp.tenant_id = v_tenant_id)
      and (v_month_start is null or (coalesce(pp.production_date, pp.created_at::date) >= v_month_start and coalesce(pp.production_date, pp.created_at::date) < v_month_next))
      and (p_tailor_id is null or pp.tailor_id = p_tailor_id)
      and (p_status is null or p_status = '' or p_status = 'all' or pp.status = p_status)
      and (p_payment_status is null or p_payment_status = '' or p_payment_status = 'all' or pp.payment_status = p_payment_status)
      and (
        v_search = '' or
        lower(
          coalesce(pp.surat_jalan_number, '') || ' ' ||
          coalesce(pp.product_name, '') || ' ' ||
          coalesce(pp.nama_barang, '') || ' ' ||
          coalesce(pp.sku, '') || ' ' ||
          coalesce(pp.pattern_code, '') || ' ' ||
          coalesce(pp.source_note, '') || ' ' ||
          coalesce(pp.catatan, '') || ' ' ||
          coalesce(pp.tailor_name, '') || ' ' ||
          coalesce(t.tailor_name, '')
        ) like '%' || v_search || '%'
      )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'tailor_id', t.tailor_id,
    'tailor_name', t.tailor_name,
    'phone', t.phone,
    'note', t.note,
    'status', t.status,
    'total_progress', coalesce(x.total_progress, 0),
    'total_jahit', coalesce(x.total_jahit, 0),
    'total_ongkos', coalesce(x.total_ongkos, 0),
    'sudah_bayar', coalesce(x.sudah_bayar, 0),
    'belum_bayar', coalesce(x.belum_bayar, 0),
    'deposit', 0,
    'kasbon', greatest(coalesce(k.kasbon, 0), 0),
    'sisa_deposit', coalesce(v_deposit_paid_total, 0) - coalesce(x.sudah_bayar, 0) - greatest(coalesce(k.kasbon, 0), 0)
  ) order by t.tailor_name), '[]'::jsonb)
  into v_tailors
  from public.production_tailors t
  left join (
    select b.tailor_id,
           count(*)::integer as total_progress,
           coalesce(sum(b.qty), 0) as total_jahit,
           coalesce(sum(b.sewing_total_amount), 0) as total_ongkos,
           coalesce(sum(b.payment_paid_amount), 0) as sudah_bayar,
           coalesce(sum(b.payment_unpaid_amount), 0) as belum_bayar
    from base b
    where b.tailor_id is not null
    group by b.tailor_id
  ) x on x.tailor_id = t.tailor_id
  left join (
    select p.tailor_id,
           coalesce(sum(case
             when p.payment_type = 'kasbon' then p.amount
             when p.payment_type = 'kasbon_repayment' then -p.amount
             else 0
           end), 0) as kasbon
    from public.production_tailor_payments p
    where (v_role = 'platform_owner' or p.tenant_id = v_tenant_id)
      and p.payment_type in ('kasbon','kasbon_repayment')
      and p.payment_status = 'sudah_bayar'
      and coalesce(p.is_voided, false) = false
      and (v_month_start is null or (p.payment_date >= v_month_start and p.payment_date < v_month_next))
    group by p.tailor_id
  ) k on k.tailor_id = t.tailor_id
  where (v_role = 'platform_owner' or t.tenant_id = v_tenant_id)
    and (p_tailor_id is null or t.tailor_id = p_tailor_id);

  return jsonb_build_object(
    'ok', true,
    'rows', coalesce(v_rows, '[]'::jsonb),
    'summary', coalesce(v_summary, '{}'::jsonb),
    'tailors', coalesce(v_tailors, '[]'::jsonb),
    'deposits', coalesce(v_deposits, '[]'::jsonb),
    'material_purchases', coalesce(v_material_purchases, '[]'::jsonb)
  );
end;
$$;

-- ============================================================================
-- 11. GRANT EXECUTE on new function
-- ============================================================================
grant execute on function public.delete_production_progress_stage_for_app(uuid, text) to authenticated, service_role;
revoke execute on function public.delete_production_progress_stage_for_app(uuid, text) from anon;
