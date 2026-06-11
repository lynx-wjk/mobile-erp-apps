import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const FUNCTION_VERSION = "marketplace-stock-sync-worker-shopee-seller-stock-v33-2026-06-09";

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    if (req.method !== "POST") {
      return json({ ok: false, message: "Method not allowed" }, 405);
    }

    const supabaseUrl = requiredEnv("SUPABASE_URL");
    const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");
    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });


    const body = await safeJson(req);
    const configuredCronSecret = String(
      Deno.env.get("MARKETPLACE_CRON_SECRET") ||
      Deno.env.get("MARKETPLACE_AUTO_SYNC_CRON_SECRET") ||
      Deno.env.get("STOCK_SYNC_CRON_SECRET") ||
      ""
    ).trim();
    const incomingCronSecret = String(
      req.headers.get("x-marketplace-cron-secret") ||
      req.headers.get("x-stock-sync-cron-secret") ||
      ""
    ).trim();
    const isCronRequest = configuredCronSecret.length > 0 && incomingCronSecret === configuredCronSecret;

    let profile: any = null;

    if (isCronRequest) {
      profile = {
        user_id: "00000000-0000-0000-0000-000000000000",
        tenant_id: text(body.tenant_id),
        role_id: "super_admin",
        status: "active",
      };
    } else {
      const bearer = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "").trim();
      if (!bearer) return json({ ok: false, message: "Missing authorization header" }, 401);

      const { data: userData, error: userError } = await admin.auth.getUser(bearer);
      if (userError || !userData?.user) return json({ ok: false, message: "Invalid user session" }, 401);

      const { data: loadedProfile, error: profileError } = await admin
        .from("users")
        .select("user_id, tenant_id, role_id, status")
        .eq("user_id", userData.user.id)
        .maybeSingle();

      if (profileError || !loadedProfile) {
        return json({ ok: false, message: profileError?.message || "User profile not found" }, 403);
      }
      if (loadedProfile.status !== "active") return json({ ok: false, message: "User is not active" }, 403);
      profile = loadedProfile;
    }

    const tenantId = String(body.tenant_id || profile.tenant_id || "").trim();
    const marketplaceAccountId = String(body.marketplace_account_id || "").trim();
    const limit = clampInt(body.limit, 1, 50, 20);

    if (!tenantId) return json({ ok: false, message: "tenant_id is required" }, 400);

    const roleId = String(profile.role_id || "").trim();
    const isSuperAdmin = roleId === "super_admin";
    const isDemoSuperAdmin = roleId === "demo_super_admin";

    if (!isSuperAdmin && !isDemoSuperAdmin && tenantId !== profile.tenant_id) {
      return json({ ok: false, message: "Forbidden tenant access" }, 403);
    }

    const requestedDryRun = body.dry_run !== false;
    const realEnabled = envFlag("MARKETPLACE_STOCK_SYNC_REAL_ENABLED", false);

    if (!requestedDryRun && isDemoSuperAdmin) {
      return json({ ok: false, message: "Demo super admin tidak boleh menjalankan real stock sync." }, 403);
    }

    if (!requestedDryRun && !realEnabled) {
      return json({
        ok: false,
        dry_run: false,
        message: "Real stock sync belum aktif. Set env MARKETPLACE_STOCK_SYNC_REAL_ENABLED=true di Supabase Edge Function, lalu deploy ulang function.",
      }, 400);
    }

    const dryRun = requestedDryRun || isDemoSuperAdmin;

    let query = admin
      .from("marketplace_stock_sync_logs")
      .select("marketplace_stock_sync_log_id, tenant_id, marketplace_account_id, marketplace_sku_map_id, product_id, marketplace, local_sku, marketplace_product_id, marketplace_sku_id, requested_stock, sync_status, attempt_count, request_payload")
      .eq("tenant_id", tenantId)
      .eq("sync_status", "queued")
      .order("created_at", { ascending: true })
      .limit(limit);

    if (marketplaceAccountId && marketplaceAccountId !== "all") {
      query = query.eq("marketplace_account_id", marketplaceAccountId);
    }

    const { data: logs, error: logsError } = await query;
    if (logsError) throw new Error(`Load queue failed: ${logsError.message}`);

    const result = {
      ok: true,
      dry_run: dryRun,
      picked: logs?.length || 0,
      success: 0,
      dry_run_success: 0,
      waiting_marketplace_ids: 0,
      skipped: 0,
      failed: 0,
      details: [] as Array<Record<string, unknown>>,
    };

    for (const log of logs || []) {
      const logId = log.marketplace_stock_sync_log_id;
      const attempt = Number(log.attempt_count || 0) + 1;

      await admin
        .from("marketplace_stock_sync_logs")
        .update({
          sync_status: "processing",
          attempt_count: attempt,
          started_at: new Date().toISOString(),
          worker_name: "marketplace-stock-sync-worker-real-api-v1",
          worker_message: dryRun ? "Dry-run processing" : "Real API processing",
          updated_at: new Date().toISOString(),
        })
        .eq("marketplace_stock_sync_log_id", logId);

      try {
        const missingIds = !text(log.marketplace_product_id) || !text(log.marketplace_sku_id);
        if (missingIds) {
          await finishLog(admin, log, {
            status: "waiting_marketplace_ids",
            error: "Marketplace product ID and SKU ID are required before API stock update.",
            message: "Waiting for marketplace IDs",
          });
          result.waiting_marketplace_ids += 1;
          result.details.push({ log_id: logId, status: "waiting_marketplace_ids", sku: log.local_sku });
          continue;
        }

        const { data: account, error: accountError } = await admin
          .from("marketplace_accounts")
          .select("marketplace_account_id, tenant_id, marketplace, app_key, shop_id, shop_cipher, shop_region, shop_name, status, stock_sync_enabled, default_warehouse_id, access_token_encrypted, refresh_token_encrypted, access_token_expired_at, refresh_token_expired_at, environment")
          .eq("marketplace_account_id", log.marketplace_account_id)
          .maybeSingle();

        if (accountError || !account) throw new Error(accountError?.message || "Marketplace account not found");
        if (account.tenant_id !== tenantId) throw new Error("Marketplace account tenant mismatch");

        if (account.status !== "active") {
          await finishLog(admin, log, {
            status: "skipped",
            error: "Marketplace account is not active.",
            message: "Skipped inactive marketplace account",
          });
          result.skipped += 1;
          result.details.push({ log_id: logId, status: "skipped", sku: log.local_sku });
          continue;
        }

        if (account.stock_sync_enabled === false) {
          await finishLog(admin, log, {
            status: "skipped",
            error: "Stock sync disabled for this marketplace account.",
            message: "Skipped by account stock_sync_enabled=false",
          });
          result.skipped += 1;
          result.details.push({ log_id: logId, status: "skipped", sku: log.local_sku });
          continue;
        }


        const normalizedStock = Math.max(0, Math.floor(Number(log.requested_stock || 0)));
        const variantSnapshot = await loadVariantSnapshot(admin, log);
        const skuMap = await loadSkuMap(admin, log);
        const outboundPayload = buildOutboundPayload(account, log, skuMap, variantSnapshot, normalizedStock, dryRun);

        if (dryRun) {
          await finishLog(admin, log, {
            status: "dry_run_success",
            error: null,
            message: "Dry-run OK. Real marketplace stock was not changed.",
            requestPayload: {
              ...(log.request_payload || {}),
              worker_payload: outboundPayload,
            },
            responsePayload: {
              dry_run: true,
              message: "Dry-run OK. No stock was sent to TikTok/Shopee.",
              stock: normalizedStock,
              marketplace: log.marketplace,
              local_sku: log.local_sku,
            },
            isDryRun: true,
          });
          result.dry_run_success += 1;
          result.details.push({ log_id: logId, status: "dry_run_success", sku: log.local_sku, stock: normalizedStock });
          continue;
        }

        const apiResult = await sendStockToMarketplace(admin, account, log, skuMap, variantSnapshot, normalizedStock);

        await finishLog(admin, log, {
          status: "success",
          error: null,
          message: "Real stock sync success",
          requestPayload: {
            ...(log.request_payload || {}),
            worker_payload: apiResult.request_payload,
          },
          responsePayload: apiResult.response_payload,
          isDryRun: false,
        });

        await admin
          .from("marketplace_sku_maps")
          .update({
            last_sync_at: new Date().toISOString(),
            last_error: null,
            updated_at: new Date().toISOString(),
          })
          .eq("marketplace_sku_map_id", log.marketplace_sku_map_id);

        result.success += 1;
        result.details.push({ log_id: logId, status: "success", sku: log.local_sku, stock: normalizedStock, marketplace: log.marketplace });
      } catch (err) {
        await finishLog(admin, log, {
          status: "failed",
          error: String(err),
          message: "Worker failed",
        });

        await admin
          .from("marketplace_sku_maps")
          .update({
            last_error: String(err),
            updated_at: new Date().toISOString(),
          })
          .eq("marketplace_sku_map_id", log.marketplace_sku_map_id);

        result.failed += 1;
        result.details.push({ log_id: logId, status: "failed", error: String(err), sku: log.local_sku });
      }
    }

    return json(result);
  } catch (err) {
    return json({ ok: false, message: String(err) }, 500);
  }
});

