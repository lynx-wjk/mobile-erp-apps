import subprocess
import json

def run_vps(cmd_str):
    cmd = ['ssh', 'inventory-vps', cmd_str]
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("VPS Error:", res.stderr)
        return ""
    return res.stdout.strip()

key = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UiLCJpYXQiOjE3ODEzNjU5OTAsImV4cCI6NDEwMjQ0NDgwMH0.TaqlY7FVaZ4a9XdNiWZXZLJxpakzQzMd6ET1xmghwfo"
order_id = "584872438198666664"

print(f"=== 1. PULL ORDER DETAILS FOR {order_id} FROM TIKTOK API VIA MARKETPLACE-ORDER-PULL ===")
payload1 = json.dumps({
    "action": "pull_single_order",
    "params": {
        "order_id": order_id,
        "marketplace": "tiktok_shop"
    }
}).replace('"', '\\"')

curl_cmd1 = f"""curl -s -X POST "http://localhost:8050/functions/v1/marketplace-order-pull" -H "Content-Type: application/json" -H "Authorization: Bearer {key}" -d "{payload1}" """
print(run_vps(curl_cmd1))

print(f"\n=== 2. CALL TIKTOK SERVICE DIRECT GET_ORDER_DETAIL FOR {order_id} ===")
payload2 = json.dumps({
    "action": "get_order_detail",
    "params": {
        "order_id": order_id
    }
}).replace('"', '\\"')

curl_cmd2 = f"""curl -s -X POST "http://localhost:8050/functions/v1/marketplace-tiktok-service" -H "Content-Type: application/json" -H "Authorization: Bearer {key}" -d "{payload2}" """
print(run_vps(curl_cmd2))

