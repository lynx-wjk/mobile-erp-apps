import subprocess
import json

def run_vps(cmd_str):
    cmd = ['ssh', 'inventory-vps', cmd_str]
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("VPS Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- GET SERVICE ROLE KEY FROM SUPABASE-REST CONTAINER ---")
key = run_vps("docker exec -i supabase-rest env | grep SUPABASE_SERVICE_KEY | cut -d= -f2")
if not key:
    key = run_vps("docker exec -i supabase-rest env | grep PGRST_JWT_SECRET | cut -d= -f2")
print("Key length:", len(key))

order_id = '584872438198666664'

print(f"\n--- TEST TIKTOK SERVICE GET ORDER DETAILS FOR {order_id} ---")
payload = json.dumps({
    "action": "get_order_detail",
    "params": {
        "order_id": order_id
    }
}).replace('"', '\\"')

curl_cmd = f"""curl -s -X POST "http://localhost:8050/functions/v1/marketplace-tiktok-service" -H "Content-Type: application/json" -H "Authorization: Bearer {key}" -d "{payload}" """
out = run_vps(curl_cmd)
print("Response:", out[:1000])

