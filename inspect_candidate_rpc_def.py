import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- DEFINITION OF finance_order_candidates_for_period_v3 ---")
print(run_sql("SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'finance_order_candidates_for_period_v3' LIMIT 1;"))

