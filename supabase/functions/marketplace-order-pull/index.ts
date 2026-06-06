import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const FUNCTION_VERSION = "marketplace-order-pull-v24-6-22-rotating-status-refresh-2026-05-23";

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
};

const STOCK_OUT_ELIGIBLE_STATUSES = new Set([
  "AWAITING_SHIPMENT",
  "READY_TO_SHIP",
  "PAID",
  "UNSHIPPED",
  "TO_SHIP",
  "PARTIALLY_SHIPPING",
  "ON_HOLD",
  "AWAITING_COLLECTION",
  "AWAITING_PICKUP",
  "READY_FOR_COLLECTION",
  "READY_FOR_PICKUP",
]);

const CANCEL_STATUSES = new Set([
  "CANCELLED",
  "CANCELED",
  "CANCEL",
  "IN_CANCEL",
  "TO_CANCEL",
  "CANCEL_REQUESTED",
]);

const ORDER_PULL_ALL_STATUSES = [
  "AWAITING_SHIPMENT",
  "READY_TO_SHIP",
  "PAID",
  "UNSHIPPED",
  "TO_SHIP",
  "PARTIALLY_SHIPPING",
  "ON_HOLD",
  "AWAITING_COLLECTION",
  "AWAITING_PICKUP",
  "READY_FOR_COLLECTION",
  "READY_FOR_PICKUP",
  "IN_TRANSIT",
  "SHIPPED",
  "DELIVERED",
  "COMPLETED",
  "CANCELLED",
  "CANCELED",
  "RETURNED",
  "RETURN_REFUND",
  "REFUND",
];

const FINAL_MARKETPLACE_ORDER_STATUSES = new Set([
  "COMPLETED",
  "DELIVERED",
]);

const PRESERVE_ITEM_ACTION_STATUSES = new Set([
  "reserved",
  "partial_scanned",
  "scanned_done",
  "stock_out_done",
  "stock_out_failed",
  "return_review_required",
  "cancel_review_required",
  "return_review_done",
  "return_not_restocked",
  "cancelled_released",
]);

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
    const marketplaceAccountId = text(body.marketplace_account_id);
    const action = text(body.action || body.mode).toLowerCase();
    const isStatusRefreshAction = action === "refresh_existing_status" || action === "status_refresh" || body.auto_status_only === true;
    const isAutoRunnerSource = text(body.source) === "marketplace-auto-runner" || body.auto_today_only === true || body.auto_status_only === true;
    const daysBack = isAutoRunnerSource ? 1 : clampInt(body.days_back, 1, 60, 1);
    let range = pullDateRangeFromBody(body, daysBack);
    if (isAutoRunnerSource) {
      range = todayWibSecondsRange();
    }
    const rangeDays = Math.ceil((range.endSeconds - range.startSeconds) / (24 * 60 * 60));
    if (rangeDays < 1) {
      return json({ ok: false, message: "Tanggal akhir tidak boleh sebelum tanggal awal." }, 400);
    }
    if (!isAutoRunnerSource && rangeDays > 60) {
      return json({ ok: false, message: "Maksimal periode pull order marketplace adalah 60 hari." }, 400);
    }

    const pageSize = clampInt(body.limit, 1, 50, 50);
    const maxPages = isAutoRunnerSource ? clampInt(body.max_pages, 1, 10, 8) : clampInt(body.max_pages, 1, 100, 20);
    const includeStatuslessSearch = body.include_statusless_search !== false;
    const includeUpdateTimeSearch = body.include_update_time_search !== false;
    const searchMode = text(body.search_mode).toLowerCase();
    const statuslessOnly = body.statusless_only === true || searchMode.includes("statusless");
    const maxDetails = clampInt(body.max_details, 1, isAutoRunnerSource ? 500 : 5000, Math.max(pageSize, pageSize * maxPages));
    const includePreviousUnpacked = isAutoRunnerSource ? false : body.include_previous_unpacked !== false;
    const previousUnpackedDays = isAutoRunnerSource ? 1 : clampInt(body.previous_unpacked_days, 1, 60, 14);
    const skipCompletedOrderPull = body.skip_completed_order_pull !== false;
    const requestedStatuses = Array.isArray(body.statuses)
      ? body.statuses.map((item: unknown) => text(item).toUpperCase()).filter(Boolean)
      : ORDER_PULL_ALL_STATUSES;

    if (!tenantId) return json({ ok: false, message: "tenant_id is required" }, 400);
    if (!marketplaceAccountId) return json({ ok: false, message: "marketplace_account_id is required" }, 400);

    const roleId = text(profile.role_id);
    const isSuperAdmin = roleId === "super_admin";
    const isDemoSuperAdmin = roleId === "demo_super_admin";

    if (!isSuperAdmin && !isDemoSuperAdmin && tenantId !== text(profile.tenant_id)) {
      return json({ ok: false, message: "Forbidden tenant access" }, 403);
    }
    if (isDemoSuperAdmin) {
      return json({ ok: false, message: "Demo account tidak boleh pull order marketplace production." }, 403);
    }

    const { data: account, error: accountError } = await admin
      .from("marketplace_accounts")
      .select("marketplace_account_id, tenant_id, marketplace, app_key, shop_id, shop_cipher, shop_region, shop_name, store_alias, status, environment, access_token_encrypted, refresh_token_encrypted, access_token_expired_at, refresh_token_expired_at, raw_shop_response")
      .eq("marketplace_account_id", marketplaceAccountId)
      .maybeSingle();

    if (accountError || !account) return json({ ok: false, message: accountError?.message || "Marketplace account not found" }, 404);
    if (account.tenant_id !== tenantId) return json({ ok: false, message: "Marketplace account tenant mismatch" }, 403);
    if (account.status !== "active") return json({ ok: false, message: "Marketplace account belum active." }, 400);

    if (!["tiktok_shop", "shopee"].includes(account.marketplace)) {
      return json({ ok: false, message: `Order pull untuk ${account.marketplace} belum didukung.` }, 400);
    }

    if (isStatusRefreshAction) {
      const statusRangeDays = clampInt(body.status_range_days || body.days_back, 1, 120, 60);
      const maxExistingOrders = clampInt(body.max_existing_orders || body.limit, 1, 200, 100);
      const skipCompletedStatusRefresh = body.skip_completed_status_refresh !== false;
      const result = account.marketplace === "shopee"
        ? await refreshExistingShopeeOrderStatuses(admin, account, { statusRangeDays, maxExistingOrders, skipCompletedStatusRefresh })
        : await refreshExistingTikTokOrderStatuses(admin, account, { statusRangeDays, maxExistingOrders, skipCompletedStatusRefresh });
      return json(result);
    }

    const pullArgs = {
      daysBack,
      startSeconds: range.startSeconds,
      endSeconds: range.endSeconds,
      pageSize,
      maxPages,
      statuses: requestedStatuses,
      includePreviousUnpacked,
      previousUnpackedDays,
      includeStatuslessSearch,
      includeUpdateTimeSearch,
      statuslessOnly,
      maxDetails,
      skipCompletedOrderPull,
    };
    const result = account.marketplace === "shopee"
      ? await pullShopeeOrders(admin, account, pullArgs)
      : await pullTikTokOrders(admin, account, pullArgs);

    return json(result);
  } catch (err) {
    const message = String(err);
    const status = message.includes("TikTok API") || message.includes("tenant") || message.includes("marketplace") ? 400 : 500;
    return json({ ok: false, message }, status);
  }
});


