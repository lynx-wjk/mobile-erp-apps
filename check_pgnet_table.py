import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- LATEST PG_NET RESPONSES ---")
sql_resp = """
SELECT id, status_code, content, error_msg
FROM net._http_response
ORDER BY id DESC LIMIT 10;
"""
print(run_sql(sql_resp))
