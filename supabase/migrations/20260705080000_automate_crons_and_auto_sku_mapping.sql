-- Migration: Automate pg_cron schedules, add auto SKU mapping trigger, and dynamically resolve mapped local SKUs
-- Date: 2026-07-05 08:00:00 (UTC+7)

-- 1. Automate pg_cron order and finance dispatchers
SELECT cron.unschedule('marketplace-order-dispatcher-every-2-min');
SELECT cron.schedule(
  'marketplace-order-dispatcher-every-2-min',
  '*/2 * * * *',
  $$
  select net.http_post(
    url := 'http://kong:8000/functions/v1/marketplace-order-dispatcher',
    body := jsonb_build_object(
      'max_accounts', 2,
      'lock_seconds', 900,
      'source', 'marketplace_order_dispatcher_automated_2m'
    ),
    params := '{}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-marketplace-cron-secret', app_private.get_runtime_secret('marketplace_cron_secret')
    ),
    timeout_milliseconds := 120000
  );
  $$
);

SELECT cron.unschedule('marketplace-finance-dispatcher-hourly');
SELECT cron.schedule(
  'marketplace-finance-dispatcher-hourly',
  '*/10 * * * *',
  $$
  update public.marketplace_finance_sync_state
  set
    finance_status = 'idle',
    last_error = null,
    next_run_at = now() - interval '1 second'
  where finance_status = 'running'
    and next_run_at <= now() - interval '15 minutes';

  select net.http_post(
    url := 'http://kong:8000/functions/v1/marketplace-finance-dispatcher',
    body := jsonb_build_object(
      'force', true,
      'max_accounts', 2,
      'window_days', 10,
      'bootstrap_days', 90,
      'max_orders', 20,
      'lock_seconds', 1800,
      'child_timeout_ms', 120000,
      'source', 'marketplace_finance_dispatcher_automated_10m'
    ),
    params := '{}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-marketplace-cron-secret', app_private.get_runtime_secret('marketplace_cron_secret')
    ),
    timeout_milliseconds := 120000
  );
  $$
);

-- 2. Create the Automatic SKU Mapping Trigger on marketplace_variant_snapshots
create or replace function public.fn_auto_map_new_variant_snapshot()
returns trigger
language plpgsql
security definer
as $$
declare
  v_product_id uuid;
  v_local_sku text;
  v_local_name text;
  v_sku_map_id uuid;
begin
  if coalesce(new.marketplace_sku_code, new.marketplace_seller_sku, '') = '' then
    return new;
  end if;

  select product_id, kode_sku, nama_barang
    into v_product_id, v_local_sku, v_local_name
  from public.products
  where tenant_id = new.tenant_id
    and (
      lower(trim(kode_sku)) = lower(trim(new.marketplace_sku_code))
      or lower(trim(kode_sku)) = lower(trim(new.marketplace_seller_sku))
    )
    and coalesce(status, 'active') = 'active'
  order by updated_at desc nulls last, created_at desc nulls last
  limit 1;

  if v_product_id is null then
    return new;
  end if;

  select marketplace_sku_map_id
    into v_sku_map_id
  from public.marketplace_sku_maps
  where tenant_id = new.tenant_id
    and marketplace_account_id = new.marketplace_account_id
    and marketplace_product_id = new.marketplace_product_id
    and marketplace_sku_id = new.marketplace_sku_id;

  if v_sku_map_id is not null then
    update public.marketplace_sku_maps
    set local_product_id = v_product_id,
        product_id = v_product_id,
        local_sku = v_local_sku,
        local_product_name = v_local_name,
        status = 'active',
        updated_at = now()
    where marketplace_sku_map_id = v_sku_map_id;
  else
    insert into public.marketplace_sku_maps (
      tenant_id,
      marketplace_account_id,
      marketplace,
      marketplace_product_id,
      marketplace_sku_id,
      marketplace_seller_sku,
      local_product_id,
      product_id,
      local_sku,
      local_product_name,
      status,
      created_at,
      updated_at
    )
    values (
      new.tenant_id,
      new.marketplace_account_id,
      new.marketplace,
      new.marketplace_product_id,
      new.marketplace_sku_id,
      coalesce(new.marketplace_sku_code, new.marketplace_seller_sku),
      v_product_id,
      v_product_id,
      v_local_sku,
      v_local_name,
      'active',
      now(),
      now()
    );
  end if;

  return new;
end;
$$;

drop trigger if exists trg_auto_map_new_variant_snapshot on public.marketplace_variant_snapshots;
create trigger trg_auto_map_new_variant_snapshot
  after insert or update on public.marketplace_variant_snapshots
  for each row execute function public.fn_auto_map_new_variant_snapshot();

-- 3. Redefine finance_sku_order_details_core_20260625 with dynamic mapped SKU fallback
CREATE OR REPLACE FUNCTION public.finance_sku_order_details_core_20260625(
  p_start date DEFAULT NULL::date,
  p_end date DEFAULT NULL::date,
  p_marketplace text DEFAULT NULL::text,
  p_account_id uuid DEFAULT NULL::uuid,
  p_marketplace_sku text DEFAULT NULL::text,
  p_local_sku text DEFAULT NULL::text,
  p_search text DEFAULT NULL::text,
  p_payout_filter text DEFAULT 'all'::text,
  p_page integer DEFAULT 1,
  p_page_size integer DEFAULT 20
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_tenant_id uuid;
  v_role text;
  v_start date := coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date);
  v_end date := coalesce(p_end, timezone('Asia/Jakarta', now())::date);
  v_start_ts timestamptz;
  v_end_ts timestamptz;
  v_marketplace text;
  v_account_id uuid := p_account_id;
  v_marketplace_sku text := lower(nullif(trim(coalesce(p_marketplace_sku, '')), ''));
  v_local_sku text := lower(nullif(trim(coalesce(p_local_sku, '')), ''));
  v_search text := lower(nullif(trim(coalesce(p_search, '')), ''));
  v_filter text := lower(trim(coalesce(p_payout_filter, 'all')));
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 20), 1), 25);
  v_offset integer;
  v_detail_mode boolean;
