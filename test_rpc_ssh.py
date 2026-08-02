import subprocess
import json

sql = """
SELECT * FROM public.finance_order_candidates_for_period_v3(
    '2026-07-14'::date,
    '2026-07-15'::date,
    'tiktok_shop',
    NULL,
    2000,
    true,
    NULL
) where order_id = '585027028427834403';
"""

cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -c "{sql}"']
res = subprocess.run(cmd, text=True, capture_output=True)
print("STDOUT:", res.stdout)
