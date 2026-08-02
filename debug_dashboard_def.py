import subprocess

sql = """
SELECT pg_get_functiondef('public.finance_customer_dashboard_snapshot_v24_6_82o'::regproc);
"""

cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -c "{sql}"']
res = subprocess.run(cmd, text=True, capture_output=True)

with open('debug_dashboard_def.txt', 'w', encoding='utf-8') as f:
    f.write(res.stdout)