async function sendStockToMarketplace(admin: any, account: any, log: any, skuMap: any, variantSnapshot: any, stock: number) {
  if (log.marketplace === "tiktok_shop") {
    return sendTikTokStock(admin, account, log, skuMap, variantSnapshot, stock);
  }

  if (log.marketplace === "shopee") {
    return sendShopeeStock(admin, account, log, stock);
  }

  throw new Error(`Unsupported marketplace for real stock sync: ${log.marketplace}`);
}

async function sendTikTokStock(admin: any, account: any, log: any, skuMap: any, variantSnapshot: any, stock: number) {
  const appKey = text(account.app_key) || requiredEnv("TIKTOK_APP_KEY");
  const appSecret = requiredEnv("TIKTOK_APP_SECRET");
  const tokenSecret = requiredEnv("MARKETPLACE_TOKEN_ENCRYPTION_KEY");
  const resolvedToken = await ensureTikTokAccessToken(admin, account, tokenSecret, appKey, appSecret, false);
  account = resolvedToken.account;
  let accessToken = resolvedToken.accessToken;
  if (!accessToken) throw new Error("TikTok access token kosong. Re-authorize account.");

  const shopCipher = text(account.shop_cipher);
  if (!shopCipher) throw new Error("TikTok shop_cipher kosong. Re-authorize account, lalu Pull Product ulang.");

  const warehouseResolution = await resolveTikTokWarehouseId(admin, account, log, skuMap, variantSnapshot, {
    appKey,
    appSecret,
    accessToken,
    shopCipher,
    tokenSecret,
  });
  account = warehouseResolution.account || account;
  accessToken = warehouseResolution.accessToken || accessToken;
  const warehouseId = warehouseResolution.warehouseId;

  if (!warehouseId) {
    throw new Error("TikTok warehouse_id tidak ditemukan. Pastikan scope seller.logistics aktif, deploy ulang function, lalu Pull Product ulang. Fallback: isi env TIKTOK_DEFAULT_WAREHOUSE_ID dari Seller Center/Open API warehouse.");
  }

  const productId = text(log.marketplace_product_id);
  const skuId = text(log.marketplace_sku_id);
  const path = `/product/202309/products/${encodeURIComponent(productId)}/inventory/update`;
  const body = {
    skus: [
      {
        id: skuId,
        inventory: [
          {
            warehouse_id: warehouseId,
            quantity: stock,
          },
        ],
      },
    ],
  };

  let response: any;
  try {
    response = await tiktokRequest({
      method: "POST",
      path,
      appKey,
      appSecret,
      accessToken,
      shopCipher,
      body,
    });
  } catch (err) {
    if (!isTikTokAuthError(err)) throw err;

    const refreshed = await ensureTikTokAccessToken(admin, account, tokenSecret, appKey, appSecret, true);
    account = refreshed.account;
    accessToken = refreshed.accessToken;

    response = await tiktokRequest({
      method: "POST",
      path,
      appKey,
      appSecret,
      accessToken,
      shopCipher: text(account.shop_cipher) || shopCipher,
      body,
    });
  }

  return {
    request_payload: {
      platform: "tiktok_shop",
      path,
      shop_cipher_masked: mask(shopCipher),
      product_id: productId,
      sku_id: skuId,
      warehouse_id: warehouseId,
      stock,
      body,
    },
    response_payload: sanitizeResponse(response),
  };
}

