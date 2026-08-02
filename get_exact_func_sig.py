import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print(run_sql("""
SELECT proname, pg_get_function_arguments(oid)
FROM pg_proc
WHERE proname IN ('finance_dashboard_snapshot', 'finance_sku_summary_rows', 'finance_sku_order_details_group_20260625');
"""))

