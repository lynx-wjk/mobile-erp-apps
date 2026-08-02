import subprocess
import json

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- 1. TEST FINANCE DASHBOARD SNAPSHOT (Ringkasan) ---")
sql_snap = "SELECT finance_customer_dashboard_snapshot_v24_6_82o(NULL, 30, 'all', 'all');"
res_snap = run_sql(sql_snap)
try:
    snap_json = json.loads(res_snap)
    print("Snapshot Summary:", json.dumps(snap_json.get('summary', {}), indent=2))
    print("Snapshot By Marketplace:", json.dumps(snap_json.get('by_marketplace', []), indent=2))
except Exception as e:
    print("Failed to parse snap json:", e, res_snap[:200])

print("\n--- 2. TEST SKU PAYOUT SUMMARY (Tab SKU) ---")
sql_sku = "SELECT finance_sku_payout_count_summary(NULL, '2026-07-01', '2026-07-22', 'tiktok_shop', 'all');"
res_sku = run_sql(sql_sku)
try:
    sku_json = json.loads(res_sku)
    print("SKU Summary count:", len(sku_json) if isinstance(sku_json, list) else type(sku_json))
    if isinstance(sku_json, list) and len(sku_json) > 0:
        print("Sample SKU item 0:", json.dumps(sku_json[0], indent=2))
except Exception as e:
    print("Failed to parse sku json:", e, res_sku[:200])

print("\n--- 3. TEST FINANCE REPORT SUMMARY (Tab Marketplace / Order Details) ---")
sql_rep = "SELECT finance_report_summary(NULL, '2026-07-01', '2026-07-22', 'tiktok_shop', 'all');"
res_rep = run_sql(sql_rep)
try:
    rep_json = json.loads(res_rep)
    print("Report Summary:", json.dumps(rep_json, indent=2))
except Exception as e:
    print("Failed to parse rep json:", e, res_rep[:200])

