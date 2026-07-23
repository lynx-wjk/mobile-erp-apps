import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const FUNCTION_VERSION = "marketplace-product-pull-cursor-v36-2026-06-18";

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  let tenantId = "unknown";
  let marketplaceAccountId = "unknown";
  let account: any = null;
  let body: any = {};

  try {
    if (req.method !== "POST") {
      return json({ ok: false, message: "Method not allowed" }, 405);
    }

    const supabaseUrl = requiredEnv("SUPABASE_URL");
    const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");
    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    body = await safeJson(req);
    const configuredCronSecret = envCronSecret();
    const incomingCronSecret = requestCronSecret(req, body);
    const isCronRequest = await verifyMarketplaceCronSecret(admin, incomingCronSecret)
      || (configuredCronSecret.length > 0 && incomingCronSecret === configuredCronSecret);

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
      if (userError || !userData?.user) {
        return json({ ok: false, message: "Invalid user session" }, 401);
      }

      const { data: loadedProfile, error: profileError } = await admin
        .from("users")
        .select("user_id, tenant_id, role_id, status")
        .eq("user_id", userData.user.id)
        .maybeSingle();

      if (profileError || !loadedProfile) {
        return json({ ok: false, message: profileError?.message || "User profile not found" }, 403);
      }

      if (loadedProfile.status !== "active") {
        return json({ ok: false, message: "User is not active" }, 403);
      }
      profile = loadedProfile;
    }

    tenantId = String(body.tenant_id || profile.tenant_id || "").trim();
    marketplaceAccountId = String(body.marketplace_account_id || "").trim();
    const limit = clampInt(body.limit ?? body.page_size, 1, 100, 10);
    const cursor = body.cursor && typeof body.cursor === "object" && !Array.isArray(body.cursor)
      ? body.cursor
      : {};
    const clearCache = body.clear_cache === true;
    const maxProductsPerRun = clampInt(body.max_products_per_run ?? limit, 1, 20, Math.min(limit, 5));

    if (!tenantId) return json({ ok: false, message: "tenant_id is required" }, 400);
    if (!marketplaceAccountId) return json({ ok: false, message: "marketplace_account_id is required" }, 400);

    const roleId = String(profile.role_id || "").trim();
    const isSuperAdmin = roleId === "super_admin";
    const isDemoSuperAdmin = roleId === "demo_super_admin";

    if (!isSuperAdmin && !isDemoSuperAdmin && tenantId !== profile.tenant_id) {
      return json({ ok: false, message: "Forbidden tenant access" }, 403);
    }

    if (isDemoSuperAdmin) {
      return json({ ok: false, message: "Demo account tidak boleh pull API marketplace production." }, 403);
    }

    const { data: loadedAccount, error: accountError } = await admin
      .from("marketplace_accounts")
      .select("marketplace_account_id, tenant_id, marketplace, app_key, shop_id, shop_cipher, shop_region, shop_name, store_alias, status, environment, default_warehouse_id, access_token_encrypted, refresh_token_encrypted, access_token_expired_at, refresh_token_expired_at, raw_shop_response")
      .eq("marketplace_account_id", marketplaceAccountId)
      .maybeSingle();

    if (accountError || !loadedAccount) {
      return json({ ok: false, message: accountError?.message || "Marketplace account not found" }, 404);
    }
    account = loadedAccount;

    if (account.tenant_id !== tenantId) {
      return json({ ok: false, message: "Marketplace account tenant mismatch" }, 403);
    }

    if (account.status !== "active") {
      return json({ ok: false, message: "Marketplace account belum active." }, 400);
    }

    if (account.marketplace === "tiktok_shop") {
      const result = await pullTiktokProducts(admin, account, { limit, cursor, clearCache, maxProductsPerRun });
      return json(result);
    }

    if (account.marketplace === "shopee") {
      const result = await pullShopeeProducts(admin, account, { limit, cursor, clearCache, maxProductsPerRun });
      return json(result);
    }

    return json({ ok: false, message: `Marketplace ${account.marketplace} belum dig.` }, 400);
  } catch (err) {
    const message = String(err.message || err);
    console.error("Product pull error caught:", message);

    let errorCode = "UNKNOWN_ERROR";
    let httpStatus = 500;

    if (message.includes("is not configured") || message.includes("Missing env") || message.includes("kosong")) {
      errorCode = "MISSING_CONFIGURATION";
      httpStatus = 400;
    } else if (message.includes("belum dig") || message.includes("not supported")) {
      errorCode = "UNSUPPORTED_MARKETPLACE";
      httpStatus = 400;
    } else if (message.includes("decrypt") || message.includes("terenkripsi") || message.includes("decryption")) {
      errorCode = "DECRYPTION_ERROR";
      httpStatus = 400;
    } else if (message.includes("expired") || message.includes("token") || message.includes("re-authorize") || message.includes("reauth")) {
      errorCode = "AUTH_ERROR";
      httpStatus = 400;
    }

    return json({
      ok: false,
      error_code: errorCode,
      message: message,
      marketplace: account?.marketplace || body?.marketplace || "unknown",
      marketplace_account_id: marketplaceAccountId || null,
      tenant_id: tenantId || null,
      api_status: null,
      api_code: null
    }, httpStatus);
  }
});

