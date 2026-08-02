import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

sql_net = """
SELECT id, status_code, content
FROM net._http_response
WHERE id >= 2920
ORDER BY id DESC;
"""
print(run_sql(sql_net))
