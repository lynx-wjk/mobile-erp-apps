import subprocess

sql = """
SELECT column_name, data_type 
FROM information_schema.columns 
WHERE table_name = 'marketplace_finance_reports';
"""

cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -c "{sql}"']
res = subprocess.run(cmd, text=True, capture_output=True)

print("STDOUT:")
print(res.stdout)
