import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- COUNT TIKTOK ORDERS STILL MISSING FINANCE REPORTS ---")
sql_missing = """
SELECT count(*)
FROM marketplace_orders o
LEFT JOIN marketplace_finance_reports f ON (
    f.marketplace_order_id = o.marketplace_order_id OR f.order_id = o.external_order_id OR f.order_id = o.order_sn
)
WHERE lower(o.marketplace) LIKE '%tiktok%'
  AND f.finance_report_id IS NULL;
"""
print("Total missing:", run_sql(sql_missing))

print("\n--- SAMPLE OF POPULATED TIKTOK FINANCE REPORTS ---")
sql_sample = """
SELECT f.order_id, f.statement_id, f.gross_amount, f.net_settlement, f.received_amount, f.settlement_date, f.pulled_at
FROM marketplace_finance_reports f
WHERE lower(f.marketplace) LIKE '%tiktok%'
ORDER BY f.pulled_at DESC LIMIT 10;
"""
print(run_sql(sql_sample))