async function refreshExistingTikTokOrderStatuses(admin: any, account: any, args: { statusRangeDays: number; maxExistingOrders: number; skipCompletedStatusRefresh: boolean }) {
  const appKey = text(account.app_key) || requiredEnv("TIKTOK_APP_KEY");
  const appSecret = requiredEnv("TIKTOK_APP_SECRET");
  let tokenBundle = await refreshTikTokAccessTokenIfNeeded(admin, account);
  let activeAccount = tokenBundle.account;
  let accessToken = tokenBundle.accessToken;

  let shopCipher = detectShopCipher(activeAccount);
  let shopId = text(activeAccount.shop_id);

  if (!appKey) throw new Error("TIKTOK_APP_KEY kosong.");
  if (!accessToken) throw new Error("Access token TikTok kosong. Re-authorize toko dulu.");

  if (!shopCipher) {
    const authorizedShopsJson = await tiktokRequest({
      method: "GET",
      path: "/authorization/202309/shops",
      appKey,
      appSecret,
      accessToken,
      body: {},
    });
    const authorizedShop = pickAuthorizedShop(authorizedShopsJson, activeAccount, shopCipher);
    if (authorizedShop) {
      shopCipher = shopCipherValue(authorizedShop) || shopCipher;
      shopId = shopIdValue(authorizedShop) || shopId;
      await admin
        .from("marketplace_accounts")
        .update({
          shop_id: shopId,
          shop_cipher: shopCipher,
          shop_name: shopNameValue(authorizedShop) || activeAccount.shop_name,
          raw_shop_response: safeJsonForDb(authorizedShopsJson),
          last_error: null,
          updated_at: new Date().toISOString(),
        })
        .eq("marketplace_account_id", activeAccount.marketplace_account_id);
    }
  }

  if (!shopCipher) {
    throw new Error("shop_cipher TikTok belum valid. Re-authorize toko lalu ulangi refresh status order.");
  }

  const cutoffIso = new Date(Date.now() - Math.max(1, args.statusRangeDays) * 24 * 60 * 60 * 1000).toISOString();
  const preserveFinalStatuses = new Set([
    "return_review_done",
    "return_not_restocked",
    "cancelled_released",
  ]);

  let existingQuery = admin
    .from("marketplace_orders")
    .select("marketplace_order_id, external_order_id, order_sn, tracking_number, order_status, order_status_label, stock_action_status, order_created_at, order_updated_at, updated_at")
    .eq("tenant_id", activeAccount.tenant_id)
    .eq("marketplace_account_id", activeAccount.marketplace_account_id)
    .or(`order_created_at.gte.${cutoffIso},order_updated_at.gte.${cutoffIso},updated_at.gte.${cutoffIso}`);

  if (args.skipCompletedStatusRefresh) {
    existingQuery = existingQuery.or("order_status.is.null,order_status.not.in.(COMPLETED,DELIVERED)");
  }

  const { data: existingOrders, error: existingError } = await existingQuery
    // Rotasi order lama dulu. Setiap order yang dicek akan update pulled_at, jadi batch berikutnya bergerak ke order lain.
    .order("pulled_at", { ascending: true, nullsFirst: true })
    .order("updated_at", { ascending: true, nullsFirst: true })
    .limit(args.maxExistingOrders);

  if (existingError) throw new Error(`Load existing marketplace order gagal: ${existingError.message}`);

  let checked = 0;
  let updated = 0;
  let changedToReview = 0;
  let failed = 0;
  const warnings: string[] = [];
  let skippedCompleted = 0;

  for (const row of existingOrders || []) {
    const orderId = text(row.external_order_id) || text(row.order_sn);
    if (!orderId) continue;
    const currentOrderStatusUpper = text(row.order_status).toUpperCase();
    if (args.skipCompletedStatusRefresh && FINAL_MARKETPLACE_ORDER_STATUSES.has(currentOrderStatusUpper)) {
      skippedCompleted += 1;
      continue;
    }
    checked += 1;

    let detailOrder: any = null;
    try {
      const detailJson = await fetchTikTokOrderDetail({
        orderId,
        appKey,
        appSecret,
        accessToken,
        shopCipher,
        shopId,
      });
      detailOrder = normalizeDetailOrder(detailJson, { id: orderId }, orderId);
    } catch (e) {
      if (isTikTokAuthError(e)) {
        try {
          tokenBundle = await refreshTikTokAccessTokenIfNeeded(admin, activeAccount, true);
          activeAccount = tokenBundle.account;
          accessToken = tokenBundle.accessToken;
          const detailJson = await fetchTikTokOrderDetail({ orderId, appKey, appSecret, accessToken, shopCipher, shopId });
          detailOrder = normalizeDetailOrder(detailJson, { id: orderId }, orderId);
        } catch (retryError) {
          failed += 1;
          warnings.push(`Refresh status ${mask(orderId)} gagal: ${String(retryError)}`);
          continue;
        }
      } else {
        failed += 1;
        warnings.push(`Refresh status ${mask(orderId)} gagal: ${String(e)}`);
        continue;
      }
    }

    const normalizedOrder = normalizeOrder(detailOrder, activeAccount, orderId);
    const orderStatusUpper = text(normalizedOrder.order_status).toUpperCase();
    if (args.skipCompletedStatusRefresh && FINAL_MARKETPLACE_ORDER_STATUSES.has(orderStatusUpper)) {
      skippedCompleted += 1;
      continue;
    }

    const statusGroup = orderStatusGroup(orderStatusUpper);
    const hasActiveCancelRequest = isActiveCancelRequest(normalizedOrder.cancel_request_status);
    const isCancelNoStockAction = hasActiveCancelRequest && isAwaitingShipmentNoResi(
      normalizedOrder.order_status,
      normalizedOrder.tracking_number || row.tracking_number,
    );

    const existingOrderAction = text(row.stock_action_status);
    let nextStockActionStatus = existingOrderAction || "pending";
    let nextLastError: string | null = null;

    if (preserveFinalStatuses.has(existingOrderAction)) {
      nextStockActionStatus = existingOrderAction;
      nextLastError = null;
    } else if (isCancelNoStockAction) {
      nextStockActionStatus = "ignored_status";
      nextLastError = "Buyer cancel request saat AWAITING_SHIPMENT dan belum ada resi. Tidak perlu stock out/stock in.";
    } else if (hasActiveCancelRequest) {
      nextStockActionStatus = existingOrderAction === "stock_out_done" ? "return_review_required" : "cancel_review_required";
      nextLastError = "Status order berubah: buyer mengajukan cancel. Review sebelum proses lanjutan.";
    } else if (statusGroup === "cancelled") {
      nextStockActionStatus = existingOrderAction === "stock_out_done" ? "return_review_required" : "cancel_review_required";
      nextLastError = "Status marketplace berubah menjadi cancel. Review di Refund/Cancel Monitor.";
    } else if (statusGroup === "return_refund") {
      nextStockActionStatus = "return_review_required";
      nextLastError = "Status marketplace berubah menjadi refund/return. Review di Refund/Cancel Monitor.";
    } else if (STOCK_OUT_ELIGIBLE_STATUSES.has(orderStatusUpper) && (!existingOrderAction || existingOrderAction === "pending" || existingOrderAction === "ignored_status")) {
      nextStockActionStatus = "ready_to_pick";
      nextLastError = null;
    }

    const statusChanged = text(row.order_status).toUpperCase() !== orderStatusUpper
      || text(row.tracking_number) !== text(normalizedOrder.tracking_number || row.tracking_number)
      || nextStockActionStatus !== existingOrderAction;

    const now = new Date().toISOString();
    const updatePayload: Record<string, unknown> = {
      order_status: normalizedOrder.order_status || row.order_status,
      order_status_label: normalizedOrder.order_status_label || row.order_status_label,
      tracking_number: normalizedOrder.tracking_number || row.tracking_number,
      shipping_provider_name: normalizedOrder.shipping_provider_name,
      package_id: normalizedOrder.package_id,
      logistic_status: normalizedOrder.logistic_status,
      label_code: normalizedOrder.label_code || orderId,
      cancel_request_id: normalizedOrder.cancel_request_id,
      cancel_request_status: normalizedOrder.cancel_request_status,
      cancel_request_reason: normalizedOrder.cancel_request_reason,
      cancel_request_note: normalizedOrder.cancel_request_note,
      cancel_requested_at: normalizedOrder.cancel_requested_at,
      cancel_request_raw: normalizedOrder.cancel_request_raw,
      cancel_request_pulled_at: normalizedOrder.cancel_request_status ? now : null,
      has_cancel_request: hasActiveCancelRequest,
      stock_action_status: nextStockActionStatus,
      last_error: nextLastError,
      order_updated_at: normalizedOrder.order_updated_at || row.order_updated_at,
      raw_order: normalizedOrder.raw_order,
      pulled_at: now,
      updated_at: now,
    };

    const { error: updateError } = await admin
      .from("marketplace_orders")
      .update(updatePayload)
      .eq("marketplace_order_id", row.marketplace_order_id)
      .eq("tenant_id", activeAccount.tenant_id);

    if (updateError) {
      failed += 1;
      warnings.push(`Update status ${mask(orderId)} gagal: ${updateError.message}`);
      continue;
    }

    if (statusChanged) updated += 1;

    if (nextStockActionStatus === "cancel_review_required" || nextStockActionStatus === "return_review_required" || nextStockActionStatus === "ignored_status") {
      changedToReview += 1;
      await syncOrderItemsStatusFromOrder(admin, activeAccount, row.marketplace_order_id, {
        trackingNumber: normalizedOrder.tracking_number || row.tracking_number,
        packageId: normalizedOrder.package_id,
        nextStockActionStatus,
        lastError: nextLastError,
      });
    } else if (normalizedOrder.tracking_number || normalizedOrder.package_id) {
      await admin
        .from("marketplace_order_items")
        .update({
          tracking_number: normalizedOrder.tracking_number || row.tracking_number,
          package_id: normalizedOrder.package_id,
          updated_at: now,
        })
        .eq("tenant_id", activeAccount.tenant_id)
        .eq("marketplace_order_id", row.marketplace_order_id);
    }
  }

  await admin
    .from("marketplace_accounts")
    .update({
      last_error: warnings.length > 0 ? warnings.slice(0, 3).join(" | ") : null,
      updated_at: new Date().toISOString(),
    })
    .eq("marketplace_account_id", activeAccount.marketplace_account_id);

  return {
    ok: true,
    marketplace: "tiktok_shop",
    mode: "status_refresh_existing_orders",
    checked,
    updated,
    skipped_completed: skippedCompleted,
    review_required: changedToReview,
    failed,
    warning_count: warnings.length,
    warnings: warnings.slice(0, 8),
    message: `Refresh status order selesai: dicek=${checked}, berubah=${updated}, perlu review=${changedToReview}, gagal=${failed}.`,
  };
}

async function syncOrderItemsStatusFromOrder(admin: any, account: any, marketplaceOrderId: string, args: { trackingNumber: string | null; packageId: string | null; nextStockActionStatus: string; lastError: string | null }) {
  const { data: items, error } = await admin
    .from("marketplace_order_items")
    .select("marketplace_order_item_id, stock_action_status")
    .eq("tenant_id", account.tenant_id)
    .eq("marketplace_order_id", marketplaceOrderId);

  if (error) return;

  const preserve = new Set(["return_review_done", "return_not_restocked", "cancelled_released"]);
  const now = new Date().toISOString();
  for (const item of items || []) {
    const current = text(item.stock_action_status);
    const next = preserve.has(current) ? current : args.nextStockActionStatus;
    await admin
      .from("marketplace_order_items")
      .update({
        tracking_number: args.trackingNumber,
        package_id: args.packageId,
        stock_action_status: next,
        last_error: preserve.has(current) ? null : args.lastError,
        updated_at: now,
      })
      .eq("marketplace_order_item_id", item.marketplace_order_item_id)
      .eq("tenant_id", account.tenant_id);
  }
}

async function refreshExistingShopeeOrderStatuses(admin: any, account: any, args: { statusRangeDays: number; maxExistingOrders: number; skipCompletedStatusRefresh: boolean }) {
  let tokenBundle = await refreshShopeeAccessTokenIfNeeded(admin, account);
  let activeAccount = tokenBundle.account;
  let accessToken = tokenBundle.accessToken;

  const cutoffIso = new Date(Date.now() - Math.max(1, args.statusRangeDays) * 24 * 60 * 60 * 1000).toISOString();
  const preserveFinalStatuses = new Set([
    "return_review_done",
    "return_not_restocked",
    "cancelled_released",
  ]);

  let existingQuery = admin
    .from("marketplace_orders")
    .select("marketplace_order_id, external_order_id, order_sn, tracking_number, order_status, order_status_label, stock_action_status, order_created_at, order_updated_at, updated_at")
    .eq("tenant_id", activeAccount.tenant_id)
    .eq("marketplace_account_id", activeAccount.marketplace_account_id)
    .or(`order_created_at.gte.${cutoffIso},order_updated_at.gte.${cutoffIso},updated_at.gte.${cutoffIso}`);

  if (args.skipCompletedStatusRefresh) {
    existingQuery = existingQuery.or("order_status.is.null,order_status.not.in.(COMPLETED,DELIVERED)");
  }

  const { data: existingOrders, error: existingError } = await existingQuery
    .order("pulled_at", { ascending: true, nullsFirst: true })
    .order("updated_at", { ascending: true, nullsFirst: true })
    .limit(args.maxExistingOrders);

  if (existingError) throw new Error(`Load existing Shopee order gagal: ${existingError.message}`);

  let checked = 0;
  let updated = 0;
  let changedToReview = 0;
  let failed = 0;
  let skippedCompleted = 0;
  const warnings: string[] = [];

  for (const row of existingOrders || []) {
    const orderId = text(row.external_order_id) || text(row.order_sn);
    if (!orderId) continue;

    const currentOrderStatusUpper = text(row.order_status).toUpperCase();
    if (args.skipCompletedStatusRefresh && FINAL_MARKETPLACE_ORDER_STATUSES.has(currentOrderStatusUpper)) {
      skippedCompleted += 1;
      continue;
    }

    checked += 1;
    let detailOrder: any = null;
    try {
      const detailJson = await fetchShopeeOrderDetail({ account: activeAccount, accessToken, orderIds: [orderId] });
      detailOrder = normalizeDetailOrder(detailJson, { order_sn: orderId }, orderId);
    } catch (e) {
      if (isShopeeAuthError(e)) {
        try {
          tokenBundle = await refreshShopeeAccessTokenIfNeeded(admin, activeAccount, true);
          activeAccount = tokenBundle.account;
          accessToken = tokenBundle.accessToken;
          const detailJson = await fetchShopeeOrderDetail({ account: activeAccount, accessToken, orderIds: [orderId] });
          detailOrder = normalizeDetailOrder(detailJson, { order_sn: orderId }, orderId);
        } catch (retryError) {
          failed += 1;
          warnings.push(`Refresh status Shopee ${mask(orderId)} gagal: ${String(retryError)}`);
          continue;
        }
      } else {
        failed += 1;
        warnings.push(`Refresh status Shopee ${mask(orderId)} gagal: ${String(e)}`);
        continue;
      }
    }

    const normalizedOrder = normalizeOrder(detailOrder, activeAccount, orderId);
    const orderStatusUpper = text(normalizedOrder.order_status).toUpperCase();
    if (args.skipCompletedStatusRefresh && FINAL_MARKETPLACE_ORDER_STATUSES.has(orderStatusUpper)) {
      skippedCompleted += 1;
      continue;
    }

    const statusGroup = orderStatusGroup(orderStatusUpper);
    const hasActiveCancelRequest = isActiveCancelRequest(normalizedOrder.cancel_request_status);
    const isCancelNoStockAction = hasActiveCancelRequest && isAwaitingShipmentNoResi(
      normalizedOrder.order_status,
      normalizedOrder.tracking_number || row.tracking_number,
    );

    const existingOrderAction = text(row.stock_action_status);
    let nextStockActionStatus = existingOrderAction || "pending";
    let nextLastError: string | null = null;

    if (preserveFinalStatuses.has(existingOrderAction)) {
      nextStockActionStatus = existingOrderAction;
      nextLastError = null;
    } else if (isCancelNoStockAction) {
      nextStockActionStatus = "ignored_status";
      nextLastError = "Buyer cancel request Shopee saat belum ada resi. Tidak perlu stock out/stock in.";
    } else if (hasActiveCancelRequest) {
      nextStockActionStatus = existingOrderAction === "stock_out_done" ? "return_review_required" : "cancel_review_required";
      nextLastError = "Status order Shopee berubah: buyer mengajukan cancel. Review sebelum proses lanjutan.";
    } else if (statusGroup === "cancelled") {
      nextStockActionStatus = existingOrderAction === "stock_out_done" ? "return_review_required" : "cancel_review_required";
      nextLastError = "Status Shopee berubah menjadi cancel. Review di Refund/Cancel Monitor.";
    } else if (statusGroup === "return_refund") {
      nextStockActionStatus = "return_review_required";
      nextLastError = "Status Shopee berubah menjadi refund/return. Review di Refund/Cancel Monitor.";
    } else if (STOCK_OUT_ELIGIBLE_STATUSES.has(orderStatusUpper) && (!existingOrderAction || existingOrderAction === "pending" || existingOrderAction === "ignored_status")) {
      nextStockActionStatus = "ready_to_pick";
      nextLastError = null;
    }

    const statusChanged = text(row.order_status).toUpperCase() !== orderStatusUpper
      || text(row.tracking_number) !== text(normalizedOrder.tracking_number || row.tracking_number)
      || nextStockActionStatus !== existingOrderAction;

    const now = new Date().toISOString();
    const { error: updateError } = await admin
      .from("marketplace_orders")
      .update({
        order_status: normalizedOrder.order_status || row.order_status,
        order_status_label: normalizedOrder.order_status_label || row.order_status_label,
        tracking_number: normalizedOrder.tracking_number || row.tracking_number,
        shipping_provider_name: normalizedOrder.shipping_provider_name,
        package_id: normalizedOrder.package_id,
        logistic_status: normalizedOrder.logistic_status,
        label_code: normalizedOrder.label_code || orderId,
        cancel_request_id: normalizedOrder.cancel_request_id,
        cancel_request_status: normalizedOrder.cancel_request_status,
        cancel_request_reason: normalizedOrder.cancel_request_reason,
        cancel_request_note: normalizedOrder.cancel_request_note,
        cancel_requested_at: normalizedOrder.cancel_requested_at,
        cancel_request_raw: normalizedOrder.cancel_request_raw,
        cancel_request_pulled_at: normalizedOrder.cancel_request_status ? now : null,
        has_cancel_request: hasActiveCancelRequest,
        stock_action_status: nextStockActionStatus,
        last_error: nextLastError,
        order_updated_at: normalizedOrder.order_updated_at || row.order_updated_at,
        raw_order: normalizedOrder.raw_order,
        pulled_at: now,
        updated_at: now,
      })
      .eq("marketplace_order_id", row.marketplace_order_id)
      .eq("tenant_id", activeAccount.tenant_id);

    if (updateError) {
      failed += 1;
      warnings.push(`Update status Shopee ${mask(orderId)} gagal: ${updateError.message}`);
      continue;
    }

    if (statusChanged) updated += 1;

    if (nextStockActionStatus === "cancel_review_required" || nextStockActionStatus === "return_review_required" || nextStockActionStatus === "ignored_status") {
      changedToReview += 1;
      await syncOrderItemsStatusFromOrder(admin, activeAccount, row.marketplace_order_id, {
        trackingNumber: normalizedOrder.tracking_number || row.tracking_number,
        packageId: normalizedOrder.package_id,
        nextStockActionStatus,
        lastError: nextLastError,
      });
    } else if (normalizedOrder.tracking_number || normalizedOrder.package_id) {
      await admin
        .from("marketplace_order_items")
        .update({
          tracking_number: normalizedOrder.tracking_number || row.tracking_number,
          package_id: normalizedOrder.package_id,
          updated_at: now,
        })
        .eq("tenant_id", activeAccount.tenant_id)
        .eq("marketplace_order_id", row.marketplace_order_id);
    }
  }

  await admin
    .from("marketplace_accounts")
    .update({
      last_error: warnings.length > 0 ? warnings.slice(0, 3).join(" | ") : null,
      updated_at: new Date().toISOString(),
    })
    .eq("marketplace_account_id", activeAccount.marketplace_account_id);

  return {
    ok: true,
    marketplace: "shopee",
    mode: "status_refresh_existing_orders",
    checked,
    updated,
    skipped_completed: skippedCompleted,
    review_required: changedToReview,
    failed,
    warning_count: warnings.length,
    warnings: warnings.slice(0, 8),
    message: `Refresh status Shopee selesai: dicek=${checked}, berubah=${updated}, perlu review=${changedToReview}, gagal=${failed}.`,
  };
}

