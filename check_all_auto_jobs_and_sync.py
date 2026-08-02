import subprocess
import json

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- 1. PG_CRON JOBS ---")
cron_jobs = run_sql("""
SELECT jobid, schedule, command, active 
FROM cron.job;
""")
print(cron_jobs if cron_jobs else "No cron jobs found")

print("\n--- 2. PG_CRON RECENT RUN DETAILS ---")
cron_runs = run_sql("""
SELECT jobid, status, return_message, start_time, end_time 
FROM cron.job_run_details 
ORDER BY start_time DESC LIMIT 15;
""")
print(cron_runs if cron_runs else "No recent cron run details found")

print("\n--- 3. MARKETPLACE ACCOUNTS & STATUS ---")
accounts = run_sql("""
SELECT marketplace_account_id, tenant_id, marketplace, shop_name, status, is_deleted, updated_at
FROM marketplace_accounts
WHERE is_deleted = false
ORDER BY marketplace, updated_at DESC;
""")
print(accounts if accounts else "No accounts found")

print("\n--- 4. MARKETPLACE AUTO RUNNER LOGS (LAST 15) ---")
runner_logs = run_sql("""
SELECT id, runner_type, marketplace, status, message, started_at, finished_at
FROM marketplace_auto_runner_logs
ORDER BY id DESC LIMIT 15;
""")
print(runner_logs if runner_logs else "No runner logs found")

print("\n--- 5. RECENT TIKTOK ORDERS IN MARKETPLACE_ORDERS ---")
tt_orders = run_sql("""
SELECT order_id, order_sn, marketplace, order_status, order_created_at, created_at
FROM marketplace_orders
WHERE lower(marketplace) LIKE '%tiktok%'
ORDER BY order_created_at DESC LIMIT 10;
""")
print(tt_orders if tt_orders else "No tiktok orders found")

print("\n--- 6. RECENT TIKTOK FINANCE REPORTS & ITEMS ---")
tt_finance_reports = run_sql("""
SELECT count(*), max(created_at), max(period_end)
FROM marketplace_finance_reports
WHERE lower(marketplace) LIKE '%tiktok%';
""")
print("Reports:", tt_finance_reports)

tt_finance_items = run_sql("""
SELECT count(*), max(created_at), max(period_end)
FROM marketplace_finance_items
WHERE lower(marketplace) LIKE '%tiktok%';
""")
print("Items:", tt_finance_items)

