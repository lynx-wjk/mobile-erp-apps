import subprocess

sql = """
select
  order_id, external_order_id, order_sn, marketplace_order_id,
  order_status, status, payment_status, total_amount, gross_amount, paid_amount,
  paid_at, order_created_at, created_time, created_at, marketplace
from public.marketplace_orders
where order_id = '585027028427834403'
   or marketplace_order_id = '585027028427834403'
   or external_order_id = '585027028427834403';
"""

cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -c "{sql}"']
res = subprocess.run(cmd, text=True, capture_output=True)
print("STDOUT:", res.stdout)
