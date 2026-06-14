-- Stock Out marketplace manual SKU override audit.
-- Keeps barcode scan strict: scanned product barcode/SKU must still match the
-- verified order/resi item. SKU changes are only recorded through the manual
-- override RPC below.

create or replace function public.marketplace_extract_order_note(
  p_note text,
  p_raw_order jsonb
)
returns text
language sql
stable
set search_path = public
as $$
  select nullif(
    concat_ws(
      E'\n',
      nullif(trim(coalesce(p_note, '')), ''),
      nullif(trim(coalesce(p_raw_order->>'buyer_note', '')), ''),
      nullif(trim(coalesce(p_raw_order->>'seller_note', '')), ''),
      nullif(trim(coalesce(p_raw_order->>'note', '')), ''),
      nullif(trim(coalesce(p_raw_order->>'remark', '')), ''),
      nullif(trim(coalesce(p_raw_order->>'message_to_seller', '')), ''),
      nullif(trim(coalesce(p_raw_order->>'buyer_message', '')), ''),
      nullif(trim(coalesce(p_raw_order->>'order_note', '')), ''),
      nullif(trim(coalesce(p_raw_order->>'package_note', '')), ''),
      nullif(trim(coalesce(p_raw_order->>'delivery_note', '')), ''),
      nullif(trim(coalesce(p_raw_order #>> '{buyer,note}', '')), ''),
      nullif(trim(coalesce(p_raw_order #>> '{buyer,message}', '')), ''),
      nullif(trim(coalesce(p_raw_order #>> '{recipient,note}', '')), ''),
      nullif(trim(coalesce(p_raw_order #>> '{shipping,note}', '')), ''),
      nullif(trim(coalesce(p_raw_order #>> '{package_list,0,package_note}', '')), ''),
      nullif(trim(coalesce(p_raw_order #>> '{package_list,0,delivery_note}', '')), '')
    ),
    ''
  );
$$;

grant execute on function public.marketplace_extract_order_note(text, jsonb) to authenticated, service_role;

create table if not exists public.marketplace_stock_out_fulfillment_overrides (
  override_id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.app_tenants(tenant_id) on delete cascade,
  marketplace_order_id uuid not null references public.marketplace_orders(marketplace_order_id) on delete cascade,
  marketplace_order_item_id uuid not null references public.marketplace_order_items(marketplace_order_item_id) on delete cascade,
  marketplace_account_id uuid references public.marketplace_accounts(marketplace_account_id) on delete set null,
  resi_code text,
  marketplace text,
  shop_name text,
  external_order_id text,
  order_sn text,
  tracking_number text,
  order_status text,
  original_product_id uuid references public.products(product_id) on delete set null,
  original_local_sku text,
  original_product_name text,
  marketplace_sku_id text,
  marketplace_seller_sku text,
  marketplace_product_name text,
  marketplace_variant_name text,
  actual_product_id uuid not null references public.products(product_id),
  actual_local_sku text not null,
  actual_barcode text,
  actual_product_name text not null,
  qty numeric not null default 1 check (qty > 0),
  marketplace_note text,
  user_note text not null,
  raw_context jsonb not null default '{}'::jsonb,
  stock_transaction_id uuid references public.stock_transactions(stock_transaction_id) on delete set null,
  created_by uuid references public.users(user_id) on delete set null,
  created_by_name text,
  created_by_email text,
  created_by_role text,
  stock_out_by uuid references public.users(user_id) on delete set null,
  stock_out_by_name text,
  stock_out_by_email text,
  stock_out_by_role text,
  stock_out_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_mso_fulfillment_overrides_order
  on public.marketplace_stock_out_fulfillment_overrides(tenant_id, marketplace_order_id, marketplace_order_item_id);

create index if not exists idx_mso_fulfillment_overrides_actual_product
  on public.marketplace_stock_out_fulfillment_overrides(tenant_id, actual_product_id);

alter table public.marketplace_stock_out_fulfillment_overrides enable row level security;

drop policy if exists marketplace_stock_out_fulfillment_overrides_tenant_select
  on public.marketplace_stock_out_fulfillment_overrides;
create policy marketplace_stock_out_fulfillment_overrides_tenant_select
  on public.marketplace_stock_out_fulfillment_overrides
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.users u
      where u.user_id = auth.uid()
        and u.tenant_id = marketplace_stock_out_fulfillment_overrides.tenant_id
        and u.status = 'active'
    )
  );

revoke all on public.marketplace_stock_out_fulfillment_overrides from anon, authenticated;
grant select on public.marketplace_stock_out_fulfillment_overrides to authenticated;
grant all on public.marketplace_stock_out_fulfillment_overrides to service_role;

create or replace view public.marketplace_order_items_public
with (security_invoker = true) as
select
  i.marketplace_order_item_id,
  i.marketplace_order_id,
  i.tenant_id,
  i.marketplace_account_id,
  i.marketplace,
  i.external_order_id,
  i.external_order_item_id,
  i.marketplace_product_id,
  i.marketplace_sku_id,
  i.seller_sku,
  i.product_name,
  i.variant_name,
  i.quantity,
  i.mapped_product_id,
  i.mapped_local_sku,
  p.nama_barang as local_product_name,
  p.kode_barcode as local_barcode,
  coalesce(p.stock_saat_ini, 0::numeric) as local_stock,
  public.marketplace_reserved_qty_for_product(i.tenant_id, i.mapped_product_id) as reserved_stock_total,
  public.marketplace_available_stock_for_product(i.tenant_id, i.mapped_product_id) as available_stock,
  i.marketplace_sku_map_id,
  i.mapping_status,
  case i.mapping_status
    when 'mapped'::text then 'Mapped'::text
    else 'Unmapped'::text
  end as mapping_label,
  i.reserved_qty,
  i.scanned_qty,
  i.returned_qty,
  i.stock_action_status,
  case i.stock_action_status
    when 'ignored_status'::text then 'Waiting Scan'::text
    when 'ignored'::text then 'Waiting Scan'::text
    when 'waiting_scan'::text then 'Waiting Scan'::text
    when 'reserved'::text then 'Waiting Scan'::text
    when 'ready_to_pick'::text then 'Ready Pick'::text
    when 'ready_stock_out'::text then 'Ready Pick'::text
    when 'partial_scanned'::text then 'Partial Scanned'::text
    when 'scanned_done'::text then 'Scanned Done'::text
    when 'stock_out_done'::text then 'Stock Out Done'::text
    when 'stock_out_failed'::text then 'Stock Out Failed'::text
    when 'reserve_failed'::text then 'Reserve Failed'::text
    when 'insufficient_stock'::text then 'Insufficient Stock'::text
    when 'unmapped'::text then 'Unmapped SKU'::text
    else initcap(replace(coalesce(i.stock_action_status, 'waiting_scan'::text), '_'::text, ' '::text))
  end as stock_action_label,
  i.last_error,
  i.created_at,
  i.updated_at,
  coalesce(i.tracking_number, o.tracking_number) as tracking_number,
  coalesce(i.package_id, o.package_id) as package_id,
  coalesce(ov.override_qty, 0::numeric) as fulfillment_override_qty,
  coalesce(ov.actual_local_skus, ''::text) as fulfillment_override_local_skus,
  coalesce(ov.actual_product_names, ''::text) as fulfillment_override_product_names,
  coalesce(ov.latest_user_note, ''::text) as fulfillment_override_note
from public.marketplace_order_items i
left join public.marketplace_orders o
  on o.marketplace_order_id = i.marketplace_order_id
left join public.products p
  on p.product_id = i.mapped_product_id
left join lateral (
  select
    sum(fo.qty) as override_qty,
    string_agg(distinct fo.actual_local_sku, ', ' order by fo.actual_local_sku) as actual_local_skus,
    string_agg(distinct fo.actual_product_name, ', ' order by fo.actual_product_name) as actual_product_names,
    (array_agg(fo.user_note order by fo.created_at desc))[1] as latest_user_note
  from public.marketplace_stock_out_fulfillment_overrides fo
  where fo.tenant_id = i.tenant_id
    and fo.marketplace_order_item_id = i.marketplace_order_item_id
) ov on true
where exists (
  select 1
  from public.users u
  where u.user_id = auth.uid()
    and u.tenant_id = i.tenant_id
    and u.status = 'active'::text
);

grant select on public.marketplace_order_items_public to authenticated, service_role;

create or replace function public.marketplace_find_order_by_resi(
  p_tenant_id uuid,
  p_resi_code text
)
returns jsonb
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
begin
  if p_tenant_id is null or v_code = '' then
    return jsonb_build_object('ok', false, 'message', 'Scan atau input nomor resi/order terlebih dahulu.');
  end if;

  perform public.marketplace_assert_tenant_access(p_tenant_id);

  select
    o.*,
    coalesce(nullif(ma.store_alias, ''), nullif(ma.shop_name, ''), nullif(o.shop_id, ''), '-') as account_name
    into v_order
  from public.marketplace_orders o
  left join public.marketplace_accounts ma
    on ma.marketplace_account_id = o.marketplace_account_id
   and ma.tenant_id = o.tenant_id
  where o.tenant_id = p_tenant_id
    and (
      lower(coalesce(o.tracking_number, '')) = v_code
      or lower(coalesce(o.label_code, '')) = v_code
      or lower(coalesce(o.package_id, '')) = v_code
      or lower(coalesce(o.external_order_id, '')) = v_code
      or lower(coalesce(o.order_sn, '')) = v_code
      or lower(coalesce(o.order_id, '')) = v_code
      or lower(o.marketplace_order_id::text) = v_code
      or exists (
        select 1
        from public.marketplace_order_items oi
        where oi.tenant_id = o.tenant_id
          and oi.marketplace_order_id = o.marketplace_order_id
          and (
            lower(coalesce(oi.tracking_number, '')) = v_code
            or lower(coalesce(oi.package_id, '')) = v_code
            or lower(coalesce(oi.external_order_item_id, '')) = v_code
          )
      )
    )
  order by coalesce(o.order_created_at, o.paid_at, o.created_time, o.created_at) desc nulls last,
           o.created_at desc nulls last
  limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'message', 'Pesanan tidak ditemukan untuk resi/order tersebut.');
  end if;

  v_marketplace_note := public.marketplace_extract_order_note(v_order.note, v_order.raw_order);

  select count(*)::integer,
         count(*) filter (
           where coalesce(oi.scanned_qty, 0) >= greatest(coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1), 1)
         )::integer
    into v_total_items, v_scanned_items
  from public.marketplace_order_items oi
  where oi.tenant_id = p_tenant_id
    and oi.marketplace_order_id = v_order.marketplace_order_id;

  return jsonb_build_object(
    'ok', true,
    'message', 'Pesanan ditemukan. Silakan lanjut scan item.',
    'marketplace_order_id', v_order.marketplace_order_id,
    'marketplace', v_order.marketplace,
    'account_name', v_order.account_name,
    'shop_name', v_order.account_name,
    'external_order_id', coalesce(nullif(v_order.external_order_id, ''), nullif(v_order.order_sn, ''), nullif(v_order.order_id, ''), v_order.marketplace_order_id::text),
    'order_sn', v_order.order_sn,
    'tracking_number', coalesce(nullif(v_order.tracking_number, ''), nullif(v_order.label_code, ''), p_resi_code),
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

create or replace function public.marketplace_mark_order_scan_state(
  p_tenant_id uuid,
  p_marketplace_order_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_all_done boolean;
begin
  perform public.marketplace_assert_tenant_access(p_tenant_id);

  select not exists (
    select 1
    from public.marketplace_order_items as i
    where i.marketplace_order_id = p_marketplace_order_id
      and i.tenant_id = p_tenant_id
      and (
        coalesce(i.scanned_qty, 0) < greatest(coalesce(nullif(i.quantity, 0), nullif(i.qty, 0), 1), 1)
        or (
          (coalesce(i.mapping_status, '') <> 'mapped' or i.mapped_product_id is null)
          and coalesce((
            select sum(fo.qty)
            from public.marketplace_stock_out_fulfillment_overrides fo
            where fo.tenant_id = i.tenant_id
              and fo.marketplace_order_item_id = i.marketplace_order_item_id
          ), 0) < greatest(coalesce(nullif(i.quantity, 0), nullif(i.qty, 0), 1), 1)
        )
      )
  ) into v_all_done;

  update public.marketplace_orders as o
     set stock_action_status = case when v_all_done then 'scanned_done' else 'partial_scanned' end,
         picked_at = case when v_all_done then coalesce(o.picked_at, now()) else o.picked_at end,
         last_error = null,
         updated_at = now()
   where o.marketplace_order_id = p_marketplace_order_id
     and o.tenant_id = p_tenant_id;

  return coalesce(v_all_done, false);
end;
$function$;

create or replace function public.marketplace_scan_order_item_manual_override_by_resi(
  p_tenant_id uuid,
  p_resi_code text,
  p_marketplace_order_item_id uuid,
  p_actual_product_id uuid,
  p_override_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_found jsonb;
  v_order record;
  v_item record;
  v_actual_product record;
  v_user record;
  v_order_id uuid;
  v_required_qty numeric;
  v_new_scanned numeric;
  v_is_override boolean;
  v_marketplace_note text;
  v_ready boolean;
  v_note text := trim(coalesce(p_override_note, ''));
begin
  perform public.marketplace_assert_tenant_access(p_tenant_id);

  if p_actual_product_id is null then
    return jsonb_build_object('ok', false, 'message', 'Pilih SKU lokal aktual terlebih dahulu.');
  end if;

  v_found := public.marketplace_find_order_by_resi(p_tenant_id, p_resi_code);
  if coalesce((v_found->>'ok')::boolean, false) = false then
    return v_found;
  end if;

  v_order_id := nullif(v_found->>'marketplace_order_id', '')::uuid;

  select
    o.*,
    coalesce(nullif(ma.store_alias, ''), nullif(ma.shop_name, ''), nullif(o.shop_id, ''), '-') as account_name
    into v_order
  from public.marketplace_orders o
  left join public.marketplace_accounts ma
    on ma.marketplace_account_id = o.marketplace_account_id
   and ma.tenant_id = o.tenant_id
  where o.tenant_id = p_tenant_id
    and o.marketplace_order_id = v_order_id
  for update of o;

  if not found then
    return jsonb_build_object('ok', false, 'message', 'Pesanan marketplace tidak ditemukan.');
  end if;

  if not public.marketplace_order_is_pickable(v_order.order_status) then
    return jsonb_build_object(
      'ok', false,
      'message', concat('Status order tidak bisa diproses stock out: ', coalesce(v_order.order_status, '-'))
    );
  end if;

  select i.*
    into v_item
  from public.marketplace_order_items i
  where i.tenant_id = p_tenant_id
    and i.marketplace_order_id = v_order_id
    and i.marketplace_order_item_id = p_marketplace_order_item_id
    and coalesce(i.stock_action_status, '') <> 'stock_out_done'
  for update;

  if not found then
    return v_found || jsonb_build_object('ok', false, 'message', 'Item tidak ditemukan pada pesanan ini.');
  end if;

  v_required_qty := greatest(coalesce(nullif(v_item.quantity, 0), nullif(v_item.qty, 0), 1), 1);

  if coalesce(v_item.scanned_qty, 0) >= v_required_qty then
    return v_found || jsonb_build_object('ok', false, 'message', 'Qty item pesanan ini sudah lengkap.');
  end if;

  select p.*
    into v_actual_product
  from public.products p
  where p.product_id = p_actual_product_id
    and p.tenant_id = p_tenant_id
    and coalesce(p.status, 'active') = 'active'
  for update;

  if not found then
    return v_found || jsonb_build_object('ok', false, 'message', 'SKU lokal aktual tidak ditemukan atau tidak aktif.');
  end if;

  v_is_override := v_item.mapped_product_id is null or v_item.mapped_product_id <> p_actual_product_id;
  if v_is_override and v_note = '' then
    return v_found || jsonb_build_object('ok', false, 'message', 'Alasan/catatan user wajib diisi saat SKU aktual berbeda dari item order.');
  end if;

  select u.*
    into v_user
  from public.users u
  where u.user_id = auth.uid()
    and u.tenant_id = p_tenant_id
    and u.status = 'active'
  limit 1;

  v_marketplace_note := public.marketplace_extract_order_note(v_order.note, v_order.raw_order);
  v_new_scanned := least(v_required_qty, coalesce(v_item.scanned_qty, 0) + 1);

  update public.marketplace_order_items oi
     set scanned_qty = v_new_scanned,
         stock_action_status = case
           when v_new_scanned >= v_required_qty then 'scanned_done'
           else 'partial_scanned'
         end,
         last_error = null,
         updated_at = now()
   where oi.marketplace_order_item_id = v_item.marketplace_order_item_id;

  insert into public.marketplace_order_item_scans (
    tenant_id,
    marketplace_account_id,
    marketplace_order_id,
    marketplace_order_item_id,
    product_id,
    local_sku,
    scan_code,
    scan_status,
    scan_message,
    scanned_by
  ) values (
    p_tenant_id,
    v_item.marketplace_account_id,
    v_order_id,
    v_item.marketplace_order_item_id,
    p_actual_product_id,
    v_actual_product.kode_sku,
    'manual:' || v_actual_product.kode_sku,
    case when v_is_override then 'manual_override' else 'manual_matched' end,
    case
      when v_is_override then concat('Manual override SKU: ', coalesce(v_item.mapped_local_sku, '-'), ' -> ', v_actual_product.kode_sku)
      else concat('Manual pilih SKU order: ', v_actual_product.kode_sku)
    end,
    auth.uid()
  );

  if v_is_override then
    insert into public.marketplace_stock_out_fulfillment_overrides (
      tenant_id,
      marketplace_order_id,
      marketplace_order_item_id,
      marketplace_account_id,
      resi_code,
      marketplace,
      shop_name,
      external_order_id,
      order_sn,
      tracking_number,
      order_status,
      original_product_id,
      original_local_sku,
      original_product_name,
      marketplace_sku_id,
      marketplace_seller_sku,
      marketplace_product_name,
      marketplace_variant_name,
      actual_product_id,
      actual_local_sku,
      actual_barcode,
      actual_product_name,
      qty,
      marketplace_note,
      user_note,
      raw_context,
      created_by,
      created_by_name,
      created_by_email,
      created_by_role
    ) values (
      p_tenant_id,
      v_order_id,
      v_item.marketplace_order_item_id,
      v_item.marketplace_account_id,
      p_resi_code,
      v_order.marketplace,
      v_order.account_name,
      coalesce(nullif(v_order.external_order_id, ''), nullif(v_order.order_sn, ''), nullif(v_order.order_id, ''), v_order.marketplace_order_id::text),
      v_order.order_sn,
      coalesce(nullif(v_order.tracking_number, ''), nullif(v_order.label_code, ''), p_resi_code),
      coalesce(v_order.order_status, v_order.status),
      v_item.mapped_product_id,
      v_item.mapped_local_sku,
      v_item.local_product_name,
      v_item.marketplace_sku_id,
      coalesce(v_item.marketplace_seller_sku, v_item.seller_sku),
      coalesce(v_item.product_name, v_item.marketplace_product_name),
      coalesce(v_item.variant_name, v_item.marketplace_variant_name, v_item.variation_name),
      p_actual_product_id,
      v_actual_product.kode_sku,
      v_actual_product.kode_barcode,
      v_actual_product.nama_barang,
      1,
      v_marketplace_note,
      v_note,
      jsonb_build_object(
        'resi', p_resi_code,
        'marketplace_note', v_marketplace_note,
        'manual_selected_at', now(),
        'order_item_raw', v_item.raw_item
      ),
      v_user.user_id,
      v_user.nama,
      v_user.email,
      v_user.role_id
    );

    insert into public.audit_logs (
      tenant_id,
      user_id,
      nama_user,
      user_name,
      user_email,
      role_id,
      aktivitas,
      activity,
      modul,
      module,
      data_sebelum,
      before_data,
      data_sesudah,
      after_data
    ) values (
      p_tenant_id,
      v_user.user_id,
      v_user.nama,
      v_user.nama,
      v_user.email,
      v_user.role_id,
      'Override SKU stock out marketplace',
      'Marketplace stock out SKU override',
      'stock_out_marketplace',
      'stock_out_marketplace',
      jsonb_build_object(
        'resi', p_resi_code,
        'marketplace', v_order.marketplace,
        'shop_name', v_order.account_name,
        'order_id', coalesce(v_order.external_order_id, v_order.order_sn, v_order.order_id),
        'marketplace_order_item_id', v_item.marketplace_order_item_id,
        'original_product_id', v_item.mapped_product_id,
        'original_local_sku', v_item.mapped_local_sku,
        'marketplace_note', v_marketplace_note
      ),
      jsonb_build_object(
        'resi', p_resi_code,
        'marketplace', v_order.marketplace,
        'shop_name', v_order.account_name,
        'order_id', coalesce(v_order.external_order_id, v_order.order_sn, v_order.order_id),
        'marketplace_order_item_id', v_item.marketplace_order_item_id,
        'original_product_id', v_item.mapped_product_id,
        'original_local_sku', v_item.mapped_local_sku,
        'marketplace_note', v_marketplace_note
      ),
      jsonb_build_object(
        'actual_product_id', p_actual_product_id,
        'actual_local_sku', v_actual_product.kode_sku,
        'actual_product_name', v_actual_product.nama_barang,
        'qty', 1,
        'user_note', v_note,
        'stock_out_user_id', v_user.user_id,
        'stock_out_user_name', v_user.nama
      ),
      jsonb_build_object(
        'actual_product_id', p_actual_product_id,
        'actual_local_sku', v_actual_product.kode_sku,
        'actual_product_name', v_actual_product.nama_barang,
        'qty', 1,
        'user_note', v_note,
        'stock_out_user_id', v_user.user_id,
        'stock_out_user_name', v_user.nama
      )
    );
  end if;

  v_ready := public.marketplace_mark_order_scan_state(p_tenant_id, v_order_id);

  return public.marketplace_find_order_by_resi(p_tenant_id, p_resi_code)
    || jsonb_build_object(
      'ok', true,
      'message', case
        when v_is_override then concat('SKU aktual dipilih: ', v_actual_product.kode_sku, '. Override tersimpan di audit/resi.')
        else 'Item berhasil ditandai sudah discan.'
      end,
      'item_id', v_item.marketplace_order_item_id,
      'actual_product_id', p_actual_product_id,
      'actual_local_sku', v_actual_product.kode_sku,
      'manual_override', v_is_override,
      'order_ready_to_finalize', v_ready
    );
end;
$function$;

grant execute on function public.marketplace_scan_order_item_manual_override_by_resi(uuid, text, uuid, uuid, text)
  to authenticated, service_role;

create or replace function public.marketplace_finalize_scanned_order_stock_out(
  p_tenant_id uuid,
  p_marketplace_order_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_order record;
  v_item record;
  v_actual record;
  v_user record;
  v_done integer := 0;
  v_failed integer := 0;
  v_note text;
  v_stock_transaction_id uuid;
  v_first_stock_transaction_id uuid;
  v_resi text;
  v_required_qty numeric;
  v_override_total numeric;
  v_marketplace_note text;
begin
  perform public.marketplace_assert_tenant_access(p_tenant_id);

  select
    o.*,
    coalesce(nullif(ma.store_alias, ''), nullif(ma.shop_name, ''), nullif(o.shop_id, ''), '-') as account_name
    into v_order
  from public.marketplace_orders as o
  left join public.marketplace_accounts ma
    on ma.marketplace_account_id = o.marketplace_account_id
   and ma.tenant_id = o.tenant_id
  where o.tenant_id = p_tenant_id
    and o.marketplace_order_id = p_marketplace_order_id
  for update of o;

  if not found then
    raise exception 'Marketplace order tidak ditemukan.';
  end if;

  select u.*
    into v_user
  from public.users u
  where u.user_id = auth.uid()
    and u.tenant_id = p_tenant_id
    and u.status = 'active'
  limit 1;

  v_resi := coalesce(
    nullif(v_order.tracking_number, ''),
    nullif(v_order.label_code, ''),
    nullif(v_order.package_id, ''),
    nullif(v_order.remote_package_id, ''),
    nullif(v_order.external_order_id, ''),
    nullif(v_order.order_sn, ''),
    nullif(v_order.remote_order_id, '')
  );

  v_marketplace_note := public.marketplace_extract_order_note(v_order.note, v_order.raw_order);

  if exists (
    select 1
    from public.marketplace_order_items as i
    where i.marketplace_order_id = p_marketplace_order_id
      and i.tenant_id = p_tenant_id
      and coalesce(i.stock_action_status, '') <> 'stock_out_done'
      and coalesce(i.scanned_qty, 0) < greatest(coalesce(nullif(i.quantity, 0), nullif(i.qty, 0), 1), 1)
  ) then
    raise exception 'Belum semua item discan. Final stock out diblokir.';
  end if;

  if exists (
    select 1
    from public.marketplace_order_items as i
    where i.marketplace_order_id = p_marketplace_order_id
      and i.tenant_id = p_tenant_id
      and coalesce(i.stock_action_status, '') <> 'stock_out_done'
      and (coalesce(i.mapping_status, '') <> 'mapped' or i.mapped_product_id is null)
      and coalesce((
        select sum(fo.qty)
        from public.marketplace_stock_out_fulfillment_overrides fo
        where fo.tenant_id = i.tenant_id
          and fo.marketplace_order_item_id = i.marketplace_order_item_id
      ), 0) < greatest(coalesce(nullif(i.quantity, 0), nullif(i.qty, 0), 1), 1)
  ) then
    raise exception 'Masih ada item order yang belum mapping atau belum punya override SKU aktual.';
  end if;

  for v_item in
    select *
    from public.marketplace_order_items as i
    where i.marketplace_order_id = p_marketplace_order_id
      and i.tenant_id = p_tenant_id
      and coalesce(i.stock_action_status, '') <> 'stock_out_done'
    order by i.created_at asc
    for update
  loop
    begin
      v_first_stock_transaction_id := null;
      v_required_qty := greatest(coalesce(nullif(v_item.quantity, 0), nullif(v_item.qty, 0), 1), 1);

      select coalesce(sum(fo.qty), 0)
        into v_override_total
      from public.marketplace_stock_out_fulfillment_overrides fo
      where fo.tenant_id = p_tenant_id
        and fo.marketplace_order_item_id = v_item.marketplace_order_item_id;

      if coalesce(v_override_total, 0) > v_required_qty then
        raise exception 'Qty override melebihi qty order untuk item %', v_item.marketplace_order_item_id;
      end if;

      for v_actual in
        with override_groups as (
          select
            fo.actual_product_id as product_id,
            max(fo.actual_local_sku) as local_sku,
            max(fo.actual_product_name) as product_name,
            sum(fo.qty) as quantity,
            true as is_override,
            string_agg(distinct fo.user_note, '; ' order by fo.user_note) as override_note
          from public.marketplace_stock_out_fulfillment_overrides fo
          where fo.tenant_id = p_tenant_id
            and fo.marketplace_order_item_id = v_item.marketplace_order_item_id
          group by fo.actual_product_id
        ),
        mapped_remainder as (
          select
            v_item.mapped_product_id as product_id,
            v_item.mapped_local_sku as local_sku,
            coalesce(v_item.local_product_name, v_item.mapped_local_sku, '-') as product_name,
            v_required_qty - coalesce(v_override_total, 0) as quantity,
            false as is_override,
            null::text as override_note
          where v_required_qty - coalesce(v_override_total, 0) > 0
        )
        select * from override_groups
        union all
        select * from mapped_remainder
      loop
        if v_actual.product_id is null or coalesce(v_actual.quantity, 0) <= 0 then
          continue;
        end if;

        v_note := concat(
          'Marketplace order scan stock out ',
          v_order.marketplace,
          ' #',
          coalesce(v_order.external_order_id, v_order.order_sn, v_order.remote_order_id, '-'),
          ' item ',
          coalesce(v_item.seller_sku, v_item.marketplace_sku_id, '-'),
          case
            when v_actual.is_override then concat(
              ' | OVERRIDE SKU dari ',
              coalesce(v_item.mapped_local_sku, '-'),
              ' ke ',
              coalesce(v_actual.local_sku, '-'),
              ' | Resi ',
              coalesce(v_resi, '-'),
              ' | Toko ',
              coalesce(v_order.account_name, '-'),
              ' | Catatan marketplace ',
              coalesce(v_marketplace_note, '-'),
              ' | Alasan user ',
              coalesce(v_actual.override_note, '-')
            )
            else ''
          end
        );

        v_stock_transaction_id := public.register_stock_transaction(
          v_actual.product_id,
          'OUT',
          v_actual.quantity,
          case when v_actual.is_override then 'marketplace_order_manual_override' else 'marketplace_order_scan' end,
          v_note,
          null,
          null
        );

        v_first_stock_transaction_id := coalesce(v_first_stock_transaction_id, v_stock_transaction_id);

        update public.stock_transactions as st
           set nomor_resi = v_resi,
               tenant_id = p_tenant_id,
               tujuan = coalesce(st.tujuan, case when v_actual.is_override then 'marketplace_order_manual_override' else 'marketplace_order_scan' end)
         where st.stock_transaction_id = v_stock_transaction_id;

        insert into public.marketplace_order_stock_movements (
          marketplace_order_id,
          marketplace_order_item_id,
          tenant_id,
          marketplace_account_id,
          product_id,
          local_sku,
          quantity,
          action_type,
          movement_status,
          stock_transaction_id,
          created_by
        ) values (
          v_item.marketplace_order_id,
          v_item.marketplace_order_item_id,
          v_item.tenant_id,
          v_item.marketplace_account_id,
          v_actual.product_id,
          v_actual.local_sku,
          v_actual.quantity,
          case when v_actual.is_override then 'scan_stock_out_manual_override' else 'scan_stock_out' end,
          'done',
          v_stock_transaction_id,
          auth.uid()
        );

        if v_actual.is_override then
          update public.marketplace_stock_out_fulfillment_overrides fo
             set stock_transaction_id = v_stock_transaction_id,
                 stock_out_by = v_user.user_id,
                 stock_out_by_name = v_user.nama,
                 stock_out_by_email = v_user.email,
                 stock_out_by_role = v_user.role_id,
                 stock_out_at = now(),
                 updated_at = now()
           where fo.tenant_id = p_tenant_id
             and fo.marketplace_order_item_id = v_item.marketplace_order_item_id
             and fo.actual_product_id = v_actual.product_id
             and fo.stock_transaction_id is null;

          insert into public.marketplace_stock_out_reviews (
            tenant_id,
            stock_transaction_id,
            marketplace_order_id,
            marketplace_order_item_id,
            marketplace_account_id,
            external_order_id,
            order_sn,
            tracking_number,
            marketplace,
            shop_name,
            marketplace_order_status,
            order_status,
            product_id,
            local_product_id,
            local_sku,
            product_name,
            local_product_name,
            qty,
            stock_out_qty,
            tujuan,
            match_mode_enabled,
            match_status,
            review_status,
            risk_flag,
            risk_status,
            risk_message,
            review_type,
            review_reason,
            note,
            created_by,
            created_by_name,
            created_by_email,
            created_by_role,
            stock_out_by,
            stock_out_by_name,
            stock_out_by_email,
            stock_out_by_role,
            stock_out_at
          ) values (
            p_tenant_id,
            v_stock_transaction_id,
            v_order.marketplace_order_id,
            v_item.marketplace_order_item_id,
            v_order.marketplace_account_id,
            coalesce(nullif(v_order.external_order_id, ''), nullif(v_order.order_sn, ''), nullif(v_order.order_id, ''), v_order.marketplace_order_id::text),
            v_order.order_sn,
            v_resi,
            v_order.marketplace,
            v_order.account_name,
            coalesce(v_order.order_status, v_order.status),
            coalesce(v_order.order_status, v_order.status),
            v_actual.product_id,
            v_actual.product_id,
            v_actual.local_sku,
            v_actual.product_name,
            v_actual.product_name,
            v_actual.quantity,
            v_actual.quantity,
            'marketplace_order_manual_override',
            true,
            'mismatch',
            'needs_action',
            'manual_sku_override',
            'pending',
            'SKU aktual stock out berbeda dari SKU order/mapping. Cek catatan marketplace dan alasan user.',
            'manual_sku_override',
            v_actual.override_note,
            concat(
              'Resi: ', coalesce(v_resi, '-'),
              E'\nMarketplace: ', coalesce(v_order.marketplace, '-'),
              E'\nToko/Penjual: ', coalesce(v_order.account_name, '-'),
              E'\nOrder: ', coalesce(v_order.external_order_id, v_order.order_sn, v_order.order_id, '-'),
              E'\nSKU order/mapping: ', coalesce(v_item.mapped_local_sku, '-'),
              E'\nSKU aktual: ', coalesce(v_actual.local_sku, '-'),
              E'\nCatatan marketplace: ', coalesce(v_marketplace_note, '-'),
              E'\nAlasan user: ', coalesce(v_actual.override_note, '-'),
              E'\nUser stock out: ', coalesce(v_user.nama, '-'), ' / ', coalesce(v_user.email, '-')
            ),
            v_user.user_id,
            v_user.nama,
            v_user.email,
            v_user.role_id,
            v_user.user_id,
            v_user.nama,
            v_user.email,
            v_user.role_id,
            now()
          );

          insert into public.audit_logs (
            tenant_id,
            user_id,
            nama_user,
            user_name,
            user_email,
            role_id,
            aktivitas,
            activity,
            modul,
            module,
            data_sebelum,
            before_data,
            data_sesudah,
            after_data
          ) values (
            p_tenant_id,
            v_user.user_id,
            v_user.nama,
            v_user.nama,
            v_user.email,
            v_user.role_id,
            'Final stock out override SKU marketplace',
            'Marketplace stock out override finalized',
            'stock_out_marketplace',
            'stock_out_marketplace',
            jsonb_build_object(
              'resi', v_resi,
              'marketplace', v_order.marketplace,
              'shop_name', v_order.account_name,
              'order_id', coalesce(v_order.external_order_id, v_order.order_sn, v_order.order_id),
              'marketplace_order_item_id', v_item.marketplace_order_item_id,
              'original_local_sku', v_item.mapped_local_sku,
              'marketplace_note', v_marketplace_note
            ),
            jsonb_build_object(
              'resi', v_resi,
              'marketplace', v_order.marketplace,
              'shop_name', v_order.account_name,
              'order_id', coalesce(v_order.external_order_id, v_order.order_sn, v_order.order_id),
              'marketplace_order_item_id', v_item.marketplace_order_item_id,
              'original_local_sku', v_item.mapped_local_sku,
              'marketplace_note', v_marketplace_note
            ),
            jsonb_build_object(
              'actual_product_id', v_actual.product_id,
              'actual_local_sku', v_actual.local_sku,
              'actual_product_name', v_actual.product_name,
              'qty', v_actual.quantity,
              'stock_transaction_id', v_stock_transaction_id,
              'user_note', v_actual.override_note,
              'stock_out_user_id', v_user.user_id,
              'stock_out_user_name', v_user.nama
            ),
            jsonb_build_object(
              'actual_product_id', v_actual.product_id,
              'actual_local_sku', v_actual.local_sku,
              'actual_product_name', v_actual.product_name,
              'qty', v_actual.quantity,
              'stock_transaction_id', v_stock_transaction_id,
              'user_note', v_actual.override_note,
              'stock_out_user_id', v_user.user_id,
              'stock_out_user_name', v_user.nama
            )
          );
        else
          if v_item.marketplace_sku_map_id is not null then
            perform public.marketplace_queue_available_stock_sync_for_mapping(
              p_tenant_id,
              v_item.marketplace_sku_map_id,
              'marketplace_order_scan_stock_out'
            );
          end if;
        end if;

        perform public.marketplace_queue_stock_sync_for_product_change(
          v_actual.product_id,
          case when v_actual.is_override then 'marketplace_order_manual_override_stock_out' else 'marketplace_order_scan_stock_out' end
        );
      end loop;

      update public.marketplace_order_items as i
         set stock_action_status = 'stock_out_done',
             reserved_qty = 0,
             stock_out_at = now(),
             last_error = null,
             updated_at = now()
       where i.marketplace_order_item_id = v_item.marketplace_order_item_id;

      update public.marketplace_orders as o
         set stock_transaction_id = coalesce(o.stock_transaction_id, v_first_stock_transaction_id)
       where o.marketplace_order_id = p_marketplace_order_id
         and o.tenant_id = p_tenant_id;

      v_done := v_done + 1;
    exception when others then
      update public.marketplace_order_items as i
         set stock_action_status = 'stock_out_failed',
             last_error = sqlerrm,
             updated_at = now()
       where i.marketplace_order_item_id = v_item.marketplace_order_item_id;

      insert into public.marketplace_order_stock_movements (
        marketplace_order_id,
        marketplace_order_item_id,
        tenant_id,
        marketplace_account_id,
        product_id,
        local_sku,
        quantity,
        action_type,
        movement_status,
        error_message,
        created_by
      ) values (
        v_item.marketplace_order_id,
        v_item.marketplace_order_item_id,
        v_item.tenant_id,
        v_item.marketplace_account_id,
        coalesce(v_item.mapped_product_id, null),
        v_item.mapped_local_sku,
        v_required_qty,
        'scan_stock_out',
        'failed',
        sqlerrm,
        auth.uid()
      );

      v_failed := v_failed + 1;
    end;
  end loop;

  update public.marketplace_orders as o
     set stock_action_status = case when v_failed > 0 then 'stock_out_failed' else 'stock_out_done' end,
         stock_out_at = case when v_failed > 0 then o.stock_out_at else now() end,
         packed_at = case when v_failed > 0 then o.packed_at else now() end,
         last_error = case when v_failed > 0 then concat(v_failed, ' item gagal final stock out.') else null end,
         updated_at = now()
   where o.marketplace_order_id = p_marketplace_order_id
     and o.tenant_id = p_tenant_id;

  return jsonb_build_object(
    'ok', v_failed = 0,
    'processed', v_done,
    'failed', v_failed,
    'message', case
      when v_failed > 0 then concat(v_failed, ' item gagal final stock out.')
      else concat(v_done, ' item final stock out berhasil.')
    end,
    'tracking_number', v_resi
  );
end;
$function$;

grant execute on function public.marketplace_find_order_by_resi(uuid, text) to authenticated, service_role;
grant execute on function public.marketplace_mark_order_scan_state(uuid, uuid) to authenticated, service_role;
grant execute on function public.marketplace_finalize_scanned_order_stock_out(uuid, uuid) to authenticated, service_role;
