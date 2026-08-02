import subprocess

sql = """
with vars as (
  select
    '2026-07-14'::date as start_date,
    '2026-07-15'::date as end_date,
    'tiktok_shop' as marketplace_filter
),
order_pool as (
  select
    o.order_id,
    o.marketplace_order_id,
    o.paid_at,
    upper(coalesce(o.order_status, o.status, '')) as order_status,
    (coalesce(o.paid_at, o.order_created_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date as order_date_wib,
    coalesce(o.updated_at, o.pulled_at, o.created_at) as sort_at
  from public.marketplace_orders o
  cross join vars v
  where (
      v.marketplace_filter is null
      or v.marketplace_filter in ('all', 'semua', 'semua platform', '-')
      or lower(coalesce(o.marketplace, '')) = v.marketplace_filter
    )
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
    and not exists (
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
select count(*) from order_pool;
"""

cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -c "{sql}"']
res = subprocess.run(cmd, text=True, capture_output=True)
print("STDOUT:", res.stdout)
print("STDERR:", res.stderr)
