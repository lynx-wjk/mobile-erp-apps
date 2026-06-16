import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type, x-marketplace-cron-secret",
  "access-control-allow-methods": "POST, OPTIONS",
};

type ClaimedState = {
  sync_state_id: string;
  tenant_id: string;
  marketplace_account_id: string;
  marketplace: "shopee" | "tiktok_shop";
  bootstrap_status: string;
  bootstrap_from_seconds: number | null;
  bootstrap_to_seconds: number | null;
  bootstrap_cursor_seconds: number | null;
  recent_cursor_seconds: number | null;
  last_success_window_end_seconds: number | null;
  last_success_at: string | null;
  failure_count: number;
  lock_token: string;
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    if (req.method !== "POST") return json({ ok: false, message: "Method not allowed" }, 405);

    const configuredSecret = String(
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

    if (!configuredSecret || incomingSecret !== configuredSecret) {
      return json({ ok: false, message: "Unauthorized dispatcher request" }, 401);
    }

    const body = await safeJson(req);
    const supabaseUrl = requiredEnv("SUPABASE_URL").replace(/\/+$/, "");
    const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");
    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const maxAccounts = clampInt(body.max_accounts, 1, 20, 6);
    const dryRun = body.dry_run === true;
    const lockSeconds = clampInt(body.lock_seconds, 60, 1800, 600);

    const { data: claimedRows, error: claimError } = await admin.rpc("marketplace_order_sync_claim", {
      p_limit: maxAccounts,
      p_lock_seconds: lockSeconds,
    });

    if (claimError) throw new Error(`Claim sync state gagal: ${claimError.message}`);

    const claimed = (claimedRows || []) as ClaimedState[];
    const results: any[] = [];

    for (const state of claimed) {
      const decision = decideNextWindow(state);

      if (decision.mode === "bootstrap_complete") {
        if (!dryRun) {
          await finishBootstrapComplete(admin, state, decision);
        }
        results.push({ account_id: state.marketplace_account_id, marketplace: state.marketplace, ...decision, ok: true });
        continue;
      }

      if (dryRun) {
        await releaseWithoutWork(admin, state);
        results.push({ account_id: state.marketplace_account_id, marketplace: state.marketplace, ...decision, dry_run: true });
        continue;
      }

      const child = await callOrderPull({
        supabaseUrl,
        cronSecret: configuredSecret,
        tenantId: state.tenant_id,
        marketplaceAccountId: state.marketplace_account_id,
        marketplace: state.marketplace,
        mode: decision.mode,
        startSeconds: decision.startSeconds,
        endSeconds: decision.endSeconds,
      });

      if (child.ok) {
        await finishSuccess(admin, state, decision, child);
      } else {
        await finishFailure(admin, state, child.message || "Order pull failed");
      }

      results.push({
        account_id: state.marketplace_account_id,
        marketplace: state.marketplace,
        mode: decision.mode,
        window_start_seconds: decision.startSeconds,
        window_end_seconds: decision.endSeconds,
        ok: child.ok,
        child_status: child.status,
        orders: child.orders,
        items: child.items,
        message: child.message,
      });
    }

    const allOk = results.every((item) => item?.ok !== false);
    return json({
      ok: allOk,
      function: "marketplace-order-dispatcher",
      claimed: claimed.length,
      processed: results.length,
      results,
    });
  } catch (err) {
    return json({ ok: false, function: "marketplace-order-dispatcher", message: String(err) }, 500);
  }
});

