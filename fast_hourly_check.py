import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- 1. CURRENT FINANCE REPORTS COUNT ---")
print(run_sql("SELECT marketplace, count(*), count(nullif(received_amount, 0)) as positive_payout_count FROM marketplace_finance_reports GROUP BY marketplace;"))

print("\n--- 2. RECENT JOB 44 CRON RUNS ---")
sql_cron = """
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = 44
ORDER BY start_time DESC LIMIT 5;
"""
print(run_sql(sql_cron))

