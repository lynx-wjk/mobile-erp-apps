-- Robust TikTok historical import date repair.
-- TikTok Indonesia XLSX exports can contain DD/MM/YYYY text, MM/DD/YYYY text, or Excel serial date cells.
-- Prefer a candidate inside the supported 90D import window to avoid Jan/Dec false parses.

create or replace function public.marketplace_import_parse_tiktok_mmdd_ts(p_value text)
returns timestamptz
language plpgsql
stable
as $$
declare
  v text;
  n numeric;
  a int;
  b int;
  y int;
  hh int := 0;
  mi int := 0;
  ss int := 0;
  ampm text;
  t text;
  m text[];
  c_mmdd timestamptz;
  c_ddmm timestamptz;
  v_min timestamptz := timestamptz '2026-03-01 00:00:00+00';
  v_max timestamptz := now() + interval '1 day';
begin
  if p_value is null then
    return null;
  end if;

  v := btrim(p_value);
  if v = '' then
    return null;
  end if;

  v := regexp_replace(v, '\s+', ' ', 'g');

  -- Excel serial date/time. Example: 45570.46875.
  if v ~ '^[0-9]+(\.[0-9]+)?$' then
    n := v::numeric;

    if n > 20000 and n < 100000 then
      return (timestamp '1899-12-30 00:00:00'
              + ((n::double precision) * interval '1 day')) at time zone 'UTC';
    end if;

    if n > 100000000000 then
      return to_timestamp((n / 1000)::double precision);
    elsif n > 1000000000 then
      return to_timestamp(n::double precision);
    end if;
  end if;

  -- Slash dates. For Indonesian TikTok exports, DD/MM/YYYY is common.
  if v ~ '^[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}' then
    m := regexp_match(v, '^([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})(.*)$');
    if m is null then
      return null;
    end if;

    a := m[1]::int;
    b := m[2]::int;
    y := m[3]::int;
    t := btrim(coalesce(m[4], ''));

    hh := 0; mi := 0; ss := 0;

    if t <> '' then
      m := regexp_match(t, '([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?\s*([AaPp][Mm])?');
      if m is not null then
        hh := m[1]::int;
        mi := m[2]::int;
        ss := coalesce(nullif(m[3], ''), '0')::int;
        ampm := upper(coalesce(m[4], ''));

        if ampm = 'PM' and hh < 12 then
          hh := hh + 12;
        elsif ampm = 'AM' and hh = 12 then
          hh := 0;
        end if;
      end if;
    end if;

    begin
      if a between 1 and 12 and b between 1 and 31 then
        c_mmdd := make_timestamptz(y, a, b, hh, mi, ss, 'UTC');
      end if;
    exception when others then
      c_mmdd := null;
    end;

    begin
      if b between 1 and 12 and a between 1 and 31 then
        c_ddmm := make_timestamptz(y, b, a, hh, mi, ss, 'UTC');
      end if;
    exception when others then
      c_ddmm := null;
    end;

    -- Prefer the candidate inside expected import window.
    if c_ddmm is not null and c_ddmm >= v_min and c_ddmm <= v_max then
      return c_ddmm;
    end if;

    if c_mmdd is not null and c_mmdd >= v_min and c_mmdd <= v_max then
      return c_mmdd;
    end if;

    -- If both are outside, TikTok ID export is usually DD/MM.
    return coalesce(c_ddmm, c_mmdd);
  end if;

  return public.marketplace_import_text_ts(v);
exception when others then
  return null;
end;
$$;

create or replace function public.marketplace_historical_staging_repair_tiktok_dates(
  p_account_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_before_bad integer := 0;
  v_after_bad integer := 0;
  v_updated integer := 0;
begin
  select count(*) into v_before_bad
  from public.marketplace_export_import_rows r
  join public.marketplace_export_import_batches b
    on b.marketplace_export_import_batch_id = r.batch_id
  where b.marketplace = 'tiktok_shop'
    and (p_account_id is null or b.marketplace_account_id = p_account_id)
    and (
      r.order_created_at is null
      or r.order_created_at < timestamptz '2026-03-01 00:00:00+00'
      or r.order_created_at > now() + interval '1 day'
    );

  -- Reparse all TikTok rows, not only invalid ones, because old MM/DD parse can be valid but wrong.
  update public.marketplace_export_import_rows r
  set
    order_created_at = public.marketplace_import_parse_tiktok_mmdd_ts(r.normalized_row->>'order_created_at'),
    normalized_row = r.normalized_row || jsonb_build_object(
      'order_created_at_repaired_by', 'marketplace_import_parse_tiktok_ddmm_or_excel_serial_v2'
    )
  from public.marketplace_export_import_batches b
  where b.marketplace_export_import_batch_id = r.batch_id
    and b.marketplace = 'tiktok_shop'
    and (p_account_id is null or b.marketplace_account_id = p_account_id)
    and public.marketplace_import_parse_tiktok_mmdd_ts(r.normalized_row->>'order_created_at') is not null;

  get diagnostics v_updated = row_count;

  select count(*) into v_after_bad
  from public.marketplace_export_import_rows r
  join public.marketplace_export_import_batches b
    on b.marketplace_export_import_batch_id = r.batch_id
  where b.marketplace = 'tiktok_shop'
    and (p_account_id is null or b.marketplace_account_id = p_account_id)
    and (
      r.order_created_at is null
      or r.order_created_at < timestamptz '2026-03-01 00:00:00+00'
      or r.order_created_at > now() + interval '1 day'
    );

  return jsonb_build_object(
    'ok', v_after_bad = 0,
    'bad_before', v_before_bad,
    'updated_rows', v_updated,
    'bad_after', v_after_bad
  );
end;
$$;

-- Compatibility wrapper for old mapper call without args.
create or replace function public.marketplace_historical_staging_repair_tiktok_dates()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select public.marketplace_historical_staging_repair_tiktok_dates(null::uuid);
$$;

grant execute on function public.marketplace_import_parse_tiktok_mmdd_ts(text) to authenticated, service_role;
grant execute on function public.marketplace_historical_staging_repair_tiktok_dates(uuid) to authenticated, service_role;
grant execute on function public.marketplace_historical_staging_repair_tiktok_dates() to authenticated, service_role;

notify pgrst, 'reload schema';
