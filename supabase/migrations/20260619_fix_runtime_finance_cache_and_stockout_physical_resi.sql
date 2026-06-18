-- Existing-function overwrite only. No new RPC.
-- Stock Out marketplace must search by physical shipping-label resi/tracking number.
-- Do not match Shopee OFG package_number, long numeric package id, order_sn, order_id, or external_order_id.

create or replace function public.marketplace_find_order_by_resi(
  p_tenant_id uuid,
  p_resi_code text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_code text := lower(trim(coalesce(p_resi_code, '')));
  v_order record;
  v_total_items integer := 0;
  v_scanned_items integer := 0;
  v_marketplace_note text;
  v_physical_resi text;
begin
  if p_tenant_id is null or v_code = '' then
    return jsonb_build_object('ok', false, 'message', 'Scan atau input resi fisik label pengiriman terlebih dahulu.');
  end if;

  perform public.marketplace_assert_tenant_access(p_tenant_id);

  select
    o.*,
    coalesce(nullif(ma.store_alias, ''), nullif(ma.shop_name, ''), nullif(o.shop_id, ''), '-') as account_name,
    coalesce(
      nullif(o.tracking_number, ''),
      nullif(o.raw_order->>'tracking_number', '')
    ) as physical_resi
  into v_order
  from public.marketplace_orders o
  left join public.marketplace_accounts ma
    on ma.marketplace_account_id = o.marketplace_account_id
   and ma.tenant_id = o.tenant_id
  where o.tenant_id = p_tenant_id
    and (
      lower(coalesce(o.tracking_number, '')) = v_code
      or lower(coalesce(o.raw_order->>'tracking_number', '')) = v_code
      or exists (
        select 1
        from public.marketplace_order_items oi
        where oi.tenant_id = o.tenant_id
          and oi.marketplace_order_id = o.marketplace_order_id
          and lower(coalesce(oi.tracking_number, '')) = v_code
      )
    )
  order by coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) desc nulls last,
           o.created_at desc nulls last
  limit 1;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'message', 'Pesanan tidak ditemukan untuk resi fisik tersebut. Jika ini Shopee dan yang muncul masih OFG/package number, tarik/backfill resi fisik dari logistics API dulu.'
    );
  end if;

  v_physical_resi := nullif(v_order.physical_resi, '');
  if v_physical_resi is null then
    v_physical_resi := p_resi_code;
  end if;

  v_marketplace_note := public.marketplace_extract_order_note(v_order.note, v_order.raw_order);

  select
    count(*)::integer,
    count(*) filter (
      where coalesce(oi.scanned_qty, 0) >= greatest(coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1), 1)
    )::integer
  into v_total_items, v_scanned_items
  from public.marketplace_order_items oi
  where oi.tenant_id = p_tenant_id
    and oi.marketplace_order_id = v_order.marketplace_order_id;

  return jsonb_build_object(
    'ok', true,
    'message', 'Pesanan ditemukan dari resi fisik. Silakan lanjut scan item.',
    'marketplace_order_id', v_order.marketplace_order_id,
    'marketplace', v_order.marketplace,
    'account_name', v_order.account_name,
    'shop_name', v_order.account_name,
    'external_order_id', coalesce(nullif(v_order.external_order_id, ''), nullif(v_order.order_sn, ''), nullif(v_order.order_id, ''), v_order.marketplace_order_id::text),
    'order_sn', v_order.order_sn,
    'tracking_number', v_physical_resi,
    'physical_resi', v_physical_resi,
    'order_status', coalesce(v_order.order_status, v_order.status),
    'marketplace_note', v_marketplace_note,
    'seller_note', v_marketplace_note,
    'order_date', (coalesce(v_order.order_created_at, v_order.paid_at, v_order.created_time, v_order.created_at) at time zone 'Asia/Jakarta')::date,
    'total_items', coalesce(v_total_items, 0),
    'processed', coalesce(v_scanned_items, 0),
    'order_ready_to_finalize', coalesce(v_total_items, 0) > 0 and coalesce(v_scanned_items, 0) >= coalesce(v_total_items, 0)
  );
end;
$function$;

grant execute on function public.marketplace_find_order_by_resi(uuid, text) to authenticated;
