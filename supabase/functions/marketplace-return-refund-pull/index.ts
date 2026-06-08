import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const FUNCTION_VERSION = "marketplace-return-refund-pull-v5-cron-nonblocking-single-row-upsert-2026-05-19";

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    if (req.method !== "POST") return json({ ok: false, message: "Method not allowed" }, 405);

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

    const tenantId = text(body.tenant_id) || text(profile.tenant_id);
    const requestedAccountId = text(body.marketplace_account_id);
    const daysBack = clampInt(body.days_back, 1, 120, 30);
    const pageSize = clampInt(body.limit, 1, 50, 20);
    const maxPages = clampInt(body.max_pages, 1, 10, 3);

    if (!tenantId) return json({ ok: false, message: "tenant_id is required" }, 400);

    const roleId = text(profile.role_id);
    const isSuperAdmin = roleId === "super_admin";
    const isDemoSuperAdmin = roleId === "demo_super_admin";

    if (!isSuperAdmin && !isDemoSuperAdmin && tenantId !== text(profile.tenant_id)) {
      return json({ ok: false, message: "Forbidden tenant access" }, 403);
    }

    if (isDemoSuperAdmin) {
      return json({ ok: false, message: "Demo account tidak boleh pull return/refund marketplace production." }, 403);
    }

    let accountQuery = admin
      .from("marketplace_accounts")
      .select("marketplace_account_id, tenant_id, marketplace, app_key, shop_id, shop_cipher, shop_region, shop_name, store_alias, status, environment, access_token_encrypted, refresh_token_encrypted, access_token_expired_at, refresh_token_expired_at, raw_shop_response")
      .eq("tenant_id", tenantId)
      .eq("status", "active");

    if (requestedAccountId && requestedAccountId !== "all") {
      accountQuery = accountQuery.eq("marketplace_account_id", requestedAccountId);
    }

    const { data: accounts, error: accountError } = await accountQuery;
    if (accountError) return json({ ok: false, message: accountError.message }, 400);
    if (!accounts || accounts.length === 0) return json({ ok: false, message: "Tidak ada marketplace account aktif untuk pull return/refund." }, 404);

    let totalPulled = 0;
    let totalInserted = 0;
    let totalCancellationPulled = 0;
    let totalCancellationInserted = 0;
    const details: unknown[] = [];
    const warnings: string[] = [];

    for (const baseAccount of accounts) {
      if (baseAccount.marketplace === "shopee") {
        let tokenBundle = await refreshShopeeAccessTokenIfNeeded(admin, baseAccount);
        let account = tokenBundle.account;
        let accessToken = tokenBundle.accessToken;
        const sinceUnix = Math.floor((Date.now() - daysBack * 24 * 60 * 60 * 1000) / 1000);
        const untilUnix = Math.floor(Date.now() / 1000);

        let returnResult: any;
        try {
          returnResult = await pullShopeeCasePages({
            account,
            accessToken,
            sinceUnix,
            untilUnix,
            pageSize,
            maxPages,
            paths: [
              "/api/v2/returns/get_return_order_list",
              "/api/v2/returns/get_return_list",
              "/api/v2/refund/get_refund_order_list",
            ],
            collect: collectReturnCases,
            softFail: true,
          });
        } catch (err) {
          if (isShopeeAuthError(err)) {
            tokenBundle = await refreshShopeeAccessTokenIfNeeded(admin, account, true);
            account = tokenBundle.account;
            accessToken = tokenBundle.accessToken;
            returnResult = await pullShopeeCasePages({
              account,
              accessToken,
              sinceUnix,
              untilUnix,
              pageSize,
              maxPages,
              paths: [
                "/api/v2/returns/get_return_order_list",
                "/api/v2/returns/get_return_list",
                "/api/v2/refund/get_refund_order_list",
              ],
              collect: collectReturnCases,
              softFail: true,
            });
          } else {
            throw err;
          }
        }

        const returnRows = dedupeCaseRows(buildCaseRows({ tenantId, account, cases: returnResult.cases }));
        const returnSave = await upsertCaseRowsIndividually(admin, returnRows, "shopee return/refund");
        warnings.push(...returnSave.warnings);

        let cancellationResult: any;
        try {
          cancellationResult = await pullShopeeCancelledOrdersAsCases({
            account,
            accessToken,
            sinceUnix,
            untilUnix,
            pageSize,
            maxPages,
          });
        } catch (err) {
          if (isShopeeAuthError(err)) {
            tokenBundle = await refreshShopeeAccessTokenIfNeeded(admin, account, true);
            account = tokenBundle.account;
            accessToken = tokenBundle.accessToken;
            cancellationResult = await pullShopeeCancelledOrdersAsCases({
              account,
              accessToken,
              sinceUnix,
              untilUnix,
              pageSize,
              maxPages,
            });
          } else {
            throw err;
          }
        }
        const cancellationRows = dedupeCaseRows(buildCancellationRows({ tenantId, account, cases: cancellationResult.cases }));
        const cancellationSave = await upsertCaseRowsIndividually(admin, cancellationRows, "shopee cancellation");
        warnings.push(...cancellationSave.warnings);

        totalPulled += returnResult.cases.length;
        totalInserted += returnSave.saved;
        totalCancellationPulled += cancellationResult.cases.length;
        totalCancellationInserted += cancellationSave.saved;

        details.push({
          marketplace_account_id: account.marketplace_account_id,
          marketplace: account.marketplace,
          store_alias: account.store_alias,
          shop_name: account.shop_name,
          return_refund_pulled: returnResult.cases.length,
          return_refund_saved_rows: returnSave.saved,
          cancellation_pulled: cancellationResult.cases.length,
          cancellation_saved_rows: cancellationSave.saved,
          message: [returnResult.message, cancellationResult.message].filter(Boolean).join(" | "),
        });
        continue;
      }

      if (baseAccount.marketplace !== "tiktok_shop") {
        warnings.push(`Marketplace ${baseAccount.marketplace} belum didukung untuk return/refund pull.`);
        continue;
      }

      const appKey = text(baseAccount.app_key) || requiredEnv("TIKTOK_APP_KEY");
      const appSecret = requiredEnv("TIKTOK_APP_SECRET");
      const shopCipher = detectShopCipher(baseAccount);
      let tokenBundle = await refreshTikTokAccessTokenIfNeeded(admin, baseAccount);
      let account = tokenBundle.account;
      let accessToken = tokenBundle.accessToken;
      const sinceUnix = Math.floor((Date.now() - daysBack * 24 * 60 * 60 * 1000) / 1000);
      const untilUnix = Math.floor(Date.now() / 1000);

      let returnResult: any;
      try {
        returnResult = await pullCasePages({
          appKey,
          appSecret,
          accessToken,
          shopCipher: shopCipher || undefined,
          sinceUnix,
          untilUnix,
          pageSize,
          maxPages,
          paths: [
            "/return_refund/202309/returns/search",
            "/return_refund/202309/return_orders/search",
            "/return_refund/202309/refunds/search",
          ],
          collect: collectReturnCases,
        });
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        if (isTikTokAuthError(msg)) {
          tokenBundle = await refreshTikTokAccessTokenIfNeeded(admin, account, true);
          account = tokenBundle.account;
          accessToken = tokenBundle.accessToken;
          returnResult = await pullCasePages({
            appKey,
            appSecret,
            accessToken,
            shopCipher: shopCipher || undefined,
            sinceUnix,
            untilUnix,
            pageSize,
            maxPages,
            paths: [
              "/return_refund/202309/returns/search",
              "/return_refund/202309/return_orders/search",
              "/return_refund/202309/refunds/search",
            ],
            collect: collectReturnCases,
          });
        } else {
          throw err;
        }
      }

      const returnRows = dedupeCaseRows(buildCaseRows({ tenantId, account, cases: returnResult.cases }));
      const returnSave = await upsertCaseRowsIndividually(admin, returnRows, "return/refund");
      const insertedForAccount = returnSave.saved;
      warnings.push(...returnSave.warnings);

      let cancellationResult: any;
      try {
        cancellationResult = await pullCasePages({
          appKey,
          appSecret,
          accessToken,
          shopCipher: shopCipher || undefined,
          sinceUnix,
          untilUnix,
          pageSize,
          maxPages,
          paths: [
            "/return_refund/202309/cancellations/search",
            "/return_refund/202309/cancel_orders/search",
            "/return_refund/202309/cancellation_orders/search",
          ],
          collect: collectCancellationCases,
          softFail: true,
        });
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        if (isTikTokAuthError(msg)) {
          tokenBundle = await refreshTikTokAccessTokenIfNeeded(admin, account, true);
          account = tokenBundle.account;
          accessToken = tokenBundle.accessToken;
          cancellationResult = await pullCasePages({
            appKey,
            appSecret,
            accessToken,
            shopCipher: shopCipher || undefined,
            sinceUnix,
            untilUnix,
            pageSize,
            maxPages,
            paths: [
              "/return_refund/202309/cancellations/search",
              "/return_refund/202309/cancel_orders/search",
              "/return_refund/202309/cancellation_orders/search",
            ],
            collect: collectCancellationCases,
            softFail: true,
          });
        } else {
          throw err;
        }
      }

      const cancellationRows = dedupeCaseRows(buildCancellationRows({ tenantId, account, cases: cancellationResult.cases }));
      const cancellationSave = await upsertCaseRowsIndividually(admin, cancellationRows, "cancellation");
      const insertedCancellationForAccount = cancellationSave.saved;
      warnings.push(...cancellationSave.warnings);

      totalPulled += returnResult.cases.length;
      totalInserted += insertedForAccount;
      totalCancellationPulled += cancellationResult.cases.length;
      totalCancellationInserted += insertedCancellationForAccount;

      details.push({
        marketplace_account_id: account.marketplace_account_id,
        marketplace: account.marketplace,
        store_alias: account.store_alias,
        shop_name: account.shop_name,
        return_refund_pulled: returnResult.cases.length,
        return_refund_saved_rows: insertedForAccount,
        cancellation_pulled: cancellationResult.cases.length,
        cancellation_saved_rows: insertedCancellationForAccount,
        message: [returnResult.message, cancellationResult.message].filter(Boolean).join(" | "),
      });
    }

    return json({
      ok: true,
      function_version: FUNCTION_VERSION,
      pulled: totalPulled + totalCancellationPulled,
      saved_rows: totalInserted + totalCancellationInserted,
      return_refund_pulled: totalPulled,
      return_refund_saved_rows: totalInserted,
      cancellation_pulled: totalCancellationPulled,
      cancellation_saved_rows: totalCancellationInserted,
      warning_count: warnings.length,
      warnings: warnings.slice(0, 12),
      message: warnings.length > 0
        ? `After-sales pull selesai dengan warning. Return/refund: ${totalPulled} case, ${totalInserted} rows. Cancellation: ${totalCancellationPulled} case, ${totalCancellationInserted} rows. Beberapa row di-skip supaya Pull Orders tidak gagal total.`
        : `After-sales pull selesai. Return/refund: ${totalPulled} case, ${totalInserted} rows. Cancellation: ${totalCancellationPulled} case, ${totalCancellationInserted} rows.`,
      details,
    });
  } catch (err) {
    return json({ ok: false, message: err instanceof Error ? err.message : String(err) }, 500);
  }
});

