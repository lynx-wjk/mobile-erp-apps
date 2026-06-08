import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const FUNCTION_VERSION = "marketplace-order-sync-jobs-overwrite-bounded-v48-status-refresh-canonical-2026-06-08";

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type, x-marketplace-cron-secret, x-stock-sync-cron-secret",
  "access-control-allow-methods": "POST, OPTIONS",
};

type JsonMap = Record<string, unknown>;

type AuthContext = {
  userId: string;
  tenantId: string;
  roleId: string;
  isCron: boolean;
  originalBearer: string;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, version: FUNCTION_VERSION, message: "Method not allowed. Gunakan POST." }, 405);

  try {
    const supabaseUrl = requiredEnv("SUPABASE_URL").replace(/\/+$/, "");
    const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");
    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { "x-client-info": FUNCTION_VERSION } },
    });

    const body = await safeJson(req);
    const params = normalizeParams(body);
    const cronSecret = String(
      Deno.env.get("MARKETPLACE_CRON_SECRET") ||
      Deno.env.get("MARKETPLACE_AUTO_SYNC_CRON_SECRET") ||
      Deno.env.get("STOCK_SYNC_CRON_SECRET") ||
      ""
    ).trim();
    const ctx = await authenticate({ req, admin, cronSecret, params });

    if (normalizeRole(ctx.roleId) === "demo_super_admin") {
      return json({ ok: false, version: FUNCTION_VERSION, message: "Demo account tidak boleh pull order marketplace production." }, 403);
    }

    const tenantId = text(params.tenant_id) || ctx.tenantId;
    if (!tenantId && ctx.isCron) {
      const delegated = await delegateOrderCronToAutoRunner({
        supabaseUrl,
        serviceRoleKey,
        cronSecret,
        params,
      });
      return json({
        ok: delegated.ok,
        version: FUNCTION_VERSION,
        delegated_to: "marketplace-auto-runner",
        http_status: delegated.http_status,
        data: delegated.data,
      }, delegated.ok ? 200 : delegated.http_status || 500);
    }
    if (!tenantId) return json({ ok: false, version: FUNCTION_VERSION, message: "tenant_id wajib diisi. Untuk cron tanpa tenant, pakai header/body cron_secret agar bisa delegate ke marketplace-auto-runner." }, 400);
    if (!ctx.isCron && tenantId !== ctx.tenantId && !isAdminRole(ctx.roleId)) {
      return json({ ok: false, version: FUNCTION_VERSION, message: "Forbidden tenant access." }, 403);
    }

    const mode = text(params.mode || params.action || (ctx.isCron ? "auto" : "period")).toLowerCase();
    const enqueue = params.enqueue !== false;
    const process = params.process !== false;
    const accountId = text(params.account_id || params.marketplace_account_id);
    const maxAccounts = clampInt(params.max_accounts, 1, 100, 50);
    const maxJobs = clampInt(params.max_jobs ?? params.max_order_jobs, 1, 12, ctx.isCron ? 1 : 6);
    const windowMinutes = clampInt(params.window_minutes, 15, 240, 60);
    const refreshExistingStatus = params.refresh_existing_status !== false;
    const statusRangeDays = clampInt(params.status_range_days, 1, 120, 90);
    const maxExistingOrders = clampInt(params.max_existing_orders, 1, 200, 100);
    const skipCompletedStatusRefresh = params.skip_completed_status_refresh !== false;
    const skipCompletedOrderPull = params.skip_completed_order_pull !== false;
    const source = text(params.source) || FUNCTION_VERSION;
    const isBoundedAutoCron = ctx.isCron && (source.includes("marketplace-auto-runner") || params.only_latest === true);

    let queued = 0;
    let queueAccounts = 0;
    let ranges: JsonMap[] = [];

    if (enqueue) {
      const queueResult = await enqueueOrderPullJobs({
        admin,
        ctx,
        tenantId,
        accountId,
        maxAccounts,
        mode,
        startDate: text(params.start_date || params.period_start || params.from_date),
        endDate: text(params.end_date || params.period_end || params.to_date),
        windowMinutes,
        maxJobs,
        boundedAutoCron: isBoundedAutoCron,
        forceRequeue: params.force_requeue === true && !isBoundedAutoCron,
        source,
      });
      queued = queueResult.queued;
      queueAccounts = queueResult.accounts;
      ranges = queueResult.ranges;
    }

    const processedResult = process
      ? await processOrderPullJobs({
          admin,
          ctx,
          supabaseUrl,
          serviceRoleKey,
          cronSecret,
          tenantId,
          accountId,
          maxJobs,
          pageSize: clampInt(params.page_size || params.limit, 10, 50, 50),
          maxPages: clampInt(params.max_pages, 1, 2, 1),
          maxDetails: clampInt(params.max_details ?? params.max_details_per_account, 0, 100, ctx.isCron ? 0 : 50),
          includeUpdateTimeSearch: params.include_update_time_search === true,
          skipCompletedOrderPull,
        })
      : emptyProcessedResult();

    const statusResult = refreshExistingStatus
      ? await refreshExistingOrderStatuses({
          admin,
          ctx,
          supabaseUrl,
          serviceRoleKey,
          cronSecret,
          tenantId,
          accountId,
          maxAccounts,
          statusRangeDays,
          maxExistingOrders,
          skipCompletedStatusRefresh,
        })
      : emptyStatusRefreshResult();

    const remaining = await countRemainingJobs(admin, tenantId, accountId);
    const message = `Order jobs: queued=${queued}, processed=${processedResult.processed}, failed=${processedResult.failed}, remaining=${remaining}, orders=${processedResult.orders}, items=${processedResult.items}, status_checked=${statusResult.checked}, status_updated=${statusResult.updated}, review=${statusResult.reviewRequired}, status_failed=${statusResult.failed}.`;
    await updateOrderPullSetting(admin, tenantId, message);

    return json({
      ok: processedResult.failed === 0 || processedResult.processed > 0 || statusResult.checked > 0,
      version: FUNCTION_VERSION,
      marketplace: accountId ? "specific" : "mixed",
      queued,
      accounts: queueAccounts || statusResult.accounts,
      ranges,
      processed: processedResult.processed,
      failed: processedResult.failed,
      orders: processedResult.orders,
      items: processedResult.items,
      mapped_items: processedResult.mappedItems,
      unmapped_items: processedResult.unmappedItems,
      warning_count: processedResult.warningCount + statusResult.warningCount,
      remaining,
      status_checked: statusResult.checked,
      status_updated: statusResult.updated,
      status_review_required: statusResult.reviewRequired,
      status_failed: statusResult.failed,
      details: [...processedResult.details, ...statusResult.details].slice(0, 18),
      message,
    });
  } catch (err) {
    return json({ ok: false, version: FUNCTION_VERSION, message: cleanError(err) }, 500);
  }
});

