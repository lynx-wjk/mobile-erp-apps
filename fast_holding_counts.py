import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- 1. TOTAL ORDERS BY MARKETPLACE & STATUS ---")
sql1 = """
SELECT marketplace, order_status, count(*)
FROM marketplace_orders
GROUP BY marketplace, order_status;
"""
print(run_sql(sql1))

print("\n--- 2. TOTAL FINANCE REPORTS IN DATABASE ---")
sql2 = """
SELECT marketplace, count(*), sum(case when received_amount > 0 then 1 else 0 end) as settled_count, sum(case when received_amount = 0 then 1 else 0 end) as zero_count
FROM marketplace_finance_reports
GROUP BY marketplace;
"""
print(run_sql(sql2))

print("\n--- 3. UNSETTLED / MISSING PAYOUT ORDERS COUNT ---")
sql3 = """
SELECT o.marketplace, count(o.marketplace_order_id)
FROM marketplace_orders o
WHERE NOT EXISTS (
    SELECT 1 FROM marketplace_finance_reports f
    WHERE f.marketplace_order_id = o.marketplace_order_id OR f.order_id = o.external_order_id
)
GROUP BY o.marketplace;
"""
print(run_sql(sql3))

