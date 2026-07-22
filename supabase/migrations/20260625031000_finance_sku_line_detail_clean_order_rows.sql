do $$
begin
  if to_regprocedure('public.finance_sku_order_line_details_price_patch_core_20260625(date,date,text,uuid,text,text,text,text,integer,integer)') is null then
    alter function public.finance_sku_order_line_details(date,date,text,uuid,text,text,text,text,integer,integer)
      rename to finance_sku_order_line_details_price_patch_core_20260625;
  end if;
end $$;

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
security definer
set search_path = public
set statement_timeout = '25s'
as $$
declare
  j jsonb;
  rows jsonb := '[]'::jsonb;
  patched_rows jsonb := '[]'::jsonb;
  v_page integer := greatest(coalesce(p_page,1),1);
  v_page_size integer := least(greatest(coalesce(p_page_size,25),1),25);
  v_total_count integer := 0;
  v_bad_group_count integer := 0;
  v_final_total integer := 0;
begin
  j := public.finance_sku_order_line_details_price_patch_core_20260625(
    p_start,p_end,p_marketplace,p_account_id,p_marketplace_sku,p_local_sku,p_search,p_payout_filter,v_page,v_page_size
  );

  rows := coalesce(j->'rows','[]'::jsonb);
  v_total_count := coalesce(nullif(j->>'total_count','')::integer, 0);

  with src as (
    select
      r.item as row,
      r.ord,
      nullif(trim(coalesce(r.item->>'order_id', r.item->>'order_sn', r.item->>'order', '')), '') as order_key,
      nullif(trim(coalesce(r.item->>'marketplace_order_item_id','')), '') as item_key,
      greatest(public._finance_num_any_20260625(r.item->>'qty'), 1) as qty,
      public._finance_num_any_20260625(coalesce(r.item->>'gross_sales', r.item->>'gross_total', r.item->>'gross_amount', '0')) as row_gross,
      public._finance_num_any_20260625(coalesce(r.item->>'payout_total', r.item->>'payout_amount', r.item->>'received_amount', '0')) as row_payout
    from jsonb_array_elements(rows) with ordinality as r(item, ord)
  ),
  valid_src as (
    select *
    from src
    where order_key is not null
      and lower(order_key) not in ('belum ada order','-','null','none')
      and lower(coalesce(row->>'source','')) not like '%group_from_payout_summary%'
  ),
  bad_src as (
    select count(*)::integer as c
    from src
    where order_key is null
       or lower(order_key) in ('belum ada order','-','null','none')
       or lower(coalesce(row->>'source','')) like '%group_from_payout_summary%'
  ),
  enriched as (
    select
      s.*,

      o.marketplace_order_id,
      o.order_created_at,
      coalesce(nullif(o.order_status,''), nullif(o.status,''), nullif(o.order_status_label,''), nullif(o.fulfillment_status,''), s.row->>'status', 'UNKNOWN') as order_status_real,
      coalesce(nullif(o.payment_status,''), s.row->>'payment_status', '') as payment_status_real,
      coalesce(nullif(o.fulfillment_status,''), s.row->>'fulfillment_status', '') as fulfillment_status_real,
      coalesce(nullif(o.tracking_number,''), nullif(o.label_code,''), nullif(o.package_id,''), s.row->>'resi', s.row->>'tracking_number') as resi_real,

      oi.marketplace_order_item_id as matched_item_id,
      public.finance_order_item_gross_from_json_20260625(to_jsonb(oi), to_jsonb(o), s.qty) as db_order_item_gross,

      fr.settlement_id,
      fr.finance_gross,
      fr.shipping_fee,
      fr.platform_fee,
      fr.commission_fee,
      fr.service_fee,
      fr.transaction_fee,
      fr.discount_amount,
      fr.voucher_amount,
      fr.refund_amount,
      fr.total_deductions

    from valid_src s

    left join lateral (
      select o1.*
      from public.marketplace_orders o1
      where (
        o1.marketplace_order_id::text = coalesce(s.row->>'marketplace_order_id','')
        or coalesce(o1.order_id::text,'') = s.order_key
        or coalesce(o1.order_sn::text,'') = s.order_key
        or coalesce(o1.external_order_id::text,'') = s.order_key
      )
      and (p_account_id is null or o1.marketplace_account_id = p_account_id)
      order by o1.order_created_at desc nulls last
      limit 1
    ) o on true

    left join lateral (
      select oi1.*
      from public.marketplace_order_items oi1
      where (
        oi1.marketplace_order_item_id::text = coalesce(s.item_key,'')
        or (
          o.marketplace_order_id is not null
          and oi1.marketplace_order_id = o.marketplace_order_id
          and (
            lower(coalesce(oi1.marketplace_sku_id,'')) = lower(coalesce(s.row->>'marketplace_sku',''))
            or lower(coalesce(oi1.remote_sku_id,'')) = lower(coalesce(s.row->>'marketplace_sku',''))
            or lower(coalesce(oi1.marketplace_sku,'')) = lower(coalesce(s.row->>'marketplace_sku',''))
            or lower(coalesce(oi1.marketplace_seller_sku,'')) = lower(coalesce(s.row->>'marketplace_seller_sku',''))
            or lower(coalesce(oi1.seller_sku,'')) = lower(coalesce(s.row->>'marketplace_seller_sku',''))
            or lower(coalesce(oi1.local_sku,'')) = lower(coalesce(s.row->>'local_sku',''))
            or lower(coalesce(oi1.mapped_local_sku,'')) = lower(coalesce(s.row->>'local_sku',''))
          )
        )
      )
      order by
        case when oi1.marketplace_order_item_id::text = coalesce(s.item_key,'') then 0 else 1 end,
        oi1.marketplace_order_item_id
      limit 1
    ) oi on true

    left join lateral (
      select
        coalesce(
          max(nullif(to_jsonb(fi)->>'settlement_id','')),
          max(nullif(to_jsonb(fi)->>'statement_id','')),
          max(nullif(to_jsonb(fi)->>'finance_report_id','')),
          max(nullif(to_jsonb(fi)->>'settlement_ref','')),
          max(nullif(to_jsonb(fi)->>'statement_ref',''))
        ) as settlement_id,

        coalesce(sum(public._finance_num_any_20260625(coalesce(
          to_jsonb(fi)->>'gross_amount',
          to_jsonb(fi)->>'gross_sales',
          to_jsonb(fi)->>'gross_total',
          '0'
        ))),0) as finance_gross,

        coalesce(sum(public._finance_num_any_20260625(coalesce(to_jsonb(fi)->>'shipping_fee','0'))),0) as shipping_fee,
        coalesce(sum(public._finance_num_any_20260625(coalesce(to_jsonb(fi)->>'platform_fee','0'))),0) as platform_fee,
        coalesce(sum(public._finance_num_any_20260625(coalesce(to_jsonb(fi)->>'commission_fee','0'))),0) as commission_fee,
        coalesce(sum(public._finance_num_any_20260625(coalesce(to_jsonb(fi)->>'service_fee','0'))),0) as service_fee,
        coalesce(sum(public._finance_num_any_20260625(coalesce(to_jsonb(fi)->>'transaction_fee','0'))),0) as transaction_fee,
        coalesce(sum(public._finance_num_any_20260625(coalesce(to_jsonb(fi)->>'discount_amount','0'))),0) as discount_amount,
        coalesce(sum(public._finance_num_any_20260625(coalesce(to_jsonb(fi)->>'voucher_amount', to_jsonb(fi)->>'voucher_discount','0'))),0) as voucher_amount,
        coalesce(sum(public._finance_num_any_20260625(coalesce(to_jsonb(fi)->>'refund_amount','0'))),0) as refund_amount,
        coalesce(sum(abs(public._finance_num_any_20260625(coalesce(to_jsonb(fi)->>'deduction_amount','0')))),0) as total_deductions
      from public.marketplace_finance_items fi
      where (p_account_id is null or fi.marketplace_account_id = p_account_id)
        and (
          coalesce(fi.order_id,'') = s.order_key
          or coalesce(fi.order_sn,'') = s.order_key
          or coalesce(fi.external_order_id,'') = s.order_key
          or coalesce(fi.remote_order_id,'') = s.order_key
        )
        and (
          coalesce(s.row->>'marketplace_sku','') = ''
          or lower(coalesce(fi.marketplace_sku,'')) = lower(coalesce(s.row->>'marketplace_sku',''))
          or lower(coalesce(fi.seller_sku,'')) = lower(coalesce(s.row->>'marketplace_seller_sku',''))
          or lower(coalesce(fi.marketplace_seller_sku,'')) = lower(coalesce(s.row->>'marketplace_seller_sku',''))
          or lower(coalesce(fi.local_sku,'')) = lower(coalesce(s.row->>'local_sku',''))
        )
    ) fr on true
  ),
  fixed as (
    select
      ord,
      (
        row
        - 'source'
        - 'delegate_source'
        - 'core_source'
      ) ||
      jsonb_build_object(
        'debug_source', coalesce(row->>'source',''),
        'source', coalesce(nullif(settlement_id,''), ''),
        'settlement_id', coalesce(nullif(settlement_id,''), ''),
        'settlement_ref', coalesce(nullif(settlement_id,''), ''),
        'statement_id', coalesce(nullif(settlement_id,''), ''),

        'order_id', order_key,
        'order_sn', coalesce(nullif(row->>'order_sn',''), order_key),
        'marketplace_order_item_id', coalesce(matched_item_id::text, item_key, ''),
        'resi', coalesce(nullif(resi_real,''), 'Belum ada resi'),
        'tracking_number', coalesce(nullif(resi_real,''), ''),

        'status', coalesce(nullif(order_status_real,''), 'UNKNOWN'),
        'order_status', coalesce(nullif(order_status_real,''), 'UNKNOWN'),
        'payment_status', coalesce(nullif(payment_status_real,''), ''),
        'fulfillment_status', coalesce(nullif(fulfillment_status_real,''), ''),
        'payout_status', coalesce(nullif(row->>'payout_status',''), case when row_payout > 0 then 'SETTLED' else 'PENDING_PAYOUT' end),

        'gross_sales',
          coalesce(nullif(row_gross,0), nullif(db_order_item_gross,0), nullif(finance_gross,0), 0),
        'gross_amount',
          coalesce(nullif(row_gross,0), nullif(db_order_item_gross,0), nullif(finance_gross,0), 0),
        'gross_total',
          coalesce(nullif(row_gross,0), nullif(db_order_item_gross,0), nullif(finance_gross,0), 0),
        'harga_jual',
          coalesce(nullif(row_gross,0), nullif(db_order_item_gross,0), nullif(finance_gross,0), 0),
        'harga_jual_total',
          coalesce(nullif(row_gross,0), nullif(db_order_item_gross,0), nullif(finance_gross,0), 0),
        'harga_jual_per_item',
          round(coalesce(nullif(row_gross,0), nullif(db_order_item_gross,0), nullif(finance_gross,0), 0) / greatest(qty,1), 2),
        'unit_price',
          round(coalesce(nullif(row_gross,0), nullif(db_order_item_gross,0), nullif(finance_gross,0), 0) / greatest(qty,1), 2),
        'price_per_item',
          round(coalesce(nullif(row_gross,0), nullif(db_order_item_gross,0), nullif(finance_gross,0), 0) / greatest(qty,1), 2),
        'gross_per_item',
          round(coalesce(nullif(row_gross,0), nullif(db_order_item_gross,0), nullif(finance_gross,0), 0) / greatest(qty,1), 2),

        'gross_source',
          case
            when row_gross > 0 then 'order_line'
            when coalesce(db_order_item_gross,0) > 0 then 'marketplace_order_item'
            when coalesce(finance_gross,0) > 0 then 'finance_item'
            else 'missing'
          end,

        'shipping_fee', coalesce(shipping_fee,0),
        'platform_fee', coalesce(platform_fee,0),
        'commission_fee', coalesce(commission_fee,0),
        'service_fee', coalesce(service_fee,0),
        'transaction_fee', coalesce(transaction_fee,0),
        'discount_amount', coalesce(discount_amount,0),
        'voucher_amount', coalesce(voucher_amount,0),
        'refund_amount', coalesce(refund_amount,0),
        'total_deductions',
          greatest(
            coalesce(total_deductions,0),
            coalesce(shipping_fee,0) + coalesce(platform_fee,0) + coalesce(commission_fee,0) + coalesce(service_fee,0) + coalesce(transaction_fee,0) + coalesce(discount_amount,0) + coalesce(voucher_amount,0) + coalesce(refund_amount,0),
            coalesce(nullif(row_gross,0), nullif(db_order_item_gross,0), nullif(finance_gross,0), 0) - row_payout
          ),

        'settlement_breakdown', jsonb_build_object(
          'omzet_item', coalesce(nullif(row_gross,0), nullif(db_order_item_gross,0), nullif(finance_gross,0), 0),
          'payout_marketplace', row_payout,
          'potongan_total',
            greatest(
              coalesce(total_deductions,0),
              coalesce(shipping_fee,0) + coalesce(platform_fee,0) + coalesce(commission_fee,0) + coalesce(service_fee,0) + coalesce(transaction_fee,0) + coalesce(discount_amount,0) + coalesce(voucher_amount,0) + coalesce(refund_amount,0),
              coalesce(nullif(row_gross,0), nullif(db_order_item_gross,0), nullif(finance_gross,0), 0) - row_payout
            ),
          'ongkir', coalesce(shipping_fee,0),
          'biaya_platform', coalesce(platform_fee,0),
          'komisi', coalesce(commission_fee,0),
          'biaya_layanan', coalesce(service_fee,0),
          'biaya_transaksi', coalesce(transaction_fee,0),
          'diskon', coalesce(discount_amount,0),
          'voucher', coalesce(voucher_amount,0),
          'refund', coalesce(refund_amount,0)
        )
      ) as row
    from enriched
  )
  select
    coalesce(jsonb_agg(row order by ord), '[]'::jsonb)
  into patched_rows
  from fixed;
  select count(*)::integer
  into v_bad_group_count
  from jsonb_array_elements(coalesce(rows,'[]'::jsonb)) as r(item)
  where nullif(trim(coalesce(r.item->>'order_id', r.item->>'order_sn', r.item->>'order', '')), '') is null
     or lower(coalesce(nullif(trim(coalesce(r.item->>'order_id', r.item->>'order_sn', r.item->>'order', '')), ''), '')) in ('belum ada order','-','null','none')
     or lower(coalesce(r.item->>'source','')) like '%group_from_payout_summary%';

  if v_bad_group_count > 0 then
    v_final_total := coalesce(jsonb_array_length(patched_rows),0);
  else
    v_final_total := greatest(v_total_count, coalesce(jsonb_array_length(patched_rows),0));
  end if;

  return jsonb_build_object(
    'rows', patched_rows,
    'data', patched_rows,
    'items', patched_rows,
    'page', v_page,
    'page_size', v_page_size,
    'total', v_final_total,
    'count', v_final_total,
    'total_count', v_final_total,
    'total_pages', greatest(ceil(coalesce(v_final_total,0)::numeric / v_page_size)::integer, 1),
    'has_more', v_page < greatest(ceil(coalesce(v_final_total,0)::numeric / v_page_size)::integer, 1),
    'next_page', case when v_page < greatest(ceil(coalesce(v_final_total,0)::numeric / v_page_size)::integer, 1) then v_page + 1 else null end,
    'source', 'finance_sku_order_line_details_clean_order_rows_20260625',
    'delegate_source', coalesce(j->>'source',''),
    'bad_group_rows_removed', v_bad_group_count,
    'requested_payout_filter', p_payout_filter
  );
end;
$$;

grant execute on function public.finance_sku_order_line_details(date,date,text,uuid,text,text,text,text,integer,integer)
to anon, authenticated, service_role;

notify pgrst, 'reload schema';