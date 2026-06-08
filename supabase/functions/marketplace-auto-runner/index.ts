import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const FUNCTION_VERSION = "marketplace-auto-runner-overwrite-bounded-order-v7-2026-06-06";

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type, x-marketplace-cron-secret, x-stock-sync-cron-secret",
  "access-control-allow-methods": "POST, OPTIONS",
};

type RunDetail = Record<string, unknown>;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    if (req.method !== "POST") return json({ ok: false, message: "Method not allowed" }, 405);

    const supabaseUrl = requiredEnv("SUPABASE_URL");
    const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");
    const cronSecret = String(
      Deno.env.get("MARKETPLACE_CRON_SECRET") ||
      Deno.env.get("MARKETPLACE_AUTO_SYNC_CRON_SECRET") ||
      Deno.env.get("STOCK_SYNC_CRON_SECRET") ||
      ""
    ).trim();

    const incomingSecret = String(
      req.headers.get("x-marketplace-cron-secret") ||
      req.headers.get("x-stock-sync-cron-secret") ||
      ""
    ).trim();

    if (!cronSecret) {
      return json({ ok: false, message: "MARKETPLACE_CRON_SECRET belum diset di Supabase Edge Function secrets." }, 500);
    }

    if (incomingSecret !== cronSecret) {
      return json({ ok: false, message: "Invalid cron secret" }, 401);
    }

    const body = await safeJson(req);
    const force = body.force === true;
    const tenantFilter = text(body.tenant_id);
    const accountFilter = text(body.marketplace_account_id);
    const maxAccounts = clampInt(body.max_accounts, 1, 100, 50);
    const queueLimit = clampInt(body.stock_sync_limit, 1, 50, 20);
    // v7: order cron 2 menit harus bounded. Default sengaja kecil supaya parent request tidak 546/timeout.
    const maxOrderJobs = clampInt(body.max_order_jobs ?? Deno.env.get("ORDER_PULL_MAX_JOBS"), 1, 12, 1);
    const maxPagesPerAccount = clampInt(body.max_pages_per_account ?? Deno.env.get("ORDER_PULL_MAX_PAGES_PER_ACCOUNT"), 1, 3, 1);
    const maxOrdersPerAccount = clampInt(body.max_orders_per_account ?? Deno.env.get("ORDER_PULL_MAX_ORDERS_PER_ACCOUNT"), 10, 100, 50);
    const maxDetailsPerAccount = clampInt(body.max_details_per_account ?? Deno.env.get("ORDER_PULL_MAX_DETAILS_PER_ACCOUNT"), 0, 120, 30);
    const childTimeoutMs = clampInt(body.child_timeout_ms ?? Deno.env.get("MARKETPLACE_RUNNER_CHILD_TIMEOUT_MS"), 15000, 90000, 35000);
    const runPendingDrain = body.run_pending_drain !== false;
    const runStatusRefresh = body.run_order_status_refresh === true;
    const runReturnRefund = body.run_return_refund_pull === true;
    const maxFinanceJobs = clampInt(body.max_finance_jobs ?? Deno.env.get("FINANCE_SYNC_MAX_JOBS"), 1, 3, 3);
    const maxFinanceOrders = clampInt(body.max_finance_orders ?? Deno.env.get("FINANCE_SYNC_MAX_ORDERS"), 1, 80, 50);
    const maxFinanceBatches = clampInt(body.max_finance_batches ?? Deno.env.get("FINANCE_SYNC_MAX_BATCHES"), 1, 3, 3);
    const cleanupStale = body.cleanup_stale !== false;
    const runStock = body.run_stock === true;
    const runOrder = body.run_order !== false;
    const runFinanceStatement = body.run_finance_statement === true || body.run_finance === true || body.run_payout === true;
    const runFinancePayout = body.run_finance_payout_direct === true || body.run_direct_payout === true;

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { "x-client-info": FUNCTION_VERSION } },
    });

    const stockResult = runStock
      ? await withRunnerLock(admin, "stock_sync", 280, () => runAutoStockSync({
          admin,
          supabaseUrl,
          serviceRoleKey,
          cronSecret,
          tenantFilter,
          accountFilter,
          force,
          maxAccounts,
          queueLimit,
        }))
      : { skipped: true, reason: "run_stock=false" };

    const orderResult = runOrder
      ? await withRunnerLock(admin, "order_pull", 110, () => runAutoOrderPull({
          admin,
          supabaseUrl,
          serviceRoleKey,
          cronSecret,
          tenantFilter,
          accountFilter,
          force,
          maxAccounts,
          maxOrderJobs,
          maxPagesPerAccount,
          maxOrdersPerAccount,
          maxDetailsPerAccount,
          childTimeoutMs,
          runPendingDrain,
          runStatusRefresh,
          runReturnRefund,
          cleanupStale,
        }))
      : { skipped: true, reason: "run_order=false" };

    const financeStatementResult = runFinanceStatement
      ? await withRunnerLock(admin, "finance_payout", 280, () => runAutoFinanceStatementJobs({
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
          cleanupStale,
        }))
      : { skipped: true, reason: "run_finance=false" };

    const financeResult = runFinancePayout
      ? await withRunnerLock(admin, "finance_direct_payout", 280, () => runAutoFinancePayoutSync({
          admin,
          supabaseUrl,
          serviceRoleKey,
          cronSecret,
          tenantFilter,
          accountFilter,
          force,
          maxAccounts,
        }))
      : { skipped: true, reason: "direct payout dimatikan; pakai finance job-based 5 menit" };

    return json({
      ok: true,
      version: FUNCTION_VERSION,
      stock_sync: stockResult,
      order_pull: orderResult,
      finance_statement_jobs: financeStatementResult,
      finance_payout_sync: financeResult,
    });
  } catch (err) {
    return json({ ok: false, version: FUNCTION_VERSION, message: String(err) }, 500);
  }
});

