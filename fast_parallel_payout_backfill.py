import subprocess
import json
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

def run_vps(cmd_str):
    cmd = ['ssh', 'inventory-vps', cmd_str]
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        return ""
    return res.stdout.strip()

cron_secret = "4bb7142023541dee631ded0e18e7fddd7c45789cc6e89751154bc73cad21ffdd"
key = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoic3VwYWJhc2UiLCJpYXQiOjE3ODEzNjU5OTAsImV4cCI6NDEwMjQ0NDgwMH0.TaqlY7FVaZ4a9XdNiWZXZLJxpakzQzMd6ET1xmghwfo"
acc_id = "6a6a6d63-fffb-431a-8812-191b9d87a84d"

print("=== 1. FETCH ALL COMPLETED/DELIVERED TIKTOK ORDERS WITHOUT PAYOUT SINCE JULY 1 ===")
sql_candidates = """
SELECT DISTINCT coalesce(nullif(o.order_id, ''), nullif(o.external_order_id, ''), nullif(o.order_sn, '')) as order_key
FROM marketplace_orders o
WHERE o.marketplace_account_id = '6a6a6d63-fffb-431a-8812-191b9d87a84d'
  AND (coalesce(o.paid_at, o.order_created_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date >= '2026-07-01'
  AND upper(o.order_status) IN ('COMPLETED', 'DELIVERED')
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
print(f"Total TikTok completed/delivered orders without payout: {len(order_ids)}")

def process_order(order_id):
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
            return ("success", net > 0)
        return ("fail", False)
    except Exception:
        return ("error", False)

start_time = time.time()
success_pos = 0
success_zero = 0
failed_cnt = 0

print("\n=== STARTING MULTI-THREADED PAYOUT BACKFILL (8 WORKERS) ===")
with ThreadPoolExecutor(max_workers=8) as executor:
    futures = {executor.submit(process_order, oid): oid for oid in order_ids}
    completed_count = 0
    for future in as_completed(futures):
        completed_count += 1
        status, is_pos = future.result()
        if status == "success":
            if is_pos:
                success_pos += 1
            else:
                success_zero += 1
        else:
            failed_cnt += 1
        
        if completed_count % 50 == 0 or completed_count == len(order_ids):
            elapsed = time.time() - start_time
            rate = completed_count / elapsed if elapsed > 0 else 0
            print(f"Progress: {completed_count}/{len(order_ids)} orders ({completed_count*100/len(order_ids):.1f}%) | Positive Payouts: {success_pos} | Zero/Pending: {success_zero} | Failed: {failed_cnt} | Speed: {rate*60:.1f} orders/min")

print(f"\n=== BACKFILL COMPLETED IN {time.time()-start_time:.1f} SECONDS ===")
print(f"Total Processed: {len(order_ids)}")
print(f"Positive Payouts Saved: {success_pos}")
print(f"Zero Payout/Pending: {success_zero}")
print(f"Failed: {failed_cnt}")