async function sendShopeeStock(admin: any, account: any, log: any, stock: number) {
  const tokenBundle = await refreshShopeeAccessTokenIfNeeded(admin, account);
  account = tokenBundle.account;
  const accessToken = tokenBundle.accessToken;
  const credential = resolveShopeeCredentials(account.environment);

  const shopId = text(account.shop_id);
  if (!shopId) throw new Error("Shopee shop_id kosong. Re-authorize account.");

  const itemId = toShopeeNumber(text(log.marketplace_product_id), "Shopee item_id");
  const modelIdRaw = text(log.marketplace_sku_id);
  const path = "/api/v2/product/update_stock";
  const timestamp = Math.floor(Date.now() / 1000);
  const signBase = `${credential.partnerId}${path}${timestamp}${accessToken}${shopId}`;
  const sign = await hmacHex(credential.partnerKey, signBase);
  const url = new URL(path, credential.host);
  url.searchParams.set("partner_id", credential.partnerId);
  url.searchParams.set("timestamp", String(timestamp));
  url.searchParams.set("access_token", accessToken);
  url.searchParams.set("shop_id", shopId);
  url.searchParams.set("sign", sign);

  const stockItem: Record<string, unknown> = {
    seller_stock: [
      {
        stock,
      },
    ],
  };
  if (modelIdRaw && modelIdRaw !== "0") {
    stockItem.model_id = toShopeeNumber(modelIdRaw, "Shopee model_id");
  }

  const body = {
    item_id: itemId,
    stock_list: [stockItem],
  };

  const res = await fetch(url.toString(), {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });

  const response = await res.json().catch(() => null);

  if (!res.ok || !response) {
    throw new Error(`Shopee API HTTP ${res.status} env=${credential.environment} account_env=${text(account.environment) || "-"} host=${credential.host}: ${JSON.stringify(sanitizeResponse(response))}`);
  }

  if (response.error) {
    throw new Error(`Shopee API error env=${credential.environment} account_env=${text(account.environment) || "-"} host=${credential.host}: ${JSON.stringify(sanitizeResponse(response))}`);
  }

  return {
    request_payload: {
      platform: "shopee",
      path,
      environment: credential.environment,
      account_environment: text(account.environment) || null,
      host: credential.host,
      shop_id: shopId,
      item_id: itemId,
      model_id: stockItem.model_id ?? null,
      stock,
      body,
    },
    response_payload: sanitizeResponse(response),
  };
}


