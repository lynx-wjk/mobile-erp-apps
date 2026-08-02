import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- COLUMNS IN MARKETPLACE_SKU_MAPS ---")
sql_cols = """
SELECT column_name, data_type 
FROM information_schema.columns 
WHERE table_name = 'marketplace_sku_maps'
ORDER BY ordinal_position;
"""
print(run_sql(sql_cols))
