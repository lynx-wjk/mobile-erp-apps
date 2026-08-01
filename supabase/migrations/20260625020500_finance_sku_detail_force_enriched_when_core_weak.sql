create or replace function public.finance_sku_order_details(
  p_start date default null,
  p_end date default null,
  p_marketplace text default null,
  p_account_id uuid default null,
  p_marketplace_sku text default null,
  p_local_sku text default null,
  p_search text default null,
  p_payout_filter text default 'all',
  p_page integer default 1,
  p_page_size integer default 20
)
returns jsonb
language plpgsql
security definer
set search_path = public
set statement_timeout = '25s'
as $$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_user_id uuid;
  v_tenant_id uuid;
  v_role text := coalesce(nullif(v_claims->>'role',''), '');
  v_start date := coalesce(p_start, date_trunc('month', now() at time zone 'Asia/Jakarta')::date);
  v_end date := coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date);
  v_start_ts timestamptz := (coalesce(p_start, date_trunc('month', now() at time zone 'Asia/Jakarta')::date)::timestamp at time zone 'Asia/Jakarta');
  v_end_ts timestamptz := ((coalesce(p_end, (now() at time zone 'Asia/Jakarta')::date) + 1)::timestamp at time zone 'Asia/Jakarta');

  v_marketplace text := public._finance_marketplace_norm_20260624(p_marketplace);
  v_account_id uuid := p_account_id;
  v_msku text := lower(nullif(trim(coalesce(p_marketplace_sku,'')), ''));
  v_lsku text := lower(nullif(trim(coalesce(p_local_sku,'')), ''));
  v_search text := lower(nullif(trim(coalesce(p_search,'')), ''));
  v_filter text := lower(trim(coalesce(p_payout_filter,'all')));
  v_page integer := greatest(coalesce(p_page,1),1);
  v_page_size integer := least(greatest(coalesce(p_page_size,20),1),25);
  v_offset integer := (greatest(coalesce(p_page,1),1)-1) * least(greatest(coalesce(p_page_size,20),1),25);
  v_detail boolean;
  v_core jsonb;
  v_core_rows integer := 0;
  v_core_has_weak_fields boolean := false;
  v_result jsonb;
