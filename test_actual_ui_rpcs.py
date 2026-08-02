import subprocess
import json

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- 1. TEST finance_dashboard_snapshot ---")
sql_snap = "SELECT finance_dashboard_snapshot(NULL, 30, 'all', 'all');"
res_snap = run_sql(sql_snap)
try:
    snap_json = json.loads(res_snap)
    print("Snapshot Summary Keys:", snap_json.keys() if isinstance(snap_json, dict) else type(snap_json))
    if isinstance(snap_json, dict):
        print("Summary:", json.dumps(snap_json.get('summary', {}), indent=2))
        print("By Marketplace:", json.dumps(snap_json.get('by_marketplace', []), indent=2))
except Exception as e:
    print("Failed snap json:", e, res_snap[:300])

print("\n--- 2. TEST finance_sku_summary_rows ---")
sql_sku = "SELECT finance_sku_summary_rows('2026-07-01'::date, '2026-07-22'::date, 'tiktok_shop', NULL);"
res_sku = run_sql(sql_sku)
try:
    sku_json = json.loads(res_sku)
    print("SKU Summary Rows Count:", len(sku_json) if isinstance(sku_json, list) else type(sku_json))
    if isinstance(sku_json, list) and len(sku_json) > 0:
        print("First SKU Item:", json.dumps(sku_json[0], indent=2))
except Exception as e:
    print("Failed sku json:", e, res_sku[:300])