async function runAutoStockSync(args: {
  admin: any;
  supabaseUrl: string;
  serviceRoleKey: string;
  cronSecret: string;
  tenantFilter: string;
  accountFilter: string;
  force: boolean;
  maxAccounts: number;
  queueLimit: number;
}) {
  let settingsQuery = args.admin
    .from("marketplace_stock_sync_settings")
    .select("tenant_id, auto_real_sync_enabled, interval_minutes, last_auto_run_at")
    .eq("auto_real_sync_enabled", true)
    .order("updated_at", { ascending: true });

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
    details: [] as RunDetail[],
  };

  for (const setting of settings || []) {
    const tenantId = text(setting.tenant_id);
    const interval = clampInt(setting.interval_minutes, 1, 60, 10);

    if (!args.force && !isDue(setting.last_auto_run_at, interval)) {
      result.skipped += 1;
      result.details.push({ type: "stock_sync", tenant_id: tenantId, status: "skipped_interval", interval_minutes: interval });
      continue;
    }

    result.tenants_run += 1;

    const { data: accounts, error: accountsError } = await args.admin
      .from("marketplace_accounts")
      .select("marketplace_account_id, marketplace, shop_name, store_alias, status, stock_sync_enabled")
      .eq("tenant_id", tenantId)
      .eq("status", "active")
      .eq("is_deleted", false)
      .order("created_at", { ascending: true })
      .limit(args.maxAccounts);

    if (accountsError) {
      await updateStockSetting(args.admin, tenantId, `Auto stock sync gagal load account: ${accountsError.message}`);
      result.worker_failed += 1;
      result.details.push({ type: "stock_sync", tenant_id: tenantId, status: "failed", error: accountsError.message });
      continue;
    }

    let tenantQueued = 0;
    let tenantSuccess = 0;
    let tenantFailed = 0;
    let tenantAccounts = 0;

    for (const account of accounts || []) {
      const accountId = text(account.marketplace_account_id);
      if (args.accountFilter && accountId !== args.accountFilter) continue;
      if (account.stock_sync_enabled === false) {
        result.skipped += 1;
        result.details.push({ type: "stock_sync", tenant_id: tenantId, account_id: accountId, status: "skipped_account_stock_sync_off" });
        continue;
      }

      result.accounts_run += 1;
      tenantAccounts += 1;

      const { data: queuedCount, error: queueError } = await args.admin.rpc("marketplace_queue_stock_sync_for_account", {
        p_tenant_id: tenantId,
        p_marketplace_account_id: accountId,
        p_reason: "auto_real_sync_10_minute_runner",
      });

      if (queueError) {
        tenantFailed += 1;
        result.worker_failed += 1;
        result.details.push({ type: "stock_sync", tenant_id: tenantId, account_id: accountId, status: "queue_failed", error: queueError.message });
        continue;
      }

      const queued = Number(queuedCount || 0);
      result.queued += queued;
      tenantQueued += queued;

      if (queued <= 0) {
        result.details.push({ type: "stock_sync", tenant_id: tenantId, account_id: accountId, status: "no_mapping_queued" });
        continue;
      }

      const worker = await invokeFunction(args.supabaseUrl, args.serviceRoleKey, args.cronSecret, "marketplace-stock-sync-worker", {
        tenant_id: tenantId,
        marketplace_account_id: accountId,
        limit: args.queueLimit,
        dry_run: false,
        source: "marketplace-auto-runner",
      });

      if (worker.ok && worker.http_status >= 200 && worker.http_status < 300 && worker.data?.ok !== false) {
        tenantSuccess += 1;
        result.worker_success += 1;
        result.details.push({ type: "stock_sync", tenant_id: tenantId, account_id: accountId, status: "worker_done", queued, worker: worker.data });
      } else {
        tenantFailed += 1;
        result.worker_failed += 1;
        result.details.push({ type: "stock_sync", tenant_id: tenantId, account_id: accountId, status: "worker_failed", queued, worker: worker.data, http_status: worker.http_status });
      }
    }

    const message = `Auto stock sync: account=${tenantAccounts}, queued=${tenantQueued}, ok=${tenantSuccess}, failed=${tenantFailed}`;
    await updateStockSetting(args.admin, tenantId, message);
  }

  return result;
}

