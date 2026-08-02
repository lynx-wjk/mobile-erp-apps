import subprocess

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- 1. TEST FINANCE_ORDER_CANDIDATES_FOR_PERIOD_V3 ---")
sql_cand = """
SELECT * FROM finance_order_candidates_for_period_v3(
    p_start := '2026-07-01',
    p_end := '2026-07-22',
    p_marketplace := 'tiktok_shop',
    p_account_id := null,
    p_limit := 20,
    p_missing_only := true,
    p_tenant_id := null
);
"""
print(run_sql(sql_cand))

