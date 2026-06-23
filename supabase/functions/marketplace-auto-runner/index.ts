import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
const FUNCTION_VERSION = "marketplace-auto-runner";
const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type, x-marketplace-cron-secret, x-stock-sync-cron-secret",
  "access-control-allow-methods": "POST, OPTIONS"
};
Deno.serve(async (req)=>{
  if (req.method === "OPTIONS") return new Response("ok", {
    headers: corsHeaders
  });
  try {
    if (req.method !== "POST") return json({
      ok: false,
      message: "Method not allowed"
    }, 405);
    const supabaseUrl = requiredEnv("SUPABASE_URL");
    const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");
    const incomingSecret = String(req.headers.get("x-marketplace-cron-secret") || req.headers.get("x-stock-sync-cron-secret") || "").trim();
    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false
      },
      global: {
        headers: {
          "x-client-info": FUNCTION_VERSION
        }
      }
    });
    const cronAuth = await verifyMarketplaceCronSecret(admin, incomingSecret);
    if (!cronAuth.ok) {
      return json({
        ok: false,
        message: cronAuth.message
      }, cronAuth.status);
    }
    const cronSecret = incomingSecret;
    const body = await safeJson(req);
    const force = body.force === true;
    const tenantFilter = text(body.tenant_id);
    const accountFilter = text(body.marketplace_account_id);
    const maxAccounts = clampInt(body.max_accounts, 1, 100, 50);
    const maxOrderAccounts = clampInt(body.max_order_accounts ?? body.order_max_accounts ?? Deno.env.get("ORDER_PULL_MAX_ACCOUNTS"), 1, 100, 100);
    const queueLimit = clampInt(body.stock_sync_limit, 1, 50, 20);
    // v7: order cron 2 menit harus bounded. Default sengaja kecil supaya parent request tidak 546/timeout.
    const maxOrderJobs = clampInt(body.max_order_jobs ?? Deno.env.get("ORDER_PULL_MAX_JOBS"), 1, 12, 1);
    const maxPagesPerAccount = clampInt(body.max_pages_per_account ?? Deno.env.get("ORDER_PULL_MAX_PAGES_PER_ACCOUNT"), 1, 3, 1);
    const maxOrdersPerAccount = clampInt(body.max_orders_per_account ?? Deno.env.get("ORDER_PULL_MAX_ORDERS_PER_ACCOUNT"), 1, 100, 10);
    const maxDetailsPerAccount = clampInt(body.max_details_per_account ?? Deno.env.get("ORDER_PULL_MAX_DETAILS_PER_ACCOUNT"), 0, 120, 30);
    const childTimeoutMs = clampInt(body.child_timeout_ms ?? Deno.env.get("MARKETPLACE_RUNNER_CHILD_TIMEOUT_MS"), 3000, 45000, 12000);
    const statusRefreshRangeDays = clampInt(body.order_status_range_days ?? body.status_range_days ?? Deno.env.get("ORDER_STATUS_REFRESH_RANGE_DAYS"), 1, 90, 90);
    const maxStatusRefreshPerAccount = clampInt(body.max_status_refresh_per_account ?? body.max_existing_orders ?? Deno.env.get("ORDER_STATUS_REFRESH_MAX_EXISTING"), 0, 200, 10);
    const runPendingDrain = body.run_pending_drain !== false;
    const runStatusRefresh = body.run_order_status_refresh !== false;
    const runReturnRefund = body.run_return_refund_pull === true;
    const maxFinanceJobs = clampInt(body.max_finance_jobs ?? Deno.env.get("FINANCE_SYNC_MAX_JOBS"), 1, 3, 3);
    const maxFinanceOrders = clampInt(body.max_finance_orders ?? Deno.env.get("FINANCE_SYNC_MAX_ORDERS"), 1, 80, 50);
    const maxFinanceBatches = clampInt(body.max_finance_batches ?? Deno.env.get("FINANCE_SYNC_MAX_BATCHES"), 1, 3, 3);
    const cleanupStale = body.cleanup_stale !== false;
    const runStock = body.run_stock === true;
    const runOrder = body.run_order !== false;
    const runOrderEnqueue = body.run_order_enqueue !== false && body.skip_order_enqueue !== true;
    const runFinanceStatement = body.run_finance_statement === true || body.run_finance === true || body.run_payout === true;
    const runFinancePayout = body.run_finance_payout_direct === true || body.run_direct_payout === true;
    const stockResult = runStock ? await withRunnerLock(admin, "stock_sync", 280, ()=>runAutoStockSync({
        admin,
        supabaseUrl,
        serviceRoleKey,
        cronSecret,
        tenantFilter,
        accountFilter,
        force,
        maxAccounts,
        queueLimit
      })) : {
      skipped: true,
      reason: "run_stock=false"
    };
    const orderResult = runOrder ? await withRunnerLock(admin, "order_pull", 110, ()=>runAutoOrderPull({
        admin,
        supabaseUrl,
        serviceRoleKey,
        cronSecret,
        tenantFilter,
        accountFilter,
        force,
        maxAccounts: maxOrderAccounts,
        maxOrderJobs,
        maxPagesPerAccount,
        maxOrdersPerAccount,
        maxDetailsPerAccount,
        childTimeoutMs,
        statusRefreshRangeDays,
        maxStatusRefreshPerAccount,
        runOrderEnqueue,
        runPendingDrain,
        runStatusRefresh,
        runReturnRefund,
        cleanupStale
      })) : {
      skipped: true,
      reason: "run_order=false"
    };
    const financeStatementResult = runFinanceStatement ? await withRunnerLock(admin, "finance_payout", 280, ()=>runAutoFinanceStatementJobs({
        admin,
        supabaseUrl,
        serviceRoleKey,
        cronSecret,
        tenantFilter,
        accountFilter,
        force,
        maxAccounts,
        maxFinanceJobs,
        maxFinanceOrders,
        maxFinanceBatches,
        cleanupStale
      })) : {
      skipped: true,
      reason: "run_finance=false"
    };
    const financeResult = runFinancePayout ? await withRunnerLock(admin, "finance_direct_payout", 280, ()=>runAutoFinancePayoutSync({
        admin,
        supabaseUrl,
        serviceRoleKey,
        cronSecret,
        tenantFilter,
        accountFilter,
        force,
        maxAccounts
      })) : {
      skipped: true,
      reason: "direct payout dimatikan; pakai finance job-based 5 menit"
    };
    return json({
      ok: true,
      version: FUNCTION_VERSION,
      stock_sync: stockResult,
      order_pull: orderResult,
      finance_statement_jobs: financeStatementResult,
      finance_payout_sync: financeResult
    });
  } catch (err) {
    return json({
      ok: false,
      version: FUNCTION_VERSION,
      message: String(err)
    }, 500);
  }
});
async function runAutoStockSync(args) {
  let settingsQuery = args.admin.from("marketplace_stock_sync_settings").select("tenant_id, auto_real_sync_enabled, interval_minutes, last_auto_run_at").eq("auto_real_sync_enabled", true).order("updated_at", {
    ascending: true
  });
  if (args.tenantFilter) settingsQuery = settingsQuery.eq("tenant_id", args.tenantFilter);
  const { data: settings, error: settingsError } = await settingsQuery;
  if (settingsError) throw new Error(`Load stock sync settings failed: ${settingsError.message}`);
  const result = {
    enabled_tenants: settings?.length || 0,
    tenants_run: 0,
    accounts_run: 0,
    queued: 0,
    worker_success: 0,
    worker_failed: 0,
    skipped: 0,
    details: []
  };
  for (const setting of settings || []){
    const tenantId = text(setting.tenant_id);
    const interval = clampInt(setting.interval_minutes, 1, 60, 10);
    if (!args.force && !isDue(setting.last_auto_run_at, interval)) {
      result.skipped += 1;
      result.details.push({
        type: "stock_sync",
        tenant_id: tenantId,
        status: "skipped_interval",
        interval_minutes: interval
      });
      continue;
    }
    result.tenants_run += 1;
    const { data: accounts, error: accountsError } = await args.admin.from("marketplace_accounts").select("marketplace_account_id, marketplace, shop_name, store_alias, status, stock_sync_enabled").eq("tenant_id", tenantId).eq("status", "active").eq("is_deleted", false).order("created_at", {
      ascending: true
    }).limit(args.maxAccounts);
    if (accountsError) {
      await updateStockSetting(args.admin, tenantId, `Auto stock sync gagal load account: ${accountsError.message}`);
      result.worker_failed += 1;
      result.details.push({
        type: "stock_sync",
        tenant_id: tenantId,
        status: "failed",
        error: accountsError.message
      });
      continue;
    }
    let tenantQueued = 0;
    let tenantSuccess = 0;
    let tenantFailed = 0;
    let tenantAccounts = 0;
    for (const account of accounts || []){
      const accountId = text(account.marketplace_account_id);
      if (args.accountFilter && accountId !== args.accountFilter) continue;
      if (account.stock_sync_enabled === false) {
        result.skipped += 1;
        result.details.push({
          type: "stock_sync",
          tenant_id: tenantId,
          account_id: accountId,
          status: "skipped_account_stock_sync_off"
        });
        continue;
      }
      result.accounts_run += 1;
      tenantAccounts += 1;
      const { data: queuedCount, error: queueError } = await args.admin.rpc("marketplace_queue_stock_sync_for_account", {
        p_tenant_id: tenantId,
        p_marketplace_account_id: accountId,
        p_reason: "auto_real_sync_10_minute_runner"
      });
      if (queueError) {
        tenantFailed += 1;
        result.worker_failed += 1;
        result.details.push({
          type: "stock_sync",
          tenant_id: tenantId,
          account_id: accountId,
          status: "queue_failed",
          error: queueError.message
        });
        continue;
      }
      const queued = Number(queuedCount || 0);
      result.queued += queued;
      tenantQueued += queued;
      if (queued <= 0) {
        result.details.push({
          type: "stock_sync",
          tenant_id: tenantId,
          account_id: accountId,
          status: "no_mapping_queued"
        });
        continue;
      }
      const worker = await invokeFunction(args.supabaseUrl, args.serviceRoleKey, args.cronSecret, "marketplace-stock-sync-worker", {
        tenant_id: tenantId,
        marketplace_account_id: accountId,
        limit: args.queueLimit,
        dry_run: false,
        source: "marketplace-auto-runner"
      });
      if (worker.ok && worker.http_status >= 200 && worker.http_status < 300 && worker.data?.ok !== false) {
        tenantSuccess += 1;
        result.worker_success += 1;
        result.details.push({
          type: "stock_sync",
          tenant_id: tenantId,
          account_id: accountId,
          status: "worker_done",
          queued,
          worker: worker.data
        });
      } else {
        tenantFailed += 1;
        result.worker_failed += 1;
        result.details.push({
          type: "stock_sync",
          tenant_id: tenantId,
          account_id: accountId,
          status: "worker_failed",
          queued,
          worker: worker.data,
          http_status: worker.http_status
        });
      }
    }
    const message = `Auto stock sync: account=${tenantAccounts}, queued=${tenantQueued}, ok=${tenantSuccess}, failed=${tenantFailed}`;
    await updateStockSetting(args.admin, tenantId, message);
  }
  return result;
}
async function runAutoOrderPull(args) {
  // AUTO_RUNNER_ORDER_LANE_DISABLED_20260624:
  // Emergency kill-switch. Unknown non-pg_cron caller is still invoking marketplace-auto-runner every ~2 minutes.
  // Keep finance/stock behavior separate; order hot lane must run from marketplace-order-dispatcher only.
  const __allowAutoRunnerOrderLane =
    (args as any)?.allow_auto_order_runner_order === true ||
    (args as any)?.allowOrderHotLane === true ||
    (args as any)?.allow_order_hot_lane === true;

  if (!__allowAutoRunnerOrderLane) {
    console.log("[marketplace-auto-runner] AUTO_RUNNER_ORDER_LANE_DISABLED_20260624", {
      reason: "unknown_non_pgcron_2min_caller",
    });

    return {
      enabled_tenants: 0,
      tenants_run: 0,
      accounts_run: 0,
      queued: 0,
      processed_jobs: 0,
      remaining_jobs: 0,
      orders: 0,
      items: 0,
      status_checked: 0,
      status_updated: 0,
      status_review_required: 0,
      failed: 0,
      skipped: 1,
      details: [
        {
          type: "order_lane_disabled",
          status: "skipped",
          reason: "AUTO_RUNNER_ORDER_LANE_DISABLED_20260624",
          message: "marketplace-auto-runner order lane disabled. Use marketplace-order-dispatcher for controlled order sync.",
        },
      ],
    };
  }
  let settingsQuery = args.admin.from("marketplace_order_pull_settings").select("tenant_id, auto_order_pull_enabled, interval_minutes, days_back, previous_unpacked_days, last_auto_run_at").eq("auto_order_pull_enabled", true).order("updated_at", {
    ascending: true
  });
  if (args.tenantFilter) settingsQuery = settingsQuery.eq("tenant_id", args.tenantFilter);
  const { data: settings, error: settingsError } = await settingsQuery;
  if (settingsError) throw new Error(`Load order pull settings failed: ${settingsError.message}`);
  const staleCleanup = args.cleanupStale ? await resetStaleJobs(args.admin) : {
    skipped: true
  };
  const result = {
    enabled_tenants: settings?.length || 0,
    tenants_run: 0,
    accounts_run: 0,
    stale_cleanup: staleCleanup,
    queued: 0,
    processed_jobs: 0,
    remaining_jobs: 0,
    orders: 0,
    items: 0,
    status_checked: 0,
    status_updated: 0,
    status_review_required: 0,
    failed: 0,
    skipped: 0,
    details: []
  };
  for (const setting of settings || []){
    const tenantId = text(setting.tenant_id);
    const interval = clampInt(setting.interval_minutes, 1, 60, 2);
    const orderDue = args.force || isDue(setting.last_auto_run_at, interval);
    // v7: pending drain dibuat opsional dan bounded. Kalau child lambat, parent tetap return sebelum pg_net timeout.
    if (args.runPendingDrain) {
      const pendingDrain = await invokeFunction(args.supabaseUrl, args.serviceRoleKey, args.cronSecret, "marketplace-order-sync-jobs", {
        mode: "process_pending",
        tenant_id: tenantId,
        marketplace_account_id: args.accountFilter || undefined,
        enqueue: false,
        process: true,
        max_accounts: args.maxAccounts,
        max_jobs: args.maxOrderJobs,
        page_size: Math.min(args.maxOrdersPerAccount, 50),
        max_pages: args.maxPagesPerAccount,
        max_details: args.maxDetailsPerAccount,
        only_latest: true,
        only_active_orders: true,
        skip_completed_orders: true,
        skip_final_orders: true,
        include_completed: false,
        source: "marketplace-auto-runner-v7-drain-pending-bounded"
      }, args.childTimeoutMs);
      if (pendingDrain.ok && pendingDrain.http_status >= 200 && pendingDrain.http_status < 300 && pendingDrain.data?.ok !== false) {
        const processedJobs = Number(pendingDrain.data?.processed || pendingDrain.data?.processed_jobs || 0);
        const remainingJobs = Number(pendingDrain.data?.remaining || pendingDrain.data?.remaining_jobs || 0);
        const orders = Number(pendingDrain.data?.orders || 0);
        const items = Number(pendingDrain.data?.items || 0);
        result.processed_jobs += processedJobs;
        result.remaining_jobs += remainingJobs;
        result.orders += orders;
        result.items += items;
        result.details.push({
          type: "order_pending_drain",
          tenant_id: tenantId,
          status: "processed",
          processed_jobs: processedJobs,
          remaining_jobs: remainingJobs,
          orders,
          items,
          response: pendingDrain.data
        });
      } else {
        result.failed += 1;
        result.details.push({
          type: "order_pending_drain",
          tenant_id: tenantId,
          status: "warning",
          response: pendingDrain.data,
          http_status: pendingDrain.http_status
        });
      }
    } else {
      result.details.push({
        type: "order_pending_drain",
        tenant_id: tenantId,
        status: "skipped_by_config"
      });
    }
    if (!args.runOrderEnqueue) {
      result.details.push({
        type: "order_pull",
        tenant_id: tenantId,
        status: "skipped_enqueue_by_config"
      });
    } else if (!orderDue) {
      result.skipped += 1;
      result.details.push({
        type: "order_pull",
        tenant_id: tenantId,
        status: "skipped_enqueue_interval_but_pending_drained",
        interval_minutes: interval
      });
      if (!args.runStatusRefresh && !args.runReturnRefund) continue;
    } else {
      result.tenants_run += 1;
      const orderJobs = await invokeFunction(args.supabaseUrl, args.serviceRoleKey, args.cronSecret, "marketplace-order-sync-jobs", {
        mode: args.force ? "backfill" : "today",
        tenant_id: tenantId,
        marketplace_account_id: args.accountFilter || undefined,
        enqueue: true,
        process: true,
        max_accounts: args.maxAccounts,
        max_jobs: args.maxOrderJobs,
        window_minutes: args.force ? 720 : 10,
        days_back: args.force ? 3 : 0,
        page_size: Math.min(args.maxOrdersPerAccount, 50),
        max_pages: args.force ? Math.max(args.maxPagesPerAccount, 2) : args.maxPagesPerAccount,
        max_details: args.maxDetailsPerAccount,
        include_update_time_search: true,
        only_latest: true,
        only_active_orders: true,
        skip_completed_orders: true,
        skip_final_orders: true,
        include_completed: false,
        source: "marketplace-auto-runner-v8-hot-today-no-90d-refresh",
        refresh_existing_status: false
      }, args.childTimeoutMs);
      if (orderJobs.ok && orderJobs.http_status >= 200 && orderJobs.http_status < 300 && orderJobs.data?.ok !== false) {
        const queued = Number(orderJobs.data?.queued || 0);
        const processedJobs = Number(orderJobs.data?.processed || orderJobs.data?.processed_jobs || 0);
        const remainingJobs = Number(orderJobs.data?.remaining || orderJobs.data?.remaining_jobs || 0);
        const orders = Number(orderJobs.data?.orders || 0);
        const items = Number(orderJobs.data?.items || 0);
        const accounts = Number(orderJobs.data?.accounts || 0);
        result.queued += queued;
        result.processed_jobs += processedJobs;
        result.remaining_jobs += remainingJobs;
        result.orders += orders;
        result.items += items;
        result.accounts_run += accounts;
        result.details.push({
          type: "order_pull_jobs",
          tenant_id: tenantId,
          status: "jobs_processed",
          queued,
          processed_jobs: processedJobs,
          remaining_jobs: remainingJobs,
          orders,
          items,
          response: orderJobs.data
        });
      } else {
        result.failed += 1;
        result.details.push({
          type: "order_pull_jobs",
          tenant_id: tenantId,
          status: "jobs_failed",
          response: orderJobs.data,
          http_status: orderJobs.http_status
        });
        await updateOrderSetting(args.admin, tenantId, `Auto order jobs gagal: ${JSON.stringify(orderJobs.data || {})}`);
        if (!args.runStatusRefresh && !args.runReturnRefund) continue;
      }
    }
    const { data: accounts, error: accountsError } = await args.admin.from("marketplace_accounts").select("marketplace_account_id, marketplace, shop_name, store_alias, status").eq("tenant_id", tenantId).eq("status", "active").eq("is_deleted", false).order("created_at", {
      ascending: true
    }).limit(args.maxAccounts);
    if (accountsError) {
      result.failed += 1;
      result.details.push({
        type: "order_status_refresh",
        tenant_id: tenantId,
        status: "failed_load_account",
        error: accountsError.message
      });
      await updateOrderSetting(args.admin, tenantId, `Auto order status gagal load account: ${accountsError.message}`);
      continue;
    }
    let tenantStatusChecked = 0;
    let tenantStatusUpdated = 0;
    let tenantStatusReviewRequired = 0;
    let tenantFailed = 0;
    for (const account of accounts || []){
      const accountId = text(account.marketplace_account_id);
      const marketplace = text(account.marketplace);
      if (args.accountFilter && accountId !== args.accountFilter) continue;
      if (![
        "tiktok_shop",
        "shopee"
      ].includes(marketplace)) {
        result.skipped += 1;
        result.details.push({
          type: "order_pull",
          tenant_id: tenantId,
          account_id: accountId,
          marketplace,
          status: "skipped_unsupported_marketplace"
        });
        continue;
      }
      if (args.runStatusRefresh) {
        const statusRefresh = await invokeFunction(args.supabaseUrl, args.serviceRoleKey, args.cronSecret, "marketplace-order-pull", {
          action: "refresh_existing_status",
          tenant_id: tenantId,
          marketplace_account_id: accountId,
          status_range_days: args.statusRefreshRangeDays,
          max_existing_orders: args.maxStatusRefreshPerAccount,
          source: "marketplace-auto-runner-v9-status-refresh-90d-payout-priority",
          sync_status_aliases: true,
          canonical_status_sync: true,
          auto_status_only: true,
          only_unfinished: true,
          only_active_orders: true,
          skip_completed_orders: true,
          skip_final_orders: true,
          include_completed: false,
          exclude_statuses: [
            "COMPLETED",
            "CANCELLED",
            "CANCELED"
          ]
        }, args.childTimeoutMs);
        if (statusRefresh.ok && statusRefresh.http_status >= 200 && statusRefresh.http_status < 300 && statusRefresh.data?.ok !== false) {
          const checked = Number(statusRefresh.data?.checked || 0);
          const updated = Number(statusRefresh.data?.updated || 0);
          const reviewRequired = Number(statusRefresh.data?.review_required || 0);
          result.status_checked += checked;
          result.status_updated += updated;
          result.status_review_required += reviewRequired;
          tenantStatusChecked += checked;
          tenantStatusUpdated += updated;
          tenantStatusReviewRequired += reviewRequired;
          result.details.push({
            type: "order_status_refresh",
            tenant_id: tenantId,
            account_id: accountId,
            status: "status_refresh_done",
            checked,
            updated,
            review_required: reviewRequired,
            response: statusRefresh.data
          });
          await insertMarketplaceRunnerLog(args.admin, account, "success", `Refresh status non-final 90 hari: cek=${checked}, update=${updated}, review=${reviewRequired}`, {
            type: "order_status_refresh",
            range_days: args.statusRefreshRangeDays,
            max_existing_orders: args.maxStatusRefreshPerAccount
          }, statusRefresh.data);
        } else {
          result.details.push({
            type: "order_status_refresh",
            tenant_id: tenantId,
            account_id: accountId,
            status: "status_refresh_warning",
            response: statusRefresh.data,
            http_status: statusRefresh.http_status
          });
          await insertMarketplaceRunnerLog(args.admin, account, "warning", `Refresh status non-final gagal/peringatan: HTTP ${statusRefresh.http_status}`, {
            type: "order_status_refresh",
            range_days: args.statusRefreshRangeDays,
            max_existing_orders: args.maxStatusRefreshPerAccount
          }, statusRefresh.data);
        }
      } else {
        result.details.push({
          type: "order_status_refresh",
          tenant_id: tenantId,
          account_id: accountId,
          status: "skipped_by_config"
        });
      }
      if (args.runReturnRefund) {
        const flags = await invokeFunction(args.supabaseUrl, args.serviceRoleKey, args.cronSecret, "marketplace-return-refund-pull", {
          tenant_id: tenantId,
          marketplace_account_id: accountId,
          days_back: 1,
          limit: 10,
          max_pages: 1,
          source: "marketplace-auto-runner-v7-return-flags-bounded",
          auto_today_only: true
        }, args.childTimeoutMs);
        if (!flags.ok || flags.http_status >= 300 || flags.data?.ok === false) {
          tenantFailed += 1;
          result.details.push({
            type: "return_refund_pull",
            tenant_id: tenantId,
            account_id: accountId,
            status: "warning",
            response: flags.data,
            http_status: flags.http_status
          });
        }
      } else {
        result.details.push({
          type: "return_refund_pull",
          tenant_id: tenantId,
          account_id: accountId,
          status: "skipped_by_config"
        });
      }
    }
    // Order pull tidak refresh finance cache. Finance cache hanya disentuh runner finance 5 menit.
    const message = `Auto order: antrean=${result.queued}, diproses=${result.processed_jobs}, sisa=${result.remaining_jobs}, order=${result.orders}, item=${result.items}, cek_status=${tenantStatusChecked}, update_status=${tenantStatusUpdated}, review=${tenantStatusReviewRequired}, gagal=${tenantFailed}`;
    await updateOrderSetting(args.admin, tenantId, message);
  }
  return result;
}
async function runAutoFinanceStatementJobs(args) {
  if (args.cleanupStale) await resetStaleJobs(args.admin);
  // statement-first-runner-v1: TikTok payout is statement-settlement based.
  // Pull recent statements repeatedly so newly SETTLED payouts are picked up without order-probe spam.
  const jakartaDateString = (offsetDays = 0)=>{
    const now = new Date();
    const utc = now.getTime() + now.getTimezoneOffset() * 60000;
    const jakarta = new Date(utc + 7 * 60 * 60000 + offsetDays * 24 * 60 * 60000);
    const y = jakarta.getFullYear();
    const m = String(jakarta.getMonth() + 1).padStart(2, '0');
    const d = String(jakarta.getDate()).padStart(2, '0');
    return `${y}-${m}-${d}`;
  };
  const statementEndDate = jakartaDateString(0);
  const statementStartDate = jakartaDateString(args.force ? -14 : -7);
  const body = {
    action: "pull_finance_statements_period",
    params: {
      start_date: statementStartDate,
      end_date: statementEndDate,
      page_size: 10,
      max_statements: args.force ? 20 : 10,
      max_transactions: 30,
      max_order_details: 0,
      include_sku_details: false,
      time_fields: [
        "payment_time",
        "statement_time"
      ],
      source: "marketplace-auto-runner-statement-first-v1"
    }
  };
  if (args.tenantFilter) body.params = {
    ...body.params,
    tenant_id: args.tenantFilter
  };
  if (args.accountFilter) body.params = {
    ...body.params,
    account_id: args.accountFilter
  };
  const response = await invokeFunction(args.supabaseUrl, args.serviceRoleKey, args.cronSecret, "marketplace-tiktok-service", body);
  const data = response?.data || {};
  const changed = sumNumbers([
    data.jobs,
    data.success,
    data.payout_success,
    data.statements,
    data.transactions,
    data.items,
    data.checked,
    data.updated,
    data.processed,
    data.processed_jobs
  ]);
  if (!response.ok || response.http_status < 200 || response.http_status >= 300 || data?.ok === false) {
    return {
      ...response,
      cache: {
        skipped: true,
        reason: "finance sync belum sukses; cache tidak direfresh"
      }
    };
  }
  if (changed <= 0 && args.force !== true) {
    return {
      ...response,
      cache: {
        skipped: true,
        reason: "tidak ada finance/payout baru"
      }
    };
  }
  // statement-first-skip-inline-cache-v1:
  // Finance statement pull must not be blocked by heavy cache refresh RPC.
  // Dashboard live RPC already reads marketplace_finance_reports by settlement_date.
  const cache = {
    skipped: true,
    reason: "skip_inline_cache_refresh_after_statement_pull",
    refresh_source: "finance_dashboard_snapshot_live"
  };
  return {
    ...response,
    cache
  };
}
async function withRunnerLock(admin, lockKey, ttlSeconds, run) {
  const owner = `${FUNCTION_VERSION}-${crypto.randomUUID()}`;
  let locked = false;
  let lockWarning = "";
  try {
    const { data, error } = await admin.rpc("marketplace_auto_runner_try_lock", {
      p_lock_key: lockKey,
      p_ttl_seconds: ttlSeconds,
      p_owner: owner
    });
    if (error) {
      lockWarning = error.message;
    } else if (data !== true) {
      return {
        skipped: true,
        reason: "proses sebelumnya masih berjalan",
        lock_key: lockKey
      };
    } else {
      locked = true;
    }
  } catch (err) {
    lockWarning = String(err);
  }
  try {
    const result = await run();
    if (lockWarning && result && typeof result === "object" && !Array.isArray(result)) {
      return {
        ...result,
        lock_warning: lockWarning
      };
    }
    return result;
  } finally{
    if (locked) {
      try {
        await admin.rpc("marketplace_auto_runner_release_lock", {
          p_lock_key: lockKey,
          p_owner: owner
        });
      } catch (_) {
      // Abaikan gagal release lock. Lock punya TTL dan akan dilepas otomatis.
      }
    }
  }
}
async function resetStaleJobs(admin) {
  try {
    const { data, error } = await admin.rpc("marketplace_reset_stale_auto_jobs", {
      p_order_stale_minutes: 6,
      p_finance_stale_minutes: 15,
      p_revive_failed: false
    });
    if (error) return {
      ok: false,
      message: error.message
    };
    return {
      ok: true,
      data
    };
  } catch (err) {
    return {
      ok: false,
      message: String(err)
    };
  }
}
async function invokeFunction(supabaseUrl, serviceRoleKey, cronSecret, functionName, body, timeoutMs = 45_000) {
  // HOT LANE SAFETY PATCH v8:
  // Auto-runner boleh pull order hari ini, tapi tidak boleh ikut refresh non-final 90 hari.
  // Refresh 90 hari harus dipisah ke warm/cold lane agar Shopee/TikTok tidak kena API spike.
  const __hotLanePayload =
    body && typeof body === "object"
      ? (body as Record<string, unknown>)
      : null;

  const __skipHotLaneNonfinal90dRefresh =
    functionName === "marketplace-order-pull" &&
    __hotLanePayload?.type === "order_status_refresh" &&
    Number(__hotLanePayload?.range_days ?? 0) >= 90 &&
    __hotLanePayload?.run_status_refresh_90d !== true &&
    __hotLanePayload?.allow_nonfinal_90d_refresh !== true &&
    __hotLanePayload?.skip_nonfinal_90d_refresh !== false;

  if (__skipHotLaneNonfinal90dRefresh) {
    console.log("[marketplace-auto-runner] hot_lane_skip_nonfinal_90d_refresh", {
      functionName: functionName,
      rangeDays: __hotLanePayload?.range_days,
      maxExistingOrders: __hotLanePayload?.max_existing_orders,
    });

    return {
      ok: true,
      http_status: 200,
      data: {
        ok: true,
        skipped: true,
        skipped_reason: "hot_lane_skip_nonfinal_90d_refresh",
        message: "Skipped non-final 90d status refresh from marketplace-auto-runner hot lane.",
        function: functionName,
        request_payload: __hotLanePayload,
      },
      elapsed_ms: 0,
    };
  }

  const url = `${supabaseUrl.replace(/\/+$/, "")}/functions/v1/${functionName}`;
  const startedAt = Date.now();
  const controller = new AbortController();
  const timeout = setTimeout(()=>controller.abort(`child_timeout_${timeoutMs}ms`), timeoutMs);
  const edgeAuthKey = String(
    Deno.env.get("EDGE_FUNCTION_AUTH_KEY") ||
    Deno.env.get("SUPABASE_ANON_KEY") ||
    ""
  ).trim();

  if (!edgeAuthKey) {
    return {
      ok: false,
      status: 500,
      data: {
        ok: false,
        code: "MISSING_EDGE_AUTH_KEY",
        message: "SUPABASE_ANON_KEY belum tersedia untuk invoke child Edge Function.",
      },
      elapsed_ms: Date.now() - startedAt,
    };
  }

  try {
    const res = await fetch(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "authorization": `Bearer ${edgeAuthKey}`,
        "apikey": edgeAuthKey,
        "x-marketplace-cron-secret": cronSecret
      },
      body: JSON.stringify(body),
      signal: controller.signal
    });
    const parsed = await res.json().catch(async ()=>({
        raw: await res.text().catch(()=>"")
      }));
    const data = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {
      value: parsed
    };
    return {
      ok: res.ok,
      http_status: res.status,
      data: {
        ...data,
        runner_child_ms: Date.now() - startedAt
      }
    };
  } catch (err) {
    return {
      ok: false,
      http_status: 0,
      data: {
        ok: false,
        message: String(err),
        child_function: functionName,
        runner_child_timeout_ms: timeoutMs,
        runner_child_ms: Date.now() - startedAt
      }
    };
  } finally{
    clearTimeout(timeout);
  }
}