async function runAutoOrderPull(args: {
  admin: any;
  supabaseUrl: string;
  serviceRoleKey: string;
  cronSecret: string;
  tenantFilter: string;
  accountFilter: string;
  force: boolean;
  maxAccounts: number;
  maxOrderJobs: number;
  maxPagesPerAccount: number;
  maxOrdersPerAccount: number;
  maxDetailsPerAccount: number;
  childTimeoutMs: number;
  runPendingDrain: boolean;
  runStatusRefresh: boolean;
  runReturnRefund: boolean;
  cleanupStale: boolean;
}) {
  let settingsQuery = args.admin
    .from("marketplace_order_pull_settings")
    .select("tenant_id, auto_order_pull_enabled, interval_minutes, days_back, previous_unpacked_days, last_auto_run_at")
    .eq("auto_order_pull_enabled", true)
    .order("updated_at", { ascending: true });

  if (args.tenantFilter) settingsQuery = settingsQuery.eq("tenant_id", args.tenantFilter);

  const { data: settings, error: settingsError } = await settingsQuery;
  if (settingsError) throw new Error(`Load order pull settings failed: ${settingsError.message}`);

  const staleCleanup = args.cleanupStale ? await resetStaleJobs(args.admin) : { skipped: true };

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
    details: [] as RunDetail[],
  };

  for (const setting of settings || []) {
    const tenantId = text(setting.tenant_id);
    const interval = clampInt(setting.interval_minutes, 1, 60, 2);
    const orderDue = args.force || isDue(setting.last_auto_run_at, interval);

    // v7: pending drain dibuat opsional dan bounded. Kalau child lambat, parent tetap return sebelum pg_net timeout.
    if (args.runPendingDrain && args.force) {
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
        source: "marketplace-auto-runner-v7-drain-pending-bounded",
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
        result.details.push({ type: "order_pending_drain", tenant_id: tenantId, status: "processed", processed_jobs: processedJobs, remaining_jobs: remainingJobs, orders, items, response: pendingDrain.data });
      } else {
        result.failed += 1;
        result.details.push({ type: "order_pending_drain", tenant_id: tenantId, status: "warning", response: pendingDrain.data, http_status: pendingDrain.http_status });
      }
    } else {
      result.details.push({ type: "order_pending_drain", tenant_id: tenantId, status: "skipped_by_config" });
    }

    if (!orderDue) {
      result.skipped += 1;
      result.details.push({ type: "order_pull", tenant_id: tenantId, status: "skipped_enqueue_interval_but_pending_drained", interval_minutes: interval });
      continue;
    }

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
      include_update_time_search: false,
      only_latest: true,
      only_active_orders: true,
      skip_completed_orders: true,
      skip_final_orders: true,
      include_completed: false,
      source: "marketplace-auto-runner-v7-order-bounded-active-only",
      refresh_existing_status: false,
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
      result.details.push({ type: "order_pull_jobs", tenant_id: tenantId, status: "jobs_processed", queued, processed_jobs: processedJobs, remaining_jobs: remainingJobs, orders, items, response: orderJobs.data });
    } else {
      result.failed += 1;
      result.details.push({ type: "order_pull_jobs", tenant_id: tenantId, status: "jobs_failed", response: orderJobs.data, http_status: orderJobs.http_status });
      await updateOrderSetting(args.admin, tenantId, `Auto order jobs gagal: ${JSON.stringify(orderJobs.data || {})}`);
      continue;
    }

    const { data: accounts, error: accountsError } = await args.admin
      .from("marketplace_accounts")
      .select("marketplace_account_id, marketplace, shop_name, store_alias, status")
      .eq("tenant_id", tenantId)
      .eq("status", "active")
      .eq("is_deleted", false)
      .order("created_at", { ascending: true })
      .limit(args.maxAccounts);

    if (accountsError) {
      result.failed += 1;
      result.details.push({ type: "order_status_refresh", tenant_id: tenantId, status: "failed_load_account", error: accountsError.message });
      await updateOrderSetting(args.admin, tenantId, `Auto order status gagal load account: ${accountsError.message}`);
      continue;
    }

    let tenantStatusChecked = 0;
    let tenantStatusUpdated = 0;
    let tenantStatusReviewRequired = 0;
    let tenantFailed = 0;

    for (const account of accounts || []) {
      const accountId = text(account.marketplace_account_id);
      const marketplace = text(account.marketplace);
      if (args.accountFilter && accountId !== args.accountFilter) continue;

      if (!["tiktok_shop", "shopee"].includes(marketplace)) {
        result.skipped += 1;
        result.details.push({ type: "order_pull", tenant_id: tenantId, account_id: accountId, marketplace, status: "skipped_unsupported_marketplace" });
        continue;
      }

      if (args.runStatusRefresh) {
        const statusRefresh = await invokeFunction(args.supabaseUrl, args.serviceRoleKey, args.cronSecret, "marketplace-order-pull", {
          action: "refresh_existing_status",
          tenant_id: tenantId,
          marketplace_account_id: accountId,
          status_range_days: 1,
          max_existing_orders: Math.min(args.maxOrdersPerAccount, 30),
          source: "marketplace-auto-runner-v7-status-bounded",
          auto_status_only: true,
          only_unfinished: true,
          only_active_orders: true,
          skip_completed_orders: true,
          skip_final_orders: true,
          include_completed: false,
          exclude_statuses: ["COMPLETED", "CANCELLED", "CANCELED", "DELIVERED"],
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
          result.details.push({ type: "order_status_refresh", tenant_id: tenantId, account_id: accountId, status: "status_refresh_done", checked, updated, review_required: reviewRequired, response: statusRefresh.data });
        } else {
          result.details.push({ type: "order_status_refresh", tenant_id: tenantId, account_id: accountId, status: "status_refresh_warning", response: statusRefresh.data, http_status: statusRefresh.http_status });
        }
      } else {
        result.details.push({ type: "order_status_refresh", tenant_id: tenantId, account_id: accountId, status: "skipped_by_config" });
      }

      if (args.runReturnRefund) {
        const flags = await invokeFunction(args.supabaseUrl, args.serviceRoleKey, args.cronSecret, "marketplace-return-refund-pull", {
          tenant_id: tenantId,
          marketplace_account_id: accountId,
          days_back: 1,
          limit: 10,
          max_pages: 1,
          source: "marketplace-auto-runner-v7-return-flags-bounded",
          auto_today_only: true,
        }, args.childTimeoutMs);

        if (!flags.ok || flags.http_status >= 300 || flags.data?.ok === false) {
          tenantFailed += 1;
          result.details.push({ type: "return_refund_pull", tenant_id: tenantId, account_id: accountId, status: "warning", response: flags.data, http_status: flags.http_status });
        }
      } else {
        result.details.push({ type: "return_refund_pull", tenant_id: tenantId, account_id: accountId, status: "skipped_by_config" });
      }
    }

    // Order pull tidak refresh finance cache. Finance cache hanya disentuh runner finance 5 menit.

    const message = `Auto order: antrean=${result.queued}, diproses=${result.processed_jobs}, sisa=${result.remaining_jobs}, order=${result.orders}, item=${result.items}, cek_status=${tenantStatusChecked}, update_status=${tenantStatusUpdated}, review=${tenantStatusReviewRequired}, gagal=${tenantFailed}`;
    await updateOrderSetting(args.admin, tenantId, message);
  }

  return result;
}

