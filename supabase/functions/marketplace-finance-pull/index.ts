import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const FUNCTION_VERSION = "marketplace-finance-pull";

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type, x-marketplace-cron-secret, x-stock-sync-cron-secret",
  "access-control-allow-methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    if (req.method !== "POST") return json({ ok: false, message: "Method not allowed" }, 405);

    const incomingSecret = text(
      req.headers.get("x-marketplace-cron-secret") ||
      req.headers.get("x-stock-sync-cron-secret"),
    );

    const body = await safeJson(req);
    const supabaseUrl = requiredEnv("SUPABASE_URL").replace(/\/+$/, "");
    const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { "x-client-info": FUNCTION_VERSION } },
    });

    const cronAuth = await verifyMarketplaceCronSecret(admin, incomingSecret);
    if (!cronAuth.ok) {
      return json({ ok: false, version: FUNCTION_VERSION, message: cronAuth.message }, cronAuth.status);
    }

    const tenantId = text(body.tenant_id);
    const accountId = text(body.account_id || body.marketplace_account_id);
    const daysBack = clampInt(body.days_back ?? body.finance_backlog_days ?? body.unpaid_backlog_days, 1, 90, 3);
    const maxOrders = clampInt(body.max_orders ?? body.limit, 1, 200, 40);
    const maxAccounts = clampInt(body.max_accounts, 1, 20, 5);

    let accountQuery = admin
      .from("marketplace_accounts")
      .select("marketplace_account_id, tenant_id, marketplace, environment, shop_id, shop_region, shop_name, store_alias, status, access_token_encrypted, refresh_token_encrypted, access_token_expired_at, refresh_token_expired_at")
      .eq("marketplace", "shopee")
      .eq("status", "active")
      .order("updated_at", { ascending: false, nullsFirst: false })
      .limit(maxAccounts);

    if (tenantId) accountQuery = accountQuery.eq("tenant_id", tenantId);
    if (accountId) accountQuery = accountQuery.eq("marketplace_account_id", accountId);

    const { data: accounts, error: accountError } = await accountQuery;
    if (accountError) throw new Error(`Load Shopee account gagal: ${accountError.message}`);

    if (!accounts || accounts.length === 0) {
      return json({
        ok: true,
        version: FUNCTION_VERSION,
        skipped: true,
        message: "Tidak ada akun Shopee active untuk finance pull.",
      });
    }

    const details = [];
    let totalChecked = 0;
    let totalSynced = 0;
    let totalFailed = 0;

    for (const account of accounts) {
      const result = await pullShopeeFinanceForAccount(admin, account, { daysBack, maxOrders });
      details.push(result);
      totalChecked += result.checked;
      totalSynced += result.synced;
      totalFailed += result.failed;
    }

    return json({
      ok: totalFailed === 0,
      version: FUNCTION_VERSION,
      marketplace: "shopee",
      accounts: accounts.length,
      checked: totalChecked,
      synced: totalSynced,
      failed: totalFailed,
      message: `Shopee finance pull selesai: cek ${totalChecked}, synced ${totalSynced}, gagal ${totalFailed}.`,
      details,
    });
  } catch (err) {
    return json({ ok: false, version: FUNCTION_VERSION, message: String(err) }, 500);
  }
});

