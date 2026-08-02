import subprocess
import json

order_id = '584872438198666664'

def run_edge_function(function_name, payload):
    payload_str = json.dumps(payload).replace('"', '\\"')
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-edge-functions curl -s -X POST "http://localhost:9000/functions/v1/{function_name}" -H "Content-Type: application/json" -d "{payload_str}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("Cmd Error:", res.stderr)
        return ""
    return res.stdout.strip()

print(f"--- 1. CALLING MARKETPLACE-ORDER-PULL FOR ORDER {order_id} ---")
payload1 = {
    "action": "pull_single_order",
    "params": {
        "order_id": order_id,
        "marketplace": "tiktok_shop"
    }
}
print(run_edge_function("marketplace-order-pull", payload1))

print(f"\n--- 2. CALLING MARKETPLACE-TIKTOK-SERVICE FOR ORDER {order_id} ---")
payload2 = {
    "action": "get_order_detail",
    "params": {
        "order_id": order_id
    }
}
print(run_edge_function("marketplace-tiktok-service", payload2))

