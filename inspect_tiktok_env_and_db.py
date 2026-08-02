import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- MARKETPLACE ACCOUNTS COLUMNS ---")
sql_cols = """
SELECT column_name
FROM information_schema.columns
WHERE table_name = 'marketplace_accounts';
"""
print(run_sql(sql_cols))

print("\n--- ACCOUNT ROW SAMPLE ---")
sql_acc = """
SELECT marketplace_account_id, marketplace, is_active, shop_id, auth_data
FROM marketplace_accounts
WHERE lower(marketplace) LIKE '%tiktok%' LIMIT 1;
"""
print(run_sql(sql_acc))

