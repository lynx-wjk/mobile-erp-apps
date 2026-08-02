import subprocess
import json

def run_vps(cmd_str):
    cmd = ['ssh', 'inventory-vps', cmd_str]
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("VPS Error:", res.stderr)
        return ""
    return res.stdout.strip()

cron_secret = "4bb7142023541dee631ded0e18e7fddd7c45789cc6e89751154bc73cad21ffdd"
tenant_id = "ae730499-550b-4907-bb18-bbc2629c64f4"
acc_id = "6a6a6d63-fffb-431a-8812-191b9d87a84d"

print("--- 1. TEST REFRESH_EXISTING_STATUS FOR TIKTOK SHOP VIA MARKETPLACE-ORDER-PULL ---")
payload1 = json.dumps({
    "tenant_id": tenant_id,
    "marketplace_account_id": acc_id,
    "action": "refresh_existing_status",
    "status_range_days": 60,
    "max_existing_orders": 200,
    "skip_completed_status_refresh": True
}).replace('"', '\\"')

curl_cmd1 = f"""curl -s -X POST "http://localhost:8050/functions/v1/marketplace-order-pull" -H "Content-Type: application/json" -H "x-marketplace-cron-secret: {cron_secret}" -d "{payload1}" """
out1 = run_vps(curl_cmd1)
print("Response:", out1[:1000])