async function delegateOrderCronToAutoRunner(args: {
  supabaseUrl: string;
  serviceRoleKey: string;
  cronSecret: string;
  params: JsonMap;
}): Promise<{ ok: boolean; http_status: number; data: any }> {
  try {
    const response = await fetch(`${args.supabaseUrl.replace(/\/+$/, "")}/functions/v1/marketplace-auto-runner`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "authorization": `Bearer ${args.serviceRoleKey}`,
        "apikey": args.serviceRoleKey,
        "x-marketplace-cron-secret": args.cronSecret,
      },
      body: JSON.stringify({
        run_stock: false,
        run_order: true,
        run_finance: false,
        force: args.params.force === true,
        max_accounts: args.params.max_accounts,
        account_id: args.params.account_id || args.params.marketplace_account_id,
        source: "marketplace-order-sync-jobs-v24-6-44-delegated-cron",
      }),
    });
    const data = await response.json().catch(async () => ({ raw: await response.text().catch(() => "") }));
    return { ok: response.ok && data?.ok !== false, http_status: response.status, data };
  } catch (err) {
    return { ok: false, http_status: 0, data: { ok: false, message: String(err) } };
  }
}

function normalizeParams(body: JsonMap): JsonMap {
  const nested = body.params;
  if (nested && typeof nested === "object" && !Array.isArray(nested)) {
    return { ...body, ...(nested as JsonMap) };
  }
  return body;
}

