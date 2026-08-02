import subprocess
import time

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

order_id = '584871522068366376'
account_id = '6a6a6d63-fffb-431a-8812-191b9d87a84d'

print(f"--- TRIGGER PULL_FINANCE_BY_ORDER FOR {order_id} VIA PG_NET ---")
sql_http = f"""
select net.http_post(
    url := 'http://kong:8000/functions/v1/marketplace-tiktok-service',
    body := jsonb_build_object(
      'action', 'pull_finance_by_order',
      'params', jsonb_build_object(
        'order_id', '{order_id}',
        'account_id', '{account_id}',
        'marketplace_account_id', '{account_id}',
        'tenant_id', 'ae730499-550b-4907-bb18-bbc2629c64f4'
      )
    ),
    params := '{{}}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-marketplace-cron-secret', app_private.get_runtime_secret('marketplace_cron_secret')
    ),
    timeout_milliseconds := 120000
);
"""
req_id = run_sql(sql_http)
print("Request ID:", req_id)

time.sleep(5)

sql_resp = f"""
SELECT id, status_code, content, error_msg
FROM net._http_response
WHERE id = {req_id};
"""
print("Response:", run_sql(sql_resp))

