import json
import subprocess
import sys

def run_sql(query):
    # Run via ssh to inventory-vps docker postgres
    cmd = ["ssh", "inventory-vps", "docker exec -i supabase-db psql -U postgres -d postgres -t -A"]
    res = subprocess.run(cmd, input=query, text=True, capture_output=True, encoding='utf-8')
    if res.returncode != 0:
        print(f"Error running SQL:\nSTDERR: {res.stderr}\nSTDOUT: {res.stdout}")
        sys.exit(1)
    return res.stdout.strip()

def run_json_sql(query):
    out = run_sql(query)
    # The output might have newlines or multiple json lines, parse as JSON
    try:
        return json.loads(out)
    except Exception as e:
        print(f"Failed to parse JSON output: {e}\nRaw output: {out[:500]}")
        raise

print("=== Starting E2E Verification ===")

# 1. Test finance_sku_order_line_details for June 2026
print("\n--- Testing June 2026 finance_sku_order_line_details ---")
for filter_name in ['returned', 'unpaid', 'paid', 'all']:
    sql = f"""
    SELECT public.finance_sku_order_line_details(
        p_start => '2026-06-01'::date,
        p_end => '2026-06-30'::date,
        p_payout_filter => '{filter_name}',
        p_page => 1,
        p_page_size => 5
    )::text;
    """
    res = run_json_sql(sql)
    total = res.get('total') or res.get('total_rows')
    rows = res.get('data') or res.get('rows') or []
    print(f"Filter: {filter_name:10} | Total rows: {total:6} | Page size returned: {len(rows)}")
    if filter_name == 'returned':
        assert total > 0, f"June returned total must be > 0, got {total}"
        for r in rows:
            assert r.get('is_returned') is True, f"Expected is_returned=True, got {r.get('is_returned')} in {r.get('order_id')}"
            print(f"  Sample returned item: order_id={r.get('order_id')}, status={r.get('order_status')}, is_returned={r.get('is_returned')}, sku={r.get('local_sku') or r.get('marketplace_seller_sku')}")
    elif filter_name == 'unpaid':
        for r in rows:
            assert r.get('is_returned') is False, f"Expected is_returned=False for unpaid, got {r.get('is_returned')} in {r.get('order_id')}"
            assert r.get('has_payout') is False, f"Expected has_payout=False for unpaid, got {r.get('has_payout')}"
    elif filter_name == 'paid':
        for r in rows:
            assert r.get('has_payout') is True, f"Expected has_payout=True for paid, got {r.get('has_payout')}"

# 2. Test finance_sku_order_line_details for July 2026
print("\n--- Testing July 2026 finance_sku_order_line_details ---")
for filter_name in ['returned', 'unpaid', 'paid', 'all']:
    sql = f"""
    SELECT public.finance_sku_order_line_details(
        p_start => '2026-07-01'::date,
        p_end => '2026-07-31'::date,
        p_payout_filter => '{filter_name}',
        p_page => 1,
        p_page_size => 5
    )::text;
    """
    res = run_json_sql(sql)
    total = res.get('total') or res.get('total_rows')
    rows = res.get('data') or res.get('rows') or []
    print(f"Filter: {filter_name:10} | Total rows: {total:6} | Page size returned: {len(rows)}")
    if filter_name == 'returned':
        assert total > 0, f"July returned total must be > 0, got {total}"
        for r in rows:
            assert r.get('is_returned') is True, f"Expected is_returned=True, got {r.get('is_returned')} in {r.get('order_id')}"
            print(f"  Sample returned item: order_id={r.get('order_id')}, status={r.get('order_status')}, is_returned={r.get('is_returned')}, sku={r.get('local_sku') or r.get('marketplace_seller_sku')}")
    elif filter_name == 'unpaid':
        for r in rows:
            assert r.get('is_returned') is False, f"Expected is_returned=False for unpaid, got {r.get('is_returned')} in {r.get('order_id')}"
            assert r.get('has_payout') is False, f"Expected has_payout=False for unpaid, got {r.get('has_payout')}"
    elif filter_name == 'paid':
        for r in rows:
            assert r.get('has_payout') is True, f"Expected has_payout=True for paid, got {r.get('has_payout')}"

print("\n=== Line Details Verification Successful ===")