async function authenticate(args: { req: Request; admin: any; cronSecret: string; params: JsonMap }): Promise<AuthContext> {
  const incomingSecret = String(
    args.req.headers.get("x-marketplace-cron-secret") ||
    args.req.headers.get("x-stock-sync-cron-secret") ||
    args.params.cron_secret ||
    args.params.marketplace_cron_secret ||
    args.params.x_marketplace_cron_secret ||
    args.params.secret ||
    ""
  ).trim();
  const isCron = args.cronSecret.length > 0 && incomingSecret === args.cronSecret;
  const originalBearer = (args.req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "").trim();

  if (isCron) {
    return {
      userId: "00000000-0000-0000-0000-000000000000",
      tenantId: text(args.params.tenant_id),
      roleId: "super_admin",
      isCron: true,
      originalBearer,
    };
  }

  if (!originalBearer) throw new Error("Missing authorization header.");
  const { data: userData, error: userError } = await args.admin.auth.getUser(originalBearer);
  if (userError || !userData?.user) throw new Error("Invalid user session.");

  const { data: profile, error: profileError } = await args.admin
    .from("users")
    .select("user_id, tenant_id, role_id, status")
    .eq("user_id", userData.user.id)
    .maybeSingle();

  if (profileError || !profile) throw new Error(profileError?.message || "User profile not found.");
  if (profile.status !== "active") throw new Error("User is not active.");

  return {
    userId: text(profile.user_id),
    tenantId: text(profile.tenant_id),
    roleId: text(profile.role_id),
    isCron: false,
    originalBearer,
  };
}

async function enqueueOrderPullJobs(args: {
  admin: any;
  ctx: AuthContext;
  tenantId: string;
  accountId: string;
  maxAccounts: number;
  mode: string;
  startDate: string;
  endDate: string;
  windowMinutes: number;
  maxJobs: number;
  boundedAutoCron: boolean;
  forceRequeue: boolean;
  source: string;
}): Promise<{ queued: number; accounts: number; ranges: JsonMap[] }> {
  const ranges = buildDateRanges(args.mode, args.startDate, args.endDate);

  let accountQuery = args.admin
    .from("marketplace_accounts")
    .select("marketplace_account_id, tenant_id, marketplace, status, is_deleted")
    .eq("tenant_id", args.tenantId)
    .in("marketplace", ["tiktok_shop", "shopee"])
    .eq("status", "active")
    .eq("is_deleted", false)
    .order("created_at", { ascending: true })
    .limit(args.maxAccounts);

  if (args.accountId) accountQuery = accountQuery.eq("marketplace_account_id", args.accountId);

  const { data: accounts, error: accountError } = await accountQuery;
  if (accountError) throw new Error(`Load marketplace account gagal: ${accountError.message}`);

  const rows: JsonMap[] = [];
  const rangeSummaries: JsonMap[] = [];

  for (const range of ranges) {
    rangeSummaries.push({ start_date: range.startDate, end_date: range.endDate, job_type: range.jobType, priority: range.priority });
    for (const account of accounts || []) {
      const marketplaceAccountId = text(account.marketplace_account_id);
      if (args.boundedAutoCron) {
        const activeJobs = await countActiveAutoOrderJobs(args.admin, args.tenantId, marketplaceAccountId);
        if (activeJobs > 0) continue;
      }
      const windows = buildWindows(range.startDate, args.windowMinutes);
      const selectedWindows = args.boundedAutoCron ? windows.slice(-Math.max(1, args.maxJobs)) : windows;
      for (const window of selectedWindows) {
        rows.push({
          tenant_id: args.tenantId,
          marketplace_account_id: marketplaceAccountId,
          marketplace: text(account.marketplace),
          job_type: range.jobType,
          period_start: range.startDate,
          period_end: range.endDate,
          window_start_seconds: window.startSeconds,
          window_end_seconds: window.endSeconds,
          window_label: window.label,
          status: "pending",
          priority: range.priority,
          attempts: 0,
          next_run_at: new Date().toISOString(),
          locked_at: null,
          last_run_at: null,
          finished_at: null,
          order_count: 0,
          item_count: 0,
          mapped_count: 0,
          unmapped_count: 0,
          warning_count: 0,
          last_message: null,
          payload: {
            source: args.source,
            mode: args.mode,
            window_minutes: args.windowMinutes,
          },
          last_result: {},
          requested_by: args.ctx.userId === "00000000-0000-0000-0000-000000000000" ? null : args.ctx.userId,
          updated_at: new Date().toISOString(),
        });
      }
    }
  }

  if (args.forceRequeue && rows.length > 0) {
    const minStart = Math.min(...rows.map((row) => Number(row.window_start_seconds)));
    const maxEnd = Math.max(...rows.map((row) => Number(row.window_end_seconds)));
    let resetQuery = args.admin
      .from("marketplace_order_pull_jobs")
      .update({
        status: "pending",
        attempts: 0,
        next_run_at: new Date().toISOString(),
        locked_at: null,
        last_run_at: null,
        finished_at: null,
        last_message: "Requeue manual dari aplikasi.",
        updated_at: new Date().toISOString(),
      })
      .eq("tenant_id", args.tenantId)
      .gte("window_start_seconds", minStart)
      .lte("window_end_seconds", maxEnd);
    if (args.accountId) resetQuery = resetQuery.eq("marketplace_account_id", args.accountId);
    await resetQuery;
  }

  if (rows.length === 0) return { queued: 0, accounts: accounts?.length || 0, ranges: rangeSummaries };

  const { data, error } = await args.admin
    .from("marketplace_order_pull_jobs")
    .upsert(rows, {
      onConflict: "marketplace_account_id,job_type,window_start_seconds,window_end_seconds",
      ignoreDuplicates: !args.forceRequeue,
    })
    .select("order_pull_job_id");

  if (error) throw new Error(`Enqueue order pull jobs gagal: ${error.message}`);
  return { queued: Array.isArray(data) ? data.length : rows.length, accounts: accounts?.length || 0, ranges: rangeSummaries };
}

