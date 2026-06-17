
begin;

create extension if not exists pgcrypto;

-- Robust TikTok export date parser.
-- Handles MM/DD/YYYY and DD/MM/YYYY ambiguity by preferring a date inside the uploaded 90d window.
create or replace function public.marketplace_import_parse_tiktok_export_ts(p_value text)
returns timestamptz
language plpgsql
stable
as $$
declare
  v text;
  m text[];
  a int;
  b int;
  y int;
  hh int := 0;
  mi int := 0;
  ss int := 0;
  ampm text;
  candidate_mmdd timestamptz;
  candidate_ddmm timestamptz;
  lower_bound timestamptz := timestamptz '2026-03-01 00:00:00+00';
  upper_bound timestamptz := now() + interval '1 day';
begin
  if p_value is null then
    return null;
  end if;

  v := btrim(regexp_replace(p_value, '\s+', ' ', 'g'));
  if v = '' then
    return null;
  end if;

  if v ~ '^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}' then
    m := regexp_match(v, '^([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})(?:\s+([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?\s*([AaPp][Mm])?)?.*$');
    if m is null then
      return null;
    end if;

    a := m[1]::int;
    b := m[2]::int;
    y := m[3]::int;
    hh := coalesce(nullif(m[4], ''), '0')::int;
    mi := coalesce(nullif(m[5], ''), '0')::int;
    ss := coalesce(nullif(m[6], ''), '0')::int;
    ampm := upper(coalesce(m[7], ''));

    if ampm = 'PM' and hh < 12 then
      hh := hh + 12;
    elsif ampm = 'AM' and hh = 12 then
      hh := 0;
    end if;

    begin
      candidate_mmdd := make_timestamptz(y, a, b, hh, mi, ss, 'UTC');
    exception when others then
      candidate_mmdd := null;
    end;

    begin
      candidate_ddmm := make_timestamptz(y, b, a, hh, mi, ss, 'UTC');
    exception when others then
      candidate_ddmm := null;
    end;

    if candidate_mmdd between lower_bound and upper_bound then
      return candidate_mmdd;
    end if;

    if candidate_ddmm between lower_bound and upper_bound then
      return candidate_ddmm;
    end if;

    return coalesce(candidate_mmdd, candidate_ddmm);
  end if;

  return public.marketplace_import_text_ts(v);
exception when others then
  return null;
end;
$$;

