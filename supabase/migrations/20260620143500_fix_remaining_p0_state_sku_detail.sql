-- Remaining P0 runtime fixes:
-- - expose lightweight tenant-scoped dispatcher pull state for UI last-pull labels
-- - add a fast SKU line-detail RPC for the finance SKU modal
-- No destructive SQL and no HPP fallback/import.

create or replace function public.marketplace_dispatcher_pull_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_tenant_id uuid;
  v_role text := coalesce(nullif(v_claims->>'role', ''), nullif(current_setting('role', true), ''), current_user);
  v_order jsonb;
  v_finance jsonb;
begin
  select coalesce(
    case
      when (v_claims->>'tenant_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (v_claims->>'tenant_id')::uuid
      else null::uuid
    end,
    (select u.tenant_id from public.users u where u.user_id = auth.uid() limit 1)
  )
  into v_tenant_id;

  if v_role <> 'service_role' and v_tenant_id is null then
    return jsonb_build_object(
      'ok', false,
      'source', 'marketplace_dispatcher_pull_state',
      'order_states', '[]'::jsonb,
      'finance_states', '[]'::jsonb,
      'summary', jsonb_build_object()
    );
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'tenant_id', s.tenant_id,
    'marketplace_account_id', s.marketplace_account_id,
    'marketplace', s.marketplace,
    'last_success_at', s.last_success_at,
    'updated_at', s.updated_at,
    'last_mode', s.last_mode,
    'last_error', s.last_error,
    'failure_count', s.failure_count,
    'next_run_at', s.next_run_at,
    'last_order_updated_at', o.last_order_updated_at
  ) order by coalesce(s.last_success_at, s.updated_at) desc nulls last), '[]'::jsonb)
  into v_order
  from public.marketplace_order_sync_state s
  left join lateral (
    select max(mo.updated_at) as last_order_updated_at
    from public.marketplace_orders mo
    where mo.tenant_id = s.tenant_id
      and mo.marketplace_account_id = s.marketplace_account_id
      and mo.order_created_at >= timezone('Asia/Jakarta', now())::date - interval '90 days'
  ) o on true
  where (v_role = 'service_role' or s.tenant_id = v_tenant_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'tenant_id', s.tenant_id,
    'marketplace_account_id', s.marketplace_account_id,
    'marketplace', s.marketplace,
    'finance_status', s.finance_status,
    'last_success_at', s.last_success_at,
    'updated_at', s.updated_at,
    'last_mode', s.last_mode,
    'last_error', s.last_error,
    'failure_count', s.failure_count,
    'checked_total', s.checked_total,
    'synced_total', s.synced_total,
    'failed_total', s.failed_total,
    'next_run_at', s.next_run_at,
    'last_finance_updated_at', coalesce(s.last_success_at, s.updated_at)
  ) order by coalesce(s.last_success_at, s.updated_at) desc nulls last), '[]'::jsonb)
  into v_finance
  from public.marketplace_finance_sync_state s
  where (v_role = 'service_role' or s.tenant_id = v_tenant_id);

  return jsonb_build_object(
    'ok', true,
    'source', 'marketplace_dispatcher_pull_state',
    'tenant_id', v_tenant_id,
    'generated_at', now(),
    'order_states', v_order,
    'finance_states', v_finance,
    'summary', jsonb_build_object(
      'last_order_pull_at', (
        select max((row->>'last_success_at')::timestamptz)
        from jsonb_array_elements(v_order) row
        where nullif(row->>'last_success_at', '') is not null
      ),
      'last_finance_pull_at', (
        select max((row->>'last_success_at')::timestamptz)
        from jsonb_array_elements(v_finance) row
        where nullif(row->>'last_success_at', '') is not null
      ),
      'last_payout_update_at', (
        select max((row->>'last_finance_updated_at')::timestamptz)
        from jsonb_array_elements(v_finance) row
        where nullif(row->>'last_finance_updated_at', '') is not null
      )
    )
  );
end;
$$;

revoke all on function public.marketplace_dispatcher_pull_state() from public;
grant execute on function public.marketplace_dispatcher_pull_state() to authenticated, service_role;

