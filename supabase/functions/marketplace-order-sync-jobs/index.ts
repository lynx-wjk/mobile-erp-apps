import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
const FUNCTION_VERSION = "marketplace-order-sync-jobs-bootstrap-pagination-v53-2026-06-10";
const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type, x-marketplace-cron-secret, x-stock-sync-cron-secret",
  "access-control-allow-methods": "POST, OPTIONS"
};
Deno.serve(async (req)=>{
  if (req.method === "OPTIONS") return new Response("ok", {
    headers: corsHeaders
  });
  if (req.method !== "POST") return json({
    ok: false,
    version: FUNCTION_VERSION,
    message: "Method not allowed. Gunakan POST."
  }, 405);
  try {
    const supabaseUrl = requiredEnv("SUPABASE_URL").replace(/\/+$/, "");
    const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");
    const edgeAuthKey = String(
      Deno.env.get("EDGE_FUNCTION_AUTH_KEY") ||
      Deno.env.get("SUPABASE_ANON_KEY") ||
      ""
    ).trim();
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
    const body = await safeJson(req);
    const params = normalizeParams(body);
    const cronSecret = String(Deno.env.get("MARKETPLACE_CRON_SECRET") || Deno.env.get("MARKETPLACE_AUTO_SYNC_CRON_SECRET") || Deno.env.get("STOCK_SYNC_CRON_SECRET") || "").trim();
    const ctx = await authenticate({
      req,
      admin,
      cronSecret,
      params
    });
    if (normalizeRole(ctx.roleId) === "demo_super_admin") {
      return json({
        ok: false,
        version: FUNCTION_VERSION,
        message: "Demo account tidak boleh pull order marketplace production."
      }, 403);
    }
    const tenantId = text(params.tenant_id) || ctx.tenantId;
    if (!tenantId && ctx.isCron) {
      const delegated = await delegateOrderCronToAutoRunner({
        supabaseUrl,
        serviceRoleKey,
        cronSecret,
        params
      });
      return json({
        ok: delegated.ok,
        version: FUNCTION_VERSION,
        delegated_to: "marketplace-auto-runner",
        http_status: delegated.http_status,
        data: delegated.data
      }, delegated.ok ? 200 : delegated.http_status || 500);
    }
    if (!tenantId) return json({
      ok: false,
      version: FUNCTION_VERSION,
      message: "tenant_id wajib diisi. Untuk cron tanpa tenant, pakai header/body cron_secret agar bisa delegate ke marketplace-auto-runner."
    }, 400);
    if (!ctx.isCron && tenantId !== ctx.tenantId && !isAdminRole(ctx.roleId)) {
      return json({
        ok: false,
        version: FUNCTION_VERSION,
        message: "Forbidden tenant access."
      }, 403);
    }
    const mode = text(params.mode || params.action || (ctx.isCron ? "auto" : "period")).toLowerCase();
    const enqueue = params.enqueue !== false;
    const process = params.process !== false;
    const accountId = text(params.account_id || params.marketplace_account_id);
    const maxAccounts = clampInt(params.max_accounts, 1, 100, 50);
    const statusMaxAccounts = clampInt(params.status_max_accounts ?? params.max_status_accounts ?? 100, 1, 100, 100);
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
    let ranges = [];
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
        source
      });
      queued = queueResult.queued;
      queueAccounts = queueResult.accounts;
      ranges = queueResult.ranges;
    }
    const processedResult = process ? await processOrderPullJobs({
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
      skipCompletedOrderPull
    }) : emptyProcessedResult();
    const statusResult = refreshExistingStatus ? await refreshExistingOrderStatuses({
      admin,
      ctx,
      supabaseUrl,
      serviceRoleKey,
      cronSecret,
      tenantId,
      accountId,
      maxAccounts: statusMaxAccounts,
      statusRangeDays,
      maxExistingOrders,
      skipCompletedStatusRefresh
    }) : emptyStatusRefreshResult();
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
      details: [
        ...processedResult.details,
        ...statusResult.details
      ].slice(0, 18),
      message
    });
  } catch (err) {
    return json({
      ok: false,
      version: FUNCTION_VERSION,
      message: cleanError(err)
    }, 500);
  }
});
async function delegateOrderCronToAutoRunner(args) {
  try {
    const response = await fetch(`${args.supabaseUrl.replace(/\/+$/, "")}/functions/v1/marketplace-auto-runner`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "authorization": `Bearer ${args.edgeAuthKey || args.serviceRoleKey}`,
        "apikey": args.edgeAuthKey || args.serviceRoleKey,
        "x-marketplace-cron-secret": args.cronSecret
      },
      body: JSON.stringify({
        run_stock: false,
        run_order: true,
        run_finance: false,
        force: args.params.force === true,
        max_accounts: args.params.max_accounts,
        account_id: args.params.account_id || args.params.marketplace_account_id,
        source: "marketplace-order-sync-jobs-v24-6-44-delegated-cron"
      })
    });
    const data = await response.json().catch(async ()=>({
        raw: await response.text().catch(()=>"")
      }));
    return {
      ok: response.ok && data?.ok !== false,
      http_status: response.status,
      data
    };
  } catch (err) {
    return {
      ok: false,
      http_status: 0,
      data: {
        ok: false,
        message: String(err)
      }
    };
  }
}
function normalizeParams(body) {
  const nested = body.params;
  if (nested && typeof nested === "object" && !Array.isArray(nested)) {
    return {
      ...body,
      ...nested
    };
  }
  return body;
}
async function authenticate(args) {
  const incomingSecret = String(args.req.headers.get("x-marketplace-cron-secret") || args.req.headers.get("x-stock-sync-cron-secret") || args.params.cron_secret || args.params.marketplace_cron_secret || args.params.x_marketplace_cron_secret || args.params.secret || "").trim();
  const isCron = args.cronSecret.length > 0 && incomingSecret === args.cronSecret;
  const originalBearer = (args.req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (isCron) {
    return {
      userId: "00000000-0000-0000-0000-000000000000",
      tenantId: text(args.params.tenant_id),
      roleId: "super_admin",
      isCron: true,
      originalBearer
    };
  }
  if (!originalBearer) throw new Error("Missing authorization header.");
  const { data: userData, error: userError } = await args.admin.auth.getUser(originalBearer);
  if (userError || !userData?.user) throw new Error("Invalid user session.");
  const { data: profile, error: profileError } = await args.admin.from("users").select("user_id, tenant_id, role_id, status").eq("user_id", userData.user.id).maybeSingle();
  if (profileError || !profile) throw new Error(profileError?.message || "User profile not found.");
  if (profile.status !== "active") throw new Error("User is not active.");
  return {
    userId: text(profile.user_id),
    tenantId: text(profile.tenant_id),
    roleId: text(profile.role_id),
    isCron: false,
    originalBearer
  };
}
async function enqueueOrderPullJobs(args) {
  const ranges = buildDateRanges(args.mode, args.startDate, args.endDate);
  let accountQuery = args.admin.from("marketplace_accounts").select("marketplace_account_id, tenant_id, marketplace, status, is_deleted").eq("tenant_id", args.tenantId).in("marketplace", [
    "tiktok_shop",
    "shopee"
  ]).eq("status", "active").eq("is_deleted", false).order("created_at", {
    ascending: true
  }).limit(args.maxAccounts);
  if (args.accountId) accountQuery = accountQuery.eq("marketplace_account_id", args.accountId);
  const { data: accounts, error: accountError } = await accountQuery;
  if (accountError) throw new Error(`Load marketplace account gagal: ${accountError.message}`);
  const rows = [];
  const rangeSummaries = [];
  for (const range of ranges){
    rangeSummaries.push({
      start_date: range.startDate,
      end_date: range.endDate,
      job_type: range.jobType,
      priority: range.priority
    });
    for (const account of accounts || []){
      const marketplaceAccountId = text(account.marketplace_account_id);
      if (args.boundedAutoCron) {
        const activeJobs = await countActiveAutoOrderJobs(args.admin, args.tenantId, marketplaceAccountId);
        if (activeJobs > 0) continue;
      }
      const windows = buildWindows(range.startDate, args.windowMinutes);
      const selectedWindows = args.boundedAutoCron ? windows.slice(-Math.max(1, args.maxJobs)) : windows;
      for (const window of selectedWindows){
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
            window_minutes: args.windowMinutes
          },
          last_result: {},
          requested_by: args.ctx.userId === "00000000-0000-0000-0000-000000000000" ? null : args.ctx.userId,
          updated_at: new Date().toISOString()
        });
      }
    }
  }
  if (args.forceRequeue && rows.length > 0) {
    const minStart = Math.min(...rows.map((row)=>Number(row.window_start_seconds)));
    const maxEnd = Math.max(...rows.map((row)=>Number(row.window_end_seconds)));
    let resetQuery = args.admin.from("marketplace_order_pull_jobs").update({
      status: "pending",
      attempts: 0,
      next_run_at: new Date().toISOString(),
      locked_at: null,
      last_run_at: null,
      finished_at: null,
      last_message: "Requeue manual dari aplikasi.",
      updated_at: new Date().toISOString()
    }).eq("tenant_id", args.tenantId).gte("window_start_seconds", minStart).lte("window_end_seconds", maxEnd);
    if (args.accountId) resetQuery = resetQuery.eq("marketplace_account_id", args.accountId);
    await resetQuery;
  }
  if (rows.length === 0) return {
    queued: 0,
    accounts: accounts?.length || 0,
    ranges: rangeSummaries
  };
  const { data, error } = await args.admin.from("marketplace_order_pull_jobs").upsert(rows, {
    onConflict: "marketplace_account_id,job_type,window_start_seconds,window_end_seconds",
    ignoreDuplicates: !args.forceRequeue
  }).select("order_pull_job_id");
  if (error) throw new Error(`Enqueue order pull jobs gagal: ${error.message}`);
  return {
    queued: Array.isArray(data) ? data.length : rows.length,
    accounts: accounts?.length || 0,
    ranges: rangeSummaries
  };
}
async function countActiveAutoOrderJobs(admin, tenantId, accountId) {
  const { count, error } = await admin.from("marketplace_order_pull_jobs").select("order_pull_job_id", {
    count: "exact",
    head: true
  }).eq("tenant_id", tenantId).eq("marketplace_account_id", accountId).in("status", [
    "pending",
    "retry",
    "running"
  ]).like("job_type", "auto_%");
  if (error) throw new Error(`Cek antrean order aktif gagal: ${error.message}`);
  return Number(count || 0);
}
async function processOrderPullJobs(args) {
  await resetStaleBootstrapJobs(args.admin, args.tenantId, args.accountId);
  let query = args.admin.from("marketplace_order_pull_jobs").select("*").eq("tenant_id", args.tenantId).in("status", [
    "pending",
    "retry"
  ]).lte("next_run_at", new Date().toISOString()).order("priority", {
    ascending: false
  }).order("window_start_seconds", {
    ascending: false
  }).order("created_at", {
    ascending: true
  }).limit(args.maxJobs);
  if (args.accountId) query = query.eq("marketplace_account_id", args.accountId);
  const { data: jobs, error } = await query;
  if (error) throw new Error(`Load order pull jobs gagal: ${error.message}`);
  const result = emptyProcessedResult();
  const loadedJobs = Array.isArray(jobs) ? jobs : [];
  const bootstrapJobs = loadedJobs.filter((job)=>isBootstrapOrderJob(job));
  const jobsToProcess = bootstrapJobs.length > 0 ? [
    bootstrapJobs[0]
  ] : loadedJobs;
  if (bootstrapJobs.length > 1) {
    result.details.push({
      type: "bootstrap_single_flight",
      status: "bounded",
      loaded_bootstrap_jobs: bootstrapJobs.length,
      processed_bootstrap_jobs: 1,
      message: "Bootstrap jobs diproses single-flight untuk menghindari timeout/overlap."
    });
  }
  for (const job of jobsToProcess){
    const jobId = text(job.order_pull_job_id || job.id);
    const startedAt = new Date().toISOString();
    const { data: claimedJob, error: claimError } = await args.admin.from("marketplace_order_pull_jobs").update({
      status: "running",
      locked_at: startedAt,
      last_run_at: startedAt,
      updated_at: startedAt
    }).eq("order_pull_job_id", jobId).in("status", [
      "pending",
      "retry"
    ]).select("order_pull_job_id").maybeSingle();
    if (claimError) throw new Error(`Claim order pull job gagal: ${claimError.message}`);
    if (!claimedJob) {
      result.details.push({
        job_id: jobId,
        window: job.window_label,
        status: "skipped_already_claimed"
      });
      continue;
    }
    const jobPayload = job.payload && typeof job.payload === "object" && !Array.isArray(job.payload)
      ? job.payload
      : {};
    const isBootstrapJob = isBootstrapOrderJob(job);

    const manualForceRefresh =
      text(jobPayload.mode).includes("force_refresh") ||
      text(jobPayload.source).includes("force_refresh") ||
      jobPayload.skip_completed_order_pull === false ||
      jobPayload.skip_completed_orders === false ||
      jobPayload.skip_final_orders === false;

    const jobPageSize = isBootstrapJob
      ? clampInt(
        jobPayload.page_size ?? jobPayload.limit ?? jobPayload.max_orders ?? jobPayload.max_orders_per_account ?? args.pageSize,
        10,
        50,
        50
      )
      : clampInt(
        jobPayload.max_orders ?? jobPayload.max_orders_per_account ?? jobPayload.page_size ?? jobPayload.limit ?? args.pageSize,
        10,
        500,
        args.pageSize
      );

    const jobMaxPages = isBootstrapJob
      ? clampInt(
        jobPayload.max_pages_per_window ?? jobPayload.max_pages ?? jobPayload.max_pages_per_account ?? args.maxPages,
        1,
        20,
        5
      )
      : clampInt(
        jobPayload.max_pages ?? jobPayload.max_pages_per_account ?? args.maxPages,
        1,
        20,
        args.maxPages
      );

    const jobMaxDetails = isBootstrapJob
      ? clampInt(
        jobPayload.max_details ?? jobPayload.max_details_per_account ?? jobPageSize * jobMaxPages,
        0,
        5000,
        jobPageSize * jobMaxPages
      )
      : clampInt(
        jobPayload.max_details ?? jobPayload.max_details_per_account ?? args.maxDetails,
        0,
        500,
        args.maxDetails
      );

    const jobSkipCompletedOrderPull = manualForceRefresh ? false : jobPayload.skip_completed_order_pull === false ? false : args.skipCompletedOrderPull;

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
      statuses: Array.isArray(jobPayload.target_statuses)
        ? jobPayload.target_statuses
        : Array.isArray(jobPayload.statuses)
          ? jobPayload.statuses
          : [],
      include_statusless_search: jobPayload.include_statusless_search === false ? false : true,
      include_update_time_search: jobPayload.include_update_time_search === true || args.includeUpdateTimeSearch,
      skip_completed_order_pull: jobSkipCompletedOrderPull,
      skip_completed_orders: jobSkipCompletedOrderPull,
      skip_final_orders: jobSkipCompletedOrderPull,
      include_completed: manualForceRefresh || jobPayload.include_completed === true,
      statusless_only: manualForceRefresh || jobPayload.statusless_only === false ? false : true,
      limit: jobPageSize,
      max_orders: jobPageSize,
      max_orders_per_account: jobPageSize,
      max_pages: jobMaxPages,
      max_pages_per_account: jobMaxPages,
      max_details: jobMaxDetails,
      max_details_per_account: jobMaxDetails,
      search_mode: isBootstrapJob
        ? "bootstrap_90d_adaptive_order_pull_job_v53"
        : manualForceRefresh
          ? "manual_force_refresh_order_pull_job_v52"
          : "statusless_order_pull_job_v24",
      source: text(jobPayload.source) || (isBootstrapJob ? "marketplace-order-sync-jobs-bootstrap-v53" : "marketplace-order-sync-jobs")
    };
    let pull = null;
    try {
      pull = await invokeOrderPull(args, basePayload);
      if (!isBootstrapJob && (!pull.ok || pull.http_status >= 300 || pull.data?.ok === false) && shouldFallbackSmallRequest(pull)) {
        const fallbackPayload = {
          ...basePayload,
          include_update_time_search: false,
          max_pages: 1,
          max_details: Math.min(50, args.maxDetails),
          search_mode: "statusless_order_pull_job_v24_fallback_small"
        };
        const fallback = await invokeOrderPull(args, fallbackPayload);
        if (fallback.ok && fallback.http_status < 300 && fallback.data?.ok !== false) {
          pull = {
            ...fallback,
            data: {
              ...fallback.data,
              fallback_used: true,
              fallback_reason: pull.data?.message || pull.data?.raw || `HTTP ${pull.http_status}`
            }
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
      const pagesScanned = toInt(pull.data?.pages_scanned ?? pull.data?.pages_checked ?? pull.data?.page_count);
      const capacityHit = isBootstrapPageLimitHit({
        isBootstrapJob,
        pagesScanned,
        jobMaxPages,
        orders,
        jobPageSize
      });
      const splitResult = capacityHit
        ? await enqueueBootstrapSplitJobs(args, job, jobPayload, {
          pageSize: jobPageSize,
          maxPages: jobMaxPages,
          maxDetails: jobMaxDetails,
          orders,
          items,
          pagesScanned
        })
        : {
          queued: 0,
          reason: ""
        };
      const finalWarnings = warnings + (capacityHit ? 1 : 0);
      result.processed += 1;
      result.orders += orders;
      result.items += items;
      result.mappedItems += mapped;
      result.unmappedItems += unmapped;
      result.warningCount += finalWarnings;
      result.details.push({
        job_id: jobId,
        window: job.window_label,
        status: "done",
        orders,
        items,
        mapped,
        unmapped,
        warnings: finalWarnings,
        fallback_used: pull.data?.fallback_used === true,
        page_limit_hit: capacityHit,
        split_jobs_queued: splitResult.queued
      });
      const lastResultData = orders === 0 ? {
        ...pull.data,
        status: "no_new_orders",
        page_limit_hit: capacityHit,
        split_jobs_queued: splitResult.queued,
        split_reason: splitResult.reason
      } : {
        ...(pull.data || {}),
        page_limit_hit: capacityHit,
        split_jobs_queued: splitResult.queued,
        split_reason: splitResult.reason
      };
      const doneMessage = capacityHit
        ? `Selesai dengan page-limit guard: ${orders} order, ${items} item. Split queued=${splitResult.queued}.`
        : pull.data?.message || `Selesai: ${orders} order, ${items} item.`;
      await args.admin.from("marketplace_order_pull_jobs").update({
        status: "done",
        finished_at: new Date().toISOString(),
        order_count: orders,
        item_count: items,
        mapped_count: mapped,
        unmapped_count: unmapped,
        warning_count: finalWarnings,
        last_message: doneMessage,
        last_result: lastResultData,
        updated_at: new Date().toISOString()
      }).eq("order_pull_job_id", jobId);
      await insertOrderJobLog(args.admin, job, "success", `Order window ${job.window_label || ""} selesai: ${orders} order, ${items} item.`, basePayload, lastResultData);
    } catch (err) {
      result.failed += 1;
      const attempts = toInt(job.attempts) + 1;
      const bootstrapRetryable = isBootstrapJob && isRetryableBootstrapError(err);
      const retryMinutes = Math.min(60, Math.max(3, attempts * (isBootstrapJob ? 3 : 5)));
      const failedStatus = bootstrapRetryable || attempts < (isBootstrapJob ? 5 : 3) ? "retry" : "failed";
      const message = cleanError(err);
      const safeErrorResult = {
        ...getSafeErrorResult(message),
        ...pull?.data && typeof pull.data === "object" ? pull.data : {}
      };
      await args.admin.from("marketplace_order_pull_jobs").update({
        status: failedStatus,
        attempts,
        next_run_at: new Date(Date.now() + retryMinutes * 60_000).toISOString(),
        finished_at: new Date().toISOString(),
        last_message: message,
        last_result: safeErrorResult,
        updated_at: new Date().toISOString()
      }).eq("order_pull_job_id", jobId);
      await insertOrderJobLog(args.admin, job, failedStatus === "failed" ? "error" : "warning", message, basePayload, safeErrorResult);
      result.details.push({
        job_id: jobId,
        window: job.window_label,
        status: failedStatus,
        error: message
      });
    }
  }
  return result;
}

async function resetStaleBootstrapJobs(admin, tenantId, accountId) {
  let query = admin.from("marketplace_order_pull_jobs").update({
    status: "retry",
    locked_at: null,
    finished_at: null,
    next_run_at: new Date().toISOString(),
    last_message: "Reset stale bootstrap running job before permanent worker claim.",
    updated_at: new Date().toISOString()
  }).eq("tenant_id", tenantId).eq("job_type", "bootstrap_90d_adaptive_v1").eq("status", "running").lt("locked_at", new Date(Date.now() - 3 * 60_000).toISOString());
  if (accountId) query = query.eq("marketplace_account_id", accountId);
  await query;
}
function isBootstrapOrderJob(job) {
  return text(job?.job_type).startsWith("bootstrap_90d");
}
function isRetryableBootstrapError(err) {
  const msg = cleanError(err).toLowerCase();
  return msg.includes("502") || msg.includes("503") || msg.includes("504") || msg.includes("546") || msg.includes("timeout") || msg.includes("resource") || msg.includes("limit") || msg.includes("network");
}
function isBootstrapPageLimitHit(args) {
  if (!args.isBootstrapJob) return false;
  if (args.jobMaxPages <= 0 || args.jobPageSize <= 0) return false;
  if (args.pagesScanned < args.jobMaxPages) return false;
  return args.orders >= args.jobPageSize * args.jobMaxPages;
}
async function enqueueBootstrapSplitJobs(args, job, jobPayload, meta) {
  const start = Number(job.window_start_seconds || 0);
  const end = Number(job.window_end_seconds || 0);
  const duration = end - start;
  if (!Number.isFinite(start) || !Number.isFinite(end) || duration <= 900) {
    return {
      queued: 0,
      reason: "window_too_small_to_split"
    };
  }
  const splitCount = duration >= 21600 ? 4 : 2;
  const rows = [];
  for(let i = 0; i < splitCount; i += 1){
    const childStart = Math.floor(start + duration * i / splitCount);
    const childEnd = Math.floor(start + duration * (i + 1) / splitCount);
    if (childEnd <= childStart) continue;
    const childDate = dateStringFromWibStartSeconds(childStart);
    rows.push({
      tenant_id: text(job.tenant_id),
      marketplace_account_id: text(job.marketplace_account_id),
      marketplace: text(job.marketplace),
      job_type: text(job.job_type) || "bootstrap_90d_adaptive_v1",
      period_start: childDate,
      period_end: dateStringFromWibStartSeconds(Math.max(childStart, childEnd - 1)),
      window_start_seconds: childStart,
      window_end_seconds: childEnd,
      window_label: `${childDate} ${timeLabelFromUnixWibSeconds(childStart)}-${timeLabelFromUnixWibSeconds(childEnd)}`,
      status: "pending",
      priority: toInt(job.priority) + 2,
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
      last_message: "Queued split child from bootstrap page-limit guard.",
      payload: {
        ...jobPayload,
        source: text(jobPayload.source) || "marketplace-order-sync-jobs-bootstrap-v53-split",
        window_kind: "split_from_page_limit",
        split_parent_job_id: text(job.order_pull_job_id || job.id),
        split_reason: `pages_scanned=${meta.pagesScanned}, orders=${meta.orders}, page_size=${meta.pageSize}, max_pages=${meta.maxPages}`,
        page_size: meta.pageSize,
        limit: meta.pageSize,
        max_pages_per_window: meta.maxPages,
        max_pages: meta.maxPages,
        max_details: meta.maxDetails,
        max_details_per_account: meta.maxDetails
      },
      last_result: {},
      requested_by: job.requested_by || null,
      updated_at: new Date().toISOString()
    });
  }
  if (rows.length === 0) {
    return {
      queued: 0,
      reason: "no_valid_split_rows"
    };
  }
  const { data, error } = await args.admin.from("marketplace_order_pull_jobs").upsert(rows, {
    onConflict: "marketplace_account_id,job_type,window_start_seconds,window_end_seconds",
    ignoreDuplicates: true
  }).select("order_pull_job_id");
  if (error) {
    return {
      queued: 0,
      reason: `split_insert_failed: ${error.message}`
    };
  }
  return {
    queued: Array.isArray(data) ? data.length : rows.length,
    reason: "page_limit_split_child_jobs_queued"
  };
}
function timeLabelFromUnixWibSeconds(seconds) {
  const wib = new Date(seconds * 1000 + 7 * 60 * 60 * 1000);
  const hour = wib.getUTCHours();
  const minute = wib.getUTCMinutes();
  return `${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}`;
}
async function invokeOrderPull(args, payload) {
  const edgeAuthKey = String(
    Deno.env.get("EDGE_FUNCTION_AUTH_KEY") ||
    Deno.env.get("SUPABASE_ANON_KEY") ||
    args.edgeAuthKey ||
    ""
  ).trim();

  const childAuthKey = edgeAuthKey || args.serviceRoleKey;

  const headers = {
    "content-type": "application/json",
    "apikey": childAuthKey
  };
  if (args.ctx.isCron) {
    headers.authorization = `Bearer ${childAuthKey}`;
    if (args.cronSecret) headers["x-marketplace-cron-secret"] = args.cronSecret;
  } else {
    headers.authorization = `Bearer ${args.ctx.originalBearer}`;
  }
  const res = await fetch(`${args.supabaseUrl}/functions/v1/marketplace-order-pull`, {
    method: "POST",
    headers,
    body: JSON.stringify(payload)
  });
  const data = await res.json().catch(async ()=>({
      raw: await res.text().catch(()=>"")
    }));
  return {
    ok: res.ok,
    http_status: res.status,
    data
  };
}
async function insertOrderJobLog(admin, job, status, message, request, response) {
  try {
    await admin.from("marketplace_sync_logs").insert({
      marketplace_account_id: job.marketplace_account_id,
      marketplace: text(job.marketplace) || "tiktok_shop",
      action: "order_pull_job_v24",
      status,
      message,
      request_payload: request,
      response_payload: response,
      created_at: new Date().toISOString()
    });
  } catch (_) {
  // Log gagal tidak boleh menggagalkan proses pull order utama.
  }
}
async function countRemainingJobs(admin, tenantId, accountId) {
  let query = admin.from("marketplace_order_pull_jobs").select("order_pull_job_id", {
    count: "exact",
    head: true
  }).eq("tenant_id", tenantId).in("status", [
    "pending",
    "retry"
  ]).lte("next_run_at", new Date().toISOString());
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
    details: []
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
    details: []
  };
}
async function refreshExistingOrderStatuses(args) {
  const result = emptyStatusRefreshResult();
  let accountQuery = args.admin.from("marketplace_accounts").select("marketplace_account_id, marketplace, status, is_deleted").eq("tenant_id", args.tenantId).in("marketplace", [
    "tiktok_shop",
    "shopee"
  ]).eq("status", "active").eq("is_deleted", false).order("created_at", {
    ascending: true
  }).limit(args.maxAccounts);
  if (args.accountId) accountQuery = accountQuery.eq("marketplace_account_id", args.accountId);
  const { data: accounts, error } = await accountQuery;
  if (error) {
    result.failed += 1;
    result.details.push({
      type: "order_status_refresh",
      status: "failed_load_account",
      error: error.message
    });
    return result;
  }
  result.accounts = accounts?.length || 0;
  for (const account of accounts || []){
    const accountId = text(account.marketplace_account_id);
    const statusRefresh = await invokeOrderPull(args, {
      action: "refresh_existing_status",
      tenant_id: args.tenantId,
      marketplace_account_id: accountId,
      status_range_days: args.statusRangeDays,
      max_existing_orders: args.maxExistingOrders,
      skip_completed_status_refresh: args.skipCompletedStatusRefresh,
      source: "marketplace-order-sync-jobs-v49-status-refresh-90d-payout-priority",
      sync_status_aliases: true,
      canonical_status_sync: true,
      only_unfinished: true,
      only_active_orders: true,
      skip_completed_orders: true,
      skip_final_orders: true,
      include_completed: false,
      exclude_statuses: [
        "COMPLETED",
        "CANCELLED",
        "CANCELED"
      ],
      auto_status_only: true
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
        message: statusRefresh.data?.message
      });
    } else {
      result.failed += 1;
      result.details.push({
        type: "order_status_refresh",
        account_id: accountId,
        status: "warning",
        http_status: statusRefresh.http_status,
        response: statusRefresh.data
      });
    }
  }
  return result;
}
async function updateOrderPullSetting(admin, tenantId, message) {
  try {
    await admin.from("marketplace_order_pull_settings").update({
      interval_minutes: 2,
      last_auto_run_at: new Date().toISOString(),
      last_auto_run_message: message,
      updated_at: new Date().toISOString()
    }).eq("tenant_id", tenantId);
  } catch (_) {
  // Setting update tidak boleh menggagalkan worker utama.
  }
}
function buildDateRanges(modeRaw, startDateRaw, endDateRaw) {
  const mode = text(modeRaw).toLowerCase();
  if (mode === "today") {
    const today = jakartaDateString(0);
    return [
      {
        startDate: today,
        endDate: today,
        jobType: "auto_today_window",
        priority: 90
      }
    ];
  }
  if (mode === "today_yesterday" || mode === "auto") {
    const today = jakartaDateString(0);
    const yesterday = jakartaDateString(-1);
    return [
      {
        startDate: today,
        endDate: today,
        jobType: "auto_today_window",
        priority: 90
      },
      {
        startDate: yesterday,
        endDate: yesterday,
        jobType: "auto_yesterday_window",
        priority: 70
      }
    ];
  }
  const startDate = normalizeDate(startDateRaw) || jakartaDateString(0);
  const endDate = normalizeDate(endDateRaw) || startDate;
  if (wibDateStartSeconds(endDate) < wibDateStartSeconds(startDate)) throw new Error("Tanggal akhir tidak boleh sebelum tanggal awal.");
  const diffDays = Math.floor((wibDateStartSeconds(endDate) - wibDateStartSeconds(startDate)) / 86400) + 1;
  if (diffDays > 90) throw new Error("Maksimal pull manual order marketplace adalah 90 hari.");
  const ranges = [];
  let cursorSeconds = wibDateStartSeconds(startDate);
  const endSeconds = wibDateStartSeconds(endDate);
  while(cursorSeconds <= endSeconds){
    const date = dateStringFromWibStartSeconds(cursorSeconds);
    ranges.push({
      startDate: date,
      endDate: date,
      jobType: "manual_period_window",
      priority: 80
    });
    cursorSeconds += 86400;
  }
  return ranges;
}
function buildWindows(date, windowMinutes) {
  const startOfDay = wibDateStartSeconds(date);
  const step = windowMinutes * 60;
  const today = jakartaDateString(0);
  const nowSeconds = Math.floor(Date.now() / 1000);
  const maxRangeEnd = date === today ? Math.min(startOfDay + 86400, nowSeconds) : startOfDay + 86400;
  const windows = [];
  for(let offset = 0; offset < 86400; offset += step){
    const startSeconds = startOfDay + offset;
    if (startSeconds >= maxRangeEnd) break;
    const endSeconds = Math.min(maxRangeEnd, startSeconds + step);
    windows.push({
      startSeconds,
      endSeconds,
      label: `${date} ${timeLabel(offset)}-${timeLabel(endSeconds - startOfDay)}`
    });
  }
  return windows;
}
function timeLabel(offsetSeconds) {
  const clamped = Math.max(0, Math.min(86400, offsetSeconds));
  const hour = Math.floor(clamped / 3600);
  const minute = Math.floor(clamped % 3600 / 60);
  return `${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}`;
}
function jakartaDateString(offsetDays) {
  const wibOffsetMs = 7 * 60 * 60 * 1000;
  const d = new Date(Date.now() + wibOffsetMs + offsetDays * 86400_000);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-${String(d.getUTCDate()).padStart(2, "0")}`;
}
function normalizeDate(raw) {
  const clean = text(raw).slice(0, 10);
  return /^\d{4}-\d{2}-\d{2}$/.test(clean) ? clean : "";
}
function wibDateStartSeconds(raw) {
  const clean = normalizeDate(raw);
  if (!clean) return NaN;
  const [year, month, day] = clean.split("-").map((x)=>Number(x));
  return Math.floor((Date.UTC(year, month - 1, day, 0, 0, 0) - 7 * 60 * 60 * 1000) / 1000);
}
function dateStringFromWibStartSeconds(seconds) {
  const wib = new Date(seconds * 1000 + 7 * 60 * 60 * 1000);
  return `${wib.getUTCFullYear()}-${String(wib.getUTCMonth() + 1).padStart(2, "0")}-${String(wib.getUTCDate()).padStart(2, "0")}`;
}
function shouldFallbackSmallRequest(pull) {
  const message = JSON.stringify(pull.data || {}).toLowerCase();
  return pull.http_status === 504 || message.includes("504") || message.includes("546") || message.includes("timeout") || message.includes("resource") || message.includes("limit");
}
function isAdminRole(role) {
  return [
    "super_admin",
    "superadmin",
    "admin",
    "owner"
  ].includes(normalizeRole(role));
}
function normalizeRole(role) {
  return text(role).toLowerCase().replace(/[^a-z0-9]+/g, "_");
}
function requiredEnv(name) {
  const value = String(Deno.env.get(name) || "").trim();
  if (!value) throw new Error(`${name} belum diset.`);
  return value;
}
function json(body, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      ...corsHeaders,
      "content-type": "application/json; charset=utf-8"
    }
  });
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
function text(value) {
  return String(value ?? "").trim();
}
function clampInt(value, min, max, fallback) {
  const parsed = Number.parseInt(String(value ?? ""), 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(min, Math.min(max, parsed));
}
function toInt(value) {
  const parsed = Number.parseInt(String(value ?? "0"), 10);
  return Number.isFinite(parsed) ? parsed : 0;
}
function cleanError(err) {
  if (err instanceof Error) return err.message;
  return String(err ?? "Unknown error");
}
function getSafeErrorResult(message, tokenAuditExists) {
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
  const tokenExists = tokenAuditExists !== undefined ? tokenAuditExists : !(msg.includes("kosong") || msg.includes("missing") || msg.includes("token kosong") || msg.includes("re-authorize") || msg.includes("reconnect"));
  return {
    ok: false,
    status,
    token_audit_exists: tokenExists,
    message
  };
}
