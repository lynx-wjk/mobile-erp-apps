
begin;

create or replace function public.marketplace_historical_import_status_snapshot()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'ok', true,
    'accounts',
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'marketplace_account_id', a.marketplace_account_id,
          'marketplace', a.marketplace,
          'shop_name', coalesce(a.shop_name, a.shop_id::text, '-'),
          'order_batches', ob.order_batches,
          'order_finalized_batches', ob.order_finalized_batches,
          'order_rows', orows.order_rows,
          'valid_orders', orows.valid_orders,
          'bad_date_rows', orows.bad_date_rows,
          'finance_batches', fb.finance_batches,
          'finance_finalized_batches', fb.finance_finalized_batches,
          'finance_rows', frows.finance_rows,
          'live_orders', live.live_orders,
          'live_items', live.live_items,
          'live_finance_reports', live.live_finance_reports,
          'finalize_status',
            case
              when ob.order_batches = 0 and fb.finance_batches = 0 then 'waiting_order_and_income'
              when ob.order_batches = 0 then 'waiting_order'
              when fb.finance_batches = 0 then 'waiting_income'
              when orows.bad_date_rows > 0 then 'needs_repair'
              when ob.order_batches > 0
                and fb.finance_batches > 0
                and ob.order_finalized_batches = ob.order_batches
                and fb.finance_finalized_batches = fb.finance_batches
                and live.live_orders >= greatest(orows.valid_orders, 1)
                then 'finalized'
              else 'ready_to_finalize'
            end
        )
        order by a.marketplace, coalesce(a.shop_name, a.shop_id::text, '-')
      ),
      '[]'::jsonb
    )
  )
  from public.marketplace_accounts a
  cross join lateral (
    select
      count(*)::int as order_batches,
      count(*) filter (where status = 'finalized')::int as order_finalized_batches
    from public.marketplace_export_import_batches b
    where b.marketplace_account_id = a.marketplace_account_id
  ) ob
  cross join lateral (
    select
      count(r.*)::int as order_rows,
      count(distinct nullif(r.marketplace_order_sn, ''))::int as valid_orders,
      count(*) filter (
        where r.order_created_at is null
           or r.order_created_at < timestamptz '2026-03-01 00:00:00+00'
           or r.order_created_at > now() + interval '1 day'
      )::int as bad_date_rows
    from public.marketplace_export_import_batches b
    left join public.marketplace_export_import_rows r
      on r.batch_id = b.marketplace_export_import_batch_id
    where b.marketplace_account_id = a.marketplace_account_id
  ) orows
  cross join lateral (
    select
      count(*)::int as finance_batches,
      count(*) filter (where status = 'finalized')::int as finance_finalized_batches
    from public.marketplace_finance_export_import_batches b
    where b.marketplace_account_id = a.marketplace_account_id
  ) fb
  cross join lateral (
    select
      count(r.*)::int as finance_rows
    from public.marketplace_finance_export_import_batches b
    left join public.marketplace_finance_export_import_rows r
      on r.batch_id = b.marketplace_finance_export_import_batch_id
    where b.marketplace_account_id = a.marketplace_account_id
  ) frows
  cross join lateral (
    select
      count(distinct o.marketplace_order_id)::int as live_orders,
      count(distinct i.marketplace_order_item_id)::int as live_items,
      count(distinct fr.marketplace_finance_report_id)::int as live_finance_reports
    from public.marketplace_orders o
    left join public.marketplace_order_items i
      on i.marketplace_order_id = o.marketplace_order_id
    left join public.marketplace_finance_reports fr
      on fr.marketplace_account_id = a.marketplace_account_id
    where o.marketplace_account_id = a.marketplace_account_id
  ) live
  where a.status = 'active'
    and a.marketplace in ('shopee', 'tiktok_shop');
$$;

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

grant execute on function public.marketplace_historical_import_status_snapshot() to authenticated, service_role;
grant execute on function public.marketplace_finalize_export_bootstrap(uuid, integer, boolean) to authenticated, service_role;

notify pgrst, 'reload schema';

commit;
