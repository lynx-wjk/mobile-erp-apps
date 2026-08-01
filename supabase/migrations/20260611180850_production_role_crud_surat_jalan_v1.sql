alter table public.production_progress
  add column if not exists surat_jalan_number text;

create unique index if not exists production_progress_tenant_surat_jalan_number_uidx
  on public.production_progress (tenant_id, surat_jalan_number)
  where surat_jalan_number is not null;

create or replace function public.production_next_surat_jalan_number(
  p_tenant_id uuid,
  p_date date default current_date
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_month text := to_char(coalesce(p_date, current_date), 'YYYYMM');
  v_next integer;
begin
  if p_tenant_id is null then
    raise exception 'tenant_id wajib ada untuk nomor surat jalan.';
  end if;

  perform pg_advisory_xact_lock(hashtext('production_surat_jalan:' || p_tenant_id::text || ':' || v_month));

  select coalesce(max((substring(surat_jalan_number from '^SJ-[0-9]{6}-([0-9]+)$'))::integer), 0) + 1
    into v_next
  from public.production_progress
  where tenant_id = p_tenant_id
    and surat_jalan_number ~ ('^SJ-' || v_month || '-[0-9]+$');

  return 'SJ-' || v_month || '-' || lpad(v_next::text, 4, '0');
end;
$$;

create or replace function public.production_assign_surat_jalan_number()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if nullif(trim(coalesce(new.surat_jalan_number, '')), '') is null then
    new.surat_jalan_number := public.production_next_surat_jalan_number(
      new.tenant_id,
      coalesce(new.production_date, new.created_at::date, current_date)
    );
  end if;

  return new;
end;
$$;

drop trigger if exists trg_production_assign_surat_jalan_number on public.production_progress;
create trigger trg_production_assign_surat_jalan_number
before insert on public.production_progress
for each row execute function public.production_assign_surat_jalan_number();

alter table public.production_progress_stages
  drop constraint if exists production_progress_stages_stage_key_check;

alter table public.production_progress_stages
  add constraint production_progress_stages_stage_key_check
  check (stage_key = any (array[
    'potong_kain'::text,
    'jahit'::text,
    'lubang_kancing'::text,
    'finishing'::text,
    'packing'::text
  ]));

create or replace function public.production_ensure_default_stages()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.production_progress_stages(
    progress_id,
    tenant_id,
    stage_key,
    stage_label,
    status
  )
  values
    (new.progress_id, new.tenant_id, 'potong_kain', 'Potong Kain', 'pending'),
    (new.progress_id, new.tenant_id, 'jahit', 'Jahit', 'pending'),
    (new.progress_id, new.tenant_id, 'lubang_kancing', 'Lubang Kancing', 'pending'),
    (new.progress_id, new.tenant_id, 'finishing', 'Finishing', 'pending'),
    (new.progress_id, new.tenant_id, 'packing', 'Packing', 'pending')
  on conflict (progress_id, stage_key) do nothing;

  return new;
end;
$$;

drop trigger if exists trg_production_ensure_default_stages on public.production_progress;
create trigger trg_production_ensure_default_stages
after insert on public.production_progress
for each row execute function public.production_ensure_default_stages();

with numbered as (
  select
    pp.progress_id,
    'SJ-' ||
      to_char(coalesce(pp.production_date, pp.created_at::date, current_date), 'YYYYMM') ||
      '-' ||
      lpad(row_number() over (
        partition by pp.tenant_id, date_trunc('month', coalesce(pp.production_date, pp.created_at::date, current_date)::timestamp)
        order by pp.created_at, pp.progress_id
      )::text, 4, '0') as next_number
  from public.production_progress pp
  where nullif(trim(coalesce(pp.surat_jalan_number, '')), '') is null
)
update public.production_progress pp
   set surat_jalan_number = numbered.next_number,
       updated_at = now()
from numbered
where numbered.progress_id = pp.progress_id;

insert into public.production_progress_stages(
  progress_id,
  tenant_id,
  stage_key,
  stage_label,
  status
)
select
  pp.progress_id,
  pp.tenant_id,
  stage.stage_key,
  stage.stage_label,
  'pending'
from public.production_progress pp
cross join (
  values
    ('potong_kain', 'Potong Kain'),
    ('jahit', 'Jahit'),
    ('lubang_kancing', 'Lubang Kancing'),
    ('finishing', 'Finishing'),
    ('packing', 'Packing')
) as stage(stage_key, stage_label)
where pp.tenant_id is not null
on conflict (progress_id, stage_key) do nothing;

drop function if exists public.delete_production_progress_for_app(uuid);

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
  v_has_final_stock boolean := false;
  v_has_paid_payment boolean := false;
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

  v_has_final_stock :=
    coalesce(v_progress.status, '') = 'done'
    or v_progress.stock_in_transaction_id is not null
    or v_progress.stock_in_batch_key is not null
    or exists (
      select 1
      from public.production_progress_items i
      where i.progress_id = p_progress_id
        and i.tenant_id = v_user.tenant_id
        and i.stock_in_transaction_id is not null
    );

  v_has_paid_payment := exists (
    select 1
    from public.production_tailor_payments p
    where p.progress_id = p_progress_id
      and p.tenant_id = v_user.tenant_id
      and p.payment_status = 'sudah_bayar'
  );

  if v_has_final_stock or v_has_paid_payment then
    update public.production_progress
       set status = 'cancelled',
           catatan = concat_ws(
             E'\n',
             nullif(catatan, ''),
             concat(
               '[cancelled_by_role_production] ',
               to_char(now() at time zone 'Asia/Jakarta', 'YYYY-MM-DD HH24:MI:SS'),
               ' user=',
               v_user.user_id::text,
               ' role=',
               v_role,
               ' reason=final_stock_or_paid_payment'
             )
           ),
           updated_at = now()
     where progress_id = p_progress_id
       and tenant_id = v_user.tenant_id;

    return jsonb_build_object(
      'ok', true,
      'action', 'cancelled',
      'message', 'Progress sudah berdampak ke stok atau pembayaran, jadi dicancel agar audit dan stok tetap aman.'
    );
  end if;

  delete from public.production_tailor_payments
   where progress_id = p_progress_id
     and tenant_id = v_user.tenant_id;

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
    'message', 'Progress draft/on-progress dihapus permanen karena belum berdampak ke stok final atau payment paid.'
  );