async function countActiveAutoOrderJobs(admin: any, tenantId: string, accountId: string): Promise<number> {
  const { count, error } = await admin
    .from("marketplace_order_pull_jobs")
    .select("order_pull_job_id", { count: "exact", head: true })
    .eq("tenant_id", tenantId)
    .eq("marketplace_account_id", accountId)
    .in("status", ["pending", "retry", "running"])
    .like("job_type", "auto_%");
  if (error) throw new Error(`Cek antrean order aktif gagal: ${error.message}`);
  return Number(count || 0);
}

async function processOrderPullJobs(args: {
  admin: any;
  ctx: AuthContext;
  supabaseUrl: string;
  serviceRoleKey: string;
  cronSecret: string;
  tenantId: string;
  accountId: string;
  maxJobs: number;
  pageSize: number;
  maxPages: number;
  maxDetails: number;
  includeUpdateTimeSearch: boolean;
  skipCompletedOrderPull: boolean;
}) {
  let query = args.admin
    .from("marketplace_order_pull_jobs")
    .select("*")
    .eq("tenant_id", args.tenantId)
    .in("status", ["pending", "retry"])
    .lte("next_run_at", new Date().toISOString())
    .order("priority", { ascending: false })
    .order("window_start_seconds", { ascending: false })
    .order("created_at", { ascending: true })
    .limit(args.maxJobs);
  if (args.accountId) query = query.eq("marketplace_account_id", args.accountId);

  const { data: jobs, error } = await query;
  if (error) throw new Error(`Load order pull jobs gagal: ${error.message}`);

  const result = emptyProcessedResult();

  for (const job of jobs || []) {
    const jobId = text(job.order_pull_job_id || job.id);
    const startedAt = new Date().toISOString();
    await args.admin
      .from("marketplace_order_pull_jobs")
      .update({ status: "running", locked_at: startedAt, last_run_at: startedAt, updated_at: startedAt })
      .eq("order_pull_job_id", jobId);

    const basePayload = {
      tenant_id: text(job.tenant_id),
      marketplace_account_id: text(job.marketplace_account_id),
      start_date: text(job.period_start),
      end_date: text(job.period_end),
      start_seconds: Number(job.window_start_seconds),
      end_seconds: Number(job.window_end_seconds),
      days_back: 1,
      previous_unpacked_days: 1,
      include_previous_unpacked: false,
      statuses: [],
      include_statusless_search: true,
      include_update_time_search: args.includeUpdateTimeSearch,
      skip_completed_order_pull: args.skipCompletedOrderPull,
      statusless_only: true,
      limit: args.pageSize,
      max_pages: args.maxPages,
      max_details: args.maxDetails,
      search_mode: "statusless_order_pull_job_v24",
      source: "marketplace-order-sync-jobs",
    };

    let pull: any = null;
    try {
      pull = await invokeOrderPull(args, basePayload);
      if ((!pull.ok || pull.http_status >= 300 || pull.data?.ok === false) && shouldFallbackSmallRequest(pull)) {
        const fallbackPayload = {
          ...basePayload,
          include_update_time_search: false,
          max_pages: 1,
          max_details: Math.min(50, args.maxDetails),
          search_mode: "statusless_order_pull_job_v24_fallback_small",
        };
        const fallback = await invokeOrderPull(args, fallbackPayload);
        if (fallback.ok && fallback.http_status < 300 && fallback.data?.ok !== false) {
          pull = {
            ...fallback,
            data: {
              ...fallback.data,
              fallback_used: true,
              fallback_reason: pull.data?.message || pull.data?.raw || `HTTP ${pull.http_status}`,
            },
          };
        }
      }

      if (!pull.ok || pull.http_status >= 300 || pull.data?.ok === false) {
        throw new Error(cleanError(pull.data?.message || pull.data?.raw || `HTTP ${pull.http_status}`));
      }

      const orders = toInt(pull.data?.orders);
      const items = toInt(pull.data?.items);
      const mapped = toInt(pull.data?.mapped_items);
      const unmapped = toInt(pull.data?.unmapped_items);
      const warnings = toInt(pull.data?.warning_count);

      result.processed += 1;
      result.orders += orders;
      result.items += items;
      result.mappedItems += mapped;
      result.unmappedItems += unmapped;
      result.warningCount += warnings;
      result.details.push({ job_id: jobId, window: job.window_label, status: "done", orders, items, mapped, unmapped, warnings, fallback_used: pull.data?.fallback_used === true });

      const lastResultData = orders === 0
        ? { ...pull.data, status: "no_new_orders" }
        : (pull.data || {});

      await args.admin
        .from("marketplace_order_pull_jobs")
        .update({
          status: "done",
          finished_at: new Date().toISOString(),
          order_count: orders,
          item_count: items,
          mapped_count: mapped,
          unmapped_count: unmapped,
          warning_count: warnings,
          last_message: pull.data?.message || `Selesai: ${orders} order, ${items} item.`,
          last_result: lastResultData,
          updated_at: new Date().toISOString(),
        })
        .eq("order_pull_job_id", jobId);

      await insertOrderJobLog(args.admin, job, "success", `Order window ${job.window_label || ""} selesai: ${orders} order, ${items} item.`, basePayload, lastResultData);
    } catch (err) {
      result.failed += 1;
      const attempts = toInt(job.attempts) + 1;
      const retryMinutes = Math.min(60, Math.max(5, attempts * 5));
      const failedStatus = attempts >= 3 ? "failed" : "retry";
      const message = cleanError(err);
      
      const safeErrorResult = {
        ...getSafeErrorResult(message),
        ...(pull?.data && typeof pull.data === "object" ? pull.data : {}),
      };

      await args.admin
        .from("marketplace_order_pull_jobs")
        .update({
          status: failedStatus,
          attempts,
          next_run_at: new Date(Date.now() + retryMinutes * 60_000).toISOString(),
          finished_at: new Date().toISOString(),
          last_message: message,
          last_result: safeErrorResult,
          updated_at: new Date().toISOString(),
        })
        .eq("order_pull_job_id", jobId);
      await insertOrderJobLog(args.admin, job, failedStatus === "failed" ? "error" : "warning", message, basePayload, safeErrorResult);
      result.details.push({ job_id: jobId, window: job.window_label, status: failedStatus, error: message });
    }
  }

  return result;
}

