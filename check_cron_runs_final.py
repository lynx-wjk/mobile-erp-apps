import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- RECENT PG_NET RESPONSES (LAST 5) ---")
sql_net = """
SELECT id, status_code, content, created
FROM net._http_response
ORDER BY id DESC LIMIT 5;
"""
print(run_sql(sql_net))