async function insertMarketplaceRunnerLog(admin, account, status, message, request, response) {
  try {
    await admin.from("marketplace_sync_logs").insert({
      marketplace_account_id: account.marketplace_account_id,
      marketplace: text(account.marketplace) || "unknown",
      action: "order_status_refresh_nonfinal_90d",
      status,
      message,
      request_payload: request,
      response_payload: response,
      created_at: new Date().toISOString()
    });
  } catch (_) {
  }
}

async function updateStockSetting(admin, tenantId, message) {
  await admin.from("marketplace_stock_sync_settings").update({
    last_auto_run_at: new Date().toISOString(),
    last_auto_run_message: message,
    updated_at: new Date().toISOString()
  }).eq("tenant_id", tenantId);
}
async function updateOrderSetting(admin, tenantId, message) {
  await admin.from("marketplace_order_pull_settings").update({
    last_auto_run_at: new Date().toISOString(),
    last_auto_run_message: message,
    updated_at: new Date().toISOString()
  }).eq("tenant_id", tenantId);
}
function todayWibDateRange() {
  const wibOffsetMs = 7 * 60 * 60 * 1000;
  const nowWib = new Date(Date.now() + wibOffsetMs);
  const yyyy = nowWib.getUTCFullYear();
  const mm = String(nowWib.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(nowWib.getUTCDate()).padStart(2, "0");
  const today = `${yyyy}-${mm}-${dd}`;
  return {
    startDate: today,
    endDate: today
  };
}
function isDue(lastRunAt, intervalMinutes) {
  if (!lastRunAt) return true;
  const last = new Date(String(lastRunAt)).getTime();
  if (!Number.isFinite(last)) return true;
  return Date.now() - last >= Math.max(1, intervalMinutes) * 60_000 - 50_000;
}
function text(value) {
  return String(value ?? "").trim();
}
function clampInt(value, min, max, fallback) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(min, Math.min(max, parsed));
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

  const fallbackSecret = String(
    Deno.env.get("MARKETPLACE_CRON_SECRET") ||
    Deno.env.get("MARKETPLACE_AUTO_SYNC_CRON_SECRET") ||
    Deno.env.get("STOCK_SYNC_CRON_SECRET") ||
    "",
  ).trim();

  if (fallbackSecret && incomingSecret === fallbackSecret) {
    return { ok: true, status: 200, message: "ok" };
  }

  if (error) {
    console.error("verify_marketplace_cron_secret failed", error.message);
  }

  return { ok: false, status: 401, message: "Invalid cron secret" };
}