async function invokeOrderPull(args: {
  ctx: AuthContext;
  supabaseUrl: string;
  serviceRoleKey: string;
  cronSecret: string;
}, payload: JsonMap): Promise<{ ok: boolean; http_status: number; data: any }> {
  const headers: Record<string, string> = {
    "content-type": "application/json",
    "apikey": args.serviceRoleKey,
  };

  if (args.ctx.isCron) {
    headers.authorization = `Bearer ${args.serviceRoleKey}`;
    if (args.cronSecret) headers["x-marketplace-cron-secret"] = args.cronSecret;
  } else {
    headers.authorization = `Bearer ${args.ctx.originalBearer}`;
  }

  const res = await fetch(`${args.supabaseUrl}/functions/v1/marketplace-order-pull`, {
    method: "POST",
    headers,
    body: JSON.stringify(payload),
  });
  const data = await res.json().catch(async () => ({ raw: await res.text().catch(() => "") }));
  return { ok: res.ok, http_status: res.status, data };
}

async function insertOrderJobLog(admin: any, job: any, status: "success" | "warning" | "error", message: string, request: JsonMap, response: JsonMap) {
  try {
    await admin.from("marketplace_sync_logs").insert({
      marketplace_account_id: job.marketplace_account_id,
      marketplace: text(job.marketplace) || "tiktok_shop",
      action: "order_pull_job_v24",
      status,
      message,
      request_payload: request,
      response_payload: response,
      created_at: new Date().toISOString(),
    });
  } catch (_) {
    // Log gagal tidak boleh menggagalkan proses pull order utama.
  }
}