async function pullShopeeCasePages(args: {
  account: any;
  accessToken: string;
  sinceUnix: number;
  untilUnix: number;
  pageSize: number;
  maxPages: number;
  paths: string[];
  collect: (jsonRes: any) => any[];
  softFail?: boolean;
}): Promise<{ cases: any[]; message: string }> {
  const cases: any[] = [];
  let lastMessage = "";

  for (const path of args.paths) {
    let cursor = "";
    let pageNo = 1;
    let pathHadResult = false;

    for (let page = 0; page < args.maxPages; page++) {
      const query: Record<string, string | number | null> = {
        page_size: args.pageSize,
        cursor: cursor || null,
        page_no: pageNo,
        time_from: args.sinceUnix,
        time_to: args.untilUnix,
        create_time_from: args.sinceUnix,
        create_time_to: args.untilUnix,
        update_time_from: args.sinceUnix,
        update_time_to: args.untilUnix,
      };

      try {
        const jsonRes = await shopeeRequest({
          method: "GET",
          account: args.account,
          accessToken: args.accessToken,
          path,
          query,
        });
        const pageCases = args.collect(jsonRes);
        pathHadResult = true;
        lastMessage = `path=${path}, cases=${pageCases.length}`;
        if (pageCases.length === 0 && page === 0) break;
        cases.push(...pageCases);

        const next = nextShopeeCursor(jsonRes);
        if (!next || next === cursor) break;
        cursor = next;
        pageNo += 1;
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        if (args.softFail) {
          lastMessage = `optional path failed ${path}: ${message}`;
          break;
        }
        throw err;
      }
    }

    if (pathHadResult) break;
  }

  return { cases, message: lastMessage };
}