async function pullTiktokProducts(admin: any, account: any, options: { limit: number; cursor: any; clearCache: boolean; maxProductsPerRun: number }) {
  const limit = options.limit;
  const cursor = options.cursor || {};
  const clearCache = options.clearCache === true;
  const maxProductsPerRun = Math.max(1, Math.min(options.maxProductsPerRun || limit, limit));

  const tokenBundle = await refreshTikTokAccessTokenIfNeeded(admin, account);
  account = tokenBundle.account;
  const appKey = Deno.env.get("TIKTOK_APP_KEY")?.trim() || account.app_key;
  const appSecret = requiredEnv("TIKTOK_APP_SECRET");
  const accessToken = tokenBundle.accessToken;

  let shopCipher = detectShopCipher(account);
  let shopId = text(account.shop_id);

  if (!appKey) throw new Error("TIKTOK_APP_KEY kosong.");
  if (!accessToken) throw new Error("Access token TikTok kosong. Re-authorize toko dulu.");

  const authorizedShopsJson = await tiktokRequest({
    method: "GET",
    path: "/authorization/202309/shops",
    appKey,
    appSecret,
    accessToken,
    body: {},
  });

  const authorizedShops = collectAuthorizedShops(authorizedShopsJson);
  const authorizedShop = pickAuthorizedShop(authorizedShopsJson, account, shopCipher);

  if (authorizedShop) {
    shopCipher = shopCipherValue(authorizedShop) || shopCipher;
    shopId = shopIdValue(authorizedShop) || shopId;

    await admin
      .from("marketplace_accounts")
      .update({
        shop_id: shopId,
        shop_cipher: shopCipher,
        shop_name: shopNameValue(authorizedShop) || account.shop_name,
        raw_shop_response: safeJsonForDb(authorizedShopsJson),
        last_error: null,
        updated_at: new Date().toISOString(),
      })
      .eq("marketplace_account_id", account.marketplace_account_id);
  } else {
    await admin
      .from("marketplace_accounts")
      .update({
        raw_shop_response: safeJsonForDb(authorizedShopsJson),
        last_error: "Authorized Shops tidak mengembalikan shop list. Cek scope Shop Authorized Information.",
        updated_at: new Date().toISOString(),
      })
      .eq("marketplace_account_id", account.marketplace_account_id);
  }

  if (!shopCipher) {
    throw new Error("shop_cipher TikTok belum valid. Aktifkan scope Shop Authorized Information, re-authorize toko, lalu Pull Produk & Varian lagi.");
  }

  const warehouseResult = await resolveAndCacheTikTokWarehouseId(admin, account, {
    appKey,
    appSecret,
    accessToken,
    shopCipher,
    shopId,
  });
  const resolvedWarehouseId = warehouseResult.warehouse_id;

  const baseQuery: Record<string, string> = {
    page_size: String(Math.max(1, Math.min(limit, maxProductsPerRun))),
    version: "202309",
  };
  if (shopId) baseQuery.shop_id = shopId;
  const tiktokPageToken = text(cursor.page_token) || text(cursor.pageToken) || text(cursor.next_page_token);
  if (tiktokPageToken) baseQuery.page_token = tiktokPageToken;

  let searchJson: any = null;
  let firstError: unknown = null;

  try {
    searchJson = await tiktokRequest({
      method: "POST",
      path: "/product/202309/products/search",
      appKey,
      appSecret,
      accessToken,
      shopCipher,
      query: baseQuery,
      body: activeProductSearchBody(),
    });
  } catch (e) {
    firstError = e;
  }

  if (!searchJson) {
    try {
      searchJson = await tiktokRequest({
        method: "POST",
        path: "/product/202309/products/search",
        appKey,
        appSecret,
        accessToken,
        shopCipher,
        query: {
          page_size: String(Math.max(1, Math.min(limit, maxProductsPerRun))),
        },
        body: {},
      });
    } catch (secondError) {
      const debug = {
        account_shop_id: maskText(shopId),
        account_shop_cipher: maskText(shopCipher),
        authorized_shop_count: authorizedShops.length,
        authorized_shops: authorizedShops.slice(0, 5).map((shop) => ({
          shop_id: maskText(shopIdValue(shop)),
          shop_cipher: maskText(shopCipherValue(shop)),
          shop_name: shopNameValue(shop),
          region: text(shop.region) || text(shop.shop_region) || text(shop.country),
        })),
        first_error: String(firstError),
        second_error: String(secondError),
      };

      await admin
        .from("marketplace_accounts")
        .update({
          last_error: `TikTok product pull gagal. Debug: ${JSON.stringify(debug)}`.slice(0, 1800),
          updated_at: new Date().toISOString(),
        })
        .eq("marketplace_account_id", account.marketplace_account_id);

      throw new Error(
        `TikTok Product Pull gagal setelah retry. ${String(secondError)}. Debug: ${JSON.stringify(debug)}`,
      );
    }
  }

  const pulledProducts = collectProducts(searchJson);
  const productList = pulledProducts.filter(isActiveMarketplaceProductRecord).slice(0, maxProductsPerRun);
  let productCount = 0;
  let variantCount = 0;
  let skippedInactiveProducts = Math.max(0, pulledProducts.length - productList.length);
  let skippedInactiveVariants = 0;
  const errors: string[] = [];

  if (clearCache && pulledProducts.length > 0) {
    await clearProductSnapshotCache(admin, account);
  }

  for (const productLite of productList) {
    const productId = text(productLite.id) || text(productLite.product_id) || text(productLite.productId);
    if (!productId) continue;

    let detailJson: any = null;
    try {
      detailJson = await fetchTikTokProductDetail({
        productId,
        appKey,
        appSecret,
        accessToken,
        shopCipher,
        shopId,
      });
    } catch (e) {
      errors.push(`Get product ${productId} gagal: ${String(e)}`);
    }

    const product = normalizeProduct(detailJson, productLite, productId);
    if (!isActiveMarketplaceProductRecord(product.raw)) {
      skippedInactiveProducts += 1;
      continue;
    }

    await upsertProductSnapshot(admin, account, product);
    productCount += 1;

    const variants = normalizeVariants(product.raw, product);
    const activeVariants = variants.filter(isActiveMarketplaceVariantRecord);
    skippedInactiveVariants += Math.max(0, variants.length - activeVariants.length);

    if (variants.length > 0 && activeVariants.length === 0) {
      continue;
    }

    if (variants.length === 0) {
      const fallbackVariant = {
        marketplace_product_id: product.marketplace_product_id,
        marketplace_sku_id: product.marketplace_product_id,
        marketplace_sku_code: null,
        marketplace_seller_sku: null,
        marketplace_product_name: product.product_name,
        marketplace_variant_name: "Default variant",
        product_status: product.product_status,
        sku_status: null,
        price_amount: null,
        price_currency: null,
        stock_quantity: null,
        raw_variant: product.raw,
      };
      await upsertVariantSnapshot(admin, account, fallbackVariant);
      variantCount += 1;
      continue;
    }

    for (const variant of activeVariants) {
      await upsertVariantSnapshot(admin, account, variant);
      variantCount += 1;
    }
  }

  await admin
    .from("marketplace_accounts")
    .update({
      default_warehouse_id: resolvedWarehouseId || account.default_warehouse_id || null,
      last_error: errors.length > 0 ? errors.slice(0, 3).join(" | ") : null,
      updated_at: new Date().toISOString(),
    })
    .eq("marketplace_account_id", account.marketplace_account_id);

  if (resolvedWarehouseId) {
    await cacheWarehouseIdForMappedVariants(admin, account, resolvedWarehouseId);
  }

  const nextPageToken = tiktokNextPageToken(searchJson);
  const hasMore = Boolean(nextPageToken);
  const nextCursor = nextPageToken ? { page_token: nextPageToken } : null;

  return {
    ok: true,
    marketplace: "tiktok_shop",
    has_more: hasMore,
    next_cursor: nextCursor,
    products: productCount,
    variants: variantCount,
    skipped_inactive_products: skippedInactiveProducts,
    skipped_inactive_variants: skippedInactiveVariants,
    warning_count: errors.length,
    warnings: errors.slice(0, 5),
    default_warehouse_id: resolvedWarehouseId || null,
    warehouse_source: warehouseResult.source,
    message: errors.length > 0
      ? `Pull selesai dengan ${errors.length} warning. Produk nonaktif dilewati: ${skippedInactiveProducts}. Varian nonaktif dilewati: ${skippedInactiveVariants}.`
      : `Pull produk TikTok aktif selesai. Produk nonaktif dilewati: ${skippedInactiveProducts}. Varian nonaktif dilewati: ${skippedInactiveVariants}.`,
  };
}

