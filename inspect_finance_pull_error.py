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

print("=== CALL MARKETPLACE-FINANCE-PULL WITH FULL ERROR DETAILS ===")
payload = json.dumps({
    "tenant_id": tenant_id,
    "account_id": acc_id,
    "marketplace_account_id": acc_id,
    "days_back": 90,
    "mode": "recent_unpaid"
}).replace('"', '\\"')

curl_cmd = f"""curl -s -X POST "http://localhost:8050/functions/v1/marketplace-finance-pull" -H "Content-Type: application/json" -H "x-marketplace-cron-secret: {cron_secret}" -d "{payload}" """
out = run_vps(curl_cmd)
print("Full Response:", out)

