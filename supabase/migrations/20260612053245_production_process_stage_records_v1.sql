-- Turn production stages into real per-process records under one Surat Jalan.

alter table public.production_progress_stages
  add column if not exists tailor_id uuid,
  add column if not exists tailor_name text,
  add column if not exists process_date date,
  add column if not exists qty_in numeric default 0,
  add column if not exists qty_out numeric default 0,
  add column if not exists qty_reject numeric default 0,
  add column if not exists unit text default 'pcs',
  add column if not exists price_per_pcs numeric default 0,
  add column if not exists total_amount numeric default 0,
  add column if not exists payment_status text default 'belum_bayar',
  add column if not exists is_skipped boolean default false,
  add column if not exists skip_reason text,
  add column if not exists sort_order integer;

update public.production_progress_stages s
   set sort_order = case s.stage_key
       when 'potong_kain' then 1
       when 'jahit' then 2
       when 'lubang_kancing' then 3
       when 'finishing' then 4
       when 'packing' then 5
       else 99
     end,
     process_date = coalesce(s.process_date, s.started_at::date, s.created_at::date),
     qty_in = coalesce(nullif(s.qty_in, 0), pp.qty, 0),
     qty_out = coalesce(nullif(s.qty_out, 0), pp.qty, 0),
     unit = coalesce(nullif(s.unit, ''), 'pcs'),
     total_amount = coalesce(s.total_amount, coalesce(s.qty_out, pp.qty, 0) * coalesce(s.price_per_pcs, 0))
  from public.production_progress pp
 where pp.progress_id = s.progress_id
   and pp.tenant_id = s.tenant_id;

create index if not exists production_progress_stages_process_idx
  on public.production_progress_stages (tenant_id, progress_id, sort_order, stage_key);

create or replace function public.production_stage_sort_order(p_stage_key text)
returns integer
language sql
immutable
as $$
  select case p_stage_key
    when 'potong_kain' then 1
    when 'jahit' then 2
    when 'lubang_kancing' then 3
    when 'finishing' then 4
    when 'packing' then 5
    else 99
  end;
$$;

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

  if v_stage_key not in ('potong_kain', 'jahit', 'lubang_kancing', 'finishing', 'packing') then
    raise exception 'Proses produksi tidak valid: %', p_stage_key;
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
      else v_stage_key
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

grant execute on function public.upsert_production_process_stage_for_app(
  uuid, text, text, uuid, text, numeric, numeric, numeric, numeric, date, text, text, boolean
) to authenticated, service_role;
revoke execute on function public.upsert_production_process_stage_for_app(
  uuid, text, text, uuid, text, numeric, numeric, numeric, numeric, date, text, text, boolean
) from anon;

comment on function public.upsert_production_process_stage_for_app(
  uuid, text, text, uuid, text, numeric, numeric, numeric, numeric, date, text, text, boolean
) is
'Tenant-scoped Produksi Berjalan process updater. Stores per-process worker, qty in/out/reject, tariff, skip reason, and enforces note when qty changes from previous process.';
