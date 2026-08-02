import subprocess
import json

sql = """
CREATE INDEX IF NOT EXISTS idx_marketplace_finance_reports_order_lookup
ON public.marketplace_finance_reports (tenant_id, marketplace_account_id, marketplace_order_id);

CREATE INDEX IF NOT EXISTS idx_marketplace_finance_reports_order_id
ON public.marketplace_finance_reports (tenant_id, marketplace_account_id, order_id);
"""

cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -c "{sql}"']
res = subprocess.run(cmd, text=True, capture_output=True)
print("STDOUT:", res.stdout)
print("STDERR:", res.stderr)