async function pullShopeeProducts(admin: any, account: any, options: { limit: number; cursor: any; clearCache: boolean; maxProductsPerRun: number }) {
  const { account: activeAccount, accessToken } = await refreshShopeeAccessTokenIfNeeded(admin, account);
  const limit = options.limit;
  const cursor = options.cursor || {};
  const clearCache = options.clearCache === true;
  const maxProductsPerRun = Math.max(1, Math.min(options.maxProductsPerRun || limit, limit));
  const pageSize = Math.min(50, Math.max(1, Math.min(limit, maxProductsPerRun)));
  const itemIds: string[] = [];
  const errors: string[] = [];
  const rawOffset = Number(cursor.offset ?? cursor.next_offset ?? 0);
  const offset = Number.isFinite(rawOffset) && rawOffset > 0 ? Math.floor(rawOffset) : 0;
  let nextOffset = offset;
  let hasMore = false;

  try {
    const listJson = await shopeeRequest({
      method: "GET",
      account: activeAccount,
      accessToken,
      path: "/api/v2/product/get_item_list",
      query: { offset, page_size: pageSize, item_status: "NORMAL" },
    });
    const list = collectShopeeItemList(listJson);
    if (list.length === 0) {
      const listData = (listJson?.response ?? listJson?.data ?? listJson) || {};
      errors.push(`Shopee item list kosong. response_keys=${Object.keys(listData).slice(0, 12).join(",")}; total_count=${text(listData.total_count)}; has_next_page=${text(listData.has_next_page)}`);
    }
    for (const item of list) {
      const id = text(item.item_id) || text(item.id);
      if (id && !itemIds.includes(id)) itemIds.push(id);
      if (itemIds.length >= maxProductsPerRun) break;
    }
    const responseData = listJson?.response ?? listJson?.data ?? listJson ?? {};
    const parsedNextOffset = Number(responseData.next_offset ?? offset + list.length);
    nextOffset = Number.isFinite(parsedNextOffset) && parsedNextOffset > offset ? parsedNextOffset : offset + list.length;
    hasMore = responseData.has_next_page === true && nextOffset > offset;
  } catch (err) {
    errors.push(`Get Shopee item list gagal: ${String(err)}`);
  }

  if (clearCache && itemIds.length > 0) {
    await clearProductSnapshotCache(admin, activeAccount);
  }

  let productCount = 0;
  let variantCount = 0;
  let skippedInactiveProducts = 0;
  let skippedInactiveVariants = 0;

  for (const itemId of itemIds) {
    let detail: any = null;
    try { detail = await fetchShopeeItemBaseInfo({ account: activeAccount, accessToken, itemId }); }
    catch (err) { errors.push(`Get Shopee item ${itemId} gagal: ${String(err)}`); }

    const product = normalizeProduct(detail, { item_id: itemId }, itemId);
    if (!isActiveMarketplaceProductRecord(product.raw)) { skippedInactiveProducts += 1; continue; }
    await upsertProductSnapshot(admin, activeAccount, product);
    productCount += 1;

    let modelJson: any = null;
    try { modelJson = await fetchShopeeModelList({ account: activeAccount, accessToken, itemId }); }
    catch (err) { errors.push(`Get Shopee model ${itemId} gagal: ${String(err)}`); }

    const variants = normalizeShopeeVariants(modelJson, product);
    const activeVariants = variants.filter(isActiveMarketplaceVariantRecord);
    skippedInactiveVariants += Math.max(0, variants.length - activeVariants.length);
    if (variants.length > 0 && activeVariants.length === 0) continue;

    if (variants.length === 0) {
      await upsertVariantSnapshot(admin, activeAccount, {
        marketplace_product_id: product.marketplace_product_id,
        marketplace_sku_id: product.marketplace_product_id,
        marketplace_sku_code: null,
        marketplace_seller_sku: null,
        marketplace_product_name: product.product_name,
        marketplace_variant_name: "Default variant",
        product_status: product.product_status,
        sku_status: null,
        price_amount: null,
        price_currency: null,
        stock_quantity: null,
        raw_variant: product.raw,
      });
      variantCount += 1;
      continue;
    }
    for (const variant of activeVariants) { await upsertVariantSnapshot(admin, activeAccount, variant); variantCount += 1; }
  }

  await admin.from("marketplace_accounts").update({
    last_error: errors.length > 0 ? errors.slice(0, 3).join(" | ") : null,
    updated_at: new Date().toISOString(),
  }).eq("marketplace_account_id", activeAccount.marketplace_account_id);

  return {
    ok: true,
    marketplace: "shopee",
    products: productCount,
    variants: variantCount,
    skipped_inactive_products: skippedInactiveProducts,
    skipped_inactive_variants: skippedInactiveVariants,
    warning_count: errors.length,
    warnings: errors.slice(0, 5),
    has_more: hasMore,
    next_cursor: hasMore ? { offset: nextOffset } : null,
    message: errors.length > 0 ? `Pull produk Shopee selesai dengan ${errors.length} warning.` : `Pull produk Shopee aktif selesai. Offset berikutnya: ${hasMore ? nextOffset : "selesai"}.`,
  };
}



function tiktokNextPageToken(jsonRes: any): string | null {
  const response = jsonRes?.response ?? jsonRes;
  const data = response?.data ?? response;
  return text(data?.next_page_token)
    || text(data?.nextPageToken)
    || text(response?.next_page_token)
    || text(response?.nextPageToken)
    || text(jsonRes?.next_page_token)
    || text(jsonRes?.nextPageToken);
}


async function resolveAndCacheTikTokWarehouseId(admin: any, account: any, args: {
  appKey: string;
  appSecret: string;
  accessToken: string;
  shopCipher: string;
  shopId: string | null;
}): Promise<{ warehouse_id: string | null; source: string }> {
  const existing = text(account.default_warehouse_id);
  if (existing) return { warehouse_id: existing, source: "account.default_warehouse_id" };

  const fromEnv = text(Deno.env.get("TIKTOK_DEFAULT_WAREHOUSE_ID"));
  let fromApi: string | null = null;
  let source = "not_found";

  try {
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
    fromApi = warehouseIdValue(warehouse);
    if (fromApi) source = "tiktok.get_warehouse_list";

    await admin
      .from("marketplace_accounts")
      .update({
        default_warehouse_id: fromApi || fromEnv || null,
        raw_shop_response: mergeRawShopResponse(account.raw_shop_response, { warehouse_list_response: safeJsonForDb(jsonRes) }),
        last_checked_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
      .eq("marketplace_account_id", account.marketplace_account_id);
  } catch (err) {
    if (fromEnv) {
      await admin
        .from("marketplace_accounts")
        .update({
          default_warehouse_id: fromEnv,
          last_error: null,
          updated_at: new Date().toISOString(),
        })
        .eq("marketplace_account_id", account.marketplace_account_id);
      return { warehouse_id: fromEnv, source: "env.TIKTOK_DEFAULT_WAREHOUSE_ID" };
    }

    await admin
      .from("marketplace_accounts")
      .update({
        last_error: `Warehouse TikTok belum terbaca: ${String(err)}`.slice(0, 1800),
        updated_at: new Date().toISOString(),
      })
      .eq("marketplace_account_id", account.marketplace_account_id);
  }

  const resolved = fromApi || fromEnv || null;
  if (resolved && resolved === fromEnv && source === "not_found") source = "env.TIKTOK_DEFAULT_WAREHOUSE_ID";
  return { warehouse_id: resolved, source };
}

async function cacheWarehouseIdForMappedVariants(admin: any, account: any, warehouseId: string) {
  await admin
    .from("marketplace_sku_maps")
    .update({
      warehouse_id: warehouseId,
      last_error: null,
      updated_at: new Date().toISOString(),
    })
    .eq("tenant_id", account.tenant_id)
    .eq("marketplace_account_id", account.marketplace_account_id)
    .eq("marketplace", "tiktok_shop")
    .is("warehouse_id", null);
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
    return values.some((value) => String(value ?? "").toLowerCase().includes("default")) || item?.is_default === true;
  }) || warehouses[0];
}

function warehouseIdValue(warehouse: any): string | null {
  return text(warehouse?.warehouse_id) || text(warehouse?.id) || text(warehouse?.warehouseId) || text(warehouse?.warehouse?.warehouse_id);
}

function mergeRawShopResponse(current: any, patch: Record<string, unknown>): any {
  const base = current && typeof current === "object" && !Array.isArray(current) ? current : {};
  return safeJsonForDb({ ...base, ...patch });
}

function activeProductSearchBody(): Record<string, unknown> {
  return {
    status: "ACTIVATE",
  };
}

function isActiveMarketplaceProductRecord(product: any): boolean {
  return isActiveMarketplaceRecord([
    product?.status,
    product?.product_status,
    product?.productStatus,
    product?.sale_status,
    product?.listing_status,
    product?.audit_status,
    product?.product?.status,
    product?.product_info?.status,
  ]);
}

function isActiveMarketplaceVariantRecord(variant: any): boolean {
  const raw = variant?.raw_variant?.sku ?? variant?.raw_variant ?? variant;
  return isActiveMarketplaceRecord([
    variant?.product_status,
    variant?.sku_status,
    raw?.status,
    raw?.sku_status,
    raw?.seller_sku_status,
    raw?.sale_status,
    raw?.listing_status,
  ]);
}

function isActiveMarketplaceRecord(statusValues: unknown[]): boolean {
  for (const value of statusValues) {
    const status = normalizeStatus(value);
    if (!status) continue;
    if (isInactiveStatus(status)) return false;
  }
  return true;
}

function isInactiveStatus(status: string): boolean {
  return [
    "delete",
    "deleted",
    "archive",
    "archived",
    "deactivate",
    "deactivated",
    "inactive",
    "disable",
    "disabled",
    "suspend",
    "suspended",
    "draft",
    "rejected",
    "banned",
    "freeze",
    "frozen",
    "unpublish",
    "unpublished",
    "offline",
    "closed",
    "blocked",
  ].some((needle) => status.includes(needle));
}

