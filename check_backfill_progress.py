import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("=== CHECK COUNT OF TIKTOK COMPLETED/DELIVERED ORDERS STILL WITHOUT PAYOUT ===")
sql_no_payout = """
SELECT upper(o.order_status) as status, count(*)
FROM marketplace_orders o
WHERE o.marketplace_account_id = '6a6a6d63-fffb-431a-8812-191b9d87a84d'
  AND (coalesce(o.paid_at, o.order_created_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date >= '2026-07-01'
  AND upper(o.order_status) IN ('COMPLETED', 'DELIVERED')
  AND NOT EXISTS (
    SELECT 1 FROM marketplace_finance_reports fr
    WHERE fr.marketplace_account_id = o.marketplace_account_id
      AND (fr.order_id = o.order_id OR fr.order_id = o.external_order_id OR fr.order_id = o.order_sn)
      AND coalesce(fr.net_settlement, fr.payout_amount, 0) > 0
  )
GROUP BY upper(o.order_status);
"""
print(run_sql(sql_no_payout))

