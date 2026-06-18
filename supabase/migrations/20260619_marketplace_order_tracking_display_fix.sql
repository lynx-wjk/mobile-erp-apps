-- Marketplace order tracking/resi display fix.
-- Do not treat package_id / label_code / order id as marketplace resi.
-- Backfill real tracking_number from import staging raw/normalized data when available.

create or replace function public.marketplace_clean_tracking_candidate(
  p_value text,
  p_order_sn text default null
)
returns text
language plpgsql
immutable
as $$
declare
  v text := btrim(coalesce(p_value, ''));
  o text := btrim(coalesce(p_order_sn, ''));
  lower_v text;
begin
  if v = '' then
    return null;
  end if;

  v := regexp_replace(v, '\s+', '', 'g');
  lower_v := lower(v);

  if v = '' or v = '-' or lower_v in ('null', 'none', 'n/a', 'na') then
    return null;
  end if;

  -- Description/header rows from TikTok XLSX.
  if lower_v like '%trackingnumber%' or lower_v like '%theorder%' then
    return null;
  end if;

  -- Do not accept the marketplace order id itself as a tracking number.
  if o <> '' and v = o then
    return null;
  end if;

  -- Known marketplace order id / package id patterns that were previously displayed as resi.
  if v ~ '^OFG[0-9A-Z]{10,}$' then
    return null;
  end if;

  -- TikTok package/order references are often long numeric-only strings.
  -- Keep real courier numeric resi only if short enough; reject 16+ digit order-like refs.
  if v ~ '^[0-9]{16,}$' then
    return null;
  end if;

  -- Very short values are usually not courier tracking numbers.
  if length(v) < 8 then
    return null;
  end if;

  return v;
end;
$$;

create or replace function public.marketplace_pick_tracking_from_json(
  p_json jsonb,
  p_order_sn text default null
)
returns text
language sql
stable
as $$
  select public.marketplace_clean_tracking_candidate(v, p_order_sn)
  from (
    values
      (p_json->>'tracking_number'),
      (p_json->>'tracking_id'),
      (p_json->>'tracking_no'),
      (p_json->>'awb'),
      (p_json->>'resi'),
      (p_json->>'waybill_number'),
      (p_json->>'airway_bill'),
      (p_json->>'shipping_tracking_number'),
      (p_json->>'logistics_tracking_number'),
      (p_json->>'spx_tracking_number'),
      (p_json->>'Tracking ID'),
      (p_json->>'Tracking Number'),
      (p_json->>'No. Resi'),
      (p_json->>'Nomor Resi'),
      (p_json#>>'{normalized_row,tracking_number}'),
      (p_json#>>'{raw_row,Tracking ID}'),
      (p_json#>>'{raw_row,Tracking Number}'),
      (p_json#>>'{raw_row,No. Resi}'),
      (p_json#>>'{raw_row,Nomor Resi}')
  ) as x(v)
  where public.marketplace_clean_tracking_candidate(v, p_order_sn) is not null
  limit 1;
$$;

create or replace function public.marketplace_backfill_order_tracking_from_staging(
  p_account_id uuid default null,
  p_marketplace text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '10min'
as $$
declare
  v_order_updated integer := 0;
  v_item_updated integer := 0;
  v_marketplace text := coalesce(public.marketplace_normalize_key(p_marketplace), p_marketplace);
begin
  create temporary table tmp_staging_tracking on commit drop as
  select
    a.tenant_id,
    a.marketplace_account_id,
    a.marketplace,
    r.marketplace_order_sn as order_sn,
    max(public.marketplace_clean_tracking_candidate(
      coalesce(
        public.marketplace_pick_tracking_from_json(r.normalized_row, r.marketplace_order_sn),
        public.marketplace_pick_tracking_from_json(r.raw_row, r.marketplace_order_sn)
      ),
      r.marketplace_order_sn
    )) filter (
      where public.marketplace_clean_tracking_candidate(
        coalesce(
          public.marketplace_pick_tracking_from_json(r.normalized_row, r.marketplace_order_sn),
          public.marketplace_pick_tracking_from_json(r.raw_row, r.marketplace_order_sn)
        ),
        r.marketplace_order_sn
      ) is not null
    ) as tracking_number
  from public.marketplace_export_import_rows r
  join public.marketplace_export_import_batches b
    on b.marketplace_export_import_batch_id = r.batch_id
  join public.marketplace_accounts a
    on a.marketplace_account_id = b.marketplace_account_id
  where nullif(r.marketplace_order_sn, '') is not null
    and (p_account_id is null or a.marketplace_account_id = p_account_id)
    and (
      v_marketplace is null
      or v_marketplace = ''
      or v_marketplace = 'all'
      or a.marketplace = v_marketplace
    )
  group by a.tenant_id, a.marketplace_account_id, a.marketplace, r.marketplace_order_sn;

  create index on tmp_staging_tracking(tenant_id, marketplace_account_id, marketplace, order_sn);

  update public.marketplace_orders o
  set
    tracking_number = t.tracking_number,
    raw_order = coalesce(o.raw_order, '{}'::jsonb) || jsonb_build_object(
      'tracking_backfilled_from', 'historical_order_import_staging',
      'tracking_backfilled_at', now(),
      'tracking_number', t.tracking_number
    ),
    updated_at = now()
  from tmp_staging_tracking t
  where t.tracking_number is not null
    and o.tenant_id = t.tenant_id
    and o.marketplace_account_id = t.marketplace_account_id
    and o.marketplace = t.marketplace
    and o.order_sn = t.order_sn
    and (
      nullif(o.tracking_number, '') is null
      or public.marketplace_clean_tracking_candidate(o.tracking_number, o.order_sn) is null
    );

  get diagnostics v_order_updated = row_count;

  update public.marketplace_order_items i
  set
    tracking_number = t.tracking_number,
    raw_item = coalesce(i.raw_item, '{}'::jsonb) || jsonb_build_object(
      'tracking_backfilled_from', 'historical_order_import_staging',
      'tracking_backfilled_at', now(),
      'tracking_number', t.tracking_number
    ),
    updated_at = now()
  from tmp_staging_tracking t
  where t.tracking_number is not null
    and i.tenant_id = t.tenant_id
    and i.marketplace_account_id = t.marketplace_account_id
    and i.marketplace = t.marketplace
    and i.order_sn = t.order_sn
    and (
      nullif(i.tracking_number, '') is null
      or public.marketplace_clean_tracking_candidate(i.tracking_number, i.order_sn) is null
    );

  get diagnostics v_item_updated = row_count;

  return jsonb_build_object(
    'ok', true,
    'order_updated', v_order_updated,
    'item_updated', v_item_updated,
    'account_id', p_account_id,
    'marketplace', p_marketplace
  );
end;
$$;

grant execute on function public.marketplace_clean_tracking_candidate(text, text) to authenticated, service_role;
grant execute on function public.marketplace_pick_tracking_from_json(jsonb, text) to authenticated, service_role;
grant execute on function public.marketplace_backfill_order_tracking_from_staging(uuid, text) to authenticated, service_role;

notify pgrst, 'reload schema';
