
CREATE OR REPLACE FUNCTION public.finance_order_candidates_for_period_v3(
  p_start date DEFAULT NULL::date,
  p_end date DEFAULT NULL::date,
  p_marketplace text DEFAULT 'tiktok_shop'::text,
  p_account_id uuid DEFAULT NULL::uuid,
  p_limit integer DEFAULT 150,
  p_missing_only boolean DEFAULT true,
  p_tenant_id uuid DEFAULT NULL::uuid
)
RETURNS TABLE(order_id text, marketplace_account_id uuid)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
with vars as (
  select
    coalesce(p_tenant_id, public.app_current_tenant_id_or_default()) as tenant_id,
    greatest(coalesce(p_start, current_date - 90), current_date - 1000) as start_date,
    least(coalesce(p_end, current_date), current_date) as end_date,
    nullif(lower(trim(coalesce(p_marketplace, ''))), '') as marketplace_filter,
    greatest(1, least(coalesce(p_limit, 150), 500)) as row_limit
),
order_pool as (
  select
    coalesce(
      nullif(o.order_id, ''),
      nullif(o.external_order_id, ''),
      nullif(o.order_sn, ''),
      o.marketplace_order_id::text
    ) as finance_order_key,
    o.marketplace_account_id
  from public.marketplace_orders o
  cross join vars v
  where o.tenant_id = v.tenant_id
    and (
      v.marketplace_filter is null
      or v.marketplace_filter in ('all', 'semua', 'semua platform', '-')
      or lower(coalesce(o.marketplace, '')) = v.marketplace_filter
    )
    and (p_account_id is null or o.marketplace_account_id = p_account_id)
    and (coalesce(o.paid_at, o.order_created_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date
      between v.start_date and v.end_date
    and coalesce(o.total_amount, o.gross_amount, o.paid_amount, 0) > 0
    and upper(coalesce(o.order_status, o.status, '')) not like all (
      array['%CANCEL%', '%CANCELED%', '%UNPAID%', '%REFUND%', '%RETURN%', '%FAILED%', '%CLOSE%']
    )
    and (
      o.paid_at is not null
      or coalesce(o.paid_amount, 0) > 0
      or upper(coalesce(o.payment_status, '')) in ('PAID', 'PAID_COMPLETED', 'SETTLED', 'COMPLETED')
      or upper(coalesce(o.order_status, o.status, '')) in (
        'AWAITING_SHIPMENT', 'AWAITING_COLLECTION', 'IN_TRANSIT', 'DELIVERED', 'COMPLETED'
      )
    )
    and coalesce(
      nullif(o.order_id, ''),
      nullif(o.external_order_id, ''),
      nullif(o.order_sn, ''),
      o.marketplace_order_id::text
    ) is not null
    and (
      not p_missing_only
      or not exists (
        select 1
        from public.marketplace_finance_reports fr
        where fr.tenant_id = o.tenant_id
          and fr.marketplace_account_id = o.marketplace_account_id
          and lower(coalesce(fr.marketplace, '')) = lower(coalesce(o.marketplace, ''))
          and (
            fr.marketplace_order_id = o.marketplace_order_id
            or fr.order_id = nullif(o.order_id, '')
            or fr.order_id = nullif(o.external_order_id, '')
            or fr.order_id = nullif(o.order_sn, '')
            or fr.order_id = o.marketplace_order_id::text
          )
          and (
            coalesce(fr.payout_amount, fr.received_amount, fr.net_settlement, 0) <> 0
            or coalesce(fr.pulled_at, fr.updated_at, fr.created_at) > now() - interval '6 hours'
          )
      )
    )
  order by
    case
      when upper(coalesce(o.order_status, o.status, '')) in ('COMPLETED', 'DELIVERED') then 0
      when upper(coalesce(o.order_status, o.status, '')) in ('IN_TRANSIT', 'AWAITING_COLLECTION') then 1
      else 2
    end,
    coalesce(o.updated_at, o.pulled_at, o.created_at) nulls first,
    (coalesce(o.paid_at, o.order_created_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date desc,
    coalesce(nullif(o.order_id, ''), nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) desc
  limit (
    select least(row_limit * 80, 4000)
    from vars
  )
)
select * from order_pool
limit (
  select row_limit from vars
);
$function$;