async function pullShopeeCancelledOrdersAsCases(args: {
  account: any;
  accessToken: string;
  sinceUnix: number;
  untilUnix: number;
  pageSize: number;
  maxPages: number;
}): Promise<{ cases: any[]; message: string }> {
  const cases: any[] = [];
  let cursor = "";
  let message = "";

  for (let page = 0; page < args.maxPages; page++) {
    try {
      const jsonRes = await shopeeRequest({
        method: "GET",
        account: args.account,
        accessToken: args.accessToken,
        path: "/api/v2/order/get_order_list",
        query: {
          time_range_field: "update_time",
          time_from: args.sinceUnix,
          time_to: args.untilUnix,
          page_size: args.pageSize,
          cursor: cursor || null,
          order_status: "CANCELLED",
          response_optional_fields: "order_status",
        },
      });

      const orders = collectShopeeOrders(jsonRes);
      cases.push(...orders.map((order) => ({
        ...order,
        type: "cancel",
        status: text(order.order_status) || "CANCELLED",
        return_type: "cancel",
        cancel_reason: text(order.cancel_reason) || text(order.buyer_cancel_reason),
      })));
      message = `path=/api/v2/order/get_order_list, cancelled=${orders.length}`;

      const next = nextShopeeCursor(jsonRes);
      if (!next || next === cursor || orders.length === 0) break;
      cursor = next;
    } catch (err) {
      message = `optional cancelled order pull failed: ${err instanceof Error ? err.message : String(err)}`;
      break;
    }
  }

  return { cases, message };
}


async function pullCasePages(args: {
  appKey: string;
  appSecret: string;
  accessToken: string;
  shopCipher?: string;
  sinceUnix: number;
  untilUnix: number;
  pageSize: number;
  maxPages: number;
  paths: string[];
  collect: (jsonRes: any) => any[];
  softFail?: boolean;
}): Promise<{ cases: any[]; message: string }> {
  let pageToken = "";
  const cases: any[] = [];
  let lastMessage = "";

  for (let page = 0; page < args.maxPages; page++) {
    const apiPayload = {
      page_size: args.pageSize,
      page_token: pageToken || undefined,
      create_time_ge: args.sinceUnix,
      create_time_lt: args.untilUnix,
      update_time_ge: args.sinceUnix,
      update_time_lt: args.untilUnix,
    };

    let apiResult: { path: string; json: any };
    try {
      apiResult = await tiktokRequestWithFallback({
        method: "POST",
        paths: args.paths,
        appKey: args.appKey,
        appSecret: args.appSecret,
        accessToken: args.accessToken,
        shopCipher: args.shopCipher,
        body: apiPayload,
      });
    } catch (err) {
      if (args.softFail) {
        return { cases, message: `optional path failed: ${err instanceof Error ? err.message : String(err)}` };
      }
      throw err;
    }

    const pageCases = args.collect(apiResult.json);
    lastMessage = `path=${apiResult.path}, cases=${pageCases.length}`;
    if (pageCases.length === 0 && page === 0) break;
    cases.push(...pageCases);

    const next = nextPageToken(apiResult.json);
    if (!next || next === pageToken) break;
    pageToken = next;
  }

  return { cases, message: lastMessage };
}

async function upsertCaseRowsIndividually(admin: any, rows: any[], label: string): Promise<{ saved: number; warnings: string[] }> {
  // Jangan bulk upsert di sini. TikTok kadang mengirim duplicate conflict key dalam satu response.
  // Bulk upsert akan error: "ON CONFLICT DO UPDATE command cannot affect row a second time".
  // v4 juga dibuat non-blocking: kalau ada 1 row malformed/duplicate aneh, row itu di-skip,
  // tapi Pull Orders tetap selesai. Operasional jangan tumbang cuma karena 1 event aftersales dobel.
  let saved = 0;
  const warnings: string[] = [];

  for (const row of rows || []) {
    const key = text(row?.case_item_key);
    if (!text(row?.tenant_id) || !text(row?.marketplace_account_id) || !key) continue;

    const { error } = await admin
      .from("marketplace_return_refund_cases")
      .upsert(row, { onConflict: "tenant_id,marketplace_account_id,case_item_key" });

    if (error) {
      warnings.push(`Skip ${label} case ${mask(key)}: ${error.message}`);
      continue;
    }

    saved += 1;
  }

  return { saved, warnings };
}