async function refreshShopeeAccessTokenIfNeeded(admin: any, account: any, force = false): Promise<{ account: any; accessToken: string }> {
  const tokenSecret = requiredEnv("MARKETPLACE_TOKEN_ENCRYPTION_KEY");
  const currentAccessToken = await decryptText(text(account.access_token_encrypted), tokenSecret);
  if (!currentAccessToken) throw new Error("Shopee access token kosong. Re-authorize account.");

  const expiredAtMs = account.access_token_expired_at ? new Date(account.access_token_expired_at).getTime() : 0;
  const safeUntilMs = Date.now() + 10 * 60 * 1000;
  if (!force && expiredAtMs > safeUntilMs) return { account, accessToken: currentAccessToken };

  const refreshToken = await decryptText(text(account.refresh_token_encrypted), tokenSecret);
  if (!refreshToken) {
    await markMarketplaceAuthError(admin, account, "Refresh token Shopee kosong. Reconnect Shopee diperlukan.");
    throw new Error("Refresh token Shopee kosong. Reconnect Shopee diperlukan.");
  }

  const credential = resolveShopeeCredentials(account.environment);
  const shopId = text(account.shop_id);
  if (!shopId) throw new Error("Shopee shop_id kosong. Reconnect Shopee diperlukan.");

  const path = "/api/v2/auth/access_token/get";
  const timestamp = Math.floor(Date.now() / 1000);
  const signBase = `${credential.partnerId}${path}${timestamp}`;
  const sign = await hmacHex(credential.partnerKey, signBase);
  const url = new URL(path, credential.host);
  url.searchParams.set("partner_id", credential.partnerId);
  url.searchParams.set("timestamp", String(timestamp));
  url.searchParams.set("sign", sign);

  const body = {
    partner_id: Number(credential.partnerId),
    refresh_token: refreshToken,
    shop_id: numericOrString(shopId),
  };

  const res = await fetch(url.toString(), {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });

  const payload = await res.json().catch(() => null);

  if (!res.ok || !payload || payload.error) {
    const message = `Refresh token Shopee gagal HTTP ${res.status}: ${JSON.stringify(sanitizeResponse(payload))}`;
    await markMarketplaceAuthError(admin, account, message);
    throw new Error(message);
  }

  const data = payload?.response ?? payload ?? {};
  const newAccessToken = text(data.access_token);
  const newRefreshToken = text(data.refresh_token) || refreshToken;

  if (!newAccessToken) {
    const message = `Refresh token Shopee gagal: response tidak berisi access_token. ${JSON.stringify(sanitizeResponse(payload))}`;
    await markMarketplaceAuthError(admin, account, message);
    throw new Error(message);
  }

  const accessExpiredAt = expireValueToIso(data.expire_in)
    || expireValueToIso(data.access_token_expire_in)
    || expireValueToIso(data.access_token_expired_at)
    || new Date(Date.now() + 4 * 60 * 60 * 1000).toISOString();

  const refreshExpiredAt = expireValueToIso(data.refresh_token_expire_in)
    || expireValueToIso(data.refresh_token_expired_at)
    || account.refresh_token_expired_at
    || null;

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
    .select("marketplace_account_id, tenant_id, marketplace, app_key, shop_id, shop_cipher, shop_region, shop_name, status, stock_sync_enabled, default_warehouse_id, access_token_encrypted, refresh_token_encrypted, access_token_expired_at, refresh_token_expired_at, environment")
    .single();

  if (error) throw new Error(`Simpan refresh token Shopee gagal: ${error.message}`);
  return { account: updated, accessToken: newAccessToken };
}

function resolveShopeeCredentials(environmentValue: unknown) {
  const environment = normalizeMarketplaceEnvironment(environmentValue);
  const productionPartnerId = requiredEnv("SHOPEE_PARTNER_ID");
  const productionPartnerKey = requiredEnv("SHOPEE_PARTNER_KEY");

  if (environment === "testing") {
    const testPartnerId = requiredEnv("SHOPEE_TEST_PARTNER_ID");
    const testPartnerKey = requiredEnv("SHOPEE_TEST_PARTNER_KEY");
    return {
      environment,
      host: optionalEnv("SHOPEE_TEST_HOST") || optionalEnv("SHOPEE_SANDBOX_HOST") || "https://openplatform.sandbox.test-stable.shopee.sg",
      partnerId: testPartnerId,
      partnerKey: testPartnerKey,
    };
  }

  return {
    environment,
    host: optionalEnv("SHOPEE_HOST") || optionalEnv("SHOPEE_API_BASE_URL") || "https://partner.shopeemobile.com",
    partnerId: productionPartnerId,
    partnerKey: productionPartnerKey,
  };
}

function normalizeMarketplaceEnvironment(value: unknown): "testing" | "production" {
  const clean = text(value).toLowerCase();
  if (["test", "testing", "dev", "development", "sandbox"].includes(clean)) return "testing";
  return "production";
}