begin
  v_detail := v_msku is not null or v_lsku is not null or v_search is not null;

  if not v_detail then
    return public.finance_sku_order_details_group_20260625(
      p_start,p_end,p_marketplace,p_account_id,p_marketplace_sku,p_local_sku,p_search,p_payout_filter,p_page,p_page_size
    );
  end if;

  v_core := public.finance_sku_order_details_core_20260625(
    p_start,p_end,p_marketplace,p_account_id,p_marketplace_sku,p_local_sku,p_search,p_payout_filter,p_page,p_page_size
  );

  v_core_rows := coalesce(jsonb_array_length(coalesce(v_core->'rows','[]'::jsonb)),0);

  select exists (
    select 1
    from jsonb_array_elements(coalesce(v_core->'rows','[]'::jsonb)) r
    where coalesce(r->>'gross_sales', r->>'gross_total', r->>'gross_amount', '') = ''
       or coalesce(r->>'product_name', r->>'product', r->>'title', '') = ''
  )
  into v_core_has_weak_fields;

  -- Kalau core detail sehat, pakai core. Kalau core ada rows tapi field penting kosong, paksa enriched fallback.
  if v_core_rows > 0 and not v_core_has_weak_fields then
    return jsonb_set(
      v_core,
      '{source}',
      to_jsonb((coalesce(v_core->>'source','finance_sku_order_details_core_20260625') || '+core_hit_strong')::text),
      true
    );
  end if;

  begin
    v_user_id := nullif(coalesce(auth.uid()::text, v_claims->>'sub'), '')::uuid;
  exception when others then
    v_user_id := null;
  end;

  select u.tenant_id
    into v_tenant_id
  from public.users u
  where u.user_id = v_user_id
  limit 1;

  if v_role <> 'service_role' and v_tenant_id is null then
    return jsonb_build_object(
      'rows','[]'::jsonb,
      'page',v_page,
      'page_size',v_page_size,
      'total',0,
      'total_count',0,
      'total_pages',1,
      'source','finance_sku_order_details_detail_enriched_no_tenant_20260625'
    );
  end if;

  with order_base as (
    select
      o.marketplace_order_id,
      o.tenant_id,
      o.marketplace_account_id,
      public._finance_marketplace_norm_20260624(o.marketplace) as marketplace,
      o.order_created_at,
      coalesce(nullif(o.order_id::text,''), nullif(o.order_sn::text,''), nullif(o.external_order_id::text,''), o.marketplace_order_id::text) as order_key,
      coalesce(nullif(o.order_sn::text,''), nullif(o.external_order_id::text,''), nullif(o.order_id::text,'')) as order_sn,
      coalesce(nullif(o.tracking_number,''), nullif(o.label_code,''), nullif(o.package_id,'')) as tracking_number,
      lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) as status_text,
      coalesce(nullif(o.order_status,''), nullif(o.status,''), nullif(o.order_status_label,''), nullif(o.fulfillment_status,''), 'UNKNOWN') as order_status_raw,
      coalesce(nullif(o.payment_status,''), '') as payment_status_raw,
      coalesce(nullif(o.fulfillment_status,''), '') as fulfillment_status_raw,
      coalesce(nullif(o.gross_amount,0), nullif(o.total_amount,0), nullif(o.paid_amount,0), 0)::numeric as order_gross
    from public.marketplace_orders o
    where o.order_created_at >= v_start_ts
      and o.order_created_at < v_end_ts
      and (v_role = 'service_role' or o.tenant_id = v_tenant_id)
      and (v_account_id is null or o.marketplace_account_id = v_account_id)
      and (v_marketplace is null or public._finance_marketplace_norm_20260624(o.marketplace) = v_marketplace)
      and lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) not like '%cancel%'
      and lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) not like '%batal%'
      and lower(concat_ws(' ', o.order_status, o.status, o.payment_status, o.fulfillment_status, o.order_status_label)) not like '%unpaid%'
  ),
  finance_by_order as (
    select
      fi.tenant_id,
      fi.marketplace_account_id,
      coalesce(nullif(fi.order_id,''), nullif(fi.order_sn,''), nullif(fi.external_order_id,''), nullif(fi.remote_order_id,'')) as order_key,
      coalesce(sum(coalesce(fi.received_amount, fi.net_settlement, 0)),0)::numeric as payout,
      coalesce(sum(coalesce(fi.gross_amount,0)),0)::numeric as finance_gross
    from public.marketplace_finance_items fi
    where (v_role = 'service_role' or fi.tenant_id = v_tenant_id)
      and (v_account_id is null or fi.marketplace_account_id = v_account_id)
      and (v_marketplace is null or public._finance_marketplace_norm_20260624(fi.marketplace) = v_marketplace)
    group by fi.tenant_id, fi.marketplace_account_id,
      coalesce(nullif(fi.order_id,''), nullif(fi.order_sn,''), nullif(fi.external_order_id,''), nullif(fi.remote_order_id,''))
  ),
  line_base_raw as (
    select
      ob.*,
      oi.marketplace_order_item_id,
      coalesce(nullif(oi.marketplace_sku_id,''), nullif(oi.remote_sku_id,''), nullif(oi.marketplace_sku,''), nullif(oi.marketplace_seller_sku,''), nullif(oi.seller_sku,''), nullif(oi.local_sku,''), nullif(oi.mapped_local_sku,'')) as marketplace_sku,
      coalesce(nullif(oi.marketplace_seller_sku,''), nullif(oi.seller_sku,''), nullif(oi.marketplace_sku,''), nullif(oi.local_sku,'')) as marketplace_seller_sku,
      coalesce(nullif(oi.local_sku,''), nullif(oi.mapped_local_sku,''), nullif(oi.seller_sku,''), nullif(oi.marketplace_seller_sku,''), nullif(oi.marketplace_sku,'')) as local_sku,
      coalesce(nullif(oi.marketplace_product_name,''), nullif(oi.product_name,''), nullif(oi.local_product_name,''), nullif(to_jsonb(oi)->>'item_name',''), nullif(to_jsonb(oi)->>'title',''), nullif(oi.marketplace_sku,''), nullif(oi.local_sku,''), '-') as product_name,
      coalesce(nullif(oi.marketplace_variant_name,''), nullif(oi.variant_name,''), nullif(oi.variation_name,''), nullif(to_jsonb(oi)->>'model_name',''), '-') as variant_name,
      greatest(coalesce(nullif(oi.qty,0), nullif(oi.quantity,0), 1),1)::numeric as qty,
      coalesce(
        nullif(oi.gross_amount,0),
        nullif(oi.paid_amount,0),
        nullif(oi.unit_gross_amount,0) * greatest(coalesce(nullif(oi.qty,0), nullif(oi.quantity,0), 1),1),
        nullif(ob.order_gross,0),
        0
      )::numeric as line_gross,
      lower(concat_ws(' ',
        ob.order_key, ob.order_sn, ob.tracking_number,
        oi.marketplace_sku_id, oi.remote_sku_id, oi.marketplace_sku,
        oi.marketplace_seller_sku, oi.seller_sku,
        oi.local_sku, oi.mapped_local_sku,
        oi.marketplace_product_name, oi.product_name, oi.local_product_name,
        to_jsonb(oi)->>'item_name', to_jsonb(oi)->>'title',
        oi.marketplace_variant_name, oi.variant_name, oi.variation_name, to_jsonb(oi)->>'model_name'
      )) as search_blob
    from order_base ob
    join public.marketplace_order_items oi
      on oi.tenant_id = ob.tenant_id
     and oi.marketplace_order_id = ob.marketplace_order_id
  ),
  line_base as (
    select *
    from line_base_raw
    where
      (v_msku is null or search_blob like '%' || v_msku || '%')
      or (v_lsku is not null and search_blob like '%' || v_lsku || '%')
      or (v_search is not null and search_blob like '%' || v_search || '%')
  ),
  line_calc as (
    select
      lb.*,
      sum(lb.line_gross) over (partition by lb.marketplace_order_id) as order_line_gross
    from line_base lb
  ),
  enriched as (
    select
      lc.*,
      coalesce(f.payout,0)::numeric as order_payout,
      case
        when coalesce(lc.order_line_gross,0) > 0
        then coalesce(f.payout,0)::numeric * (coalesce(lc.line_gross,0)::numeric / lc.order_line_gross)
        else coalesce(f.payout,0)::numeric
      end as line_payout
    from line_calc lc
    left join finance_by_order f
      on f.tenant_id = lc.tenant_id
     and f.marketplace_account_id = lc.marketplace_account_id
     and f.order_key in (lc.order_key, lc.order_sn)
  ),
  filtered as (
    select *
    from enriched
    where v_filter in ('all','')
       or (v_filter in ('paid','settled','payout','sudah payout') and coalesce(order_payout,0) > 0)
       or (v_filter in ('unpaid','pending','belum payout','no payout') and coalesce(order_payout,0) <= 0)
  ),
  dedup as (
    select distinct on (order_key, marketplace_sku, local_sku, marketplace_order_item_id)
      *
    from filtered
    order by order_key, marketplace_sku, local_sku, marketplace_order_item_id, order_created_at desc
  ),
  counted as (
    select *, count(*) over ()::integer as total_count
    from dedup
  ),
  paged as (
    select *
    from counted
    order by order_created_at desc, order_key, marketplace_order_item_id
    offset v_offset
    limit v_page_size
  )
  select jsonb_build_object(
    'rows',
      coalesce(jsonb_agg(jsonb_build_object(
        'source','finance_sku_order_details_detail_enriched_when_core_weak_20260625',
        'order', order_key,
        'order_id', order_key,
        'order_sn', order_sn,
        'marketplace_order_id', marketplace_order_id,
        'marketplace_order_item_id', marketplace_order_item_id,
        'resi', tracking_number,
        'tracking_number', tracking_number,
        'order_date', order_created_at,
        'order_created_at', order_created_at,
        'marketplace', marketplace,
        'marketplace_account_id', marketplace_account_id,
        'marketplace_sku', coalesce(nullif(marketplace_sku,''), '-'),
        'marketplace_seller_sku', coalesce(nullif(marketplace_seller_sku,''), '-'),
        'local_sku', coalesce(nullif(public.finance_resolve_variant_mapping_20260625(tenant_id, marketplace_account_id, marketplace_sku, marketplace_seller_sku, local_sku)->>'local_sku',''), '-'),
        'raw_local_sku', coalesce(nullif(local_sku,''), '-'),
        'mapping_id', public.finance_resolve_variant_mapping_20260625(tenant_id, marketplace_account_id, marketplace_sku, marketplace_seller_sku, local_sku)->>'mapping_id',
        'product_name', coalesce(nullif(product_name,''), coalesce(nullif(marketplace_sku,''), '-')),
        'variant_name', coalesce(nullif(variant_name,''), '-'),
        'qty', qty,
        'quantity', qty,
        'gross_amount', line_gross,
        'gross_sales', line_gross,
        'gross_total', line_gross,
        'payout_amount', line_payout,
        'payout_total', line_payout,
        'received_amount', line_payout,
        'net_settlement', line_payout,
        'status', coalesce(nullif(order_status_raw,''), 'UNKNOWN'),
        'order_status', coalesce(nullif(order_status_raw,''), 'UNKNOWN'),
        'payment_status', coalesce(nullif(payment_status_raw,''), ''),
        'fulfillment_status', coalesce(nullif(fulfillment_status_raw,''), ''),
        'payout_status', case when coalesce(order_payout,0) > 0 then 'SETTLED' else 'PENDING_PAYOUT' end,
        'hpp', public._finance_num_20260625(public.finance_resolve_variant_mapping_20260625(tenant_id, marketplace_account_id, marketplace_sku, marketplace_seller_sku, local_sku)->>'hpp'),
        'hpp_total', public._finance_num_20260625(public.finance_resolve_variant_mapping_20260625(tenant_id, marketplace_account_id, marketplace_sku, marketplace_seller_sku, local_sku)->>'hpp') * qty,
        'total_hpp', public._finance_num_20260625(public.finance_resolve_variant_mapping_20260625(tenant_id, marketplace_account_id, marketplace_sku, marketplace_seller_sku, local_sku)->>'hpp') * qty,
        'target_margin', public._finance_num_20260625(public.finance_resolve_variant_mapping_20260625(tenant_id, marketplace_account_id, marketplace_sku, marketplace_seller_sku, local_sku)->>'target_margin'),
        'profit', line_payout - (public._finance_num_20260625(public.finance_resolve_variant_mapping_20260625(tenant_id, marketplace_account_id, marketplace_sku, marketplace_seller_sku, local_sku)->>'hpp') * qty),
        'margin_percent', case when line_gross > 0 then round(((line_payout - (public._finance_num_20260625(public.finance_resolve_variant_mapping_20260625(tenant_id, marketplace_account_id, marketplace_sku, marketplace_seller_sku, local_sku)->>'hpp') * qty)) / line_gross) * 100, 2) else 0 end
      ) order by order_created_at desc, order_key), '[]'::jsonb),
    'page', v_page,
    'page_size', v_page_size,
    'total', coalesce(max(total_count),0),
    'total_count', coalesce(max(total_count),0),
    'total_pages', greatest(ceil(coalesce(max(total_count),0)::numeric / v_page_size)::integer, 1),
    'source','finance_sku_order_details_detail_enriched_when_core_weak_20260625',
    'core_source', coalesce(v_core->>'source',''),
    'core_rows', v_core_rows,
    'core_has_weak_fields', v_core_has_weak_fields,
    'debug_params', jsonb_build_object(
      'marketplace', p_marketplace,
      'marketplace_sku', p_marketplace_sku,
      'local_sku', p_local_sku,
      'search', p_search,
      'payout_filter', p_payout_filter
    )
  )
  into v_result
  from paged;

  return coalesce(v_result, jsonb_build_object(
    'rows','[]'::jsonb,
    'page',v_page,
    'page_size',v_page_size,
    'total',0,
    'total_count',0,
    'total_pages',1,
    'source','finance_sku_order_details_detail_enriched_when_core_weak_20260625_empty',
    'core_source',coalesce(v_core->>'source',''),
    'core_rows',v_core_rows,
    'core_has_weak_fields',v_core_has_weak_fields,
    'debug_params', jsonb_build_object(
      'marketplace', p_marketplace,
      'marketplace_sku', p_marketplace_sku,
      'local_sku', p_local_sku,
      'search', p_search,
      'payout_filter', p_payout_filter
    )
  ));
end;
$$;

grant execute on function public.finance_sku_order_details(date,date,text,uuid,text,text,text,text,integer,integer)
to anon, authenticated, service_role;

notify pgrst, 'reload schema';