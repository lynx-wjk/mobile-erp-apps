import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("=== CHECK MARKETPLACE_FINANCE_REPORTS FOR 584837246890771957 ===")
sql = """
SELECT finance_report_id, order_id, gross_amount, net_settlement, received_amount, platform_fee, commission_fee, affiliate_fee, shipping_fee
FROM marketplace_finance_reports
WHERE marketplace_account_id = '6a6a6d63-fffb-431a-8812-191b9d87a84d'
  AND order_id = '584837246890771957';
"""
print(run_sql(sql))