create or replace function public.finance_sku_order_line_details(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null,
  p_marketplace_sku text default null,
  p_local_sku text default null,
  p_search text default null,
  p_payout_filter text default 'all',
  p_page integer default 1,
  p_page_size integer default 25
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
set statement_timeout = '6s'
as $$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_tenant_id uuid;
  v_role text := coalesce(nullif(v_claims->>'role', ''), nullif(current_setting('role', true), ''), current_user);
  v_start date := coalesce(p_start, date_trunc('month', timezone('Asia/Jakarta', now()))::date);
  v_end date := coalesce(p_end, timezone('Asia/Jakarta', now())::date);
  v_start_ts timestamptz;
  v_end_ts timestamptz;
  v_marketplace text;
  v_marketplace_sku_raw text := nullif(trim(coalesce(p_marketplace_sku, '')), '');
  v_local_sku_raw text := nullif(trim(coalesce(p_local_sku, '')), '');
  v_marketplace_sku text := lower(nullif(trim(coalesce(p_marketplace_sku, '')), ''));
  v_local_sku text := lower(nullif(trim(coalesce(p_local_sku, '')), ''));
  v_search text := lower(nullif(trim(coalesce(p_search, '')), ''));
  v_filter text := lower(trim(coalesce(p_payout_filter, 'all')));
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer := least(greatest(coalesce(p_page_size, 25), 1), 25);
  v_offset integer;
begin
  select coalesce(
    case
      when (v_claims->>'tenant_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (v_claims->>'tenant_id')::uuid
      else null::uuid
    end,
    (select u.tenant_id from public.users u where u.user_id = auth.uid() limit 1)
  )
  into v_tenant_id;

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

  if v_role <> 'service_role' and v_tenant_id is null then
    return jsonb_build_object('rows', '[]'::jsonb, 'page', v_page, 'page_size', v_page_size, 'total', 0, 'total_count', 0, 'total_pages', 1, 'source', 'finance_sku_order_line_details');
  end if;

  if v_marketplace_sku is null and v_local_sku is null and v_search is null then
    return jsonb_build_object('rows', '[]'::jsonb, 'page', v_page, 'page_size', v_page_size, 'total', 0, 'total_count', 0, 'total_pages', 1, 'source', 'finance_sku_order_line_details');
  end if;

  return (
    with candidate_lines as materialized (
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
          case
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%shopee%' then 'shopee'
            when lower(regexp_replace(coalesce(o.marketplace, ''), '[^a-z0-9]+', '', 'g')) like '%tiktok%' then 'tiktok'
            else lower(regexp_replace(coalesce(o.marketplace, 'unknown'), '[^a-z0-9]+', '', 'g'))
          end as marketplace_group,
          oi.marketplace_order_item_id,
          coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku_id,
          coalesce(nullif(oi.marketplace_sku, ''), nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as marketplace_sku,
          coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as marketplace_seller_sku,
          coalesce(nullif(oi.local_sku, ''), nullif(oi.mapped_local_sku, '')) as local_sku,
          coalesce(nullif(oi.marketplace_product_name, ''), nullif(oi.product_name, ''), nullif(oi.local_product_name, '')) as product_name,
          coalesce(nullif(oi.marketplace_variant_name, ''), nullif(oi.variant_name, ''), nullif(oi.variation_name, '')) as variant_name,
          greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1)::numeric as qty,
          coalesce(
            nullif(oi.gross_amount, 0),
            nullif(oi.paid_amount, 0),
            nullif(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1),
            0
          )::numeric as line_gross
        from public.marketplace_order_items oi
        join public.marketplace_orders o
          on o.tenant_id = oi.tenant_id
         and o.marketplace_order_id = oi.marketplace_order_id
        where o.order_created_at >= v_start_ts
          and o.order_created_at < v_end_ts
          and (v_role = 'service_role' or oi.tenant_id = v_tenant_id)
          and (p_account_id is null or oi.marketplace_account_id = p_account_id)
          and (v_role = 'service_role' or o.tenant_id = v_tenant_id)
          and (p_account_id is null or o.marketplace_account_id = p_account_id)
          and (
            v_marketplace_sku is null
            or oi.marketplace_sku_id = v_marketplace_sku_raw
            or oi.marketplace_sku = v_marketplace_sku_raw
            or oi.remote_sku_id = v_marketplace_sku_raw
            or oi.marketplace_seller_sku = v_marketplace_sku_raw
            or oi.seller_sku = v_marketplace_sku_raw
            or v_marketplace_sku in (
                lower(coalesce(oi.marketplace_sku_id, '')),
                lower(coalesce(oi.marketplace_sku, '')),
                lower(coalesce(oi.remote_sku_id, '')),
                lower(coalesce(oi.marketplace_seller_sku, '')),
                lower(coalesce(oi.seller_sku, ''))
              )
          )
          and (
            v_local_sku is null
            or oi.local_sku = v_local_sku_raw
            or oi.mapped_local_sku = v_local_sku_raw
            or v_local_sku = lower(coalesce(oi.local_sku, oi.mapped_local_sku, ''))
          )
          and (
            v_search is null or lower(concat_ws(' ', o.order_id, o.order_sn, o.external_order_id, o.tracking_number, oi.marketplace_sku_id, oi.marketplace_sku, oi.marketplace_seller_sku, oi.seller_sku, oi.local_sku, oi.mapped_local_sku, oi.marketplace_product_name, oi.product_name, oi.marketplace_variant_name, oi.variant_name)) like '%' || v_search || '%'
          )
          and (
            v_filter <> 'unpaid' or not exists (
              select 1
              from public.marketplace_finance_reports fr
              where fr.tenant_id = o.tenant_id
                and fr.marketplace_account_id = o.marketplace_account_id
                and (
                  fr.marketplace_order_id = o.marketplace_order_id
                  or fr.order_id = coalesce(nullif(o.order_id::text, ''), nullif(o.order_sn::text, ''), nullif(o.external_order_id::text, ''), o.marketplace_order_id::text)
                )
            )
          )
      ) x
      where (v_marketplace is null or x.marketplace_group = v_marketplace)
        and x.status_text not like '%cancel%'
        and x.status_text not like '%batal%'
        and x.status_text not like '%unpaid%'
        and x.status_text not like '%in_cancel%'
    ),
    candidate_orders as materialized (
      select distinct tenant_id, marketplace_account_id, marketplace_group, marketplace_order_id, order_key
      from candidate_lines
    ),
    order_line_totals as materialized (
      select
        oi.tenant_id,
        oi.marketplace_order_id,
        coalesce(sum(coalesce(
          nullif(oi.gross_amount, 0),
          nullif(oi.paid_amount, 0),
          nullif(oi.unit_gross_amount, 0) * greatest(coalesce(nullif(oi.qty, 0), nullif(oi.quantity, 0), 1), 1),
          0
        )), 0)::numeric as order_line_gross
      from public.marketplace_order_items oi
      join candidate_orders co
        on co.tenant_id = oi.tenant_id
       and co.marketplace_order_id = oi.marketplace_order_id
      group by oi.tenant_id, oi.marketplace_order_id
    ),
    finance_matches as materialized (
      select
        co.marketplace_order_id,
        coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)::numeric as payout
      from candidate_orders co
      join public.marketplace_finance_reports fr
        on fr.tenant_id = co.tenant_id
       and fr.marketplace_account_id = co.marketplace_account_id
       and fr.marketplace_order_id = co.marketplace_order_id
      where v_filter <> 'unpaid'
      union all
      select
        co.marketplace_order_id,
        coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)::numeric as payout
      from candidate_orders co
      join public.marketplace_finance_reports fr
        on fr.tenant_id = co.tenant_id
       and fr.marketplace_account_id = co.marketplace_account_id
       and fr.order_id = co.order_key
       and (fr.marketplace_order_id is null or fr.marketplace_order_id <> co.marketplace_order_id)
      where v_filter <> 'unpaid'
    ),
    finance_by_order as materialized (
      select
        marketplace_order_id,
        coalesce(sum(payout), 0)::numeric as payout,
        true as has_payout
      from finance_matches
      group by marketplace_order_id
    ),
    hpp_sku as materialized (
      select tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
             max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
             max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
      from public.marketplace_variant_hpp_mappings
      where coalesce(is_active, true) is true and nullif(marketplace_sku_id, '') is not null
      group by tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, ''))
    ),
    hpp_seller as materialized (
      select tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
             max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
             max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
      from public.marketplace_variant_hpp_mappings
      where coalesce(is_active, true) is true and nullif(marketplace_seller_sku, '') is not null
      group by tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, ''))
    ),
    hpp_local as materialized (
      select tenant_id, marketplace_account_id, lower(nullif(local_sku, '')) as local_sku,
             max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
             max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
      from public.marketplace_variant_hpp_mappings
      where coalesce(is_active, true) is true and nullif(local_sku, '') is not null
      group by tenant_id, marketplace_account_id, lower(nullif(local_sku, ''))
    ),
    enriched as (
      select
        cl.*,
        coalesce(olt.order_line_gross, cl.line_gross, 0)::numeric as order_line_gross,
        coalesce(f.payout, 0)::numeric as order_payout,
        coalesce(f.has_payout, false) as has_payout,
        coalesce(hs.hpp, hsel.hpp, hl.hpp, 0)::numeric as unit_hpp,
        coalesce(hs.target_margin, hsel.target_margin, hl.target_margin, 0)::numeric as target_margin
      from candidate_lines cl
      left join order_line_totals olt
        on olt.tenant_id = cl.tenant_id
       and olt.marketplace_order_id = cl.marketplace_order_id
      left join finance_by_order f on f.marketplace_order_id = cl.marketplace_order_id
      left join hpp_sku hs on hs.tenant_id = cl.tenant_id and hs.marketplace_account_id = cl.marketplace_account_id and hs.marketplace_sku_id = lower(nullif(cl.marketplace_sku_id, ''))
      left join hpp_seller hsel on hsel.tenant_id = cl.tenant_id and hsel.marketplace_account_id = cl.marketplace_account_id and hsel.marketplace_seller_sku = lower(nullif(cl.marketplace_seller_sku, ''))
      left join hpp_local hl on hl.tenant_id = cl.tenant_id and hl.marketplace_account_id = cl.marketplace_account_id and hl.local_sku = lower(nullif(cl.local_sku, ''))
    ),
    filtered as (
      select *
      from enriched
      where (v_filter = 'all' or (v_filter = 'paid' and has_payout) or (v_filter = 'unpaid' and not has_payout))
    ),
    paged_with_extra as (
      select *
      from filtered
      order by order_created_at desc, order_key, marketplace_order_item_id
      offset v_offset
      limit v_page_size + 1
    ),
    paged as (
      select *
      from paged_with_extra
      order by order_created_at desc, order_key, marketplace_order_item_id
      limit v_page_size
    ),
    page_meta as (
      select
        (select count(*)::integer from paged) as visible_count,
        (select count(*)::integer from paged_with_extra) > v_page_size as has_more
    )
    select jsonb_build_object(
      'rows', coalesce(jsonb_agg(jsonb_build_object(
        'source', 'finance_sku_order_line_details',
        'sku_detail_source', 'finance_sku_order_line_details',
        'order', order_key,
        'order_id', order_key,
        'order_sn', order_sn,
        'marketplace_order_id', marketplace_order_id,
        'marketplace_order_item_id', marketplace_order_item_id,
        'resi', tracking_number,
        'tracking_number', tracking_number,
        'order_date', order_created_at,
        'order_created_at', order_created_at,
        'marketplace', marketplace_group,
        'marketplace_account_id', marketplace_account_id,
        'local_sku', coalesce(nullif(local_sku, ''), '-'),
        'sku', coalesce(nullif(local_sku, ''), nullif(marketplace_sku_id, ''), nullif(marketplace_seller_sku, ''), '-'),
        'marketplace_sku_id', marketplace_sku_id,
        'marketplace_sku', marketplace_sku,
        'marketplace_seller_sku', marketplace_seller_sku,
        'product_name', product_name,
        'variant_name', variant_name,
        'marketplace_variation_name', variant_name,
        'qty', qty,
        'quantity', qty,
        'gross', line_gross,
        'gross_amount', line_gross,
        'gross_total', line_gross,
        'gross_per_item', case when qty > 0 then line_gross / qty else 0 end,
        'payout', case when has_payout and order_line_gross > 0 then order_payout * (line_gross / order_line_gross) else 0 end,
        'payout_amount', case when has_payout and order_line_gross > 0 then order_payout * (line_gross / order_line_gross) else 0 end,
        'payout_per_item', case when has_payout and order_line_gross > 0 and qty > 0 then (order_payout * (line_gross / order_line_gross)) / qty else 0 end,
        'hpp', unit_hpp * qty,
        'hpp_total', unit_hpp * qty,
        'hpp_per_item', unit_hpp,
        'unit_hpp', unit_hpp,
        'hpp_status', case when unit_hpp > 0 then 'HPP mapping' else 'HPP belum mapping' end,
        'target_margin_percent', target_margin,
        'finance_status', case when has_payout then 'SETTLED' else 'PENDING_PAYOUT' end,
        'payout_status', case when has_payout then 'SETTLED' else 'PENDING_PAYOUT' end
      ) order by order_created_at desc, order_key, marketplace_order_item_id)
        filter (where marketplace_order_item_id is not null), '[]'::jsonb),
      'page', v_page,
      'page_size', v_page_size,
      'total', v_offset + page_meta.visible_count + case when page_meta.has_more then 1 else 0 end,
      'total_count', v_offset + page_meta.visible_count + case when page_meta.has_more then 1 else 0 end,
      'total_pages', case when page_meta.has_more then v_page + 1 else greatest(v_page, 1) end,
      'has_more', page_meta.has_more,
      'source', 'finance_sku_order_line_details'
    )
    from page_meta
    left join paged on true
    group by page_meta.visible_count, page_meta.has_more
  );
end;
$$;

revoke all on function public.finance_sku_order_line_details(date, date, text, uuid, text, text, text, text, integer, integer) from public;
grant execute on function public.finance_sku_order_line_details(date, date, text, uuid, text, text, text, text, integer, integer) to authenticated, service_role;