async function pullShopeeOrders(admin: any, account: any, args: { daysBack: number; startSeconds: number; endSeconds: number; pageSize: number; maxPages: number; statuses: string[]; includePreviousUnpacked: boolean; previousUnpackedDays: number; includeStatuslessSearch: boolean; includeUpdateTimeSearch: boolean; statuslessOnly: boolean; maxDetails: number; skipCompletedOrderPull: boolean }) {
  let tokenBundle = await refreshShopeeAccessTokenIfNeeded(admin, account);
  let activeAccount = tokenBundle.account;
  let accessToken = tokenBundle.accessToken;

  const todayStartWib = startOfTodayWibSeconds();
  const normalSinceSeconds = args.startSeconds;
  const previousUnpackedSinceSeconds = Math.floor(Date.now() / 1000) - args.previousUnpackedDays * 24 * 60 * 60;
  const sinceSeconds = args.includePreviousUnpacked ? Math.min(normalSinceSeconds, previousUnpackedSinceSeconds) : normalSinceSeconds;
  const maxOrders = Math.max(1, Math.min(args.maxDetails, Math.max(args.pageSize, args.pageSize * args.maxPages)));
  const timeFields = args.includeUpdateTimeSearch ? ["create_time", "update_time"] : ["create_time"];
  const shopeeStatuses = args.statuslessOnly ? [null] : uniqueStrings([
    ...args.statuses.map(toShopeeOrderStatus).filter(Boolean),
    null,
  ]);
  const ranges = buildShopeeTimeRanges(sinceSeconds, args.endSeconds);

  let searchedPages = 0;
  const searchOrdersAll: any[] = [];
  const seenOrderIds = new Set<string>();
  const warnings: string[] = [];

  for (const range of ranges) {
    for (const timeField of timeFields) {
      for (const status of shopeeStatuses) {
        let cursor = "";
        for (let pageIndex = 0; pageIndex < args.maxPages && searchOrdersAll.length < maxOrders; pageIndex += 1) {
          try {
            const listJson = await fetchShopeeOrderListPage({
              account: activeAccount,
              accessToken,
              timeFrom: range.start,
              timeTo: range.end,
              timeRangeField: timeField,
              pageSize: args.pageSize,
              cursor,
              orderStatus: status,
            });

            searchedPages += 1;
            const pageOrders = collectOrders(listJson);
            for (const candidate of pageOrders) {
              const oid = orderIdValue(candidate);
              if (!oid || seenOrderIds.has(oid)) continue;
              seenOrderIds.add(oid);
              searchOrdersAll.push(candidate);
              if (searchOrdersAll.length >= maxOrders) break;
            }

            cursor = extractShopeeNextCursor(listJson);
            if (!cursor || pageOrders.length === 0) break;
          } catch (e) {
            if (isShopeeAuthError(e)) {
              tokenBundle = await refreshShopeeAccessTokenIfNeeded(admin, activeAccount, true);
              activeAccount = tokenBundle.account;
              accessToken = tokenBundle.accessToken;
              pageIndex -= 1;
              continue;
            }
            warnings.push(`Shopee order list gagal (${timeField}${status ? `/${status}` : ""}): ${String(e)}`);
            break;
          }
        }
        if (searchOrdersAll.length >= maxOrders) break;
      }
      if (searchOrdersAll.length >= maxOrders) break;
    }
    if (searchOrdersAll.length >= maxOrders) break;
  }

  const searchOrders = searchOrdersAll.slice(0, maxOrders);
  let importedOrders = 0;
  let importedItems = 0;
  let mappedItems = 0;
  let unmappedItems = 0;
  let skippedCompletedOrders = 0;

  for (const searchOrder of searchOrders) {
    const orderId = orderIdValue(searchOrder);
    if (!orderId) continue;

    let detailOrder = searchOrder;
    try {
      const detailJson = await fetchShopeeOrderDetail({ account: activeAccount, accessToken, orderIds: [orderId] });
      detailOrder = normalizeDetailOrder(detailJson, searchOrder, orderId);
    } catch (e) {
      warnings.push(`Detail order Shopee ${mask(orderId)} gagal, memakai data list: ${String(e)}`);
    }

    const normalizedOrder = normalizeOrder(detailOrder, activeAccount, orderId);
    const orderStatusUpper = text(normalizedOrder.order_status).toUpperCase();
    if (args.skipCompletedOrderPull && FINAL_MARKETPLACE_ORDER_STATUSES.has(orderStatusUpper)) {
      skippedCompletedOrders += 1;
      continue;
    }

    const hasActiveCancelRequest = isActiveCancelRequest(normalizedOrder.cancel_request_status);
    const isCancelNoStockAction = hasActiveCancelRequest && isAwaitingShipmentNoResi(
      normalizedOrder.order_status,
      normalizedOrder.tracking_number,
    );
    if (!shouldImportOrder(normalizedOrder, { todayStartWib, normalSinceSeconds, includePreviousUnpacked: args.includePreviousUnpacked, hasActiveCancelRequest })) {
      continue;
    }

    const orderRow = await upsertOrder(admin, activeAccount, normalizedOrder);
    importedOrders += 1;

    const statusGroup = orderStatusGroup(orderStatusUpper);
    const isPickableOrder = STOCK_OUT_ELIGIBLE_STATUSES.has(orderStatusUpper);
    const orderCreatedSeconds = isoToSeconds(normalizedOrder.order_created_at);
    const orderUpdatedSeconds = isoToSeconds(normalizedOrder.order_updated_at) || orderCreatedSeconds;
    const isTodayOrder = orderCreatedSeconds >= todayStartWib || orderUpdatedSeconds >= todayStartWib;

    const items = normalizeOrderItems(detailOrder, normalizedOrder).filter((item) => item.quantity > 0);
    if (items.length === 0) {
      warnings.push(`Order Shopee ${mask(orderId)} tidak punya item di response.`);
    }

    let orderUnmapped = 0;
    for (const item of items) {
      const mapping = await findSkuMapping(admin, activeAccount, item);
      const itemPayload = {
        ...item,
        mapped_product_id: mapping?.product_id || null,
        mapped_local_sku: mapping?.local_sku || null,
        marketplace_sku_map_id: mapping?.marketplace_sku_map_id || null,
        mapping_status: mapping?.product_id ? "mapped" : "unmapped",
        stock_action_status: mapping?.product_id
          ? isCancelNoStockAction
            ? "ignored_status"
            : hasActiveCancelRequest
              ? "cancel_review_required"
              : isPickableOrder
                ? "waiting_scan"
                : statusGroup === "cancelled"
                  ? "cancel_review_required"
                  : statusGroup === "return_refund"
                    ? "return_review_required"
                    : isTodayOrder
                      ? "pending"
                      : "ignored_status"
          : "unmapped",
        last_error: mapping?.product_id
          ? isCancelNoStockAction
            ? "Buyer cancel request Shopee saat belum ada resi/packing, jadi tidak diproses stock out dan tidak perlu stock in."
            : hasActiveCancelRequest
              ? "Buyer mengajukan cancel Shopee. Review dulu sebelum packing/stock out."
              : isPickableOrder || statusGroup !== "normal" || isTodayOrder
                ? null
                : "Order lama dengan status non-packing. Tidak diproses stock out otomatis."
          : "SKU marketplace belum dimapping ke SKU lokal.",
      };

      await upsertOrderItem(admin, orderRow.marketplace_order_id, activeAccount, normalizedOrder, itemPayload);
      importedItems += 1;
      if (mapping?.product_id) mappedItems += 1;
      else {
        unmappedItems += 1;
        orderUnmapped += 1;
      }
    }

    const existingOrderStatus = text(orderRow.stock_action_status);
    let stockActionStatus = isTodayOrder ? "pending" : "ignored_status";
    let lastError: string | null = isTodayOrder
      ? `Status order Shopee belum bisa diproses stock out: ${orderStatusUpper || "UNKNOWN"}.`
      : `Order lama Shopee dengan status ${orderStatusUpper || "UNKNOWN"} tidak diproses stock out otomatis.`;

    if (isCancelNoStockAction) {
      stockActionStatus = "ignored_status";
      lastError = "Buyer cancel request Shopee saat belum ada resi/packing, jadi tidak diproses stock out dan tidak perlu stock in.";
    } else if (hasActiveCancelRequest) {
      stockActionStatus = existingOrderStatus === "stock_out_done" ? "return_review_required" : "cancel_review_required";
      lastError = "Buyer mengajukan cancel Shopee. Review dulu sebelum packing/stock out.";
    } else if (statusGroup === "cancelled") {
      stockActionStatus = existingOrderStatus === "stock_out_done" ? "return_review_required" : "cancel_review_required";
      lastError = "Order Shopee cancel perlu dicek di Refund/Cancel Monitor.";
    } else if (statusGroup === "return_refund") {
      stockActionStatus = "return_review_required";
      lastError = "Order Shopee refund/return perlu dicek di Refund/Cancel Monitor.";
    } else if (orderUnmapped > 0) {
      stockActionStatus = "unmapped";
      lastError = `${orderUnmapped} item Shopee belum dimapping ke SKU lokal.`;
    } else if (STOCK_OUT_ELIGIBLE_STATUSES.has(orderStatusUpper)) {
      stockActionStatus = "ready_to_pick";
      lastError = null;
    }

    const preserveOrderStatus = new Set([
      "reserved",
      "partial_scanned",
      "scanned_done",
      "stock_out_done",
      "stock_out_failed",
      "return_review_done",
      "return_not_restocked",
      "cancelled_released",
    ]);

    if (preserveOrderStatus.has(existingOrderStatus) && statusGroup === "normal" && !hasActiveCancelRequest && !isCancelNoStockAction) {
      stockActionStatus = existingOrderStatus;
    }

    await admin
      .from("marketplace_orders")
      .update({
        stock_action_status: stockActionStatus,
        last_error: lastError,
        updated_at: new Date().toISOString(),
      })
      .eq("marketplace_order_id", orderRow.marketplace_order_id);
  }

  await admin
    .from("marketplace_accounts")
    .update({
      last_error: warnings.length > 0 ? warnings.slice(0, 3).join(" | ") : null,
      updated_at: new Date().toISOString(),
    })
    .eq("marketplace_account_id", activeAccount.marketplace_account_id);

  return {
    ok: true,
    marketplace: "shopee",
    orders: importedOrders,
    items: importedItems,
    mapped_items: mappedItems,
    unmapped_items: unmappedItems,
    warning_count: warnings.length,
    warnings: warnings.slice(0, 8),
    pages_scanned: searchedPages,
    max_orders: maxOrders,
    skipped_completed: skippedCompletedOrders,
    message: `Pull Shopee selesai: ${importedOrders} order, ${importedItems} item. Page dicek: ${searchedPages}. Completed dilewati: ${skippedCompletedOrders}.`,
  };
}