async function pullShopeeFinanceForAccount(admin: any, account: any, args: { daysBack: number; maxOrders: number }) {
  const tokenBundle = await refreshShopeeAccessTokenIfNeeded(admin, account);
  const activeAccount = tokenBundle.account;
  const accessToken = tokenBundle.accessToken;

  const cutoff = new Date(Date.now() - args.daysBack * 24 * 60 * 60 * 1000).toISOString();

  const { data: orders, error: orderError } = await admin
    .from("marketplace_orders")
    .select("marketplace_order_id, tenant_id, marketplace_account_id, marketplace, shop_id, shop_region, order_sn, external_order_id, order_status, currency, total_amount, gross_amount, paid_amount, order_created_at, order_updated_at, created_at")
    .eq("marketplace", "shopee")
    .eq("marketplace_account_id", activeAccount.marketplace_account_id)
    .not("order_sn", "is", null)
    .gte("order_created_at", cutoff)
    .not("order_status", "in", "(CANCELLED,CANCELED,UNPAID)")
    .order("order_created_at", { ascending: false, nullsFirst: false })
    .limit(args.maxOrders);

  if (orderError) throw new Error(`Load Shopee orders gagal: ${orderError.message}`);

  let checked = 0;
  let synced = 0;
  let failed = 0;
  const warnings: string[] = [];

  for (const order of orders || []) {
    checked += 1;
    const orderSn = text(order.order_sn || order.external_order_id);

    try {
      const escrow = await shopeeGet(activeAccount, accessToken, "/api/v2/payment/get_escrow_detail", {
        order_sn: orderSn,
      });

      const response = escrow?.response ?? {};
      const income = response?.order_income ?? {};
      const buyer = response?.buyer_payment_info ?? {};
      const items = Array.isArray(income?.items) ? income.items : [];

      const itemGrossTotal = sumItemsGross(items);
      const grossAmount =
        money(income.cost_of_goods_sold) ||
        itemGrossTotal ||
        money(buyer.merchant_subtotal) ||
        money(order.gross_amount) ||
        money(order.total_amount);

      const payoutAmount =
        money(income.escrow_amount_after_adjustment) ||
        money(income.escrow_amount) ||
        money(order.paid_amount);

      const refundAmount = sumMoney(income, [
        "refund_amount",
        "seller_return_refund",
        "drc_adjustable_refund",
        "final_return_to_seller_shipping_fee",
      ]);

      const commissionFee = money(income.commission_fee);
      const platformFee = sumMoney(income, [
        "service_fee",
        "seller_transaction_fee",
        "buyer_transaction_fee",
        "credit_card_transaction_fee",
        "campaign_fee",
        "fbs_fee",
        "ams_commission_fee",
      ]);

      const shippingFee = sumMoney(income, [
        "actual_shipping_fee",
        "estimated_shipping_fee",
      ]);

      const discountAmount =
        Math.abs(money(buyer.shopee_voucher)) +
        Math.abs(money(buyer.seller_voucher)) +
        sumItemMoney(items, ["discount_from_voucher_seller", "discount_from_voucher_shopee", "discount_from_coin"]);

      const feeAmount = Math.max(0, grossAmount - payoutAmount - refundAmount);
      const periodStart = dateOnly(order.order_created_at || order.created_at || new Date().toISOString());

      const financePayload = {
        finance_report_id: crypto.randomUUID(),
        marketplace_finance_report_id: crypto.randomUUID(),
        marketplace_account_id: activeAccount.marketplace_account_id,
        tenant_id: activeAccount.tenant_id,
        marketplace: "shopee",
        shop_id: activeAccount.shop_id,
        shop_region: activeAccount.shop_region || "ID",
        report_type: "order_settlement",
        period_start: periodStart,
        period_end: periodStart,
        total_orders: 1,
        gross_sales: grossAmount,
        gross_amount: grossAmount,
        total_fees: feeAmount,
        fee_amount: feeAmount,
        platform_fee: platformFee,
        commission_fee: commissionFee,
        affiliate_fee: sumItemMoney(items, ["ams_commission_fee"]),
        shipping_fee: shippingFee,
        discount_amount: discountAmount,
        total_refund: refundAmount,
        refund_amount: refundAmount,
        net_settlement: payoutAmount,
        payout_amount: payoutAmount,
        received_amount: payoutAmount,
        total_hpp: 0,
        estimated_profit: payoutAmount,
        gross_profit: null,
        margin_percent: null,
        currency: text(order.currency) || "IDR",
        status: "pulled",
        settlement_status: text(order.order_status) || "UNKNOWN",
        settlement_date: periodStart,
        statement_id: `shopee_escrow_${orderSn}`,
        transaction_count: 1,
        marketplace_order_id: order.marketplace_order_id,
        order_id: orderSn,
        raw_response: escrow,
        raw_report: response,
        raw_finance: income,
        pulled_at: new Date().toISOString(),
        note: `Pulled by ${FUNCTION_VERSION}`,
        updated_at: new Date().toISOString(),
      };

      await upsertFinanceReport(admin, activeAccount, orderSn, financePayload);
      await updateOrderAmounts(admin, order, grossAmount, payoutAmount);
      await updateOrderItemsFromEscrow(admin, order, items, payoutAmount, itemGrossTotal);

      synced += 1;
    } catch (err) {
      failed += 1;
      warnings.push(`${orderSn}: ${String(err)}`.slice(0, 900));
    }
  }

  await logSync(admin, {
    tenant_id: activeAccount.tenant_id,
    marketplace_account_id: activeAccount.marketplace_account_id,
    marketplace: "shopee",
    action: "finance_pull_shopee_escrow",
    status: failed === 0 ? "success" : "partial_failed",
    message: `Shopee finance: checked ${checked}, synced ${synced}, failed ${failed}.`,
    request_payload: { days_back: args.daysBack, max_orders: args.maxOrders },
    response_payload: { warnings: warnings.slice(0, 10) },
  });

  return {
    account_id: activeAccount.marketplace_account_id,
    store_alias: activeAccount.store_alias,
    checked,
    synced,
    failed,
    warnings: warnings.slice(0, 10),
  };
}

