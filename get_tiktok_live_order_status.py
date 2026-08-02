import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

order_id = '584872438198666664'

print(f"=== CHECK ORDER {order_id} IN DATABASE ===")
sql_order = f"SELECT marketplace_order_id, external_order_id, marketplace, order_status, paid_at, order_created_at, updated_at FROM marketplace_orders WHERE external_order_id = '{order_id}';"
print(run_sql(sql_order))

print(f"\n=== PULL LIVE STATUS FOR ORDER {order_id} FROM TIKTOK SHOP API ===")
cmd_api = f"""ssh inventory-vps 'docker exec -i supabase-edge-functions curl -s -X POST "http://localhost:9000/functions/v1/marketplace-tiktok-service" -H "Content-Type: application/json" -d "{{\\"action\\": \\"get_order_details\\", \\"params\\": {{\\"order_id\\": \\"{order_id}\\"}}}}"'"""
res_api = subprocess.run(cmd_api, shell=True, text=True, capture_output=True)
print("TikTok API Response:", res_api.stdout)

