-- Existing table backfill only. No new RPC.
-- Extract likely physical shipping-label resi/AWB/tracking values from raw JSON.
-- Exclude OFG/package/order references and long numeric package ids.

with recursive walk(
  marketplace_order_id,
  marketplace,
  order_sn,
  external_order_id,
  order_id,
  key_name,
  val
) as (
  select
    o.marketplace_order_id,
    o.marketplace,
    o.order_sn,
    o.external_order_id,
    o.order_id,
    null::text as key_name,
    o.raw_order as val
  from public.marketplace_orders o
  where o.raw_order is not null

  union all

  select
    w.marketplace_order_id,
    w.marketplace,
    w.order_sn,
    w.external_order_id,
    w.order_id,
    child.key_name,
    child.val
  from walk w
  cross join lateral (
    select
      e.key::text as key_name,
      e.value as val
    from jsonb_each(
      case when jsonb_typeof(w.val) = 'object' then w.val else '{}'::jsonb end
    ) e

    union all

    select
      w.key_name as key_name,
      a.value as val
    from jsonb_array_elements(
      case when jsonb_typeof(w.val) = 'array' then w.val else '[]'::jsonb end
    ) as a(value)
  ) child
),
candidates as (
  select
    marketplace_order_id,
    val #>> '{}' as resi,
    key_name
  from walk
  where jsonb_typeof(val) = 'string'
    and lower(coalesce(key_name, '')) in (
      'tracking_number',
      'tracking_no',
      'trackingno',
      'awb',
      'awb_no',
      'airway_bill_no',
      'airwaybill_no',
      'waybill_no',
      'waybill',
      'logistics_tracking_number',
      'shipping_tracking_number',
      'delivery_tracking_number'
    )
),
clean as (
  select
    o.marketplace_order_id,
    trim(c.resi) as resi,
    row_number() over (
      partition by o.marketplace_order_id
      order by
        case
          when lower(c.key_name) in ('tracking_number','tracking_no','awb','awb_no') then 0
          else 1
        end,
        length(trim(c.resi)) desc
    ) as rn
  from public.marketplace_orders o
  join candidates c on c.marketplace_order_id = o.marketplace_order_id
  where c.resi is not null
    and trim(c.resi) <> ''
    and trim(c.resi) <> '-'
    and upper(trim(c.resi)) not like 'OFG%'
    and trim(c.resi) !~ '^[0-9]{16,}$'
    and lower(trim(c.resi)) not in (
      lower(coalesce(o.order_sn,'')),
      lower(coalesce(o.external_order_id,'')),
      lower(coalesce(o.order_id,''))
    )
),
chosen as (
  select marketplace_order_id, resi
  from clean
  where rn = 1
)
update public.marketplace_orders o
set tracking_number = chosen.resi,
    updated_at = now()
from chosen
where chosen.marketplace_order_id = o.marketplace_order_id
  and (
    o.tracking_number is null
    or trim(o.tracking_number) = ''
    or trim(o.tracking_number) = '-'
    or upper(o.tracking_number) like 'OFG%'
    or o.tracking_number ~ '^[0-9]{16,}$'
  );

update public.marketplace_order_items oi
set tracking_number = o.tracking_number,
    updated_at = now()
from public.marketplace_orders o
where o.marketplace_order_id = oi.marketplace_order_id
  and o.tenant_id = oi.tenant_id
  and o.tracking_number is not null
  and trim(o.tracking_number) <> ''
  and trim(o.tracking_number) <> '-'
  and upper(o.tracking_number) not like 'OFG%'
  and o.tracking_number !~ '^[0-9]{16,}$'
  and (
    oi.tracking_number is null
    or trim(oi.tracking_number) = ''
    or trim(oi.tracking_number) = '-'
    or upper(oi.tracking_number) like 'OFG%'
    or oi.tracking_number ~ '^[0-9]{16,}$'
  );

select
  marketplace,
  count(*) filter (
    where tracking_number is not null
      and trim(tracking_number) <> ''
      and trim(tracking_number) <> '-'
      and upper(tracking_number) not like 'OFG%'
      and tracking_number !~ '^[0-9]{16,}$'
  ) as physical_resi_rows,
  count(*) as total_orders
from public.marketplace_orders
group by marketplace
order by marketplace;