async function upsertFinanceReport(admin: any, account: any, orderSn: string, payload: Record<string, unknown>) {
  const { data: existing, error: existingError } = await admin
    .from("marketplace_finance_reports")
    .select("finance_report_id")
    .eq("marketplace", "shopee")
    .eq("marketplace_account_id", account.marketplace_account_id)
    .eq("order_id", orderSn)
    .limit(1)
    .maybeSingle();

  if (existingError) throw new Error(`Cek finance existing gagal: ${existingError.message}`);

  if (existing?.finance_report_id) {
    const updatePayload = { ...payload };
    delete updatePayload.finance_report_id;
    delete updatePayload.marketplace_finance_report_id;

    const { error } = await admin
      .from("marketplace_finance_reports")
      .update(updatePayload)
      .eq("finance_report_id", existing.finance_report_id);

    if (error) throw new Error(`Update finance report gagal: ${error.message}`);
    return;
  }

  const { error } = await admin.from("marketplace_finance_reports").insert(payload);
  if (error) throw new Error(`Insert finance report gagal: ${error.message}`);
}

async function updateOrderAmounts(admin: any, order: any, grossAmount: number, payoutAmount: number) {
  const { error } = await admin
    .from("marketplace_orders")
    .update({
      gross_amount: grossAmount,
      paid_amount: payoutAmount,
      total_amount: grossAmount,
      payment_status: payoutAmount > 0 ? "PAID" : order.payment_status,
      updated_at: new Date().toISOString(),
    })
    .eq("marketplace_order_id", order.marketplace_order_id);

  if (error) throw new Error(`Update marketplace_orders gagal: ${error.message}`);
}

