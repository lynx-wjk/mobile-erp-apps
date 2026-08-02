import subprocess
import json
import time

def run_vps(cmd_str):
    cmd = ['ssh', 'inventory-vps', cmd_str]
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("VPS Error:", res.stderr)
        return ""
    return res.stdout.strip()

cron_secret = "4bb7142023541dee631ded0e18e7fddd7c45789cc6e89751154bc73cad21ffdd"
key = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UiLCJpYXQiOjE3ODEzNjU5OTAsImV4cCI6NDEwMjQ0NDgwMH0.TaqlY7FVaZ4a9XdNiWZXZLJxpakzQzMd6ET1xmghwfo"
acc_id = "6a6a6d63-fffb-431a-8812-191b9d87a84d"

print("=== 1. FETCH ALL TIKTOK SHOP ORDERS WITHOUT PAYOUT IN MARKETPLACE_FINANCE_REPORTS ===")
sql_candidates = """
SELECT DISTINCT coalesce(nullif(o.order_id, ''), nullif(o.external_order_id, ''), nullif(o.order_sn, '')) as order_key
FROM marketplace_orders o
WHERE o.marketplace_account_id = '6a6a6d63-fffb-431a-8812-191b9d87a84d'
  AND o.order_status IN ('COMPLETED', 'DELIVERED', 'IN_TRANSIT', 'AWAITING_COLLECTION', 'SHIPPED')
  AND NOT EXISTS (
    SELECT 1 FROM marketplace_finance_reports fr
    WHERE fr.marketplace_account_id = o.marketplace_account_id
      AND (fr.order_id = o.order_id OR fr.order_id = o.external_order_id OR fr.order_id = o.order_sn)
      AND coalesce(fr.net_settlement, fr.payout_amount, 0) > 0
  )
ORDER BY order_key DESC;
"""

ids_str = run_vps(f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql_candidates}"')
order_ids = [line.strip() for line in ids_str.split('\n') if line.strip()]
print(f"Total TikTok candidate orders without positive payout in DB: {len(order_ids)}")

success_count = 0
zero_payout_count = 0
error_count = 0

for i, order_id in enumerate(order_ids):
    if i % 10 == 0:
        print(f"Progress: {i}/{len(order_ids)} orders processed (success={success_count}, zero_payout={zero_payout_count}, error={error_count})...")
    
    payload = json.dumps({
        "action": "pull_finance_by_order",
        "params": {
            "account_id": acc_id,
            "order_id": order_id
        }
    }).replace('"', '\\"')

    curl_cmd = f"""curl -s -X POST "http://localhost:8050/functions/v1/marketplace-tiktok-service" -H "Content-Type: application/json" -H "Authorization: Bearer {key}" -H "apikey: {key}" -H "x-marketplace-cron-secret: {cron_secret}" -d "{payload}" """
    out = run_vps(curl_cmd)
    
    try:
        data = json.loads(out)
        if data.get("ok"):
            net = data.get("finance_report", {}).get("net_settlement", 0)
            if net > 0:
                success_count += 1
            else:
                zero_payout_count += 1
        else:
            error_count += 1
    except Exception as e:
        error_count += 1
    
    time.sleep(0.1)

print(f"\n=== BATCH PAYOUT PULL COMPLETE ===")
print(f"Total Orders Processed: {len(order_ids)}")
print(f"Positive Payouts Saved: {success_count}")
print(f"Zero Payout (Pending Settlement): {zero_payout_count}")
print(f"Errors: {error_count}")

