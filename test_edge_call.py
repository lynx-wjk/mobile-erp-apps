import subprocess
import json

def run_vps(cmd_str):
    cmd = ['ssh', 'inventory-vps', cmd_str]
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("VPS Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- 1. TEST TIKTOK SERVICE DIRECT CALL ---")
payload1 = json.dumps({
    "action": "get_order_details",
    "params": {
        "order_id": "584872438198666664"
    }
}).replace('"', '\\"')

curl_cmd1 = f"""curl -s -X POST "http://localhost:8050/functions/v1/marketplace-tiktok-service" -H "Content-Type: application/json" -d "{payload1}" """
print(run_vps(curl_cmd1))

print("\n--- 2. TEST TIKTOK SERVICE ACTIONS ---")
payload2 = json.dumps({
    "action": "get_order_detail",
    "params": {
        "order_id": "584872438198666664"
    }
}).replace('"', '\\"')
curl_cmd2 = f"""curl -s -X POST "http://localhost:8050/functions/v1/marketplace-tiktok-service" -H "Content-Type: application/json" -d "{payload2}" """
print(run_vps(curl_cmd2))

