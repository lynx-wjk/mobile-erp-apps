import json
import subprocess
import sys
import urllib.request
import ssl

def run_psql(query):
    # Execute query on live PostgreSQL in container supabase-db on inventory-vps
    cmd = ["ssh", "inventory-vps", "docker exec -i supabase-db psql -U postgres -d postgres -t -A"]
    res = subprocess.run(cmd, input=query, text=True, capture_output=True, encoding='utf-8')
    if res.returncode != 0:
        print(f"PSQL execution error:\nSTDERR: {res.stderr}\nSTDOUT: {res.stdout}")
        sys.exit(1)
    return res.stdout.strip()

def run_json_query(query):
    out = run_psql(query)
    try:
        return json.loads(out)
    except Exception as e:
        print(f"Error parsing JSON:\n{e}\nRaw output:\n{out[:500]}")
        sys.exit(1)

print("================================================================")
print("=== VICTORY AUDIT: INDEPENDENT DATABASE & RPC VERIFICATION ===")
print("================================================================")

# -------------------------------------------------------------
# 1. RPC: finance_sku_order_line_details Verification
# -------------------------------------------------------------
print("\n[CHECK 1] Testing finance_sku_order_line_details for June 2026...")
june_returned_res = run_json_query("""
SELECT public.finance_sku_order_line_details(
    p_start => '2026-06-01'::date,
    p_end => '2026-06-30'::date,
    p_payout_filter => 'returned',
    p_page => 1,
    p_page_size => 10
)::text;
""")

june_returned_total = june_returned_res.get('total')
june_returned_rows = june_returned_res.get('data') or june_returned_res.get('rows') or []
print(f"  June 2026 Returned Count: {june_returned_total} (Expect > 0)")
if june_returned_total <= 0:
    print("FAILED: June 2026 returned count is not > 0")
    sys.exit(1)

for idx, r in enumerate(june_returned_rows):
    assert r.get('is_returned') is True, f"Row {idx} is_returned is not True"
    assert 'Cancel' in r.get('payout_status') or 'Return' in r.get('payout_status'), f"Unexpected payout_status: {r.get('payout_status')}"
    print(f"    Sample {idx+1}: Order ID={r.get('order_id')}, Status={r.get('order_status')}, SKU={r.get('local_sku')}, is_returned={r.get('is_returned')}, PayoutStatus={r.get('payout_status')}")

print("\n[CHECK 2] Testing finance_sku_order_line_details for July 2026...")
july_returned_res = run_json_query("""
SELECT public.finance_sku_order_line_details(
    p_start => '2026-07-01'::date,
    p_end => '2026-07-31'::date,
    p_payout_filter => 'returned',
    p_page => 1,
    p_page_size => 10
)::text;
""")

july_returned_total = july_returned_res.get('total')
july_returned_rows = july_returned_res.get('data') or july_returned_res.get('rows') or []
print(f"  July 2026 Returned Count: {july_returned_total} (Expect > 0)")
if july_returned_total <= 0:
    print("FAILED: July 2026 returned count is not > 0")
    sys.exit(1)

for idx, r in enumerate(july_returned_rows):
    assert r.get('is_returned') is True, f"Row {idx} is_returned is not True"
    print(f"    Sample {idx+1}: Order ID={r.get('order_id')}, Status={r.get('order_status')}, SKU={r.get('local_sku')}, is_returned={r.get('is_returned')}, PayoutStatus={r.get('payout_status')}")