function normalizeStatus(value: unknown): string {
  if (value === null || value === undefined) return "";
  return String(value)
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_");
}


async function fetchTikTokProductDetail(args: {
  productId: string;
  appKey: string;
  appSecret: string;
  accessToken: string;
  shopCipher: string;
  shopId: string | null;
}) {
  const path = `/product/202309/products/${encodeURIComponent(args.productId)}`;
  const attempts: Array<Record<string, string>> = [];

  if (args.shopId) {
    attempts.push({ shop_id: args.shopId, version: "202309" });
  }

  attempts.push({ version: "202309" });
  attempts.push({});

  let lastError: unknown = null;

  for (const query of attempts) {
    try {
      return await tiktokRequest({
        method: "GET",
        path,
        appKey: args.appKey,
        appSecret: args.appSecret,
        accessToken: args.accessToken,
        shopCipher: args.shopCipher,
        query,
      });
    } catch (e) {
      lastError = e;
    }
  }

  throw lastError;
}


function detectShopCipher(account: any): string | null {
  const direct = text(account.shop_cipher);
  if (direct) return direct;

  const raw = account.raw_shop_response;
  const data = raw?.response?.data ?? raw?.data ?? raw;
  const arrays = [data?.shops, data?.shop_list, data?.authorized_shops, data?.shops_list];
  for (const arr of arrays) {
    if (Array.isArray(arr) && arr.length > 0) {
      const cipher = shopCipherValue(arr[0]);
      if (cipher) return cipher;
    }
  }

  return null;
}

function shopCipherValue(shop: any): string | null {
  return text(shop?.shop_cipher)
    || text(shop?.cipher)
    || text(shop?.shopCipher)
    || text(shop?.shop?.shop_cipher)
    || text(shop?.seller?.shop_cipher);
}

function shopIdValue(shop: any): string | null {
  return text(shop?.shop_id)
    || text(shop?.id)
    || text(shop?.shop_code)
    || text(shop?.shopId)
    || text(shop?.shop?.id)
    || text(shop?.seller?.shop_id);
}

function shopNameValue(shop: any): string | null {
  return text(shop?.shop_name)
    || text(shop?.name)
    || text(shop?.shopName)
    || text(shop?.shop?.name)
    || text(shop?.seller?.shop_name);
}

function maskText(value: string | null | undefined): string | null {
  if (!value) return null;
  if (value.length <= 10) return "****";
  return `${value.slice(0, 6)}…${value.slice(-6)}`;
}

function pickAuthorizedShop(jsonRes: any, account: any, currentCipher: string | null): any | null {
  const shops = collectAuthorizedShops(jsonRes);
  if (shops.length === 0) return null;

  const currentShopId = text(account.shop_id);
  const currentName = text(account.shop_name) || text(account.store_alias);
  const region = text(account.shop_region);

  const byCipher = shops.find((shop) => shopCipherValue(shop) && shopCipherValue(shop) === currentCipher);
  if (byCipher) return byCipher;

  const byId = shops.find((shop) => {
    const ids = [shopIdValue(shop)].filter(Boolean);
    return currentShopId && ids.includes(currentShopId);
  });
  if (byId) return byId;

  const byName = shops.find((shop) => {
    const shopName = shopNameValue(shop);
    return currentName && shopName && shopName.toLowerCase() === currentName.toLowerCase();
  });
  if (byName) return byName;

  const byRegion = shops.find((shop) => {
    const shopRegion = text(shop.region) || text(shop.shop_region) || text(shop.country);
    return region && shopRegion && shopRegion.toUpperCase() === region.toUpperCase();
  });
  if (byRegion) return byRegion;

  return shops[0];
}

function collectAuthorizedShops(jsonRes: any): any[] {
  const response = jsonRes?.response ?? jsonRes;
  const data = response?.data ?? response;
  const candidates = [
    data?.shops,
    data?.shop_list,
    data?.authorized_shops,
    data?.shops_list,
    data?.data?.shops,
    data?.data?.shop_list,
    response?.shops,
    response?.shop_list,
    response?.authorized_shops,
  ];

  for (const item of candidates) {
    if (Array.isArray(item)) return item;
  }

  return [];
}

function safeJsonForDb(input: any): any {
  if (input === undefined) return null;
  return JSON.parse(JSON.stringify(input));
}


async function refreshTikTokAccessTokenIfNeeded(admin: any, account: any, force = false): Promise<{ account: any; accessToken: string }> {
  const tokenSecret = requiredEnv("MARKETPLACE_TOKEN_ENCRYPTION_KEY");
  const appKey = Deno.env.get("TIKTOK_APP_KEY")?.trim() || text(account.app_key);
  const appSecret = requiredEnv("TIKTOK_APP_SECRET");
  const currentAccessToken = await decryptText(String(account.access_token_encrypted || ""), tokenSecret);
  if (!currentAccessToken) throw new Error("Access token TikTok kosong. Re-authorize toko dulu.");

  const expiredAtMs = account.access_token_expired_at ? new Date(account.access_token_expired_at).getTime() : 0;
  const safeUntilMs = Date.now() + 10 * 60 * 1000;
  if (!force && expiredAtMs > safeUntilMs) return { account, accessToken: currentAccessToken };

  const refreshToken = await decryptText(String(account.refresh_token_encrypted || ""), tokenSecret);
  if (!refreshToken) throw new Error("Refresh token TikTok kosong. Reconnect TikTok Shop diperlukan.");

  if (!appKey) throw new Error("TIKTOK_APP_KEY kosong.");
  const authBase = String(Deno.env.get("TIKTOK_AUTH_BASE_URL") || "https://auth.tiktok-shops.com").replace(/\/+$/, "");
  const url = new URL("/api/v2/token/refresh", authBase);
  url.searchParams.set("app_key", appKey);
  url.searchParams.set("app_secret", appSecret);
  url.searchParams.set("refresh_token", refreshToken);
  url.searchParams.set("grant_type", "refresh_token");

  const res = await fetch(url.toString(), { method: "GET", headers: { accept: "application/json" } });
  const payload = await res.json().catch(() => null);

  if (!res.ok || !payload) {
    const message = `Refresh token TikTok gagal HTTP ${res.status}: ${JSON.stringify(maskTokenObject(payload))}`;
    await admin.from("marketplace_accounts").update({
      status: "reauth_required",
      last_error: message.slice(0, 1800),
      updated_at: new Date().toISOString(),
    }).eq("marketplace_account_id", account.marketplace_account_id);
    throw new Error(message);
  }

  const data = payload?.data ?? payload;

  if (payload?.code && String(payload.code) !== "0") {
    const message = `Refresh token TikTok gagal: ${JSON.stringify(maskTokenObject(payload))}`;
    await admin.from("marketplace_accounts").update({
      status: "reauth_required",
      last_error: message.slice(0, 1800),
      updated_at: new Date().toISOString(),
    }).eq("marketplace_account_id", account.marketplace_account_id);
    throw new Error(message);
  }

  const newAccessToken = text(data?.access_token);
  const newRefreshToken = text(data?.refresh_token) || refreshToken;

  if (!newAccessToken) {
    throw new Error(`Refresh token TikTok gagal: response tidak berisi access_token. ${JSON.stringify(maskTokenObject(payload))}`);
  }

  const accessExpiredAt = expireValueToIso(data?.access_token_expire_in)
    || expireValueToIso(data?.access_token_expired_at)
    || new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();

  const refreshExpiredAt = expireValueToIso(data?.refresh_token_expire_in)
    || expireValueToIso(data?.refresh_token_expired_at)
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
    .select("marketplace_account_id, tenant_id, marketplace, app_key, shop_id, shop_cipher, shop_region, shop_name, store_alias, status, environment, default_warehouse_id, access_token_encrypted, refresh_token_encrypted, access_token_expired_at, refresh_token_expired_at, raw_shop_response")
    .single();

  if (error) throw new Error(`Update TikTok refreshed token failed: ${error.message}`);
  return { account: updated, accessToken: newAccessToken };
}

