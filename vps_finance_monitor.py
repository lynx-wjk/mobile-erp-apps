import subprocess
import json

def get_vps_resources():
    cmd = ['ssh', 'inventory-vps', 'top -bn1 | head -n 5']
    res = subprocess.run(cmd, text=True, capture_output=True)
    return res.stdout

def get_finance_backfill_status():
    sql = """
    select
      status,
      count(*) as job_count,
      min(period_start) as oldest_period,
      max(period_end) as newest_period
    from public.finance_sync_jobs
    group by status;
    """
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    return res.stdout

if __name__ == "__main__":
    print("=== VPS Resource Usage ===")
    print(get_vps_resources())
    print("\n=== Finance Backfill Jobs Status ===")
    print(get_finance_backfill_status())