# Check Unpaid & Paid filters for strict separation in line details
print("\n[CHECK 3] Testing strict separation in unpaid and paid filters...")
for month_name, start_date, end_date in [('June 2026', '2026-06-01', '2026-06-30'), ('July 2026', '2026-07-01', '2026-07-31')]:
    unpaid_res = run_json_query(f"""
    SELECT public.finance_sku_order_line_details(
        p_start => '{start_date}'::date,
        p_end => '{end_date}'::date,
        p_payout_filter => 'unpaid',
        p_page => 1,
        p_page_size => 20
    )::text;
    """)
    unpaid_total = unpaid_res.get('total')
    unpaid_rows = unpaid_res.get('data') or []
    print(f"  {month_name} Unpaid Count: {unpaid_total}")
    for r in unpaid_rows:
        assert r.get('is_returned') is False, f"Violation: Returned order found in unpaid: {r}"
        assert r.get('has_payout') is False, f"Violation: Order with payout found in unpaid: {r}"
        assert r.get('payout_status') == 'Belum Payout', f"Violation: Unexpected payout status in unpaid: {r.get('payout_status')}"

    paid_res = run_json_query(f"""
    SELECT public.finance_sku_order_line_details(
        p_start => '{start_date}'::date,
        p_end => '{end_date}'::date,
        p_payout_filter => 'paid',
        p_page => 1,
        p_page_size => 20
    )::text;
    """)
    paid_total = paid_res.get('total')
    paid_rows = paid_res.get('data') or []
    print(f"  {month_name} Paid Count: {paid_total}")
    for r in paid_rows:
        assert r.get('is_returned') is False, f"Violation: Returned order found in paid: {r}"
        assert r.get('has_payout') is True, f"Violation: Order without payout found in paid: {r}"

    all_res = run_json_query(f"""
    SELECT public.finance_sku_order_line_details(
        p_start => '{start_date}'::date,
        p_end => '{end_date}'::date,
        p_payout_filter => 'all',
        p_page => 1,
        p_page_size => 1
    )::text;
    """)
    all_total = all_res.get('total')
    print(f"  {month_name} All Count: {all_total}")
    returned_total = june_returned_total if 'June' in month_name else july_returned_total
    assert (paid_total + unpaid_total + returned_total) == all_total, f"Sum mismatch: {paid_total} + {unpaid_total} + {returned_total} != {all_total}"
    print(f"  -> Sum partition integrity verified: {paid_total} (paid) + {unpaid_total} (unpaid) + {returned_total} (returned) == {all_total} (total)")

