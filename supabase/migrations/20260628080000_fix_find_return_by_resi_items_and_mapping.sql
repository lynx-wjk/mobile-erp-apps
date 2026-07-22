-- Migration to fix marketplace_find_return_by_resi_for_app to return item-level details
-- so that cancelled orders or returns can be processed and stocked in by the app.

CREATE OR REPLACE FUNCTION public.marketplace_find_return_by_resi_for_app(p_resi text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tenant_id uuid;
  v_clean text := lower(regexp_replace(coalesce(p_resi, ''), '\s+', '', 'g'));
  v_cutoff timestamptz := now() - interval '90 days';
  v_rows jsonb;
begin
  select u.tenant_id
    into v_tenant_id
  from public.users u
  where u.user_id = auth.uid()
    and coalesce(u.status, 'active') = 'active'
  limit 1;

  if v_tenant_id is null then
    raise exception 'User belum terhubung ke tenant aktif.';
  end if;
  if v_clean = '' then
    raise exception 'Nomor resi kosong.';
  end if;

  with matches as (
    -- Priority 1: return review item view
    select
      1 as priority,
      'return_review_item'::text as source,
      to_jsonb(r) || jsonb_build_object(
        'source', 'return_review_item',
        'matched_resi', coalesce(nullif(r.return_tracking_number, ''), nullif(r.tracking_number, '')),
        'recommended_action', 'REVIEW_REFUND_RETURN',
        'source_updated_at', coalesce(r.order_updated_at, r.pulled_at, now()),
        'shop_name', coalesce(ma.store_alias, ma.shop_name, r.marketplace_account_id::text)
      ) as payload,
      coalesce(r.order_updated_at, r.pulled_at, now()) as sort_time
    from public.marketplace_return_reviews_public r
    left join public.marketplace_accounts ma
      on ma.marketplace_account_id = r.marketplace_account_id
    where r.tenant_id = v_tenant_id
      and coalesce(r.order_updated_at, r.pulled_at, now()) >= v_cutoff
      and (
        lower(regexp_replace(coalesce(r.return_tracking_number, ''), '\s+', '', 'g')) = v_clean or
        lower(regexp_replace(coalesce(r.tracking_number, ''), '\s+', '', 'g')) = v_clean or
        lower(regexp_replace(coalesce(r.external_order_id, ''), '\s+', '', 'g')) = v_clean or
        lower(regexp_replace(coalesce(r.order_sn, ''), '\s+', '', 'g')) = v_clean
      )

    union all

    -- Priority 2: return refund cases (joining with order items to get IDs and mapping status)
    select
      2 as priority,
      'return_case'::text as source,
      jsonb_build_object(
        'source', 'return_case',
        'marketplace_return_refund_case_id', c.marketplace_return_refund_case_id,
        'marketplace_order_item_id', oi.marketplace_order_item_id,
        'marketplace_account_id', c.marketplace_account_id,
        'marketplace', c.marketplace,
        'external_return_id', c.external_return_id,
        'external_order_id', c.external_order_id,
        'external_order_item_id', c.external_order_item_id,
        'marketplace_product_name', coalesce(c.product_name, oi.product_name),
        'marketplace_variant_name', coalesce(c.variant_name, oi.variant_name),
        'seller_sku', coalesce(c.seller_sku, oi.seller_sku),
        'marketplace_sku_id', coalesce(c.marketplace_sku_id, oi.marketplace_sku_id),
        'mapped_local_sku', oi.mapped_local_sku,
        'mapped_product_id', oi.mapped_product_id,
        'local_product_name', p.nama_barang,
        'item_qty', c.quantity,
        'qty_total', c.quantity,
        'case_type', c.case_type,
        'case_status', c.case_status,
        'return_status', c.return_status,
        'refund_status', c.refund_status,
        'return_reason', c.return_reason,
        'refund_reason', c.refund_reason,
        'tracking_number', c.return_tracking_number,
        'return_tracking_number', c.return_tracking_number,
        'matched_resi', c.return_tracking_number,
        'order_status', c.case_status,
        'recommended_action', 'REVIEW_REFUND_RETURN',
        'note', coalesce(c.buyer_note, c.last_error, ''),
        'source_updated_at', coalesce(c.updated_at_marketplace, c.pulled_at, c.updated_at, now()),
        'shop_name', coalesce(ma.store_alias, ma.shop_name, c.marketplace_account_id::text)
      ) as payload,
      coalesce(c.updated_at_marketplace, c.pulled_at, c.updated_at, now()) as sort_time
    from public.marketplace_return_refund_cases c
    left join public.marketplace_order_items oi
      on oi.tenant_id = c.tenant_id
      and oi.marketplace_account_id = c.marketplace_account_id
      and (
        (c.external_order_item_id is not null and oi.external_order_item_id = c.external_order_item_id) or
        (c.external_order_item_id is null and oi.marketplace_order_id in (select marketplace_order_id from public.marketplace_orders where external_order_id = c.external_order_id or order_sn = c.external_order_id) and (oi.seller_sku = c.seller_sku or oi.marketplace_sku_id = c.marketplace_sku_id))
      )
    left join public.products p
      on p.product_id = oi.mapped_product_id
    left join public.marketplace_accounts ma
      on ma.marketplace_account_id = c.marketplace_account_id
    where c.tenant_id = v_tenant_id
      and coalesce(c.updated_at_marketplace, c.pulled_at, c.updated_at, now()) >= v_cutoff
      and (
        lower(regexp_replace(coalesce(c.return_tracking_number, ''), '\s+', '', 'g')) = v_clean or
        lower(regexp_replace(coalesce(c.external_return_id, ''), '\s+', '', 'g')) = v_clean or
        lower(regexp_replace(coalesce(c.external_order_id, ''), '\s+', '', 'g')) = v_clean
      )

    union all

    -- Priority 3: standard orders (joining with order items to return item-level details)
    select
      3 as priority,
      'order'::text as source,
      jsonb_build_object(
        'source', 'order',
        'marketplace_order_id', o.marketplace_order_id,
        'marketplace_order_item_id', oi.marketplace_order_item_id,
        'marketplace_account_id', o.marketplace_account_id,
        'marketplace', o.marketplace,
        'external_order_id', coalesce(o.external_order_id, o.order_id, o.remote_order_id, o.order_sn),
        'order_sn', o.order_sn,
        'tracking_number', o.tracking_number,
        'label_code', o.label_code,
        'matched_resi', coalesce(o.tracking_number, o.label_code),
        'order_status', coalesce(o.order_status_label, o.order_status, o.status),
        'buyer_username', o.buyer_username,
        'recipient_name', o.recipient_name,
        'order_created_at', coalesce(o.order_created_at, o.created_time, o.created_at),
        'order_updated_at', coalesce(o.order_updated_at, o.updated_time, o.updated_at),
        'source_updated_at', coalesce(o.order_updated_at, o.updated_time, o.updated_at, now()),
        'stock_action_status', o.stock_action_status,
        'return_case_status', o.return_case_status,
        'return_case_id', o.return_case_id,
        'recommended_action',
          case
            when o.return_case_id is not null or o.return_review_status is not null then 'REVIEW_REFUND_RETURN'
            else 'REVIEW_CANCEL_WITH_REAL_RESI'
          end,
        'note', coalesce(o.note, o.last_error, ''),
        'shop_name', coalesce(ma.store_alias, ma.shop_name, o.marketplace_account_id::text),
        'marketplace_product_name', oi.product_name,
        'marketplace_variant_name', oi.variant_name,
        'seller_sku', oi.seller_sku,
        'marketplace_sku_id', oi.marketplace_sku_id,
        'mapped_local_sku', oi.mapped_local_sku,
        'mapped_product_id', oi.mapped_product_id,
        'local_product_name', p.nama_barang,
        'qty_total', oi.qty,
        'item_qty', oi.qty,
        'item_returned_qty', oi.qty,
        'stock_out_qty_total', case when marketplace_order_item_is_stocked_out(oi.tenant_id, oi.marketplace_order_item_id) then oi.qty else 0 end,
        'item_stock_action_status', coalesce(oi.stock_action_status, 'pending'),
        'item_return_review_status', coalesce(oi.return_review_status, 'pending')
      ) as payload,
      coalesce(o.order_updated_at, o.updated_time, o.updated_at, now()) as sort_time
    from public.marketplace_orders o
    join public.marketplace_order_items oi
      on oi.marketplace_order_id = o.marketplace_order_id
    left join public.products p
      on p.product_id = oi.mapped_product_id
    left join public.marketplace_accounts ma
      on ma.marketplace_account_id = o.marketplace_account_id
    where o.tenant_id = v_tenant_id
      and coalesce(o.order_updated_at, o.updated_time, o.updated_at, now()) >= v_cutoff
      and (
        lower(regexp_replace(coalesce(o.tracking_number, ''), '\s+', '', 'g')) = v_clean or
        lower(regexp_replace(coalesce(o.label_code, ''), '\s+', '', 'g')) = v_clean or
        lower(regexp_replace(coalesce(o.external_order_id, ''), '\s+', '', 'g')) = v_clean or
        lower(regexp_replace(coalesce(o.order_id, ''), '\s+', '', 'g')) = v_clean or
        lower(regexp_replace(coalesce(o.order_sn, ''), '\s+', '', 'g')) = v_clean
      )
  )
  select coalesce(jsonb_agg(payload order by priority, sort_time desc), '[]'::jsonb)
    into v_rows
  from (
    select *
    from matches
    order by priority, sort_time desc
    limit 30
  ) x;

  return jsonb_build_object(
    'ok', true,
    'query', p_resi,
    'window_days', 90,
    'rows', v_rows,
    'total', jsonb_array_length(v_rows)
  );
end;
$function$;
