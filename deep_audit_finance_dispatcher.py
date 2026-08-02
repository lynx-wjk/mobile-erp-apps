import subprocess
import json

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("=== 1. COUNT OF COMPLETED/DELIVERED ORDERS FROM JULY 1 WITHOUT PAYOUT ===")
sql_no_payout = """
SELECT o.marketplace, upper(o.order_status) as status, count(*)
FROM marketplace_orders o
WHERE (coalesce(o.paid_at, o.order_created_at, o.created_time, o.created_at) at time zone 'Asia/Jakarta')::date >= '2026-07-01'
  AND upper(o.order_status) IN ('COMPLETED', 'DELIVERED')
  AND NOT EXISTS (
    SELECT 1 FROM marketplace_finance_reports fr
    WHERE fr.marketplace_account_id = o.marketplace_account_id
      AND (fr.order_id = o.order_id OR fr.order_id = o.external_order_id OR fr.order_id = o.order_sn)
      AND coalesce(fr.net_settlement, fr.payout_amount, 0) > 0
  )
GROUP BY o.marketplace, upper(o.order_status);
"""
print(run_sql(sql_no_payout))

print("\n=== 2. CHECK RECENT CRON RUN LOGS FOR JOB 44 (marketplace-finance-dispatcher) ===")
sql_cron = """
SELECT jobid, runid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = 44
ORDER BY start_time DESC
LIMIT 10;
"""
print(run_sql(sql_cron))

print("\n=== 3. CHECK MARKETPLACE_FINANCE_SYNC_STATE TABLE ===")
sql_state = """
SELECT marketplace_account_id, marketplace, finance_status, last_mode, last_success_at, next_run_at, synced_total, last_error
FROM marketplace_finance_sync_state;
"""
print(run_sql(sql_state))

