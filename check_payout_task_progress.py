import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("=== CHECK NUMBER OF REPORTS WITH POSITIVE PAYOUT IN DATABASE ===")
sql = """
SELECT count(*)
FROM marketplace_finance_reports
WHERE marketplace_account_id = '6a6a6d63-fffb-431a-8812-191b9d87a84d'
  AND coalesce(net_settlement, payout_amount, 0) > 0;
"""
print("Total positive payout reports:", run_sql(sql))