async function updateOrderItemsFromEscrow(admin: any, order: any, items: any[], payoutAmount: number, itemGrossTotal: number) {
  const orderSn = text(order.order_sn || order.external_order_id);

  for (const item of items) {
    const itemId = text(item.item_id);
    const modelId = text(item.model_id);
    if (!itemId || !modelId) continue;

    const qty = Math.max(1, money(item.quantity_purchased) || 1);
    const itemGross = money(item.discounted_price) * qty;
    const itemPaid = itemGrossTotal > 0 ? Math.round((payoutAmount * itemGross) / itemGrossTotal) : 0;

    const productName = text(item.item_name);
    const variantName = text(item.model_name);
    const sellerSku = text(item.model_sku) || text(item.item_sku);

    const commonPayload = {
      marketplace: "shopee",
      order_sn: orderSn,
      external_order_id: orderSn,
      marketplace_product_id: itemId,
      marketplace_sku_id: modelId,
      remote_item_id: itemId,
      remote_sku_id: modelId,
      marketplace_product_name: productName || null,
      product_name: productName || null,
      marketplace_variant_name: variantName || null,
      variation_name: variantName || null,
      variant_name: variantName || null,
      marketplace_seller_sku: sellerSku || null,
      seller_sku: sellerSku || null,
      qty,
      quantity: qty,
      gross_amount: itemGross,
      paid_amount: itemPaid,
      unit_gross_amount: qty > 0 ? Math.round(itemGross / qty) : itemGross,
      unit_paid_amount: qty > 0 ? Math.round(itemPaid / qty) : itemPaid,
      marketplace_price_updated_at: new Date().toISOString(),
      finance_price_source: "shopee_escrow_detail",
      raw_item: item,
      updated_at: new Date().toISOString(),
    };

    const { data: existing, error: existingError } = await admin
      .from("marketplace_order_items")
      .select("marketplace_order_item_id")
      .eq("marketplace_order_id", order.marketplace_order_id)
      .eq("marketplace_product_id", itemId)
      .eq("marketplace_sku_id", modelId)
      .limit(1)
      .maybeSingle();

    if (existingError) {
      throw new Error(`Cek marketplace_order_items gagal: ${existingError.message}`);
    }

    if (existing?.marketplace_order_item_id) {
      const { error } = await admin
        .from("marketplace_order_items")
        .update(commonPayload)
        .eq("marketplace_order_item_id", existing.marketplace_order_item_id);

      if (error) throw new Error(`Update marketplace_order_items gagal: ${error.message}`);
      continue;
    }

    const insertPayload = {
      marketplace_order_item_id: crypto.randomUUID(),
      marketplace_order_id: order.marketplace_order_id,
      tenant_id: order.tenant_id,
      marketplace_account_id: order.marketplace_account_id,
      external_order_item_id: `${orderSn}_${itemId}_${modelId}`,
      mapping_status: "unmapped",
      scan_status: "waiting_scan",
      scanned_qty: 0,
      reserved_qty: 0,
      returned_qty: 0,
      created_at: new Date().toISOString(),
      ...commonPayload,
    };

    const { error } = await admin
      .from("marketplace_order_items")
      .insert(insertPayload);

    if (error) {
      throw new Error(`Insert missing marketplace_order_items gagal: ${error.message}`);
    }
  }
}