begin
  perform set_config('work_mem', '64MB', true);

  select
    coalesce(
      case
        when (v_claims->>'tenant_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then (v_claims->>'tenant_id')::uuid
        else null::uuid
      end,
      (select u.tenant_id from public.users u where u.user_id = auth.uid() limit 1)
    ),
    coalesce(nullif(v_claims->>'role', ''), '')
  into v_tenant_id, v_role;

  v_start_ts := (v_start::timestamp at time zone 'Asia/Jakarta');
  v_end_ts := ((v_end + 1)::timestamp at time zone 'Asia/Jakarta');
  v_offset := (v_page - 1) * v_page_size;
  v_filter := case
    when v_filter in ('settled', 'released', 'release', 'payout', 'paid payout', 'sudah payout') then 'paid'
    when v_filter in ('pending', 'belum payout', 'no payout', 'missing payout') then 'unpaid'
    when v_filter = '' then 'all'
    else v_filter
  end;
  v_marketplace := case
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
    when lower(regexp_replace(coalesce(p_marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
    else null
  end;
  v_detail_mode := v_marketplace_sku is not null
    or v_local_sku is not null
    or v_search is not null;

  if v_role <> 'service_role' and v_tenant_id is null then
    return jsonb_build_object(
      'rows', '[]'::jsonb,
      'page', v_page,
      'page_size', v_page_size,
      'total', 0,
      'total_count', 0,
      'total_pages', 1,
      'source', 'finance_sku_order_details_fast_mtd'
    );
  end if;

  if v_detail_mode then
    return (
      with order_base as (
        select *
        from (
          select
            o.marketplace_order_id,
            o.tenant_id,
            o.marketplace_account_id,
            o.order_created_at,
            timezone('Asia/Jakarta', o.order_created_at)::date as order_date,
            coalesce(nullif(o.order_id::text, ''), nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), o.marketplace_order_id::text) as order_key,
            coalesce(nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), nullif(o.order_id::text, '')) as order_sn,
            coalesce(nullif(o.tracking_number, ''), nullif(o.label_code, ''), nullif(o.package_id, '')) as tracking_number,
            lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) as status_text,
            coalesce(nullif(o.gross_amount, 0), nullif(o.total_amount, 0), nullif(o.paid_amount, 0), 0)::numeric as order_gross,
            case
              when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
              when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
              else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
            end as marketplace_group
          from public.marketplace_orders o
          where o.order_created_at >= v_start_ts
            and o.order_created_at < v_end_ts
            and (v_role = 'service_role' or o.tenant_id = v_tenant_id)
            and (v_account_id is null or o.marketplace_account_id = v_account_id)
            -- Exclude UUID fake orders
            and not (o.order_sn ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
            and not (coalesce(o.order_id, '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        ) o
        where (v_marketplace is null or v_marketplace = '' or o.marketplace_group = public._finance_marketplace_norm_20260624(v_marketplace))
          and o.status_text not like '%cancel%'
          and o.status_text not like '%batal%'
          and o.status_text not like '%unpaid%'
          and o.status_text not like '%in_cancel%'
          and o.status_text not like '%refund%'
          and o.status_text not like '%return%'
      ),
      finance_by_order as (
        select
          ob.marketplace_order_id,
          coalesce(sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)), 0)::numeric as payout,
          coalesce(sum(coalesce(fr.gross_amount, fr.gross_sales, 0)), 0)::numeric as finance_gross
        from order_base ob
        join public.marketplace_finance_reports fr
          on fr.tenant_id = ob.tenant_id
          and fr.marketplace_account_id = ob.marketplace_account_id
          and fr.order_id = ob.order_key
          and coalesce(fr.report_type, '') <> 'statement'
        group by ob.marketplace_order_id
      ),
      line_base as (
        select
          ob.*,
          oi.marketplace_order_item_id,
          coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku_id,
          coalesce(nullif(oi.marketplace_sku, ''), nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku,
          coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as marketplace_seller_sku,
          coalesce(
            nullif(oi.local_sku, ''),
            nullif(oi.mapped_local_sku, ''),
            (
              select m.local_sku
              from public.marketplace_sku_maps m
              where m.tenant_id = oi.tenant_id
                and m.marketplace_account_id = oi.marketplace_account_id
                and m.marketplace_product_id = oi.marketplace_product_id
                and m.marketplace_sku_id = oi.marketplace_sku_id
                and coalesce(m.status, 'active') = 'active'
              limit 1
            )
          ) as local_sku,
          coalesce(nullif(oi.marketplace_product_name, ''), nullif(oi.product_name, ''), nullif(oi.local_product_name, '')) as product_name,
          coalesce(nullif(oi.marketplace_variant_name, ''), nullif(oi.variant_name, ''), nullif(oi.variation_name, '')) as variant_name,
          greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1)::numeric as qty,
          coalesce(
            nullif(oi.gross_amount, 0),
            nullif(oi.paid_amount, 0),
            nullif(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1),
            0
          )::numeric as line_gross
        from order_base ob
        join public.marketplace_order_items oi
          on oi.tenant_id = ob.tenant_id
         and oi.marketplace_order_id = ob.marketplace_order_id
        where (v_marketplace_sku is null or v_marketplace_sku in (
            lower(coalesce(oi.marketplace_sku_id, '')),
            lower(coalesce(oi.marketplace_sku, '')),
            lower(coalesce(oi.remote_sku_id, '')),
            lower(coalesce(oi.marketplace_seller_sku, '')),
            lower(coalesce(oi.seller_sku, ''))
          ))
          and (v_local_sku is null or v_local_sku = lower(coalesce(oi.local_sku, oi.mapped_local_sku, (
              select m.local_sku
              from public.marketplace_sku_maps m
              where m.tenant_id = oi.tenant_id
                and m.marketplace_account_id = oi.marketplace_account_id
                and m.marketplace_product_id = oi.marketplace_product_id
                and m.marketplace_sku_id = oi.marketplace_sku_id
                and coalesce(m.status, 'active') = 'active'
              limit 1
            ), '')))
          and (v_search is null or lower(concat_ws(' ', ob.order_key, ob.order_sn, ob.tracking_number, oi.marketplace_sku_id, oi.marketplace_sku, oi.marketplace_seller_sku, oi.seller_sku, oi.local_sku, oi.mapped_local_sku, oi.marketplace_product_name, oi.product_name, oi.marketplace_variant_name, oi.variant_name)) like '%' || v_search || '%')
      ),
      line_calc as (
        select lb.*, sum(lb.line_gross) over (partition by lb.marketplace_order_id) as order_line_gross
        from line_base lb
      ),
      enriched_base as (
        select
          lc.*,
          coalesce(f.payout, 0)::numeric as order_payout,
          (coalesce(f.payout, 0) <> 0) as has_payout
        from line_calc lc
        left join finance_by_order f on f.marketplace_order_id = lc.marketplace_order_id
      ),
      filtered as (
        select *
        from enriched_base
        where
          v_filter = 'all'
          or (v_filter = 'paid' and has_payout)
          or (v_filter = 'unpaid' and not has_payout)
      ),
      counted as (
        select count(*)::integer as total from filtered
      ),
      paged as (
        select * from filtered
        order by order_created_at desc, order_key, marketplace_order_item_id
        limit v_page_size offset v_offset
      )
      select jsonb_build_object(
        'rows', coalesce(jsonb_agg(
          jsonb_build_object(
            'id', marketplace_order_item_id,
            'order_id', order_key,
            'order_sn', order_sn,
            'marketplace', marketplace_group,
            'marketplace_name', marketplace_group,
            'created_at', order_created_at,
            'order_status', status_text,
            'status', status_text,
            'product_name', product_name,
            'variant_name', variant_name,
            'marketplace_sku', marketplace_sku,
            'local_sku', coalesce(local_sku, 'Unmapped'),
            'qty', qty,
            'gross_amount', line_gross,
            'unit_price', round(line_gross / qty, 2),
            'order_payout', case when order_line_gross > 0 then round((line_gross / order_line_gross) * order_payout, 2) else 0 end,
            'has_payout', has_payout
          )
        ), '[]'::jsonb),
        'page', v_page,
        'page_size', v_page_size,
        'total', (select total from counted),
        'total_count', (select total from counted),
        'total_pages', ceil((select total from counted)::numeric / v_page_size::numeric),
        'source', 'finance_sku_order_details_fast_mtd_detail_mode'
      )
      from paged
    );
  end if;

  -- Default aggregated mode
  return (
    with order_base as (
      select *
      from (
        select
          o.marketplace_order_id,
          o.tenant_id,
          o.marketplace_account_id,
          o.order_created_at,
          timezone('Asia/Jakarta', o.order_created_at)::date as order_date,
          coalesce(nullif(o.order_id::text, ''), nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), o.marketplace_order_id::text) as order_key,
          lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) as status_text,
          case
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
            else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
          end as marketplace_group
        from public.marketplace_orders o
        where o.order_created_at >= v_start_ts
          and o.order_created_at < v_end_ts
          and (v_role = 'service_role' or o.tenant_id = v_tenant_id)
          and (v_account_id is null or o.marketplace_account_id = v_account_id)
          -- Exclude UUID fake orders
          and not (o.order_sn ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
          and not (coalesce(o.order_id, '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
      ) o
      where (v_marketplace is null or v_marketplace = '' or o.marketplace_group = public._finance_marketplace_norm_20260624(v_marketplace))
        and o.status_text not like '%cancel%'
        and o.status_text not like '%batal%'
        and o.status_text not like '%unpaid%'
        and o.status_text not like '%in_cancel%'
        and o.status_text not like '%refund%'
        and o.status_text not like '%return%'
    ),
    finance_by_order as (
      select
        ob.marketplace_order_id,
        coalesce(sum(coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)), 0)::numeric as payout
      from order_base ob
      join public.marketplace_finance_reports fr
        on fr.tenant_id = ob.tenant_id
        and fr.marketplace_account_id = ob.marketplace_account_id
        and fr.order_id = ob.order_key
        and coalesce(fr.report_type, '') <> 'statement'
      group by ob.marketplace_order_id
    ),
    item_base as (
      select
        ob.marketplace_order_id,
        coalesce(nullif(oi.marketplace_sku, ''), nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, ''), nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, ''), '-') as marketplace_sku,
        coalesce(
          nullif(oi.local_sku, ''),
          nullif(oi.mapped_local_sku, ''),
          (
            select m.local_sku
            from public.marketplace_sku_maps m
            where m.tenant_id = oi.tenant_id
              and m.marketplace_account_id = oi.marketplace_account_id
              and m.marketplace_product_id = oi.marketplace_product_id
              and m.marketplace_sku_id = oi.marketplace_sku_id
              and coalesce(m.status, 'active') = 'active'
            limit 1
          )
        ) as local_sku,
        greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1)::numeric as qty,
        coalesce(
          nullif(oi.gross_amount, 0),
          nullif(oi.paid_amount, 0),
          nullif(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1),
          0
        )::numeric as item_gross,
        (coalesce(f.payout, 0) <> 0) as has_payout
      from order_base ob
      join public.marketplace_order_items oi
        on oi.tenant_id = ob.tenant_id
       and oi.marketplace_order_id = ob.marketplace_order_id
      left join finance_by_order f on f.marketplace_order_id = ob.marketplace_order_id
    ),
    filtered as (
      select *
      from item_base
      where
        v_filter = 'all'
        or (v_filter = 'paid' and has_payout)
        or (v_filter = 'unpaid' and not has_payout)
    ),
    grouped as (
      select
        marketplace_sku,
        coalesce(nullif(local_sku, ''), 'Unmapped') as local_sku_display,
        sum(qty)::numeric as total_qty,
        sum(item_gross)::numeric as total_gross,
        count(distinct marketplace_order_id)::integer as order_count
      from filtered
      group by marketplace_sku, coalesce(nullif(local_sku, ''), 'Unmapped')
    ),
    counted as (
      select count(*)::integer as total from grouped
    ),
    paged as (
      select *
      from grouped
      order by total_gross desc, marketplace_sku
      limit v_page_size offset v_offset
    )
    select jsonb_build_object(
      'rows', coalesce(jsonb_agg(
        jsonb_build_object(
          'marketplace_sku', marketplace_sku,
          'local_sku', local_sku_display,
          'qty', total_qty,
          'quantity', total_qty,
          'gross_amount', total_gross,
          'order_count', order_count
        )
      ), '[]'::jsonb),
      'page', v_page,
      'page_size', v_page_size,
      'total', (select total from counted),
      'total_count', (select total from counted),
      'total_pages', ceil((select total from counted)::numeric / v_page_size::numeric),
      'source', 'finance_sku_order_details_fast_mtd_aggregated'
    )
    from paged
  );