# -------------------------------------------------------------
# 2. RPC: finance_sku_order_details_group_20260625 Verification
# -------------------------------------------------------------
print("\n[CHECK 4] Testing finance_sku_order_details_group_20260625...")
for month_name, start_date, end_date in [('June 2026', '2026-06-01', '2026-06-30'), ('July 2026', '2026-07-01', '2026-07-31')]:
    grp_res = run_json_query(f"""
    SELECT public.finance_sku_order_details_group_20260625(
        p_start => '{start_date}'::date,
        p_end => '{end_date}'::date,
        p_payout_filter => 'all',
        p_page => 1,
        p_page_size => 500
    )::text;
    """)
    print(f"\n  --- {month_name} Group Summary ---")
    sku_rows = grp_res.get('data') or grp_res.get('rows') or []
    tot_qty = grp_res.get('total_qty')
    total_omzet = grp_res.get('total_omzet')
    total_payout = grp_res.get('total_payout')
    settled_hpp = grp_res.get('settled_hpp')
    unpaid_hpp = grp_res.get('unpaid_hpp')
    hpp_return = grp_res.get('hpp_return')
    net_profit = grp_res.get('net_profit')

    sum_total_qty = sum(r.get('total_qty', 0) for r in sku_rows)
    sum_qty_settled = sum(r.get('qty_settled', 0) for r in sku_rows)
    sum_qty_unsettled = sum(r.get('qty_unsettled', 0) for r in sku_rows)
    sum_qty_returned = sum(r.get('qty_returned', 0) for r in sku_rows)
    sum_settled_hpp = sum(r.get('settled_hpp', 0) for r in sku_rows)
    sum_unpaid_hpp = sum(r.get('unpaid_hpp', 0) for r in sku_rows)
    sum_hpp_return = sum(r.get('hpp_return', 0) for r in sku_rows)

    print(f"  SKU Count: {len(sku_rows)}")
    print(f"  Total Qty: {sum_total_qty} | Settled Qty: {sum_qty_settled} | Unsettled Qty: {sum_qty_unsettled} | Returned Qty: {sum_qty_returned}")
    print(f"  Total Omzet: Rp {total_omzet:,.2f}")
    print(f"  Total Payout: Rp {total_payout:,.2f}")
    print(f"  Settled HPP: Rp {sum_settled_hpp:,.2f} (RPC Header: Rp {settled_hpp:,.2f})")
    print(f"  Unpaid HPP: Rp {sum_unpaid_hpp:,.2f} (RPC Header: Rp {unpaid_hpp:,.2f})")
    print(f"  HPP Return: Rp {sum_hpp_return:,.2f} (RPC Header: Rp {hpp_return:,.2f})")
    print(f"  Net Profit: Rp {net_profit:,.2f}")

    # Verify partition sum of quantities
    assert (sum_qty_settled + sum_qty_unsettled + sum_qty_returned) == sum_total_qty, f"Qty mismatch: {sum_qty_settled} + {sum_qty_unsettled} + {sum_qty_returned} != {sum_total_qty}"
    print("  -> Total Quantity partition check PASSED.")

    # Cross-verify unpaid_hpp from raw database:
    # Query database directly to sum (qty * hpp) for orders where order_status is NOT cancelled/returned and has NO payout
    raw_unpaid_check = run_json_query(f"""
    WITH valid_orders AS (
      SELECT o.tenant_id, o.marketplace_order_id,
             coalesce(nullif(o.external_order_id, ''), nullif(o.order_sn, ''), o.marketplace_order_id::text) as order_key,
             (lower(concat_ws(' ', o.order_status, o.status, o.raw_order->>'status')) ~ '(cancel|canceled|cancelled|batal|dibatalkan|returned|return|refund|rts|gagal|failed|closed)') as is_returned
      FROM public.marketplace_orders o
      WHERE o.tenant_id = public._tenant_rpc_current_tenant_id()
        AND o.order_created_at >= ('{start_date}'::text || ' 00:00:00+07')::timestamptz
        AND o.order_created_at < (('{end_date}'::date + 1)::text || ' 00:00:00+07')::timestamptz
    ),
    order_payout AS (
      SELECT vo.*,
             coalesce(fr.payout_amount, fr.net_settlement, fr.received_amount, 0) as payout
      FROM valid_orders vo
      LEFT JOIN public.marketplace_finance_reports fr ON fr.tenant_id = vo.tenant_id AND fr.marketplace_order_id = vo.marketplace_order_id
    ),
    items AS (
      SELECT op.*,
             coalesce(nullif(oi.quantity, 0), nullif(oi.qty, 0), 1) as qty,
             coalesce(nullif(oi.marketplace_sku_id, ''), nullif(oi.remote_sku_id, '')) as sku_id,
             coalesce(nullif(oi.marketplace_seller_sku, ''), nullif(oi.seller_sku, '')) as seller_sku,
             coalesce(nullif(trim(oi.mapped_local_sku),''), nullif(trim(oi.local_sku),''), nullif(trim(oi.seller_sku),''), nullif(trim(oi.marketplace_seller_sku),''), nullif(trim(oi.marketplace_sku_id),''), 'Unmapped') as local_sku
      FROM order_payout op
      JOIN public.marketplace_order_items oi ON oi.tenant_id = op.tenant_id AND oi.marketplace_order_id = op.marketplace_order_id
    ),
    hpp_lookup AS (
      SELECT lower(nullif(marketplace_sku_id, '')) as sku_id,
             max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
      FROM public.marketplace_variant_hpp_mappings
      WHERE tenant_id = public._tenant_rpc_current_tenant_id() AND coalesce(is_active, true) = true AND nullif(marketplace_sku_id, '') is not null
      GROUP BY 1
    ),
    hpp_seller_lookup AS (
      SELECT lower(nullif(marketplace_seller_sku, '')) as seller_sku,
             max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
      FROM public.marketplace_variant_hpp_mappings
      WHERE tenant_id = public._tenant_rpc_current_tenant_id() AND coalesce(is_active, true) = true AND nullif(marketplace_seller_sku, '') is not null
      GROUP BY 1
    ),
    hpp_local_lookup AS (
      SELECT lower(nullif(local_sku, '')) as local_sku,
             max(coalesce(hpp_amount, hpp, hpp_per_item, 0))::numeric as hpp
      FROM public.marketplace_variant_hpp_mappings
      WHERE tenant_id = public._tenant_rpc_current_tenant_id() AND coalesce(is_active, true) = true AND nullif(local_sku, '') is not null
      GROUP BY 1
    ),
    enriched AS (
      SELECT it.*,
             coalesce(hs.hpp, hsel.hpp, hl.hpp, 0)::numeric as unit_hpp
      FROM items it
      LEFT JOIN hpp_lookup hs ON hs.sku_id = lower(it.sku_id)
      LEFT JOIN hpp_seller_lookup hsel ON hsel.seller_sku = lower(it.seller_sku)
      LEFT JOIN hpp_local_lookup hl ON hl.local_sku = lower(it.local_sku)
    )
    SELECT
      jsonb_build_object(
        'raw_unpaid_qty', coalesce(sum(qty) filter (where coalesce(payout, 0) = 0 and not is_returned), 0),
        'raw_unpaid_hpp', coalesce(sum(qty * unit_hpp) filter (where coalesce(payout, 0) = 0 and not is_returned), 0),
        'raw_returned_qty', coalesce(sum(qty) filter (where is_returned), 0),
        'raw_returned_hpp', coalesce(sum(qty * unit_hpp) filter (where is_returned), 0)
      ) as raw_stats
    FROM enriched;
    """)

    raw_stats = raw_unpaid_check.get('raw_stats', raw_unpaid_check)
    print(f"  Raw Stats Reconciliation:")
    print(f"    Raw Unpaid Qty: {raw_stats.get('raw_unpaid_qty')} vs RPC: {sum_qty_unsettled}")
    print(f"    Raw Unpaid HPP: Rp {raw_stats.get('raw_unpaid_hpp'):,.2f} vs RPC: Rp {sum_unpaid_hpp:,.2f}")
    print(f"    Raw Returned Qty: {raw_stats.get('raw_returned_qty')} vs RPC: {sum_qty_returned}")
    print(f"    Raw Returned HPP: Rp {raw_stats.get('raw_returned_hpp'):,.2f} vs RPC: Rp {sum_hpp_return:,.2f}")

    assert raw_stats.get('raw_unpaid_qty') == sum_qty_unsettled, "Raw unpaid qty != RPC sum_qty_unsettled"
    assert raw_stats.get('raw_unpaid_hpp') == sum_unpaid_hpp, "Raw unpaid HPP != RPC sum_unpaid_hpp"
    assert raw_stats.get('raw_returned_qty') == sum_qty_returned, "Raw returned qty != RPC sum_qty_returned"
    assert raw_stats.get('raw_returned_hpp') == sum_hpp_return, "Raw returned HPP != RPC sum_hpp_return"
    print(f"  -> {month_name} Cross-Reconciliation with Raw Database: 100% EXACT MATCH.")

