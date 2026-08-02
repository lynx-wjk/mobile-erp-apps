import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- 1. LATEST 5 TIKTOK ORDERS CREATED / SYNCED ---")
sql_latest = """
SELECT external_order_id, order_status, order_created_at, updated_at
FROM marketplace_orders
WHERE lower(marketplace) LIKE '%tiktok%'
ORDER BY order_created_at DESC LIMIT 5;
"""
print(run_sql(sql_latest))

print("\n--- 2. LATEST 5 TIKTOK FINANCE REPORTS PULLED ---")
sql_latest_fin = """
SELECT order_id, statement_id, gross_amount, received_amount, net_settlement, pulled_at
FROM marketplace_finance_reports
WHERE lower(marketplace) LIKE '%tiktok%'
ORDER BY pulled_at DESC LIMIT 5;
"""
print(run_sql(sql_latest_fin))