end;
$function$;

-- 4. Redefine finance_sku_order_line_details to dynamically lookup SKU mappings
CREATE OR REPLACE FUNCTION public.finance_sku_order_line_details(
  p_start date DEFAULT NULL::date, 
  p_end date DEFAULT NULL::date, 
  p_marketplace text DEFAULT NULL::text, 
  p_account_id uuid DEFAULT NULL::uuid, 
  p_marketplace_sku text DEFAULT NULL::text, 
  p_local_sku text DEFAULT NULL::text, 
  p_search text DEFAULT NULL::text, 
  p_payout_filter text DEFAULT 'all'::text, 
  p_page integer DEFAULT 1, 
  p_page_size integer DEFAULT 25
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '25s'
AS $function$
declare
  v_tenant_id uuid := public.app_current_tenant_id_or_default();
  v_start date := coalesce(p_start, date_trunc('month', now() at time zone 'Asia/Jakarta')::date);
  v_end date := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);
  v_marketplace text := nullif(lower(trim(coalesce(p_marketplace,''))), '');
  v_filter text := lower(trim(coalesce(p_payout_filter,'all')));
  v_local_sku text := lower(trim(coalesce(p_local_sku,'')));
  v_page integer := greatest(1, coalesce(p_page, 1));
  v_page_size integer := least(100, greatest(1, coalesce(p_page_size, 25)));
  v_offset integer;
  v_is_unmapped boolean := false;
  v_start_ts timestamptz;
  v_end_ts   timestamptz;
  v_rows jsonb;
  v_total integer;