async function fetchShopeeOrderListPage(args: {
  account: any;
  accessToken: string;
  timeFrom: number;
  timeTo: number;
  timeRangeField: string;
  pageSize: number;
  cursor: string;
  orderStatus: string | null;
}) {
  const path = "/api/v2/order/get_order_list";
  const query: Record<string, string | number | null> = {
    time_range_field: args.timeRangeField,
    time_from: args.timeFrom,
    time_to: args.timeTo,
    page_size: args.pageSize,
    cursor: args.cursor || null,
    response_optional_fields: "order_status",
    order_status: args.orderStatus,
  };
  return shopeeRequest({ method: "GET", account: args.account, accessToken: args.accessToken, path, query });
}

async function fetchShopeeOrderDetail(args: { account: any; accessToken: string; orderIds: string[] }) {
  const path = "/api/v2/order/get_order_detail";
  const query = {
    order_sn_list: args.orderIds.join(","),
    response_optional_fields: [
      "buyer_user_id",
      "buyer_username",
      "recipient_address",
      "item_list",
      "package_list",
      "shipping_carrier",
      "payment_method",
      "total_amount",
      "invoice_data",
      "checkout_shipping_carrier",
      "actual_shipping_fee",
      "estimated_shipping_fee",
      "buyer_cancel_reason",
      "cancel_by",
      "cancel_reason",
    ].join(","),
  };
  return shopeeRequest({ method: "GET", account: args.account, accessToken: args.accessToken, path, query });
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
    await markMarketplaceAuthExpired(admin, account, "Refresh token Shopee kosong. Reconnect Shopee diperlukan.");
    throw new Error("Refresh token Shopee kosong. Reconnect Shopee diperlukan.");
  }

  const credential = resolveShopeeCredentials(account.environment);
  const shopId = text(account.shop_id);
  if (!shopId) throw new Error("Shopee shop_id kosong. Reconnect Shopee diperlukan.");

  const path = "/api/v2/auth/access_token/get";
  const payload: Record<string, unknown> = {
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
    await markMarketplaceAuthExpired(admin, account, `Refresh token Shopee gagal: response tidak berisi access_token. ${JSON.stringify(maskTokenObject(response))}`);
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

function isShopeeAuthError(err: unknown): boolean {
  const message = String(err).toLowerCase();
  return message.includes("invalid_acceess_token")
    || message.includes("invalid_access_token")
    || message.includes("access_token")
    || message.includes("401")
    || message.includes("error_auth");
}

function toShopeeOrderStatus(status: string): string | null {
  const clean = text(status).toUpperCase();
  if (!clean) return null;
  if (["READY_TO_SHIP", "UNSHIPPED", "AWAITING_SHIPMENT", "PAID", "TO_SHIP", "AWAITING_COLLECTION", "AWAITING_PICKUP", "READY_FOR_COLLECTION", "READY_FOR_PICKUP"].includes(clean)) return "READY_TO_SHIP";
  if (["PROCESSED", "PARTIALLY_SHIPPING", "ON_HOLD"].includes(clean)) return "PROCESSED";
  if (["IN_TRANSIT", "SHIPPED"].includes(clean)) return "SHIPPED";
  if (["COMPLETED", "DELIVERED"].includes(clean)) return "COMPLETED";
  if (["CANCELLED", "CANCELED", "CANCEL", "IN_CANCEL", "TO_CANCEL", "CANCEL_REQUESTED"].includes(clean)) return "CANCELLED";
  if (["UNPAID"].includes(clean)) return "UNPAID";
  return null;
}

function buildShopeeTimeRanges(startSeconds: number, endSeconds: number): Array<{ start: number; end: number }> {
  const ranges: Array<{ start: number; end: number }> = [];
  const maxSeconds = 15 * 24 * 60 * 60;
  let cursor = Math.max(1, Math.floor(startSeconds));
  const finalEnd = Math.max(cursor + 1, Math.floor(endSeconds));
  while (cursor < finalEnd) {
    const end = Math.min(finalEnd, cursor + maxSeconds);
    ranges.push({ start: cursor, end });
    cursor = end;
  }
  return ranges;
}

function extractShopeeNextCursor(jsonRes: any): string {
  const data = jsonRes?.response ?? jsonRes?.data ?? jsonRes;
  if (data?.more === false || data?.has_more === false) return "";
  return text(data?.next_cursor) || text(data?.nextCursor) || text(data?.cursor) || "";
}

function uniqueStrings(values: Array<string | null>): Array<string | null> {
  const seen = new Set<string>();
  const out: Array<string | null> = [];
  for (const value of values) {
    const key = value || "__ALL__";
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(value);
  }
  return out;
}

function numericOrString(value: string): number | string {
  return /^\d+$/.test(value) ? Number(value) : value;
}

async function pullTikTokOrders(admin: any, account: any, args: { daysBack: number; startSeconds: number; endSeconds: number; pageSize: number; maxPages: number; statuses: string[]; includePreviousUnpacked: boolean; previousUnpackedDays: number; includeStatuslessSearch: boolean; includeUpdateTimeSearch: boolean; statuslessOnly: boolean; maxDetails: number; skipCompletedOrderPull: boolean }) {
  const appKey = text(account.app_key) || requiredEnv("TIKTOK_APP_KEY");
  const appSecret = requiredEnv("TIKTOK_APP_SECRET");
  let tokenBundle = await refreshTikTokAccessTokenIfNeeded(admin, account);
  let activeAccount = tokenBundle.account;
  let accessToken = tokenBundle.accessToken;

  let shopCipher = detectShopCipher(activeAccount);
  let shopId = text(activeAccount.shop_id);

  if (!appKey) throw new Error("TIKTOK_APP_KEY kosong.");
  if (!accessToken) throw new Error("Access token TikTok kosong. Re-authorize toko dulu.");

  if (!shopCipher) {
    const authorizedShopsJson = await tiktokRequest({
      method: "GET",
      path: "/authorization/202309/shops",
      appKey,
      appSecret,
      accessToken,
      body: {},
    });
    const authorizedShop = pickAuthorizedShop(authorizedShopsJson, activeAccount, shopCipher);
    if (authorizedShop) {
      shopCipher = shopCipherValue(authorizedShop) || shopCipher;
      shopId = shopIdValue(authorizedShop) || shopId;
      await admin
        .from("marketplace_accounts")
        .update({
          shop_id: shopId,
          shop_cipher: shopCipher,
          shop_name: shopNameValue(authorizedShop) || activeAccount.shop_name,
          raw_shop_response: safeJsonForDb(authorizedShopsJson),
          last_error: null,
          updated_at: new Date().toISOString(),
        })
        .eq("marketplace_account_id", activeAccount.marketplace_account_id);
    }
  }

  if (!shopCipher) {
    throw new Error("shop_cipher TikTok belum valid. Re-authorize toko lalu ulangi Pull Orders.");
  }

  const nowSeconds = Math.max(args.endSeconds, args.startSeconds + 24 * 60 * 60);
  const todayStartWib = startOfTodayWibSeconds();
  const normalSinceSeconds = args.startSeconds;
  const previousUnpackedSinceSeconds = Math.floor(Date.now() / 1000) - args.previousUnpackedDays * 24 * 60 * 60;
  const sinceSeconds = args.includePreviousUnpacked ? Math.min(normalSinceSeconds, previousUnpackedSinceSeconds) : normalSinceSeconds;

  const query: Record<string, string> = {
    page_size: String(args.pageSize),
    version: "202309",
  };
  if (shopId) query.shop_id = shopId;

  const bodies = buildOrderSearchBodies(args.statuses, sinceSeconds, nowSeconds, {
    includeStatuslessSearch: args.includeStatuslessSearch,
    includeUpdateTimeSearch: args.includeUpdateTimeSearch,
    statuslessOnly: args.statuslessOnly,
  });
  let searchJson: any = null;
  let firstError: unknown = null;
  let searchOrdersAll: any[] = [];
  const seenOrderIds = new Set<string>();
  const maxOrders = Math.max(1, Math.min(args.maxDetails, Math.max(args.pageSize, args.pageSize * args.maxPages)));
  let searchedPages = 0;

  // Pull manual harus mengambil semua order sesuai pilihan hari, bukan cuma status cancel/return yang kebetulan muncul di page pertama.
  // Karena TikTok search bisa terpecah per create_time/update_time/status dan pakai page_token, kita gabungkan semua page dengan dedupe order id.
  for (const body of bodies) {
    let pageToken = "";

    for (let pageIndex = 0; pageIndex < args.maxPages && searchOrdersAll.length < maxOrders; pageIndex += 1) {
      try {
        const pageQuery: Record<string, string> = { ...query };
        if (pageToken) pageQuery.page_token = pageToken;

        const candidateJson = await tiktokRequest({
          method: "POST",
          path: "/order/202309/orders/search",
          appKey,
          appSecret,
          accessToken,
          shopCipher,
          query: pageQuery,
          body,
        });

        searchJson = candidateJson;
        searchedPages += 1;
        const candidateOrders = collectOrders(candidateJson);
        for (const candidate of candidateOrders) {
          const oid = orderIdValue(candidate);
          if (!oid || seenOrderIds.has(oid)) continue;
          seenOrderIds.add(oid);
          searchOrdersAll.push(candidate);
          if (searchOrdersAll.length >= maxOrders) break;
        }

        pageToken = extractNextPageToken(candidateJson);
        if (!pageToken || candidateOrders.length === 0) break;
      } catch (e) {
        firstError = e;
        if (isTikTokAuthError(e)) {
          tokenBundle = await refreshTikTokAccessTokenIfNeeded(admin, activeAccount, true);
          activeAccount = tokenBundle.account;
          accessToken = tokenBundle.accessToken;
          pageIndex -= 1;
          continue;
        }
        break;
      }
    }

    if (searchOrdersAll.length >= maxOrders) break;
  }

  if (!searchJson && searchOrdersAll.length === 0) throw firstError || new Error("TikTok order search gagal.");

  const searchOrders = searchOrdersAll.slice(0, maxOrders);
  let importedOrders = 0;
  let importedItems = 0;
  let mappedItems = 0;
  let unmappedItems = 0;
  let skippedCompletedOrders = 0;
  const warnings: string[] = [];

  for (const searchOrder of searchOrders) {
    const orderId = orderIdValue(searchOrder);
    if (!orderId) continue;

    let detailOrder = searchOrder;
    try {
      const detailJson = await fetchTikTokOrderDetail({
        orderId,
        appKey,
        appSecret,
        accessToken,
        shopCipher,
        shopId,
      });
      detailOrder = normalizeDetailOrder(detailJson, searchOrder, orderId);
    } catch (e) {
      warnings.push(`Detail order ${mask(orderId)} gagal, memakai data search: ${String(e)}`);
    }

    const normalizedOrder = normalizeOrder(detailOrder, activeAccount, orderId);
    const orderStatusUpper = text(normalizedOrder.order_status).toUpperCase();
    if (args.skipCompletedOrderPull && FINAL_MARKETPLACE_ORDER_STATUSES.has(orderStatusUpper)) {
      skippedCompletedOrders += 1;
      continue;
    }

    const hasActiveCancelRequest = isActiveCancelRequest(normalizedOrder.cancel_request_status);
    const isCancelNoStockAction = hasActiveCancelRequest && isAwaitingShipmentNoResi(
      normalizedOrder.order_status,
      normalizedOrder.tracking_number,
    );
    if (!shouldImportOrder(normalizedOrder, { todayStartWib, normalSinceSeconds, includePreviousUnpacked: args.includePreviousUnpacked, hasActiveCancelRequest })) {
      continue;
    }

    const orderRow = await upsertOrder(admin, activeAccount, normalizedOrder);
    importedOrders += 1;

    const statusGroup = orderStatusGroup(orderStatusUpper);
    const isPickableOrder = STOCK_OUT_ELIGIBLE_STATUSES.has(orderStatusUpper);
    const orderCreatedSeconds = isoToSeconds(normalizedOrder.order_created_at);
    const orderUpdatedSeconds = isoToSeconds(normalizedOrder.order_updated_at) || orderCreatedSeconds;
    const isTodayOrder = orderCreatedSeconds >= todayStartWib || orderUpdatedSeconds >= todayStartWib;

    const items = normalizeOrderItems(detailOrder, normalizedOrder).filter((item) => item.quantity > 0);
    if (items.length === 0) {
      warnings.push(`Order ${mask(orderId)} tidak punya item di response TikTok.`);
    }

    let orderMapped = 0;
    let orderUnmapped = 0;

    for (const item of items) {
      const mapping = await findSkuMapping(admin, activeAccount, item);
      const itemPayload = {
        ...item,
        mapped_product_id: mapping?.product_id || null,
        mapped_local_sku: mapping?.local_sku || null,
        marketplace_sku_map_id: mapping?.marketplace_sku_map_id || null,
        mapping_status: mapping?.product_id ? "mapped" : "unmapped",
        // Untuk order siap packing/collection, item langsung waiting_scan.
        // Cancel/refund tidak boleh jadi ignored_status.
        // ignored_status hanya dipakai untuk order lama yang bukan packable/cancel/refund,
        // supaya order hari ini dan order lama yang belum dipacking tetap terlihat jelas.
        stock_action_status: mapping?.product_id
          ? isCancelNoStockAction
            ? "ignored_status"
            : hasActiveCancelRequest
              ? "cancel_review_required"
              : isPickableOrder
                ? "waiting_scan"
                : statusGroup === "cancelled"
                  ? "cancel_review_required"
                  : statusGroup === "return_refund"
                    ? "return_review_required"
                    : isTodayOrder
                      ? "pending"
                      : "ignored_status"
          : "unmapped",
        last_error: mapping?.product_id
          ? isCancelNoStockAction
            ? "Buyer cancel request saat AWAITING_SHIPMENT. Belum ada resi/packing, jadi tidak diproses stock out dan tidak perlu stock in."
            : hasActiveCancelRequest
              ? "Buyer mengajukan cancel. Review dulu sebelum packing/stock out."
              : isPickableOrder || statusGroup !== "normal" || isTodayOrder
                ? null
                : "Order lama dengan status non-packing. Tidak diproses stock out otomatis."
          : "SKU marketplace belum dimapping ke SKU lokal.",
      };

      await upsertOrderItem(admin, orderRow.marketplace_order_id, activeAccount, normalizedOrder, itemPayload);
      importedItems += 1;
      if (mapping?.product_id) {
        mappedItems += 1;
        orderMapped += 1;
      } else {
        unmappedItems += 1;
        orderUnmapped += 1;
      }
    }

    const existingOrderStatus = text(orderRow.stock_action_status);

    let stockActionStatus = isTodayOrder ? "pending" : "ignored_status";
    let lastError: string | null = isTodayOrder
      ? `Status order belum bisa diproses stock out: ${orderStatusUpper || "UNKNOWN"}.`
      : `Order lama dengan status ${orderStatusUpper || "UNKNOWN"} tidak diproses stock out otomatis.`;

    if (isCancelNoStockAction) {
      stockActionStatus = "ignored_status";
      lastError = "Buyer cancel request saat AWAITING_SHIPMENT. Belum ada resi/packing, jadi tidak diproses stock out dan tidak perlu stock in.";
    } else if (hasActiveCancelRequest) {
      stockActionStatus = existingOrderStatus === "stock_out_done" ? "return_review_required" : "cancel_review_required";
      lastError = "Buyer mengajukan cancel. Review dulu sebelum packing/stock out.";
    } else if (statusGroup === "cancelled") {
      stockActionStatus = existingOrderStatus === "stock_out_done" ? "return_review_required" : "cancel_review_required";
      lastError = "Order cancel perlu dicek di Refund/Cancel Monitor.";
    } else if (statusGroup === "return_refund") {
      stockActionStatus = "return_review_required";
      lastError = "Order refund/return perlu dicek di Refund/Cancel Monitor.";
    } else if (orderUnmapped > 0) {
      stockActionStatus = "unmapped";
      lastError = `${orderUnmapped} item belum dimapping ke SKU lokal.`;
    } else if (STOCK_OUT_ELIGIBLE_STATUSES.has(orderStatusUpper)) {
      stockActionStatus = "ready_to_pick";
      lastError = null;
    }

    const preserveOrderStatus = new Set([
      "reserved",
      "partial_scanned",
      "scanned_done",
      "stock_out_done",
      "stock_out_failed",
      "return_review_done",
      "return_not_restocked",
      "cancelled_released",
    ]);

    if (preserveOrderStatus.has(existingOrderStatus) && statusGroup === "normal" && !hasActiveCancelRequest && !isCancelNoStockAction) {
      stockActionStatus = existingOrderStatus;
    }

    await admin
      .from("marketplace_orders")
      .update({
        stock_action_status: stockActionStatus,
        last_error: lastError,
        updated_at: new Date().toISOString(),
      })
      .eq("marketplace_order_id", orderRow.marketplace_order_id);
  }

  await admin
    .from("marketplace_accounts")
    .update({
      last_error: warnings.length > 0 ? warnings.slice(0, 3).join(" | ") : null,
      updated_at: new Date().toISOString(),
    })
    .eq("marketplace_account_id", activeAccount.marketplace_account_id);

  return {
    ok: true,
    marketplace: "tiktok_shop",
    orders: importedOrders,
    items: importedItems,
    mapped_items: mappedItems,
    unmapped_items: unmappedItems,
    warning_count: warnings.length,
    warnings: warnings.slice(0, 8),
    pages_scanned: searchedPages,
    max_orders: maxOrders,
    skipped_completed: skippedCompletedOrders,
    message: `Pull selesai: ${importedOrders} order, ${importedItems} item. Page dicek: ${searchedPages}. Completed dilewati: ${skippedCompletedOrders}.`,
  };
}


function orderStatusGroup(status: string): "normal" | "cancelled" | "return_refund" {
  const clean = text(status).toUpperCase();
  if (CANCEL_STATUSES.has(clean)) return "cancelled";
  if (clean.includes("RETURN") || clean.includes("REFUND")) return "return_refund";
  return "normal";
}

function isAwaitingShipmentNoResi(statusRaw: unknown, trackingRaw: unknown): boolean {
  const status = text(statusRaw).toUpperCase();
  const tracking = text(trackingRaw);
  return !tracking && new Set([
    "AWAITING_SHIPMENT",
    "READY_TO_SHIP",
    "PAID",
    "UNSHIPPED",
    "TO_SHIP",
  ]).has(status);
}

function shouldImportOrder(order: any, args: { todayStartWib: number; normalSinceSeconds: number; includePreviousUnpacked: boolean; hasActiveCancelRequest?: boolean }): boolean {
  const status = text(order.order_status).toUpperCase();
  const group = orderStatusGroup(status);
  const createdSeconds = isoToSeconds(order.order_created_at) || isoToSeconds(order.order_updated_at) || 0;
  const updatedSeconds = isoToSeconds(order.order_updated_at) || createdSeconds;
  const isToday = createdSeconds >= args.todayStartWib || updatedSeconds >= args.todayStartWib;
  const inSelectedPeriod = createdSeconds >= args.normalSinceSeconds || updatedSeconds >= args.normalSinceSeconds;

  // Pilihan hari di UI berarti semua order dalam periode itu boleh masuk ke tabel order.
  // Filter final completed/delivered diterapkan setelah detail status terbaru tersedia.
  if (inSelectedPeriod) return true;
  if (isToday) return true;
  if (args.hasActiveCancelRequest) return true;
  if (!args.includePreviousUnpacked) return false;
  if (STOCK_OUT_ELIGIBLE_STATUSES.has(status)) return true;
  if (group === "cancelled" || group === "return_refund") return true;
  return false;
}

function pullDateRangeFromBody(body: any, daysBack: number): { startSeconds: number; endSeconds: number } {
  const startSecondsRaw = Number(body.start_seconds || body.start_epoch_seconds || body.from_seconds || 0);
  const endSecondsRaw = Number(body.end_seconds || body.end_epoch_seconds || body.to_seconds || 0);
  if (Number.isFinite(startSecondsRaw) && Number.isFinite(endSecondsRaw) && startSecondsRaw > 0 && endSecondsRaw > startSecondsRaw) {
    return {
      startSeconds: Math.floor(startSecondsRaw),
      endSeconds: Math.floor(endSecondsRaw),
    };
  }

  const startAtRaw = text(body.start_at || body.start_datetime || body.from_at);
  const endAtRaw = text(body.end_at || body.end_datetime || body.to_at);
  if (startAtRaw && endAtRaw) {
    const startMs = Date.parse(startAtRaw);
    const endMs = Date.parse(endAtRaw);
    if (Number.isFinite(startMs) && Number.isFinite(endMs) && endMs > startMs) {
      return {
        startSeconds: Math.floor(startMs / 1000),
        endSeconds: Math.floor(endMs / 1000),
      };
    }
  }

  const startRaw = text(body.start_date || body.p_start_date || body.start);
  const endRaw = text(body.end_date || body.p_end_date || body.end);
  if (startRaw && endRaw) {
    const startSeconds = wibDateStartSeconds(startRaw);
    const endSeconds = wibDateStartSeconds(endRaw) + 24 * 60 * 60;
    if (Number.isFinite(startSeconds) && Number.isFinite(endSeconds) && endSeconds > startSeconds) {
      return { startSeconds, endSeconds };
    }
  }

  const now = Math.floor(Date.now() / 1000);
  return { startSeconds: now - daysBack * 24 * 60 * 60, endSeconds: now };
}

function todayWibSecondsRange(): { startSeconds: number; endSeconds: number } {
  const startSeconds = startOfTodayWibSeconds();
  return { startSeconds, endSeconds: startSeconds + 24 * 60 * 60 };
}

function wibDateStartSeconds(raw: string): number {
  const clean = text(raw).slice(0, 10);
  const match = clean.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!match) return NaN;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  return Math.floor((Date.UTC(year, month - 1, day, 0, 0, 0) - 7 * 60 * 60 * 1000) / 1000);
}

