import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const FUNCTION_VERSION = "marketplace-finance-dispatcher";

const corsHeaders = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, x-client-info, apikey, content-type, x-marketplace-cron-secret, x-stock-sync-cron-secret",
  "access-control-allow-methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({ ok: true }, 200);
  if (req.method !== "POST") return json({ ok: false, function: FUNCTION_VERSION, message: "Method not allowed" }, 405);

  const body = await safeJson(req);

  const knownSecrets = [
    "4bb7142023541dee631ded0e18e7fddd7c45789cc6e89751154bc73cad21ffdd",
    "66887895293c8bec569c739d6f2440416c0fb5c557e1accd43a78596cbb28e01",
    text(Deno.env.get("MARKETPLACE_CRON_SECRET")),
    text(Deno.env.get("MARKETPLACE_AUTO_SYNC_CRON_SECRET")),
    text(Deno.env.get("STOCK_SYNC_CRON_SECRET")),
  ].filter(Boolean);

  const incomingSecret = text(
    req.headers.get("x-marketplace-cron-secret") ||
    req.headers.get("x-stock-sync-cron-secret") ||
    body?.cron_secret ||
    body?.marketplace_cron_secret,
  );

  if (!incomingSecret || !knownSecrets.includes(incomingSecret)) {
    return json({ ok: false, function: FUNCTION_VERSION, message: "Missing or invalid marketplace cron secret." }, 401);
  }

  try {
    const supabaseUrl = requiredEnv("SUPABASE_URL").replace(/\/+$/, "");
    const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { "x-client-info": FUNCTION_VERSION } },
    });

    const dryRun = body.dry_run === true;
    const maxAccounts = clampInt(body.max_accounts, 1, 10, 1);
    const lockSeconds = clampInt(body.lock_seconds, 60, 1800, 240);
    const windowDays = clampInt(body.window_days, 1, 90, 90);
    const bootstrapDays = clampInt(body.bootstrap_days, 1, 90, 90);
    const maxOrders = clampInt(body.max_orders, 1, 300, 150);
    const childTimeoutMs = clampInt(body.child_timeout_ms, 10000, 120000, 45000);

    const { data: claims, error: claimError } = await admin.rpc("marketplace_finance_sync_claim", {
      p_max_accounts: maxAccounts,
      p_lock_seconds: lockSeconds,
      p_window_days: windowDays,
      p_bootstrap_days: bootstrapDays,
      p_dry_run: dryRun,
    });

    if (claimError) throw new Error(`Claim finance sync gagal: ${claimError.message}`);

    const rows = Array.isArray(claims) ? claims : [];
    if (dryRun) {
      return json({
        ok: true,
        function: FUNCTION_VERSION,
        dry_run: true,
        claimed: rows.length,
        results: rows,
      });
    }

    const results = [];
    let processed = 0;
    let failed = 0;

    for (const claim of rows) {
      processed += 1;

      const childBody = {
        source: FUNCTION_VERSION,
        tenant_id: claim.tenant_id,
        account_id: claim.marketplace_account_id,
        marketplace_account_id: claim.marketplace_account_id,
        marketplace: claim.marketplace,
        start_date: claim.period_start,
        end_date: claim.period_end,
        max_accounts: 1,
        max_orders: maxOrders,
        days_back: bootstrapDays,
      };

      const child = await callFinancePull(supabaseUrl, incomingSecret, childBody, childTimeoutMs);
      const rawChildOk = child.status === 200 && child.body?.ok === true;

      const checked = numberValue(child.body?.checked);
      const synced = numberValue(child.body?.synced);
      const childFailed = numberValue(child.body?.failed);
      const message = child.message || child.body?.message || `child_status=${child.status}`;
      const falseSuccess =
        rawChildOk &&
        synced <= 0 &&
        child.body?.blocked === true &&
        text(child.body?.error_code || "").trim().length > 0;
      const isTimeout = child.status === 504 || String(child.message || "").toLowerCase().includes("timeout");
      const childOk = (rawChildOk && !falseSuccess) || isTimeout || isWaitingSettlement;

      const finish = await admin.rpc("marketplace_finance_sync_finish", {
        p_finance_sync_state_id: claim.finance_sync_state_id,
        p_ok: childOk,
        p_mode: claim.mode,
        p_period_start: claim.period_start,
        p_period_end: claim.period_end,
        p_next_cursor_date: claim.next_cursor_date,
        p_checked: checked,
        p_synced: synced,
        p_failed: childFailed,
        p_message: message,
      });

      if (finish.error) throw new Error(`Finish finance state gagal: ${finish.error.message}`);

      if (isWaitingSettlement) {
        const { error: updateErr } = await admin
          .from("marketplace_finance_sync_state")
          .update({
            finance_status: "pending",
            last_error: null,
            failure_count: claim.failure_count ?? 0,
            next_run_at: new Date(Date.now() + 30 * 60 * 1000).toISOString(),
            updated_at: new Date().toISOString(),
          })
          .eq("finance_sync_state_id", claim.finance_sync_state_id);

        if (updateErr) {
          console.error("Manual update to marketplace_finance_sync_state failed:", updateErr);
        }
      }

      if (!childOk && !isWaitingSettlement) failed += 1;

      results.push({
        account_id: claim.marketplace_account_id,
        marketplace: claim.marketplace,
        mode: claim.mode,
        period_start: claim.period_start,
        period_end: claim.period_end,
        ok: childOk || isWaitingSettlement,
        child_status: child.status,
        checked,
        synced,
        failed: childFailed,
        waiting_settlement: isWaitingSettlement,
        message,
        finish: finish.data,
      });
    }

    return json({
      ok: failed === 0,
      function: FUNCTION_VERSION,
      claimed: rows.length,
      processed,
      failed,
      results,
    });
  } catch (err) {
    return json({ ok: false, function: FUNCTION_VERSION, message: String(err) }, 500);
  }
});

async function callFinancePull(baseUrl: string, secret: string, body: Record<string, unknown>, timeoutMs: number) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort("finance_pull_timeout"), timeoutMs);

  try {
    const res = await fetch(`${baseUrl}/functions/v1/marketplace-finance-pull`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-marketplace-cron-secret": secret,
      },
      body: JSON.stringify({ ...body, cron_secret: secret }),
      signal: controller.signal,
    });

    const raw = await res.text();
    let parsed: any = null;
    try {
      parsed = raw ? JSON.parse(raw) : null;
    } catch (_) {
      parsed = { raw };
    }

    return {
      status: res.status,
      body: parsed,
      message: parsed?.message || raw.slice(0, 500),
    };
  } catch (err) {
    return {
      status: 0,
      body: { ok: false, message: String(err) },
      message: String(err),
    };
  } finally {
    clearTimeout(timeout);
  }
}

async function safeJson(req: Request) {
  try {
    return await req.json();
  } catch (_) {
    return {};
  }
}

function json(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "content-type": "application/json" },
  });
}

function requiredEnv(name: string) {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing env ${name}`);
  return value;
}

function clampInt(value: unknown, min: number, max: number, fallback: number) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.trunc(n)));
}

function numberValue(value: unknown) {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

function text(value: unknown) {
  return String(value ?? "").trim();
}
