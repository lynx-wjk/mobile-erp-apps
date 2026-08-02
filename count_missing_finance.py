import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- COUNT TOTAL TIKTOK ORDERS MISSING FINANCE REPORTS ---")
sql_count = """
SELECT count(*)
FROM marketplace_orders o
LEFT JOIN marketplace_finance_reports f ON (
    f.marketplace_order_id = o.marketplace_order_id OR f.order_id = o.external_order_id OR f.order_id = o.order_sn
)
WHERE lower(o.marketplace) LIKE '%tiktok%'
  AND f.finance_report_id IS NULL;
"""
print("Total missing finance reports:", run_sql(sql_count))

print("\n--- POSITION OF ORDER 584871522068366376 IN THE QUEUE ---")
sql_pos = """
WITH ordered_candidates AS (
    SELECT o.external_order_id, ROW_NUMBER() OVER (ORDER BY o.order_created_at ASC) as row_num
    FROM marketplace_orders o
    LEFT JOIN marketplace_finance_reports f ON (
        f.marketplace_order_id = o.marketplace_order_id OR f.order_id = o.external_order_id OR f.order_id = o.order_sn
    )
    WHERE lower(o.marketplace) LIKE '%tiktok%'
      AND f.finance_report_id IS NULL
)
SELECT row_num, external_order_id
FROM ordered_candidates
WHERE external_order_id = '584871522068366376';
"""
print("Position:", run_sql(sql_pos))

