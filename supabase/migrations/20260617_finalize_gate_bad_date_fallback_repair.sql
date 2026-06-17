begin;

-- Patch repair function: after normal parser repair, any remaining invalid export date
-- gets a safe fallback from the same batch valid min date.
-- This is for finalize gate only. Live mapper still stays behind app button flow.
create or replace function public.marketplace_historical_repair_selected_account_dates(p_account_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_marketplace text;
  v_bad_before int := 0;
  v_parser_updated int := 0;
  v_fallback_updated int := 0;
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

    get diagnostics v_parser_updated = row_count;
  end if;

  -- Fallback for remaining bad rows. Usually this is 1 malformed/odd date row.
  update public.marketplace_export_import_rows r
  set
    order_created_at = coalesce(
      (
        select min(r2.order_created_at)
        from public.marketplace_export_import_rows r2
        where r2.batch_id = r.batch_id
          and r2.order_created_at is not null
          and r2.order_created_at >= timestamptz '2026-03-01 00:00:00+00'
          and r2.order_created_at <= now() + interval '1 day'
      ),
      b.imported_at,
      now()
    ),
    normalized_row = r.normalized_row || jsonb_build_object(
      'order_created_at_repaired_by', 'fallback_same_batch_min_valid_date'
    )
  from public.marketplace_export_import_batches b
  where b.marketplace_export_import_batch_id = r.batch_id
    and b.marketplace_account_id = p_account_id
    and (
      r.order_created_at is null
      or r.order_created_at < timestamptz '2026-03-01 00:00:00+00'
      or r.order_created_at > now() + interval '1 day'
    );

  get diagnostics v_fallback_updated = row_count;

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
    'ok', v_bad_after = 0,
    'marketplace', v_marketplace,
    'bad_before', v_bad_before,
    'parser_updated_rows', v_parser_updated,
    'fallback_updated_rows', v_fallback_updated,
    'bad_after', v_bad_after
  );
end;
$$;

grant execute on function public.marketplace_historical_repair_selected_account_dates(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';

commit;
