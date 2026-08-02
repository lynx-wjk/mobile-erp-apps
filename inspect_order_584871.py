import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

order_id = '584871522068366376'

print(f"--- 1. CHECK MARKETPLACE_ORDERS FOR {order_id} ---")
sql_order = f"""
SELECT marketplace_order_id, order_id, order_sn, external_order_id, marketplace, order_status, status, order_created_at, created_at
FROM marketplace_orders
WHERE order_id = '{order_id}' OR order_sn = '{order_id}' OR external_order_id = '{order_id}';
"""
print(run_sql(sql_order))

print(f"\n--- 2. CHECK MARKETPLACE_ORDER_ITEMS FOR {order_id} ---")
sql_items = f"""
SELECT marketplace_order_item_id, marketplace_sku, local_sku, product_name, variant_name, qty, gross_amount, paid_amount
FROM marketplace_order_items
WHERE order_sn = '{order_id}' OR external_order_id = '{order_id}';
"""
print(run_sql(sql_items))

print(f"\n--- 3. CHECK MARKETPLACE_FINANCE_REPORTS FOR {order_id} ---")
sql_reports = f"""
SELECT marketplace_finance_report_id, statement_id, order_id, marketplace_order_id, gross_amount, payout_amount, net_settlement, settlement_status, settlement_date, created_at, raw_finance
FROM marketplace_finance_reports
WHERE order_id = '{order_id}' OR statement_id = '{order_id}' OR order_id LIKE '%{order_id}%';
"""
print(run_sql(sql_reports))

print(f"\n--- 4. CHECK MARKETPLACE_FINANCE_ITEMS FOR {order_id} ---")
sql_fin_items = f"""
SELECT id, order_id, order_sn, external_order_id, statement_id, gross_amount, received_amount, net_settlement, settlement_status, settlement_date, created_at
FROM marketplace_finance_items
WHERE order_id = '{order_id}' OR order_sn = '{order_id}' OR external_order_id = '{order_id}' OR statement_id = '{order_id}';
"""
print(run_sql(sql_fin_items))

print(f"\n--- 5. CHECK LATEST TIKTOK FINANCE STATEMENTS / REPORTS ---")
sql_latest_fin = """
SELECT statement_id, order_id, gross_amount, payout_amount, settlement_date, created_at
FROM marketplace_finance_reports
WHERE lower(marketplace) LIKE '%tiktok%'
ORDER BY created_at DESC LIMIT 10;
"""
print(run_sql(sql_latest_fin))