async function runAutoFinanceStatementJobs(args: {
  admin: any;
  supabaseUrl: string;
  serviceRoleKey: string;
  cronSecret: string;
  tenantFilter: string;
  accountFilter: string;
  force: boolean;
  maxAccounts: number;
  maxFinanceJobs: number;
  maxFinanceOrders: number;
  maxFinanceBatches: number;
  cleanupStale: boolean;
}) {
  if (args.cleanupStale) await resetStaleJobs(args.admin);
  // Pull finance/payout dibuat job-based supaya tidak menahan satu request panjang.
  // Default v81: jadwal 5 menit, maksimal 3 job, 20 order per batch, 3 batch per job.
  const body: Record<string, unknown> = {
    action: "process_finance_sync_jobs",
    params: {
      mode: "recent_unpaid",
      days_back: args.force ? 7 : 3,
      enqueue: true,
      process: true,
      max_jobs: args.maxFinanceJobs,
      max_accounts: args.maxAccounts,
      max_orders: args.maxFinanceOrders,
      max_batches_per_job: args.maxFinanceBatches,
      max_order_details: 120,
      include_sku_details: true,
      only_missing_payout: true,
      include_recent_orders: true,
      include_pending_payout: true,
      include_all_missing_payout: true,
      missing_payout_limit: args.maxFinanceOrders,
      include_negative_refund_check: true,
      skip_settled_with_payout: true,
      source: "marketplace-auto-runner-v24-6-82o-finance-force-7d-unpaid",
    },
  };
  if (args.tenantFilter) body.params = { ...(body.params as Record<string, unknown>), tenant_id: args.tenantFilter };
  if (args.accountFilter) body.params = { ...(body.params as Record<string, unknown>), account_id: args.accountFilter };
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
    data.processed_jobs,
  ]);

  if (!response.ok || response.http_status < 200 || response.http_status >= 300 || data?.ok === false) {
    return { ...response, cache: { skipped: true, reason: "finance sync belum sukses; cache tidak direfresh" } };
  }

  if (changed <= 0 && args.force !== true) {
    return { ...response, cache: { skipped: true, reason: "tidak ada finance/payout baru" } };
  }

  const cache = await refreshFinanceCacheSafe({
    admin: args.admin,
    marketplace: "all",
    accountId: args.accountFilter || null,
    reason: "auto_finance_statement",
  });
  return { ...response, cache };
}