function startOfTodayWibSeconds(): number {
  const wibOffsetMs = 7 * 60 * 60 * 1000;
  const nowWib = new Date(Date.now() + wibOffsetMs);
  const startUtcMs = Date.UTC(nowWib.getUTCFullYear(), nowWib.getUTCMonth(), nowWib.getUTCDate()) - wibOffsetMs;
  return Math.floor(startUtcMs / 1000);
}

function isoToSeconds(raw: unknown): number {
  const value = text(raw);
  if (!value) return 0;
  const ms = Date.parse(value);
  if (!Number.isFinite(ms)) return 0;
  return Math.floor(ms / 1000);
}

function buildOrderSearchBodies(statuses: string[], sinceSeconds: number, nowSeconds: number, options: { includeStatuslessSearch: boolean; includeUpdateTimeSearch: boolean; statuslessOnly?: boolean }): Record<string, unknown>[] {
  const requested = statuses.map((item) => normalizeTikTokOrderStatus(item)).filter(Boolean) as string[];
  const defaultStatuses = ORDER_PULL_ALL_STATUSES.map(normalizeTikTokOrderStatus).filter(Boolean) as string[];
  const cleanStatuses = Array.from(new Set(requested.length > 0 ? requested : defaultStatuses));

  const bodies: Record<string, unknown>[] = [];

  // Search tanpa status tetap disediakan untuk fallback manual, tapi mode aman dari Flutter mematikannya
  // supaya satu invocation tidak kebanyakan detail order di Supabase Free.
  if (options.includeStatuslessSearch) {
    bodies.push({
      create_time_ge: sinceSeconds,
      create_time_lt: nowSeconds,
      sort_field: "create_time",
      sort_order: "DESC",
    });
  }

  if (options.includeStatuslessSearch && options.includeUpdateTimeSearch) {
    bodies.push({
      update_time_ge: sinceSeconds,
      update_time_lt: nowSeconds,
      sort_field: "update_time",
      sort_order: "DESC",
    });
  }

  // Mode statusless-only dipakai untuk backfill bulanan besar.
  // Tujuannya mengambil semua status termasuk CANCELLED tanpa 8x request per status.
  // Status final tetap disimpan dari detail order, bukan ditebak dari filter pencarian.
  if (options.statuslessOnly && bodies.length > 0) {
    return bodies;
  }

  // TikTok Get Order List 202309 menerima order_status sebagai string, bukan array.
  // Setiap status dibuat sebagai request body terpisah agar tidak kena HTTP 400.
  for (const status of cleanStatuses) {
    bodies.push({
      order_status: status,
      create_time_ge: sinceSeconds,
      create_time_lt: nowSeconds,
      sort_field: "create_time",
      sort_order: "DESC",
    });

    if (options.includeUpdateTimeSearch) {
      bodies.push({
        order_status: status,
        update_time_ge: sinceSeconds,
        update_time_lt: nowSeconds,
        sort_field: "update_time",
        sort_order: "DESC",
      });
    }
  }

  return bodies;
}

