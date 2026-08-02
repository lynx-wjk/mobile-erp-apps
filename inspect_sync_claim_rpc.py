import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- DEFINITION OF marketplace_finance_sync_claim ---")
print(run_sql("SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'marketplace_finance_sync_claim' LIMIT 1;"))

