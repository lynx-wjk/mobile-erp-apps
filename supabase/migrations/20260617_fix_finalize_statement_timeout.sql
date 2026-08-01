begin;

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
  v_active_same_marketplace int := 0;
  v_mapper_result jsonb;
  v_status jsonb;
begin
  -- Historical finalization can process tens of thousands of rows.
  -- Use a longer transaction-local timeout for this RPC only.
  perform set_config('statement_timeout', '10min', true);
  perform set_config('lock_timeout', '30s', true);
  perform set_config('idle_in_transaction_session_timeout', '10min', true);

  select *
    into v_account
  from public.marketplace_accounts
  where marketplace_account_id = p_account_id
    and status = 'active';

  if not found then
    return jsonb_build_object(
      'ok', false,
      'message', 'Akun marketplace aktif tidak ditemukan.',
      'marketplace_account_id', p_account_id
    );
  end if;

  if to_regprocedure('public.marketplace_historical_staging_to_live(text, boolean)') is null then
    return jsonb_build_object(
      'ok', false,
      'message', 'Mapper live belum terpasang di backend.'
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
      'message', 'Masih ada tanggal order yang perlu diperbaiki sebelum finalize.',
      'bad_dates', v_bad_dates,
      'repair', v_repair
    );
  end if;

  select count(*)
    into v_active_same_marketplace
  from public.marketplace_accounts
  where status = 'active'
    and marketplace = v_account.marketplace;

  if v_active_same_marketplace <> 1 then
    return jsonb_build_object(
      'ok', false,
      'message', 'Finalize live diblokir karena ada lebih dari satu akun aktif untuk marketplace yang sama. Mapper account-scoped perlu diterapkan sebelum finalize.',
      'marketplace', v_account.marketplace,
      'active_same_marketplace', v_active_same_marketplace
    );
  end if;

  v_mapper_result := public.marketplace_historical_staging_to_live(
    v_account.marketplace,
    true
  );

  v_status := public.marketplace_historical_import_status_snapshot();

  return jsonb_build_object(
    'ok', coalesce((v_mapper_result->>'ok')::boolean, false),
    'message', 'Finalisasi historical import selesai.',
    'marketplace_account_id', p_account_id,
    'marketplace', v_account.marketplace,
    'shop_name', v_account.shop_name,
    'order_rows', v_order_rows,
    'finance_rows', v_finance_rows,
    'valid_orders', v_valid_orders,
    'orders_upserted', coalesce((v_mapper_result->>'orders_upserted')::int, 0),
    'items_upserted', coalesce((v_mapper_result->>'items_upserted')::int, 0),
    'finance_reports_upserted', coalesce((v_mapper_result->>'finance_reports_upserted')::int, 0),
    'status_snapshot', v_status
  );
exception when others then
  return jsonb_build_object(
    'ok', false,
    'message', 'Finalisasi historical import gagal: ' || sqlerrm,
    'sqlstate', sqlstate,
    'marketplace_account_id', p_account_id
  );
end;
$$;

grant execute on function public.marketplace_finalize_export_bootstrap(uuid, integer, boolean) to authenticated, service_role;

notify pgrst, 'reload schema';

commit;