function decideNextWindow(state: ClaimedState) {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const toleranceSeconds = 5 * 60;
  // Keep one dispatcher. Window size is runtime budget, not a separate queue strategy.
  // Shopee 1h has been stable. TikTok 1h hit supervisor cancellation, so use 15m until stable.
  const bootstrapWindowSeconds = state.marketplace === "tiktok_shop" ? 15 * 60 : 60 * 60;
  const catchupWindowSeconds = state.marketplace === "tiktok_shop" ? 15 * 60 : 60 * 60;
  const recentLookbackSeconds = 2 * 60;
  const recentWindowSeconds = 15 * 60;

  const bootstrapFrom = numberOr(state.bootstrap_from_seconds, nowSeconds - 90 * 24 * 60 * 60);
  const bootstrapTo = numberOr(state.bootstrap_to_seconds, nowSeconds);
  const bootstrapCursor = numberOr(state.bootstrap_cursor_seconds, bootstrapFrom);

  if (state.bootstrap_status !== "done") {
    if (bootstrapCursor >= bootstrapTo - 1) {
      return {
        mode: "bootstrap_complete",
        startSeconds: bootstrapTo,
        endSeconds: bootstrapTo,
        nextCursorSeconds: bootstrapTo,
      };
    }

    return {
      mode: "bootstrap_90d",
      startSeconds: bootstrapCursor,
      endSeconds: Math.min(bootstrapCursor + bootstrapWindowSeconds, bootstrapTo),
      nextCursorSeconds: Math.min(bootstrapCursor + bootstrapWindowSeconds, bootstrapTo),
    };
  }

  const recentCursor = numberOr(
    state.recent_cursor_seconds,
    numberOr(state.last_success_window_end_seconds, Math.max(nowSeconds - recentWindowSeconds, bootstrapTo))
  );

  if (recentCursor < nowSeconds - toleranceSeconds) {
    return {
      mode: "catchup_gap",
      startSeconds: recentCursor,
      endSeconds: Math.min(recentCursor + catchupWindowSeconds, nowSeconds),
      nextCursorSeconds: Math.min(recentCursor + catchupWindowSeconds, nowSeconds),
    };
  }

  return {
    mode: "recent_pull",
    startSeconds: Math.max(recentCursor - recentLookbackSeconds, nowSeconds - recentWindowSeconds),
    endSeconds: nowSeconds,
    nextCursorSeconds: nowSeconds,
  };
}

async function callOrderPull(args: {
  supabaseUrl: string;
  cronSecret: string;
  tenantId: string;
  marketplaceAccountId: string;
  marketplace: string;
  mode: string;
  startSeconds: number;
  endSeconds: number;
}) {
  try {
    const response = await fetch(`${args.supabaseUrl}/functions/v1/marketplace-order-pull`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-marketplace-cron-secret": args.cronSecret,
      },
      body: JSON.stringify({
        tenant_id: args.tenantId,
        marketplace_account_id: args.marketplaceAccountId,
        marketplace: args.marketplace,
        start_seconds: args.startSeconds,
        end_seconds: args.endSeconds,
        page_size: 100,
        limit: 100,
        // Canonical dispatcher uses no explicit status list so order-pull searches all statuses once.
        // Detail must follow every pulled order; do not cap detail below pulled order count.
        statuses: [],
        max_pages: args.mode === "recent_pull" ? 1 : 1,
        max_orders: 100,
        max_orders_per_account: 100,
        max_details: 100,
        max_details_per_account: 100,
        include_previous_unpacked: false,
        include_statusless_search: false,
        include_update_time_search: false,
        statusless_only: false,
        skip_completed_order_pull: false,
        source: "marketplace_order_dispatcher",
        dispatcher_mode: args.mode,
      }),
    });

    const textBody = await response.text();
    let data: any = {};
    try {
      data = textBody ? JSON.parse(textBody) : {};
    } catch {
      data = { raw: textBody };
    }

    return {
      ok: response.ok && data?.ok !== false,
      status: response.status,
      orders: numberOr(data?.orders, 0),
      items: numberOr(data?.items, 0),
      message: data?.message || data?.error || textBody.slice(0, 500) || `HTTP ${response.status}`,
      data,
    };
  } catch (err) {
    return { ok: false, status: 0, orders: 0, items: 0, message: String(err), data: null };
  }
}

