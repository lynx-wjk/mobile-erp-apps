import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

order_id = '584871522068366376'

print(f"--- VERIFY MARKETPLACE_FINANCE_REPORTS FOR {order_id} ---")
sql_report = f"""
SELECT finance_report_id, order_id, statement_id, gross_amount, received_amount, net_settlement, total_fees, status, settlement_date, pulled_at
FROM marketplace_finance_reports
WHERE order_id = '{order_id}' OR statement_id = '{order_id}';
"""
print(run_sql(sql_report))

