import subprocess
import json

sql = """
select pg_get_functiondef('public.finance_profit_loss_by_marketplace_v2'::regproc);
"""

cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -c "{sql}"']
res = subprocess.run(cmd, text=True, capture_output=True)
print("STDOUT:", res.stdout)