begin
  v_offset := (v_page - 1) * v_page_size;
  v_start_ts := v_start::timestamptz at time zone 'Asia/Jakarta';
  v_end_ts   := (v_end + 1)::timestamptz at time zone 'Asia/Jakarta';

  if v_marketplace in ('all','semua','_all','*','-','semua platform') then
    v_marketplace := null;
  end if;

  if v_filter in ('','all','semua','-') then
    v_filter := 'all';
  elsif v_filter in ('settled','released','release','payout','paid','sudah payout') then
    v_filter := 'paid';
  elsif v_filter in ('pending','unpaid','belum payout','no payout','missing payout') then
    v_filter := 'unpaid';
  end if;

  -- Detect UI "unmapped" label -> search for null local_sku in DB
  if v_local_sku in ('unmapped','not_mapped','tidak_dipetakan','belum dipetakan','belum_dipetakan') then
    v_is_unmapped := true;
    v_local_sku := '';
  end if;

  -- Fast path for unmapped: query marketplace_order_items directly
  if v_is_unmapped then
    with base as (
      select
        o.tenant_id,
        o.marketplace,
        coalesce(nullif(o.order_id::text,''), nullif(o.order_sn,''), o.marketplace_order_id::text) as order_key,
        o.order_created_at,
        o.order_status,
        o.marketplace_account_id,
        oi.marketplace_order_item_id,
        oi.marketplace_sku,
        oi.marketplace_seller_sku,
        oi.seller_sku,
        null::text as local_sku,
        oi.marketplace_product_name,
        oi.product_name,
        oi.marketplace_variant_name,
        oi.variant_name,
        greatest(1, coalesce(nullif(oi.quantity,0), nullif(oi.qty,0), 1))::integer as qty,
        coalesce(oi.gross_amount, 0)::numeric as gross_amount,
        coalesce(oi.unit_gross_amount, 0)::numeric as unit_price,
        coalesce(
          nullif(trim(oi.local_sku),''),
          nullif(trim(oi.mapped_local_sku),'')
        ) as item_local_sku,
        oi.marketplace_product_id,
        oi.marketplace_sku_id,
        oi.marketplace_order_id
      from public.marketplace_order_items oi
      join public.marketplace_orders o
        on o.marketplace_order_id = oi.marketplace_order_id
        and o.tenant_id = oi.tenant_id
      where oi.tenant_id = v_tenant_id
        and o.order_created_at >= v_start_ts
        and o.order_created_at <  v_end_ts
        and (p_account_id is null or o.marketplace_account_id = p_account_id)
        and (
          v_marketplace is null
          or public._finance_marketplace_norm_20260624(o.marketplace)
             = public._finance_marketplace_norm_20260624(v_marketplace)
        )
        -- Exclude cancelled/unpaid/batal/failed/refunded orders
        and not (lower(coalesce(o.order_status, '')) ~ '(cancel|canceled|cancelled|batal|return|returned|refund|refunded|unpaid|failed|reject|in_cancel)')
        and not (lower(coalesce(o.payment_status, '')) ~ '(unpaid|failed|cancel|canceled|cancelled|refund|refunded)')
        -- Filter by marketplace SKU if requested
        and (
          p_marketplace_sku is null or p_marketplace_sku = ''
          or lower(coalesce(oi.marketplace_sku, oi.marketplace_seller_sku, oi.seller_sku, '')) = lower(p_marketplace_sku)
        )
        -- Filter by search text if requested
        and (
          p_search is null or p_search = ''
          or coalesce(o.order_id::text, o.order_sn, '') ilike '%' || p_search || '%'
          or coalesce(oi.marketplace_product_name, oi.product_name, '') ilike '%' || p_search || '%'
        )
    ),
    unmapped_base as (
      select b.*
      from base b
      left join lateral (
        select m.local_sku
        from public.marketplace_sku_maps m
        where m.tenant_id = b.tenant_id
          and m.marketplace_account_id = b.marketplace_account_id
          and m.marketplace_product_id = b.marketplace_product_id
          and m.marketplace_sku_id = b.marketplace_sku_id
          and coalesce(m.status, 'active') = 'active'
        limit 1
      ) m on true
      where b.item_local_sku is null and m.local_sku is null
    ),
    with_payout as (
      select
        u.*,
        coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)::numeric as order_payout,
        (fr.finance_report_id is not null) as has_payout
      from unmapped_base u
      left join lateral (
        select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement
        from public.marketplace_finance_reports fr
        where fr.tenant_id = u.tenant_id
          and fr.marketplace_account_id = u.marketplace_account_id
          and (fr.order_id = u.order_key or fr.marketplace_order_id = u.marketplace_order_id)
        limit 1
      ) fr on true
    ),
    filtered as (
      select *
      from with_payout
      where
        v_filter = 'all'
        or (v_filter = 'paid' and has_payout)
        or (v_filter = 'unpaid' and not has_payout)
    ),
    counted as (
      select count(*)::integer as total from filtered
    ),
    paged as (
      select * from filtered
      order by order_created_at desc, order_key, marketplace_order_item_id
      limit v_page_size offset v_offset
    )
    select
      coalesce(jsonb_agg(
        jsonb_build_object(
          'id', marketplace_order_item_id,
          'order_id', order_key,
          'order_sn', order_key,
          'marketplace', marketplace,
          'marketplace_name', marketplace,
          'created_at', order_created_at,
          'order_status', order_status,
          'status', order_status,
          'product_name', coalesce(marketplace_product_name, product_name, '-'),
          'variant_name', coalesce(marketplace_variant_name, variant_name, '-'),
          'marketplace_sku', coalesce(marketplace_sku, marketplace_seller_sku, seller_sku, '-'),
          'local_sku', 'Unmapped',
          'qty', qty,
          'quantity', qty,
          'gross_amount', gross_amount,
          'unit_price', unit_price,
          'order_payout', order_payout,
          'has_payout', has_payout
        ) order by order_created_at desc, order_key
      ), '[]'::jsonb),
      (select coalesce(max(total),0) from counted)
    into v_rows, v_total
    from paged;

    return jsonb_build_object(
      'ok', true,
      'source', 'unmapped_direct_join',
      'rows', v_rows,
      'total', v_total,
      'page', v_page,
      'page_size', v_page_size,
      'total_pages', ceil(v_total::numeric / v_page_size::numeric),
      'total_count', v_total,
      'summary_source', 'marketplace_order_items'
    );
  end if;

  -- Default mapped logic
  with base_items as (
    select
      i.marketplace_order_item_id,
      i.marketplace_order_id,
      o.marketplace,
      o.marketplace_account_id,
      coalesce(nullif(o.order_id::text,''), nullif(o.order_sn,''), o.marketplace_order_id::text) as order_key,
      o.order_created_at,
      o.order_status,
      i.marketplace_product_name,
      i.product_name,
      i.marketplace_variant_name,
      i.variant_name,
      i.marketplace_sku,
      i.marketplace_seller_sku,
      i.seller_sku,
      coalesce(
        nullif(trim(i.local_sku),''),
        nullif(trim(i.mapped_local_sku),''),
        (
          select m.local_sku
          from public.marketplace_sku_maps m
          where m.tenant_id = i.tenant_id
            and m.marketplace_account_id = i.marketplace_account_id
            and m.marketplace_product_id = i.marketplace_product_id
            and m.marketplace_sku_id = i.marketplace_sku_id
            and coalesce(m.status, 'active') = 'active'
          limit 1
        )
      ) as local_sku,
      greatest(1, coalesce(nullif(i.quantity,0), nullif(i.qty,0), 1))::integer as qty,
      coalesce(i.gross_amount, 0)::numeric as gross_amount,
      coalesce(i.unit_gross_amount, 0)::numeric as unit_price
    from public.marketplace_order_items i
    join public.marketplace_orders o
      on o.marketplace_order_id = i.marketplace_order_id
      and o.tenant_id = i.tenant_id
    where i.tenant_id = v_tenant_id
      and o.order_created_at >= v_start_ts
      and o.order_created_at <  v_end_ts
      and (p_account_id is null or o.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or public._finance_marketplace_norm_20260624(o.marketplace)
           = public._finance_marketplace_norm_20260624(v_marketplace)
      )
      -- Exclude cancelled/unpaid/batal/failed/refunded orders
      and not (lower(coalesce(o.order_status, '')) ~ '(cancel|canceled|cancelled|batal|return|returned|refund|refunded|unpaid|failed|reject|in_cancel)')
      and not (lower(coalesce(o.payment_status, '')) ~ '(unpaid|failed|cancel|canceled|cancelled|refund|refunded)')
  ),
  match_sku as (
    select *
    from base_items b
    where
      (
        p_marketplace_sku is null or p_marketplace_sku = ''
        or lower(coalesce(b.marketplace_sku, b.marketplace_seller_sku, b.seller_sku, '')) = lower(p_marketplace_sku)
      )
      and (
        v_local_sku is null or v_local_sku = ''
        or lower(coalesce(b.local_sku,'')) = v_local_sku
      )
      and (
        p_search is null or p_search = ''
        or b.order_key ilike '%' || p_search || '%'
        or coalesce(b.marketplace_product_name, b.product_name, '') ilike '%' || p_search || '%'
      )
  ),
  with_payout as (
    select
      m.*,
      coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)::numeric as order_payout,
      (fr.finance_report_id is not null) as has_payout
    from match_sku m
    left join lateral (
      select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement
      from public.marketplace_finance_reports fr
      where fr.tenant_id = v_tenant_id
        and fr.marketplace_account_id = m.marketplace_account_id
        and (fr.order_id = m.order_key or fr.marketplace_order_id = m.marketplace_order_id)
      limit 1
    ) fr on true
  ),
  filtered as (
    select *
    from with_payout
    where
      v_filter = 'all'
      or (v_filter = 'paid' and has_payout)
      or (v_filter = 'unpaid' and not has_payout)
  ),
  counted as (
    select count(*)::integer as total from filtered
  ),
  paged as (
    select * from filtered
    order by order_created_at desc, order_key, marketplace_order_item_id
    limit v_page_size offset v_offset
  )
  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'id', marketplace_order_item_id,
        'order_id', order_key,
        'order_sn', order_key,
        'marketplace', marketplace,
        'marketplace_name', marketplace,
        'created_at', order_created_at,
        'order_status', order_status,
        'status', order_status,
        'product_name', coalesce(marketplace_product_name, product_name, '-'),
        'variant_name', coalesce(marketplace_variant_name, variant_name, '-'),
        'marketplace_sku', coalesce(marketplace_sku, marketplace_seller_sku, seller_sku, '-'),
        'local_sku', coalesce(local_sku, 'Unmapped'),
        'qty', qty,
        'quantity', qty,
        'gross_amount', gross_amount,
        'unit_price', unit_price,
        'order_payout', order_payout,
        'has_payout', has_payout
      ) order by order_created_at desc, order_key
    ), '[]'::jsonb),
    (select coalesce(max(total),0) from counted)
  into v_rows, v_total
  from paged;

  return jsonb_build_object(
    'ok', true,
    'source', 'mapped_direct_join',
    'rows', v_rows,
    'total', v_total,
    'page', v_page,
    'page_size', v_page_size,
    'total_pages', ceil(v_total::numeric / v_page_size::numeric),
    'total_count', v_total,
    'summary_source', 'marketplace_order_items'
  );
