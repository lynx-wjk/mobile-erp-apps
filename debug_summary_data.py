import subprocess
import json

sql = """
select jsonb_pretty(
  coalesce(
    public.finance_customer_dashboard_snapshot_v24_6_82o(
        '2026-06-01'::date, '2026-07-20'::date, 'all', NULL
    )->'summary'->'marketplaces',
    '[]'::jsonb
  )
);
"""

cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -c "{sql}"']
res = subprocess.run(cmd, text=True, capture_output=True)

with open('debug_summary_data.json', 'w', encoding='utf-8') as f:
    f.write(res.stdout)