function buildCancellationRows(args: { tenantId: string; account: any; cases: any[] }) {
  const normalized = args.cases.map((rawCase) => ({
    ...rawCase,
    type: textDeep(rawCase, ["type", "cancel_type", "cancellation_type", "aftersale_type"]) || "cancel",
    status: textDeep(rawCase, ["status", "cancel_status", "cancellation_status", "request_status", "cancel_request_status"]) || "REQUESTED",
    return_type: textDeep(rawCase, ["type", "cancel_type", "cancellation_type"]) || "cancel",
    return_reason: textDeep(rawCase, ["cancel_reason", "cancellation_reason", "reason", "reason_text", "buyer_cancel_reason"]),
    refund_reason: textDeep(rawCase, ["cancel_reason", "cancellation_reason", "reason", "reason_text", "buyer_cancel_reason"]),
    buyer_note: textDeep(rawCase, ["buyer_note", "buyer_message", "message", "remark", "comment", "description"]),
  }));
  return buildCaseRows({ tenantId: args.tenantId, account: args.account, cases: normalized }).map((row) => ({
    ...row,
    case_type: text(row.case_type) || "cancel",
    case_status: text(row.case_status) || "REQUESTED",
    refund_status: null,
    return_status: null,
    last_error: text(row.last_error) || null,
  }));
}

function buildCaseRows(args: { tenantId: string; account: any; cases: any[] }) {
  const rows: any[] = [];
  for (const rawCase of args.cases) {
    const base = normalizeReturnCase(rawCase);
    const items = collectReturnCaseItems(rawCase);

    // Jangan bikin row item broad kalau TikTok hanya balikin case level tanpa item identifier.
    // Kalau dipaksakan, 1 return case akan dianggap berlaku ke semua item order. Itu bug yang bikin
    // monitor nampilin semua produk dalam pesanan padahal yang diretur cuma satu.
    const normalizedItems = items.length > 0 ? items : [rawCase];

    for (const item of normalizedItems) {
      const itemNorm = normalizeReturnItem(item);
      const externalReturnId = base.external_return_id || itemNorm.external_return_id || fallbackCaseId(rawCase, item);
      if (!externalReturnId) continue;

      const externalOrderId = base.external_order_id || itemNorm.external_order_id;
      const externalOrderItemId = itemNorm.external_order_item_id || base.external_order_item_id;
      const marketplaceSkuId = itemNorm.marketplace_sku_id || base.marketplace_sku_id;
      const sellerSku = itemNorm.seller_sku || base.seller_sku;
      const marketplaceProductId = itemNorm.marketplace_product_id || base.marketplace_product_id;

      const hasConcreteItemIdentifier = Boolean(
        text(externalOrderItemId) || text(marketplaceSkuId) || text(sellerSku) || text(marketplaceProductId)
      );

      // Dedupe penting: TikTok bisa mengirim item return yang sama lewat beberapa endpoint
      // atau event case yang berbeda. Untuk review stock, satu order item cukup muncul satu kali.
      // Kalau ada identifier item konkret, pakai key stabil berbasis order + item, bukan return_id.
      // return_id tetap disimpan untuk audit, tapi tidak dipakai sebagai pembeda utama.
      const stableItemIdentifier = externalOrderItemId || marketplaceSkuId || sellerSku || marketplaceProductId || "UNMATCHED_ITEM";
      const caseItemKey = hasConcreteItemIdentifier && externalOrderId
        ? [externalOrderId, stableItemIdentifier].join("::")
        : [externalReturnId, externalOrderId || "-", stableItemIdentifier].join("::");

      rows.push({
        tenant_id: args.tenantId,
        marketplace_account_id: args.account.marketplace_account_id,
        marketplace: args.account.marketplace || "tiktok_shop",
        external_return_id: externalReturnId,
        case_item_key: caseItemKey,
        external_order_id: externalOrderId,
        external_order_item_id: externalOrderItemId,
        marketplace_product_id: marketplaceProductId,
        marketplace_sku_id: marketplaceSkuId,
        seller_sku: sellerSku,
        product_name: itemNorm.product_name || base.product_name,
        variant_name: itemNorm.variant_name || base.variant_name,
        quantity: itemNorm.quantity || base.quantity || 0,
        case_type: base.case_type,
        case_status: base.case_status,
        refund_status: base.refund_status,
        return_status: base.return_status,
        return_reason: base.return_reason,
        refund_reason: base.refund_reason,
        buyer_note: base.buyer_note,
        return_tracking_number: base.return_tracking_number || itemNorm.return_tracking_number,
        logistics_provider: base.logistics_provider,
        requested_at: toIsoFromAny(base.requested_at),
        updated_at_marketplace: toIsoFromAny(base.updated_at_marketplace),
        raw_case: rawCase,
        // Row tanpa identifier tetap disimpan buat audit/debug, tapi SQL review tidak akan mapping ke semua item.
        review_status: hasConcreteItemIdentifier ? "pending" : "needs_item_identifier",
        last_error: hasConcreteItemIdentifier ? null : "Return/refund case tidak membawa item identifier. Tidak dibuat review item otomatis supaya tidak salah tampil semua SKU dalam order.",
        pulled_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      });
    }
  }
  return rows;
}


function dedupeCaseRows(rows: any[]) {
  // Supabase/Postgres upsert will throw:
  // "ON CONFLICT DO UPDATE command cannot affect row a second time"
  // when the same conflict key appears twice in one payload.
  // TikTok can return the same cancellation/return item more than once
  // through different nodes/endpoints, so dedupe before upsert.
  const byKey = new Map<string, any>();

  for (const row of rows || []) {
    const caseItemKey = text(row?.case_item_key);
    if (!caseItemKey) continue;

    const key = [
      text(row?.tenant_id),
      text(row?.marketplace_account_id),
      caseItemKey,
    ].join("::");

    const existing = byKey.get(key);
    if (!existing) {
      byKey.set(key, row);
      continue;
    }

    byKey.set(key, mergeCaseRows(existing, row));
  }

  return Array.from(byKey.values());
}

