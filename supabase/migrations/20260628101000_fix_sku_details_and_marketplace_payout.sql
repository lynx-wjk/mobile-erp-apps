-- Migration: Fix finance SKU details unit_price error and dashboard marketplace payout

-- 1. Fix finance_sku_order_line_details error (unit_price does not exist)
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
        coalesce(oi.unit_gross_amount, 0)::numeric as unit_price -- FIXED: unit_price column does not exist
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
        -- unmapped: local_sku is null/empty on the item
        and coalesce(nullif(trim(oi.local_sku),''), nullif(trim(oi.mapped_local_sku),'')) is null
    ),
    with_payout as (
      select
        b.*,
        coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0)::numeric as order_payout,
        (fr.finance_report_id is not null) as has_payout
      from base b
      left join lateral (
        select fr.finance_report_id, fr.payout_amount, fr.received_amount, fr.net_settlement
        from public.marketplace_finance_reports fr
        where fr.tenant_id = b.tenant_id
          and (fr.order_id = b.order_key or fr.marketplace_order_id::text = b.order_key)
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
      coalesce(nullif(trim(i.local_sku),''), nullif(trim(i.mapped_local_sku),'')) as local_sku,
      greatest(1, coalesce(nullif(i.quantity,0), nullif(i.qty,0), 1))::integer as qty,
      coalesce(i.gross_amount, 0)::numeric as gross_amount,
      coalesce(i.unit_gross_amount, 0)::numeric as unit_price -- FIXED: unit_price does not exist
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
        and (fr.order_id = m.order_key or fr.marketplace_order_id::text = m.order_key)
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

-- 2. Fix finance_dashboard_snapshot_core_20260625 missing payout per marketplace
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

  select u.tenant_id
    into v_tenant_id
  from public.users u
  where u.user_id = v_user_id
  limit 1;

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
    -- Build map of marketplace -> payout from the ground truth
    with mp_payout as (
      select
        public._finance_marketplace_norm_20260624(fi.marketplace) as marketplace,
        coalesce(sum(coalesce(fi.payout_amount, fi.received_amount, fi.net_settlement, 0)), 0) as payout,
        coalesce(sum(coalesce(fi.gross_amount, 0)), 0) as omzet
      from public.marketplace_finance_reports fi
      where fi.tenant_id = v_tenant_id
        and fi.period_start >= v_start
        and fi.period_start <= v_end
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

    -- Inject payout back into base marketplace breakdown
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

    -- Override global payout when base returned 0 but reports has data
    if v_payout_total = 0 and v_reports_payout > 0 then
      v_payout_total := v_reports_payout;
      v_base := jsonb_set(v_base, '{summary,payout_total}', to_jsonb(v_reports_payout), true);
      v_base := jsonb_set(v_base, '{summary,payout_amount}', to_jsonb(v_reports_payout), true);
      v_base := jsonb_set(v_base, '{summary,net_settlement}', to_jsonb(v_reports_payout), true);
      v_base := jsonb_set(v_base, '{summary,received_amount}', to_jsonb(v_reports_payout), true);
      v_base := jsonb_set(v_base, '{payout_total}', to_jsonb(v_reports_payout), true);
    end if;
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
      and fi.period_start >= v_start
      and fi.period_start <= v_end
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

  with fee_rows as (
    select jsonb_array_elements(
      jsonb_build_array(
        jsonb_build_object('name','Platform fee','type','deduction','amount',coalesce((v_fee->>'platform_fee')::numeric,0)),
        jsonb_build_object('name','Commission fee','type','deduction','amount',coalesce((v_fee->>'commission_fee')::numeric,0)),
        jsonb_build_object('name','Service fee','type','deduction','amount',coalesce((v_fee->>'service_fee')::numeric,0)),
        jsonb_build_object('name','Affiliate fee','type','deduction','amount',coalesce((v_fee->>'affiliate_fee')::numeric,0)),
        jsonb_build_object('name','Shipping fee','type','deduction','amount',coalesce((v_fee->>'shipping_fee')::numeric,0)),
        jsonb_build_object('name','Voucher/Discount','type','deduction','amount',coalesce((v_fee->>'voucher_amount')::numeric,0) + coalesce((v_fee->>'discount_amount')::numeric,0)),
        jsonb_build_object('name','Refund','type','deduction','amount',coalesce((v_fee->>'refund_amount')::numeric,0)),
        jsonb_build_object('name','Adjustment','type','deduction','amount',coalesce((v_fee->>'adjustment_amount')::numeric,0))
      )
    ) as item
  )
  select coalesce(
    jsonb_agg(item order by (item->>'amount')::numeric asc),
    '[]'::jsonb
  )
    into v_breakdown
  from fee_rows
  where coalesce((item->>'amount')::numeric,0) <> 0;

  return jsonb_build_object(
    'ok', true,
    'base', v_base,
    'fee_breakdown', v_fee,
    'fee_items', v_breakdown,
    'cash_flow', v_cash_flow,
    'expenses', v_expenses,
    'purchases', v_purchases,
    'payout_total', v_payout_total,
    'hpp_total', v_hpp_total,
    'ops_total', v_ops_total,
    'purchase_total', v_purchase_total,
    'reports_payout', v_reports_payout
  );
end;
$function$;
