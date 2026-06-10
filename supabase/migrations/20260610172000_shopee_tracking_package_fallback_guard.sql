-- Permanent Shopee tracking fallback guard.
-- Prevents future Shopee orders from having empty tracking_number/label_code
-- when Shopee stores the shipment number under raw_order.package_list[0].package_number.
-- Does not touch Finance/HPP/UI.

create or replace function public.fill_shopee_tracking_from_raw_order()
returns trigger
language plpgsql
as $$
declare
  v_tracking text;
begin
  if new.marketplace = 'shopee' then
    v_tracking := coalesce(
      nullif(new.raw_order #>> '{package_list,0,tracking_number}', ''),
      nullif(new.raw_order #>> '{package_list,0,tracking_no}', ''),
      nullif(new.raw_order #>> '{package_list,0,package_number}', '')
    );

    if v_tracking is not null then
      if new.tracking_number is null or new.tracking_number = '' then
        new.tracking_number := v_tracking;
      end if;

      if new.label_code is null or new.label_code = '' then
        new.label_code := v_tracking;
      end if;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_fill_shopee_tracking_from_raw_order on public.marketplace_orders;

create trigger trg_fill_shopee_tracking_from_raw_order
before insert or update of marketplace, raw_order, tracking_number, label_code
on public.marketplace_orders
for each row
execute function public.fill_shopee_tracking_from_raw_order();

-- One-time correction for already-pulled Shopee rows. This is not a recurring backfill.
update public.marketplace_orders
set
  tracking_number = coalesce(
    nullif(tracking_number, ''),
    nullif(raw_order #>> '{package_list,0,tracking_number}', ''),
    nullif(raw_order #>> '{package_list,0,tracking_no}', ''),
    nullif(raw_order #>> '{package_list,0,package_number}', '')
  ),
  label_code = coalesce(
    nullif(label_code, ''),
    nullif(raw_order #>> '{package_list,0,tracking_number}', ''),
    nullif(raw_order #>> '{package_list,0,tracking_no}', ''),
    nullif(raw_order #>> '{package_list,0,package_number}', '')
  ),
  updated_at = now()
where marketplace = 'shopee'
  and (
    tracking_number is null or tracking_number = ''
    or label_code is null or label_code = ''
  )
  and coalesce(
    nullif(raw_order #>> '{package_list,0,tracking_number}', ''),
    nullif(raw_order #>> '{package_list,0,tracking_no}', ''),
    nullif(raw_order #>> '{package_list,0,package_number}', '')
  ) is not null;

comment on function public.fill_shopee_tracking_from_raw_order() is
  'Fills Shopee tracking_number/label_code from raw_order.package_list fallback when parser leaves them blank.';