async function refreshShopeeAccessTokenIfNeeded(admin: any, account: any, force = false) {
  const tokenSecret = requiredEnv("MARKETPLACE_TOKEN_ENCRYPTION_KEY");
  const currentAccessToken = await decryptText(text(account.access_token_encrypted), tokenSecret);
  if (!currentAccessToken) throw new Error("Shopee access token kosong. Re-authorize account.");

  const expiredAtMs = account.access_token_expired_at ? new Date(account.access_token_expired_at).getTime() : 0;
  const safeUntilMs = Date.now() + 10 * 60 * 1000;
  if (!force && expiredAtMs > safeUntilMs) return { account, accessToken: currentAccessToken };

  const refreshToken = await decryptText(text(account.refresh_token_encrypted), tokenSecret);
  if (!refreshToken) throw new Error("Refresh token Shopee kosong. Reconnect Shopee diperlukan.");

  const partnerId = requiredEnv("SHOPEE_PARTNER_ID");
  const partnerKey = requiredEnv("SHOPEE_PARTNER_KEY");
  const host = text(Deno.env.get("SHOPEE_HOST")) || "https://partner.shopeemobile.com";
  const path = "/api/v2/auth/access_token/get";
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const sign = await hmacHex(partnerKey, `${partnerId}${path}${timestamp}`);
  const url = new URL(path, host);

  url.searchParams.set("partner_id", partnerId);
  url.searchParams.set("timestamp", timestamp);
  url.searchParams.set("sign", sign);

  const payload = {
    partner_id: Number(partnerId),
    refresh_token: refreshToken,
    shop_id: numericOrString(account.shop_id),
  };

  const res = await fetch(url.toString(), {
    method: "POST",
    headers: { accept: "application/json", "content-type": "application/json" },
    body: JSON.stringify(payload),
  });

  const jsonRes = await res.json().catch(() => null);
  if (!res.ok || !jsonRes || jsonRes.error) {
    throw new Error(`Refresh Shopee token gagal: ${JSON.stringify(maskTokenObject(jsonRes))}`);
  }

  const data = jsonRes.response ?? jsonRes;
  const newAccessToken = text(data.access_token);
  const newRefreshToken = text(data.refresh_token) || refreshToken;

  if (!newAccessToken) throw new Error(`Refresh Shopee token gagal: response tidak berisi access_token.`);

  const accessExpiredAt =
    expireValueToIso(data.expire_in) ||
    expireValueToIso(data.access_token_expire_in) ||
    expireValueToIso(data.access_token_expired_at) ||
    new Date(Date.now() + 4 * 60 * 60 * 1000).toISOString();

  const refreshExpiredAt =
    expireValueToIso(data.refresh_token_expire_in) ||
    expireValueToIso(data.refresh_token_expired_at) ||
    account.refresh_token_expired_at ||
    null;

  const { data: updated, error } = await admin
    .from("marketplace_accounts")
    .update({
      access_token_encrypted: await encryptText(newAccessToken, tokenSecret),
      refresh_token_encrypted: await encryptText(newRefreshToken, tokenSecret),
      access_token_expired_at: accessExpiredAt,
      refresh_token_expired_at: refreshExpiredAt,
      status: "active",
      last_error: null,
      updated_at: new Date().toISOString(),
    })
    .eq("marketplace_account_id", account.marketplace_account_id)
    .select("marketplace_account_id, tenant_id, marketplace, environment, shop_id, shop_region, shop_name, store_alias, status, access_token_encrypted, refresh_token_encrypted, access_token_expired_at, refresh_token_expired_at")
    .single();

  if (error) throw new Error(`Simpan refresh token Shopee gagal: ${error.message}`);
  return { account: updated, accessToken: newAccessToken };
}

async function shopeeGet(account: any, accessToken: string, path: string, query: Record<string, string>) {
  const partnerId = requiredEnv("SHOPEE_PARTNER_ID");
  const partnerKey = requiredEnv("SHOPEE_PARTNER_KEY");
  const host = text(Deno.env.get("SHOPEE_HOST")) || "https://partner.shopeemobile.com";
  const shopId = text(account.shop_id);
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const sign = await hmacHex(partnerKey, `${partnerId}${path}${timestamp}${accessToken}${shopId}`);

  const url = new URL(path, host);
  url.searchParams.set("partner_id", partnerId);
  url.searchParams.set("timestamp", timestamp);
  url.searchParams.set("access_token", accessToken);
  url.searchParams.set("shop_id", shopId);
  url.searchParams.set("sign", sign);

  for (const [key, value] of Object.entries(query)) url.searchParams.set(key, value);

  const res = await fetch(url.toString(), {
    method: "GET",
    headers: { accept: "application/json" },
  });

  const body = await res.json().catch(async () => ({ raw: await res.text().catch(() => "") }));
  if (!res.ok || body?.error) {
    throw new Error(`Shopee API ${path} gagal HTTP ${res.status}: ${JSON.stringify(maskTokenObject(body))}`);
  }

  return body;
}

async function logSync(admin: any, payload: Record<string, unknown>) {
  try {
    await admin.from("marketplace_sync_logs").insert({
      sync_log_id: crypto.randomUUID(),
      ...payload,
      created_at: new Date().toISOString(),
    });
  } catch (_) {}
}

function sumItemsGross(items: any[]) {
  return items.reduce((sum, item) => {
    const qty = Math.max(1, money(item.quantity_purchased) || 1);
    return sum + money(item.discounted_price) * qty;
  }, 0);
}

function sumItemMoney(items: any[], keys: string[]) {
  let total = 0;
  for (const item of items) {
    for (const key of keys) total += Math.abs(money(item?.[key]));
  }
  return total;
}

function sumMoney(source: any, keys: string[]) {
  return keys.reduce((sum, key) => sum + Math.abs(money(source?.[key])), 0);
}