# -------------------------------------------------------------
# 3. Live VPS Deployment Verification
# -------------------------------------------------------------
print("\n[CHECK 5] Testing Live VPS Deployment (https://mdhproduction.com)...")
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

req = urllib.request.Request(
    "https://mdhproduction.com/",
    headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
)
with urllib.request.urlopen(req, context=ctx, timeout=15) as resp:
    status_code = resp.status
    headers = dict(resp.getheaders())
    html_content = resp.read().decode('utf-8')
    print(f"  HTTPS Root Status: {status_code}")
    print(f"  Cache-Control: {headers.get('cache-control') or headers.get('Cache-Control')}")
    assert status_code == 200, f"Expected 200, got {status_code}"
    assert "flutter_bootstrap.js" in html_content or "flutter.js" in html_content or "main.dart.js" in html_content, "Flutter entrypoint not found in index.html"
    print("  -> Live root endpoint returns HTTP 200 with valid Flutter entrypoint.")

req_ver = urllib.request.Request(
    "https://mdhproduction.com/version.json",
    headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
)
with urllib.request.urlopen(req_ver, context=ctx, timeout=15) as resp:
    version_json = json.loads(resp.read().decode('utf-8'))
    print(f"  Live version.json: {version_json}")
    assert version_json.get('app_name') == 'mobile_erp', "version.json app_name mismatch"

req_js = urllib.request.Request(
    "https://mdhproduction.com/main.dart.js",
    headers={"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
)
with urllib.request.urlopen(req_js, context=ctx, timeout=15) as resp:
    js_status = resp.status
    js_len = resp.headers.get('Content-Length')
    print(f"  Live main.dart.js: Status={js_status}, Content-Length={js_len} bytes")
    assert js_status == 200, f"Expected 200 for main.dart.js, got {js_status}"

print("\n================================================================")
print("=== ALL INDEPENDENT VICTORY AUDIT CHECKS PASSED SUCCESSFULLY ===")
print("================================================================")