async function countRemainingJobs(admin: any, tenantId: string, accountId: string): Promise<number> {
  let query = admin
    .from("marketplace_order_pull_jobs")
    .select("order_pull_job_id", { count: "exact", head: true })
    .eq("tenant_id", tenantId)
    .in("status", ["pending", "retry"])
    .lte("next_run_at", new Date().toISOString());
  if (accountId) query = query.eq("marketplace_account_id", accountId);
  const { count } = await query;
  return Number(count || 0);
}

function emptyProcessedResult() {
  return {
    processed: 0,
    failed: 0,
    orders: 0,
    items: 0,
    mappedItems: 0,
    unmappedItems: 0,
    warningCount: 0,
    details: [] as JsonMap[],
  };
}


function emptyStatusRefreshResult() {
  return {
    accounts: 0,
    checked: 0,
    updated: 0,
    reviewRequired: 0,
    failed: 0,
    warningCount: 0,
    details: [] as JsonMap[],
  };
}

async function refreshExistingOrderStatuses(args: {
  admin: any;
  ctx: AuthContext;
  supabaseUrl: string;
  serviceRoleKey: string;
  cronSecret: string;
  tenantId: string;
  accountId: string;
  maxAccounts: number;
  statusRangeDays: number;
  maxExistingOrders: number;
  skipCompletedStatusRefresh: boolean;
}) {
  const result = emptyStatusRefreshResult();

  let accountQuery = args.admin
    .from("marketplace_accounts")
    .select("marketplace_account_id, marketplace, status, is_deleted")
    .eq("tenant_id", args.tenantId)
    .in("marketplace", ["tiktok_shop", "shopee"])
    .eq("status", "active")
    .eq("is_deleted", false)
    .order("created_at", { ascending: true })
    .limit(args.maxAccounts);

  if (args.accountId) accountQuery = accountQuery.eq("marketplace_account_id", args.accountId);

  const { data: accounts, error } = await accountQuery;
  if (error) {
    result.failed += 1;
    result.details.push({ type: "order_status_refresh", status: "failed_load_account", error: error.message });
    return result;
  }

  result.accounts = accounts?.length || 0;

  for (const account of accounts || []) {
    const accountId = text(account.marketplace_account_id);
    const statusRefresh = await invokeOrderPull(args, {
      action: "refresh_existing_status",
      tenant_id: args.tenantId,
      marketplace_account_id: accountId,
      status_range_days: args.statusRangeDays,
      max_existing_orders: args.maxExistingOrders,
      skip_completed_status_refresh: args.skipCompletedStatusRefresh,
      source: "marketplace-order-sync-jobs-v48-status-refresh-canonical",
      sync_status_aliases: true,
      canonical_status_sync: true,
      only_unfinished: true,
      only_active_orders: true,
      skip_completed_orders: true,
      skip_final_orders: true,
      include_completed: false,
      exclude_statuses: ["COMPLETED", "CANCELLED", "CANCELED", "DELIVERED"],
      auto_status_only: true,
    });

    if (statusRefresh.ok && statusRefresh.http_status >= 200 && statusRefresh.http_status < 300 && statusRefresh.data?.ok !== false) {
      const checked = toInt(statusRefresh.data?.checked);
      const updated = toInt(statusRefresh.data?.updated);
      const reviewRequired = toInt(statusRefresh.data?.review_required);
      const failed = toInt(statusRefresh.data?.failed);
      const warnings = toInt(statusRefresh.data?.warning_count);
      result.checked += checked;
      result.updated += updated;
      result.reviewRequired += reviewRequired;
      result.failed += failed;
      result.warningCount += warnings;
      result.details.push({
        type: "order_status_refresh",
        account_id: accountId,
        status: "done",
        checked,
        updated,
        review_required: reviewRequired,
        failed,
        warning_count: warnings,
        message: statusRefresh.data?.message,
      });
    } else {
      result.failed += 1;
      result.details.push({
        type: "order_status_refresh",
        account_id: accountId,
        status: "warning",
        http_status: statusRefresh.http_status,
        response: statusRefresh.data,
      });
    }
  }

  return result;
}

