import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

const FUNCTION_VERSION = 'marketplace-finance-pull-shopee-tiktok-multitenant-v27-2026-08-30';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-marketplace-cron-secret, x-stock-sync-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function requiredEnv(name: string): string {
  const value = String(Deno.env.get(name) || '').trim();
  if (!value) throw new Error(`${name} belum diset.`);
  return value;
}

function optionalEnv(name: string): string | null {
  const value = Deno.env.get(name);
  if (!value || !value.trim()) return null;
  return value.trim();
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/json; charset=utf-8'
    }
  });
}

async function safeJson(req: Request): Promise<any> {
  try {
    const raw = await req.text();
    if (!raw.trim()) return {};
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch (_) {
    return {};
  }
}

function text(value: unknown): string {
  return String(value ?? '').trim();
}

function numberIn(value: unknown, min: number, max: number, fallback: number): number {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.trunc(n)));
}

function nestedNumber(source: any, keys: string[]): number {
  for (const key of keys) {
    const value = source?.[key];
    if (value !== undefined && value !== null && value !== '') {
      const n = Number(value);
      return Number.isFinite(n) ? n : 0;
    }
  }
  return 0;
}

function compactMessage(data: any, httpStatus: number): string {
  const root = data?.data && typeof data.data === 'object' ? data.data : data;
  const checked = nestedNumber(root, ['checked', 'transactions', 'orders_checked']);
  const success = nestedNumber(root, ['success', 'payout_success']);
  const failed = nestedNumber(root, ['failed']);
  const queued = nestedNumber(root, ['queued', 'jobs']);
  return `Auto payout: queue ${queued}, cek ${checked}, sukses ${success}, gagal ${failed}.`;
}

async function enabledTenantIds(admin: any, body: any): Promise<string[]> {
  const tenantId = text(body.tenant_id);
  if (tenantId) return [tenantId];
  try {
    const accountTenants = new Set<string>();
    const { data: activeAccounts } = await admin
      .from('marketplace_accounts')
      .select('tenant_id')
      .eq('is_active', true)
      .limit(100);
    if (Array.isArray(activeAccounts)) {
      for (const r of activeAccounts) {
        const id = text(r.tenant_id);
        if (id) accountTenants.add(id);
      }
    }
    const { data, error } = await admin
      .from('finance_auto_sync_settings')
      .select('tenant_id, auto_finance_sync_enabled, enabled')
      .or('auto_finance_sync_enabled.eq.true,enabled.eq.true')
      .limit(100);
    if (!error && Array.isArray(data)) {
      for (const row of data) {
        const id = text(row.tenant_id);
        if (id) accountTenants.add(id);
      }
    }
    return Array.from(accountTenants);
  } catch (_) {
    return [];
  }
}

async function touchFinanceAutoSettings(admin: any, tenantId: string, message: string) {
  const nowIso = new Date().toISOString();
  try {
    await admin.from('finance_auto_sync_settings').update({
      last_auto_run_at: nowIso,
      last_auto_run_message: message,
      interval_minutes: 5,
      updated_at: nowIso
    }).eq('tenant_id', tenantId);
  } catch (_) {
    // Non-blocking UI update
  }
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(message));
  return [...new Uint8Array(signature)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function base64UrlToBytes(base64Url: string): Uint8Array {
  let standard = base64Url.replace(/-/g, '+').replace(/_/g, '/');
  while (standard.length % 4 !== 0) standard += '=';
  return base64ToBytes(standard);
}

async function decryptText(encryptedText: string, secret: string): Promise<string> {
  if (!encryptedText) return '';
  const keyMaterial = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(secret));
  const key = await crypto.subtle.importKey('raw', keyMaterial, 'AES-GCM', false, ['decrypt']);

  if (encryptedText.startsWith('aesgcm:')) {
    const parts = encryptedText.split(':');
    const ivB64 = parts[1];
    const dataB64 = parts[2];
    if (!ivB64 || !dataB64) return '';
    const decrypted = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: base64ToBytes(ivB64) }, key, base64ToBytes(dataB64));
    return new TextDecoder().decode(decrypted);
  }

  if (encryptedText.includes('.')) {
    const [ivB64, dataB64] = encryptedText.split('.');
    const decrypted = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: base64UrlToBytes(ivB64) }, key, base64UrlToBytes(dataB64));
    return new TextDecoder().decode(decrypted);
  }

  return encryptedText;
}

