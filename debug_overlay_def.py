import subprocess

sql = """
SELECT pg_get_functiondef('public.finance_snapshot_order_omzet_settlement_overlay_20260623'::regproc);
"""

cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -c "{sql}"']
res = subprocess.run(cmd, text=True, capture_output=True)

with open('debug_overlay_def.txt', 'w', encoding='utf-8') as f:
    f.write(res.stdout)