async function updateOrderPullSetting(admin: any, tenantId: string, message: string) {
  try {
    await admin
      .from("marketplace_order_pull_settings")
      .update({
        interval_minutes: 2,
        last_auto_run_at: new Date().toISOString(),
        last_auto_run_message: message,
        updated_at: new Date().toISOString(),
      })
      .eq("tenant_id", tenantId);
  } catch (_) {
    // Setting update tidak boleh menggagalkan worker utama.
  }
}

function buildDateRanges(modeRaw: string, startDateRaw: string, endDateRaw: string): Array<{ startDate: string; endDate: string; jobType: string; priority: number }> {
  const mode = text(modeRaw).toLowerCase();
  if (mode === "today") {
    const today = jakartaDateString(0);
    return [{ startDate: today, endDate: today, jobType: "auto_today_window", priority: 90 }];
  }
  if (mode === "today_yesterday" || mode === "auto") {
    const today = jakartaDateString(0);
    const yesterday = jakartaDateString(-1);
    return [
      { startDate: today, endDate: today, jobType: "auto_today_window", priority: 90 },
      { startDate: yesterday, endDate: yesterday, jobType: "auto_yesterday_window", priority: 70 },
    ];
  }

  const startDate = normalizeDate(startDateRaw) || jakartaDateString(0);
  const endDate = normalizeDate(endDateRaw) || startDate;
  if (wibDateStartSeconds(endDate) < wibDateStartSeconds(startDate)) throw new Error("Tanggal akhir tidak boleh sebelum tanggal awal.");
  const diffDays = Math.floor((wibDateStartSeconds(endDate) - wibDateStartSeconds(startDate)) / 86400) + 1;
  if (diffDays > 90) throw new Error("Maksimal pull manual order marketplace adalah 90 hari.");

  const ranges: Array<{ startDate: string; endDate: string; jobType: string; priority: number }> = [];
  let cursorSeconds = wibDateStartSeconds(startDate);
  const endSeconds = wibDateStartSeconds(endDate);
  while (cursorSeconds <= endSeconds) {
    const date = dateStringFromWibStartSeconds(cursorSeconds);
    ranges.push({ startDate: date, endDate: date, jobType: "manual_period_window", priority: 80 });
    cursorSeconds += 86400;
  }
  return ranges;
}

function buildWindows(date: string, windowMinutes: number): Array<{ startSeconds: number; endSeconds: number; label: string }> {
  const startOfDay = wibDateStartSeconds(date);
  const step = windowMinutes * 60;
  const today = jakartaDateString(0);
  const nowSeconds = Math.floor(Date.now() / 1000);
  const maxRangeEnd = date === today ? Math.min(startOfDay + 86400, nowSeconds) : startOfDay + 86400;
  const windows: Array<{ startSeconds: number; endSeconds: number; label: string }> = [];
  for (let offset = 0; offset < 86400; offset += step) {
    const startSeconds = startOfDay + offset;
    if (startSeconds >= maxRangeEnd) break;
    const endSeconds = Math.min(maxRangeEnd, startSeconds + step);
    windows.push({
      startSeconds,
      endSeconds,
      label: `${date} ${timeLabel(offset)}-${timeLabel(endSeconds - startOfDay)}`,
    });
  }
  return windows;
}