async function fetchShopeeItemBaseInfo(args: { account: any; accessToken: string; itemId: string }) {
  return shopeeRequest({
    method: "GET",
    account: args.account,
    accessToken: args.accessToken,
    path: "/api/v2/product/get_item_base_info",
    query: {
      item_id_list: args.itemId,
      need_tax_info: false,
      need_complaint_policy: false,
    },
  });
}

async function fetchShopeeModelList(args: { account: any; accessToken: string; itemId: string }) {
  return shopeeRequest({
    method: "GET",
    account: args.account,
    accessToken: args.accessToken,
    path: "/api/v2/product/get_model_list",
    query: {
      item_id: args.itemId,
    },
  });
}

async function refreshShopeeAccessTokenIfNeeded(admin: any, account: any, force = false): Promise<{ account: any; accessToken: string }> {
  const tokenSecret = requiredEnv("MARKETPLACE_TOKEN_ENCRYPTION_KEY");
  const currentAccessToken = await decryptText(String(account.access_token_encrypted || ""), tokenSecret);
  if (!currentAccessToken) throw new Error("Shopee access token kosong. Re-authorize account.");

  const expiredAtMs = account.access_token_expired_at ? new Date(account.access_token_expired_at).getTime() : 0;
  const safeUntilMs = Date.now() + 10 * 60 * 1000;
  if (!force && expiredAtMs > safeUntilMs) return { account, accessToken: currentAccessToken };

  const refreshToken = await decryptText(String(account.refresh_token_encrypted || ""), tokenSecret);
  if (!refreshToken) throw new Error("Refresh token Shopee kosong. Reconnect Shopee diperlukan.");

  const credential = resolveShopeeCredentials(account.environment);
  const shopId = text(account.shop_id);
  if (!shopId) throw new Error("Shopee shop_id kosong. Reconnect Shopee diperlukan.");

  const response = await shopeeRequest({
    method: "POST",
    account,
    path: "/api/v2/auth/access_token/get",
    credential,
    authless: true,
    body: {
      partner_id: Number(credential.partnerId),
      refresh_token: refreshToken,
      shop_id: numericOrString(shopId),
    },
  });

  const data = response?.response ?? response ?? {};
  const newAccessToken = text(data.access_token);
  const newRefreshToken = text(data.refresh_token) || refreshToken;
  if (!newAccessToken) throw new Error(`Refresh token Shopee gagal: ${JSON.stringify(maskTokenObject(response))}`);

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
    .select("marketplace_account_id, tenant_id, marketplace, app_key, shop_id, shop_cipher, shop_region, shop_name, store_alias, status, environment, default_warehouse_id, access_token_encrypted, refresh_token_encrypted, access_token_expired_at, refresh_token_expired_at, raw_shop_response")
    .single();

  if (error) throw new Error(`Simpan refresh token Shopee gagal: ${error.message}`);
  return { account: updated, accessToken: newAccessToken };
}

async function shopeeRequest(args: {
  method: "GET" | "POST";
  account: any;
  path: string;
  accessToken?: string;
  query?: Record<string, string | number | boolean | null | undefined>;
  body?: Record<string, unknown>;
  credential?: any;
  authless?: boolean;
}) {
  const credential = args.credential || resolveShopeeCredentials(args.account.environment);
  const shopId = text(args.account.shop_id);
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const accessToken = text(args.accessToken);
  const signBase = args.authless
    ? `${credential.partnerId}${args.path}${timestamp}`
    : `${credential.partnerId}${args.path}${timestamp}${accessToken}${shopId}`;
  const sign = await hmacHex(credential.partnerKey, signBase);
  const url = new URL(args.path, credential.host);
  url.searchParams.set("partner_id", credential.partnerId);
  url.searchParams.set("timestamp", timestamp);
  url.searchParams.set("sign", sign);
  if (!args.authless) {
    if (!accessToken) throw new Error("Shopee access token kosong. Reconnect Shopee diperlukan.");
    if (!shopId) throw new Error("Shopee shop_id kosong. Reconnect Shopee diperlukan.");
    url.searchParams.set("access_token", accessToken);
    url.searchParams.set("shop_id", shopId);
  }
  for (const [key, value] of Object.entries(args.query || {})) {
    if (value === null || value === undefined || value === "") continue;
    url.searchParams.set(key, String(value));
  }

  const res = await fetch(url.toString(), {
    method: args.method,
    headers: {
      accept: "application/json",
      "content-type": "application/json",
    },
    body: args.method === "POST" ? JSON.stringify(args.body || {}) : undefined,
  });
  const payload = await res.json().catch(() => null);

  if (!res.ok) {
    if (res.status === 429) {
      throw new Error(`Shopee API Rate Limit (HTTP 429) pada ${args.path}`);
    }
    if (res.status >= 500) {
      throw new Error(`Shopee API Server Error (HTTP ${res.status}) pada ${args.path}: ${text(payload ? JSON.stringify(maskTokenObject(payload)) : res.statusText).slice(0, 200)}`);
    }
    throw new Error(`Shopee API HTTP ${res.status}: ${JSON.stringify(maskTokenObject(payload))}`);
  }

  if (!payload || typeof payload !== "object") {
    throw new Error(`Shopee API Abnormal Response (non-JSON payload) pada ${args.path}`);
  }

  if (payload.error) {
    const errCode = text(payload.error).toLowerCase();
    const errMsg = text(payload.message || payload.msg || payload.error_description || payload.error_msg);
    if (errCode.includes("rate_limit") || errCode.includes("frequency") || errCode.includes("limit_exceeded")) {
      throw new Error(`Shopee API Rate Limit [${payload.error}]: ${errMsg || "Frequency limit reached."}`);
    }
    if (errCode.includes("auth") || errCode.includes("permission") || errCode.includes("token") || errCode.includes("sign") || errCode.includes("shop_not_found") || errCode.includes("user_not_found") || errCode.includes("banned")) {
      throw new Error(`Shopee API Auth Error [${payload.error}]: ${errMsg || "Authorization invalid or expired."}`);
    }
    throw new Error(`Shopee API error [${payload.error}]: ${errMsg || JSON.stringify(maskTokenObject(payload))}`);
  }

  return payload;
}

function resolveShopeeCredentials(environmentValue: unknown) {
  const environment = normalizeMarketplaceEnvironment(environmentValue);
  const productionPartnerId = requiredEnv("SHOPEE_PARTNER_ID");
  const productionPartnerKey = requiredEnv("SHOPEE_PARTNER_KEY");

  if (environment === "testing") {
    const testPartnerId = optionalEnv("SHOPEE_TEST_PARTNER_ID");
    const testPartnerKey = optionalEnv("SHOPEE_TEST_PARTNER_KEY");
    return {
      environment,
      host: optionalEnv("SHOPEE_TEST_HOST") || optionalEnv("SHOPEE_SANDBOX_HOST") || "https://partner.test-stable.shopeemobile.com",
      partnerId: testPartnerId || productionPartnerId,
      partnerKey: testPartnerKey || productionPartnerKey,
      usedFallbackCredential: !testPartnerId || !testPartnerKey,
    };
  }

  return {
    environment,
    host: optionalEnv("SHOPEE_HOST") || optionalEnv("SHOPEE_API_BASE_URL") || "https://partner.shopeemobile.com",
    partnerId: productionPartnerId,
    partnerKey: productionPartnerKey,
    usedFallbackCredential: false,
  };
}