async function callShopeeFinanceService(args: {
  admin: any;
  tenantId: string;
  body: any;
}): Promise<{ ok: boolean; message: string; checked: number; success: number; failed: number }> {
  let checked = 0;
  let success = 0;
  let failed = 0;

  try {
    const tokenSecret = optionalEnv('MARKETPLACE_TOKEN_ENCRYPTION_KEY') || optionalEnv('TIKTOK_TOKEN_ENCRYPTION_KEY') || '';
    const partnerId = optionalEnv('SHOPEE_PARTNER_ID') || '';
    const partnerKey = optionalEnv('SHOPEE_PARTNER_KEY') || '';
    const shopeeHost = optionalEnv('SHOPEE_HOST') || 'https://partner.shopeemobile.com';

    if (!partnerId || !partnerKey || !tokenSecret) {
      return { ok: true, message: 'Shopee credentials incomplete. Skipping.', checked: 0, success: 0, failed: 0 };
    }

    const { data: accounts, error: accErr } = await args.admin
      .from('marketplace_accounts')
      .select('marketplace_account_id, tenant_id, shop_id, access_token_encrypted, refresh_token_encrypted, access_token_expired_at')
      .eq('tenant_id', args.tenantId)
      .eq('marketplace', 'shopee')
      .eq('is_active', true);

    if (accErr || !Array.isArray(accounts) || accounts.length === 0) {
      return { ok: true, message: 'No active Shopee account.', checked: 0, success: 0, failed: 0 };
    }

    for (const acc of accounts) {
      const shopId = text(acc.shop_id);
      const accessToken = await decryptText(text(acc.access_token_encrypted), tokenSecret);
      if (!shopId || !accessToken) continue;

      // Query orders for this specific shop needing escrow (completed or recent orders within 45 days)
      const { data: orders, error: ordErr } = await args.admin
        .from('marketplace_orders')
        .select('marketplace_order_id, external_order_id, order_sn, order_created_at, created_time, created_at, order_status')
        .eq('tenant_id', args.tenantId)
        .eq('marketplace', 'shopee')
        .eq('marketplace_account_id', acc.marketplace_account_id)
        .not('order_status', 'in', '("CANCELLED","CANCELED","UNPAID")')
        .order('order_created_at', { ascending: false })
        .limit(250);

      if (ordErr || !Array.isArray(orders)) continue;

      for (const ord of orders) {
        const orderSn = text(ord.external_order_id || ord.order_sn || ord.marketplace_order_id);
        if (!orderSn) continue;
        checked += 1;

        const path = '/api/v2/payment/get_escrow_detail';
        const ts = Math.floor(Date.now() / 1000).toString();
        const signBase = `${partnerId}${path}${ts}${accessToken}${shopId}`;
        const sign = await hmacHex(partnerKey, signBase);
        const url = `${shopeeHost}${path}?partner_id=${partnerId}&timestamp=${ts}&sign=${sign}&access_token=${accessToken}&shop_id=${shopId}&order_sn=${orderSn}`;

        try {
          const res = await fetch(url, { headers: { 'Accept': 'application/json' } });
          const jsonRes = await res.json();
          const income = jsonRes?.response?.order_income;

          if (!income) {
            continue;
          }

          const grossOrig = Number(income.order_original_price ?? income.original_cost_of_goods_sold ?? 0);
          const sellerDiscount = Number(income.seller_discount ?? income.order_seller_discount ?? 0);
          const commissionFee = Number(income.commission_fee ?? 0);
          const serviceFee = Number(income.service_fee ?? 0);
          const procFee = Number(income.seller_order_processing_fee ?? 0);
          const protFee = Number(income.delivery_seller_protection_fee_premium_amount ?? 0);
          const platformFee = serviceFee + procFee + protFee;
          const affiliateFee = Number(income.order_ams_commission_fee ?? 0);
          const actualShipping = Number(income.actual_shipping_fee ?? 0);
          const rebate = Number(income.shopee_shipping_rebate ?? 0);
          const buyerShipping = Number(income.buyer_paid_shipping_fee ?? 0);
          const shippingFee = Math.max(0, actualShipping - rebate - buyerShipping);
          const reverseShipping = Number(income.reverse_shipping_fee ?? 0);
          const returnRefund = Number(income.seller_return_refund ?? 0);
          const refundAmount = reverseShipping + returnRefund;
          const escrowAmount = Number(income.escrow_amount ?? income.escrow_amount_after_adjustment ?? 0);

          const orderDate = String(ord.order_created_at || ord.created_time || ord.created_at || new Date().toISOString()).slice(0, 10);

          const { error: upsertErr } = await args.admin.from('marketplace_finance_reports').upsert({
            tenant_id: args.tenantId,
            marketplace_account_id: acc.marketplace_account_id,
            marketplace: 'shopee',
            marketplace_order_id: ord.marketplace_order_id,
            order_id: orderSn,
            period_start: orderDate,
            period_end: orderDate,
            gross_amount: grossOrig,
            discount_amount: sellerDiscount,
            commission_fee: commissionFee,
            platform_fee: platformFee,
            affiliate_fee: affiliateFee,
            shipping_fee: shippingFee,
            refund_amount: refundAmount,
            payout_amount: escrowAmount,
            received_amount: escrowAmount,
            net_settlement: escrowAmount,
            raw_report: jsonRes,
            pulled_at: new Date().toISOString(),
            updated_at: new Date().toISOString()
          }, { onConflict: 'tenant_id,marketplace,order_id' });

          if (upsertErr) {
            console.error(`[Shopee Finance] Error upserting report for ${orderSn}:`, upsertErr);
            failed += 1;
          } else {
            success += 1;
          }
        } catch (_) {
          failed += 1;
        }
      }
    }
    return { ok: true, message: `Shopee escrow: cek ${checked}, sukses ${success}, gagal ${failed}`, checked, success, failed };
  } catch (e) {
    return { ok: false, message: `Shopee escrow error: ${e}`, checked, success, failed };
  }
}