async function withRunnerLock<T>(admin: any, lockKey: string, ttlSeconds: number, run: () => Promise<T>): Promise<T | Record<string, unknown>> {
  const owner = `${FUNCTION_VERSION}-${crypto.randomUUID()}`;
  let locked = false;
  let lockWarning = "";

  try {
    const { data, error } = await admin.rpc("marketplace_auto_runner_try_lock_v24_6_81b", {
      p_lock_key: lockKey,
      p_ttl_seconds: ttlSeconds,
      p_owner: owner,
    });

    if (error) {
      lockWarning = error.message;
    } else if (data !== true) {
      return { skipped: true, reason: "proses sebelumnya masih berjalan", lock_key: lockKey };
    } else {
      locked = true;
    }
  } catch (err) {
    lockWarning = String(err);
  }

  try {
    const result = await run();
    if (lockWarning && result && typeof result === "object" && !Array.isArray(result)) {
      return { ...(result as Record<string, unknown>), lock_warning: lockWarning };
    }
    return result;
  } finally {
    if (locked) {
      try {
        await admin.rpc("marketplace_auto_runner_release_lock_v24_6_81b", {
          p_lock_key: lockKey,
          p_owner: owner,
        });
      } catch (_) {
        // Abaikan gagal release lock. Lock punya TTL dan akan dilepas otomatis.
      }
    }
  }
}

