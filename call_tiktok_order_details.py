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
order_id = "584872438198666664"

print(f"=== CALL TIKTOK SERVICE FOR ORDER {order_id} WITH CRON SECRET ===")

payload = json.dumps({
    "action": "get_order_detail",
    "params": {
        "order_id": order_id
    }
}).replace('"', '\\"')

curl_cmd = f"""curl -s -X POST "http://localhost:8050/functions/v1/marketplace-tiktok-service" -H "Content-Type: application/json" -H "x-marketplace-cron-secret: {cron_secret}" -d "{payload}" """
out = run_vps(curl_cmd)
print("Response:", out)

