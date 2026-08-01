-- Fix ambiguous TikTok date repair function overload and handle one bad staging row.
-- Previous migration created both a zero-arg wrapper and a uuid-default overload.
-- marketplace_historical_staging_to_live() calls the no-arg function, which became ambiguous.

drop function if exists public.marketplace_historical_staging_repair_tiktok_dates();

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
  v_fallback_updated integer := 0;
begin
  select count(*) into v_before_bad
  from public.marketplace_export_import_rows r
  join public.marketplace_export_import_batches b
    on b.marketplace_export_import_batch_id = r.batch_id
  where b.marketplace = 'tiktok_shop'
    and (p_account_id is null or b.marketplace_account_id = p_account_id)
    and nullif(r.marketplace_order_sn, '') is not null
    and (
      r.order_created_at is null
      or r.order_created_at < timestamptz '2026-03-01 00:00:00+00'
      or r.order_created_at > now() + interval '1 day'
    );

  update public.marketplace_export_import_rows r
  set
    order_created_at = public.marketplace_import_parse_tiktok_mmdd_ts(r.normalized_row->>'order_created_at'),
    normalized_row = r.normalized_row || jsonb_build_object(
      'order_created_at_repaired_by', 'marketplace_import_parse_tiktok_ddmm_or_excel_serial_v3'
    )
  from public.marketplace_export_import_batches b
  where b.marketplace_export_import_batch_id = r.batch_id
    and b.marketplace = 'tiktok_shop'
    and (p_account_id is null or b.marketplace_account_id = p_account_id)
    and nullif(r.marketplace_order_sn, '') is not null
    and public.marketplace_import_parse_tiktok_mmdd_ts(r.normalized_row->>'order_created_at') is not null;

  get diagnostics v_updated = row_count;

  -- Very small safety fallback for malformed exported rows.
  -- Uses the closest valid date from the same batch so one broken XLSX row cannot block a 31k-row import.
  with fallback as (
    select
      bad.marketplace_export_import_row_id,
      (
        select max(good.order_created_at)
        from public.marketplace_export_import_rows good
        where good.batch_id = bad.batch_id
          and good.order_created_at >= timestamptz '2026-03-01 00:00:00+00'
          and good.order_created_at <= now() + interval '1 day'
      ) as fallback_created_at
    from public.marketplace_export_import_rows bad
    join public.marketplace_export_import_batches b
      on b.marketplace_export_import_batch_id = bad.batch_id
    where b.marketplace = 'tiktok_shop'
      and (p_account_id is null or b.marketplace_account_id = p_account_id)
      and nullif(bad.marketplace_order_sn, '') is not null
      and (
        bad.order_created_at is null
        or bad.order_created_at < timestamptz '2026-03-01 00:00:00+00'
        or bad.order_created_at > now() + interval '1 day'
      )
  )
  update public.marketplace_export_import_rows r
  set
    order_created_at = f.fallback_created_at,
    normalized_row = r.normalized_row || jsonb_build_object(
      'order_created_at_repaired_by', 'same_batch_max_valid_fallback',
      'order_created_at_repair_note', 'Original export row date was malformed or empty'
    )
  from fallback f
  where f.marketplace_export_import_row_id = r.marketplace_export_import_row_id
    and f.fallback_created_at is not null;

  get diagnostics v_fallback_updated = row_count;

  select count(*) into v_after_bad
  from public.marketplace_export_import_rows r
  join public.marketplace_export_import_batches b
    on b.marketplace_export_import_batch_id = r.batch_id
  where b.marketplace = 'tiktok_shop'
    and (p_account_id is null or b.marketplace_account_id = p_account_id)
    and nullif(r.marketplace_order_sn, '') is not null
    and (
      r.order_created_at is null
      or r.order_created_at < timestamptz '2026-03-01 00:00:00+00'
      or r.order_created_at > now() + interval '1 day'
    );

  return jsonb_build_object(
    'ok', v_after_bad = 0,
    'bad_before', v_before_bad,
    'updated_rows', v_updated,
    'fallback_updated_rows', v_fallback_updated,
    'bad_after', v_after_bad
  );
end;
$$;

grant execute on function public.marketplace_historical_staging_repair_tiktok_dates(uuid)
  to authenticated, service_role;

notify pgrst, 'reload schema';
