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

payload = json.dumps({
    "p_start": "2026-07-01",
    "p_end": "2026-07-22",
    "p_marketplace": "tiktok_shop",
    "p_account_id": "6a6a6d63-fffb-431a-8812-191b9d87a84d",
    "p_marketplace_sku": "1730633792562104235",
    "p_local_sku": "unmapped",
    "p_search": None,
    "p_payout_filter": "paid",
    "p_page": 1,
    "p_page_size": 10
}).replace('"', '\\"')

curl_cmd = f"""curl -s -X POST "http://localhost:8050/rest/v1/rpc/finance_sku_order_line_details" -H "Content-Type: application/json" -H "Authorization: Bearer {key}" -H "apikey: {key}" -d "{payload}" """
out = run_vps(curl_cmd)

print("=== RPC FINANCE_SKU_ORDER_LINE_DETAILS RESPONSE FOR PAID FILTER ===")
print(out[:1000])