end;
$$;

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
  select u.tenant_id into v_tenant_id
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception 'User belum terhubung ke tenant aktif.';
  end if;

  select
    coalesce(sum(amount) filter (where payment_type = 'deposit' and payment_status = 'sudah_bayar'), 0),
    coalesce(sum(amount) filter (where payment_type = 'sewing_payment' and payment_status = 'sudah_bayar'), 0),
    coalesce(sum(case
      when payment_type = 'kasbon' then amount
      when payment_type = 'kasbon_repayment' then -amount
      else 0
    end) filter (where payment_status = 'sudah_bayar'), 0)
  into v_deposit_paid_total, v_paid_sewing_global, v_paid_kasbon_global
  from public.production_tailor_payments
  where tenant_id = v_tenant_id
    and (v_month_start is null or (payment_date >= v_month_start and payment_date < v_month_next));

  select
    coalesce(sum(total_pembelian) filter (where lower(coalesce(status,'')) in ('approved','verified_finance','paid','done','accepted')), 0),
    coalesce(sum(total_pembelian) filter (where lower(coalesce(status,'')) not in ('approved','verified_finance','paid','done','accepted')), 0)
  into v_material_paid_total, v_material_unpaid_total
  from public.purchases p
  where p.tenant_id = v_tenant_id
    and position('[production_material]' in lower(coalesce(p.catatan,''))) > 0
    and (v_month_start is null or (p.tanggal >= v_month_start and p.tanggal < v_month_next));

  with base as (
    select pp.*,
           coalesce(pp.tailor_name, t.tailor_name, '-') as effective_tailor_name
    from public.production_progress pp
    left join public.production_tailors t on t.tailor_id = pp.tailor_id and t.tenant_id = pp.tenant_id
    where pp.tenant_id = v_tenant_id
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
          and (v_month_start is null or (p.payment_date >= v_month_start and p.payment_date < v_month_next))
      ), '[]'::jsonb)
    ) as payload,
    b.created_at
    from base b
  )
  select coalesce(jsonb_agg(payload order by created_at desc), '[]'::jsonb)
    into v_rows
  from row_payload;

  with base as (
    select pp.*
    from public.production_progress pp
    left join public.production_tailors t on t.tailor_id = pp.tailor_id and t.tenant_id = pp.tenant_id
    where pp.tenant_id = v_tenant_id
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
  where p.tenant_id = v_tenant_id
    and p.payment_type = 'deposit'
    and (v_month_start is null or (p.payment_date >= v_month_start and p.payment_date < v_month_next));

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
  where p.tenant_id = v_tenant_id
    and position('[production_material]' in lower(coalesce(p.catatan,''))) > 0
    and (v_month_start is null or (p.tanggal >= v_month_start and p.tanggal < v_month_next));

  with base as (
    select pp.*
    from public.production_progress pp
    left join public.production_tailors t on t.tailor_id = pp.tailor_id and t.tenant_id = pp.tenant_id
    where pp.tenant_id = v_tenant_id
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
    where p.tenant_id = v_tenant_id
      and p.payment_type in ('kasbon','kasbon_repayment')
      and p.payment_status = 'sudah_bayar'
      and (v_month_start is null or (p.payment_date >= v_month_start and p.payment_date < v_month_next))
    group by p.tailor_id
  ) k on k.tailor_id = t.tailor_id
  where t.tenant_id = v_tenant_id
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

grant execute on function public.production_next_surat_jalan_number(uuid, date) to authenticated, service_role;
revoke execute on function public.production_next_surat_jalan_number(uuid, date) from anon;

grant execute on function public.delete_production_progress_for_app(uuid) to authenticated, service_role;
revoke execute on function public.delete_production_progress_for_app(uuid) from anon;

grant execute on function public.list_production_progress_full_for_app(uuid, text, text, text, date) to authenticated, service_role;
revoke execute on function public.list_production_progress_full_for_app(uuid, text, text, text, date) from anon;

comment on column public.production_progress.surat_jalan_number is
  'Nomor Surat Jalan produksi otomatis per tenant dan bulan, format SJ-YYYYMM-0001.';

comment on function public.delete_production_progress_for_app(uuid) is
  'Allows tenant-scoped production/super_admin CRUD delete. Final stock or paid rows are cancelled instead of hard-deleted.';