async function finishBootstrapComplete(admin: any, state: ClaimedState, decision: any) {
  const nowIso = new Date().toISOString();
  const { error } = await admin
    .from("marketplace_order_sync_state")
    .update({
      bootstrap_status: "done",
      bootstrap_completed_at: nowIso,
      recent_cursor_seconds: decision.nextCursorSeconds,
      last_mode: "bootstrap_complete",
      last_error: null,
      failure_count: 0,
      lock_token: null,
      locked_until: null,
      next_run_at: new Date(Date.now() + 15 * 1000).toISOString(),
      updated_at: nowIso,
    })
    .eq("sync_state_id", state.sync_state_id);

  if (error) throw new Error(`Finish bootstrap complete gagal: ${error.message}`);
}

async function finishSuccess(admin: any, state: ClaimedState, decision: any, child: any) {
  const nowIso = new Date().toISOString();
  const updatePayload: Record<string, unknown> = {
    last_success_window_start_seconds: decision.startSeconds,
    last_success_window_end_seconds: decision.endSeconds,
    last_success_at: nowIso,
    last_mode: decision.mode,
    last_error: null,
    failure_count: 0,
    lock_token: null,
    locked_until: null,
    updated_at: nowIso,
  };

  if (decision.mode === "bootstrap_90d") {
    updatePayload.bootstrap_cursor_seconds = decision.nextCursorSeconds;
    updatePayload.bootstrap_status =
      decision.nextCursorSeconds >= numberOr(state.bootstrap_to_seconds, decision.nextCursorSeconds)
        ? "done"
        : "running";
    if (updatePayload.bootstrap_status === "done") {
      updatePayload.bootstrap_completed_at = nowIso;
      updatePayload.recent_cursor_seconds = decision.nextCursorSeconds;
      updatePayload.next_run_at = new Date(Date.now() + 15 * 1000).toISOString();
    } else {
      updatePayload.next_run_at = new Date(Date.now() + 30 * 1000).toISOString();
    }
  } else {
    updatePayload.recent_cursor_seconds = decision.nextCursorSeconds;
    updatePayload.recent_caught_up_at = new Date().toISOString();
    updatePayload.next_run_at = decision.mode === "recent_pull"
      ? new Date(Date.now() + 120 * 1000).toISOString()
      : new Date(Date.now() + 30 * 1000).toISOString();
  }

  const { error } = await admin
    .from("marketplace_order_sync_state")
    .update(updatePayload)
    .eq("sync_state_id", state.sync_state_id);

  if (error) throw new Error(`Finish success gagal: ${error.message}`);
}

async function finishFailure(admin: any, state: ClaimedState, message: string) {
  const failureCount = Math.max(0, numberOr(state.failure_count, 0)) + 1;
  const backoffSeconds = Math.min(30 * 60, 60 * Math.max(1, failureCount));
  const { error } = await admin
    .from("marketplace_order_sync_state")
    .update({
      bootstrap_status: state.bootstrap_status === "running" ? "pending" : state.bootstrap_status,
      last_error: message.slice(0, 1000),
      failure_count: failureCount,
      lock_token: null,
      locked_until: null,
      next_run_at: new Date(Date.now() + backoffSeconds * 1000).toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq("sync_state_id", state.sync_state_id);

  if (error) throw new Error(`Finish failure gagal: ${error.message}`);
}

async function releaseWithoutWork(admin: any, state: ClaimedState) {
  await admin
    .from("marketplace_order_sync_state")
    .update({
      lock_token: null,
      locked_until: null,
      next_run_at: new Date(Date.now() + 30 * 1000).toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq("sync_state_id", state.sync_state_id);
}

async function safeJson(req: Request): Promise<any> {
  try {
    return await req.json();
  } catch {
    return {};
  }
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "content-type": "application/json" },
  });
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`${name} kosong.`);
  return value;
}

function clampInt(value: unknown, min: number, max: number, fallback: number): number {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.floor(n)));
}

function numberOr(value: unknown, fallback: number): number {
  const n = Number(value);
  return Number.isFinite(n) ? Math.floor(n) : fallback;
}
