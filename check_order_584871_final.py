import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

order_id = '584871522068366376'

print("--- 1. MARKETPLACE_ORDERS ---")
sql1 = f"SELECT marketplace_order_id, external_order_id, marketplace, order_status, paid_at FROM marketplace_orders WHERE external_order_id = '{order_id}';"
print(run_sql(sql1))

print("\n--- 2. MARKETPLACE_ORDER_ITEMS ---")
sql2 = f"SELECT marketplace_sku, local_sku, product_name, variant_name, qty, gross_amount, paid_amount FROM marketplace_order_items WHERE external_order_id = '{order_id}';"
print(run_sql(sql2))

print("\n--- 3. MARKETPLACE_FINANCE_REPORTS ---")
sql3 = f"SELECT finance_report_id, order_id, statement_id, gross_amount, received_amount, net_settlement, total_fees, status, pulled_at FROM marketplace_finance_reports WHERE order_id = '{order_id}';"
print(run_sql(sql3))