async function resetStaleJobs(admin: any): Promise<Record<string, unknown>> {
  try {
    const { data, error } = await admin.rpc("marketplace_reset_stale_auto_jobs_v24_6_81b", {
      p_order_stale_minutes: 6,
      p_finance_stale_minutes: 15,
      p_revive_failed: false,
    });
    if (error) return { ok: false, message: error.message };
    return { ok: true, data };
  } catch (err) {
    return { ok: false, message: String(err) };
  }
}

async function invokeFunction(
  supabaseUrl: string,
  serviceRoleKey: string,
  cronSecret: string,
  functionName: string,
  body: Record<string, unknown>,
  timeoutMs = 45_000,
): Promise<{ ok: boolean; http_status: number; data: any }> {
  const url = `${supabaseUrl.replace(/\/+$/, "")}/functions/v1/${functionName}`;
  const startedAt = Date.now();
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(`child_timeout_${timeoutMs}ms`), timeoutMs);
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "authorization": `Bearer ${serviceRoleKey}`,
        "apikey": serviceRoleKey,
        "x-marketplace-cron-secret": cronSecret,
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });

    const parsed = await res.json().catch(async () => ({ raw: await res.text().catch(() => "") }));
    const data = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : { value: parsed };
    return { ok: res.ok, http_status: res.status, data: { ...data, runner_child_ms: Date.now() - startedAt } };
  } catch (err) {
    return {
      ok: false,
      http_status: 0,
      data: {
        ok: false,
        message: String(err),
        child_function: functionName,
        runner_child_timeout_ms: timeoutMs,
        runner_child_ms: Date.now() - startedAt,
      },
    };
  } finally {
    clearTimeout(timeout);
  }
}

async function updateStockSetting(admin: any, tenantId: string, message: string) {
  await admin
    .from("marketplace_stock_sync_settings")
    .update({
      last_auto_run_at: new Date().toISOString(),
      last_auto_run_message: message,
      updated_at: new Date().toISOString(),
    })
    .eq("tenant_id", tenantId);
}

async function updateOrderSetting(admin: any, tenantId: string, message: string) {
  await admin
    .from("marketplace_order_pull_settings")
    .update({
      last_auto_run_at: new Date().toISOString(),
      last_auto_run_message: message,
      updated_at: new Date().toISOString(),
    })
    .eq("tenant_id", tenantId);
}

