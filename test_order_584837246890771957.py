import subprocess
import json

def run_vps(cmd_str):
    cmd = ['ssh', 'inventory-vps', cmd_str]
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        return ""
    return res.stdout.strip()

cron_secret = "4bb7142023541dee631ded0e18e7fddd7c45789cc6e89751154bc73cad21ffdd"
key = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UiLCJpYXQiOjE3ODEzNjU5OTAsImV4cCI6NDEwMjQ0NDgwMH0.TaqlY7FVaZ4a9XdNiWZXZLJxpakzQzMd6ET1xmghwfo"
acc_id = "6a6a6d63-fffb-431a-8812-191b9d87a84d"
order_id = "584837246890771957"

payload = json.dumps({
    "action": "pull_finance_by_order",
    "params": {
        "account_id": acc_id,
        "order_id": order_id
    }
}).replace('"', '\\"')

curl_cmd = f"""curl -s -X POST "http://localhost:8050/functions/v1/marketplace-tiktok-service" -H "Content-Type: application/json" -H "Authorization: Bearer {key}" -H "apikey: {key}" -H "x-marketplace-cron-secret: {cron_secret}" -d "{payload}" """
out = run_vps(curl_cmd)

print("=== PULL FINANCE BY ORDER RESPONSE FOR 584837246890771957 ===")
print(out)

