param(
  [string]$Repo = "C:\Users\budic\Downloads\android\inventory_control_apps"
)

$ErrorActionPreference = "Stop"
Set-Location $Repo

git restore -- supabase/functions/marketplace-tiktok-service/index.ts

$py = @'
from pathlib import Path
import sys

p = Path("supabase/functions/marketplace-tiktok-service/index.ts")
s = p.read_text(encoding="utf-8-sig")

def must_replace(src, dst, label):
    global s
    if src not in s:
        sys.exit("ERROR: " + label + " not found")
    s = s.replace(src, dst, 1)

must_replace("""function moneyByKeys(source, keys) {
  for (const key of keys){
    const direct = nestedMoney(source[key]);
    if (Number.isFinite(direct)) return direct;
    const amount = nestedMoney(source[`${key}_amount`]);
    if (Number.isFinite(amount)) return amount;
    const value = nestedMoney(source[`${key}_value`]);
    if (Number.isFinite(value)) return value;
  }
  return 0;
}
""", """function moneyByKeys(source, keys) {
  if (!source || typeof source !== 'object') return 0;
  for (const key of keys){
    const direct = nestedMoney(source[key]);
    if (Number.isFinite(direct)) return direct;
    const amount = nestedMoney(source[`${key}_amount`]);
    if (Number.isFinite(amount)) return amount;
    const value = nestedMoney(source[`${key}_value`]);
    if (Number.isFinite(value)) return value;
  }
  return 0;
}
function valueByPath(source, path) {
  if (!source || typeof source !== 'object') return undefined;
  let current = source;
  for (const part of String(path).split('.')){
    if (!current || typeof current !== 'object') return undefined;
    current = current[part];
  }
  return current;
}
function moneyByPaths(source, paths) {
  for (const path of paths){
    const value = nestedMoney(valueByPath(source, path));
    if (Number.isFinite(value)) return value;
  }
  return 0;
}
function moneyByKeysOrPaths(source, keys, paths = []) {
  return moneyByKeys(source, keys) || moneyByPaths(source, paths);
}
function tiktokGrossAmount(row) {
  return moneyByKeysOrPaths(row, [
    'gross_sales','gross_amount','revenue','revenue_amount','net_sales','net_sales_amount',
    'order_amount','customer_payment_amount','sale_price','paid_amount','unit_gross_amount','unit_paid_amount'
  ], [
    'revenue_breakdown.subtotal_before_discount_amount',
    'revenue_breakdown.customer_payment_amount',
    'supplementary_component.customer_payment_amount',
    'supplementary_component.subtotal_before_discount_amount',
    'raw_item.sale_price'
  ]);
}
function tiktokPayoutAmount(row) {
  return moneyByKeysOrPaths(row, [
    'settlement','settlement_amount','total_settlement_amount','payout','payout_amount',
    'received_amount','seller_income','net_settlement','allocated_payout'
  ], [
    'settlement_breakdown.settlement_amount',
    'settlement_breakdown.total_settlement_amount',
    'supplementary_component.settlement_amount'
  ]);
}
function tiktokPlatformFee(row) {
  return Math.abs(moneyByKeysOrPaths(row, ['platform_fee','platform_service_fee','transaction_fee','allocated_platform_fee'], ['fee_breakdown.platform_fee','fee_breakdown.platform_service_fee','fee_breakdown.transaction_fee']));
}
function tiktokCommissionFee(row) {
  return Math.abs(moneyByKeysOrPaths(row, ['commission_fee','referral_fee','allocated_commission_fee'], ['fee_breakdown.commission_fee','fee_breakdown.referral_fee']));
}
function tiktokAffiliateFee(row) {
  return Math.abs(moneyByKeysOrPaths(row, ['affiliate_commission','affiliate_fee','affiliate_partner_commission','affiliate_shop_ads_commission','allocated_affiliate_fee'], ['fee_breakdown.affiliate_commission','fee_breakdown.affiliate_fee','fee_breakdown.affiliate_partner_commission','fee_breakdown.affiliate_shop_ads_commission']));
}
function tiktokShippingFee(row) {
  return Math.abs(moneyByKeysOrPaths(row, ['shipping_fee','shipping_cost','tiktok_shop_shipping_fee','allocated_shipping_fee'], ['fee_breakdown.shipping_fee','shipping_breakdown.shipping_fee']));
}
function tiktokRefundAmount(row) {
  return Math.abs(moneyByKeysOrPaths(row, ['refund_amount','gross_sales_refund','customer_refund','customer_refund_amount','allocated_refund_amount'], ['supplementary_component.customer_refund_amount','refund_breakdown.customer_refund_amount']));
}
function tiktokDiscountAmount(row) {
  const seller = Math.abs(moneyByKeysOrPaths(row, ['seller_discount','seller_discount_amount','seller_cofunded_voucher_discount'], ['revenue_breakdown.seller_discount_amount','supplementary_component.seller_discount_amount','raw_item.seller_discount']));
  const platform = Math.abs(moneyByKeysOrPaths(row, ['platform_discount','platform_discount_amount','platform_cofunded_voucher_discount'], ['revenue_breakdown.platform_discount_amount','supplementary_component.platform_discount_amount','raw_item.platform_discount']));
  const direct = Math.abs(moneyByKeys(row, ['discount_amount','allocated_discount_amount']));
  return seller + platform || direct;
}
""", "money helpers")