function todayWibDateRange(): { startDate: string; endDate: string } {
  const wibOffsetMs = 7 * 60 * 60 * 1000;
  const nowWib = new Date(Date.now() + wibOffsetMs);
  const yyyy = nowWib.getUTCFullYear();
  const mm = String(nowWib.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(nowWib.getUTCDate()).padStart(2, "0");
  const today = `${yyyy}-${mm}-${dd}`;
  return { startDate: today, endDate: today };
}

function isDue(lastRunAt: unknown, intervalMinutes: number): boolean {
  if (!lastRunAt) return true;
  const last = new Date(String(lastRunAt)).getTime();
  if (!Number.isFinite(last)) return true;
  return Date.now() - last >= Math.max(1, intervalMinutes) * 60_000 - 5_000;
}

function text(value: unknown): string {
  return String(value ?? "").trim();
}

function clampInt(value: unknown, min: number, max: number, fallback: number): number {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(min, Math.min(max, parsed));
}

async function safeJson(req: Request): Promise<Record<string, any>> {
  try {
    const raw = await req.text();
    if (!raw.trim()) return {};
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch (_) {
    return {};
  }
}


async function runAutoFinancePayoutSync(args: {
  admin: any;
  supabaseUrl: string;
  serviceRoleKey: string;
  cronSecret: string;
  tenantFilter: string;
  accountFilter: string;
  force: boolean;
  maxAccounts: number;
}) {
  let settingsQuery = args.admin
    .from('finance_auto_sync_settings')
    .select('tenant_id, enabled, interval_minutes, max_orders_per_account, last_auto_run_at')
    .eq('enabled', true)
    .order('updated_at', { ascending: true });

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
      details: [] as RunDetail[],
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
    details: [] as RunDetail[],
  };

  const now = Date.now();
  const sinceDate = new Date(now - 3 * 24 * 60 * 60 * 1000).toISOString();

  for (const setting of settings || []) {
    const intervalMs = clampInt(setting.interval_minutes, 5, 1440, 10) * 60 * 1000;
    const lastRun = setting.last_auto_run_at ? new Date(setting.last_auto_run_at).getTime() : 0;
    if (!args.force && lastRun && now - lastRun < intervalMs) {
      result.skipped += 1;
      continue;
    }

    result.tenants_run += 1;
    const perAccountLimit = clampInt(setting.max_orders_per_account, 1, 20, 20);

    let accountsQuery = args.admin
      .from('marketplace_accounts')
      .select('marketplace_account_id, tenant_id, marketplace, status, shop_name, store_alias')
      .eq('tenant_id', setting.tenant_id)
      .eq('marketplace', 'tiktok_shop')
      .eq('status', 'active')
      .eq('is_deleted', false)
      .order('updated_at', { ascending: false })
      .limit(args.maxAccounts);

    if (args.accountFilter) accountsQuery = accountsQuery.eq('marketplace_account_id', args.accountFilter);

    const { data: accounts, error: accountError } = await accountsQuery;
    if (accountError) {
      result.failed += 1;
      result.details.push({ tenant_id: setting.tenant_id, ok: false, error: accountError.message });
      continue;
    }

    for (const account of accounts || []) {
      result.accounts_run += 1;
      const { data: orders, error: orderError } = await args.admin
        .from('marketplace_orders')
        .select('order_id, external_order_id, order_sn, marketplace_account_id, order_created_at, paid_at, pulled_at')
        .eq('tenant_id', setting.tenant_id)
        .eq('marketplace_account_id', account.marketplace_account_id)
        .gte('created_at', sinceDate)
        .order('updated_at', { ascending: true, nullsFirst: true })
        .limit(perAccountLimit);

      if (orderError) {
        result.failed += 1;
        result.details.push({ tenant_id: setting.tenant_id, account_id: account.marketplace_account_id, ok: false, error: orderError.message });
        continue;
      }

      let accountSuccess = 0;
      let accountFailed = 0;
      for (const order of orders || []) {
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
              authorization: `Bearer ${args.serviceRoleKey}`,
              apikey: args.serviceRoleKey,
              'content-type': 'application/json',
              'x-marketplace-cron-secret': args.cronSecret,
            },
            body: JSON.stringify({
              action: 'pull_finance_by_order',
              params: { account_id: account.marketplace_account_id, order_id: orderId },
            }),
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
        failed: accountFailed,
      });
    }

    const message = `Auto payout: cek ${result.orders_checked}, sukses ${result.success}, gagal ${result.failed}`;
    await args.admin
      .from('finance_auto_sync_settings')
      .update({ last_auto_run_at: new Date().toISOString(), last_auto_run_message: message, updated_at: new Date().toISOString() })
      .eq('tenant_id', setting.tenant_id);

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
      message,
    });

    const cache = await refreshFinanceCacheSafe({
      admin: args.admin,
      marketplace: "all",
      accountId: args.accountFilter || null,
      reason: "auto_payout",
    });
    result.details.push({ tenant_id: setting.tenant_id, type: "finance_cache_refresh", status: cache.ok ? "done" : "warning", response: cache });
  }

  return result;
}

function sumNumbers(values: unknown[]): number {
  return values.reduce((total, value) => {
    const n = Number(value ?? 0);
    return total + (Number.isFinite(n) ? n : 0);
  }, 0);
}

async function refreshFinanceCacheSafe(args: {
  admin: any;
  marketplace?: string | null;
  accountId?: string | null;
  reason: string;
}): Promise<Record<string, unknown>> {
  try {
    const { data, error } = await args.admin.rpc("finance_refresh_recent_caches_v24_6_81b", {
      p_marketplace: args.marketplace || "all",
      p_account_id: args.accountId || null,
      p_reason: args.reason,
    });
    if (error) return { ok: false, message: error.message };
    return { ok: true, data };
  } catch (err) {
    return { ok: false, message: String(err) };
  }
}

function requiredEnv(name: string): string {
  const value = String(Deno.env.get(name) || "").trim();
  if (!value) throw new Error(`${name} is not configured`);
  return value;
}

function json(payload: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      ...corsHeaders,
      "content-type": "application/json; charset=utf-8",
    },
  });
}