end;
$function$;

-- 5. Redefine finance_dashboard_snapshot_core_20260625 with settlement date filters
CREATE OR REPLACE FUNCTION public.finance_dashboard_snapshot_core_20260625(
  p_start date DEFAULT NULL::date,
  p_end date DEFAULT NULL::date,
  p_marketplace text DEFAULT NULL::text,
  p_account_id uuid DEFAULT NULL::uuid
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '30s'
AS $function$
declare
  v_start date := coalesce(p_start, date_trunc('month', now() at time zone 'Asia/Jakarta')::date);
  v_end date := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);
  v_marketplace text := nullif(lower(trim(coalesce(p_marketplace,''))), '');
  v_user_id uuid;
  v_tenant_id uuid;

  v_base jsonb;
  v_expenses jsonb := '[]'::jsonb;
  v_purchases jsonb := '[]'::jsonb;
  v_cash_flow jsonb := '[]'::jsonb;
  v_breakdown jsonb := '[]'::jsonb;
  v_fee jsonb := '{}'::jsonb;

  v_ops_total numeric := 0;
  v_purchase_total numeric := 0;
  v_payout_total numeric := 0;
  v_hpp_total numeric := 0;

  v_reports_payout numeric := 0;
  v_reports_omzet  numeric := 0;
  
  v_mp_payout_map jsonb := '{}'::jsonb;
  v_marketplaces_arr jsonb := '[]'::jsonb;

  v_sum_platform_fee numeric := 0;
  v_sum_commission_fee numeric := 0;
  v_sum_affiliate_fee numeric := 0;
  v_sum_shipping_fee numeric := 0;
  v_sum_discount_amount numeric := 0;
  v_sum_refund_amount numeric := 0;
  v_total_deductions numeric := 0;