old_load = """async function loadOrderLite(serviceClient, tenantId, accountId, orderId) {
  const safeOrderId = orderId.replace(/[,()]/g, '');
  if (!safeOrderId) return null;
  const { data } = await serviceClient.from('marketplace_orders').select('marketplace_order_id, order_id, external_order_id, order_sn, tracking_number, order_created_at, paid_at, created_time, created_at, remote_order_id').eq('tenant_id', tenantId).eq('marketplace_account_id', accountId).or(`order_id.eq.${safeOrderId},external_order_id.eq.${safeOrderId},order_sn.eq.${safeOrderId},remote_order_id.eq.${safeOrderId}`).limit(1).maybeSingle();
  return data;
}
"""
new_load = old_load + """async function loadOrderFinanceFallbackRows(serviceClient, account, orderId, transactionRow) {
  const safeOrderId = getString(orderId, '').replace(/[,()]/g, '');
  if (!safeOrderId) return [];
  const tenantId = getString(account.tenant_id);
  const accountId = getString(account.marketplace_account_id);
  const { data, error } = await serviceClient.from('marketplace_order_items').select('marketplace_order_item_id, marketplace_order_id, order_sn, external_order_id, external_order_item_id, marketplace_product_id, marketplace_sku_id, marketplace_sku, marketplace_seller_sku, seller_sku, marketplace_product_name, product_name, marketplace_variant_name, variation_name, variant_name, local_product_id, product_id, mapped_product_id, local_sku, mapped_local_sku, marketplace_sku_map_id, qty, quantity, gross_amount, paid_amount, unit_gross_amount, unit_paid_amount, tracking_number, finance_price_source, raw_item').eq('tenant_id', tenantId).eq('marketplace_account_id', accountId).or(`order_sn.eq.${safeOrderId},external_order_id.eq.${safeOrderId}`).order('marketplace_order_item_id', { ascending: true }).limit(100);
  if (error) throw new Error(`Load order item fallback finance gagal: ${error.message}`);
  const rows = Array.isArray(data) ? data : [];
  if (rows.length === 0) return [];
  const itemGrosses = rows.map((row)=>Math.max(0, tiktokGrossAmount(row) || tiktokGrossAmount(row.raw_item) || getNumber(row.gross_amount ?? row.unit_gross_amount, 0)));
  const totalGross = itemGrosses.reduce((sum, value)=>sum + value, 0);
  const txPayout = tiktokPayoutAmount(transactionRow);
  const txPlatformFee = tiktokPlatformFee(transactionRow);
  const txCommissionFee = tiktokCommissionFee(transactionRow);
  const txAffiliateFee = tiktokAffiliateFee(transactionRow);
  const txShippingFee = tiktokShippingFee(transactionRow);
  const txRefund = tiktokRefundAmount(transactionRow);
  return rows.map((row, index)=>{
    const qty = Math.max(1, getNumber(row.quantity ?? row.qty, 1));
    const itemGross = itemGrosses[index] || 0;
    const ratio = totalGross > 0 ? itemGross / totalGross : 1 / rows.length;
    const rawItem = row.raw_item && typeof row.raw_item === 'object' ? row.raw_item : {};
    return {
      ...rawItem,
      ...row,
      id: getString(row.external_order_item_id ?? row.marketplace_order_item_id, `${safeOrderId}_${index}`),
      item_id: getString(row.external_order_item_id ?? row.marketplace_order_item_id, `${safeOrderId}_${index}`),
      order_id: safeOrderId,
      order_sn: safeOrderId,
      external_order_id: safeOrderId,
      sku_id: getString(row.marketplace_sku_id ?? row.marketplace_sku ?? rawItem.sku_id, ''),
      remote_sku_id: getString(row.marketplace_sku_id ?? row.marketplace_sku ?? rawItem.sku_id, ''),
      seller_sku: getString(row.marketplace_seller_sku ?? row.seller_sku ?? rawItem.seller_sku, ''),
      product_id: getString(row.marketplace_product_id ?? rawItem.product_id, ''),
      product_name: getString(row.marketplace_product_name ?? row.product_name ?? rawItem.product_name, ''),
      sku_name: getString(row.marketplace_variant_name ?? row.variation_name ?? row.variant_name ?? rawItem.sku_name, ''),
      variant_name: getString(row.marketplace_variant_name ?? row.variation_name ?? row.variant_name ?? rawItem.sku_name, ''),
      quantity: qty,
      qty,
      gross_amount: itemGross,
      order_amount: itemGross,
      unit_gross_amount: itemGross / qty,
      paid_amount: itemGross,
      unit_paid_amount: itemGross / qty,
      settlement_amount: txPayout * ratio,
      received_amount: txPayout * ratio,
      net_settlement: txPayout * ratio,
      platform_fee: txPlatformFee * ratio,
      commission_fee: txCommissionFee * ratio,
      affiliate_fee: txAffiliateFee * ratio,
      shipping_fee: txShippingFee * ratio,
      refund_amount: txRefund * ratio,
      discount_amount: tiktokDiscountAmount(rawItem) || tiktokDiscountAmount(row),
      tracking_number: getString(row.tracking_number ?? rawItem.tracking_number, ''),
      _finance_order_item_fallback: true,
      _finance_allocation_ratio: ratio
    };
  });
}
"""
must_replace(old_load, new_load, "loadOrderLite block")

