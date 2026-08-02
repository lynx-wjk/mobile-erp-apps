import subprocess
import json

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- 1. DASHBOARD SNAPSHOT (July 1 - July 22, TikTok Shop) ---")
sql1 = "SELECT finance_dashboard_snapshot('2026-07-01'::date, '2026-07-22'::date, 'tiktok_shop'::text, NULL::uuid);"
res1 = run_sql(sql1)
try:
    d1 = json.loads(res1)
    print("Summary:", json.dumps(d1.get('summary', {}), indent=2))
    print("By Marketplace:", json.dumps(d1.get('by_marketplace', []), indent=2))
except Exception as e:
    print("Error parsing d1:", e)

print("\n--- 2. SKU ORDER DETAILS GROUP (July 1 - July 22, TikTok Shop) ---")
sql2 = "SELECT finance_sku_order_details_group_20260625('2026-07-01'::date, '2026-07-22'::date, 'tiktok_shop'::text, NULL::uuid, NULL, NULL, NULL, 'all', 1, 5);"
res2 = run_sql(sql2)
try:
    d2 = json.loads(res2)
    print("SKU Group Result Count:", len(d2) if isinstance(d2, list) else type(d2))
    if isinstance(d2, list) and len(d2) > 0:
        print("Sample Group Item 0:", json.dumps(d2[0], indent=2))
except Exception as e:
    print("Error parsing d2:", e)

