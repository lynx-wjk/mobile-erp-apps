CREATE OR REPLACE FUNCTION public.finance_sku_order_details_core_v3(p_start date DEFAULT NULL::date, p_end date DEFAULT NULL::date, p_marketplace text DEFAULT NULL::text, p_account_id uuid DEFAULT NULL::uuid, p_marketplace_sku text DEFAULT NULL::text, p_local_sku text DEFAULT NULL::text, p_search text DEFAULT NULL::text, p_payout_filter text DEFAULT 'all'::text, p_page integer DEFAULT 1, p_page_size integer DEFAULT 20)
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

   if v_detail_mode and v_marketplace_sku = 'missing_or_adjustment' then
     return (
       with finance_adjustments as (
         select
           tenant_id,
           marketplace_account_id,
           marketplace,
           coalesce(nullif(order_id, ''), 'ADJ-' || md5(random()::text)) as order_key,
           gross_amount,
           payout_amount,
           net_settlement,
           settlement_date,
           period_start
         from public.marketplace_finance_reports fr
         where tenant_id = v_tenant_id
           and (v_marketplace is null or lower(coalesce(marketplace, '')) like '%' || v_marketplace || '%')
           and (v_account_id is null or marketplace_account_id = v_account_id)
           and coalesce(settlement_date, period_start) >= v_start
           and coalesce(settlement_date, period_start) <= v_end
           and not exists (
             select 1 from public.marketplace_orders o
             where o.tenant_id = fr.tenant_id
               and coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) = coalesce(nullif(fr.order_id, ''), fr.marketplace_order_id::text)
           )
       ),
       paged as (
         select *
         from finance_adjustments
         order by coalesce(settlement_date, period_start) desc, order_key
         offset v_offset
         limit v_page_size
       )
       select jsonb_build_object(
         'rows', coalesce(jsonb_agg(jsonb_build_object(
           'source', 'finance_sku_order_details_fast_mtd_detail',
           'order', order_key,
           'order_id', order_key,
           'order_sn', order_key,
           'marketplace_order_id', order_key,
           'marketplace_order_item_id', order_key,
           'resi', '-',
           'tracking_number', '-',
           'order_date', coalesce(settlement_date, period_start),
           'order_created_at', coalesce(settlement_date, period_start),
           'marketplace', marketplace,
           'marketplace_account_id', marketplace_account_id,
           'local_sku', 'Unmapped',
           'sku', 'missing_or_adjustment',
           'marketplace_sku_id', 'missing_or_adjustment',
           'marketplace_sku', 'missing_or_adjustment',
           'marketplace_seller_sku', 'missing_or_adjustment',
           'product_name', 'Platform Adjustment / Missing Order',
           'variant_name', 'N/A',
           'marketplace_variation_name', 'N/A',
           'qty', 1,
           'quantity', 1,
           'gross', coalesce(gross_amount, 0),
           'gross_amount', coalesce(gross_amount, 0),
           'gross_total', coalesce(gross_amount, 0),
           'gross_per_item', coalesce(gross_amount, 0),
           'payout', coalesce(payout_amount, net_settlement, 0),
           'payout_amount', coalesce(payout_amount, net_settlement, 0),
           'payout_per_item', coalesce(payout_amount, net_settlement, 0),
           'hpp', 0,
           'hpp_total', 0,
           'hpp_per_item', 0,
           'unit_hpp', 0,
           'hpp_status', 'HPP belum mapping',
           'target_margin_percent', 0,
           'finance_status', 'SETTLED',
           'payout_status', 'SETTLED'
         ) order by coalesce(settlement_date, period_start) desc, order_key), '[]'::jsonb),
         'page', v_page,
         'page_size', v_page_size,
         'total', (select count(*) from finance_adjustments),
         'total_count', (select count(*) from finance_adjustments),
         'total_pages', greatest(1, ceil((select count(*) from finance_adjustments)::numeric / v_page_size)::integer),
         'source', 'finance_sku_order_details_fast_mtd'
       )
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
           where coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) >= v_start_ts
       and coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) < v_end_ts
             and (v_role = 'service_role' or o.tenant_id = v_tenant_id)
             and (v_account_id is null or o.marketplace_account_id = v_account_id)
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
           coalesce(sum(coalesce(fr.gross_amount, fr.gross_sales, 0)), 0)::numeric as finance_gross,
           coalesce(sum(coalesce(fr.platform_fee, 0)), 0)::numeric as platform_fee,
           coalesce(sum(coalesce(fr.commission_fee, 0)), 0)::numeric as commission_fee,
           coalesce(sum(coalesce(fr.affiliate_fee, 0)), 0)::numeric as affiliate_fee,
           coalesce(sum(coalesce(fr.shipping_fee, 0)), 0)::numeric as shipping_fee,
           coalesce(sum(coalesce(fr.discount_amount, 0)), 0)::numeric as discount_amount,
           coalesce(sum(coalesce(fr.voucher_amount, 0)), 0)::numeric as voucher_amount,
           coalesce(sum(coalesce(fr.refund_amount, 0)), 0)::numeric as refund_amount,
           coalesce(sum(coalesce(fr.adjustment_amount, 0)), 0)::numeric as adjustment_amount,
           max(fr.statement_id) as statement_id
         from order_base ob
         join
         (
           select tenant_id, marketplace_account_id, marketplace, order_id, marketplace_order_id, gross_amount, gross_sales, payout_amount, received_amount, net_settlement, platform_fee, commission_fee, affiliate_fee, shipping_fee, discount_amount, 0 as voucher_amount, refund_amount, adjustment_amount, statement_id
           from public.marketplace_finance_reports
           where lower(coalesce(marketplace, '')) not in ('tiktok', 'tiktok_shop')

           union all

           select tenant_id, marketplace_account_id, marketplace, coalesce(nullif(order_id, ''), nullif(order_sn, ''), nullif(external_order_id, '')) as order_id, marketplace_order_id, gross_amount, gross_amount as gross_sales, received_amount as payout_amount, received_amount, net_settlement, platform_fee, commission_fee, affiliate_fee, shipping_fee, discount_amount, voucher_amount, refund_amount, adjustment_amount, statement_id
           from public.marketplace_finance_items
           where lower(coalesce(marketplace, '')) in ('tiktok', 'tiktok_shop')
         ) fr
           on fr.tenant_id = ob.tenant_id
          and fr.marketplace_account_id = ob.marketplace_account_id
          and fr.order_id = ob.order_key
         group by ob.marketplace_order_id
       ),
       line_base as (
         select
           ob.*,
           oi.marketplace_order_item_id,
           coalesce(nullif(oi.marketplace_product_id, ''), nullif(oi.product_id::text, '')) as marketplace_product_id,
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
           and (v_local_sku is null or v_local_sku = lower(coalesce(oi.local_sku, oi.mapped_local_sku, '')))
           and (v_search is null or lower(concat_ws(' ', ob.order_key, ob.order_sn, ob.tracking_number, oi.marketplace_sku_id, oi.marketplace_sku, oi.marketplace_seller_sku, oi.seller_sku, oi.local_sku, oi.mapped_local_sku, oi.marketplace_product_name, oi.product_name, oi.marketplace_variant_name, oi.variant_name)) like '%' || v_search || '%')
       ),
       line_calc as (
         select lb.*, sum(lb.line_gross) over (partition by lb.marketplace_order_id) as order_line_gross
         from line_base lb
       ),
       enriched_base as (
         select
           lc.*,
           f.statement_id,
           coalesce(f.payout, 0)::numeric as order_payout,
           coalesce(f.finance_gross, 0)::numeric as order_finance_gross,
           coalesce(f.platform_fee, 0)::numeric as order_platform_fee,
           coalesce(f.commission_fee, 0)::numeric as order_commission_fee,
           coalesce(f.affiliate_fee, 0)::numeric as order_affiliate_fee,
           coalesce(f.shipping_fee, 0)::numeric as order_shipping_fee,
           coalesce(f.discount_amount, 0)::numeric as order_discount_amount,
           coalesce(f.voucher_amount, 0)::numeric as order_voucher_amount,
           coalesce(f.refund_amount, 0)::numeric as order_refund_amount,
           coalesce(f.adjustment_amount, 0)::numeric as order_adjustment_amount,
           (coalesce(f.payout, 0) <> 0) as has_payout
         from line_calc lc
         left join finance_by_order f on f.marketplace_order_id = lc.marketplace_order_id
       ),
       filtered as (
         select *
         from enriched_base
         where (v_filter = 'all' or (v_filter = 'paid' and has_payout) or (v_filter = 'unpaid' and not has_payout))
       ),
       counted as (
         select filtered.*, count(*) over ()::integer as total_count
         from filtered
       ),
       paged as (
         select *
         from counted
         order by order_created_at desc, order_key
         offset v_offset
         limit v_page_size
       ),
       hpp_sku as (
         select tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, '')) as marketplace_sku_id,
                max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
                max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
         from public.marketplace_variant_hpp_mappings
         where coalesce(is_active, true) is true and nullif(marketplace_sku_id, '') is not null
           and (v_role = 'service_role' or tenant_id = v_tenant_id)
         group by tenant_id, marketplace_account_id, lower(nullif(marketplace_sku_id, ''))
       ),
       hpp_seller as (
         select tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, '')) as marketplace_seller_sku,
                max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
                max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
         from public.marketplace_variant_hpp_mappings
         where coalesce(is_active, true) is true and nullif(marketplace_seller_sku, '') is not null
           and (v_role = 'service_role' or tenant_id = v_tenant_id)
         group by tenant_id, marketplace_account_id, lower(nullif(marketplace_seller_sku, ''))
       ),
       hpp_local as (
         select tenant_id, marketplace_account_id, lower(nullif(local_sku, '')) as local_sku,
                max(coalesce(hpp, hpp_amount, hpp_per_item, 0))::numeric as hpp,
                max(coalesce(target_margin_percent, target_margin, 0))::numeric as target_margin
         from public.marketplace_variant_hpp_mappings
         where coalesce(is_active, true) is true and nullif(local_sku, '') is not null
           and (v_role = 'service_role' or tenant_id = v_tenant_id)
         group by tenant_id, marketplace_account_id, lower(nullif(local_sku, ''))
       ),
       paged_enriched as (
         select
           p.*,
           coalesce(hs.hpp, hsel.hpp, hl.hpp, 0)::numeric as unit_hpp,
           coalesce(hs.target_margin, hsel.target_margin, hl.target_margin, 0)::numeric as target_margin
         from paged p
         left join hpp_sku hs
           on hs.tenant_id = p.tenant_id
          and hs.marketplace_account_id = p.marketplace_account_id
          and hs.marketplace_sku_id = lower(nullif(p.marketplace_sku_id, ''))
         left join hpp_seller hsel
           on hsel.tenant_id = p.tenant_id
          and hsel.marketplace_account_id = p.marketplace_account_id
          and hsel.marketplace_seller_sku = lower(nullif(p.marketplace_seller_sku, ''))
         left join hpp_local hl
           on hl.tenant_id = p.tenant_id
          and hl.marketplace_account_id = p.marketplace_account_id
          and hl.local_sku = lower(nullif(p.local_sku, ''))
       )
       select jsonb_build_object(
         'rows', coalesce(jsonb_agg(jsonb_build_object(
           'source', 'finance_sku_order_details_fast_mtd_detail',
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
           'statement_id', statement_id,
           'marketplace_product_id', marketplace_product_id,
           'finance_gross', case when order_line_gross > 0 then order_finance_gross * (line_gross / order_line_gross) else 0 end,
           'admin_fee', case when order_line_gross > 0 then order_platform_fee * (line_gross / order_line_gross) else 0 end,
           'commission_fee', case when order_line_gross > 0 then order_commission_fee * (line_gross / order_line_gross) else 0 end,
           'affiliate_fee', case when order_line_gross > 0 then order_affiliate_fee * (line_gross / order_line_gross) else 0 end,
           'shipping_fee', case when order_line_gross > 0 then order_shipping_fee * (line_gross / order_line_gross) else 0 end,
           'voucher_amount', case when order_line_gross > 0 then order_voucher_amount * (line_gross / order_line_gross) else 0 end,
           'discount_amount', case when order_line_gross > 0 then order_discount_amount * (line_gross / order_line_gross) else 0 end,
           'refund_amount', case when order_line_gross > 0 then order_refund_amount * (line_gross / order_line_gross) else 0 end,
           'adjustment_amount', case when order_line_gross > 0 then order_adjustment_amount * (line_gross / order_line_gross) else 0 end,
           'reconciliation_status', case when abs((case when order_line_gross > 0 then order_finance_gross * (line_gross / order_line_gross) else 0 end) - line_gross) > 100 then 'MISMATCH' else 'MATCH' end,
           'hpp', unit_hpp * qty,
           'hpp_total', unit_hpp * qty,
           'hpp_per_item', unit_hpp,
           'unit_hpp', unit_hpp,
           'hpp_status', case when unit_hpp > 0 then 'HPP mapping' else 'HPP belum mapping' end,
           'target_margin_percent', target_margin,
           'finance_status', case when has_payout then 'SETTLED' else 'PENDING_PAYOUT' end,
           'payout_status', case when has_payout then 'SETTLED' else 'PENDING_PAYOUT' end
         ) order by order_created_at desc, order_key), '[]'::jsonb),
         'page', v_page,
         'page_size', v_page_size,
         'total', coalesce(max(total_count), 0),
         'total_count', coalesce(max(total_count), 0),
         'total_pages', greatest(1, ceil(coalesce(max(total_count), 0)::numeric / v_page_size)::integer),
         'source', 'finance_sku_order_details_fast_mtd'
       )
       from paged_enriched
     );
   end if;

   return jsonb_build_object('ok', true);
 end;
 $function$;
