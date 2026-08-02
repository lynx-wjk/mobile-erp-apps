import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- SEARCH FUNCTIONS RELATED TO FINANCE OR DASHBOARD ---")
sql = """
SELECT proname, pg_get_function_arguments(oid)
FROM pg_proc
WHERE proname LIKE '%finance%' OR proname LIKE '%dashboard%' OR proname LIKE '%sku%'
ORDER BY proname;
"""
print(run_sql(sql))