function optionalEnv(name: string): string | null {
  const value = Deno.env.get(name);
  if (!value || !value.trim()) return null;
  return value.trim();
}

function numericOrString(value: string): number | string {
  return /^\d+$/.test(value) ? Number(value) : value;
}

async function loadVariantSnapshot(admin: any, log: any) {
  const { data, error } = await admin
    .from("marketplace_variant_snapshots")
    .select("marketplace_variant_snapshot_id, raw_variant, stock_quantity")
    .eq("tenant_id", log.tenant_id)
    .eq("marketplace_account_id", log.marketplace_account_id)
    .eq("marketplace_product_id", log.marketplace_product_id)
    .eq("marketplace_sku_id", log.marketplace_sku_id)
    .order("updated_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (error) throw new Error(`Load variant snapshot failed: ${error.message}`);
  return data;
}

async function loadSkuMap(admin: any, log: any) {
  if (!text(log.marketplace_sku_map_id)) return null;
  const { data, error } = await admin
    .from("marketplace_sku_maps")
    .select("marketplace_sku_map_id, marketplace_account_id, warehouse_id, raw_product, last_error, status")
    .eq("marketplace_sku_map_id", log.marketplace_sku_map_id)
    .maybeSingle();

  if (error) throw new Error(`Load SKU mapping failed: ${error.message}`);
  return data;
}

async function resolveTikTokWarehouseId(admin: any, account: any, log: any, skuMap: any, variantSnapshot: any, args: {
  appKey: string;
  appSecret: string;
  accessToken: string;
  shopCipher: string;
  tokenSecret: string;
}): Promise<{ warehouseId: string | null; account: any; accessToken: string | null; source: string }> {
  let warehouseId =
    text(skuMap?.warehouse_id) ||
    text(log?.request_payload?.warehouse_id) ||
    text(account.default_warehouse_id) ||
    extractWarehouseId(variantSnapshot?.raw_variant) ||
    extractWarehouseId(skuMap?.raw_product) ||
    text(Deno.env.get("TIKTOK_DEFAULT_WAREHOUSE_ID"));

  if (warehouseId) {
    await cacheResolvedWarehouseId(admin, account, log, warehouseId);
    return { warehouseId, account, accessToken: args.accessToken, source: "cached" };
  }

  let accessToken = args.accessToken;
  try {
    const warehouse = await fetchTikTokDefaultWarehouse({
      appKey: args.appKey,
      appSecret: args.appSecret,
      accessToken,
      shopCipher: args.shopCipher,
      shopId: text(account.shop_id),
    });
    warehouseId = warehouse?.warehouse_id || null;
  } catch (err) {
    if (!isTikTokAuthError(err)) throw err;
    const refreshed = await ensureTikTokAccessToken(admin, account, args.tokenSecret, args.appKey, args.appSecret, true);
    account = refreshed.account;
    accessToken = refreshed.accessToken;
    const warehouse = await fetchTikTokDefaultWarehouse({
      appKey: args.appKey,
      appSecret: args.appSecret,
      accessToken,
      shopCipher: text(account.shop_cipher) || args.shopCipher,
      shopId: text(account.shop_id),
    });
    warehouseId = warehouse?.warehouse_id || null;
  }

  if (warehouseId) {
    await cacheResolvedWarehouseId(admin, account, log, warehouseId);
    return { warehouseId, account, accessToken, source: "tiktok.get_warehouse_list" };
  }

  return { warehouseId: null, account, accessToken, source: "not_found" };
}

async function fetchTikTokDefaultWarehouse(args: {
  appKey: string;
  appSecret: string;
  accessToken: string;
  shopCipher: string;
  shopId: string | null;
}): Promise<{ warehouse_id: string; raw: any } | null> {
  const query: Record<string, string> = { version: "202309" };
  if (args.shopId) query.shop_id = args.shopId;

  const jsonRes = await tiktokRequest({
    method: "GET",
    path: "/logistics/202309/warehouses",
    appKey: args.appKey,
    appSecret: args.appSecret,
    accessToken: args.accessToken,
    shopCipher: args.shopCipher,
    query,
  });

  const warehouse = pickWarehouse(collectWarehouses(jsonRes));
  const warehouseId = warehouseIdValue(warehouse);
  return warehouseId ? { warehouse_id: warehouseId, raw: warehouse } : null;
}

async function cacheResolvedWarehouseId(admin: any, account: any, log: any, warehouseId: string) {
  await admin
    .from("marketplace_accounts")
    .update({
      default_warehouse_id: warehouseId,
      last_error: null,
      updated_at: new Date().toISOString(),
    })
    .eq("marketplace_account_id", account.marketplace_account_id);

  if (text(log.marketplace_sku_map_id)) {
    await admin
      .from("marketplace_sku_maps")
      .update({
        warehouse_id: warehouseId,
        last_error: null,
        updated_at: new Date().toISOString(),
      })
      .eq("marketplace_sku_map_id", log.marketplace_sku_map_id);
  }
}

function collectWarehouses(jsonRes: any): any[] {
  const response = jsonRes?.response ?? jsonRes;
  const data = response?.data ?? response;
  const candidates = [
    data?.warehouses,
    data?.warehouse_list,
    data?.warehouseList,
    data?.warehouse,
    data?.data?.warehouses,
    data?.data?.warehouse_list,
    response?.warehouses,
    response?.warehouse_list,
  ];

  for (const item of candidates) {
    if (Array.isArray(item)) return item;
  }
  return [];
}

function pickWarehouse(warehouses: any[]): any | null {
  if (!warehouses.length) return null;
  return warehouses.find((item) => {
    const values = [item?.is_default, item?.default, item?.is_default_warehouse, item?.warehouse_type, item?.type, item?.name, item?.warehouse_name];
    return item?.is_default === true || values.some((value) => String(value ?? "").toLowerCase().includes("default"));
  }) || warehouses[0];
}

function warehouseIdValue(warehouse: any): string | null {
  return text(warehouse?.warehouse_id) || text(warehouse?.id) || text(warehouse?.warehouseId) || text(warehouse?.warehouse?.warehouse_id);
}

function buildOutboundPayload(account: any, log: any, skuMap: any, variantSnapshot: any, stock: number, dryRun: boolean) {
  if (log.marketplace === "tiktok_shop") {
    const shopCipher = text(account.shop_cipher);
    return {
      dry_run: dryRun,
      platform: "tiktok_shop",
      endpoint: `/product/202309/products/${log.marketplace_product_id}/inventory/update`,
      shop_cipher_masked: shopCipher ? mask(shopCipher) : null,
      warehouse_id: text(skuMap?.warehouse_id) || text(log?.request_payload?.warehouse_id) || text(account.default_warehouse_id) || extractWarehouseId(variantSnapshot?.raw_variant) || text(Deno.env.get("TIKTOK_DEFAULT_WAREHOUSE_ID")),
      product_id: log.marketplace_product_id,
      sku_id: log.marketplace_sku_id,
      quantity: stock,
    };
  }

  if (log.marketplace === "shopee") {
    return {
      dry_run: dryRun,
      platform: "shopee",
      endpoint: "/api/v2/product/update_stock",
      shop_id: account.shop_id || null,
      item_id: log.marketplace_product_id,
      model_id: log.marketplace_sku_id,
      normal_stock: stock,
    };
  }

  return {
    dry_run: dryRun,
    platform: log.marketplace,
    product_id: log.marketplace_product_id,
    sku_id: log.marketplace_sku_id,
    stock,
  };
}

class TikTokApiError extends Error {
  httpStatus: number;
  code: string | null;
  payload: any;

  constructor(message: string, httpStatus: number, code: string | null, payload: any) {
    super(message);
    this.name = "TikTokApiError";
    this.httpStatus = httpStatus;
    this.code = code;
    this.payload = payload;
  }
}

function isTikTokAuthError(err: unknown): boolean {
  const e = err as any;
  const code = String(e?.code ?? e?.payload?.code ?? "");
  const message = String(e?.message ?? e?.payload?.message ?? e?.payload?.msg ?? "").toLowerCase();
  return e instanceof TikTokApiError && (e.httpStatus === 401 || code === "105001" || message.includes("access token"));
}

async function tiktokRequest(args: {
  method: "GET" | "POST";
  path: string;
  appKey: string;
  appSecret: string;
  accessToken: string;
  shopCipher?: string;
  query?: Record<string, string | number | boolean | null | undefined>;
  body?: Record<string, unknown>;
}) {
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const params: Record<string, string> = {
    app_key: args.appKey,
    timestamp,
  };

  if (args.shopCipher) params.shop_cipher = args.shopCipher;

  for (const [key, value] of Object.entries(args.query || {})) {
    if (value === null || value === undefined || value === "") continue;
    params[key] = String(value);
  }

  const bodyString = args.method === "POST" ? JSON.stringify(args.body || {}) : "";
  params.sign = await signTikTokRequest(args.path, params, bodyString, args.appSecret);

  const url = new URL(`https://open-api.tiktokglobalshop.com${args.path}`);
  for (const [key, value] of Object.entries(params)) url.searchParams.set(key, value);

  const res = await fetch(url.toString(), {
    method: args.method,
    headers: {
      accept: "application/json",
      "content-type": "application/json",
      "x-tts-access-token": args.accessToken,
    },
    body: args.method === "POST" ? bodyString : undefined,
  });

  const jsonRes = await res.json().catch(() => null);
  const code = jsonRes?.code !== undefined && jsonRes?.code !== null ? String(jsonRes.code) : null;

  if (!res.ok || !jsonRes) {
    throw new TikTokApiError(`TikTok API HTTP ${res.status}: ${JSON.stringify(jsonRes)}`, res.status, code, jsonRes);
  }

  if (code !== null && code !== "0" && code.toLowerCase() !== "success") {
    throw new TikTokApiError(`TikTok API error: ${JSON.stringify(jsonRes)}`, res.status, code, jsonRes);
  }

  return jsonRes;
}

async function signTikTokRequest(path: string, params: Record<string, string>, bodyString: string, secret: string): Promise<string> {
  const sortedKeys = Object.keys(params)
    .filter((key) => key !== "sign" && key !== "access_token")
    .sort();

  let base = path;
  for (const key of sortedKeys) base += `${key}${params[key]}`;
  if (bodyString) base += bodyString;

  const signString = `${secret}${base}${secret}`;
  return hmacHex(secret, signString);
}

async function finishLog(admin: any, log: any, args: {
  status: string;
  error?: string | null;
  message: string;
  requestPayload?: Record<string, unknown>;
  responsePayload?: Record<string, unknown>;
  isDryRun?: boolean;
}) {
  const patch: Record<string, unknown> = {
    sync_status: args.status,
    is_dry_run: args.isDryRun ?? (args.status === "dry_run_success"),
    error_message: args.error ?? null,
    worker_message: args.message,
    finished_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };

  if (args.requestPayload !== undefined) patch.request_payload = args.requestPayload;
  if (args.responsePayload !== undefined) patch.response_payload = args.responsePayload;

  const { error } = await admin
    .from("marketplace_stock_sync_logs")
    .update(patch)
    .eq("marketplace_stock_sync_log_id", log.marketplace_stock_sync_log_id);

  if (error) throw new Error(`Update log failed: ${error.message}`);
}

function extractWarehouseId(rawVariant: any): string | null {
  const sku = rawVariant?.sku || rawVariant || {};
  const direct = text(sku.warehouse_id) || text(sku.default_warehouse_id) || text(sku.inventory?.warehouse_id);
  if (direct) return direct;

  const arrays = [sku.inventory, sku.inventories, sku.stock_infos, sku.warehouse_stock, sku.stock_info];
  for (const arr of arrays) {
    if (!Array.isArray(arr)) continue;
    for (const item of arr) {
      const id = text(item?.warehouse_id) || text(item?.id);
      if (id) return id;
    }
  }

  return null;
}

async function ensureTikTokAccessToken(
  admin: any,
  account: any,
  tokenSecret: string,
  appKey: string,
  appSecret: string,
  forceRefresh: boolean,
): Promise<{ account: any; accessToken: string }> {
  const accessToken = await decryptText(text(account.access_token_encrypted), tokenSecret);
  const expiredAtMs = account.access_token_expired_at ? new Date(account.access_token_expired_at).getTime() : 0;
  const safeUntilMs = Date.now() + 10 * 60 * 1000;

  if (!forceRefresh && accessToken && expiredAtMs > safeUntilMs) {
    return { account, accessToken };
  }

  const refreshToken = await decryptText(text(account.refresh_token_encrypted), tokenSecret);
  if (!refreshToken) {
    await markMarketplaceAuthError(admin, account, "TikTok refresh token kosong. Reconnect TikTok Shop diperlukan.");
    throw new Error("TikTok refresh token kosong. Reconnect TikTok Shop diperlukan.");
  }

  const refreshUrl = new URL("https://auth.tiktok-shops.com/api/v2/token/refresh");
  refreshUrl.searchParams.set("app_key", appKey);
  refreshUrl.searchParams.set("app_secret", appSecret);
  refreshUrl.searchParams.set("refresh_token", refreshToken);
  refreshUrl.searchParams.set("grant_type", "refresh_token");

  const res = await fetch(refreshUrl.toString(), {
    method: "GET",
    headers: { accept: "application/json" },
  });
  const payload = await res.json().catch(() => null);
  const data = payload?.data ?? payload ?? {};
  const code = payload?.code !== undefined && payload?.code !== null ? String(payload.code) : null;

  if (!res.ok || (code !== null && code !== "0" && code.toLowerCase() !== "success")) {
    const message = `Refresh token TikTok gagal. Reconnect TikTok Shop diperlukan. HTTP ${res.status}: ${JSON.stringify(payload)}`;
    await markMarketplaceAuthError(admin, account, message);
    throw new Error(message);
  }

  const newAccessToken = text(data.access_token);
  const newRefreshToken = text(data.refresh_token) || refreshToken;
  if (!newAccessToken) {
    const message = `Refresh token TikTok gagal: response tidak berisi access_token. ${JSON.stringify(payload)}`;
    await markMarketplaceAuthError(admin, account, message);
    throw new Error(message);
  }

  const accessExpiredAt = expireValueToIso(data.access_token_expire_in)
    || expireValueToIso(data.access_token_expired_at)
    || expireValueToIso(data.expire_in)
    || new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString();
  const refreshExpiredAt = expireValueToIso(data.refresh_token_expire_in)
    || expireValueToIso(data.refresh_token_expired_at)
    || account.refresh_token_expired_at
    || null;

  const updatePayload: Record<string, unknown> = {
    access_token_encrypted: await encryptText(newAccessToken, tokenSecret),
    refresh_token_encrypted: await encryptText(newRefreshToken, tokenSecret),
    access_token_expired_at: accessExpiredAt,
    refresh_token_expired_at: refreshExpiredAt,
    status: "active",
    last_error: null,
    updated_at: new Date().toISOString(),
  };

  const { data: updated, error } = await admin
    .from("marketplace_accounts")
    .update(updatePayload)
    .eq("marketplace_account_id", account.marketplace_account_id)
    .select("marketplace_account_id, tenant_id, marketplace, app_key, shop_id, shop_cipher, shop_region, shop_name, status, stock_sync_enabled, default_warehouse_id, access_token_encrypted, refresh_token_encrypted, access_token_expired_at, refresh_token_expired_at, environment")
    .single();

  if (error) throw new Error(`Update TikTok refreshed token failed: ${error.message}`);
  return { account: updated || { ...account, ...updatePayload }, accessToken: newAccessToken };
}

async function markMarketplaceAuthError(admin: any, account: any, message: string) {
  await admin
    .from("marketplace_accounts")
    .update({
      status: "error",
      last_error: message,
      updated_at: new Date().toISOString(),
    })
    .eq("marketplace_account_id", account.marketplace_account_id);
}

function expireValueToIso(value: unknown): string | null {
  if (value === null || value === undefined || value === "") return null;
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return null;
  const seconds = n > 1000000000 ? n : Math.floor(Date.now() / 1000) + n;
  return new Date(seconds * 1000).toISOString();
}

async function encryptText(plainText: string, secret: string): Promise<string> {
  const encoder = new TextEncoder();
  const keyMaterial = await crypto.subtle.digest("SHA-256", encoder.encode(secret));
  const key = await crypto.subtle.importKey("raw", keyMaterial, "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, encoder.encode(plainText));
  return `aesgcm:${toBase64(iv)}:${toBase64(new Uint8Array(encrypted))}`;
}

async function decryptText(encryptedText: string, secret: string): Promise<string> {
  if (!encryptedText) return "";

  const encoder = new TextEncoder();
  const keyMaterial = await crypto.subtle.digest("SHA-256", encoder.encode(secret));
  const key = await crypto.subtle.importKey("raw", keyMaterial, "AES-GCM", false, ["decrypt"]);

  if (encryptedText.startsWith("aesgcm:")) {
    const [, ivBase64, dataBase64] = encryptedText.split(":");
    if (!ivBase64 || !dataBase64) throw new Error("Format token marketplace tidak lengkap. Reconnect TikTok Shop diperlukan.");
    const decrypted = await crypto.subtle.decrypt({ name: "AES-GCM", iv: fromBase64(ivBase64) }, key, fromBase64(dataBase64));
    return new TextDecoder().decode(decrypted);
  }

  if (encryptedText.includes(".")) {
    const [ivBase64Url, dataBase64Url] = encryptedText.split(".");
    if (!ivBase64Url || !dataBase64Url) throw new Error("Format token marketplace tidak valid. Reconnect TikTok Shop diperlukan.");
    const decrypted = await crypto.subtle.decrypt({ name: "AES-GCM", iv: base64UrlToBytes(ivBase64Url) }, key, base64UrlToBytes(dataBase64Url));
    return new TextDecoder().decode(decrypted);
  }

  // Compatibility for old development rows that may have stored plaintext tokens.
  return encryptedText;
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function fromBase64(input: string): Uint8Array {
  const binary = atob(input);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function base64UrlToBytes(value: string): Uint8Array {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
  return fromBase64(padded);
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
  return [...new Uint8Array(signature)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function sanitizeResponse(input: any) {
  return JSON.parse(JSON.stringify(input || {}));
}

function toShopeeNumber(value: string | null, fieldName: string): number {
  if (!value) throw new Error(`${fieldName} kosong.`);
  const clean = value.trim();
  if (!/^\d+$/.test(clean)) throw new Error(`${fieldName} harus numeric. Value sekarang: ${clean}`);
  const num = Number(clean);
  if (!Number.isFinite(num)) throw new Error(`${fieldName} tidak valid: ${clean}`);
  return num;
}

async function safeJson(req: Request) {
  try {
    return await req.json();
  } catch (_) {
    return {};
  }
}

function json(payload: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(payload, null, 2), {
    status,
    headers: {
      ...corsHeaders,
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value || !value.trim()) throw new Error(`Missing env: ${name}`);
  return value.trim();
}

function envFlag(name: string, fallback: boolean): boolean {
  const value = Deno.env.get(name);
  if (value === undefined || value === null || value.trim() === "") return fallback;
  return ["1", "true", "yes", "on"].includes(value.trim().toLowerCase());
}

function clampInt(value: unknown, min: number, max: number, fallback: number) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.floor(n)));
}

function text(value: unknown): string {
  if (value === null || value === undefined) return "";
  const clean = String(value).trim();
  if (!clean || clean === "null" || clean === "undefined") return "";
  return clean;
}

function mask(value: string) {
  if (!value) return "";
  if (value.length <= 10) return "***";
  return `${value.slice(0, 5)}...${value.slice(-5)}`;
}
