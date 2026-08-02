import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- RELEASING LOCKS ---")
sql_release = """
UPDATE marketplace_order_sync_state
SET sync_status = 'idle', lock_token = null, lock_until = now() - interval '1 second';

UPDATE marketplace_finance_sync_state
SET finance_status = 'idle', last_error = null, next_run_at = now() - interval '1 second';
"""
print(run_sql(sql_release))

print("\n--- TRIGGER DISPATCHER ---")
sql_trigger = """
select net.http_post(
    url := 'http://kong:8000/functions/v1/marketplace-order-dispatcher',
    body := jsonb_build_object(
      'max_accounts', 5,
      'lock_seconds', 60,
      'source', 'manual_trigger_fresh'
    ),
    params := '{}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-marketplace-cron-secret', app_private.get_runtime_secret('marketplace_cron_secret')
    ),
    timeout_milliseconds := 120000
);
"""
res_id = run_sql(sql_trigger)
print("Trigger result id:", res_id)

