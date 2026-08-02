import subprocess
import json

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

order_id = '584872438198666664'

print(f"=== 1. MARKETPLACE_ORDERS FOR {order_id} ===")
sql1 = f"SELECT marketplace_order_id, external_order_id, marketplace, order_status, shipping_status, paid_at, order_created_at, updated_at FROM marketplace_orders WHERE external_order_id = '{order_id}' OR order_sn = '{order_id}';"
print(run_sql(sql1))

print(f"\n=== 2. MARKETPLACE_ORDER_ITEMS FOR {order_id} ===")
sql2 = f"SELECT marketplace_sku, local_sku, product_name, variant_name, qty, gross_amount, paid_amount FROM marketplace_order_items WHERE external_order_id = '{order_id}' OR order_sn = '{order_id}';"
print(run_sql(sql2))

print(f"\n=== 3. MARKETPLACE_FINANCE_REPORTS FOR {order_id} ===")
sql3 = f"SELECT finance_report_id, order_id, statement_id, gross_amount, net_settlement, received_amount, status, pulled_at FROM marketplace_finance_reports WHERE order_id = '{order_id}';"
print(run_sql(sql3))

print("\n=== 4. HOW MANY ORDERS IN MARKETPLACE_ORDERS ARE STILL 'IN_TRANSIT' or 'SHIPPED' or 'AWAITING_COLLECTION' FROM BEFORE JULY 15? ===")
sql4 = """
SELECT marketplace, order_status, count(*)
FROM marketplace_orders
WHERE order_created_at < '2026-07-15'
  AND order_status IN ('IN_TRANSIT', 'SHIPPED', 'AWAITING_COLLECTION', 'AWAITING_SHIPMENT', 'UNPAID', 'PROCESSING', 'ON_HOLD')
GROUP BY marketplace, order_status;
"""
print(run_sql(sql4))