function timeLabel(offsetSeconds: number): string {
  const clamped = Math.max(0, Math.min(86400, offsetSeconds));
  const hour = Math.floor(clamped / 3600);
  const minute = Math.floor((clamped % 3600) / 60);
  return `${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}`;
}

function jakartaDateString(offsetDays: number): string {
  const wibOffsetMs = 7 * 60 * 60 * 1000;
  const d = new Date(Date.now() + wibOffsetMs + offsetDays * 86400_000);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-${String(d.getUTCDate()).padStart(2, "0")}`;
}

function normalizeDate(raw: string): string {
  const clean = text(raw).slice(0, 10);
  return /^\d{4}-\d{2}-\d{2}$/.test(clean) ? clean : "";
}

function wibDateStartSeconds(raw: string): number {
  const clean = normalizeDate(raw);
  if (!clean) return NaN;
  const [year, month, day] = clean.split("-").map((x) => Number(x));
  return Math.floor((Date.UTC(year, month - 1, day, 0, 0, 0) - 7 * 60 * 60 * 1000) / 1000);
}

function dateStringFromWibStartSeconds(seconds: number): string {
  const wib = new Date(seconds * 1000 + 7 * 60 * 60 * 1000);
  return `${wib.getUTCFullYear()}-${String(wib.getUTCMonth() + 1).padStart(2, "0")}-${String(wib.getUTCDate()).padStart(2, "0")}`;
}

function shouldFallbackSmallRequest(pull: { http_status: number; data: any }): boolean {
  const message = JSON.stringify(pull.data || {}).toLowerCase();
  return pull.http_status === 504 || message.includes("504") || message.includes("546") || message.includes("timeout") || message.includes("resource") || message.includes("limit");
}

function isAdminRole(role: string): boolean {
  return ["super_admin", "superadmin", "admin", "owner"].includes(normalizeRole(role));
}

function normalizeRole(role: string): string {
  return text(role).toLowerCase().replace(/[^a-z0-9]+/g, "_");
}

function requiredEnv(name: string): string {
  const value = String(Deno.env.get(name) || "").trim();
  if (!value) throw new Error(`${name} belum diset.`);
  return value;
}

function json(body: JsonMap, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { ...corsHeaders, "content-type": "application/json; charset=utf-8" },
  });
}

async function safeJson(req: Request): Promise<JsonMap> {
  try {
    const raw = await req.text();
    if (!raw.trim()) return {};
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch (_) {
    return {};
  }
}

function text(value: unknown): string {
  return String(value ?? "").trim();
}

function clampInt(value: unknown, min: number, max: number, fallback: number): number {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(min, Math.min(max, parsed));
}

function toInt(value: unknown): number {
  const parsed = Number.parseInt(String(value ?? "0"), 10);
  return Number.isFinite(parsed) ? parsed : 0;
}

function cleanError(err: unknown): string {
  if (err instanceof Error) return err.message;
  return String(err ?? "Unknown error");
}

function getSafeErrorResult(message: string, tokenAuditExists?: boolean): Record<string, unknown> {
  const msg = message.toLowerCase();
  let status = "failed";
  if (msg.includes("kosong") || msg.includes("missing") || msg.includes("token kosong")) {
    status = "token_missing";
  } else if (msg.includes("expired") || msg.includes("kadaluarsa")) {
    status = "refresh_token_expired";
  } else if (msg.includes("refresh token shopee gagal") || msg.includes("refresh token tiktok gagal") || msg.includes("refresh gagal")) {
    status = "refresh_failed";
  } else if (msg.includes("re-authorize") || msg.includes("reconnect") || msg.includes("reauth")) {
    status = "reauth_required";
  } else {
    status = "provider_api_error";
  }
  
  const tokenExists = tokenAuditExists !== undefined
    ? tokenAuditExists
    : !(msg.includes("kosong") || msg.includes("missing") || msg.includes("token kosong") || msg.includes("re-authorize") || msg.includes("reconnect"));

  return { ok: false, status, token_audit_exists: tokenExists, message };
}
