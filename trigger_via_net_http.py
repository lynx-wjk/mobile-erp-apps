import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- TRIGGER MARKETPLACE-ORDER-DISPATCHER VIA NET.HTTP_POST ---")
sql_http = """
select net.http_post(
    url := 'http://kong:8000/functions/v1/marketplace-order-dispatcher',
    body := jsonb_build_object(
      'max_accounts', 5,
      'lock_seconds', 60,
      'source', 'manual_trigger'
    ),
    params := '{}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-marketplace-cron-secret', app_private.get_runtime_secret('marketplace_cron_secret')
    ),
    timeout_milliseconds := 120000
);
"""
print("http_post result:", run_sql(sql_http))

print("\n--- TRIGGER MARKETPLACE-FINANCE-DISPATCHER VIA NET.HTTP_POST ---")
sql_http_fin = """
select net.http_post(
    url := 'http://kong:8000/functions/v1/marketplace-finance-dispatcher',
    body := jsonb_build_object(
      'force', true,
      'max_accounts', 5,
      'window_days', 30,
      'source', 'manual_trigger'
    ),
    params := '{}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-marketplace-cron-secret', app_private.get_runtime_secret('marketplace_cron_secret')
    ),
    timeout_milliseconds := 120000
);
"""
print("http_post finance result:", run_sql(sql_http_fin))