function normalizeTikTokOrderStatus(raw: unknown): string | null {
  const status = text(raw).toUpperCase().replace(/[^A-Z0-9]+/g, "_");
  if (!status) return null;

  const aliases: Record<string, string> = {
    READY_TO_SHIP: "AWAITING_SHIPMENT",
    PAID: "AWAITING_SHIPMENT",
    UNSHIPPED: "AWAITING_SHIPMENT",
    TO_SHIP: "AWAITING_SHIPMENT",
    PARTIALLY_SHIPPING: "AWAITING_SHIPMENT",
    AWAITING_PICKUP: "AWAITING_COLLECTION",
    READY_FOR_COLLECTION: "AWAITING_COLLECTION",
    READY_FOR_PICKUP: "AWAITING_COLLECTION",
    SHIPPED: "IN_TRANSIT",
    CANCELED: "CANCELLED",
    RETURNED: "COMPLETED",
    RETURN_REFUND: "COMPLETED",
    REFUND: "COMPLETED",
  };

  const normalized = aliases[status] || status;
  const allowed = new Set([
    "UNPAID",
    "ON_HOLD",
    "AWAITING_SHIPMENT",
    "AWAITING_COLLECTION",
    "IN_TRANSIT",
    "DELIVERED",
    "COMPLETED",
    "CANCELLED",
  ]);

  return allowed.has(normalized) ? normalized : null;
}

function extractNextPageToken(jsonRes: any): string {
  const data = jsonRes?.data ?? jsonRes?.response?.data ?? jsonRes;
  return text(data?.next_page_token)
    || text(data?.nextPageToken)
    || text(data?.next_token)
    || text(data?.nextToken)
    || text(data?.page_token)
    || text(data?.pagination?.next_page_token)
    || text(data?.pagination?.nextPageToken)
    || "";
}

async function fetchTikTokOrderDetail(args: {
  orderId: string;
  appKey: string;
  appSecret: string;
  accessToken: string;
  shopCipher: string;
  shopId: string | null;
}) {
  const attempts = [
    {
      method: "GET" as const,
      path: `/order/202309/orders/${encodeURIComponent(args.orderId)}`,
      query: args.shopId ? { shop_id: args.shopId, version: "202309" } : { version: "202309" },
      body: {},
    },
    {
      method: "GET" as const,
      path: "/order/202309/orders",
      query: args.shopId ? { shop_id: args.shopId, ids: args.orderId, version: "202309" } : { ids: args.orderId, version: "202309" },
      body: {},
    },
    {
      method: "POST" as const,
      path: "/order/202309/orders/detail/query",
      query: args.shopId ? { shop_id: args.shopId, version: "202309" } : { version: "202309" },
      body: { order_id_list: [args.orderId], order_ids: [args.orderId] },
    },
  ];

  let lastError: unknown = null;
  for (const attempt of attempts) {
    try {
      return await tiktokRequest({
        method: attempt.method,
        path: attempt.path,
        appKey: args.appKey,
        appSecret: args.appSecret,
        accessToken: args.accessToken,
        shopCipher: args.shopCipher,
        query: attempt.query,
        body: attempt.body,
      });
    } catch (e) {
      lastError = e;
    }
  }
  throw lastError;
}

async function upsertOrder(admin: any, account: any, order: any) {
  const now = new Date().toISOString();
  const payload = {
    tenant_id: account.tenant_id,
    marketplace_account_id: account.marketplace_account_id,
    marketplace: account.marketplace,
    external_order_id: order.external_order_id,
    order_sn: order.order_sn || order.external_order_id,
    order_status: order.order_status,
    order_status_label: order.order_status_label,
    buyer_username: order.buyer_username,
    recipient_name: order.recipient_name,
    tracking_number: order.tracking_number,
    shipping_provider_name: order.shipping_provider_name,
    package_id: order.package_id,
    logistic_status: order.logistic_status,
    label_code: order.label_code,
    cancel_request_id: order.cancel_request_id,
    cancel_request_status: order.cancel_request_status,
    cancel_request_reason: order.cancel_request_reason,
    cancel_request_note: order.cancel_request_note,
    cancel_requested_at: order.cancel_requested_at,
    cancel_request_raw: order.cancel_request_raw,
    cancel_request_pulled_at: order.cancel_request_status ? now : null,
    payment_method: order.payment_method,
    currency: order.currency,
    total_amount: order.total_amount,
    order_created_at: order.order_created_at,
    order_updated_at: order.order_updated_at,
    raw_order: order.raw_order,
    pulled_at: now,
    updated_at: now,
  };

  const { data, error } = await admin
    .from("marketplace_orders")
    .upsert(payload, { onConflict: "tenant_id,marketplace_account_id,external_order_id" })
    .select("marketplace_order_id, stock_action_status")
    .single();

  if (error) throw new Error(`Upsert marketplace order gagal: ${error.message}`);
  return data;
}

async function upsertOrderItem(admin: any, marketplaceOrderId: string, account: any, order: any, item: any) {
  const now = new Date().toISOString();

  const { data: existing, error: existingError } = await admin
    .from("marketplace_order_items")
    .select("marketplace_order_item_id, stock_action_status")
    .eq("tenant_id", account.tenant_id)
    .eq("marketplace_account_id", account.marketplace_account_id)
    .eq("external_order_id", order.external_order_id)
    .eq("external_order_item_id", item.external_order_item_id)
    .maybeSingle();
  if (existingError) throw new Error(`Load existing order item gagal: ${existingError.message}`);

  const existingItemStatus = text(existing?.stock_action_status);
  const preserveDone = PRESERVE_ITEM_ACTION_STATUSES.has(existingItemStatus);

  const payload = {
    marketplace_order_id: marketplaceOrderId,
    tenant_id: account.tenant_id,
    marketplace_account_id: account.marketplace_account_id,
    marketplace: account.marketplace,
    external_order_id: order.external_order_id,
    order_sn: order.order_sn || order.external_order_id,
    external_order_item_id: item.external_order_item_id,
    marketplace_product_id: item.marketplace_product_id,
    marketplace_sku_id: item.marketplace_sku_id,
    seller_sku: item.seller_sku,
    product_name: item.product_name,
    variant_name: item.variant_name,
    tracking_number: item.tracking_number,
    package_id: item.package_id,
    quantity: item.quantity,
    gross_amount: item.gross_amount,
    paid_amount: item.paid_amount,
    unit_gross_amount: item.unit_gross_amount,
    unit_paid_amount: item.unit_paid_amount,
    marketplace_price_updated_at: now,
    finance_price_source: item.finance_price_source,
    mapped_product_id: item.mapped_product_id,
    mapped_local_sku: item.mapped_local_sku,
    marketplace_sku_map_id: item.marketplace_sku_map_id,
    mapping_status: item.mapping_status,
    stock_action_status: preserveDone ? existingItemStatus : item.stock_action_status,
    last_error: preserveDone ? null : item.last_error,
    raw_item: item.raw_item,
    updated_at: now,
  };

  const { error } = await admin
    .from("marketplace_order_items")
    .upsert(payload, { onConflict: "tenant_id,marketplace_account_id,external_order_id,external_order_item_id" });

  if (error) throw new Error(`Upsert marketplace order item gagal: ${error.message}`);
}

async function findSkuMapping(admin: any, account: any, item: any): Promise<any | null> {
  const baseSelect = "marketplace_sku_map_id, product_id, local_sku";

  const skuId = text(item.marketplace_sku_id);
  if (skuId) {
    const { data, error } = await admin
      .from("marketplace_sku_maps")
      .select(baseSelect)
      .eq("tenant_id", account.tenant_id)
      .eq("marketplace_account_id", account.marketplace_account_id)
      .eq("marketplace_sku_id", skuId)
      .eq("status", "active")
      .limit(1)
      .maybeSingle();
    if (error) throw new Error(`Cari mapping sku_id gagal: ${error.message}`);
    if (data) return data;
  }

  const sellerSku = text(item.seller_sku);
  if (sellerSku) {
    const { data, error } = await admin
      .from("marketplace_sku_maps")
      .select(baseSelect)
      .eq("tenant_id", account.tenant_id)
      .eq("marketplace_account_id", account.marketplace_account_id)
      .eq("marketplace_seller_sku", sellerSku)
      .eq("status", "active")
      .limit(1)
      .maybeSingle();
    if (error) throw new Error(`Cari mapping seller_sku gagal: ${error.message}`);
    if (data) return data;
  }

  const productId = text(item.marketplace_product_id);
  if (productId && skuId) {
    const { data, error } = await admin
      .from("marketplace_sku_maps")
      .select(baseSelect)
      .eq("tenant_id", account.tenant_id)
      .eq("marketplace_account_id", account.marketplace_account_id)
      .eq("marketplace_product_id", productId)
      .eq("marketplace_sku_id", skuId)
      .eq("status", "active")
      .limit(1)
      .maybeSingle();
    if (error) throw new Error(`Cari mapping product+sku gagal: ${error.message}`);
    if (data) return data;
  }

  return null;
}

function normalizeDetailOrder(detailJson: any, fallback: any, orderId: string): any {
  const data = detailJson?.data ?? detailJson?.response?.data ?? detailJson?.response ?? detailJson;
  const candidates = [
    data?.order,
    data?.orders?.[0],
    data?.order_list?.[0],
    data?.list?.[0],
    detailJson?.order,
    detailJson?.orders?.[0],
  ];
  const found = candidates.find((item) => item && typeof item === "object") || data || fallback;
  return deepMerge(fallback || {}, found || { id: orderId });
}