function mergeCaseRows(a: any, b: any) {
  const out = { ...a };

  for (const [key, value] of Object.entries(b || {})) {
    if (value === null || value === undefined || value === "") continue;

    if (key === "review_status") {
      const av = text(out[key]);
      const bv = text(value);
      if (av === "pending") continue;
      if (bv === "pending") out[key] = value;
      continue;
    }

    if (key === "raw_case") {
      out[key] = {
        previous: out[key],
        duplicate: value,
      };
      continue;
    }

    out[key] = value;
  }

  out.updated_at = new Date().toISOString();
  out.pulled_at = new Date().toISOString();
  return out;
}

function normalizeReturnCase(raw: any) {
  return {
    external_return_id: textDeep(raw, ["return_id", "return_sn", "return_order_id", "refund_id", "refund_sn", "reverse_order_id", "cancellation_id", "cancel_id", "cancel_order_id", "cancel_request_id", "request_id", "id", "aftersale_id"]),
    external_order_id: textDeep(raw, ["order_id", "order_sn", "ordersn", "order?.id", "order?.order_id", "order?.order_sn", "main_order_id", "parent_order_id"]),
    external_order_item_id: textDeep(raw, ["order_line_item_id", "order_item_id", "line_item_id", "return_line_item_id", "refund_line_item_id", "model_id", "item_id", "order_line?.id", "line_item?.id"]),
    marketplace_product_id: textDeep(raw, ["product_id", "item_id", "product?.id", "product?.product_id", "item?.product_id", "item?.item_id"]),
    marketplace_sku_id: textDeep(raw, ["sku_id", "model_id", "seller_sku_id", "product_sku_id", "sku?.id", "sku?.sku_id", "item?.sku_id", "item?.model_id", "return_item?.sku_id", "refund_item?.sku_id"]),
    seller_sku: textDeep(raw, ["seller_sku", "sku", "sku_code", "seller_sku_code", "model_sku", "item_sku", "sku?.seller_sku", "sku?.seller_sku_code", "item?.seller_sku", "item?.model_sku", "item?.item_sku"]),
    case_type: textDeep(raw, ["type", "return_type", "aftersale_type", "refund_type", "cancel_type", "cancellation_type"]),
    case_status: textDeep(raw, ["status", "case_status", "aftersale_status", "cancel_status", "cancellation_status", "request_status", "cancel_request_status"]),
    refund_status: textDeep(raw, ["refund_status", "refund?.status"]),
    return_status: textDeep(raw, ["return_status", "return?.status"]),
    return_reason: textDeep(raw, ["return_reason", "cancel_reason", "cancellation_reason", "reason", "return?.reason", "reason_text", "buyer_cancel_reason"]),
    refund_reason: textDeep(raw, ["refund_reason", "refund?.reason"]),
    buyer_note: textDeep(raw, ["buyer_note", "buyer_message", "description", "comment"]),
    return_tracking_number: textDeep(raw, ["return_tracking_number", "return_shipping_tracking_number", "tracking_number", "tracking_no", "return_logistics?.tracking_number", "logistics?.tracking_number"]),
    logistics_provider: textDeep(raw, ["logistics_provider", "shipping_carrier", "logistics?.provider_name", "return_logistics?.provider_name"]),
    requested_at: valueDeep(raw, ["create_time", "created_time", "request_time", "requested_at", "cancel_time", "cancel_request_time"]),
    updated_at_marketplace: valueDeep(raw, ["update_time", "updated_time", "latest_update_time"]),
    product_name: textDeep(raw, ["product_name", "item_name", "product?.name", "item?.product_name", "item?.item_name"]),
    variant_name: textDeep(raw, ["sku_name", "model_name", "variant_name", "sku?.name", "item?.sku_name", "item?.model_name"]),
    quantity: numberDeep(raw, ["quantity", "qty", "return_quantity", "refund_quantity", "model_quantity_purchased"]),
  };
}

function normalizeReturnItem(item: any) {
  return {
    external_return_id: textDeep(item, ["return_id", "return_sn", "return_order_id", "refund_id", "refund_sn", "reverse_order_id", "cancellation_id", "cancel_id", "cancel_order_id", "cancel_request_id", "request_id", "id"]),
    external_order_id: textDeep(item, ["order_id", "order_sn", "ordersn", "order?.id", "order?.order_sn", "main_order_id", "parent_order_id"]),
    external_order_item_id: textDeep(item, [
      "order_line_item_id", "order_item_id", "line_item_id", "return_line_item_id", "return_order_line_item_id",
      "refund_line_item_id", "refund_order_line_item_id", "model_id", "line_item?.id", "order_line?.id", "item_id"
    ]),
    marketplace_product_id: textDeep(item, ["product_id", "item_id", "product?.id", "product?.product_id", "item?.product_id", "item?.item_id"]),
    marketplace_sku_id: textDeep(item, ["sku_id", "model_id", "seller_sku_id", "product_sku_id", "sku?.id", "sku?.sku_id", "item?.sku_id", "item?.model_id"]),
    seller_sku: textDeep(item, ["seller_sku", "sku", "sku_code", "seller_sku_code", "shop_sku", "model_sku", "item_sku", "sku?.seller_sku", "sku?.seller_sku_code", "item?.model_sku", "item?.item_sku"]),
    product_name: textDeep(item, ["product_name", "item_name", "product?.name", "name", "item?.product_name", "item?.item_name"]),
    variant_name: textDeep(item, ["sku_name", "model_name", "variant_name", "sku?.name", "item?.sku_name", "item?.model_name"]),
    quantity: numberDeep(item, ["quantity", "qty", "return_quantity", "refund_quantity", "return_qty", "refund_qty", "model_quantity_purchased"]),
    return_tracking_number: textDeep(item, ["return_tracking_number", "return_shipping_tracking_number", "tracking_number", "tracking_no", "logistics?.tracking_number"]),
  };
}