function normalizeMarketplaceEnvironment(value: unknown): "testing" | "production" {
  const clean = String(value ?? "").trim().toLowerCase();
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

async function hmacHex(secret: string, message: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
  return [...new Uint8Array(signature)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function maskTokenObject(input: any): any {
  if (input === null || input === undefined) return input;
  if (typeof input === "string") return input.length > 24 ? maskText(input) : input;
  if (Array.isArray(input)) return input.map(maskTokenObject);
  if (typeof input === "object") {
    const out: Record<string, any> = {};
    for (const [key, value] of Object.entries(input)) {
      const lowerKey = key.toLowerCase();
      out[key] = lowerKey.includes("token") || lowerKey.includes("secret") || lowerKey === "code"
        ? (typeof value === "string" ? maskText(value) : "***")
        : maskTokenObject(value);
    }
    return out;
  }
  return input;
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

  if (args.shopCipher) {
    params.shop_cipher = args.shopCipher;
  }

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
  if (!res.ok || !jsonRes) {
    throw new Error(`TikTok API HTTP ${res.status}: ${JSON.stringify(jsonRes)}`);
  }

  const code = jsonRes.code;
  if (code !== undefined && String(code) !== "0" && String(code).toLowerCase() !== "success") {
    throw new Error(`TikTok API error: ${JSON.stringify(jsonRes)}`);
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
  const encoder = new TextEncoder();
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, encoder.encode(signString));
  return [...new Uint8Array(signature)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function collectProducts(jsonRes: any): any[] {
  const data = jsonRes?.data ?? jsonRes?.response?.data ?? jsonRes?.response ?? jsonRes;
  const candidates = [
    data?.products,
    data?.product_list,
    data?.item_list,
    data?.list,
    data?.items,
    data?.data?.products,
    data?.data?.product_list,
  ];

  for (const item of candidates) {
    if (Array.isArray(item)) return item;
  }

  return [];
}

function collectShopeeItemList(jsonRes: any): any[] {
  const data = jsonRes?.response ?? jsonRes?.data ?? jsonRes;
  const candidates = [
    data?.item,
    data?.item_list,
    data?.items,
    data?.list,
    data?.products,
  ];
  for (const item of candidates) {
    if (Array.isArray(item)) return item;
  }
  return [];
}

function normalizeProduct(detailJson: any, productLite: any, productId: string) {
  const data = detailJson?.data ?? detailJson?.response?.data ?? detailJson?.response ?? detailJson;
  const product = data?.product ?? data?.product_info ?? data ?? productLite;
  const itemList = Array.isArray(data?.item_list) ? data.item_list : null;
  const merged = deepMerge(productLite || {}, itemList?.[0] || product || {});

  return {
    marketplace_product_id: productId,
    product_name: text(merged.title) || text(merged.name) || text(merged.product_name) || text(merged.item_name) || `Product ${productId}`,
    product_status: text(merged.status) || text(merged.product_status) || text(merged.item_status) || null,
    image_url: firstImageUrl(merged),
    raw: merged,
  };
}

function normalizeVariants(rawProduct: any, product: any): any[] {
  const skus = firstArray([
    rawProduct?.skus,
    rawProduct?.sku_list,
    rawProduct?.seller_skus,
    rawProduct?.product_skus,
    rawProduct?.product?.skus,
    rawProduct?.product_info?.skus,
  ]);

  if (!skus) return [];

  const catalog = buildAttributeCatalog(rawProduct);

  return skus.map((sku: any, index: number) => {
    const skuId =
      text(sku.id) ||
      text(sku.sku_id) ||
      text(sku.seller_sku_id) ||
      text(sku.global_sku_id) ||
      text(sku.product_sku_id) ||
      `${product.marketplace_product_id}-${index + 1}`;

    const options = buildVariantOptions(sku, rawProduct, catalog);
    const variantName = buildVariantName(options, sku, index);
    const price = extractPrice(sku);

    return {
      marketplace_product_id: product.marketplace_product_id,
      marketplace_sku_id: skuId,
      marketplace_sku_code: text(sku.sku_code) || text(sku.sku) || text(sku.sku_code_original) || null,
      marketplace_seller_sku: text(sku.seller_sku) || text(sku.seller_sku_code) || text(sku.outer_sku_id) || null,
      marketplace_product_name: product.product_name,
      marketplace_variant_name: variantName,
      product_status: product.product_status,
      sku_status: text(sku.status) || text(sku.sku_status) || null,
      price_amount: price.amount,
      price_currency: price.currency,
      stock_quantity: extractStock(sku),
      raw_variant: {
        sku,
        normalized_options: options,
      },
    };
  });
}

function normalizeShopeeVariants(modelJson: any, product: any): any[] {
  const data = modelJson?.response ?? modelJson?.data ?? modelJson ?? {};
  const models = firstArray([
    data?.model,
    data?.model_list,
    data?.models,
    data?.item_model_list,
  ]) || [];
  const tierVariations = firstArray([data?.tier_variation, data?.tier_variation_list, data?.tier_variations]) || [];

  return models.map((model: any, index: number) => {
    const modelId = text(model.model_id) || text(model.id) || `${product.marketplace_product_id}-${index + 1}`;
    const stockInfo = firstArray([model.stock_info, model.stock_infos, model.stock, model.inventory]) || [];
    const totalStock = stockInfo.reduce((sum: number, item: any) => {
      const qty = numberOrNull(item?.normal_stock) ?? numberOrNull(item?.current_stock) ?? numberOrNull(item?.stock) ?? numberOrNull(item?.sellable_stock) ?? 0;
      return sum + qty;
    }, 0);
    const priceInfo = firstArray([model.price_info, model.price_infos])?.[0] || model;
    const priceAmount = numberOrNull(priceInfo?.current_price)
      ?? numberOrNull(priceInfo?.model_price)
      ?? numberOrNull(priceInfo?.original_price)
      ?? numberOrNull(model.price);
    const variantName = text(model.model_name)
      || text(model.name)
      || buildShopeeVariantName(model, tierVariations, index)
      || `Variant ${index + 1}`;

    return {
      marketplace_product_id: product.marketplace_product_id,
      marketplace_sku_id: modelId,
      marketplace_sku_code: text(model.model_sku) || text(model.sku) || null,
      marketplace_seller_sku: text(model.model_sku) || text(model.seller_sku) || null,
      marketplace_product_name: product.product_name,
      marketplace_variant_name: variantName,
      product_status: product.product_status,
      sku_status: text(model.model_status) || text(model.status) || null,
      price_amount: priceAmount,
      price_currency: text(priceInfo?.currency) || text(model.currency) || null,
      stock_quantity: stockInfo.length > 0 ? totalStock : null,
      raw_variant: {
        sku: model,
        tier_variation: tierVariations,
      },
    };
  });
}

function buildShopeeVariantName(model: any, tierVariations: any[], index: number): string | null {
  const tierIndex = firstArray([model?.tier_index, model?.tier_indexes, model?.tier_variation_index]) || [];
  const parts: string[] = [];
  for (let i = 0; i < tierIndex.length; i += 1) {
    const optionIndex = Number(tierIndex[i]);
    const tier = tierVariations[i];
    const options = firstArray([tier?.option_list, tier?.options, tier?.value_list, tier?.values]) || [];
    const value = options[optionIndex];
    const optionName = text(value?.option) || text(value?.value) || text(value?.name) || text(value);
    const tierName = text(tier?.name);
    if (optionName) parts.push(tierName ? `${tierName}: ${optionName}` : optionName);
  }
  return parts.length > 0 ? parts.join(" / ") : null;
}

async function clearProductSnapshotCache(admin: any, account: any) {
  const rpc = await admin.rpc("marketplace_clear_product_cache", {
    p_tenant_id: account.tenant_id,
    p_marketplace_account_id: account.marketplace_account_id,
  });

  if (!rpc.error) return;

  const { error: variantError } = await admin
    .from("marketplace_variant_snapshots")
    .delete()
    .eq("tenant_id", account.tenant_id)
    .eq("marketplace_account_id", account.marketplace_account_id);

  if (variantError) throw new Error(`Clear variant cache failed: ${variantError.message}`);

  const { error: productError } = await admin
    .from("marketplace_product_snapshots")
    .delete()
    .eq("tenant_id", account.tenant_id)
    .eq("marketplace_account_id", account.marketplace_account_id);

  if (productError) throw new Error(`Clear product cache failed: ${productError.message}`);
}


async function upsertProductSnapshot(admin: any, account: any, product: any) {
  const now = new Date().toISOString();
  const payload = {
    tenant_id: account.tenant_id,
    marketplace_account_id: account.marketplace_account_id,
    marketplace: account.marketplace,
    marketplace_product_id: product.marketplace_product_id,
    product_name: product.product_name,
    product_status: product.product_status,
    image_url: product.image_url,
    raw_product: product.raw,
    last_seen_at: now,
    updated_at: now,
  };

  const { data: existing, error: findError } = await admin
    .from("marketplace_product_snapshots")
    .select("marketplace_product_snapshot_id")
    .eq("tenant_id", account.tenant_id)
    .eq("marketplace_account_id", account.marketplace_account_id)
    .eq("marketplace_product_id", product.marketplace_product_id)
    .limit(1)
    .maybeSingle();

  if (findError) throw new Error(`Find product snapshot failed: ${findError.message}`);

  if (existing?.marketplace_product_snapshot_id) {
    const { error } = await admin
      .from("marketplace_product_snapshots")
      .update(payload)
      .eq("marketplace_product_snapshot_id", existing.marketplace_product_snapshot_id);
    if (error) throw new Error(`Update product snapshot failed: ${error.message}`);
    return;
  }

  const { error } = await admin
    .from("marketplace_product_snapshots")
    .insert({ ...payload, first_seen_at: now, created_at: now });
  if (error) throw new Error(`Insert product snapshot failed: ${error.message}`);
}

async function upsertVariantSnapshot(admin: any, account: any, variant: any) {
  const now = new Date().toISOString();
  const payload = {
    tenant_id: account.tenant_id,
    marketplace_account_id: account.marketplace_account_id,
    marketplace: account.marketplace,
    marketplace_product_id: variant.marketplace_product_id,
    marketplace_sku_id: variant.marketplace_sku_id,
    marketplace_sku_code: variant.marketplace_sku_code,
    marketplace_seller_sku: variant.marketplace_seller_sku,
    marketplace_product_name: variant.marketplace_product_name,
    marketplace_variant_name: variant.marketplace_variant_name,
    product_status: variant.product_status,
    sku_status: variant.sku_status,
    price_amount: variant.price_amount,
    price_currency: variant.price_currency,
    stock_quantity: variant.stock_quantity,
    raw_variant: variant.raw_variant,
    last_seen_at: now,
    updated_at: now,
  };

  const { data: existing, error: findError } = await admin
    .from("marketplace_variant_snapshots")
    .select("marketplace_variant_snapshot_id")
    .eq("tenant_id", account.tenant_id)
    .eq("marketplace_account_id", account.marketplace_account_id)
    .eq("marketplace_product_id", variant.marketplace_product_id)
    .eq("marketplace_sku_id", variant.marketplace_sku_id)
    .limit(1)
    .maybeSingle();

  if (findError) throw new Error(`Find variant snapshot failed: ${findError.message}`);

  if (existing?.marketplace_variant_snapshot_id) {
    const { error } = await admin
      .from("marketplace_variant_snapshots")
      .update(payload)
      .eq("marketplace_variant_snapshot_id", existing.marketplace_variant_snapshot_id);
    if (error) throw new Error(`Update variant snapshot failed: ${error.message}`);
    return;
  }

  const { error } = await admin
    .from("marketplace_variant_snapshots")
    .insert({ ...payload, first_seen_at: now, created_at: now });
  if (error) throw new Error(`Insert variant snapshot failed: ${error.message}`);
}

function buildVariantName(options: Array<{ name: string | null; value: string }>, sku: any, index: number): string {
  const cleanOptions = dedupeOptions(options)
    .filter((item) => item.value.trim().length > 0)
    .map((item) => item.name ? `${item.name}: ${item.value}` : item.value);

  if (cleanOptions.length > 0) return cleanOptions.join(" • ");

  const directName =
    text(sku.variant_name) ||
    text(sku.sku_name) ||
    text(sku.name) ||
    text(sku.title) ||
    text(sku.sku_title) ||
    text(sku.specification);

  if (directName) return directName;

  return `Default variant ${index + 1}`;
}

function buildVariantOptions(sku: any, rawProduct: any, catalog: Map<string, { attrName: string | null; valueName: string }>): Array<{ name: string | null; value: string }> {
  const directOptions: Array<{ name: string | null; value: string }> = [];

  const attrArrays = [
    sku?.sales_attributes,
    sku?.sale_attributes,
    sku?.sale_properties,
    sku?.properties,
    sku?.variation_attributes,
    sku?.variant_attributes,
    sku?.sku_attributes,
    sku?.attributes,
    sku?.attribute_values,
    sku?.option_values,
    sku?.specs,
    sku?.specifications,
  ];

  for (const arr of attrArrays) {
    if (!Array.isArray(arr)) continue;
    for (const attr of arr) {
      const parsed = parseAttributeObject(attr, catalog);
      if (parsed) directOptions.push(parsed);
    }
  }

  const combination = sku?.combination || sku?.combinations || sku?.variant_combination;
  if (Array.isArray(combination)) {
    for (const attr of combination) {
      const parsed = parseAttributeObject(attr, catalog);
      if (parsed) directOptions.push(parsed);
    }
  } else if (combination && typeof combination === "object") {
    for (const [name, value] of Object.entries(combination)) {
      const cleanValue = text(value);
      if (cleanValue) directOptions.push({ name: text(name), value: cleanValue });
    }
  }

  const valueIds = collectValueIds(sku);
  for (const valueId of valueIds) {
    const mapped = catalog.get(valueId);
    if (mapped) directOptions.push({ name: mapped.attrName, value: mapped.valueName });
  }

  const optionTextCandidates = [
    sku?.option_name,
    sku?.option_value,
    sku?.variant,
    sku?.variation,
  ];

  for (const candidate of optionTextCandidates) {
    const value = text(candidate);
    if (value) directOptions.push({ name: null, value });
  }

  return dedupeOptions(directOptions);
}

function parseAttributeObject(attr: any, catalog: Map<string, { attrName: string | null; valueName: string }>): { name: string | null; value: string } | null {
  if (!attr) return null;

  if (typeof attr === "string" || typeof attr === "number") {
    const mapped = catalog.get(String(attr));
    if (mapped) return { name: mapped.attrName, value: mapped.valueName };
    return { name: null, value: String(attr) };
  }

  const attrId =
    text(attr.attribute_id) ||
    text(attr.sales_attribute_id) ||
    text(attr.property_id) ||
    text(attr.id) ||
    text(attr.name_id);

  const valueId =
    text(attr.value_id) ||
    text(attr.attribute_value_id) ||
    text(attr.sales_attribute_value_id) ||
    text(attr.property_value_id) ||
    text(attr.option_value_id) ||
    text(attr.value?.id) ||
    text(attr.value?.value_id);

  if (valueId) {
    const mapped = catalog.get(valueId) || (attrId ? catalog.get(`${attrId}:${valueId}`) : null);
    if (mapped) return { name: mapped.attrName, value: mapped.valueName };
  }

  const name =
    text(attr.name) ||
    text(attr.attribute_name) ||
    text(attr.sales_attribute_name) ||
    text(attr.property_name) ||
    text(attr.option_name) ||
    text(attr.key) ||
    text(attr.attribute?.name) ||
    (attrId ? catalog.get(`attr:${attrId}`)?.attrName ?? null : null);

  const value =
    text(attr.value_name) ||
    text(attr.value) ||
    text(attr.attribute_value_name) ||
    text(attr.sku_attribute_value) ||
    text(attr.property_value_name) ||
    text(attr.option_value) ||
    text(attr.option_value_name) ||
    text(attr.value?.name) ||
    text(attr.value?.value_name) ||
    text(attr.value?.display_name) ||
    text(attr.display_name);

  if (value) return { name, value };

  return null;
}

function buildAttributeCatalog(rawProduct: any): Map<string, { attrName: string | null; valueName: string }> {
  const catalog = new Map<string, { attrName: string | null; valueName: string }>();

  const arrays = [
    rawProduct?.sales_attributes,
    rawProduct?.sale_attributes,
    rawProduct?.sale_properties,
    rawProduct?.product_sales_attributes,
    rawProduct?.variation_attributes,
    rawProduct?.variant_attributes,
    rawProduct?.properties,
    rawProduct?.product?.sales_attributes,
    rawProduct?.product_info?.sales_attributes,
  ];

  for (const arr of arrays) {
    if (!Array.isArray(arr)) continue;

    for (const attr of arr) {
      const attrId =
        text(attr.id) ||
        text(attr.attribute_id) ||
        text(attr.sales_attribute_id) ||
        text(attr.property_id);

      const attrName =
        text(attr.name) ||
        text(attr.attribute_name) ||
        text(attr.sales_attribute_name) ||
        text(attr.property_name);

      if (attrId && attrName) {
        catalog.set(`attr:${attrId}`, { attrName, valueName: attrName });
      }

      const values = firstArray([
        attr.values,
        attr.attribute_values,
        attr.sales_attribute_values,
        attr.sale_property_values,
        attr.property_values,
        attr.options,
        attr.value_list,
      ]);

      if (!values) continue;

      for (const value of values) {
        const valueId =
          text(value.id) ||
          text(value.value_id) ||
          text(value.attribute_value_id) ||
          text(value.sales_attribute_value_id) ||
          text(value.property_value_id) ||
          text(value.option_value_id);

        const valueName =
          text(value.name) ||
          text(value.value_name) ||
          text(value.attribute_value_name) ||
          text(value.property_value_name) ||
          text(value.option_value) ||
          text(value.display_name);

        if (!valueId || !valueName) continue;

        catalog.set(valueId, { attrName, valueName });
        if (attrId) catalog.set(`${attrId}:${valueId}`, { attrName, valueName });
      }
    }
  }

  return catalog;
}

function collectValueIds(sku: any): string[] {
  const result: string[] = [];
  const arrays = [
    sku?.sales_attribute_value_ids,
    sku?.attribute_value_ids,
    sku?.property_value_ids,
    sku?.option_value_ids,
    sku?.sku_sale_property_value_ids,
    sku?.variant_option_value_ids,
  ];

  for (const arr of arrays) {
    if (!Array.isArray(arr)) continue;
    for (const value of arr) {
      const clean = text(value);
      if (clean) result.push(clean);
    }
  }

  return result;
}

function dedupeOptions(options: Array<{ name: string | null; value: string }>): Array<{ name: string | null; value: string }> {
  const seen = new Set<string>();
  const output: Array<{ name: string | null; value: string }> = [];

  for (const item of options) {
    const value = item.value.trim();
    if (!value) continue;
    const key = `${item.name || ""}:${value}`.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    output.push({ name: item.name?.trim() || null, value });
  }

  return output;
}


function extractStock(sku: any): number | null {
  const direct = numberOrNull(sku.stock_quantity) ?? numberOrNull(sku.inventory_quantity) ?? numberOrNull(sku.quantity) ?? numberOrNull(sku.available_stock);
  if (direct !== null) return direct;

  const inventory = firstArray([sku.inventory, sku.inventories, sku.stock_infos, sku.warehouse_stock]);
  if (inventory) {
    let total = 0;
    let found = false;
    for (const item of inventory) {
      const qty = numberOrNull(item.quantity) ?? numberOrNull(item.available_stock) ?? numberOrNull(item.stock) ?? numberOrNull(item.inventory_quantity);
      if (qty !== null) {
        total += qty;
        found = true;
      }
    }
    if (found) return total;
  }

  return null;
}

function extractPrice(sku: any): { amount: number | null; currency: string | null } {
  const priceObj = sku.price || sku.sale_price || sku.original_price || sku.list_price || null;
  const amount = numberOrNull(priceObj?.amount) ?? numberOrNull(priceObj?.value) ?? numberOrNull(priceObj) ?? numberOrNull(sku.price_amount);
  const currency = text(priceObj?.currency) || text(sku.currency) || null;
  return { amount, currency };
}

function firstImageUrl(product: any): string | null {
  const images = firstArray([product.images, product.main_images, product.product_images]);
  if (!images || images.length === 0) return null;
  const first = images[0];
  return text(first?.url) || text(first?.thumb_url) || text(first?.uri) || text(first);
}

function firstArray(candidates: any[]): any[] | null {
  for (const item of candidates) {
    if (Array.isArray(item)) return item;
  }
  return null;
}

function deepMerge(a: any, b: any) {
  return { ...(a || {}), ...(b || {}) };
}

function text(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  const clean = String(value).trim();
  if (!clean || clean === "null" || clean === "undefined") return null;
  return clean;
}

function numberOrNull(value: unknown): number | null {
  if (value === null || value === undefined || value === "") return null;
  if (typeof value === "object") {
    const obj: any = value;
    return numberOrNull(obj.amount ?? obj.value ?? obj.price ?? obj.current_price ?? obj.original_price);
  }
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
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
  const keyHash = await crypto.subtle.digest("SHA-256", encoder.encode(secret));
  const key = await crypto.subtle.importKey("raw", keyHash, { name: "AES-GCM" }, false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, encoder.encode(plainText));
  return `aesgcm:${toBase64(iv)}:${toBase64(new Uint8Array(encrypted))}`;
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

async function decryptText(encryptedText: string, secret: string): Promise<string> {
  if (!encryptedText) return "";

  const encoder = new TextEncoder();
  const keyHash = await crypto.subtle.digest("SHA-256", encoder.encode(secret));
  const key = await crypto.subtle.importKey("raw", keyHash, { name: "AES-GCM" }, false, ["decrypt"]);

  if (encryptedText.startsWith("aesgcm:")) {
    const [, ivBase64, dataBase64] = encryptedText.split(":");
    if (!ivBase64 || !dataBase64) throw new Error("Token terenkripsi tidak lengkap.");
    const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: fromBase64(ivBase64) }, key, fromBase64(dataBase64));
    return new TextDecoder().decode(plain);
  }

  if (encryptedText.includes(".")) {
    const [ivBase64, dataBase64] = encryptedText.split(".");
    if (!ivBase64 || !dataBase64) throw new Error("Token terenkripsi tidak lengkap.");
    const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: fromBase64Url(ivBase64) }, key, fromBase64Url(dataBase64));
    return new TextDecoder().decode(plain);
  }

  return encryptedText;
}

function fromBase64Url(input: string): Uint8Array {
  const normalized = input.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  return fromBase64(padded);
}

function fromBase64(input: string): Uint8Array {
  const normalized = input.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

async function safeJson(req: Request): Promise<Record<string, any>> {
  try {
    const value = await req.json();
    if (value && typeof value === "object") return value;
    return {};
  } catch (_) {
    return {};
  }
}

function clampInt(value: unknown, min: number, max: number, fallback: number): number {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.floor(n)));
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value || !value.trim()) throw new Error(`Missing env: ${name}`);
  return value.trim();
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: {
      ...corsHeaders,
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  });
}

function envCronSecret(): string {
  return String(
    Deno.env.get("MARKETPLACE_CRON_SECRET") ||
    Deno.env.get("MARKETPLACE_AUTO_SYNC_CRON_SECRET") ||
    Deno.env.get("STOCK_SYNC_CRON_SECRET") ||
    "",
  ).trim();
}

function requestCronSecret(req: Request, body?: any): string {
  return String(
    req.headers.get("x-marketplace-cron-secret") ||
    req.headers.get("x-stock-sync-cron-secret") ||
    body?.cron_secret ||
    body?.marketplace_cron_secret ||
    body?.x_marketplace_cron_secret ||
    body?.secret ||
    "",
  ).trim();
}

async function verifyMarketplaceCronSecret(admin: any, incomingSecret: string): Promise<boolean> {
  if (!incomingSecret) return false;

  const { data, error } = await admin.rpc("verify_marketplace_cron_secret", {
    p_secret: incomingSecret,
  });

  if (!error && data === true) return true;

  if (error) {
    console.error("verify_marketplace_cron_secret failed", error.message);
  }

  return false;
}
