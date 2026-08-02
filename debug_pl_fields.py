import subprocess
import json

sql = """
select * from public.finance_profit_loss_by_marketplace_v2(
    '2026-06-01'::date,
    '2026-07-20'::date,
    'all',
    NULL
) limit 1;
"""

cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -c "{sql}"']
res = subprocess.run(cmd, text=True, capture_output=True)
print("STDOUT:", res.stdout)