function money(value: unknown) {
  if (value === null || value === undefined || value === "") return 0;
  const n = Number(String(value).replace(/[^0-9.-]/g, ""));
  return Number.isFinite(n) ? n : 0;
}

function numericOrString(value: unknown) {
  const clean = text(value);
  const n = Number(clean);
  return Number.isFinite(n) && clean !== "" ? n : clean;
}

function expireValueToIso(value: unknown) {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return null;
  if (n > 2000000000) return new Date(n * 1000).toISOString();
  return new Date(Date.now() + n * 1000).toISOString();
}

async function encryptText(plainText: string, secret: string) {
  const key = await cryptoKey(secret, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = new Uint8Array(await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    new TextEncoder().encode(plainText),
  ));
  return `aesgcm:${bytesToBase64(iv)}:${bytesToBase64(encrypted)}`;
}

async function decryptText(value: string, secret: string) {
  if (!value) return "";
  const key = await cryptoKey(secret, ["decrypt"]);

  if (value.startsWith("aesgcm:")) {
    const [, ivPart, cipherPart] = value.split(":");
    const decrypted = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: base64ToBytes(ivPart) },
      key,
      base64ToBytes(cipherPart),
    );
    return new TextDecoder().decode(decrypted);
  }

  const [ivPart, cipherPart] = value.split(".");
  const decrypted = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: base64UrlToBytes(ivPart) },
    key,
    base64UrlToBytes(cipherPart),
  );
  return new TextDecoder().decode(decrypted);
}

async function cryptoKey(secret: string, usages: KeyUsage[]) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret));
  return crypto.subtle.importKey("raw", digest, "AES-GCM", false, usages);
}

async function hmacHex(secret: string, message: string) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function base64ToBytes(input: string) {
  const binary = atob(input);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function base64UrlToBytes(input: string) {
  const normalized = input.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
  return base64ToBytes(padded);
}

function bytesToBase64(bytes: Uint8Array) {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}

function maskTokenObject(input: unknown) {
  return JSON.parse(JSON.stringify(input, (_key, value) => {
    if (typeof value !== "string") return value;
    if (value.length < 20) return value;
    return `${value.slice(0, 6)}...${value.slice(-6)}`;
  }));
}


async function verifyMarketplaceCronSecret(admin: any, incomingSecret: string): Promise<{ ok: boolean; status: number; message: string }> {
  if (!incomingSecret) {
    return { ok: false, status: 401, message: "Invalid cron secret" };
  }

  const { data, error } = await admin.rpc("verify_marketplace_cron_secret", {
    p_secret: incomingSecret,
  });

  if (!error && data === true) {
    return { ok: true, status: 200, message: "ok" };
  }

  const fallbackSecret = text(
    Deno.env.get("MARKETPLACE_CRON_SECRET") ||
    Deno.env.get("MARKETPLACE_AUTO_SYNC_CRON_SECRET") ||
    Deno.env.get("STOCK_SYNC_CRON_SECRET"),
  );

  if (fallbackSecret && incomingSecret === fallbackSecret) {
    return { ok: true, status: 200, message: "ok" };
  }

  if (error) {
    console.error("verify_marketplace_cron_secret failed", error.message);
  }

  return { ok: false, status: 401, message: "Invalid cron secret" };
}


async function safeJson(req: Request) {
  try {
    const raw = await req.text();
    if (!raw.trim()) return {};
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch (_) {
    return {};
  }
}

function requiredEnv(name: string) {
  const value = text(Deno.env.get(name));
  if (!value) throw new Error(`${name} belum diset.`);
  return value;
}

function clampInt(value: unknown, min: number, max: number, fallback: number) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.trunc(n)));
}

function dateOnly(value: unknown) {
  const d = new Date(text(value));
  if (Number.isNaN(d.getTime())) return new Date().toISOString().slice(0, 10);
  return d.toISOString().slice(0, 10);
}

function text(value: unknown) {
  return String(value ?? "").trim();
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      ...corsHeaders,
      "content-type": "application/json; charset=utf-8",
    },
  });
}
