import subprocess
import time

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

secret = run_sql("SELECT app_private.get_runtime_secret('marketplace_cron_secret');")
account_id = '6a6a6d63-fffb-431a-8812-191b9d87a84d'

print("--- STARTING TIKTOK FINANCE BATCH PULL ---")

for i in range(10):
    sql_http = f"""
    select net.http_post(
        url := 'http://kong:8000/functions/v1/marketplace-tiktok-service',
        body := jsonb_build_object(
          'action', 'pull_finance_period',
          'params', jsonb_build_object(
            'start_date', '2026-06-01',
            'end_date', '2026-07-22',
            'marketplace', 'tiktok_shop',
            'account_id', '{account_id}',
            'marketplace_account_id', '{account_id}',
            'tenant_id', 'ae730499-550b-4907-bb18-bbc2629c64f4',
            'max_orders', 150,
            'missing_only', true
          )
        ),
        params := '{{}}'::jsonb,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-marketplace-cron-secret', '{secret}'
        ),
        timeout_milliseconds := 120000
    );
    """
    req_id = run_sql(sql_http)
    print(f"Batch {i+1} Request ID: {req_id}")
    if not req_id.isdigit():
        print("Error getting req_id, stopping.")
        break
    time.sleep(8)

    sql_resp = f"""
    SELECT status_code, content
    FROM net._http_response
    WHERE id = {req_id};
    """
    resp = run_sql(sql_resp)
    print(f"Batch {i+1} Result: {resp[:350]}")
    if '"checked":0' in resp or '"success":0' in resp:
        print("No more candidates!")
        break

print("\n--- BATCH PULL COMPLETE ---")
