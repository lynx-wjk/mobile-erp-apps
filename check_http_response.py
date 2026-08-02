import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- NET HTTP RESPONSES ---")
sql_resp = """
SELECT id, status_code, body
FROM net.http_collect(2902);
"""
print("2902:", run_sql(sql_resp))

sql_resp2 = """
SELECT id, status_code, body
FROM net.http_collect(2903);
"""
print("2903:", run_sql(sql_resp2))

print("\n--- TIKTOK ORDERS MISSING ITEMS NOW ---")
sql_missing = """
SELECT count(o.marketplace_order_id)
FROM marketplace_orders o
LEFT JOIN marketplace_order_items i ON i.marketplace_order_id = o.marketplace_order_id
WHERE lower(o.marketplace) LIKE '%tiktok%'
  AND i.marketplace_order_item_id IS NULL;
"""
print("Missing count:", run_sql(sql_missing))