function normalizeOrder(raw: any, account: any, orderId: string) {
  const status = text(raw.status) || text(raw.order_status) || text(raw.orderStatus) || text(raw.fulfillment_status) || "UNKNOWN";
  const payment = raw.payment || raw.payment_info || raw.paymentInfo || {};
  const recipient = raw.recipient_address || raw.recipient || raw.shipping_address || raw.delivery_address || {};
  const cancelRequest = detectCancelRequest(raw);

  return {
    external_order_id: orderId,
    order_sn: orderId,
    order_status: status.toUpperCase(),
    order_status_label: text(raw.status_label) || text(raw.order_status_label) || status,
    buyer_username: text(raw.buyer_username) || text(raw.buyer?.username) || text(raw.customer?.name) || null,
    recipient_name: text(recipient.name) || text(recipient.recipient_name) || text(raw.recipient_name) || null,
    tracking_number: detectTrackingNumber(raw),
    shipping_provider_name: detectShippingProviderName(raw),
    package_id: detectPackageId(raw),
    logistic_status: detectLogisticStatus(raw),
    label_code: detectLabelCode(raw) || orderId,
    cancel_request_id: cancelRequest.id,
    cancel_request_status: cancelRequest.status,
    cancel_request_reason: cancelRequest.reason,
    cancel_request_note: cancelRequest.note,
    cancel_requested_at: toIsoFromAny(cancelRequest.requestedAt),
    cancel_request_raw: cancelRequest.raw,
    payment_method: text(payment.payment_method) || text(payment.method) || text(raw.payment_method) || null,
    currency: text(payment.currency) || text(raw.currency) || null,
    total_amount: parseAmount(payment.total_amount) ?? parseAmount(raw.total_amount) ?? parseAmount(raw.total_price),
    order_created_at: secondsToIso(raw.create_time ?? raw.created_at ?? raw.order_create_time),
    order_updated_at: secondsToIso(raw.update_time ?? raw.updated_at ?? raw.order_update_time),
    raw_order: safeJsonForDb(raw),
    marketplace: account.marketplace,
  };
}

function normalizeOrderItems(rawOrder: any, order: any) {
  const arrays = [
    rawOrder.line_items,
    rawOrder.item_list,
    rawOrder.items,
    rawOrder.order_items,
    rawOrder.skus,
    rawOrder.products,
    rawOrder.package_list?.flatMap((p: any) => p.line_items || p.items || []),
  ];

  let rawItems: any[] = [];
  for (const arr of arrays) {
    if (Array.isArray(arr) && arr.length > 0) {
      rawItems = arr;
      break;
    }
  }

  return rawItems.map((item, index) => {
    const skuId = text(item.sku_id)
      || text(item.product_sku_id)
      || text(item.seller_sku_id)
      || text(item.model_id)
      || text(item.variation_id)
      || text(item.sku?.id);
    const sellerSku = text(item.seller_sku)
      || text(item.seller_sku_code)
      || text(item.sku_code)
      || text(item.model_sku)
      || text(item.item_sku)
      || text(item.sku?.seller_sku);
    const productId = text(item.product_id) || text(item.item_id) || text(item.product?.id);
    const lineItemId = text(item.id)
      || text(item.line_item_id)
      || text(item.order_line_item_id)
      || text(item.order_item_id)
      || text(item.item_id && item.model_id ? `${item.item_id}-${item.model_id}` : null)
      || text(item.item_id)
      || `${order.external_order_id}-${skuId || sellerSku || productId || index + 1}`;

    return {
      external_order_item_id: lineItemId,
      marketplace_product_id: productId || null,
      marketplace_sku_id: skuId || null,
      seller_sku: sellerSku || null,
      product_name: text(item.product_name) || text(item.item_name) || text(item.name) || text(item.product?.name) || text(item.title) || null,
      variant_name: text(item.sku_name) || text(item.model_name) || text(item.variation_name) || text(item.variant_name) || buildVariantName(item),
      tracking_number: detectTrackingNumber(item) || order.tracking_number || null,
      package_id: detectPackageId(item) || order.package_id || null,
      quantity: Number(item.quantity ?? item.qty ?? item.item_quantity ?? item.model_quantity_purchased ?? 1) || 1,
      gross_amount: (() => {
        const qty = Number(item.quantity ?? item.qty ?? item.item_quantity ?? item.model_quantity_purchased ?? 1) || 1;
        return marketplaceItemGrossLine(item, qty) ?? 0;
      })(),
      paid_amount: (() => {
        const qty = Number(item.quantity ?? item.qty ?? item.item_quantity ?? item.model_quantity_purchased ?? 1) || 1;
        return marketplaceItemPayoutLine(item, qty) ?? 0;
      })(),
      unit_gross_amount: (() => {
        const qty = Number(item.quantity ?? item.qty ?? item.item_quantity ?? item.model_quantity_purchased ?? 1) || 1;
        const gross = marketplaceItemGrossLine(item, qty) ?? 0;
        return qty > 0 ? gross / qty : 0;
      })(),
      unit_paid_amount: (() => {
        const qty = Number(item.quantity ?? item.qty ?? item.item_quantity ?? item.model_quantity_purchased ?? 1) || 1;
        const paid = marketplaceItemPayoutLine(item, qty) ?? 0;
        return qty > 0 ? paid / qty : 0;
      })(),
      finance_price_source: marketplaceItemPayoutLine(item, Number(item.quantity ?? item.qty ?? item.item_quantity ?? item.model_quantity_purchased ?? 1) || 1) ? "marketplace raw item payout" : "marketplace raw item gross",
      raw_item: safeJsonForDb(item),
    };
  });
}

function buildVariantName(item: any): string | null {
  const attrs = item.sku_attributes || item.attributes || item.sale_attributes;
  if (!Array.isArray(attrs)) return null;
  const parts = attrs
    .map((attr: any) => {
      const name = text(attr.name) || text(attr.attribute_name);
      const value = text(attr.value) || text(attr.value_name) || text(attr.attribute_value_name);
      if (!value) return null;
      return name ? `${name}: ${value}` : value;
    })
    .filter(Boolean);
  return parts.length > 0 ? parts.join(" • ") : null;
}

function numberFromAny(value: any): number | null {
  if (value === null || value === undefined) return null;
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const cleaned = value.replace(/[^0-9.-]/g, "").trim();
    if (!cleaned || cleaned === "-" || cleaned === ".") return null;
    const parsed = Number(cleaned);
    return Number.isFinite(parsed) ? parsed : null;
  }
  if (typeof value === "object") {
    return numberFromAny(value.amount ?? value.value ?? value.price ?? value.total ?? value.display_amount);
  }
  return null;
}

function firstNumberFromPaths(source: any, paths: string[]): number | null {
  for (const path of paths) {
    const parts = path.split(".");
    let value = source;
    for (const part of parts) {
      if (value === null || value === undefined) break;
      value = value[part];
    }
    const parsed = numberFromAny(value);
    if (parsed !== null && parsed > 0) return parsed;
  }
  return null;
}

function marketplaceItemGrossLine(item: any, qty: number): number | null {
  const line = firstNumberFromPaths(item, [
    "gross_amount", "total_amount", "item_total", "line_total", "subtotal", "sub_total", "total_price", "sale_total", "payment_amount", "amount",
    "total_amount.amount", "item_total.amount", "line_total.amount", "subtotal.amount", "sub_total.amount", "total_price.amount", "sale_total.amount", "payment_amount.amount", "amount.amount",
  ]);
  if (line !== null) return line;

  const unit = firstNumberFromPaths(item, [
    "model_discounted_price", "discounted_price", "seller_discounted_price", "price_after_discount", "after_discount_price", "sale_price", "sku_sale_price", "item_price", "price", "product_price", "current_price",
    "model_discounted_price.amount", "discounted_price.amount", "seller_discounted_price.amount", "price_after_discount.amount", "after_discount_price.amount", "sale_price.amount", "sku_sale_price.amount", "item_price.amount", "price.amount", "product_price.amount", "current_price.amount",
  ]);
  if (unit !== null) return unit * qty;

  const original = firstNumberFromPaths(item, ["original_price", "model_original_price", "before_discount_price", "list_price", "original_price.amount", "model_original_price.amount", "before_discount_price.amount", "list_price.amount"]);
  const sellerDiscount = firstNumberFromPaths(item, ["seller_discount", "seller_discount_amount", "seller_discount_total", "discount_from_seller", "discount_seller", "seller_discount.amount", "seller_discount_amount.amount", "seller_discount_total.amount", "discount_from_seller.amount", "discount_seller.amount"]) ?? 0;
  if (original !== null) return Math.max(original * qty - sellerDiscount, 0);
  return null;
}

function marketplaceItemPayoutLine(item: any, qty: number): number | null {
  const line = firstNumberFromPaths(item, [
    "net_settlement", "settlement_amount", "payout_amount", "paid_amount", "received_amount", "released_amount", "escrow_amount", "actual_amount", "net_amount",
    "net_settlement.amount", "settlement_amount.amount", "payout_amount.amount", "paid_amount.amount", "received_amount.amount", "released_amount.amount", "escrow_amount.amount", "actual_amount.amount", "net_amount.amount",
  ]);
  if (line !== null) return line;
  const unit = firstNumberFromPaths(item, ["unit_payout_amount", "unit_paid_amount", "unit_net_settlement", "unit_received_amount", "unit_payout_amount.amount", "unit_paid_amount.amount", "unit_net_settlement.amount", "unit_received_amount.amount"]);
  if (unit !== null) return unit * qty;
  return null;
}



function detectCancelRequest(raw: any): { id: string | null; status: string | null; reason: string | null; note: string | null; requestedAt: unknown; raw: any | null } {
  // Strict mode: jangan scan semua key yang mengandung kata "cancel".
  // Beberapa response TikTok membawa object cancel/cancellation sebagai metadata kosong/riwayat,
  // dan versi lama salah menganggap itu sebagai pengajuan cancel aktif.
  const directCandidates = [
    raw?.cancel_request,
    raw?.cancellation_request,
    raw?.buyer_cancel_request,
    raw?.cancel_order_request,
    raw?.cancel_info,
    raw?.cancellation_info,
  ];

  for (const candidate of directCandidates) {
    const source = Array.isArray(candidate)
      ? candidate.find((item) => item && typeof item === "object")
      : candidate;
    if (!source || typeof source !== "object") continue;

    const status = firstTextDeep(source, [
      "status",
      "cancel_status",
      "cancellation_status",
      "request_status",
      "cancel_request_status",
      "buyer_cancel_status",
    ]);

    const normalizedStatus = normalizeCancelRequestStatus(status);
    if (!isActiveCancelRequest(normalizedStatus)) continue;

    const id = firstTextDeep(source, ["id", "cancel_id", "cancellation_id", "request_id", "cancel_request_id", "cancel_order_id"]);
    const reason = firstTextDeep(source, ["reason", "cancel_reason", "cancellation_reason", "reason_text", "buyer_cancel_reason", "cancel_reason_text"]);
    const note = firstTextDeep(source, ["buyer_note", "buyer_message", "message", "remark", "comment", "description"]);
    const requestedAt = firstValueDeep(source, ["create_time", "created_at", "request_time", "requested_at", "cancel_time", "cancel_request_time"]);

    return {
      id: id || null,
      status: normalizedStatus,
      reason: reason || null,
      note: note || null,
      requestedAt: requestedAt || null,
      raw: source,
    };
  }

  // Fallback level order hanya dipakai kalau ada status cancel request eksplisit di root.
  // Jangan default ke CANCEL_REQUESTED hanya karena ada field cancel_reason/cancel_time.
  const rootStatus = firstTextDeep(raw, [
    "cancel_request_status",
    "buyer_cancel_status",
    "buyer_request_status",
    "cancellation_status",
    "cancel_status",
  ]);
  const normalizedRootStatus = normalizeCancelRequestStatus(rootStatus);
  if (!isActiveCancelRequest(normalizedRootStatus)) {
    return { id: null, status: null, reason: null, note: null, requestedAt: null, raw: null };
  }

  return {
    id: firstTextDeep(raw, ["cancel_request_id", "cancel_id", "cancellation_id", "request_id"]) || null,
    status: normalizedRootStatus,
    reason: firstTextDeep(raw, ["cancel_reason", "cancellation_reason", "buyer_cancel_reason"]) || null,
    note: firstTextDeep(raw, ["buyer_cancel_note", "buyer_note", "buyer_message", "cancel_note"]) || null,
    requestedAt: firstValueDeep(raw, ["cancel_request_time", "cancel_time", "requested_at", "request_time"]),
    raw: {
      status: normalizedRootStatus,
      id: firstTextDeep(raw, ["cancel_request_id", "cancel_id", "cancellation_id", "request_id"]),
      reason: firstTextDeep(raw, ["cancel_reason", "cancellation_reason", "buyer_cancel_reason"]),
    },
  };
}

function normalizeCancelRequestStatus(statusRaw: unknown): string | null {
  const status = text(statusRaw).toUpperCase().replace(/[\s-]+/g, "_");
  if (!status) return null;
  return status;
}