s = s.replace(".or(`order_sn.eq.${safeOrderId},external_order_id.eq.${safeOrderId},order_id.eq.${safeOrderId},remote_order_id.eq.${safeOrderId}`)", ".or(`order_sn.eq.${safeOrderId},external_order_id.eq.${safeOrderId}`)")

must_replace("""  const remoteSkuId = getString(detailRow.sku_id ?? detailRow.remote_sku_id ?? detailRow.product_sku_id, '');
  const sellerSku = getString(detailRow.seller_sku ?? detailRow.seller_sku_code ?? detailRow.sku_code ?? detailRow.marketplace_seller_sku, '');
  const productName = getString(detailRow.product_name ?? detailRow.product?.name ?? transactionRow.product_name, '');
  const variationName = getString(detailRow.sku_name ?? detailRow.variation_name ?? detailRow.variant_name, '');
""", """  const remoteSkuId = getString(detailRow.sku_id ?? detailRow.remote_sku_id ?? detailRow.product_sku_id ?? detailRow.marketplace_sku_id ?? detailRow.marketplace_sku, '');
  const sellerSku = getString(detailRow.seller_sku ?? detailRow.seller_sku_code ?? detailRow.sku_code ?? detailRow.marketplace_seller_sku, '');
  const productName = getString(detailRow.product_name ?? detailRow.marketplace_product_name ?? detailRow.product?.name ?? transactionRow.product_name, '');
  const variationName = getString(detailRow.sku_name ?? detailRow.variation_name ?? detailRow.variant_name ?? detailRow.marketplace_variant_name, '');
""", "saveFinanceItem extraction")

start = s.find("  const gross = moneyByKeys(detailRow, [")
end = s.find("  const map = await resolveLocalSkuForFinance", start)
if start < 0 or end < 0:
    sys.exit("ERROR: saveFinanceItem money block range not found")
s = s[:start] + """  const gross = tiktokGrossAmount(detailRow) || tiktokGrossAmount(transactionRow);
  const payout = tiktokPayoutAmount(detailRow) || tiktokPayoutAmount(transactionRow);
  const platformFee = tiktokPlatformFee(detailRow) || tiktokPlatformFee(transactionRow);
  const commissionFee = tiktokCommissionFee(detailRow) || tiktokCommissionFee(transactionRow);
  const affiliateFee = tiktokAffiliateFee(detailRow) || tiktokAffiliateFee(transactionRow);
  const shippingFee = tiktokShippingFee(detailRow) || tiktokShippingFee(transactionRow);
  const refundAmount = tiktokRefundAmount(detailRow) || tiktokRefundAmount(transactionRow);
  const discountAmount = tiktokDiscountAmount(detailRow) || tiktokDiscountAmount(transactionRow);
""" + s[end:]

must_replace("""        if (detailRows.length === 0) detailRows = [
          tx
        ];
""", """        if (detailRows.length === 0 && orderId) {
          const fallbackRows = await loadOrderFinanceFallbackRows(serviceClient, refreshed, orderId, tx);
          if (fallbackRows.length > 0) detailRows = fallbackRows;
        }
        if (detailRows.length === 0) detailRows = [
          tx
        ];
""", "detailRows fallback")

p.write_text(s, encoding="utf-8", newline="\n")
print("PATCHED supabase/functions/marketplace-tiktok-service/index.ts")
'@

$py | python -

git diff --check
git diff -- supabase/functions/marketplace-tiktok-service/index.ts
