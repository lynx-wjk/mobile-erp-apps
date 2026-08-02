import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("=== SAMPLE COMPLETED ORDERS FROM JULY 1 ===")
sql_sample = """
SELECT marketplace_order_id, order_id, external_order_id, order_sn, order_status, order_created_at
FROM marketplace_orders
WHERE marketplace_account_id = '6a6a6d63-fffb-431a-8812-191b9d87a84d'
  AND upper(order_status) = 'COMPLETED'
  AND (coalesce(paid_at, order_created_at) at time zone 'Asia/Jakarta')::date >= '2026-07-01'
LIMIT 5;
"""
sample_rows = run_sql(sql_sample)
print(sample_rows)

for line in sample_rows.split('\n'):
    if not line.strip():
        continue
    parts = line.split('|')
    mo_id, oid, ext_id, sn, status, created = parts
    print(f"\nChecking order_id={oid}, ext_id={ext_id}, sn={sn} in marketplace_finance_reports:")
    sql_fr = f"""
    SELECT id, order_id, marketplace_order_id, payout_amount, net_settlement, received_amount, status
    FROM marketplace_finance_reports
    WHERE marketplace_account_id = '6a6a6d63-fffb-431a-8812-191b9d87a84d'
      AND (order_id = '{oid}' OR order_id = '{ext_id}' OR order_id = '{sn}' OR marketplace_order_id = '{mo_id}');
    """
    print(run_sql(sql_fr) or "NOT FOUND IN MARKETPLACE_FINANCE_REPORTS")

