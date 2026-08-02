import subprocess

order_id = '584872438198666664'

print(f"--- CALLING MARKETPLACE-ORDER-PULL FOR ORDER {order_id} ---")
cmd = f"""ssh inventory-vps 'docker exec -i supabase-edge-functions curl -s -X POST "http://localhost:9000/functions/v1/marketplace-order-pull" -H "Content-Type: application/json" -d "{{\\"action\\": \\"pull_single_order\\", \\"params\\": {{\\"order_id\\": \\"{order_id}\\", \\"marketplace\\": \\"tiktok_shop\\"}}}}"'''"""
res = subprocess.run(cmd, shell=True, text=True, capture_output=True)
print("Response:", res.stdout)
if res.stderr:
    print("Stderr:", res.stderr)