begin
  if v_marketplace in ('all','semua','_all','*') then
    v_marketplace := null;
  end if;

  begin
    v_user_id := nullif(
      coalesce(
        auth.uid()::text,
        (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
      ),
      ''
    )::uuid;
  exception when others then
    v_user_id := null;
  end;

  begin
    v_tenant_id := coalesce(
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'tenant_id')::uuid,
      (
        select u.tenant_id
        from public.users u
        where u.user_id = nullif(
          coalesce(
            auth.uid()::text,
            (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
          ),
          ''
        )::uuid
        limit 1
      )
    );
  exception when others then
    v_tenant_id := null;
  end;

  v_base := public.finance_customer_dashboard_snapshot_v24_6_82o(
    v_start,
    v_end,
    v_marketplace,
    p_account_id
  );

  v_payout_total :=
    case
      when coalesce(
        v_base->'summary'->>'payout_total',
        v_base->'summary'->>'payout_amount',
        v_base->'summary'->>'net_settlement',
        v_base->'summary'->>'received_amount',
        '0'
      ) ~ '^-?[0-9]+(\.[0-9]+)?$'
      then coalesce(
        v_base->'summary'->>'payout_total',
        v_base->'summary'->>'payout_amount',
        v_base->'summary'->>'net_settlement',
        v_base->'summary'->>'received_amount',
        '0'
      )::numeric
      else 0
    end;

  v_hpp_total :=
    case
      when coalesce(
        v_base->'summary'->>'hpp_total',
        v_base->'summary'->>'total_hpp',
        '0'
      ) ~ '^-?[0-9]+(\.[0-9]+)?$'
      then coalesce(
        v_base->'summary'->>'hpp_total',
        v_base->'summary'->>'total_hpp',
        '0'
      )::numeric
      else 0
    end;

  if v_tenant_id is not null then
    with mp_payout as (
      select
        public._finance_marketplace_norm_20260624(fi.marketplace) as marketplace,
        coalesce(sum(coalesce(fi.payout_amount, fi.received_amount, fi.net_settlement, 0)), 0) as payout,
        coalesce(sum(coalesce(fi.gross_amount, 0)), 0) as omzet
      from public.marketplace_finance_reports fi
      where fi.tenant_id = v_tenant_id
        and coalesce(fi.settlement_date::date, fi.period_start::date, fi.created_at::date) between v_start and v_end
        and (
           coalesce(fi.report_type, '') <> 'statement'
           or public._finance_marketplace_norm_20260624(fi.marketplace) = 'tiktok_shop'
        )
        and not (
           public._finance_marketplace_norm_20260624(fi.marketplace) = 'tiktok_shop' 
           and coalesce(fi.report_type, '') = 'order_settlement'
        )
        and (p_account_id is null or fi.marketplace_account_id = p_account_id)
        and (
          v_marketplace is null
          or public._finance_marketplace_norm_20260624(fi.marketplace) = 
             public._finance_marketplace_norm_20260624(v_marketplace)
        )
      group by public._finance_marketplace_norm_20260624(fi.marketplace)
    )
    select 
      coalesce(jsonb_object_agg(marketplace, payout), '{}'::jsonb),
      coalesce(sum(payout), 0),
      coalesce(sum(omzet), 0)
    into v_mp_payout_map, v_reports_payout, v_reports_omzet
    from mp_payout;

    v_marketplaces_arr := coalesce(
      v_base->'marketplace_breakdown', 
      v_base->'by_marketplace', 
      v_base->'marketplaces', 
      '[]'::jsonb
    );
    
    if jsonb_array_length(v_marketplaces_arr) > 0 then
      select jsonb_agg(
        jsonb_set(
          jsonb_set(
            jsonb_set(
              jsonb_set(elem, '{payout_total}', to_jsonb(coalesce((v_mp_payout_map->>public._finance_marketplace_norm_20260624(elem->>'marketplace'))::numeric, 0)), true),
              '{payout_amount}', to_jsonb(coalesce((v_mp_payout_map->>public._finance_marketplace_norm_20260624(elem->>'marketplace'))::numeric, 0)), true),
            '{net_settlement}', to_jsonb(coalesce((v_mp_payout_map->>public._finance_marketplace_norm_20260624(elem->>'marketplace'))::numeric, 0)), true),
          '{received_amount}', to_jsonb(coalesce((v_mp_payout_map->>public._finance_marketplace_norm_20260624(elem->>'marketplace'))::numeric, 0)), true)
      )
      into v_marketplaces_arr
      from jsonb_array_elements(v_marketplaces_arr) elem;
      
      v_base := jsonb_set(v_base, '{marketplace_breakdown}', v_marketplaces_arr, true);
      v_base := jsonb_set(v_base, '{by_marketplace}', v_marketplaces_arr, true);
      v_base := jsonb_set(v_base, '{marketplaces}', v_marketplaces_arr, true);
    end if;

    if v_reports_payout > 0 then
      v_payout_total := v_reports_payout;
      v_base := jsonb_set(v_base, '{summary,payout_total}', to_jsonb(v_reports_payout), true);
      v_base := jsonb_set(v_base, '{summary,payout_amount}', to_jsonb(v_reports_payout), true);
      v_base := jsonb_set(v_base, '{summary,net_settlement}', to_jsonb(v_reports_payout), true);
      v_base := jsonb_set(v_base, '{summary,received_amount}', to_jsonb(v_reports_payout), true);
      v_base := jsonb_set(v_base, '{payout_total}', to_jsonb(v_reports_payout), true);
    end if;

    select
      coalesce(sum(coalesce(fi.platform_fee, 0)), 0),
      coalesce(sum(coalesce(fi.commission_fee, 0)), 0),
      coalesce(sum(coalesce(fi.affiliate_fee, 0)), 0),
      coalesce(sum(coalesce(fi.shipping_fee, 0)), 0),
      coalesce(sum(coalesce(fi.discount_amount, 0)), 0),
      coalesce(sum(coalesce(fi.refund_amount, 0)), 0)
    into
      v_sum_platform_fee,
      v_sum_commission_fee,
      v_sum_affiliate_fee,
      v_sum_shipping_fee,
      v_sum_discount_amount,
      v_sum_refund_amount
    from public.marketplace_finance_reports fi
    where fi.tenant_id = v_tenant_id
      and coalesce(fi.settlement_date::date, fi.period_start::date, fi.created_at::date) between v_start and v_end
      and coalesce(fi.report_type, '') <> 'statement'
      and (p_account_id is null or fi.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or public._finance_marketplace_norm_20260624(fi.marketplace) =
           public._finance_marketplace_norm_20260624(v_marketplace)
      );

    v_total_deductions := v_sum_platform_fee + v_sum_commission_fee + v_sum_affiliate_fee + v_sum_shipping_fee + v_sum_discount_amount + v_sum_refund_amount;

    v_base := jsonb_set(v_base, '{deductions}', jsonb_build_object(
      'platform_fee', v_sum_platform_fee,
      'commission_fee', v_sum_commission_fee,
      'affiliate_fee', v_sum_affiliate_fee,
      'shipping_fee', v_sum_shipping_fee,
      'discount_amount', v_sum_discount_amount,
      'refund_amount', v_sum_refund_amount,
      'service_fee', 0,
      'voucher_amount', 0,
      'adjustment_amount', 0,
      'total_deductions', v_total_deductions
    ), true);

    v_base := jsonb_set(v_base, '{fee_breakdown}', jsonb_build_object(
      'platform_fee', v_sum_platform_fee,
      'commission_fee', v_sum_commission_fee,
      'affiliate_fee', v_sum_affiliate_fee,
      'shipping_fee', v_sum_shipping_fee,
      'discount_amount', v_sum_discount_amount,
      'refund_amount', v_sum_refund_amount,
      'service_fee', 0,
      'voucher_amount', 0,
      'adjustment_amount', 0,
      'total_deductions', v_total_deductions
    ), true);
  end if;

  if v_tenant_id is not null then
    select
      coalesce(
        jsonb_agg(
          to_jsonb(e)
          order by coalesce(e.expense_date, e.paid_at, e.created_at::date) desc, e.created_at desc
        ),
        '[]'::jsonb
      ),
      coalesce(sum(e.amount),0)
    into v_expenses, v_ops_total
    from public.finance_operational_expenses e
    where e.tenant_id = v_tenant_id
      and coalesce(e.expense_date, e.paid_at, e.created_at::date) between v_start and v_end
      and lower(coalesce(e.status,'active')) not in ('cancelled','canceled','deleted','void','voided','rejected');

    select
      coalesce(
        jsonb_agg(
          to_jsonb(p)
          order by coalesce(p.tanggal, p.created_at::date) desc, p.created_at desc
        ),
        '[]'::jsonb
      ),
      coalesce(sum(p.total_pembelian),0)
    into v_purchases, v_purchase_total
    from public.purchases p
    where p.tenant_id = v_tenant_id
      and coalesce(p.tanggal, p.created_at::date) between v_start and v_end
      and lower(coalesce(p.status,'')) in (
        'verified','verified_finance','finance_verified','approved','approved_by_finance',
        'finance_approved','paid','completed','done','selesai','finish','finished'
      );
  end if;

  with fee as (
    select
      coalesce(sum(platform_fee),0)      as platform_fee,
      coalesce(sum(commission_fee),0)    as commission_fee,
      0::numeric                         as service_fee,
      coalesce(sum(affiliate_fee),0)     as affiliate_fee,
      coalesce(sum(shipping_fee),0)      as shipping_fee,
      0::numeric                         as voucher_amount,
      coalesce(sum(discount_amount),0)   as discount_amount,
      coalesce(sum(refund_amount),0)     as refund_amount,
      coalesce(sum(adjustment_amount),0) as adjustment_amount
    from public.marketplace_finance_reports fi
    where fi.tenant_id = v_tenant_id
      and coalesce(fi.settlement_date::date, fi.period_start::date, fi.created_at::date) between v_start and v_end
      and coalesce(fi.report_type, '') <> 'statement'
      and (p_account_id is null or fi.marketplace_account_id = p_account_id)
      and (
        v_marketplace is null
        or public._finance_marketplace_norm_20260624(fi.marketplace) = 
           public._finance_marketplace_norm_20260624(v_marketplace)
      )
  )
  select jsonb_build_object(
    'platform_fee', platform_fee,
    'commission_fee', commission_fee,
    'service_fee', service_fee,
    'affiliate_fee', affiliate_fee,
    'shipping_fee', shipping_fee,
    'voucher_amount', voucher_amount,
    'discount_amount', discount_amount,
    'refund_amount', refund_amount,
    'adjustment_amount', adjustment_amount,
    'total_deductions',
      platform_fee + commission_fee + service_fee + affiliate_fee + shipping_fee
      + voucher_amount + discount_amount + refund_amount + adjustment_amount
  )
  into v_fee
  from fee;

  with marketplace_rows as (
    select
      elem,
      coalesce(
        elem->>'marketplace',
        elem->>'marketplace_name',
        elem->>'name',
        elem->>'label',
        'Marketplace'
      ) as marketplace_label,
      case
        when coalesce(
          elem->>'payout_total',
          elem->>'payout_amount',
          elem->>'net_settlement',
          elem->>'received_amount',
          elem->>'payout',
          '0'
        ) ~ '^-?[0-9]+(\.[0-9]+)?$'
        then coalesce(
          elem->>'payout_total',
          elem->>'payout_amount',
          elem->>'net_settlement',
          elem->>'received_amount',
          elem->>'payout',
          '0'
        )::numeric
        else 0
      end as amount
    from jsonb_array_elements(
      coalesce(
        v_base->'by_marketplace',
        v_base->'marketplace_breakdown',
        v_base->'marketplaces',
        '[]'::jsonb
      )
    ) as elem
  ),
  rows as (
    select jsonb_build_object(
      'date', v_start,
      'category', marketplace_label,
      'marketplace', marketplace_label,
      'type', 'income',
      'amount', amount,
      'source', 'marketplace_by_marketplace'
    ) as row
    from marketplace_rows
    where amount <> 0

    union all
    select jsonb_build_object(
      'date', v_start,
      'category', 'Biaya operasional',
      'type', 'expense',
      'amount', -v_ops_total,
      'source', 'operational_expenses'
    ) as row
    where v_ops_total <> 0

    union all
    select jsonb_build_object(
      'date', v_start,
      'category', 'Pembelian bahan/barang',
      'type', 'expense',
      'amount', -v_purchase_total,
      'source', 'purchases'
    ) as row
    where v_purchase_total <> 0
  )
  select coalesce(jsonb_agg(row order by (row->>'amount')::numeric desc), '[]'::jsonb)
    into v_cash_flow
  from rows;

  return jsonb_build_object(
    'summary', jsonb_build_object(
      'omzet_total', coalesce(v_base->'summary'->>'omzet_total', '0')::numeric,
      'gross_sales', coalesce(v_base->'summary'->>'omzet_total', '0')::numeric,
      'gross_total', coalesce(v_base->'summary'->>'omzet_total', '0')::numeric,
      'gross_amount', coalesce(v_base->'summary'->>'omzet_total', '0')::numeric,
      'order_count', coalesce(v_base->'summary'->>'order_count', '0')::numeric,
      'orders_count', coalesce(v_base->'summary'->>'order_count', '0')::numeric,
      'all_orders_count', coalesce(v_base->'summary'->>'order_count', '0')::numeric,
      'payout_total', v_payout_total,
      'payout_amount', v_payout_total,
      'received_amount', v_payout_total,
      'net_settlement', v_payout_total,
      'finance_order_count', coalesce(v_base->'summary'->>'finance_order_count', '0')::numeric,
      'finance_orders_count', coalesce(v_base->'summary'->>'finance_order_count', '0')::numeric,
      'operational_cost', v_ops_total,
      'expense_total', v_ops_total,
      'purchase_total', v_purchase_total,
      'pembelian_total', v_purchase_total,
      'hpp_total', v_hpp_total,
      'total_hpp', v_hpp_total,
      'net_profit', v_payout_total - v_hpp_total - v_ops_total - v_purchase_total,
      'profit', v_payout_total - v_hpp_total - v_ops_total - v_purchase_total,
      'net_margin_percent', case when v_payout_total > 0 then round(((v_payout_total - v_hpp_total - v_ops_total - v_purchase_total) / v_payout_total) * 100, 2) else 0 end,
      'summary_policy', 'omzet_by_order_date_payout_by_settlement_date_v2'
    ),
    'by_marketplace', coalesce(v_base->'by_marketplace', '[]'::jsonb),
    'marketplace_breakdown', coalesce(v_base->'by_marketplace', '[]'::jsonb),
    'marketplaces', coalesce(v_base->'by_marketplace', '[]'::jsonb),
    'operational_expenses', v_expenses,
    'expenses', v_expenses,
    'purchases', v_purchases,
    'pembelian', v_purchases,
    'cash_adjustments', coalesce(v_base->'cash_adjustments', '[]'::jsonb),
    'company_cash_adjustments', coalesce(v_base->'cash_adjustments', '[]'::jsonb),
    'cash_flow', v_cash_flow,
    'fee_breakdown', v_fee,
    'deductions', v_fee,
    'source', 'finance_dashboard_snapshot_core_20260625_settlement_payout_v2',
    'ok', true
  );
end;
$function$;