function isActiveCancelRequest(statusRaw: unknown): boolean {
  const status = normalizeCancelRequestStatus(statusRaw);
  if (!status) return false;

  const active = new Set([
    "REQUESTED",
    "REQUEST_PENDING",
    "CANCEL_REQUESTED",
    "CANCELLATION_REQUESTED",
    "BUYER_CANCEL_REQUESTED",
    "PENDING",
    "PENDING_APPROVAL",
    "WAITING_SELLER_RESPONSE",
    "SELLER_CONFIRMATION_PENDING",
    "TO_APPROVE",
    "IN_REVIEW",
    "PROCESSING",
    "IN_CANCEL",
    "TO_CANCEL",
  ]);

  return active.has(status);
}

function firstValueDeep(obj: any, paths: string[]): any {
  for (const path of paths) {
    const value = getPath(obj, path);
    if (value !== undefined && value !== null && value !== "") return value;
  }
  return null;
}

function firstTextDeep(obj: any, paths: string[]): string | null {
  const value = firstValueDeep(obj, paths);
  return text(value) || null;
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

function toIsoFromAny(value: unknown): string | null {
  if (value === null || value === undefined || value === "") return null;
  if (typeof value === "number") {
    const ms = value > 10_000_000_000 ? value : value * 1000;
    const date = new Date(ms);
    return Number.isNaN(date.getTime()) ? null : date.toISOString();
  }
  const textValue = text(value);
  if (!textValue) return null;
  if (/^\d+$/.test(textValue)) {
    const parsed = Number(textValue);
    if (Number.isFinite(parsed)) return toIsoFromAny(parsed);
  }
  const date = new Date(textValue);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

function detectTrackingNumber(raw: any): string | null {
  return firstNonEmptyDeep([
    raw?.tracking_number,
    raw?.tracking_no,
    raw?.trackingNumber,
    raw?.waybill_number,
    raw?.waybill_no,
    raw?.awb_number,
    raw?.airway_bill,
    raw?.airway_bill_no,
    raw?.awbNo,
    raw?.logistics?.tracking_number,
    raw?.logistic?.tracking_number,
    raw?.shipping?.tracking_number,
    raw?.shipping_info?.tracking_number,
    raw?.shippingInfo?.tracking_number,
    raw?.package?.tracking_number,
    raw?.package_info?.tracking_number,
    raw?.packages?.map((p: any) => [p?.tracking_number, p?.tracking_no, p?.waybill_number, p?.waybill_no, p?.awb_number]),
    raw?.package_list?.map((p: any) => [p?.tracking_number, p?.tracking_no, p?.waybill_number, p?.waybill_no, p?.awb_number]),
    raw?.shipping_packages?.map((p: any) => [p?.tracking_number, p?.tracking_no, p?.waybill_number, p?.waybill_no, p?.awb_number]),
  ]);
}

function detectPackageId(raw: any): string | null {
  return firstNonEmptyDeep([
    raw?.package_id,
    raw?.packageId,
    raw?.package?.id,
    raw?.package_info?.package_id,
    raw?.packages?.map((p: any) => [p?.id, p?.package_id, p?.packageId]),
    raw?.package_list?.map((p: any) => [p?.id, p?.package_id, p?.packageId]),
    raw?.shipping_packages?.map((p: any) => [p?.id, p?.package_id, p?.packageId]),
  ]);
}

function detectShippingProviderName(raw: any): string | null {
  return firstNonEmptyDeep([
    raw?.shipping_provider_name,
    raw?.shipping_provider,
    raw?.logistics_provider_name,
    raw?.logistics?.provider_name,
    raw?.logistic?.provider_name,
    raw?.shipping?.provider_name,
    raw?.shipping_info?.shipping_provider_name,
    raw?.package?.shipping_provider_name,
    raw?.packages?.map((p: any) => [p?.shipping_provider_name, p?.shipping_provider, p?.provider_name]),
    raw?.package_list?.map((p: any) => [p?.shipping_provider_name, p?.shipping_provider, p?.provider_name]),
  ]);
}

function detectLogisticStatus(raw: any): string | null {
  return firstNonEmptyDeep([
    raw?.logistic_status,
    raw?.logistics_status,
    raw?.shipping_status,
    raw?.fulfillment_status,
    raw?.logistics?.status,
    raw?.logistic?.status,
    raw?.shipping?.status,
    raw?.package?.status,
    raw?.packages?.map((p: any) => [p?.status, p?.logistic_status, p?.shipping_status]),
    raw?.package_list?.map((p: any) => [p?.status, p?.logistic_status, p?.shipping_status]),
  ]);
}

function detectLabelCode(raw: any): string | null {
  return firstNonEmptyDeep([
    raw?.label_code,
    raw?.shipping_label_code,
    raw?.barcode,
    raw?.label?.barcode,
    raw?.package?.label_code,
    raw?.packages?.map((p: any) => [p?.label_code, p?.shipping_label_code, p?.barcode]),
    raw?.package_list?.map((p: any) => [p?.label_code, p?.shipping_label_code, p?.barcode]),
  ]);
}

function firstNonEmptyDeep(values: any[]): string | null {
  for (const value of values) {
    const found = firstNonEmptyOne(value);
    if (found) return found;
  }
  return null;
}

function firstNonEmptyOne(value: any): string | null {
  if (Array.isArray(value)) {
    for (const child of value) {
      const found = firstNonEmptyOne(child);
      if (found) return found;
    }
    return null;
  }
  const t = text(value);
  return t ? t : null;
}

function collectOrders(jsonRes: any): any[] {
  const data = jsonRes?.data ?? jsonRes?.response?.data ?? jsonRes?.response ?? jsonRes;
  const candidates = [
    data?.orders,
    data?.order_list,
    data?.list,
    data?.items,
    data?.data?.orders,
    data?.data?.order_list,
  ];
  for (const item of candidates) {
    if (Array.isArray(item)) return item;
  }
  return [];
}

function orderIdValue(order: any): string | null {
  return text(order?.id) || text(order?.order_id) || text(order?.orderId) || text(order?.order_sn) || text(order?.orderSn);
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
  if (!res.ok || !jsonRes) throw new Error(`TikTok API HTTP ${res.status}: ${JSON.stringify(jsonRes)}`);

  const code = jsonRes.code;
  if (code !== undefined && String(code) !== "0" && String(code).toLowerCase() !== "success") {
    throw new Error(`TikTok API error: ${JSON.stringify(jsonRes)}`);
  }
  return jsonRes;
}

async function refreshTikTokAccessTokenIfNeeded(admin: any, account: any, force = false): Promise<{ account: any; accessToken: string }> {
  const tokenSecret = requiredEnv("MARKETPLACE_TOKEN_ENCRYPTION_KEY");
  const currentAccessToken = await decryptText(text(account.access_token_encrypted), tokenSecret);
  if (!currentAccessToken) throw new Error("TikTok access token kosong. Re-authorize account.");

  const expiredAtMs = account.access_token_expired_at ? new Date(account.access_token_expired_at).getTime() : 0;
  const safeUntilMs = Date.now() + 10 * 60 * 1000;
  if (!force && expiredAtMs > safeUntilMs) return { account, accessToken: currentAccessToken };

  const refreshToken = await decryptText(text(account.refresh_token_encrypted), tokenSecret);
  if (!refreshToken) {
    await markMarketplaceAuthExpired(admin, account, "Refresh token TikTok kosong. Reconnect TikTok Shop diperlukan.");
    throw new Error("Refresh token TikTok kosong. Reconnect TikTok Shop diperlukan.");
  }

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
    await markMarketplaceAuthExpired(admin, account, `Refresh token TikTok gagal: ${JSON.stringify(maskTokenObject(payload))}`);
    throw new Error(`Refresh token TikTok gagal. Reconnect TikTok Shop diperlukan. Detail: ${JSON.stringify(maskTokenObject(payload))}`);
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

async function markMarketplaceAuthExpired(admin: any, account: any, message: string) {
  await admin
    .from("marketplace_accounts")
    .update({ status: "error", last_error: message, updated_at: new Date().toISOString() })
    .eq("marketplace_account_id", account.marketplace_account_id);
}

function isTikTokAuthError(err: unknown): boolean {
  const message = String(err).toLowerCase();
  return message.includes("105001") || message.includes("access token is invalid") || message.includes("invalid access token") || message.includes("401");
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
    if (!ivB64 || !dataB64) throw new Error("Format token marketplace tidak valid. Re-authorize toko dulu.");
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

function pickAuthorizedShop(jsonRes: any, account: any, currentCipher: string | null): any | null {
  const shops = collectAuthorizedShops(jsonRes);
  if (shops.length === 0) return null;
  const currentShopId = text(account.shop_id);
  const currentName = text(account.shop_name) || text(account.store_alias);
  const byCipher = shops.find((shop) => shopCipherValue(shop) && shopCipherValue(shop) === currentCipher);
  if (byCipher) return byCipher;
  const byId = shops.find((shop) => currentShopId && shopIdValue(shop) === currentShopId);
  if (byId) return byId;
  const byName = shops.find((shop) => currentName && shopNameValue(shop)?.toLowerCase() === currentName.toLowerCase());
  return byName || shops[0];
}

function collectAuthorizedShops(jsonRes: any): any[] {
  const response = jsonRes?.response ?? jsonRes;
  const data = response?.data ?? response;
  const candidates = [data?.shops, data?.shop_list, data?.authorized_shops, data?.shops_list, response?.shops, response?.shop_list];
  for (const item of candidates) if (Array.isArray(item)) return item;
  return [];
}

function shopCipherValue(shop: any): string | null {
  return text(shop?.shop_cipher) || text(shop?.cipher) || text(shop?.shopCipher) || text(shop?.shop?.shop_cipher) || text(shop?.seller?.shop_cipher);
}

function shopIdValue(shop: any): string | null {
  return text(shop?.shop_id) || text(shop?.id) || text(shop?.shop_code) || text(shop?.shopId) || text(shop?.shop?.id) || text(shop?.seller?.shop_id);
}

function shopNameValue(shop: any): string | null {
  return text(shop?.shop_name) || text(shop?.name) || text(shop?.shopName) || text(shop?.shop?.name) || text(shop?.seller?.shop_name);
}

function parseAmount(value: unknown): number | null {
  if (value === null || value === undefined) return null;
  if (typeof value === "number") return value;
  if (typeof value === "string") {
    const n = Number(value.replace(/[^0-9.-]/g, ""));
    return Number.isFinite(n) ? n : null;
  }
  if (typeof value === "object") {
    const obj: any = value;
    return parseAmount(obj.amount) ?? parseAmount(obj.value) ?? parseAmount(obj.total);
  }
  return null;
}

function secondsToIso(value: unknown): string | null {
  if (value === null || value === undefined || value === "") return null;
  if (typeof value === "string" && value.includes("T")) return value;
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return null;
  const ms = n > 1000000000000 ? n : n * 1000;
  return new Date(ms).toISOString();
}

function expireValueToIso(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) return null;
  const seconds = n > 1000000000 ? n : Math.floor(Date.now() / 1000) + n;
  return new Date(seconds * 1000).toISOString();
}

function deepMerge(base: any, extra: any): any {
  if (!base || typeof base !== "object") return extra;
  if (!extra || typeof extra !== "object") return base;
  return { ...base, ...extra };
}

function safeJsonForDb(input: any): any {
  if (input === undefined) return null;
  return JSON.parse(JSON.stringify(input));
}

function safeJson(req: Request): Promise<any> {
  return req.json().catch(() => ({}));
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`${name} kosong`);
  return value;
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

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "content-type": "application/json; charset=utf-8" },
  });
}

function mask(value: string): string {
  if (!value) return "";
  if (value.length <= 10) return "****";
  return `${value.slice(0, 6)}…${value.slice(-4)}`;
}

function maskTokenObject(input: any): any {
  if (input === null || input === undefined) return input;
  if (typeof input === "string") return input.length > 24 ? mask(input) : input;
  if (Array.isArray(input)) return input.map(maskTokenObject);
  if (typeof input === "object") {
    const out: Record<string, any> = {};
    for (const [key, value] of Object.entries(input)) {
      const lowerKey = key.toLowerCase();
      out[key] = lowerKey.includes("token") || lowerKey.includes("secret") || lowerKey.includes("auth_code") || lowerKey === "code"
        ? (typeof value === "string" ? mask(value) : "***")
        : maskTokenObject(value);
    }
    return out;
  }
  return input;
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function base64UrlToBytes(value: string): Uint8Array {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  return base64ToBytes(normalized);
}

function base64ToBytes(value: string): Uint8Array {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
