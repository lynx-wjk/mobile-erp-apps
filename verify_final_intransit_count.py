import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("=== FINAL COUNT OF REMAINING IN-TRANSIT ORDERS IN DATABASE ===")
sql = """
SELECT marketplace, order_status, count(*)
FROM marketplace_orders
WHERE order_status IN ('IN_TRANSIT', 'SHIPPED', 'AWAITING_COLLECTION', 'AWAITING_SHIPMENT')
GROUP BY marketplace, order_status;
"""
print(run_sql(sql))

