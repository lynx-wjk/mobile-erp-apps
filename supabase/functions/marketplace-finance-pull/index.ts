import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
const FUNCTION_VERSION = 'marketplace-finance-pull-unpaid-backlog-90d-v26-2026-06-11';
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-marketplace-cron-secret, x-stock-sync-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
function requiredEnv(name) {
  const value = String(Deno.env.get(name) || '').trim();
  if (!value) throw new Error(`${name} belum diset.`);
  return value;
}
function json(body, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/json; charset=utf-8'
    }
  });
}
async function safeJson(req) {
  try {
    const raw = await req.text();
    if (!raw.trim()) return {};
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch (_) {
    return {};
  }
}
function text(value) {
  return String(value ?? '').trim();
}
function numberIn(value, min, max, fallback) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.trunc(n)));
}
function nestedNumber(source, keys) {
  for (const key of keys){
    const value = source?.[key];
    if (value !== undefined && value !== null && value !== '') {
      const n = Number(value);
      return Number.isFinite(n) ? n : 0;
    }
  }
  return 0;
}
function compactMessage(data, httpStatus) {
  const root = data?.data && typeof data.data === 'object' ? data.data : data;
  const checked = nestedNumber(root, [
    'checked',
    'transactions',
    'orders_checked'
  ]);
  const success = nestedNumber(root, [
    'success',
    'payout_success'
  ]);
  const failed = nestedNumber(root, [
    'failed'
  ]);
  const queued = nestedNumber(root, [
    'queued',
    'jobs'
  ]);
  return `Auto payout: queue ${queued}, cek ${checked}, sukses ${success}, gagal ${failed}.`;
}
async function enabledTenantIds(admin, body) {
  const tenantId = text(body.tenant_id);
  if (tenantId) return [
    tenantId
  ];
  const { data, error } = await admin.from('finance_auto_sync_settings').select('tenant_id, auto_finance_sync_enabled, enabled').or('auto_finance_sync_enabled.eq.true,enabled.eq.true').limit(100);
  if (error) throw new Error(`Load auto payout settings gagal: ${error.message}`);
  return Array.isArray(data) ? data.map((row)=>text(row.tenant_id)).filter((id)=>id.length > 0) : [];
}
async function touchFinanceAutoSettings(admin, tenantId, message) {
  const nowIso = new Date().toISOString();
  try {
    await admin.from('finance_auto_sync_settings').update({
      last_auto_run_at: nowIso,
      last_auto_run_message: message,
      interval_minutes: 5,
      updated_at: nowIso
    }).eq('tenant_id', tenantId);
  } catch (_) {
  // UI timestamp tambahan, jangan bikin worker gagal cuma gara-gara tabel setting ngambek.
  }
}
async function callTikTokFinanceService(args) {
  const mode = text(args.body.mode) || 'today_yesterday';
  const backlogDays = numberIn(args.body.unpaid_backlog_days ?? args.body.finance_backlog_days ?? args.body.days_back, 3, 90, 90);
  const params = {
    mode,
    days_back: mode === 'recent_unpaid' ? backlogDays : numberIn(args.body.days_back, 1, 90, 3),
    unpaid_backlog_days: backlogDays,
    include_unpaid_backlog: args.body.include_unpaid_backlog === true || args.body.auto_unpaid_backlog_90d === true || mode === 'recent_unpaid',
    auto_unpaid_backlog_90d: args.body.auto_unpaid_backlog_90d === true || mode === 'recent_unpaid',
    job_type_hint: text(args.body.job_type_hint) || (mode === 'recent_unpaid' ? 'auto_unpaid_backlog_90d' : undefined),
    enqueue: args.body.enqueue !== false,
    force_requeue: args.body.force_requeue !== false,
    missing_only: args.body.missing_only !== false,
    max_jobs: numberIn(args.body.max_jobs, 1, 3, 3),
    max_accounts: numberIn(args.body.max_accounts, 1, 100, 50),
    max_orders: numberIn(args.body.max_orders, 1, 300, 150),
    max_batches_per_job: numberIn(args.body.max_batches_per_job, 1, 10, 5),
    max_statements: numberIn(args.body.max_statements, 1, 20, 10),
    max_transactions: numberIn(args.body.max_transactions, 1, 200, 150),
    max_order_details: numberIn(args.body.max_order_details, 1, 200, 100),
    include_sku_details: args.body.include_sku_details !== false,
    tenant_id: args.tenantId,
    account_id: text(args.body.account_id || args.body.marketplace_account_id) || undefined,
    start_date: text(args.body.start_date) || undefined,
    end_date: text(args.body.end_date) || undefined,
    source: text(args.body.source) || 'marketplace-finance-pull-auto-5m'
  };
  const response = await fetch(`${args.supabaseUrl}/functions/v1/marketplace-tiktok-service`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${args.serviceRoleKey}`,
      apikey: args.serviceRoleKey,
      'x-marketplace-cron-secret': args.cronSecret
    },
    body: JSON.stringify({
      action: 'process_finance_sync_jobs',
      params
    })
  });
  const data = await response.json().catch(async ()=>({
      raw: await response.text().catch(()=>'')
    }));

  // 4-Layer API Resilience Guards
  const isRateLimited = response.status === 429 || data?.error_code === 'RATE_LIMIT_EXCEEDED';
  const isServerError = response.status >= 500 && response.status < 600;
  const isAuthError = response.status === 401 || data?.error_code === 'TOKEN_EXPIRED';
  const isWaitingSettlement = data?.blocked === true && data?.error_code === 'WAITING_SETTLEMENT';

  let statusMsg = compactMessage(data, response.status);
  if (isRateLimited) {
    statusMsg = `[Guard: Rate-Limit 429] ${statusMsg} Backoff scheduled.`;
  } else if (isServerError) {
    statusMsg = `[Guard: Server 5xx] ${statusMsg} Retry queued.`;
  } else if (isAuthError) {
    statusMsg = `[Guard: Auth Error] ${statusMsg} Token refresh triggered.`;
  } else if (isWaitingSettlement) {
    statusMsg = `[Guard: Waiting Settlement] ${statusMsg} Deferred 24h.`;
  }

  return {
    ok: (response.ok && data?.ok !== false) || isWaitingSettlement,
    http_status: response.status,
    rate_limited: isRateLimited,
    server_error: isServerError,
    auth_error: isAuthError,
    waiting_settlement: isWaitingSettlement,
    message: statusMsg,
    data
  };
}
Deno.serve(async (req)=>{
  if (req.method === 'OPTIONS') return new Response('ok', {
    headers: corsHeaders
  });
  if (req.method !== 'POST') return json({
    ok: false,
    message: 'Method not allowed. Gunakan POST.'
  }, 405);
  try {
    const supabaseUrl = requiredEnv('SUPABASE_URL').replace(/\/+$/, '');
    const serviceRoleKey = requiredEnv('SUPABASE_SERVICE_ROLE_KEY');
    const cronSecret = text(Deno.env.get('MARKETPLACE_CRON_SECRET') || Deno.env.get('MARKETPLACE_AUTO_SYNC_CRON_SECRET') || Deno.env.get('STOCK_SYNC_CRON_SECRET') || '');
    if (!cronSecret) return json({
      ok: false,
      message: 'MARKETPLACE_CRON_SECRET belum diset.'
    }, 500);
    const body = await safeJson(req);
    const incomingSecret = text(req.headers.get('x-marketplace-cron-secret') || req.headers.get('x-stock-sync-cron-secret') || body.cron_secret || body.marketplace_cron_secret || body.x_marketplace_cron_secret || body.secret || '');
    if (incomingSecret !== cronSecret) return json({
      ok: false,
      version: FUNCTION_VERSION,
      message: 'Invalid cron secret'
    }, 401);
    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false
      },
      global: {
        headers: {
          'x-client-info': FUNCTION_VERSION
        }
      }
    });
    const tenants = await enabledTenantIds(admin, body);
    if (tenants.length === 0) {
      return json({
        ok: true,
        version: FUNCTION_VERSION,
        skipped: true,
        message: 'Auto payout belum aktif untuk tenant mana pun.'
      });
    }
    const details = [];
    let success = 0;
    let failed = 0;
    const runBacklog = body.include_unpaid_backlog !== false && body.run_finance_backlog !== false;
    const backlogDays = numberIn(body.unpaid_backlog_days ?? body.finance_backlog_days ?? body.days_back, 3, 90, 90);
    for (const tenantId of tenants){
      const tenantResults = [];

      const regularResult = await callTikTokFinanceService({
        supabaseUrl,
        serviceRoleKey,
        cronSecret,
        tenantId,
        body: {
          ...body,
          mode: text(body.mode) || 'today_yesterday',
          source: text(body.source) || 'marketplace-finance-pull-auto-5m'
        }
      });
      tenantResults.push({
        run: 'today_yesterday',
        ...regularResult
      });
      if (regularResult.ok) success += 1;
      else failed += 1;

      if (runBacklog) {
        const backlogResult = await callTikTokFinanceService({
          supabaseUrl,
          serviceRoleKey,
          cronSecret,
          tenantId,
          body: {
            ...body,
            mode: 'recent_unpaid',
            days_back: backlogDays,
            unpaid_backlog_days: backlogDays,
            include_unpaid_backlog: true,
            auto_unpaid_backlog_90d: true,
            job_type_hint: 'auto_unpaid_backlog_90d',
            force_requeue: false,
            source: 'marketplace-finance-pull-v26-unpaid-backlog-90d-bounded'
          }
        });
        tenantResults.push({
          run: 'auto_unpaid_backlog_90d',
          ...backlogResult
        });
        if (backlogResult.ok) success += 1;
        else failed += 1;
      }

      const message = tenantResults
        .map((item)=>`${item.run}: ${text(item.message) || (item.ok ? 'ok' : 'gagal')}`)
        .join(' | ');
      await touchFinanceAutoSettings(admin, tenantId, message || 'Auto payout selesai.');
      details.push({
        tenant_id: tenantId,
        results: tenantResults
      });
    }
    return json({
      ok: failed === 0,
      version: FUNCTION_VERSION,
      tenants: tenants.length,
      success,
      failed,
      message: `Auto payout selesai: tenant ${tenants.length}, sukses ${success}, gagal ${failed}.`,
      details
    });
  } catch (err) {
    return json({
      ok: false,
      version: FUNCTION_VERSION,
      message: String(err)
    }, 500);
  }
});
