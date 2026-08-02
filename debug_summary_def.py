import subprocess

sql = """
SELECT proname, pg_get_functiondef(oid) FROM pg_proc WHERE proname LIKE '%finance_report_summary%';
"""

cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -c "{sql}"']
res = subprocess.run(cmd, text=True, capture_output=True)

with open('debug_summary_def.txt', 'w', encoding='utf-8') as f:
    f.write(res.stdout)