async function safeJson(req) {
  try {
    const raw = await req.text();
    if (!raw.trim()) return {};
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch (_) {
    return {};
  }
}
async function runAutoFinancePayoutSync(args) {
  let settingsQuery = args.admin.from('finance_auto_sync_settings').select('tenant_id, enabled, interval_minutes, max_orders_per_account, last_auto_run_at').eq('enabled', true).order('updated_at', {
    ascending: true
  });
  if (args.tenantFilter) settingsQuery = settingsQuery.eq('tenant_id', args.tenantFilter);
  const { data: settings, error: settingsError } = await settingsQuery;
  if (settingsError) {
    return {
      enabled_tenants: 0,
      tenants_run: 0,
      accounts_run: 0,
      orders_checked: 0,
      success: 0,
      failed: 0,
      skipped: 0,
      error: `Load finance auto settings failed: ${settingsError.message}`,
      details: []
    };
  }
  const result = {
    enabled_tenants: settings?.length || 0,
    tenants_run: 0,
    accounts_run: 0,
    orders_checked: 0,
    success: 0,
    failed: 0,
    skipped: 0,
    details: []
  };
  const now = Date.now();
  const sinceDate = new Date(now - 3 * 24 * 60 * 60 * 1000).toISOString();
  for (const setting of settings || []){
    const intervalMs = clampInt(setting.interval_minutes, 5, 1440, 10) * 60 * 1000;
    const lastRun = setting.last_auto_run_at ? new Date(setting.last_auto_run_at).getTime() : 0;
    if (!args.force && lastRun && now - lastRun < intervalMs) {
      result.skipped += 1;
      continue;
    }
    result.tenants_run += 1;
    const perAccountLimit = clampInt(setting.max_orders_per_account, 1, 20, 20);
    let accountsQuery = args.admin.from('marketplace_accounts').select('marketplace_account_id, tenant_id, marketplace, status, shop_name, store_alias').eq('tenant_id', setting.tenant_id).eq('marketplace', 'tiktok_shop').eq('status', 'active').eq('is_deleted', false).order('updated_at', {
      ascending: false
    }).limit(args.maxAccounts);
    if (args.accountFilter) accountsQuery = accountsQuery.eq('marketplace_account_id', args.accountFilter);
    const { data: accounts, error: accountError } = await accountsQuery;
    if (accountError) {
      result.failed += 1;
      result.details.push({
        tenant_id: setting.tenant_id,
        ok: false,
        error: accountError.message
      });
      continue;
    }
    for (const account of accounts || []){
      result.accounts_run += 1;
      const { data: orders, error: orderError } = await args.admin.from('marketplace_orders').select('order_id, external_order_id, order_sn, marketplace_account_id, order_created_at, paid_at, pulled_at').eq('tenant_id', setting.tenant_id).eq('marketplace_account_id', account.marketplace_account_id).gte('created_at', sinceDate).order('updated_at', {
        ascending: true,
        nullsFirst: true
      }).limit(perAccountLimit);
      if (orderError) {
        result.failed += 1;
        result.details.push({
          tenant_id: setting.tenant_id,
          account_id: account.marketplace_account_id,
          ok: false,
          error: orderError.message
        });
        continue;
      }
      let accountSuccess = 0;
      let accountFailed = 0;
      for (const order of orders || []){
        const orderId = text(order.order_id) || text(order.external_order_id) || text(order.order_sn);
        if (!orderId) {
          result.skipped += 1;
          continue;
        }
        result.orders_checked += 1;
        try {
          const response = await fetch(`${args.supabaseUrl}/functions/v1/marketplace-tiktok-service`, {
            method: 'POST',
            headers: {
              authorization: `Bearer ${String(Deno.env.get("SUPABASE_ANON_KEY") || args.serviceRoleKey || "").trim()}`,
              apikey: String(Deno.env.get("SUPABASE_ANON_KEY") || args.serviceRoleKey || "").trim(),
              'content-type': 'application/json',
              'x-marketplace-cron-secret': args.cronSecret
            },
            body: JSON.stringify({
              action: 'pull_finance_by_order',
              params: {
                account_id: account.marketplace_account_id,
                order_id: orderId
              }
            })
          });
          if (response.ok) {
            accountSuccess += 1;
            result.success += 1;
          } else {
            accountFailed += 1;
            result.failed += 1;
          }
        } catch (err) {
          accountFailed += 1;
          result.failed += 1;
        }
      }
      result.details.push({
        tenant_id: setting.tenant_id,
        account_id: account.marketplace_account_id,
        orders_checked: (orders || []).length,
        success: accountSuccess,
        failed: accountFailed
      });
    }
    const message = `Auto payout: cek ${result.orders_checked}, sukses ${result.success}, gagal ${result.failed}`;
    await args.admin.from('finance_auto_sync_settings').update({
      last_auto_run_at: new Date().toISOString(),
      last_auto_run_message: message,
      updated_at: new Date().toISOString()
    }).eq('tenant_id', setting.tenant_id);
    await args.admin.from('finance_sync_logs').insert({
      tenant_id: setting.tenant_id,
      sync_type: 'auto_payout_status',
      period_start: new Date(now - 3 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10),
      period_end: new Date(now).toISOString().slice(0, 10),
      marketplace: 'all',
      checked_count: result.orders_checked,
      success_count: result.success,
      failed_count: result.failed,
      skipped_count: result.skipped,
      message
    });
    const cache = await refreshFinanceCacheSafe({
      admin: args.admin,
      marketplace: "all",
      accountId: args.accountFilter || null,
      reason: "auto_payout"
    });
    result.details.push({
      tenant_id: setting.tenant_id,
      type: "finance_cache_refresh",
      status: cache.ok ? "done" : "warning",
      response: cache
    });
  }
  return result;
}
function sumNumbers(values) {
  return values.reduce((total, value)=>{
    const n = Number(value ?? 0);
    return total + (Number.isFinite(n) ? n : 0);
  }, 0);
}
async function refreshFinanceCacheSafe(args) {
  try {
    const { data, error } = await args.admin.rpc("finance_refresh_recent_caches", {
      p_marketplace: args.marketplace || "all",
      p_account_id: args.accountId || null,
      p_reason: args.reason
    });
    if (error) return {
      ok: false,
      message: error.message
    };
    return {
      ok: true,
      data
    };
  } catch (err) {
    return {
      ok: false,
      message: String(err)
    };
  }
}
function requiredEnv(name) {
  const value = String(Deno.env.get(name) || "").trim();
  if (!value) throw new Error(`${name} is not configured`);
  return value;
}
function json(payload, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      ...corsHeaders,
      "content-type": "application/json; charset=utf-8"
    }
  });
}