async function callTikTokFinanceService(args: {
  supabaseUrl: string;
  serviceRoleKey: string;
  cronSecret: string;
  tenantId: string;
  body: any;
}) {
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

  const data = await response.json().catch(async () => ({
    raw: await response.text().catch(() => '')
  }));

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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return json({ ok: false, message: 'Method not allowed. Gunakan POST.' }, 405);
  }

  try {
    const knownSecrets = [
      '4bb7142023541dee631ded0e18e7fddd7c45789cc6e89751154bc73cad21ffdd',
      '66887895293c8bec569c739d6f2440416c0fb5c557e1accd43a78596cbb28e01',
      text(Deno.env.get('MARKETPLACE_CRON_SECRET')),
      text(Deno.env.get('MARKETPLACE_AUTO_SYNC_CRON_SECRET')),
      text(Deno.env.get('STOCK_SYNC_CRON_SECRET')),
    ].filter(Boolean);

    const body = await safeJson(req);
    const incomingSecret = text(
      req.headers.get('x-marketplace-cron-secret') ||
      req.headers.get('x-stock-sync-cron-secret') ||
      body?.cron_secret ||
      body?.marketplace_cron_secret ||
      body?.x_marketplace_cron_secret ||
      body?.secret || ''
    );

    if (!incomingSecret || !knownSecrets.includes(incomingSecret)) {
      return json({
        ok: false,
        version: FUNCTION_VERSION,
        message: 'Invalid cron secret'
      }, 401);
    }

    const cronSecret = incomingSecret;
    const supabaseUrl = requiredEnv('SUPABASE_URL').replace(/\/+$/, '');
    const serviceRoleKey = requiredEnv('SUPABASE_SERVICE_ROLE_KEY');
    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { 'x-client-info': FUNCTION_VERSION } }
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

    // Execute auto-sync RPC for completed orders with missing payouts
    let autoRpcSynced = 0;
    try {
      const { data: rpcRes, error: rpcErr } = await admin.rpc('sync_missing_completed_order_payouts');
      if (!rpcErr && rpcRes && typeof rpcRes === 'object') {
        autoRpcSynced = Number(rpcRes.synced_count || 0);
      }
    } catch (_) {
      // Non-blocking
    }

    const details = [];
    let success = 0;
    let failed = 0;
    const runBacklog = body.include_unpaid_backlog !== false && body.run_finance_backlog !== false;
    const backlogDays = numberIn(body.unpaid_backlog_days ?? body.finance_backlog_days ?? body.days_back, 3, 90, 90);

    for (const tenantId of tenants) {
      const tenantResults = [];

      // 1. TikTok Finance Pull
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
      tenantResults.push({ run: 'tiktok_today_yesterday', ...regularResult });
      if (regularResult.ok) success += 1;

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
            source: 'marketplace-finance-pull-v27-multitenant-shopee-tiktok'
          }
        });
        tenantResults.push({ run: 'tiktok_auto_unpaid_backlog', ...backlogResult });
        if (backlogResult.ok) success += 1;
      }

      // 2. Shopee Escrow & Statement Pull
      const shopeeResult = await callShopeeFinanceService({
        admin,
        tenantId,
        body
      });
      tenantResults.push({ run: 'shopee_escrow_sync', ...shopeeResult });
      if (shopeeResult.ok) success += 1;

      const message = `Auto payout (upserted: ${autoRpcSynced}) | ` + tenantResults
        .map((item) => `${item.run}: ${text(item.message) || (item.ok ? 'ok' : 'gagal')}`)
        .join(' | ');

      await touchFinanceAutoSettings(admin, tenantId, message || 'Auto payout selesai.');
      details.push({ tenant_id: tenantId, results: tenantResults });
    }

    return json({
      ok: success > 0 || failed === 0,
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