function collectReturnCases(jsonRes: any): any[] {
  const data = jsonRes?.data ?? jsonRes?.response?.data ?? jsonRes?.response ?? jsonRes;
  const candidates = [
    data?.returns,
    data?.return_orders,
    data?.return_order_list,
    data?.return_list,
    data?.refunds,
    data?.refund_order_list,
    data?.refund_list,
    data?.return_refunds,
    data?.list,
    data?.items,
    data?.data?.returns,
    data?.data?.list,
  ];
  for (const candidate of candidates) {
    if (Array.isArray(candidate)) return candidate;
  }
  return [];
}


function collectCancellationCases(jsonRes: any): any[] {
  const data = jsonRes?.data ?? jsonRes?.response?.data ?? jsonRes?.response ?? jsonRes;
  const candidates = [
    data?.cancellations,
    data?.cancel_orders,
    data?.cancellation_orders,
    data?.cancel_list,
    data?.cancellation_list,
    data?.list,
    data?.items,
    data?.data?.cancellations,
    data?.data?.list,
  ];
  for (const candidate of candidates) {
    if (Array.isArray(candidate)) return candidate;
  }
  return [];
}

function collectReturnCaseItems(raw: any): any[] {
  const candidates = [
    raw?.items,
    raw?.line_items,
    raw?.order_line_items,
    raw?.return_items,
    raw?.return_line_items,
    raw?.return_order_items,
    raw?.return_order_line_items,
    raw?.refund_items,
    raw?.refund_line_items,
    raw?.refund_order_items,
    raw?.skus,
    raw?.products,
    raw?.return?.items,
    raw?.return?.line_items,
    raw?.refund?.items,
    raw?.refund?.line_items,
    raw?.order?.items,
    raw?.order?.line_items,
    raw?.package_list,
    raw?.packages,
  ];

  const out: any[] = [];
  for (const candidate of candidates) {
    if (!Array.isArray(candidate)) continue;
    for (const entry of candidate) {
      const nested = [entry?.items, entry?.line_items, entry?.return_items, entry?.refund_items, entry?.skus, entry?.products]
        .find((x) => Array.isArray(x));
      if (Array.isArray(nested)) out.push(...nested);
      else out.push(entry);
    }
  }

  // Hilangkan item duplikat yang kadang muncul di beberapa node response.
  const seen = new Set<string>();
  return out.filter((item) => {
    const norm = normalizeReturnItem(item);
    const key = [norm.external_order_item_id, norm.marketplace_sku_id, norm.seller_sku, norm.marketplace_product_id, JSON.stringify(item).slice(0, 120)].join("|");
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function nextPageToken(jsonRes: any): string {
  const data = jsonRes?.data ?? jsonRes?.response?.data ?? jsonRes?.response ?? jsonRes;
  return text(data?.next_page_token) || text(data?.next_page_token_id) || text(data?.page_token) || "";
}

function collectShopeeOrders(jsonRes: any): any[] {
  const data = jsonRes?.response ?? jsonRes?.data ?? jsonRes;
  const candidates = [
    data?.orders,
    data?.order_list,
    data?.list,
    data?.items,
  ];
  for (const candidate of candidates) {
    if (Array.isArray(candidate)) return candidate;
  }
  return [];
}

function nextShopeeCursor(jsonRes: any): string {
  const data = jsonRes?.response ?? jsonRes?.data ?? jsonRes;
  if (data?.more === false || data?.has_more === false) return "";
  return text(data?.next_cursor) || text(data?.cursor) || text(data?.next_page_token) || "";
}

async function refreshShopeeAccessTokenIfNeeded(admin: any, account: any, force = false): Promise<{ account: any; accessToken: string }> {
  const tokenSecret = requiredEnv("MARKETPLACE_TOKEN_ENCRYPTION_KEY");
  const currentAccessToken = await decryptText(text(account.access_token_encrypted), tokenSecret);
  if (!currentAccessToken) throw new Error("Shopee access token kosong. Reconnect account dulu.");

  const expiredAtMs = account.access_token_expired_at ? new Date(account.access_token_expired_at).getTime() : 0;
  const safeUntilMs = Date.now() + 10 * 60 * 1000;
  if (!force && expiredAtMs > safeUntilMs) return { account, accessToken: currentAccessToken };

  const refreshToken = await decryptText(text(account.refresh_token_encrypted), tokenSecret);
  if (!refreshToken) throw new Error("Refresh token Shopee kosong. Reconnect Shopee diperlukan.");

  const credential = resolveShopeeCredentials(account.environment);
  const shopId = text(account.shop_id);
  if (!shopId) throw new Error("Shopee shop_id kosong. Reconnect Shopee diperlukan.");

  const path = "/api/v2/auth/access_token/get";
  const payload = {
    partner_id: Number(credential.partnerId),
    refresh_token: refreshToken,
    shop_id: numericOrString(shopId),
  };
  const response = await shopeeRequest({
    method: "POST",
    account,
    path,
    credential,
    body: payload,
    authless: true,
  });

  const data = response?.response ?? response ?? {};
  const newAccessToken = text(data.access_token);
  const newRefreshToken = text(data.refresh_token) || refreshToken;
  if (!newAccessToken) {
    throw new Error(`Refresh token Shopee gagal: response tidak berisi access_token. ${JSON.stringify(maskTokenObject(response))}`);
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
    .select("marketplace_account_id, tenant_id, marketplace, app_key, shop_id, shop_cipher, shop_region, shop_name, store_alias, status, environment, access_token_encrypted, refresh_token_encrypted, access_token_expired_at, refresh_token_expired_at, raw_shop_response")
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
  if (!res.ok || !payload) throw new Error(`Shopee API HTTP ${res.status}: ${JSON.stringify(payload)}`);
  if (payload.error) throw new Error(`Shopee API error: ${JSON.stringify(maskTokenObject(payload))}`);
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

async function tiktokRequestWithFallback(args: {
  method: "POST";
  paths: string[];
  appKey: string;
  appSecret: string;
  accessToken: string;
  shopCipher?: string;
  body: Record<string, unknown>;
}) {
  const errors: string[] = [];
  for (const path of args.paths) {
    try {
      const jsonRes = await tiktokRequest({ ...args, path });
      return { path, json: jsonRes };
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      errors.push(`${path}: ${msg}`);
      // Auth errors should not hide behind fallback endpoint attempts.
      if (isTikTokAuthError(msg)) throw err;
    }
  }
  throw new Error(`Semua endpoint TikTok return/refund gagal. Detail: ${errors.join(" | ")}`);
}

async function tiktokRequest(args: {
  method: "POST";
  path: string;
  appKey: string;
  appSecret: string;
  accessToken: string;
  shopCipher?: string;
  body: Record<string, unknown>;
}) {
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const params: Record<string, string> = {
    app_key: args.appKey,
    timestamp,
  };

  if (args.shopCipher) params.shop_cipher = args.shopCipher;
  const bodyString = JSON.stringify(args.body || {});
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
    body: bodyString,
  });

  const jsonRes = await res.json().catch(() => null);
  if (!res.ok || !jsonRes) throw new Error(`TikTok API HTTP ${res.status}: ${JSON.stringify(jsonRes)}`);

  const code = jsonRes.code;
  if (code !== undefined && String(code) !== "0" && String(code).toLowerCase() !== "success") {
    throw new Error(`TikTok API error: ${JSON.stringify(maskTokenObject(jsonRes))}`);
  }
  return jsonRes;
}

async function refreshTikTokAccessTokenIfNeeded(admin: any, account: any, force = false): Promise<{ account: any; accessToken: string }> {
  const tokenSecret = requiredEnv("MARKETPLACE_TOKEN_ENCRYPTION_KEY");
  const currentAccessToken = await decryptText(text(account.access_token_encrypted), tokenSecret);
  if (!currentAccessToken) throw new Error("TikTok access token kosong. Reconnect account dulu.");

  const expiredAtMs = account.access_token_expired_at ? new Date(account.access_token_expired_at).getTime() : 0;
  const safeUntilMs = Date.now() + 10 * 60 * 1000;
  if (!force && expiredAtMs > safeUntilMs) return { account, accessToken: currentAccessToken };

  const refreshToken = await decryptText(text(account.refresh_token_encrypted), tokenSecret);
  if (!refreshToken) throw new Error("Refresh token TikTok kosong. Reconnect TikTok Shop diperlukan.");

  const appKey = text(account.app_key) || requiredEnv("TIKTOK_APP_KEY");
  const appSecret = requiredEnv("TIKTOK_APP_SECRET");
  const refreshUrl = new URL("https://auth.tiktok-shops.com/api/v2/token/refresh");
  refreshUrl.searchParams.set("app_key", appKey);
  refreshUrl.searchParams.set("app_secret", appSecret);
  refreshUrl.searchParams.set("refresh_token", refreshToken);
  refreshUrl.searchParams.set("grant_type", "refresh_token");

  const res = await fetch(refreshUrl.toString(), { method: "GET", headers: { accept: "application/json" } });
  const payload = await res.json().catch(() => null);
  if (!res.ok || !payload || (payload.code !== undefined && String(payload.code) !== "0" && String(payload.code).toLowerCase() !== "success")) {
    throw new Error(`Refresh token TikTok gagal. Reconnect diperlukan. Detail: ${JSON.stringify(maskTokenObject(payload))}`);
  }

  const data = payload.data ?? payload;
  const newAccessToken = text(data.access_token);
  const newRefreshToken = text(data.refresh_token) || refreshToken;
  if (!newAccessToken) throw new Error(`Response refresh token TikTok tidak berisi access_token: ${JSON.stringify(maskTokenObject(payload))}`);

  const accessExpiredAt = expireValueToIso(data.access_token_expire_in)
    || expireValueToIso(data.access_token_expired_at)
    || new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
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
    .select("marketplace_account_id, tenant_id, marketplace, app_key, shop_id, shop_cipher, shop_region, shop_name, store_alias, status, access_token_encrypted, refresh_token_encrypted, access_token_expired_at, refresh_token_expired_at, raw_shop_response")
    .single();

  if (error) throw new Error(`Simpan refresh token TikTok gagal: ${error.message}`);
  return { account: updated, accessToken: newAccessToken };
}

function isTikTokAuthError(message: string): boolean {
  const m = String(message).toLowerCase();
  return m.includes("105001") || m.includes("access token is invalid") || m.includes("invalid access token") || m.includes("401");
}

function isShopeeAuthError(err: unknown): boolean {
  const message = String(err).toLowerCase();
  return message.includes("invalid_acceess_token")
    || message.includes("invalid_access_token")
    || message.includes("access_token")
    || message.includes("401")
    || message.includes("error_auth");
}

function detectShopCipher(account: any): string | null {
  const direct = text(account.shop_cipher);
  if (direct) return direct;
  const raw = account.raw_shop_response;
  const data = raw?.response?.data ?? raw?.data ?? raw;
  const arrays = [data?.shops, data?.shop_list, data?.authorized_shops, data?.shops_list];
  for (const arr of arrays) {
    if (!Array.isArray(arr)) continue;
    for (const shop of arr) {
      const cipher = text(shop?.cipher) || text(shop?.shop_cipher) || text(shop?.shopCipher);
      if (cipher) return cipher;
    }
  }
  return null;
}

async function signTikTokRequest(path: string, params: Record<string, string>, bodyString: string, secret: string): Promise<string> {
  const sortedKeys = Object.keys(params).filter((key) => key !== "sign" && key !== "access_token").sort();
  let base = path;
  for (const key of sortedKeys) base += `${key}${params[key]}`;
  if (bodyString) base += bodyString;
  return hmacHex(secret, `${secret}${base}${secret}`);
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
  return [...new Uint8Array(signature)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function encryptText(plainText: string, secret: string): Promise<string> {
  const encoder = new TextEncoder();
  const keyHash = await crypto.subtle.digest("SHA-256", encoder.encode(secret));
  const key = await crypto.subtle.importKey("raw", keyHash, { name: "AES-GCM" }, false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, encoder.encode(plainText));
  return `aesgcm:${toBase64(iv)}:${toBase64(new Uint8Array(encrypted))}`;
}

async function decryptText(encryptedText: string, secret: string): Promise<string> {
  if (!encryptedText) return "";
  const keyMaterial = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret));
  const key = await crypto.subtle.importKey("raw", keyMaterial, "AES-GCM", false, ["decrypt"]);

  if (encryptedText.startsWith("aesgcm:")) {
    const parts = encryptedText.split(":");
    const ivB64 = parts[1];
    const dataB64 = parts[2];
    if (!ivB64 || !dataB64) throw new Error("Format token marketplace tidak valid. Reconnect toko dulu.");
    const decrypted = await crypto.subtle.decrypt({ name: "AES-GCM", iv: base64ToBytes(ivB64) }, key, base64ToBytes(dataB64));
    return new TextDecoder().decode(decrypted);
  }

  if (encryptedText.includes(".")) {
    const [ivB64, dataB64] = encryptedText.split(".");
    const decrypted = await crypto.subtle.decrypt({ name: "AES-GCM", iv: base64UrlToBytes(ivB64) }, key, base64UrlToBytes(dataB64));
    return new TextDecoder().decode(decrypted);
  }

  return encryptedText;
}

function valueDeep(obj: any, paths: string[]): any {
  for (const path of paths) {
    const value = getPath(obj, path);
    if (value !== undefined && value !== null && value !== "") return value;
  }
  return null;
}

function textDeep(obj: any, paths: string[]): string | null {
  const value = valueDeep(obj, paths);
  return text(value) || null;
}

function numberDeep(obj: any, paths: string[]): number {
  const value = valueDeep(obj, paths);
  if (value === null || value === undefined || value === "") return 0;
  if (typeof value === "number") return Number.isFinite(value) ? value : 0;
  const parsed = Number(String(value).replace(/[^0-9.\-]/g, ""));
  return Number.isFinite(parsed) ? parsed : 0;
}

function getPath(obj: any, path: string): any {
  if (!obj) return undefined;
  const parts = path.replace(/\?\./g, ".").split(".");
  let current = obj;
  for (const part of parts) {
    if (!part) continue;
    current = current?.[part];
    if (current === undefined || current === null) return current;
  }
  return current;
}

function fallbackCaseId(rawCase: any, item: any): string {
  const order = textDeep(rawCase, ["order_id", "order_sn"]) || textDeep(item, ["order_id", "order_sn"]) || "unknown_order";
  const sku = textDeep(item, ["order_line_item_id", "sku_id", "seller_sku", "id"]) || "case";
  return `${order}:${sku}:${textDeep(rawCase, ["status", "return_status", "refund_status"]) || "return_refund"}`;
}

function expireValueToIso(value: unknown): string | null {
  if (value === null || value === undefined || value === "") return null;
  const n = Number(value);
  if (!Number.isFinite(n)) {
    const d = new Date(String(value));
    return Number.isNaN(d.getTime()) ? null : d.toISOString();
  }
  // TikTok sometimes returns seconds from now, sometimes unix seconds.
  if (n > 2_000_000_000) return new Date(n * 1000).toISOString();
  return new Date(Date.now() + n * 1000).toISOString();
}

function toIsoFromAny(value: unknown): string | null {
  if (value === null || value === undefined || value === "") return null;
  const n = Number(value);
  if (Number.isFinite(n)) {
    if (n > 2_000_000_000_000) return new Date(n).toISOString();
    if (n > 1_000_000_000) return new Date(n * 1000).toISOString();
  }
  const d = new Date(String(value));
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

function maskTokenObject(obj: unknown): unknown {
  if (!obj || typeof obj !== "object") return obj;
  if (Array.isArray(obj)) return obj.map(maskTokenObject);
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(obj as Record<string, unknown>)) {
    const lower = key.toLowerCase();
    if (lower.includes("token") || lower.includes("secret")) out[key] = "***masked***";
    else out[key] = maskTokenObject(value);
  }
  return out;
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Environment variable ${name} belum diset.`);
  return value;
}

async function safeJson(req: Request): Promise<any> {
  try {
    return await req.json();
  } catch (_) {
    return {};
  }
}

function text(value: unknown): string {
  if (value === null || value === undefined) return "";
  return String(value).trim();
}

function clampInt(value: unknown, min: number, max: number, fallback: number): number {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(min, Math.min(max, parsed));
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}

function base64ToBytes(input: string): Uint8Array {
  const binary = atob(input);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function base64UrlToBytes(input: string): Uint8Array {
  let base64 = input.replace(/-/g, "+").replace(/_/g, "/");
  while (base64.length % 4) base64 += "=";
  return base64ToBytes(base64);
}

function json(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "content-type": "application/json" },
  });
}
