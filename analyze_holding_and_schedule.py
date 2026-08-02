import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- 1. TOTAL ORDERS BY MARKETPLACE AND STATUS ---")
sql1 = """
SELECT marketplace, order_status, count(*)
FROM marketplace_orders
GROUP BY marketplace, order_status
ORDER BY marketplace, order_status;
"""
print(run_sql(sql1))

print("\n--- 2. ORDERS MISSING FINANCE REPORTS (NO PAYOUT YET) BY MARKETPLACE AND STATUS ---")
sql2 = """
SELECT o.marketplace, o.order_status, count(o.marketplace_order_id)
FROM marketplace_orders o
LEFT JOIN marketplace_finance_reports f ON (
    f.marketplace_order_id = o.marketplace_order_id OR f.order_id = o.external_order_id OR f.order_id = o.order_sn
)
WHERE f.finance_report_id IS NULL
GROUP BY o.marketplace, o.order_status
ORDER BY o.marketplace, o.order_status;
"""
print(run_sql(sql2))

print("\n--- 3. ORDERS WITH FINANCE REPORTS BUT 0 PAYOUT / ZERO NET SETTLEMENT ---")
sql3 = """
SELECT o.marketplace, o.order_status, count(o.marketplace_order_id)
FROM marketplace_orders o
JOIN marketplace_finance_reports f ON (
    f.marketplace_order_id = o.marketplace_order_id OR f.order_id = o.external_order_id OR f.order_id = o.order_sn
)
WHERE COALESCE(f.received_amount, f.net_settlement, f.payout_amount, 0) = 0
GROUP BY o.marketplace, o.order_status
ORDER BY o.marketplace, o.order_status;
"""
print(run_sql(sql3))

print("\n--- 4. MARKETPLACE_FINANCE_SYNC_STATE RECENT RUN STATUS ---")
sql4 = """
SELECT marketplace_account_id, marketplace, finance_status, period_start, period_end, next_run_at, updated_at
FROM marketplace_finance_sync_state;
"""
print(run_sql(sql4))

print("\n--- 5. CHECK PG_CRON SCHEDULE FOR JOB 44 ---")
sql5 = """
SELECT jobid, schedule, command, nodename, active
FROM cron.job
WHERE jobid = 44 OR command LIKE '%finance%';
"""
print(run_sql(sql5))

