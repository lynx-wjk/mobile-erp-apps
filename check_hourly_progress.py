import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("=== HOURLY FINANCE BACKFILL PROGRESS REPORT (ITERATION 1) ===")

print("\n--- 1. TOTAL FINANCE REPORTS COUNT ---")
sql_total = """
SELECT marketplace, count(*) as total_reports, count(nullif(received_amount, 0)) as settled_reports, count(case when received_amount = 0 then 1 end) as zero_payout_reports
FROM marketplace_finance_reports
GROUP BY marketplace;
"""
print(run_sql(sql_total))

print("\n--- 2. TIKTOK ORDERS STILL MISSING FINANCE REPORTS ---")
sql_missing_tt = """
SELECT count(o.marketplace_order_id)
FROM marketplace_orders o
WHERE lower(o.marketplace) LIKE '%tiktok%'
  AND NOT EXISTS (
    SELECT 1 FROM marketplace_finance_reports f
    WHERE f.marketplace_order_id = o.marketplace_order_id OR f.order_id = o.external_order_id OR f.order_id = o.order_sn
  );
"""
missing_tt = run_sql(sql_missing_tt)
print("Remaining TikTok Orders Without Finance Report:", missing_tt)

print("\n--- 3. SHOPEE ORDERS STILL MISSING FINANCE REPORTS ---")
sql_missing_sp = """
SELECT count(o.marketplace_order_id)
FROM marketplace_orders o
WHERE lower(o.marketplace) LIKE '%shopee%'
  AND NOT EXISTS (
    SELECT 1 FROM marketplace_finance_reports f
    WHERE f.marketplace_order_id = o.marketplace_order_id OR f.order_id = o.external_order_id OR f.order_id = o.order_sn
  );
"""
missing_sp = run_sql(sql_missing_sp)
print("Remaining Shopee Orders Without Finance Report:", missing_sp)

print("\n--- 4. RECENT CRON RUNS (JOB 44) ---")
sql_cron = """
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = 44
ORDER BY start_time DESC LIMIT 6;
"""
print(run_sql(sql_cron))