create or replace function public.marketplace_historical_repair_selected_account_dates(p_account_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_marketplace text;
  v_bad_before int := 0;
  v_updated int := 0;
  v_bad_after int := 0;
begin
  select marketplace
    into v_marketplace
  from public.marketplace_accounts
  where marketplace_account_id = p_account_id;

  if v_marketplace is null then
    return jsonb_build_object('ok', false, 'message', 'marketplace account not found');
  end if;

  select count(*)
    into v_bad_before
  from public.marketplace_export_import_rows r
  join public.marketplace_export_import_batches b
    on b.marketplace_export_import_batch_id = r.batch_id
  where b.marketplace_account_id = p_account_id
    and (
      r.order_created_at is null
      or r.order_created_at < timestamptz '2026-03-01 00:00:00+00'
      or r.order_created_at > now() + interval '1 day'
    );

  if v_marketplace = 'tiktok_shop' then
    update public.marketplace_export_import_rows r
    set
      order_created_at = public.marketplace_import_parse_tiktok_export_ts(r.normalized_row->>'order_created_at'),
      normalized_row = r.normalized_row || jsonb_build_object(
        'order_created_at_repaired_by', 'marketplace_import_parse_tiktok_export_ts'
      )
    from public.marketplace_export_import_batches b
    where b.marketplace_export_import_batch_id = r.batch_id
      and b.marketplace_account_id = p_account_id
      and public.marketplace_import_parse_tiktok_export_ts(r.normalized_row->>'order_created_at') is not null
      and (
        r.order_created_at is null
        or r.order_created_at < timestamptz '2026-03-01 00:00:00+00'
        or r.order_created_at > now() + interval '1 day'
      );

    get diagnostics v_updated = row_count;
  end if;

  select count(*)
    into v_bad_after
  from public.marketplace_export_import_rows r
  join public.marketplace_export_import_batches b
    on b.marketplace_export_import_batch_id = r.batch_id
  where b.marketplace_account_id = p_account_id
    and (
      r.order_created_at is null
      or r.order_created_at < timestamptz '2026-03-01 00:00:00+00'
      or r.order_created_at > now() + interval '1 day'
    );

  return jsonb_build_object(
    'ok', true,
    'marketplace', v_marketplace,
    'bad_before', v_bad_before,
    'updated_rows', v_updated,
    'bad_after', v_bad_after
  );
end;
$$;

-- This is the RPC the app button will call.
-- For now it validates/repairs and returns a clear account-scoped result.
-- The actual staging->live mapper stays behind this RPC, not behind manual VPS commands.
create or replace function public.marketplace_finalize_export_bootstrap(
  p_account_id uuid,
  p_min_valid_orders integer default 1,
  p_force boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_account record;
  v_repair jsonb;
  v_order_batches int := 0;
  v_finance_batches int := 0;
  v_order_rows int := 0;
  v_finance_rows int := 0;
  v_valid_orders int := 0;
  v_bad_dates int := 0;
begin
  select *
    into v_account
  from public.marketplace_accounts
  where marketplace_account_id = p_account_id
    and status = 'active';

  if not found then
    return jsonb_build_object(
      'ok', false,
      'message', 'active marketplace account not found',
      'marketplace_account_id', p_account_id
    );
  end if;

  v_repair := public.marketplace_historical_repair_selected_account_dates(p_account_id);

  select
    count(distinct b.marketplace_export_import_batch_id),
    count(r.*),
    count(distinct nullif(r.marketplace_order_sn, '')),
    count(*) filter (
      where r.order_created_at is null
         or r.order_created_at < timestamptz '2026-03-01 00:00:00+00'
         or r.order_created_at > now() + interval '1 day'
    )
  into
    v_order_batches,
    v_order_rows,
    v_valid_orders,
    v_bad_dates
  from public.marketplace_export_import_batches b
  left join public.marketplace_export_import_rows r
    on r.batch_id = b.marketplace_export_import_batch_id
  where b.marketplace_account_id = p_account_id;

  select
    count(distinct b.marketplace_finance_export_import_batch_id),
    count(r.*)
  into
    v_finance_batches,
    v_finance_rows
  from public.marketplace_finance_export_import_batches b
  left join public.marketplace_finance_export_import_rows r
    on r.batch_id = b.marketplace_finance_export_import_batch_id
  where b.marketplace_account_id = p_account_id;

  if v_order_batches = 0 or v_order_rows = 0 then
    return jsonb_build_object(
      'ok', false,
      'message', 'Order export belum masuk staging untuk akun ini.',
      'marketplace', v_account.marketplace,
      'shop_name', v_account.shop_name
    );
  end if;

  if v_finance_batches = 0 or v_finance_rows = 0 then
    return jsonb_build_object(
      'ok', false,
      'message', 'Income/Payout export belum masuk staging untuk akun ini.',
      'marketplace', v_account.marketplace,
      'shop_name', v_account.shop_name
    );
  end if;

  if not p_force and v_valid_orders < p_min_valid_orders then
    return jsonb_build_object(
      'ok', false,
      'message', 'Jumlah valid order masih di bawah minimum.',
      'valid_orders', v_valid_orders,
      'min_valid_orders', p_min_valid_orders
    );
  end if;

  if v_bad_dates > 0 then
    return jsonb_build_object(
      'ok', false,
      'message', 'Masih ada order_created_at invalid. Mapper live diblokir.',
      'bad_dates', v_bad_dates,
      'repair', v_repair
    );
  end if;

  -- Guard: mapper live belum ditembak otomatis dari VPS command.
  -- UI finalize sudah siap menjadi pintu resmi.
  return jsonb_build_object(
    'ok', true,
    'message', 'Finalize gate siap. Staging valid dan tanggal sudah direpair. Mapper live akan dijalankan lewat tombol/app flow berikutnya, bukan command manual VPS.',
    'marketplace_account_id', p_account_id,
    'marketplace', v_account.marketplace,
    'shop_name', v_account.shop_name,
    'order_batches', v_order_batches,
    'order_rows', v_order_rows,
    'valid_orders', v_valid_orders,
    'finance_batches', v_finance_batches,
    'finance_rows', v_finance_rows,
    'repair', v_repair
  );
end;
$$;

grant execute on function public.marketplace_import_parse_tiktok_export_ts(text) to authenticated, service_role;
grant execute on function public.marketplace_historical_repair_selected_account_dates(uuid) to authenticated, service_role;
grant execute on function public.marketplace_finalize_export_bootstrap(uuid, integer, boolean) to authenticated, service_role;

notify pgrst, 'reload schema';

commit;
